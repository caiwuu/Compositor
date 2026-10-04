import AppKit
import UniformTypeIdentifiers

extension AgentTools {
    var documentTools: [AgentTool] {
        [
            AgentTool(name: "list_documents", title: "List Documents",
                description: "Lists the documents open in Compositor’s tabs: id, title, file path, canvas size, whether there are unsaved changes, and which one is on screen. Most tools take a document_id; without it they work on the one on screen.",
                schema: Schema.object([:]), readOnly: true) { [unowned self] _ in
                    AgentResult(value: ["documents": workspace.tabs.map { documentSummary($0) },
                                        "on_screen": workspace.current.id.uuidString])
                },
            AgentTool(name: "get_document", title: "Read Document",
                description: "Describes a document in full: canvas size and resolution, the selection’s bounds, foreground and background colors, what Undo and Redo would do, and every layer from the top of the Layers panel down. Each layer has its id, name, kind (pixels, empty, folder, adjustment, text, shape), parent folder and depth, visibility, opacity, blend mode, placement (x, y, width, height in document pixels, rotation in degrees clockwise, flips), its pixel size, mask, clipping, and its adjustment, effects, text or shape settings. Coordinates are document pixels from the top-left corner. Call this before editing and whenever ids are needed.",
                schema: Schema.object(["document_id": Schema.documentID]), readOnly: true) { [unowned self] arguments in
                    AgentResult(value: documentJSON(try tab(arguments)))
                },
            AgentTool(name: "get_canvas_image", title: "Look at Canvas",
                description: "Returns a picture of the canvas as it would export (or of one layer’s own pixels, or its mask), scaled to fit max_size, so you can see the result of your edits. Use region to look closely at part of the canvas. To place things exactly, turn on grid: lines labeled with their document coordinates. show_selection outlines the selection and outline_layer_ids outlines layers' content, labeled with their names. JPEG is smaller and shows transparency over the background color; PNG keeps transparency.",
                schema: Schema.object([
                    "document_id": Schema.documentID,
                    "layer_id": Schema.string("Show only this layer’s own pixels, unplaced, instead of the whole canvas."),
                    "mask": Schema.boolean("With layer_id: show the layer’s mask (white shows the layer, black hides it)."),
                    "grid": Schema.boolean("Draw grid lines labeled with their coordinates."),
                    "grid_spacing": Schema.integer("Pixels between grid lines. Default: a round number giving about eight lines.", minimum: 1),
                    "show_selection": Schema.boolean("Outline the selection (the canvas only)."),
                    "outline_layer_ids": Schema.array("Outline these layers’ opaque content, each in its own color (the canvas only).", items: Schema.layerID),
                    "max_size": Schema.integer("Longest side of the picture, in pixels. Default 1024.", minimum: 64, maximum: 4096),
                    "format": Schema.string("Default jpeg.", choices: ["jpeg", "png"]),
                    "background": Schema.string("JPEG only: the color under transparent areas. Default #FFFFFF."),
                ].merging(Schema.rect("the part of the canvas to show")) { a, _ in a }), readOnly: true) { [unowned self] arguments in
                    try await canvasImage(arguments)
                },
            AgentTool(name: "new_document", title: "New Canvas",
                description: "Opens a new canvas in its own tab (or the empty tab on screen) with one blank layer, and puts it on screen. Returns the new document, with its id.",
                schema: Schema.object([
                    "width": Schema.integer("Canvas width in pixels.", minimum: 1, maximum: DocumentLimits.maxSide),
                    "height": Schema.integer("Canvas height in pixels.", minimum: 1, maximum: DocumentLimits.maxSide),
                    "resolution": Schema.number("Pixels per inch, saved with the image. Default 72.", minimum: 1, maximum: 9600),
                    "fill": Schema.string("Fill the first layer with this color (#RRGGBB) instead of leaving it transparent."),
                ], required: ["width", "height"])) { [unowned self] arguments in
                    try await newDocument(arguments)
                },
            AgentTool(name: "open_project", title: "Open Project",
                description: "Opens a Compositor project (.comp) in a new tab and puts it on screen; a project already open is just brought forward.",
                schema: Schema.object(["path": Schema.string("Absolute path of the .comp project, or one starting with ~/.")], required: ["path"])) { [unowned self] arguments in
                    try await openProject(arguments)
                },
            AgentTool(name: "switch_document", title: "Switch Document",
                description: "Puts another open document on screen, as clicking its tab does.",
                schema: Schema.object(["document_id": Schema.documentID], required: ["document_id"])) { [unowned self] arguments in
                    let tab = try tab(arguments)
                    workspace.select(tab.id)
                    guard workspace.current.id == tab.id else {
                        throw AgentError("Compositor can’t switch tabs right now: \(blocker(workspace.current.session) ?? "something on screen is still open").")
                    }
                    return AgentResult(value: documentSummary(tab))
                },
            AgentTool(name: "save_project", title: "Save Project",
                description: "Saves a document as a Compositor project (.comp, keeping every layer editable). Without a path it saves where the project already lives; a document never saved needs a path. Compositor is sandboxed: it can write under ~/Pictures and ~/Downloads, and in folders the person has added in Compositor > MCP Server….",
                schema: Schema.object([
                    "document_id": Schema.documentID,
                    "path": Schema.string("Where to save, ending in .comp. Saving to a new path is Save As."),
                ])) { [unowned self] arguments in
                    try await saveProject(arguments)
                },
            AgentTool(name: "export_image", title: "Export Image",
                description: "Writes the flattened canvas to a PNG or JPEG file. The same folders as save_project are reachable.",
                schema: Schema.object([
                    "document_id": Schema.documentID,
                    "path": Schema.string("The file to write. Its extension (.png, .jpg) picks the format unless format is given."),
                    "format": Schema.string("Default from the path, else png.", choices: ["png", "jpeg"]),
                    "quality": Schema.number("JPEG quality from 0 to 1. Default 0.9.", minimum: 0, maximum: 1),
                    "background": Schema.string("JPEG only: the color under transparent areas. Default #FFFFFF."),
                ], required: ["path"])) { [unowned self] arguments in
                    try await exportImage(arguments)
                },
            AgentTool(name: "history", title: "Undo or Redo",
                description: "Undoes or redoes steps, exactly as Edit > Undo and Redo do. Every tool call that changes a document is one step.",
                schema: Schema.object([
                    "document_id": Schema.documentID,
                    "action": Schema.string("Which way to go.", choices: ["undo", "redo"]),
                    "steps": Schema.integer("How many steps. Default 1.", minimum: 1, maximum: 100),
                ], required: ["action"])) { [unowned self] arguments in
                    try await history(arguments)
                },
            AgentTool(name: "describe_settings", title: "Describe Settings",
                description: "Shows the settings a filter, adjustment or layer effect takes, with their default values, so you know which keys to pass to apply_filter, add_adjustment_layer, update_layer (adjustment, effects). Also lists installed fonts for text layers. Numbers outside a setting’s range are clamped.",
                schema: Schema.object([
                    "topic": Schema.string("What to describe.", choices: ["filter", "adjustment", "effects", "fonts"]),
                    "name": Schema.string("For filter: a filter name from apply_filter. For adjustment: an adjustment kind from add_adjustment_layer."),
                    "query": Schema.string("For fonts: only families whose name contains this; their styles are listed too."),
                ], required: ["topic"]), readOnly: true) { [unowned self] arguments in
                    try describeSettings(arguments)
                },
        ]
    }

    private func canvasImage(_ arguments: AgentArguments) async throws -> AgentResult {
        let session = try tab(arguments).session
        let document = try canvas(session)
        let longSide = min(4096, max(64, try arguments.int("max_size") ?? 1024))
        let png = try arguments.string("format")?.lowercased() == "png"
        let background = try arguments.color("background") ?? .white
        var image: CGImage
        var described: JSONObject = [:]
        if let id = try arguments.uuid("layer_id") {
            let layer = try self.layer(id, in: session)
            if try arguments.bool("mask") == true {
                guard let mask = layer.mask?.asset.image else { throw AgentError("“\(layer.name)” has no mask.") }
                image = mask
            } else {
                guard let pixels = layer.asset?.image else { throw AgentError("“\(layer.name)” has no pixels of its own (it’s \(layerJSON(layer)["kind"] ?? "empty")).") }
                image = pixels
            }
            described["layer_id"] = id.uuidString
        } else {
            guard let snapshot = session.projectSnapshot() else { throw AgentError("Nothing to show yet.") }
            image = try await ImageExporter.shared.render(snapshot).image
            if let region = try arguments.rect() {
                let bounds = region.integral.intersection(CGRect(x: 0, y: 0, width: document.width, height: document.height))
                guard !bounds.isNull, bounds.width >= 1, bounds.height >= 1, let cropped = image.cropping(to: bounds) else {
                    throw AgentError("That region is outside the \(document.width) × \(document.height) canvas.")
                }
                image = cropped
                described["region"] = ["x": bounds.minX, "y": bounds.minY, "width": bounds.width, "height": bounds.height]
            }
        }
        let source = (width: image.width, height: image.height)
        var picture = try Self.scaled(image, longSide: longSide)
        let onCanvas = described["layer_id"] == nil
        let origin = CGPoint(x: (described["region"] as? JSONObject)?["x"] as? CGFloat ?? 0,
                             y: (described["region"] as? JSONObject)?["y"] as? CGFloat ?? 0)
        let showSelection = try arguments.bool("show_selection") == true
        let outlineIDs = try arguments.uuids("outline_layer_ids") ?? []
        guard onCanvas || (!showSelection && outlineIDs.isEmpty) else {
            throw AgentError("show_selection and outline_layer_ids mark the canvas; leave out layer_id.")
        }
        let outlines = try outlineIDs.compactMap { id -> (name: String, corners: [CGPoint])? in
            let layer = try self.layer(id, in: session)
            return contentPlacement(layer).map { (layer.name, $0.corners) }
        }
        var grid: CGFloat?
        if try arguments.bool("grid") == true || arguments.has("grid_spacing") {
            grid = CGFloat(try arguments.int("grid_spacing") ?? Int(Self.gridSpacing(for: CGFloat(max(source.width, source.height)))))
            described["grid_spacing"] = grid
        }
        let selection = showSelection ? session.selection.flatMap { $0.isEmpty ? nil : $0.path } : nil
        if grid != nil || selection != nil || !outlines.isEmpty {
            picture = try marked(picture, scale: CGFloat(picture.width) / CGFloat(max(1, source.width)), origin: origin,
                                 grid: grid, selection: selection, outlines: outlines)
        }
        let data = png ? try Self.encode(picture, as: .png) : try Self.encode(picture, as: .jpeg, background: background)
        described["image_width"] = picture.width
        described["image_height"] = picture.height
        described["scale"] = Double(picture.width) / Double(max(1, source.width))
        return AgentResult(value: described, images: [AgentImage(data: data, mimeType: png ? "image/png" : "image/jpeg")])
    }

    private func newDocument(_ arguments: AgentArguments) async throws -> AgentResult {
        let width = try arguments.requiredInt("width"), height = try arguments.requiredInt("height")
        guard (1...DocumentLimits.maxSide).contains(width), (1...DocumentLimits.maxSide).contains(height),
              width * height <= DocumentLimits.maxSurfacePixels else {
            throw AgentError("A canvas can be up to \(DocumentLimits.maxSide) pixels on a side and \(DocumentLimits.maxSurfaceMegapixels) megapixels.")
        }
        let resolution = try arguments.double("resolution")
        if let resolution, !(1...9600).contains(resolution) { throw AgentError("resolution must be between 1 and 9600.") }
        let fill = try arguments.color("fill")
        guard workspace.canSwitch else { throw AgentError("Compositor can’t open a tab right now: \(blocker(workspace.current.session) ?? "something on screen is still open").") }
        let tab = workspace.addTab()
        tab.session.createNewProject(width: width, height: height)
        guard tab.session.document != nil else { throw AgentError("Compositor couldn’t make the canvas. Try again.") }
        if let resolution { tab.session.document?.resolution = resolution }
        if let fill, let layer = tab.session.activeLayer {
            try await change(tab.session, String(localized: "Fill")) {
                let context = try Self.surface(width: width, height: height)
                context.setFillColor(CGColor(srgbRed: fill.red, green: fill.green, blue: fill.blue, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                guard let image = context.makeImage() else { throw ExportError.render }
                guard let index = tab.session.document?.layers.firstIndex(where: { $0.id == layer.id }) else { return }
                tab.session.document?.layers[index].asset = try Self.asset(image, name: layer.name)
            }
        }
        return AgentResult(value: documentJSON(tab))
    }

    private func openProject(_ arguments: AgentArguments) async throws -> AgentResult {
        let path = try arguments.requiredString("path")
        let url = try AgentFiles.url(path)
        guard url.pathExtension.lowercased() == "comp" else { throw AgentError("open_project opens Compositor projects (.comp). Use add_image_layer for pictures.") }
        do { _ = try await ProjectStore.shared.load(from: url) }
        catch { throw AgentFiles.shared.explain(error, path: url.path) }
        guard await workspace.open(url) else {
            throw AgentError("Compositor couldn’t open the project just now: \(blocker(workspace.current.session) ?? "another file operation is running").")
        }
        return AgentResult(value: documentJSON(workspace.current))
    }

    private func saveProject(_ arguments: AgentArguments) async throws -> AgentResult {
        let tab = try tab(arguments)
        _ = try canvas(tab.session)
        var destination: URL
        if let path = try arguments.string("path") {
            destination = try AgentFiles.url(path)
            if destination.pathExtension.lowercased() != "comp" { destination.appendPathExtension("comp") }
        } else if let existing = tab.session.projectURL {
            destination = existing
        } else {
            throw AgentError("This document has never been saved, so give a path ending in .comp, such as ~/Pictures/Poster.comp.")
        }
        try await ready(tab.session)
        do {
            guard try await tab.controller.save(to: destination) else {
                throw AgentError("Compositor couldn’t save just now: \(blocker(tab.session) ?? "another operation is running").")
            }
        } catch let error as AgentError { throw error }
        catch { throw AgentFiles.shared.explain(error, path: destination.path) }
        return AgentResult(value: ["saved": true, "path": destination.path])
    }

    private func exportImage(_ arguments: AgentArguments) async throws -> AgentResult {
        let session = try tab(arguments).session
        _ = try canvas(session)
        var url = try AgentFiles.url(try arguments.requiredString("path"))
        let ext = url.pathExtension.lowercased()
        let format = try arguments.string("format")?.lowercased() ?? (["jpg", "jpeg"].contains(ext) ? "jpeg" : "png")
        guard ["png", "jpeg", "jpg"].contains(format) else { throw AgentError("format must be png or jpeg.") }
        let jpeg = format != "png"
        if ext.isEmpty { url.appendPathExtension(jpeg ? "jpg" : "png") }
        let quality = min(1, max(0, try arguments.double("quality") ?? 0.9))
        let background = try arguments.color("background") ?? .white
        guard let snapshot = session.projectSnapshot() else { throw AgentError("Nothing to export yet.") }
        let bytes: Int
        do {
            if jpeg {
                let raster = try await ImageExporter.shared.render(snapshot)
                let result = try await ImageExporter.shared.jpeg(raster, options: JPEGOptions(quality: quality, red: background.red,
                                                                                               green: background.green, blue: background.blue))
                try await ImageExporter.shared.write(result.data, to: url)
                bytes = result.data.count
            } else {
                let data = try await ImageExporter.shared.pngData(snapshot)
                try await ImageExporter.shared.write(data, to: url)
                bytes = data.count
            }
        } catch { throw AgentFiles.shared.explain(error, path: url.path) }
        return AgentResult(value: ["exported": true, "path": url.path, "format": jpeg ? "jpeg" : "png", "bytes": bytes,
                                   "width": snapshot.manifest.width, "height": snapshot.manifest.height])
    }

    private func history(_ arguments: AgentArguments) async throws -> AgentResult {
        let session = try tab(arguments).session
        let undo = try arguments.requiredString("action") == "undo"
        let steps = min(100, max(1, try arguments.int("steps") ?? 1))
        try await ready(session)
        var names: [String] = []
        for _ in 0..<steps {
            if undo {
                guard session.canUndo else { break }
                names.append(session.history.undoName)
                session.undo()
            } else {
                guard session.canRedo else { break }
                names.append(session.history.redoName)
                session.redo()
            }
        }
        guard !names.isEmpty else { throw AgentError(undo ? "There’s nothing to undo." : "There’s nothing to redo.") }
        return AgentResult(value: [undo ? "undone" : "redone": names,
                                   "undo": session.history.canUndo ? session.history.undoName as Any : NSNull(),
                                   "redo": session.history.canRedo ? session.history.redoName as Any : NSNull()])
    }

    private func describeSettings(_ arguments: AgentArguments) throws -> AgentResult {
        switch try arguments.requiredString("topic") {
        case "filter":
            let name = try arguments.requiredString("name")
            switch AgentColor.simplified(name) {
            case "levels": return AgentResult(value: ["filter": "Levels", "settings": try AgentCoding.json(LevelsSettings()),
                "notes": "ranges run RGB, then red, green, blue. black, white, outputBlack and outputWhite are 0–255; gamma 0.1–9.99."])
            case "huesaturation": return AgentResult(value: ["filter": "Hue/Saturation", "settings": try AgentCoding.json(HueSaturationSettings()),
                "notes": "hue −180…180, saturation and lightness −100…100. Set colorize to tint the whole image."])
            case "invert": return AgentResult(value: ["filter": "Invert", "settings": [:]])
            default: break
            }
            guard let kind = Self.filterKind(name) else { throw AgentError("Unknown filter “\(name)”. Filters: \(Self.filterNames.joined(separator: ", ")).") }
            let all = try AgentCoding.json(FilterSettings()) as? JSONObject ?? [:]
            let keys = Self.settingsKeys(kind)
            return AgentResult(value: ["filter": kind.rawValue, "settings": all.filter { keys.contains($0.key) }])
        case "adjustment":
            let name = try arguments.requiredString("name")
            guard let kind = AdjustmentKind.allCases.first(where: { AgentColor.simplified($0.rawValue) == AgentColor.simplified(name) }) else {
                throw AgentError("Unknown adjustment “\(name)”. Kinds: \(AdjustmentKind.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            let all = try AgentCoding.json(Self.described(kind)) as? JSONObject ?? [:]
            let keys = Self.adjustmentKeys(kind)
            return AgentResult(value: ["adjustment": kind.rawValue, "settings": all.filter { keys.contains($0.key) },
                                       "notes": kind == .hsv ? "hue −180…180, saturation and lightness −100…100; colorize tints." : ""])
        case "effects":
            let all = LayerEffects(stroke: StrokeEffect(), shadow: ShadowEffect(), colorOverlay: ColorOverlayEffect(),
                                   innerShadow: InnerShadowEffect(), outerGlow: OuterGlowEffect(), innerGlow: InnerGlowEffect())
            return AgentResult(value: ["effects": try AgentCoding.json(all),
                "notes": "Pass any of these to update_layer’s effects; omit an effect to leave it as it is, or set it to null to remove it. Colors are red/green/blue from 0 to 1, or give \"color\": \"#RRGGBB\". Effects work on pixel, text and shape layers."])
        case "fonts":
            let query = try arguments.string("query")?.lowercased()
            let families = NSFontManager.shared.availableFontFamilies.filter { query.map($0.lowercased().contains) ?? true }
            guard let query, !query.isEmpty else { return AgentResult(value: ["families": families]) }
            return AgentResult(value: ["fonts": families.prefix(40).map { family -> JSONObject in
                let styles = (NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []).compactMap { member -> JSONObject? in
                    guard let name = member.first as? String else { return nil }
                    return ["font": name, "style": member.count > 1 ? member[1] : ""]
                }
                return ["family": family, "styles": styles]
            }, "notes": "Pass a style’s font name (such as Helvetica-Bold) or a family name to add_text_layer."])
        default:
            throw AgentError("topic must be filter, adjustment, effects or fonts.")
        }
    }
}
