import AppKit

extension AgentTools {
    var layerTools: [AgentTool] {
        let placement: [String: JSONObject] = [
            "parent_id": Schema.string("Put the layer in this folder; \"\" for the top level. Without above_id or below_id it goes to the top of the folder (or the bottom, with position)."),
            "above_id": Schema.string("Put the layer just above this one, in the same folder."),
            "below_id": Schema.string("Put the layer just below this one, in the same folder."),
            "position": Schema.string("With parent_id or alone: the top or the bottom of that folder or of the whole stack.", choices: ["top", "bottom"]),
            "clipped": Schema.boolean("Clip the layer to the one below it, so it shows only where that one does."),
        ]
        func creating(_ properties: [String: JSONObject]) -> [String: JSONObject] {
            properties.merging(placement) { a, _ in a }.merging(["document_id": Schema.documentID, "name": Schema.string("The layer’s name.")]) { a, _ in a }
        }
        let blendModes = LayerBlendMode.allCases.map(\.rawValue)
        let textProperties: [String: JSONObject] = [
            "text": Schema.string("The words; \\n starts a new line."),
            "font": Schema.string("A font name such as Helvetica-Bold, or a family such as Avenir Next. describe_settings with topic fonts lists them."),
            "size": Schema.number("Font size in pixels.", minimum: 1, maximum: 2000),
            "color": Schema.string("#RRGGBB."),
            "alignment": Schema.string("Default left.", choices: TextAlignment.allCases.map(\.rawValue)),
            "tracking": Schema.number("Letter spacing in thousandths of an em, as in Photoshop.", minimum: -100, maximum: 1000),
            "leading": Schema.number("Baseline to baseline in pixels; 0 is automatic (120% of the size).", minimum: 0, maximum: 5000),
            "box_width": Schema.number("Wrap the text in a box this wide (with box_height). null makes it point text again.", minimum: 16),
            "box_height": Schema.number("The text box’s height.", minimum: 16),
        ]
        return [
            AgentTool(name: "add_image_layer", title: "Add Image Layer",
                description: "Places a picture on a new layer above the selected one: from a file, an http(s) URL, or base64 data. Without a canvas, the picture makes one its own size. It lands at its own pixel size, centered, unless x, y, width or height say otherwise (giving only width or height keeps its proportions). Compositor is sandboxed: files must be under ~/Pictures, ~/Downloads, in a project’s folder, or in a folder added in Compositor > MCP Server…; url and data work from anywhere.",
                schema: Schema.object(creating([
                    "path": Schema.string("Absolute path of an image file (PNG, JPEG, HEIC, TIFF, WebP, SVG, …)."),
                    "url": Schema.string("An http or https address of an image to download."),
                    "data": Schema.string("The image file’s bytes as base64 (a data: URL works too)."),
                    "x": Schema.number("Left edge in document pixels."), "y": Schema.number("Top edge in document pixels."),
                    "width": Schema.number("Width to scale it to, in document pixels.", minimum: 1),
                    "height": Schema.number("Height to scale it to, in document pixels.", minimum: 1),
                ]))) { [unowned self] arguments in
                    try await addImageLayer(arguments)
                },
            AgentTool(name: "add_shape_layer", title: "Add Shape Layer",
                description: "Draws a rectangle, ellipse or line on a new shape layer, which stays sharp when resized and can be recolored with update_layer. Rectangles and ellipses fill x, y, width, height; a line runs from start to end.",
                schema: Schema.object(creating([
                    "kind": Schema.string("The shape.", choices: ShapeKind.allCases.map(\.rawValue)),
                    "color": Schema.string("#RRGGBB. Default the foreground color."),
                    "corner_radius": Schema.number("Rounded corners for rectangles, in pixels.", minimum: 0),
                    "line_width": Schema.number("A line’s thickness in pixels. Default 4.", minimum: 1, maximum: 2000),
                    "start": Schema.array("A line’s first end, [x, y].", items: ["type": "number"]),
                    "end": Schema.array("A line’s other end, [x, y].", items: ["type": "number"]),
                ].merging(Schema.rect("the shape")) { a, _ in a }), required: ["kind"])) { [unowned self] arguments in
                    try await addShapeLayer(arguments)
                },
            AgentTool(name: "add_gradient_layer", title: "Add Gradient Layer",
                description: "Fills a new layer the size of the canvas with a linear or radial gradient. Stack it with a blend mode or opacity, or mask it, for lighting and color washes.",
                schema: Schema.object(creating([
                    "type": Schema.string("Default linear.", choices: ["linear", "radial"]),
                    "colors": Schema.array("Two or more stops, first to last: \"#RRGGBB\" strings, or objects {color, position 0–1, opacity 0–1}. Default foreground to background color.", items: [:]),
                    "start": Schema.array("Where the gradient starts (a radial one’s center), [x, y]. Default the top middle (radial: the center).", items: ["type": "number"]),
                    "end": Schema.array("Where it ends (a radial one’s edge), [x, y]. Default the bottom middle (radial: a corner).", items: ["type": "number"]),
                ]))) { [unowned self] arguments in
                    try await addGradientLayer(arguments)
                },
            AgentTool(name: "add_text_layer", title: "Add Text Layer",
                description: "Sets text on a new text layer, which stays editable (update_layer’s text changes it). x and y are where the first line’s top-left starts; without them the text is centered on the canvas.",
                schema: Schema.object(creating(textProperties.merging([
                    "x": Schema.number("Left edge of the text, in document pixels."), "y": Schema.number("Top of the first line, in document pixels."),
                ]) { a, _ in a }), required: ["text"])) { [unowned self] arguments in
                    try await addTextLayer(arguments)
                },
            AgentTool(name: "add_adjustment_layer", title: "Add Adjustment Layer",
                description: "Adds an adjustment layer, which changes the look of everything below it (or, clipped, of the one layer below) without touching any pixels; edit it later with update_layer’s adjustment. describe_settings with topic adjustment shows each kind’s settings.",
                schema: Schema.object(creating([
                    "kind": Schema.string("The adjustment.", choices: AdjustmentKind.allCases.map(\.rawValue)),
                    "settings": Schema.anyObject("Settings to change from the defaults, as describe_settings shows them, such as {\"hue\": 30} or {\"exposureSettings\": {\"exposure\": 0.5}}."),
                ]), required: ["kind"])) { [unowned self] arguments in
                    try await addAdjustmentLayer(arguments)
                },
            AgentTool(name: "add_folder", title: "Add Folder",
                description: "Makes a folder (a layer group). With layer_ids, those layers are moved into it, as Group Layers does; otherwise it’s empty, above the selected layer.",
                schema: Schema.object(creating([
                    "layer_ids": Schema.array("Layers to put in the folder.", items: ["type": "string"]),
                ]))) { [unowned self] arguments in
                    try await addFolder(arguments)
                },
            AgentTool(name: "update_layer", title: "Update Layer",
                description: "Changes a layer: name, visibility, opacity, blend mode, placement, clipping, and the settings of an adjustment, effects, text or shape layer. Only what’s given changes, all in one undo step. Placement is in document pixels: x, y move the top-left corner; width and height scale (one alone keeps proportions); dx, dy move by an amount, and also move a folder’s contents.",
                schema: Schema.object([
                    "document_id": Schema.documentID, "layer_id": Schema.layerID,
                    "name": Schema.string("New name."),
                    "visible": Schema.boolean("Show or hide the layer."),
                    "opacity": Schema.number("0 (invisible) to 1 (opaque).", minimum: 0, maximum: 1),
                    "blend_mode": Schema.string("How the layer mixes with those below.", choices: blendModes),
                    "x": Schema.number("Left edge."), "y": Schema.number("Top edge."),
                    "width": Schema.number("Width.", minimum: 1), "height": Schema.number("Height.", minimum: 1),
                    "dx": Schema.number("Move right by this much (negative: left)."), "dy": Schema.number("Move down by this much (negative: up)."),
                    "rotation": Schema.number("Degrees clockwise around the layer’s center."),
                    "flip_horizontal": Schema.boolean("Mirrored left to right."), "flip_vertical": Schema.boolean("Mirrored top to bottom."),
                    "clipped": Schema.boolean("Clip to the layer below, or stop clipping."),
                    "adjustment": Schema.anyObject("For adjustment layers: settings to change, as describe_settings shows them."),
                    "effects": Schema.anyObject("Layer effects to add or change: stroke, shadow, colorOverlay, innerShadow, outerGlow, innerGlow, each an object of its settings (describe_settings, topic effects); null removes one."),
                    "text": Schema.object(textProperties, description: "For text layers: what to change."),
                    "shape": Schema.object([
                        "color": Schema.string("#RRGGBB."), "corner_radius": Schema.number("Rectangle corner radius.", minimum: 0),
                        "line_width": Schema.number("Line thickness.", minimum: 1, maximum: 2000),
                    ], description: "For shape layers: what to change."),
                ], required: ["layer_id"])) { [unowned self] arguments in
                    try await updateLayer(arguments)
                },
            AgentTool(name: "delete_layers", title: "Delete Layers",
                description: "Deletes layers (a folder takes everything in it).",
                schema: Schema.object(["document_id": Schema.documentID,
                                       "layer_ids": Schema.array("The layers to delete.", items: ["type": "string"])], required: ["layer_ids"]),
                destructive: true) { [unowned self] arguments in
                    try await deleteLayers(arguments)
                },
            AgentTool(name: "duplicate_layers", title: "Duplicate Layers",
                description: "Copies layers (a folder with everything in it); each copy goes just above its original. Returns the copies’ ids.",
                schema: Schema.object(["document_id": Schema.documentID,
                                       "layer_ids": Schema.array("The layers to copy.", items: ["type": "string"])], required: ["layer_ids"])) { [unowned self] arguments in
                    try await duplicateLayers(arguments)
                },
            AgentTool(name: "move_layer", title: "Move Layer in Stack",
                description: "Moves a layer up or down the Layers panel, or into or out of a folder. Give above_id, below_id, or parent_id with position.",
                schema: Schema.object(placement.filter { $0.key != "clipped" }.merging(["document_id": Schema.documentID, "layer_id": Schema.layerID]) { a, _ in a },
                                      required: ["layer_id"])) { [unowned self] arguments in
                    let session = try tab(arguments).session
                    _ = try await editable(session)
                    let id = try arguments.requiredUUID("layer_id")
                    _ = try layer(id, in: session)
                    let changed = try await change(session, String(localized: "Move Layer")) {
                        guard try arrange(id, arguments, in: session) else { throw AgentError("Say where: above_id, below_id, or parent_id with position.") }
                    }
                    return outcome(session, changed: changed, layerID: id)
                },
            AgentTool(name: "merge_layers", title: "Merge Layers",
                description: "Merges layers into one pixel layer, keeping how they look. One layer merges down into the one below it.",
                schema: Schema.object(["document_id": Schema.documentID,
                                       "layer_ids": Schema.array("The layers to merge.", items: ["type": "string"])], required: ["layer_ids"]),
                destructive: true) { [unowned self] arguments in
                    try await mergeLayers(arguments)
                },
            AgentTool(name: "ungroup_folder", title: "Ungroup Folder",
                description: "Takes a folder’s layers out of it, where it was, and removes the folder.",
                schema: Schema.object(["document_id": Schema.documentID, "layer_id": Schema.layerID], required: ["layer_id"])) { [unowned self] arguments in
                    let session = try tab(arguments).session
                    _ = try await editable(session)
                    let folder = try target(arguments, in: session)
                    guard folder.isGroup else { throw AgentError("“\(folder.name)” isn’t a folder.") }
                    let changed = try await change(session, String(localized: "Ungroup Layers")) { session.ungroupLayers() }
                    return outcome(session, changed: changed, extra: ["layer_ids": session.selectedLayerIDs.map(\.uuidString).sorted()])
                },
            AgentTool(name: "layer_mask", title: "Layer Mask",
                description: "Works on a layer’s mask, which hides parts of it without erasing them: white shows, black hides. reveal_all and hide_all add a plain mask; reveal_selection and hide_selection add one from the selection; the others change an existing mask. To paint on a mask, use fill or draw with target mask.",
                schema: Schema.object(["document_id": Schema.documentID, "layer_id": Schema.layerID,
                    "action": Schema.string("What to do.", choices: ["reveal_all", "hide_all", "reveal_selection", "hide_selection", "delete", "enable", "disable", "invert", "link", "unlink"]),
                ], required: ["layer_id", "action"])) { [unowned self] arguments in
                    try await layerMask(arguments)
                },
        ]
    }

    // MARK: Helpers

    /// The document, once the editor is free to change its layers.
    func editable(_ session: EditorSession) async throws -> CanvasDocument {
        let document = try canvas(session)
        try await ready(session)
        guard session.canEditLayers else {
            throw AgentError("Compositor can’t edit layers right now: \(blocker(session) ?? "something on screen is still open").")
        }
        return document
    }

    /// Puts a new layer above the selected one, in its folder, as the menus do, and selects it.
    func insertNew(_ layer: ImageLayer, in session: EditorSession) throws {
        guard let document = session.document else { return }
        guard document.layers.count < 10_000 else { throw AgentError("A document can have up to 10,000 layers.") }
        var layer = layer
        let active = session.activeLayer
        layer.parentID = active?.isGroup == true ? active?.id : active?.parentID
        let index = document.layers.firstIndex { $0.id == session.activeLayerID }.map { $0 + 1 } ?? document.layers.count
        session.document?.layers.insert(layer, at: index)
        if let parent = layer.parentID { session.collapsedGroupIDs.remove(parent) }
        session.activeLayerID = layer.id
    }

    /// Moves a layer where `parent_id`, `above_id`, `below_id` and `position` say; false when they say nothing.
    @discardableResult
    func arrange(_ id: UUID, _ arguments: AgentArguments, in session: EditorSession) throws -> Bool {
        let above = try arguments.uuid("above_id"), below = try arguments.uuid("below_id")
        let position = try arguments.string("position")
        let parentGiven = arguments.values["parent_id"] != nil
        var parent: UUID?
        if let text = arguments.values["parent_id"] as? String, !text.isEmpty { parent = try arguments.uuid("parent_id") }
        guard above != nil || below != nil || parentGiven || position != nil else { return false }
        if above == id || below == id { throw AgentError("A layer can’t go above or below itself.") }
        let layers = session.document?.layers ?? []
        let placed: Bool
        if let above {
            let target = try layer(above, in: session)
            placed = session.placeLayer(id, in: target.parentID, above: above)
        } else if let below {
            let target = try layer(below, in: session)
            let siblings = layers.filter { $0.parentID == target.parentID && $0.id != id }
            let index = siblings.firstIndex { $0.id == below } ?? 0
            placed = index > 0 ? session.placeLayer(id, in: target.parentID, above: siblings[index - 1].id)
                               : session.placeLayer(id, in: target.parentID, atBottom: true)
        } else {
            if let parent, try !layer(parent, in: session).isGroup { throw AgentError("parent_id must be a folder.") }
            if position == "bottom" {
                placed = session.placeLayer(id, in: parent, atBottom: true)
            } else {
                let siblings = layers.filter { $0.parentID == parent && $0.id != id }
                placed = siblings.last.map { session.placeLayer(id, in: parent, above: $0.id) } ?? session.placeLayer(id, in: parent)
            }
        }
        guard placed else { throw AgentError("The layer can’t go there (a folder can’t go inside itself).") }
        return true
    }

    /// Makes a layer with `make`, puts it in place, and reports it, as one undo step.
    private func create(_ arguments: AgentArguments, _ name: String, in session: EditorSession,
                        _ make: (CanvasDocument) throws -> ImageLayer?) async throws -> AgentResult {
        let document = try await editable(session)
        var id: UUID?
        let changed = try await change(session, name) {
            if let layer = try make(document) { try insertNew(layer, in: session) }
            id = session.activeLayerID
            guard let id else { return }
            try arrange(id, arguments, in: session)
            if try arguments.bool("clipped") == true { session.toggleClippingMask(id) }
            if let name = try arguments.string("name")?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
               let index = session.document?.layers.firstIndex(where: { $0.id == id }) {
                session.document?.layers[index].name = name
            }
        }
        return outcome(session, changed: changed, layerID: id)
    }

    private func imageFile(_ arguments: AgentArguments) async throws -> URL {
        if let path = try arguments.string("path") { return try AgentFiles.url(path) }
        let data: Data
        var suggested = ""
        if let link = try arguments.string("url") {
            guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                throw AgentError("url must be an http or https address.")
            }
            let (body, response) = try await URLSession.shared.data(from: url)
            if let response = response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
                throw AgentError("Downloading \(link) failed with HTTP status \(response.statusCode).")
            }
            data = body
            suggested = url.pathExtension
        } else if let text = try arguments.string("data") {
            let base64 = text.range(of: "base64,").map { String(text[$0.upperBound...]) } ?? text
            guard let decoded = Data(base64Encoded: base64, options: .ignoreUnknownCharacters), !decoded.isEmpty else {
                throw AgentError("data isn’t valid base64.")
            }
            data = decoded
        } else {
            throw AgentError("Give the picture as path, url or data.")
        }
        guard data.count <= 500_000_000 else { throw AgentError("That file is too large.") }
        guard let type = AgentFiles.imageExtension(of: data) ?? (suggested.isEmpty ? nil : suggested) else {
            throw AgentError("That doesn’t look like an image file.")
        }
        return try AgentFiles.temporaryFile(data, extension: type)
    }

    static func fontName(_ name: String) throws -> String {
        if NSFont(name: name, size: 12) != nil { return name }
        let manager = NSFontManager.shared
        if let family = manager.availableFontFamilies.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }),
           let font = manager.font(withFamily: family, traits: [], weight: 5, size: 12) {
            return font.fontName
        }
        throw AgentError("No installed font is called “\(name)”. describe_settings with topic fonts lists them.")
    }

    private func textStyle(_ arguments: AgentArguments, base: LayerTextStyle) throws -> LayerTextStyle {
        var style = base
        if let text = try arguments.string("text") {
            style.content = text
            style.colorRuns = nil
            style.fontRuns = nil
        }
        if let font = try arguments.string("font") { style.fontName = try Self.fontName(font); style.fontRuns = nil }
        if let size = try arguments.double("size") { style.fontSize = size }
        if let color = try arguments.color("color") {
            style.red = color.red; style.green = color.green; style.blue = color.blue
            style.colorRuns = nil
        }
        if let alignment = try arguments.choice("alignment", TextAlignment.self) { style.alignment = alignment }
        if let tracking = try arguments.double("tracking") { style.tracking = tracking }
        if let leading = try arguments.double("leading") { style.leading = leading }
        if arguments.values["box_width"] is NSNull {
            style.boxSize = nil
        } else if let width = try arguments.double("box_width") {
            let height = try arguments.double("box_height") ?? style.boxSize?.height ?? max(16, style.lineHeight * 4 + LayerTextStyle.padding * 2)
            style.boxSize = CGSize(width: width.rounded(), height: height.rounded())
        } else if let height = try arguments.double("box_height"), let box = style.boxSize {
            style.boxSize = CGSize(width: box.width, height: height.rounded())
        }
        guard style.isValid else {
            throw AgentError("Those text settings are out of range: size 1–2000, tracking −100–1000, leading 0–5000, a box at least 16 pixels.")
        }
        return style
    }

    // MARK: Making layers

    private func addImageLayer(_ arguments: AgentArguments) async throws -> AgentResult {
        let session = try tab(arguments).session
        let url = try await imageFile(arguments)
        let used = session.document?.layers.reduce(0) { $0 + ($1.asset.map { $0.image.width * $0.image.height } ?? 0) } ?? 0
        let remaining = DocumentLimits.documentPixelBudget - used
        let asset: ImportedImage
        do {
            if url.pathExtension.lowercased() == "svg" {
                asset = try await ImageImporter.shared.decodeSVG(url, fitting: session.document?.size, remainingPixels: remaining)
            } else {
                asset = try await ImageImporter.shared.decode(url, remainingPixels: remaining)
            }
        } catch { throw AgentFiles.shared.explain(error, path: url.path) }
        let name = url.path.hasPrefix(FileManager.default.temporaryDirectory.path) ? String(localized: "Image") : url.deletingPathExtension().lastPathComponent
        let image = ImportedImage(image: asset.image, thumbnail: asset.thumbnail, name: name)
        guard session.document != nil else {
            try await ready(session)
            guard !session.isImporting, !session.isProjectBusy else { throw AgentError("Compositor is busy. Try again.") }
            let changed = try await change(session, String(localized: "Import Image")) { session.insert(image) }
            if let tab = workspace.tabs.first(where: { $0.session === session }) { workspace.select(tab.id) }
            return outcome(session, changed: changed, layerID: session.activeLayerID)
        }
        return try await create(arguments, String(localized: "Import Image"), in: session) { document in
            var layer = ImageLayer(asset: image, origin: .zero)
            var size = layer.transform.size
            let width = try arguments.double("width"), height = try arguments.double("height")
            if let width, let height { size = CGSize(width: width, height: height) }
            else if let width { size = CGSize(width: width, height: size.height * width / size.width) }
            else if let height { size = CGSize(width: size.width * height / size.height, height: height) }
            let x = try arguments.double("x") ?? ((CGFloat(document.width) - size.width) / 2).rounded(.down)
            let y = try arguments.double("y") ?? ((CGFloat(document.height) - size.height) / 2).rounded(.down)
            layer.transform = LayerTransform(origin: CGPoint(x: x, y: y), size: size)
            guard layer.transform.isValid else { throw AgentError("That placement is out of range.") }
            return layer
        }
    }

    private func addShapeLayer(_ arguments: AgentArguments) async throws -> AgentResult {
        let session = try tab(arguments).session
        guard let kind = try arguments.choice("kind", ShapeKind.self) else { throw AgentError("“kind” is required.") }
        let color = try arguments.color("color") ?? session.foregroundColor
        return try await create(arguments, kind.localizedName, in: session) { _ in
            var rect: CGRect
            var start: CGPoint?, end: CGPoint?
            var radius = CGFloat(try arguments.double("corner_radius") ?? 0)
            let thickness = CGFloat(try arguments.double("line_width") ?? 4)
            if kind == .line {
                guard let first = arguments.values["start"], let last = arguments.values["end"] else { throw AgentError("A line needs start and end.") }
                let from = try AgentArguments.point(first, key: "start"), to = try AgentArguments.point(last, key: "end")
                rect = CGRect(x: min(from.x, to.x), y: min(from.y, to.y), width: abs(to.x - from.x), height: abs(to.y - from.y))
                    .insetBy(dx: -thickness / 2, dy: -thickness / 2)
                func unit(_ point: CGPoint) -> CGPoint {
                    CGPoint(x: rect.width > 0 ? (point.x - rect.minX) / rect.width : 0.5, y: rect.height > 0 ? (point.y - rect.minY) / rect.height : 0.5)
                }
                start = unit(from); end = unit(to)
                radius = 0
            } else {
                guard let box = try arguments.rect() else { throw AgentError("Give the shape’s x, y, width and height.") }
                rect = box
                if kind == .ellipse { radius = 0 }
            }
            rect = CGRect(x: rect.minX.rounded(), y: rect.minY.rounded(), width: max(1, rect.width.rounded()), height: max(1, rect.height.rounded()))
            guard Int(rect.width) * Int(rect.height) <= EditorSession.maxShapePixels else {
                throw AgentError("That shape is too large; a shape can cover up to \(DocumentLimits.maxSurfaceMegapixels) megapixels.")
            }
            let image = try EditorSession.shapeImage(kind, size: rect.size, color: color, cornerRadius: radius,
                                                     lineWidth: thickness, start: start, end: end)
            let style = LayerShapeStyle(kind: kind, red: color.red, green: color.green, blue: color.blue, cornerRadius: radius,
                                        lineWidth: kind == .line ? thickness : nil, start: start, end: end)
            let name = session.nextShapeName(kind)
            var layer = ImageLayer(asset: try Self.asset(image, name: name), origin: rect.origin)
            layer.name = name
            layer.shape = LayerShape(style: style, image: image)
            return layer
        }
    }

    private func addGradientLayer(_ arguments: AgentArguments) async throws -> AgentResult {
        let session = try tab(arguments).session
        let radial = try arguments.string("type")?.lowercased() == "radial"
        var stops: [(color: PaletteColor, position: CGFloat?, opacity: CGFloat)] = []
        for item in try arguments.array("colors") ?? [] {
            if let text = item as? String {
                guard let color = AgentColor.parse(text) else { throw AgentError("“\(text)” isn’t a color.") }
                stops.append((color, nil, 1))
            } else if let object = item as? JSONObject {
                let stop = AgentArguments(object)
                guard let color = try stop.color("color") else { throw AgentError("Each gradient stop needs a color.") }
                stops.append((color, try stop.double("position").map { CGFloat(min(1, max(0, $0))) },
                              CGFloat(min(1, max(0, try stop.double("opacity") ?? 1)))))
            } else {
                throw AgentError("colors must list \"#RRGGBB\" strings or {color, position, opacity} objects.")
            }
        }
        if stops.isEmpty { stops = [(session.foregroundColor, 0, 1), (session.backgroundColor, 1, 1)] }
        guard stops.count >= 2 else { throw AgentError("A gradient needs at least two colors.") }
        let startValue = arguments.values["start"], endValue = arguments.values["end"]
        return try await create(arguments, String(localized: "Gradient"), in: session) { document in
            let width = document.width, height = document.height
            let start = try startValue.map { try AgentArguments.point($0, key: "start") }
                ?? (radial ? CGPoint(x: CGFloat(width) / 2, y: CGFloat(height) / 2) : CGPoint(x: CGFloat(width) / 2, y: 0))
            let end = try endValue.map { try AgentArguments.point($0, key: "end") }
                ?? (radial ? CGPoint(x: 0, y: 0) : CGPoint(x: CGFloat(width) / 2, y: CGFloat(height)))
            let context = try Self.surface(width: width, height: height)
            let colors = stops.map { CGColor(srgbRed: $0.color.red, green: $0.color.green, blue: $0.color.blue, alpha: $0.opacity) }
            let locations = stops.enumerated().map { $0.element.position ?? CGFloat($0.offset) / CGFloat(stops.count - 1) }
            guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)
            else { throw ExportError.render }
            let options: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            if radial {
                context.drawRadialGradient(gradient, startCenter: start, startRadius: 0, endCenter: start,
                                           endRadius: max(1, hypot(end.x - start.x, end.y - start.y)), options: options)
            } else {
                context.drawLinearGradient(gradient, start: start, end: end, options: options)
            }
            guard let image = context.makeImage() else { throw ExportError.render }
            var layer = ImageLayer(asset: try Self.asset(image, name: String(localized: "Gradient")), origin: .zero)
            layer.name = String(localized: "Gradient")
            return layer
        }
    }

    private func addTextLayer(_ arguments: AgentArguments) async throws -> AgentResult {
        let session = try tab(arguments).session
        var base = session.textDefaults
        base.colorRuns = nil; base.fontRuns = nil; base.boxSize = nil
        base.red = session.foregroundColor.red; base.green = session.foregroundColor.green; base.blue = session.foregroundColor.blue
        let style = try textStyle(arguments, base: base)
        guard !style.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AgentError("“text” is required.") }
        let defaults = session.textDefaults
        defer { session.textDefaults = defaults }
        return try await create(arguments, String(localized: "New Text Layer"), in: session) { document in
            let image = try EditorSession.textImage(style)
            let x = try arguments.double("x").map { CGFloat($0) - LayerTextStyle.padding } ?? ((CGFloat(document.width) - CGFloat(image.width)) / 2).rounded()
            let y = try arguments.double("y").map { CGFloat($0) - LayerTextStyle.padding } ?? ((CGFloat(document.height) - CGFloat(image.height)) / 2).rounded()
            let draft = TextDraft(documentID: document.id, layerID: nil, origin: CGPoint(x: x, y: y), style: style)
            guard session.applyText(draft) else { throw AgentError(session.brushError ?? "Compositor couldn’t set that text.") }
            return nil
        }
    }

    private func addAdjustmentLayer(_ arguments: AgentArguments) async throws -> AgentResult {
        let session = try tab(arguments).session
        guard let kind = try arguments.choice("kind", AdjustmentKind.self) else { throw AgentError("“kind” is required.") }
        var adjustment = LayerAdjustment(kind: kind)
        if kind == .gradientMap {
            adjustment.gradientMap = GradientMapSettings(shadows: AdjustmentColor(session.foregroundColor), highlights: AdjustmentColor(session.backgroundColor))
        }
        if kind == .grain { adjustment.grain.seed = .random(in: .min ... .max) }
        if kind == .addNoise { adjustment.resolvedNoiseSeed = .random(in: .min ... .max) }
        let patch = try arguments.object("settings")
        adjustment = try AgentCoding.merged(Self.prepared(adjustment, for: patch), with: patch, name: "adjustment settings")
        guard adjustment.isValid else { throw AgentError("Some of those settings are out of range. describe_settings shows the defaults.") }
        return try await create(arguments, String(localized: "New \(kind.localizedName) Adjustment"), in: session) { document in
            var layer = ImageLayer(name: kind.localizedName, blankSize: document.size)
            layer.adjustment = adjustment
            return layer
        }
    }

    private func addFolder(_ arguments: AgentArguments) async throws -> AgentResult {
        let session = try tab(arguments).session
        if let ids = try arguments.uuids("layer_ids"), !ids.isEmpty {
            for id in ids { _ = try layer(id, in: session) }
            _ = try await editable(session)
            session.selectLayers(Set(ids), primary: ids[0])
            guard session.selectedLayerIDs == Set(ids) else { throw AgentError("Compositor couldn’t select those layers just now.") }
            return try await create(arguments, String(localized: "Group Layers"), in: session) { _ in
                session.groupSelectedLayers()
                guard session.activeLayer?.isGroup == true else { throw AgentError("Those layers can’t be grouped together.") }
                return nil
            }
        }
        return try await create(arguments, String(localized: "New Folder"), in: session) { document in
            let names = Set(document.layers.map(\.name))
            var number = 1
            while names.contains(String(localized: "Folder \(number)")) { number += 1 }
            var folder = ImageLayer(name: String(localized: "Folder \(number)"), blankSize: document.size)
            folder.isGroup = true
            return folder
        }
    }

    // MARK: Changing layers

    private func updateLayer(_ arguments: AgentArguments) async throws -> AgentResult {
        let session = try tab(arguments).session
        _ = try await editable(session)
        let id = try arguments.requiredUUID("layer_id")
        let original = try layer(id, in: session)
        func index() throws -> Int {
            guard let index = session.document?.layers.firstIndex(where: { $0.id == id }) else { throw AgentError("The layer went away.") }
            return index
        }
        let changed = try await change(session, String(localized: "Edit Layer")) {
            if let patch = try arguments.object("text") {
                guard let text = original.liveText else { throw AgentError("“\(original.name)” isn’t a text layer (any more).") }
                let style = try textStyle(AgentArguments(patch), base: text.style)
                let draft = TextDraft(documentID: session.document?.id ?? UUID(), layerID: id, origin: original.origin,
                                      transform: original.transform, style: style)
                let defaults = session.textDefaults
                defer { session.textDefaults = defaults }
                guard session.applyText(draft) else { throw AgentError(session.brushError ?? "Compositor couldn’t change that text.") }
            }
            if let patch = try arguments.object("shape") {
                guard let shape = original.liveShape, let asset = original.asset else { throw AgentError("“\(original.name)” isn’t a shape layer (any more).") }
                let changes = AgentArguments(patch)
                var style = shape.style
                if let color = try changes.color("color") { style.red = color.red; style.green = color.green; style.blue = color.blue }
                if let radius = try changes.double("corner_radius"), style.kind == .rectangle { style.cornerRadius = max(0, radius) }
                if let width = try changes.double("line_width"), style.kind == .line { style.lineWidth = min(2000, max(1, width)) }
                let image = try EditorSession.shapeImage(style.kind, size: CGSize(width: asset.image.width, height: asset.image.height),
                                                         color: style.color, cornerRadius: style.cornerRadius,
                                                         lineWidth: style.lineWidth ?? 0, start: style.start, end: style.end)
                let i = try index()
                session.document?.layers[i].asset = try Self.asset(image, name: asset.name)
                session.document?.layers[i].shape = LayerShape(style: style, image: image)
            }
            var layer = try self.layer(id, in: session)
            let i = try index()
            if let name = try arguments.string("name")?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { layer.name = name }
            if let visible = try arguments.bool("visible") { layer.isVisible = visible }
            if let opacity = try arguments.double("opacity") {
                guard (0...1).contains(opacity) else { throw AgentError("opacity runs from 0 to 1.") }
                layer.opacity = opacity
            }
            if let mode = try arguments.choice("blend_mode", LayerBlendMode.self) {
                guard !layer.isGroup else { throw AgentError("Folders don’t have a blend mode; set it on the layers inside.") }
                layer.blendMode = mode
            }
            var transform = layer.transform
            let width = try arguments.double("width"), height = try arguments.double("height")
            if width != nil || height != nil || arguments.has("x") || arguments.has("y") || arguments.has("rotation")
                || arguments.has("flip_horizontal") || arguments.has("flip_vertical") {
                guard !layer.isGroup else { throw AgentError("A folder has no placement of its own; use dx and dy to move everything in it.") }
                if let width, let height { transform.size = CGSize(width: width, height: height) }
                else if let width { transform.size = CGSize(width: width, height: transform.size.height * width / transform.size.width) }
                else if let height { transform.size = CGSize(width: transform.size.width * height / transform.size.height, height: height) }
                if let x = try arguments.double("x") { transform.origin.x = x }
                if let y = try arguments.double("y") { transform.origin.y = y }
                if let rotation = try arguments.double("rotation") { transform.rotation = rotation }
                if let flip = try arguments.bool("flip_horizontal") { transform.flipX = flip }
                if let flip = try arguments.bool("flip_vertical") { transform.flipY = flip }
            }
            let dx = CGFloat(try arguments.double("dx") ?? 0), dy = CGFloat(try arguments.double("dy") ?? 0)
            transform.origin.x += dx; transform.origin.y += dy
            guard transform.isValid else { throw AgentError("That placement is out of range.") }
            let resized = transform.size != layer.transform.size
            if transform != layer.transform, let mask = layer.mask, mask.isLinked, var placement = mask.placement {
                placement.origin.x += transform.origin.x - layer.transform.origin.x
                placement.origin.y += transform.origin.y - layer.transform.origin.y
                layer.mask?.placement = placement
            }
            layer.transform = transform
            if let patch = try arguments.object("adjustment") {
                guard let adjustment = layer.adjustment else { throw AgentError("“\(layer.name)” isn’t an adjustment layer.") }
                let value = try AgentCoding.merged(Self.prepared(adjustment, for: patch), with: patch, name: "adjustment settings")
                guard value.isValid else { throw AgentError("Some of those settings are out of range. describe_settings shows the defaults.") }
                layer.adjustment = value
            }
            session.document?.layers[i] = layer
            if resized { session.redrawShape(at: i) }
            if dx != 0 || dy != 0, layer.isGroup {
                for child in session.descendantIDs(of: id) {
                    guard let c = session.document?.layers.firstIndex(where: { $0.id == child }) else { continue }
                    session.document?.layers[c].transform.origin.x += dx
                    session.document?.layers[c].transform.origin.y += dy
                    if let mask = session.document?.layers[c].mask, mask.isLinked, var placement = mask.placement {
                        placement.origin.x += dx; placement.origin.y += dy
                        session.document?.layers[c].mask?.placement = placement
                    }
                }
            }
            if let patch = try arguments.object("effects") {
                guard !layer.isGroup, layer.asset != nil else { throw AgentError("Effects go on pixel, text and shape layers.") }
                let value = try AgentCoding.merged(Self.prepared(layer.effects ?? LayerEffects(), for: patch), with: patch, name: "effects")
                guard value.isValid else { throw AgentError("Some of those effect settings are out of range. describe_settings with topic effects shows them.") }
                session.setEffects(value, on: id)
            }
            if let clipped = try arguments.bool("clipped"), clipped != (layer.maskSourceID != nil) {
                session.toggleClippingMask(id)
                guard (try self.layer(id, in: session).maskSourceID != nil) == clipped else {
                    throw AgentError("“\(layer.name)” can’t be clipped: it needs a layer below it in the same folder.")
                }
            }
        }
        return outcome(session, changed: changed, layerID: id)
    }

    private func deleteLayers(_ arguments: AgentArguments) async throws -> AgentResult {
        let session = try tab(arguments).session
        _ = try await editable(session)
        guard let ids = try arguments.uuids("layer_ids"), !ids.isEmpty else { throw AgentError("“layer_ids” is required.") }
        for id in ids { _ = try layer(id, in: session) }
        let changed = try await change(session, String(localized: "Delete Layer")) {
            if ids.count == 1 {
                session.deleteLayer(ids[0])
            } else {
                session.selectLayers(Set(ids), primary: ids[0])
                session.deleteSelectedLayers()
            }
        }
        let left = ids.filter { id in session.document?.layers.contains { $0.id == id } == true }
        if !left.isEmpty, !changed {
            throw AgentError(blocker(session).map { "Compositor didn’t delete them: \($0)." }
                ?? "Compositor is asking the person what to do with layers that depend on these; they can answer on screen.")
        }
        return outcome(session, changed: changed, extra: ["deleted": ids.count - left.count])
    }

    private func duplicateLayers(_ arguments: AgentArguments) async throws -> AgentResult {
        let session = try tab(arguments).session
        _ = try await editable(session)
        guard let ids = try arguments.uuids("layer_ids"), !ids.isEmpty else { throw AgentError("“layer_ids” is required.") }
        for id in ids { _ = try layer(id, in: session) }
        let changed = try await change(session, String(localized: "Duplicate Layer")) { session.duplicateLayers(ids) }
        let copies = session.document?.layers.filter { session.selectedLayerIDs.contains($0.id) }.map(\.id.uuidString) ?? []
        return outcome(session, changed: changed, extra: ["copy_ids": copies])
    }

    private func mergeLayers(_ arguments: AgentArguments) async throws -> AgentResult {
        let session = try tab(arguments).session
        _ = try await editable(session)
        guard let ids = try arguments.uuids("layer_ids"), !ids.isEmpty else { throw AgentError("“layer_ids” is required.") }
        for id in ids { _ = try layer(id, in: session) }
        session.selectLayers(Set(ids), primary: ids.count == 1 ? ids[0] : ids.last)
        guard session.selectedLayerIDs == Set(ids) else { throw AgentError("Compositor couldn’t select those layers just now.") }
        let changed = try await change(session, String(localized: "Merge Layers")) { session.mergeLayers() }
        guard changed else { throw AgentError("Those layers can’t be merged (there may be nothing below to merge into, or nothing visible).") }
        return outcome(session, changed: changed, layerID: session.activeLayerID)
    }

    private func layerMask(_ arguments: AgentArguments) async throws -> AgentResult {
        let session = try tab(arguments).session
        _ = try await editable(session)
        let layer = try target(arguments, in: session)
        let action = try arguments.requiredString("action")
        let adds = ["reveal_all", "hide_all", "reveal_selection", "hide_selection"].contains(action)
        if adds, layer.mask != nil { throw AgentError("“\(layer.name)” already has a mask; delete it first, or fill it.") }
        if !adds, layer.mask == nil { throw AgentError("“\(layer.name)” has no mask.") }
        if action.hasSuffix("_selection"), session.selection == nil { throw AgentError("There’s no selection; make one with select first.") }
        let changed = try await change(session, String(localized: "Layer Mask")) {
            switch action {
            case "reveal_all", "hide_all": session.addLayerMask(revealing: action == "reveal_all")
            case "reveal_selection", "hide_selection": session.addMask(revealing: action == "reveal_selection")
            case "delete": session.deleteLayerMask()
            case "enable", "disable":
                if layer.mask?.isEnabled != (action == "enable") { session.toggleLayerMask() }
            case "link", "unlink":
                if layer.mask?.isLinked != (action == "link") { session.toggleMaskLink(layer.id) }
            case "invert":
                session.isMaskSelected = true
                let selection = session.document?.selection
                session.document?.selection = nil
                await session.invertPixels()
                session.document?.selection = selection
            default: throw AgentError("Unknown action “\(action)”.")
            }
        }
        session.isMaskSelected = false
        return outcome(session, changed: changed, layerID: layer.id)
    }

    // MARK: Settings

    /// Optional settings the patch names, filled with their defaults so the patch has something to change.
    static func prepared(_ adjustment: LayerAdjustment, for patch: JSONObject?) -> LayerAdjustment {
        var result = adjustment
        let keys = Set(patch?.keys.map { $0 } ?? [])
        if keys.contains("exposureSettings") { result.exposure = result.exposure }
        if keys.contains("gradientMapSettings") { result.gradientMap = result.gradientMap }
        if keys.contains("grainSettings") { result.grain = result.grain }
        if keys.contains("blackWhiteSettings") { result.blackWhite = result.blackWhite }
        if keys.contains("colorBalanceSettings") { result.colorBalance = result.colorBalance }
        if keys.contains("hsvSettings") { result.hsvSettings = result.resolvedHSV }
        else if !keys.isDisjoint(with: ["hue", "saturation", "lightness", "colorize"]) { result.hsvSettings = nil }
        return result
    }

    static func prepared(_ effects: LayerEffects, for patch: JSONObject?) -> LayerEffects {
        var result = effects
        let named = Set((patch ?? [:]).filter { $0.value is JSONObject }.keys)
        if named.contains("stroke"), result.stroke == nil { result.stroke = StrokeEffect() }
        if named.contains("shadow"), result.shadow == nil { result.shadow = ShadowEffect() }
        if named.contains("colorOverlay"), result.colorOverlay == nil { result.colorOverlay = ColorOverlayEffect() }
        if named.contains("innerShadow"), result.innerShadow == nil { result.innerShadow = InnerShadowEffect() }
        if named.contains("outerGlow"), result.outerGlow == nil { result.outerGlow = OuterGlowEffect() }
        if named.contains("innerGlow"), result.innerGlow == nil { result.innerGlow = InnerGlowEffect() }
        return result
    }

    /// An adjustment with every setting its kind reads filled in, for describe_settings.
    static func described(_ kind: AdjustmentKind) -> LayerAdjustment {
        var adjustment = LayerAdjustment(kind: kind)
        switch kind {
        case .exposure: adjustment.exposure = adjustment.exposure
        case .gradientMap: adjustment.gradientMap = adjustment.gradientMap
        case .grain: adjustment.grain = adjustment.grain
        case .blackWhite: adjustment.blackWhite = adjustment.blackWhite
        case .colorBalance: adjustment.colorBalance = adjustment.colorBalance
        case .gaussianBlur: adjustment.gaussianRadius = adjustment.gaussianRadius
        case .motionBlur:
            adjustment.resolvedMotionAngle = adjustment.resolvedMotionAngle
            adjustment.resolvedMotionDistance = adjustment.resolvedMotionDistance
        case .addNoise:
            adjustment.resolvedNoiseAmount = adjustment.resolvedNoiseAmount
            adjustment.resolvedNoiseGaussian = adjustment.resolvedNoiseGaussian
            adjustment.resolvedNoiseMonochromatic = adjustment.resolvedNoiseMonochromatic
        case .hsv, .levels, .curves, .invert: break
        }
        return adjustment
    }

    static func adjustmentKeys(_ kind: AdjustmentKind) -> [String] {
        switch kind {
        case .hsv: ["hue", "saturation", "lightness", "colorize"]
        case .levels: ["levels"]
        case .curves: ["curves"]
        case .exposure: ["exposureSettings"]
        case .gradientMap: ["gradientMapSettings"]
        case .grain: ["grainSettings"]
        case .blackWhite: ["blackWhiteSettings"]
        case .colorBalance: ["colorBalanceSettings"]
        case .gaussianBlur: ["blurRadius"]
        case .motionBlur: ["motionAngle", "motionDistance"]
        case .addNoise: ["noiseAmount", "noiseGaussian", "noiseMonochromatic"]
        case .invert: []
        }
    }
}
