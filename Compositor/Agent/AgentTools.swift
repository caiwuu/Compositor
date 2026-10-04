import AppKit
import ImageIO
import UniformTypeIdentifiers

nonisolated struct AgentImage: Sendable {
    let data: Data
    let mimeType: String
}

/// What a tool hands back: JSON for the agent to read, and any pictures of the canvas.
struct AgentResult {
    var value: Any
    var images: [AgentImage] = []
}

/// One MCP tool: its name and JSON Schema for the tool list, and what it does.
struct AgentTool {
    let name: String
    let title: String
    let description: String
    let schema: JSONObject
    var readOnly = false
    var destructive = false
    let run: @MainActor (AgentArguments) async throws -> AgentResult

    var listing: JSONObject {
        ["name": name, "title": title, "description": description, "inputSchema": schema,
         "annotations": ["title": title, "readOnlyHint": readOnly, "destructiveHint": destructive,
                         "idempotentHint": readOnly, "openWorldHint": false]]
    }
}

/// The tools an AI agent drives Compositor with over MCP. Each works on an open document through the same session
/// methods the menus and tools use, so every change shows on the canvas as it happens and is one step in Undo.
@MainActor
final class AgentTools {
    let workspace: ProjectWorkspace
    private(set) var tools: [AgentTool] = []
    /// Each layer image's opaque bounds, kept with the image so the key can't be reused by another.
    var contentBoundsCache: [ObjectIdentifier: (image: CGImage, bounds: CGRect?)] = [:]

    init(workspace: ProjectWorkspace) {
        self.workspace = workspace
        tools = documentTools + perceptionTools + layerTools + pixelTools + selectionTools + canvasTools
    }

    func tool(named name: String) -> AgentTool? { tools.first { $0.name == name } }

    func call(_ name: String, _ arguments: JSONObject = [:]) async throws -> AgentResult {
        guard let tool = tool(named: name) else { throw AgentError("There’s no tool named \(name).") }
        return try await tool.run(AgentArguments(arguments))
    }

    // MARK: Finding things

    func tab(_ arguments: AgentArguments) throws -> ProjectTab {
        guard let id = try arguments.uuid("document_id") else { return workspace.current }
        guard let tab = workspace.tabs.first(where: { $0.id == id }) else {
            throw AgentError("No open document has the id \(id.uuidString). Call list_documents for the open ones.")
        }
        return tab
    }

    func canvas(_ session: EditorSession) throws -> CanvasDocument {
        guard let document = session.document else {
            throw AgentError("This document has no canvas yet. Make one with new_document, or add an image with add_image_layer.")
        }
        return document
    }

    func layer(_ id: UUID, in session: EditorSession) throws -> ImageLayer {
        guard let layer = session.document?.layers.first(where: { $0.id == id }) else {
            throw AgentError("No layer has the id \(id.uuidString). Call get_document for the current layers.")
        }
        return layer
    }

    /// The layer named by `layer_id`, else the active one, made the active layer so session methods act on it.
    func target(_ arguments: AgentArguments, in session: EditorSession, key: String = "layer_id") throws -> ImageLayer {
        let id = try arguments.uuid(key) ?? session.activeLayerID
        guard let id else { throw AgentError("Say which layer with “\(key)”; no layer is selected.") }
        let layer = try layer(id, in: session)
        if session.activeLayerID != id || session.selectedLayerIDs != [id] { session.selectLayers([id], primary: id) }
        session.isMaskSelected = false
        guard session.activeLayerID == id else { throw AgentError("Compositor couldn’t select that layer just now. Try again.") }
        return layer
    }

    // MARK: Waiting for the editor

    /// Waits out a short operation, applies what switching tools would apply, and reports anything else in the way.
    func ready(_ session: EditorSession) async throws {
        for _ in 0..<600 where session.isProjectBusy || session.isImporting || workspace.isManaging {
            try await Task.sleep(for: .milliseconds(50))
        }
        if session.gradientEdit != nil { await session.commitGradient() }
        if session.pixelMove != nil { await session.finishPixelMove() }
        session.commitTransform()
        session.cancelCrop()
        session.cancelLasso()
        session.cancelShape()
        if let reason = blocker(session) {
            throw AgentError("Compositor can’t take that edit right now: \(reason). Ask the person to finish or cancel it, then try again.")
        }
    }

    func blocker(_ session: EditorSession) -> String? {
        if workspace.isManaging { return "a file panel or an alert is open" }
        if session.textDraft != nil { return "text is being typed on the canvas" }
        if session.brushStroke != nil || session.warpStroke != nil { return "a brush stroke is in progress" }
        if session.levels != nil { return "the Levels dialog is open" }
        if session.hueSaturation != nil { return "the Hue/Saturation dialog is open" }
        if let edit = session.filterEdit { return "the \(edit.kind.rawValue) dialog is open" }
        if session.adjustmentEditingID != nil { return "an adjustment layer is being edited" }
        if session.colorRange != nil { return "the Color Range dialog is open" }
        if session.selectionAmountOperation != nil { return "a selection dialog is open" }
        if session.gradientEdit != nil { return "a gradient is waiting to be applied" }
        if session.pixelMove != nil { return "selected pixels are being moved" }
        if session.renamingLayerID != nil { return "a layer is being renamed" }
        if session.showsImporter || session.isImporting { return "images are being imported" }
        if session.importError != nil { return "an import error is showing" }
        if session.showsConversionSheet || session.showsRawDevelop { return "an import dialog is open" }
        if session.showsNewDocument && session.document != nil { return "the New Canvas sheet is open" }
        if session.isProjectBusy { return "another operation is still running" }
        if session.transformEdit != nil { return "a transform is in progress" }
        return nil
    }

    /// Runs `body` as one undo step named `name`. A failure part-way is undone, so nothing is left half done.
    /// Returns whether the document changed.
    @discardableResult
    func change(_ session: EditorSession, _ name: String, _ body: () async throws -> Void) async throws -> Bool {
        let before = session.history.currentRevision
        session.brushError = nil
        session.beginEdit(name)
        var failure: Error?
        do { try await body() } catch { failure = error }
        session.endEdit()
        if failure == nil, let message = session.brushError { failure = AgentError(message) }
        session.brushError = nil
        if let failure {
            if session.history.currentRevision != before { session.undo() }
            throw failure
        }
        return session.history.currentRevision != before
    }

    // MARK: Describing things

    func documentSummary(_ tab: ProjectTab) -> JSONObject {
        let session = tab.session
        var summary: JSONObject = ["document_id": tab.id.uuidString, "title": tab.title,
                                   "on_screen": tab.id == workspace.current.id, "unsaved_changes": session.isModified,
                                   "path": Self.orNull(session.projectURL?.path)]
        if let document = session.document {
            summary["width"] = document.width
            summary["height"] = document.height
            summary["layer_count"] = document.layers.count
        } else {
            summary["empty"] = true
        }
        return summary
    }

    func documentJSON(_ tab: ProjectTab) -> JSONObject {
        var result = documentSummary(tab)
        let session = tab.session
        guard let document = session.document else { return result }
        result["resolution"] = document.resolution
        result["active_layer_id"] = Self.orNull(session.activeLayerID?.uuidString)
        result["selected_layer_ids"] = session.selectedLayerIDs.map(\.uuidString).sorted()
        result["selection"] = selectionJSON(session)
        result["foreground_color"] = AgentColor.hex(session.foregroundColor)
        result["background_color"] = AgentColor.hex(session.backgroundColor)
        result["undo"] = session.history.canUndo ? session.history.undoName : NSNull()
        result["redo"] = session.history.canRedo ? session.history.redoName : NSNull()
        if !document.guides.isEmpty, let guides = try? AgentCoding.json(document.guides) { result["guides"] = guides }
        let visible = document.effectiveVisibleIDs
        let byID = Dictionary(uniqueKeysWithValues: document.layers.map { ($0.id, $0) })
        let entries = LayerHierarchy.entries(document.layers.map(\.hierarchyRecord), topFirst: true)
        result["layers"] = entries.compactMap { entry in
            byID[entry.layer.id].map { layerJSON($0, depth: entry.depth, shown: visible.contains($0.id)) }
        }
        return result
    }

    func layerJSON(_ layer: ImageLayer, depth: Int = 0, shown: Bool = true) -> JSONObject {
        let kind = layer.isGroup ? "folder" : layer.adjustment != nil ? "adjustment"
            : layer.liveText != nil ? "text" : layer.liveShape != nil ? "shape" : layer.asset == nil ? "empty" : "pixels"
        var json: JSONObject = [
            "id": layer.id.uuidString, "name": layer.name, "kind": kind, "depth": depth,
            "parent_id": Self.orNull(layer.parentID?.uuidString), "visible": layer.isVisible, "shown": shown,
            "opacity": layer.opacity, "blend_mode": layer.blendMode.rawValue,
            "x": layer.transform.origin.x, "y": layer.transform.origin.y,
            "width": layer.transform.size.width, "height": layer.transform.size.height,
            "rotation": layer.transform.rotation, "flip_horizontal": layer.transform.flipX, "flip_vertical": layer.transform.flipY,
        ]
        if let image = layer.asset?.image {
            json["pixel_width"] = image.width
            json["pixel_height"] = image.height
            json["content_bounds"] = Self.orNull(contentPlacement(layer).map { placed -> JSONObject in
                ["x": placed.bounds.minX, "y": placed.bounds.minY, "width": placed.bounds.width, "height": placed.bounds.height]
            })
        }
        if let source = layer.maskSourceID { json["clipped_to"] = source.uuidString }
        if let mask = layer.mask { json["mask"] = ["enabled": mask.isEnabled, "linked": mask.isLinked] }
        if let adjustment = layer.adjustment, let value = try? AgentCoding.json(adjustment) { json["adjustment"] = value }
        if let effects = layer.effects, let value = try? AgentCoding.json(effects) { json["effects"] = value }
        if let text = layer.liveText {
            json["text"] = ["content": text.style.content, "font": text.style.fontName as String, "size": text.style.fontSize,
                            "color": AgentColor.hex(red: text.style.red, green: text.style.green, blue: text.style.blue),
                            "alignment": text.style.alignment.rawValue, "tracking": text.style.tracking, "leading": text.style.leading,
                            "box_width": Self.orNull(text.style.boxSize?.width), "box_height": Self.orNull(text.style.boxSize?.height)]
        }
        if let shape = layer.liveShape {
            json["shape"] = ["kind": shape.style.kind.rawValue, "color": AgentColor.hex(shape.style.color),
                             "corner_radius": shape.style.cornerRadius, "line_width": Self.orNull(shape.style.lineWidth)]
        }
        return json
    }

    /// JSON null for a missing value: an optional left in `Any` stays wrapped and can't be encoded.
    nonisolated static func orNull(_ value: Any?) -> Any { value ?? NSNull() }

    func selectionJSON(_ session: EditorSession) -> Any {
        guard let selection = session.selection else { return NSNull() }
        if selection.isEmpty { return ["empty": true] }
        let box = selection.path.boundingBoxOfPath
        return ["x": box.minX, "y": box.minY, "width": box.width, "height": box.height, "feather": selection.feather]
    }

    /// What a change returns: whether anything happened, the undo step it made, and the layer it was about.
    func outcome(_ session: EditorSession, changed: Bool, layerID: UUID? = nil, extra: JSONObject = [:]) -> AgentResult {
        var json: JSONObject = ["changed": changed]
        if changed, session.history.canUndo { json["undo"] = session.history.undoName }
        if let layerID, let layer = session.document?.layers.first(where: { $0.id == layerID }) {
            json["layer"] = layerJSON(layer, shown: session.document?.effectiveVisibleIDs.contains(layerID) ?? true)
        }
        if session.document?.selection != nil || extra["selection"] != nil { json["selection"] = selectionJSON(session) }
        json.merge(extra) { _, new in new }
        return AgentResult(value: json)
    }

    // MARK: Pictures

    nonisolated static func encode(_ image: CGImage, as type: UTType, quality: Double = 0.85, background: PaletteColor? = nil) throws -> Data {
        let source = try background.map { try flattened(image, over: $0) } ?? image
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { throw ExportError.encode }
        CGImageDestinationAddImage(destination, source, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.encode }
        return data as Data
    }

    /// `image` over an opaque `background`.
    nonisolated static func flattened(_ image: CGImage, over background: PaletteColor) throws -> CGImage {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw ExportError.render }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(srgbRed: background.red, green: background.green, blue: background.blue, alpha: 1))
        context.fill(bounds)
        context.draw(image, in: bounds)
        guard let flattened = context.makeImage() else { throw ExportError.render }
        return flattened
    }

    /// `image` shrunk to fit `longSide`, never enlarged.
    nonisolated static func scaled(_ image: CGImage, longSide: Int) throws -> CGImage {
        let scale = min(1, CGFloat(longSide) / CGFloat(max(image.width, image.height)))
        guard scale < 1 else { return image }
        let width = max(1, Int((CGFloat(image.width) * scale).rounded())), height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ExportError.render }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw ExportError.render }
        return result
    }

    /// A new layer's pixels, ready for the document: sRGB, premultiplied RGBA, with its thumbnail.
    nonisolated static func asset(_ image: CGImage, name: String) throws -> ImportedImage {
        ImportedImage(image: image, thumbnail: try PixelAdjust.thumbnail(of: image), name: name)
    }

    /// A drawing surface the size of a layer, in the working pixel format, with y running down.
    nonisolated static func surface(width: Int, height: Int) throws -> CGContext {
        guard width > 0, height > 0, width <= DocumentLimits.maxSide, height <= DocumentLimits.maxSide,
              width * height <= DocumentLimits.maxSurfacePixels else {
            throw AgentError("That’s too large: a layer can be up to \(DocumentLimits.maxSide) pixels on a side and \(DocumentLimits.maxSurfaceMegapixels) megapixels.")
        }
        return try BrushRaster.context(width: width, height: height, mask: false)
    }
}
