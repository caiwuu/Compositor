import AppKit

extension AgentTools {
    var selectionTools: [AgentTool] {
        [
            AgentTool(name: "select", title: "Select",
                description: "Makes or changes the selection, which limits fill, draw, clear_pixels and apply_filter to part of a layer and is what layer_mask’s *_selection actions and Content-Aware Fill use. rectangle, ellipse and polygon draw an outline (combined by mode); layer selects a layer’s opaque pixels; mask selects from a layer’s mask; expand, contract and feather change the current selection by amount pixels.",
                schema: Schema.object([
                    "document_id": Schema.documentID,
                    "action": Schema.string("What to do.", choices: ["all", "none", "invert", "rectangle", "ellipse", "polygon", "layer", "mask", "expand", "contract", "feather"]),
                    "mode": Schema.selectionMode,
                    "points": Schema.points,
                    "layer_id": Schema.string("For layer and mask: which layer."),
                    "amount": Schema.integer("For expand, contract and feather: pixels.", minimum: 1, maximum: 500),
                    "feather": Schema.number("For rectangle, ellipse and polygon: soften the new edge by this many pixels.", minimum: 0, maximum: 500),
                ].merging(Schema.rect("the outline")) { a, _ in a }, required: ["action"])) { [unowned self] arguments in
                    try await select(arguments)
                },
            AgentTool(name: "smart_select", title: "Smart Select",
                description: "Selects by what’s in the picture: subject finds the main subject (people, animals, objects) with machine learning; object selects the thing at x, y; wand selects pixels similar in color to the one at x, y. object and wand read the visible canvas unless sample_all_layers is false, in which case they read layer_id (or the selected layer).",
                schema: Schema.object([
                    "document_id": Schema.documentID,
                    "method": Schema.string("How to select.", choices: ["subject", "object", "wand"]),
                    "mode": Schema.selectionMode,
                    "x": Schema.number("For object and wand: the point, in document pixels."), "y": Schema.number("The point’s y."),
                    "tolerance": Schema.integer("Wand: how different (0–255) a color may be and still be selected. Default 32.", minimum: 0, maximum: 255),
                    "contiguous": Schema.boolean("Wand: only pixels connected to the point. Default true."),
                    "sample_all_layers": Schema.boolean("Read the whole visible canvas rather than one layer. Default true."),
                    "layer_id": Schema.string("The layer to read when sample_all_layers is false."),
                ], required: ["method"])) { [unowned self] arguments in
                    try await smartSelect(arguments)
                },
        ]
    }

    var canvasTools: [AgentTool] {
        let anchors = ["top_left", "top", "top_right", "left", "center", "right", "bottom_left", "bottom", "bottom_right"]
        return [
            AgentTool(name: "resize_canvas", title: "Canvas Size",
                description: "Changes the canvas size without scaling the layers: the canvas grows or shrinks around the anchor. New area is transparent unless fill is given.",
                schema: Schema.object([
                    "document_id": Schema.documentID,
                    "width": Schema.integer("New width in pixels.", minimum: 1, maximum: DocumentLimits.maxSide),
                    "height": Schema.integer("New height in pixels.", minimum: 1, maximum: DocumentLimits.maxSide),
                    "anchor": Schema.string("What stays put. Default center.", choices: anchors),
                    "fill": Schema.string("Color for new area on the bottom layer, #RRGGBB."),
                ], required: ["width", "height"])) { [unowned self] arguments in
                    let width = try arguments.requiredInt("width"), height = try arguments.requiredInt("height")
                    let anchor = try arguments.string("anchor").map { name -> Int in
                        guard let index = anchors.firstIndex(of: name) else { throw AgentError("anchor must be one of \(anchors.joined(separator: ", ")).") }
                        return index
                    } ?? 4
                    let fill = try arguments.color("fill").map { CanvasExtensionColor(red: $0.red, green: $0.green, blue: $0.blue) }
                    return try await resizeDocument(arguments, String(localized: "Canvas Size")) { snapshot in
                        try await CanvasResizer.shared.resize(snapshot, to: CanvasSizeOptions(width: width, height: height, anchor: anchor, fill: fill))
                    }
                },
            AgentTool(name: "resize_image", title: "Image Size",
                description: "Scales the whole image, every layer with it, to a new pixel size. Giving only width or only height keeps the proportions.",
                schema: Schema.object([
                    "document_id": Schema.documentID,
                    "width": Schema.integer("New width in pixels.", minimum: 1, maximum: DocumentLimits.maxSide),
                    "height": Schema.integer("New height in pixels.", minimum: 1, maximum: DocumentLimits.maxSide),
                    "resolution": Schema.number("Pixels per inch to save. Default unchanged.", minimum: 1, maximum: 9600),
                    "sampling": Schema.string("Default High quality; Nearest keeps hard pixel edges.", choices: LayerSampling.allCases.map(\.rawValue)),
                ])) { [unowned self] arguments in
                    let session = try tab(arguments).session
                    let document = try canvas(session)
                    var width = try arguments.int("width"), height = try arguments.int("height")
                    if width == nil, let height { width = max(1, Int((Double(document.width) * Double(height) / Double(document.height)).rounded())) }
                    if height == nil, let width { height = max(1, Int((Double(document.height) * Double(width) / Double(document.width)).rounded())) }
                    let options = ImageSizeOptions(width: width ?? document.width, height: height ?? document.height,
                                                   resolution: try arguments.double("resolution") ?? document.resolution,
                                                   sampling: try arguments.choice("sampling", LayerSampling.self) ?? .high)
                    return try await resizeDocument(arguments, String(localized: "Image Size")) { snapshot in
                        try await ImageResizer.shared.resize(snapshot, to: options)
                    }
                },
            AgentTool(name: "crop", title: "Crop",
                description: "Crops the canvas to a rectangle, in document pixels. Layers keep their pixels outside it, so moving them later can bring them back into view.",
                schema: Schema.object(Schema.rect("the area to keep").merging(["document_id": Schema.documentID]) { a, _ in a },
                                      required: ["x", "y", "width", "height"]),
                destructive: true) { [unowned self] arguments in
                    guard let rect = try arguments.rect()?.integral else { throw AgentError("Give x, y, width and height.") }
                    return try await resizeDocument(arguments, String(localized: "Crop")) { snapshot in
                        try await CanvasResizer.shared.resize(snapshot, to: CanvasSizeOptions(width: Int(rect.width), height: Int(rect.height),
                                                                                             contentOffset: CGPoint(x: -rect.minX, y: -rect.minY)))
                    }
                },
            AgentTool(name: "trim", title: "Trim",
                description: "Crops away empty edges: transparent pixels, or pixels the color of the top-left or bottom-right corner.",
                schema: Schema.object([
                    "document_id": Schema.documentID,
                    "based_on": Schema.string("Default transparent.", choices: ["transparent", "top_left_color", "bottom_right_color"]),
                ]), destructive: true) { [unowned self] arguments in
                    let session = try tab(arguments).session
                    _ = try await editable(session)
                    var options = TrimOptions()
                    switch try arguments.string("based_on") {
                    case "top_left_color": options.basedOn = .topLeftPixelColor
                    case "bottom_right_color": options.basedOn = .bottomRightPixelColor
                    default: options.basedOn = .transparentPixels
                    }
                    let changed = try await change(session, String(localized: "Trim")) { _ = try await session.trim(options: options) }
                    return outcome(session, changed: changed, extra: ["width": session.document?.width ?? 0, "height": session.document?.height ?? 0])
                },
            AgentTool(name: "flip_canvas", title: "Flip Canvas",
                description: "Mirrors the whole image, every layer with it.",
                schema: Schema.object([
                    "document_id": Schema.documentID,
                    "direction": Schema.string("Which way.", choices: ["horizontal", "vertical"]),
                ], required: ["direction"])) { [unowned self] arguments in
                    let session = try tab(arguments).session
                    _ = try await editable(session)
                    let horizontal = try arguments.requiredString("direction") != "vertical"
                    let changed = try await change(session, String(localized: "Flip Canvas")) { session.flipCanvas(horizontally: horizontal) }
                    return outcome(session, changed: changed)
                },
        ]
    }

    private func selectionMode(_ arguments: AgentArguments) throws -> SelectionMode {
        switch try arguments.string("mode")?.lowercased() {
        case nil, "replace", "new": .replace
        case "add": .add
        case "subtract": .subtract
        default: throw AgentError("mode must be replace, add or subtract.")
        }
    }

    private func select(_ arguments: AgentArguments) async throws -> AgentResult {
        let session = try tab(arguments).session
        _ = try await editable(session)
        let action = try arguments.requiredString("action")
        let mode = try selectionMode(arguments)
        let changed = try await change(session, String(localized: "Select")) {
            switch action {
            case "all": session.selectAll()
            case "none": session.deselect()
            case "invert":
                guard session.selection != nil else { throw AgentError("Nothing is selected, so there’s nothing to invert (with no selection, edits already cover everything).") }
                session.invertSelection()
            case "rectangle", "ellipse", "polygon":
                let path: CGPath
                if action == "polygon" {
                    guard let points = try arguments.points("points"), points.count >= 3 else { throw AgentError("A polygon needs at least 3 points.") }
                    let outline = CGMutablePath()
                    outline.addLines(between: points)
                    outline.closeSubpath()
                    path = outline
                } else {
                    guard let rect = try arguments.rect() else { throw AgentError("Give x, y, width and height.") }
                    path = action == "ellipse" ? CGPath(ellipseIn: rect, transform: nil) : CGPath(rect: rect, transform: nil)
                }
                session.applySelection(path, mode: mode, name: String(localized: "Select"))
                if let feather = try arguments.double("feather"), feather >= 1, session.canModifySelection {
                    session.featherSelection(by: Int(feather.rounded()))
                }
            case "layer", "mask":
                let id = try arguments.requiredUUID("layer_id")
                let layer = try self.layer(id, in: session)
                if action == "mask" {
                    guard layer.mask != nil else { throw AgentError("“\(layer.name)” has no mask.") }
                    session.loadMaskSelection(layerID: id, mode: mode)
                } else {
                    guard layer.asset != nil, !layer.isGroup else { throw AgentError("“\(layer.name)” has no pixels to select.") }
                    session.loadLayerSelection(layerID: id, mode: mode)
                }
            case "expand", "contract", "feather":
                let amount = try arguments.requiredInt("amount")
                guard (1...500).contains(amount) else { throw AgentError("amount must be 1 to 500 pixels.") }
                guard session.canModifySelection else { throw AgentError("There’s no selection to change.") }
                switch action {
                case "expand": session.expandSelection(by: amount)
                case "contract": session.contractSelection(by: amount)
                default: session.featherSelection(by: amount)
                }
            default:
                throw AgentError("Unknown action “\(action)”.")
            }
        }
        return outcome(session, changed: changed, extra: ["selection": selectionJSON(session)])
    }

    private func smartSelect(_ arguments: AgentArguments) async throws -> AgentResult {
        let session = try tab(arguments).session
        let document = try await editable(session)
        let method = try arguments.requiredString("method")
        let mode = try selectionMode(arguments)
        let sampleAll = try arguments.bool("sample_all_layers") ?? true
        if !sampleAll { _ = try target(arguments, in: session) }
        func point() throws -> CGPoint {
            let x = try arguments.requiredDouble("x"), y = try arguments.requiredDouble("y")
            guard x >= 0, y >= 0, x < Double(document.width), y < Double(document.height) else {
                throw AgentError("x, y must be on the \(document.width) × \(document.height) canvas.")
            }
            return CGPoint(x: x, y: y)
        }
        let changed: Bool
        switch method {
        case "subject":
            guard session.canSelectSubject else { throw AgentError("Compositor can’t select right now.") }
            changed = try await change(session, String(localized: "Select Subject")) { await session.selectSubject(mode: mode) }
        case "object":
            let at = try point()
            let saved = session.objectSelectionSettings
            defer { session.objectSelectionSettings = saved }
            session.objectSelectionSettings.sampleAllLayers = sampleAll
            changed = try await change(session, String(localized: "Select Object")) { await session.selectObject(at: at, mode: mode) }
        case "wand":
            let at = try point()
            let saved = session.wandSettings
            defer { session.wandSettings = saved }
            session.wandSettings.sampleAllLayers = sampleAll
            if let tolerance = try arguments.int("tolerance") { session.wandSettings.tolerance = min(255, max(0, tolerance)) }
            if let contiguous = try arguments.bool("contiguous") { session.wandSettings.contiguous = contiguous }
            changed = try await change(session, String(localized: "Magic Wand")) { await session.magicWand(at: at, mode: mode) }
        default:
            throw AgentError("method must be subject, object or wand.")
        }
        return outcome(session, changed: changed,
                       extra: ["selection": selectionJSON(session)].merging(changed ? [:] : ["note": "Nothing was found to select there."]) { a, _ in a })
    }

    /// Canvas Size, Image Size and Crop: the document rebuilt at its new size, as the menus do it.
    private func resizeDocument(_ arguments: AgentArguments, _ name: String,
                                _ make: (ProjectSnapshot) async throws -> ProjectSnapshot) async throws -> AgentResult {
        let session = try tab(arguments).session
        _ = try await editable(session)
        guard session.canStartProjectOperation, let snapshot = session.projectSnapshot() else {
            throw AgentError("Compositor can’t resize right now: \(blocker(session) ?? "another operation is running").")
        }
        let changed = try await change(session, name) {
            session.isProjectBusy = true
            let resized: ProjectSnapshot
            do { resized = try await make(snapshot) } catch { session.isProjectBusy = false; throw error }
            session.isProjectBusy = false
            session.applyDocumentSize(resized, actionName: name)
        }
        return outcome(session, changed: changed, extra: ["width": session.document?.width ?? 0, "height": session.document?.height ?? 0])
    }
}
