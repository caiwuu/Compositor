import AppKit

extension AgentTools {
    var pixelTools: [AgentTool] {
        let target: [String: JSONObject] = [
            "document_id": Schema.documentID,
            "layer_id": Schema.string("The layer to work on. Default the selected one."),
            "target": Schema.string("The layer’s own pixels, or its mask (where white shows the layer and black hides it). Default pixels.", choices: ["pixels", "mask"]),
        ]
        return [
            AgentTool(name: "apply_filter", title: "Apply Filter",
                description: "Runs a filter or color adjustment on a pixel layer’s own pixels, inside the selection if there is one, as one undo step. Remove Background masks the background away (the pixels are kept, so it can be undone or painted back); Content-Aware Fill needs a selection and fills it from its surroundings. To change the look without touching pixels, use add_adjustment_layer instead. The layer must be visible. describe_settings with topic filter shows each filter’s settings.",
                schema: Schema.object([
                    "document_id": Schema.documentID, "layer_id": Schema.string("The layer to filter. Default the selected one."),
                    "filter": Schema.string("The filter.", choices: Self.filterNames),
                    "settings": Schema.anyObject("Settings to change from the defaults, as describe_settings shows them, such as {\"radius\": 8}."),
                ], required: ["filter"])) { [unowned self] arguments in
                    try await applyFilter(arguments)
                },
            AgentTool(name: "fill", title: "Fill",
                description: "Fills a layer (or its mask) with a color, inside the selection if there is one, else all of it. On a mask, white reveals and black hides; grays are partial.",
                schema: Schema.object(target.merging([
                    "color": Schema.string("#RRGGBB, or a name such as white or black. Default the foreground color."),
                    "opacity": Schema.number("0 to 1. Default 1.", minimum: 0, maximum: 1),
                ]) { a, _ in a })) { [unowned self] arguments in
                    try await fill(arguments)
                },
            AgentTool(name: "clear_pixels", title: "Clear Selected Pixels",
                description: "Erases the selected part of a layer to transparency, as Delete does with a selection.",
                schema: Schema.object(["document_id": Schema.documentID, "layer_id": Schema.string("Default the selected layer.")]),
                destructive: true) { [unowned self] arguments in
                    let session = try tab(arguments).session
                    _ = try await editable(session)
                    let layer = try self.target(arguments, in: session)
                    guard session.selection != nil else { throw AgentError("There’s no selection to clear; make one with select first.") }
                    guard session.canEditPixels, layer.asset != nil else { throw cantPaint(layer, in: session) }
                    let changed = try await change(session, String(localized: "Clear")) { await session.clearSelectedPixels() }
                    return outcome(session, changed: changed, layerID: layer.id)
                },
            AgentTool(name: "draw", title: "Draw",
                description: "Paints shapes onto a layer’s pixels or its mask, in document pixels, clipped to the selection if there is one, all as one undo step: rectangles, ellipses, polygons (filled), lines and polylines (stroked). erase: true cuts them out instead (on a mask, paint black to hide). For shapes that stay editable, use add_shape_layer.",
                schema: Schema.object(target.merging([
                    "shapes": Schema.array("What to paint, in order.", items: Schema.object([
                        "type": Schema.string("The shape.", choices: ["rectangle", "ellipse", "polygon", "line", "polyline"]),
                        "x": Schema.number("Rectangle or ellipse left."), "y": Schema.number("Top."),
                        "width": Schema.number("Width.", minimum: 0), "height": Schema.number("Height.", minimum: 0),
                        "corner_radius": Schema.number("Rounded rectangle corners.", minimum: 0),
                        "points": Schema.points,
                        "color": Schema.string("#RRGGBB. Default the foreground color."),
                        "opacity": Schema.number("0 to 1. Default 1.", minimum: 0, maximum: 1),
                        "stroke_width": Schema.number("Outline thickness. Lines default to 4; with it, other shapes are outlined instead of filled.", minimum: 0),
                        "erase": Schema.boolean("Erase to transparency instead of painting."),
                    ], required: ["type"])),
                ]) { a, _ in a }, required: ["shapes"])) { [unowned self] arguments in
                    try await draw(arguments)
                },
        ]
    }

    static var filterNames: [String] { FilterKind.allCases.map(\.rawValue) + ["Levels", "Hue/Saturation", "Invert"] }

    static func filterKind(_ name: String) -> FilterKind? {
        let key = AgentColor.simplified(name)
        if let kind = FilterKind.allCases.first(where: { AgentColor.simplified($0.rawValue) == key }) { return kind }
        let aliases: [String: FilterKind] = ["cameraraw": .cameraRaw, "bloom": .bloomGlow, "glow": .bloomGlow,
                                             "blackandwhite": .blackWhite, "blur": .gaussianBlur, "noise": .addNoise]
        return aliases[key]
    }

    static func settingsKeys(_ kind: FilterKind) -> [String] {
        switch kind {
        case .gaussianBlur: ["radius"]
        case .motionBlur: ["angle", "distance"]
        case .addNoise: ["amount", "gaussian", "monochromatic"]
        case .vignette: ["vignetteAmount", "vignetteColor", "vignetteMidpoint", "vignetteRoundness", "vignetteFeather", "vignetteHighlights"]
        case .bloomGlow: ["bloomAmount", "bloomRadius"]
        case .dither: ["dither"]
        case .tonalContrast: ["tonalAmount", "tonalRadius", "tonalShadows", "tonalMidtones", "tonalHighlights"]
        case .lensCorrection: ["distortion"]
        case .cameraRaw: ["cameraRaw"]
        case .removeBackground: ["backgroundQuality", "refineEdges", "matteContrast", "shiftEdge"]
        case .contentAwareFill: []
        case .curves: ["curves"]
        case .exposure: ["exposure"]
        case .gradientMap: ["gradientMap"]
        case .grain: ["grain"]
        case .blackWhite: ["blackWhite"]
        case .colorBalance: ["colorBalance"]
        }
    }

    /// Why pixels can't be changed on `layer`, in words the agent can act on.
    func cantPaint(_ layer: ImageLayer, in session: EditorSession) -> AgentError {
        if let reason = blocker(session) { return AgentError("Compositor can’t do that right now: \(reason).") }
        if session.document?.effectiveVisibleIDs.contains(layer.id) != true {
            return AgentError("“\(layer.name)” is hidden (or in a hidden folder); show it first with update_layer.")
        }
        if session.selection?.isEmpty == true { return AgentError("The selection is empty, so there’s nothing to change; select none or select something.") }
        if layer.adjustment != nil { return AgentError("“\(layer.name)” is an adjustment layer and has no pixels; change it with update_layer’s adjustment.") }
        if layer.isGroup { return AgentError("“\(layer.name)” is a folder and has no pixels; work on a layer inside it, or its mask.") }
        if session.isMaskSelected, layer.mask?.isEnabled == false { return AgentError("“\(layer.name)”’s mask is disabled; enable it first.") }
        if layer.asset == nil { return AgentError("“\(layer.name)” is empty, so there’s nothing to change.") }
        return AgentError("Compositor can’t change “\(layer.name)” right now.")
    }

    /// Picks the layer and, with target mask, its mask.
    func pixelTarget(_ arguments: AgentArguments, in session: EditorSession) throws -> (layer: ImageLayer, mask: Bool) {
        let layer = try target(arguments, in: session)
        let mask = try arguments.string("target")?.lowercased() == "mask"
        if mask {
            guard layer.mask != nil else { throw AgentError("“\(layer.name)” has no mask; add one with layer_mask.") }
            session.isMaskSelected = true
        }
        return (layer, mask)
    }

    private static func cgColor(_ color: PaletteColor, mask: Bool, alpha: CGFloat = 1) -> CGColor {
        mask ? CGColor(gray: 0.299 * color.red + 0.587 * color.green + 0.114 * color.blue, alpha: alpha)
             : CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: alpha)
    }

    // MARK: Tools

    private func applyFilter(_ arguments: AgentArguments) async throws -> AgentResult {
        let session = try tab(arguments).session
        _ = try await editable(session)
        let layer = try target(arguments, in: session)
        let name = try arguments.requiredString("filter")
        let patch = try arguments.object("settings")
        let changed: Bool
        switch AgentColor.simplified(name) {
        case "invert":
            guard session.canInvert else { throw cantPaint(layer, in: session) }
            changed = try await change(session, String(localized: "Invert")) { await session.invertPixels() }
        case "levels":
            guard session.canAdjustColors else { throw cantPaint(layer, in: session) }
            let settings = try AgentCoding.merged(LevelsSettings(), with: patch, name: "Levels settings")
            changed = try await change(session, String(localized: "Levels")) {
                session.beginLevels()
                guard session.levels != nil else { throw AgentError(session.brushError ?? "Levels couldn’t start on this layer.") }
                session.updateLevels(settings, preview: false)
                await session.commitLevels()
                if session.levels != nil { session.cancelLevels() }
            }
        case "huesaturation", "hsv":
            guard session.canAdjustColors else { throw cantPaint(layer, in: session) }
            let settings = try AgentCoding.merged(HueSaturationSettings(), with: patch, name: "Hue/Saturation settings")
            changed = try await change(session, String(localized: "Hue/Saturation")) {
                session.beginHueSaturation()
                guard session.hueSaturation != nil else { throw AgentError(session.brushError ?? "Hue/Saturation couldn’t start on this layer.") }
                session.updateHueSaturation(settings, preview: false)
                await session.commitHueSaturation()
                if session.hueSaturation != nil { session.cancelHueSaturation() }
            }
        default:
            guard let kind = Self.filterKind(name) else {
                throw AgentError("Unknown filter “\(name)”. Filters: \(Self.filterNames.joined(separator: ", ")).")
            }
            if kind == .contentAwareFill, session.selection == nil {
                throw AgentError("Content-Aware Fill fills the selection: select what to replace first.")
            }
            guard kind == .vignette ? session.canVignette : session.canAdjustColors else { throw cantPaint(layer, in: session) }
            var base = FilterSettings()
            if kind == .gradientMap {
                base.gradientMap = GradientMapSettings(shadows: AdjustmentColor(session.foregroundColor), highlights: AdjustmentColor(session.backgroundColor))
            }
            let settings = try AgentCoding.merged(base, with: patch, name: "\(kind.rawValue) settings")
            changed = try await change(session, kind.rawValue) {
                session.beginFilter(kind)
                guard let edit = session.filterEdit else { throw AgentError(session.brushError ?? "\(kind.rawValue) couldn’t start on this layer.") }
                session.updateFilter(settings, preview: kind.isAutomatic)
                if kind.isAutomatic {
                    for _ in 0..<20 {
                        guard let task = edit.previewTask, session.filterEdit === edit else { break }
                        await task.value
                    }
                    if let error = edit.previewError { session.cancelFilter(); throw AgentError(error) }
                }
                await session.commitFilter()
                if session.filterEdit != nil {
                    let error = session.filterEdit?.previewError
                    session.cancelFilter()
                    throw AgentError(error ?? "\(kind.rawValue) couldn’t be applied.")
                }
            }
        }
        return outcome(session, changed: changed, layerID: layer.id,
                       extra: changed ? [:] : ["note": "Nothing changed: those settings leave the pixels as they are."])
    }

    private func fill(_ arguments: AgentArguments) async throws -> AgentResult {
        let session = try tab(arguments).session
        let document = try await editable(session)
        let (layer, mask) = try pixelTarget(arguments, in: session)
        defer { session.isMaskSelected = false }
        guard session.canEditPixels, mask || !layer.isGroup else { throw cantPaint(layer, in: session) }
        let color = Self.cgColor(try arguments.color("color") ?? session.foregroundColor, mask: mask,
                                 alpha: CGFloat(min(1, max(0, try arguments.double("opacity") ?? 1))))
        let name = mask ? String(localized: "Fill Mask") : String(localized: "Fill")
        let changed = try await change(session, name) {
            guard let current = session.activeLayer else { return }
            await session.applyPixelEdit(to: current, name: name) { edit in
                try edit.paint { context in
                    context.setFillColor(color)
                    context.fill(CGRect(origin: .zero, size: document.size))
                }
            }
        }
        return outcome(session, changed: changed, layerID: layer.id)
    }

    private struct Mark {
        enum Kind: String { case rectangle, ellipse, polygon, line, polyline }
        let kind: Kind
        let path: CGPath
        let color: PaletteColor
        let opacity: CGFloat
        let strokeWidth: CGFloat?
        let erase: Bool
    }

    private func draw(_ arguments: AgentArguments) async throws -> AgentResult {
        let session = try tab(arguments).session
        let document = try await editable(session)
        guard let list = try arguments.array("shapes"), !list.isEmpty else { throw AgentError("“shapes” is required.") }
        let foreground = session.foregroundColor
        let marks: [Mark] = try list.enumerated().map { index, item in
            guard let object = item as? JSONObject else { throw AgentError("shapes[\(index)] must be an object.") }
            let shape = AgentArguments(object)
            let type = try shape.requiredString("type").lowercased()
            guard let kind = Mark.Kind(rawValue: type) else { throw AgentError("shapes[\(index)].type must be rectangle, ellipse, polygon, line or polyline.") }
            let path = CGMutablePath()
            switch kind {
            case .rectangle, .ellipse:
                guard let rect = try shape.rect() else { throw AgentError("shapes[\(index)] needs x, y, width and height.") }
                if kind == .ellipse { path.addEllipse(in: rect) }
                else { path.addPath(ShapeKind.rectangle.path(in: rect, cornerRadius: CGFloat(try shape.double("corner_radius") ?? 0))) }
            case .polygon, .line, .polyline:
                guard let points = try shape.points("points"), points.count >= (kind == .polygon ? 3 : 2) else {
                    throw AgentError("shapes[\(index)] needs points: at least \(kind == .polygon ? 3 : 2) [x, y] pairs.")
                }
                path.addLines(between: points)
                if kind == .polygon { path.closeSubpath() }
            }
            var width = try shape.double("stroke_width").map { CGFloat($0) }
            if kind == .line || kind == .polyline { width = width ?? 4 }
            return Mark(kind: kind, path: path, color: try shape.color("color") ?? foreground,
                        opacity: CGFloat(min(1, max(0, try shape.double("opacity") ?? 1))), strokeWidth: width,
                        erase: try shape.bool("erase") ?? false)
        }
        let (layer, mask) = try pixelTarget(arguments, in: session)
        defer { session.isMaskSelected = false }
        guard session.canEditPixels else { throw cantPaint(layer, in: session) }
        let name = mask ? String(localized: "Paint Mask") : String(localized: "Draw")
        let changed = try await change(session, name) {
            guard let current = session.activeLayer else { return }
            await session.applyPixelEdit(to: current, name: name) { edit in
                try edit.paint { context in
                    context.clip(to: CGRect(origin: .zero, size: document.size))
                    context.setShouldAntialias(true)
                    for mark in marks {
                        context.saveGState()
                        if mark.erase && !mask { context.setBlendMode(.destinationOut) }
                        let color = Self.cgColor(mark.erase && mask ? PaletteColor(red: 0, green: 0, blue: 0) : mark.color,
                                                 mask: mask, alpha: mark.opacity)
                        context.addPath(mark.path)
                        if let width = mark.strokeWidth, width > 0 {
                            context.setStrokeColor(color)
                            context.setLineWidth(width)
                            context.setLineCap(.round)
                            context.setLineJoin(.round)
                            context.strokePath()
                        } else {
                            context.setFillColor(color)
                            context.fillPath()
                        }
                        context.restoreGState()
                    }
                }
            }
        }
        return outcome(session, changed: changed, layerID: layer.id)
    }
}
