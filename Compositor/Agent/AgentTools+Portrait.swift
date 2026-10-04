import AppKit

extension AgentTools {
    var portraitTools: [AgentTool] {
        [
            AgentTool(name: "warp", title: "Liquify Warp",
                description: "Moves parts of a pixel layer smoothly, as Liquify's Forward Warp does but exactly: each move carries the point at from to to, and drags what's within radius of it along, less and less toward the edge. To slim a face or an arm, move its edge as a path instead: path follows the edge (detect's face contour or an arm's outer edge points) and shift moves it, a few pixels inward; everything within radius of the line moves with it, so the edge stays a smooth curve. Separate point moves along an edge make it wavy. shifts gives each path point its own move, as for a jaw, tapering to [0, 0] at the ends. A move can't be longer than half its radius, or the picture would fold; for more, call again. With a selection, only selected pixels move (feathered edges fade). To slim, the background beside the edge has to move in, so don't select just the person; select a generous area around the part instead, to keep other things (a face, a straight edge) still, and check with compare outside_selection that nothing else moved. One undo step.",
                schema: Schema.object([
                    "document_id": Schema.documentID,
                    "layer_id": Schema.string("The pixel layer to warp. Default: the selected layer."),
                    "moves": Schema.array("The moves, in document pixels: from and to, or path with shift or shifts.", items: Schema.object([
                        "from": Schema.array("Where the point is: [x, y].", items: Schema.number("A coordinate.")),
                        "to": Schema.array("Where it goes: [x, y].", items: Schema.number("A coordinate.")),
                        "path": Schema.points,
                        "shift": Schema.array("How the whole path moves: [dx, dy].", items: Schema.number("A distance.")),
                        "shifts": Schema.array("How each path point moves, one [dx, dy] each.", items: Schema.array("[dx, dy].", items: Schema.number("A distance."))),
                        "radius": Schema.number("How far around it the move reaches, in pixels. Default: radius below.", minimum: 1),
                    ])),
                    "radius": Schema.number("The radius for moves that don't give one.", minimum: 1),
                ], required: ["moves"]), destructive: true) { [unowned self] arguments in
                    try await warp(arguments)
                },
            AgentTool(name: "brush_stroke", title: "Brush Strokes",
                description: "Paints strokes with Compositor's own brushes along points, as dragging on the canvas does. paint lays color (soft by default: hardness 0) for blush, eye shadow, contour, dodge and burn on a layer set to Soft Light or Overlay; erase clears pixels; spot_heal blends away what's under the brush (a single point is a dab: remove blemishes at the spots detect finds); clone copies from clone_source; blur softens; smudge pushes color; liquify pushes pixels along the stroke. With target mask, paint and erase work on the layer mask (white shows, black hides). Each stroke is a list of points; all strokes in one call are one undo step. The selection limits where it paints.",
                schema: Schema.object([
                    "document_id": Schema.documentID,
                    "layer_id": Schema.string("The layer to paint on. Default: the selected layer."),
                    "target": Schema.string("pixels (default) or the layer's mask.", choices: ["pixels", "mask"]),
                    "mode": Schema.string("Which brush.", choices: ["paint", "erase", "spot_heal", "clone", "blur", "smudge", "liquify"]),
                    "strokes": Schema.array("Strokes, each a list of [x, y] points in document pixels.", items: Schema.points),
                    "size": Schema.number("Brush diameter in pixels. Default 40.", minimum: 1, maximum: 5000),
                    "hardness": Schema.number("0 (soft edge) to 1 (hard). Default 0.", minimum: 0, maximum: 1),
                    "opacity": Schema.number("0 to 1: how strongly it paints (for blur, smudge and liquify: strength). Default 1.", minimum: 0, maximum: 1),
                    "color": Schema.string("paint: #RRGGBB. Default the foreground color. On a mask, white shows and black hides."),
                    "heal_mode": Schema.string("spot_heal: how it finds replacement pixels. Default Content-Aware.", choices: SpotHealingMode.allCases.map(\.rawValue)),
                    "clone_source": Schema.array("clone: [x, y], the point that the first stroke's first point copies from.", items: Schema.number("A coordinate.")),
                    "sample_all_layers": Schema.boolean("clone: copy from the visible canvas rather than the layer alone."),
                    "blur_radius": Schema.number("blur: how far it softens, in pixels. Default 5.", minimum: 1, maximum: 100),
                ], required: ["mode", "strokes"]), destructive: true) { [unowned self] arguments in
                    try await brushStrokes(arguments)
                },
            AgentTool(name: "smooth_skin", title: "Smooth Skin",
                description: "Smooths skin while keeping edges (eyes, lips, the face's outline) sharp: an edge-preserving filter, mixed back in by strength, with some of the skin's fine texture kept by detail so it doesn't look plastic. Works on a pixel layer inside the selection: select first with smart_select face_skin or skin, feathered, and consider a duplicate layer whose opacity you can lower later.",
                schema: Schema.object([
                    "document_id": Schema.documentID,
                    "layer_id": Schema.string("The pixel layer. Default: the selected layer."),
                    "strength": Schema.number("0 to 1. Default 0.5.", minimum: 0, maximum: 1),
                    "radius": Schema.number("How large the smoothed-out unevenness is, in pixels. Default: from the largest face's size.", minimum: 1, maximum: 100),
                    "detail": Schema.number("0 to 1: how much fine texture (pores) stays. Default 0.35.", minimum: 0, maximum: 1),
                ]), destructive: true) { [unowned self] arguments in
                    try await smoothSkin(arguments)
                },
        ]
    }

    // MARK: Selecting by what's in a portrait

    func selectPortrait(_ method: String, _ arguments: AgentArguments, in session: EditorSession, mode: SelectionMode) async throws {
        let image = try Self.flattened(try await rendered(session.projectSnapshot()), over: .white)
        let index = try arguments.int("face_index") ?? 0
        let input = AgentSendable(value: image)
        let path = try await Task.detached(priority: .userInitiated) {
            AgentSendable(value: try Self.portraitPath(method, in: input.value, faceIndex: index))
        }.value.value
        guard let path, !path.isEmpty, !path.boundingBoxOfPath.isEmpty else {
            throw AgentError(method == "person" ? "No person was found." : method == "skin" ? "No skin was found." : "That part of the face wasn’t found.")
        }
        session.applySelection(path, mode: mode, name: String(localized: "Select"))
    }

    nonisolated static func portraitPath(_ method: String, in image: CGImage, faceIndex: Int) throws -> CGPath? {
        let width = image.width, height = image.height
        switch method {
        case "person":
            return try MagicWand.outline(of: try AgentPortrait.personMask(image), width: width, height: height)
        case "skin":
            let faces = try AgentPortrait.faces(in: image)
            var skin = AgentPortrait.skinMask(try AgentBitmap(image), faces: faces, person: try AgentPortrait.personMask(image))
            for face in faces {
                guard let facial = AgentPortrait.faceSkin(face, skin: skin, width: width, height: height) else { continue }
                for index in skin.indices where facial[index] != 0 { skin[index] = 255 }
            }
            return try MagicWand.outline(of: skin, width: width, height: height)
        default:
            let faces = try AgentPortrait.faces(in: image)
            guard !faces.isEmpty else { throw AgentError("No face was found.") }
            guard faceIndex < faces.count else { throw AgentError("There \(faces.count == 1 ? "is 1 face" : "are \(faces.count) faces"); face_index counts from 0.") }
            let face = faces[faceIndex]
            guard let outline = AgentPortrait.path(of: method, in: face) else { return nil }
            guard method == "face_skin" else { return outline }
            // Only skin: not hair over the forehead, glasses, or a hand on the cheek.
            let skin = AgentPortrait.skinMask(try AgentBitmap(image), faces: [face], person: nil)
            guard let facial = AgentPortrait.faceSkin(face, skin: skin, width: width, height: height) else { return outline }
            return try MagicWand.outline(of: facial, width: width, height: height)
        }
    }

    /// Select > Color Range with the colors given and the colors at points, combined with the selection by `mode`.
    func selectColorRange(_ arguments: AgentArguments, in session: EditorSession, mode: SelectionMode) async throws {
        var include: [UInt8] = []
        for value in try arguments.array("colors") ?? [] {
            guard let text = value as? String, let color = AgentColor.parse(text) else { throw AgentError("colors must be #RRGGBB.") }
            include += [color.red, color.green, color.blue].map { UInt8((min(1, max(0, $0)) * 255).rounded()) }
        }
        let points = try arguments.points("points") ?? []
        guard !include.isEmpty || !points.isEmpty else { throw AgentError("Give colors, or points to take colors from.") }
        let original = session.selection
        session.beginColorRange()
        guard let edit = session.colorRange else { throw AgentError("Color Range can’t open right now.") }
        edit.fuzziness = Double(min(200, max(0, try arguments.int("fuzziness") ?? 40)))
        edit.invert = try arguments.bool("invert") ?? false
        for point in points { session.sampleColorRange(at: point, shift: true, option: false) }
        edit.include += include
        guard edit.hasColors else { session.cancelColorRange(); throw AgentError("Those points aren’t on the canvas.") }
        session.updateColorRange()
        edit.preview = nil
        for _ in 0..<600 where edit.preview == nil && edit.error == nil { try await Task.sleep(for: .milliseconds(25)) }
        if let error = edit.error { session.cancelColorRange(); throw AgentError(error) }
        guard edit.preview != nil else { session.cancelColorRange(); throw AgentError("Color Range took too long.") }
        session.commitColorRange()
        guard let found = session.selection, !found.isEmpty else { throw AgentError("No pixels are near those colors.") }
        switch mode {
        case .replace: break
        case .add:
            if let original { session.setSelection(DocumentSelection(path: original.path.union(found.path, using: .winding)), name: String(localized: "Color Range")) }
        case .subtract:
            session.setSelection(original.map { DocumentSelection(path: $0.path.subtracting(found.path, using: .winding)) }, name: String(localized: "Color Range"))
        }
    }

    // MARK: Warping

    /// A point dragged by `deltas[0]`, or a line whose points move by their deltas, with what lies between them moving
    /// by a mix of the two nearest, so a whole edge shifts evenly.
    nonisolated private struct WarpMove: Sendable {
        let points: [CGPoint]
        let deltas: [CGPoint]
        let radius: CGFloat

        /// How far `p` is from the line, squared, and how the line moves at the point nearest it.
        func nearest(_ p: CGPoint) -> (distance: CGFloat, delta: CGPoint) {
            guard points.count > 1 else {
                return ((p.x - points[0].x) * (p.x - points[0].x) + (p.y - points[0].y) * (p.y - points[0].y), deltas[0])
            }
            var best = (distance: CGFloat.infinity, delta: CGPoint.zero)
            for i in 0..<(points.count - 1) {
                let a = points[i], b = points[i + 1]
                let ab = CGPoint(x: b.x - a.x, y: b.y - a.y)
                let length = ab.x * ab.x + ab.y * ab.y
                let t = length > 0 ? min(1, max(0, ((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / length)) : 0
                let q = CGPoint(x: a.x + ab.x * t, y: a.y + ab.y * t)
                let distance = (p.x - q.x) * (p.x - q.x) + (p.y - q.y) * (p.y - q.y)
                if distance < best.distance {
                    best = (distance, CGPoint(x: deltas[i].x + (deltas[i + 1].x - deltas[i].x) * t,
                                              y: deltas[i].y + (deltas[i + 1].y - deltas[i].y) * t))
                }
            }
            return best
        }
    }

    private func warp(_ arguments: AgentArguments) async throws -> AgentResult {
        let session = try tab(arguments).session
        let document = try await editable(session)
        let layer = try target(arguments, in: session)
        session.isMaskSelected = false
        guard let image = layer.asset?.image, layer.adjustment == nil, !layer.isGroup, session.canEditPixels else { throw cantPaint(layer, in: session) }
        guard let list = try arguments.array("moves"), !list.isEmpty else { throw AgentError("Give at least one move.") }
        guard list.count <= 200 else { throw AgentError("Up to 200 moves at a time.") }
        let defaultRadius = try arguments.double("radius")
        let toDocument = BrushRaster.pixelToDocument(layer.transform, width: image.width, height: image.height)
        let toPixel = toDocument.inverted()
        let scale = abs(toPixel.a * toPixel.d - toPixel.b * toPixel.c).squareRoot()
        let moves = try list.map { value -> WarpMove in
            guard let object = value as? JSONObject else { throw AgentError("Each move is an object.") }
            guard let radius = (object["radius"] as? NSNumber)?.doubleValue ?? defaultRadius, radius >= 1 else {
                throw AgentError("Give each move a radius, or radius for all of them.")
            }
            var points: [CGPoint] = [], deltas: [CGPoint] = []
            if let path = object["path"] {
                points = try AgentArguments.points(path, key: "path")
                guard points.count >= 2, points.count <= 500 else { throw AgentError("A path needs 2 to 500 points.") }
                if let shifts = object["shifts"] {
                    deltas = try AgentArguments.points(shifts, key: "shifts")
                    guard deltas.count == points.count else { throw AgentError("shifts needs one [dx, dy] for each point of path.") }
                } else if let shift = object["shift"] {
                    deltas = Array(repeating: try AgentArguments.point(shift, key: "shift"), count: points.count)
                } else {
                    throw AgentError("A path move needs shift or shifts.")
                }
            } else if let from = object["from"], let to = object["to"] {
                let start = try AgentArguments.point(from, key: "from"), end = try AgentArguments.point(to, key: "to")
                points = [start]
                deltas = [CGPoint(x: end.x - start.x, y: end.y - start.y)]
            } else {
                throw AgentError("Each move needs from and to, or path and shift.")
            }
            let length = deltas.map { hypot($0.x, $0.y) }.max() ?? 0
            guard length <= radius / 2 else {
                throw AgentError("A move of \(Int(length.rounded())) pixels needs a radius of at least \(Int((length * 2).rounded(.up))); or move it in several calls.")
            }
            let pixels = points.map { $0.applying(toPixel) }
            let moved = zip(points, deltas).map { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y).applying(toPixel) }
            return WarpMove(points: pixels, deltas: zip(pixels, moved).map { CGPoint(x: $1.x - $0.x, y: $1.y - $0.y) },
                            radius: CGFloat(radius) * scale)
        }
        var coverage: [UInt8]?
        if let selection = session.selection, !selection.isEmpty {
            coverage = try AgentBitmap.gray(try selection.coverage(width: document.width, height: document.height),
                                            width: document.width, height: document.height)
        }
        let input = AgentSendable(value: (image, moves, coverage, toDocument, document.width, document.height))
        let patch = try await Task.detached(priority: .userInitiated) {
            let (image, moves, coverage, toDocument, width, height) = input.value
            return AgentSendable(value: try Self.warped(image, moves: moves, coverage: coverage, toDocument: toDocument,
                                                        documentWidth: width, documentHeight: height))
        }.value.value
        guard let patch else { return outcome(session, changed: false, layerID: layer.id, extra: ["note": "Nothing moved: the moves are off the layer or outside the selection."]) }
        let name = String(localized: "Liquify")
        let changed = try await change(session, name) {
            guard let current = session.activeLayer else { return }
            await session.applyPixelEdit(to: current, name: name) { edit in
                try edit.paint { context in
                    context.concatenate(toDocument)
                    BrushRaster.draw(patch.image, in: patch.rect, mask: false, context: context)
                }
            }
        }
        return outcome(session, changed: changed, layerID: layer.id, extra: ["moves": moves.count])
    }

    /// The part of `image` the moves change, warped: each output pixel takes its color from the point that moves onto
    /// it, found by working the warp backward a few times. Nil when no pixel changes.
    private nonisolated static func warped(_ image: CGImage, moves: [WarpMove], coverage: [UInt8]?, toDocument: CGAffineTransform,
                                           documentWidth: Int, documentHeight: Int) throws -> (image: CGImage, rect: CGRect)? {
        let width = image.width, height = image.height
        var area = CGRect.null
        for move in moves {
            let reach = move.radius + (move.deltas.map { hypot($0.x, $0.y) }.max() ?? 0) + 2
            for point in move.points {
                area = area.union(CGRect(x: point.x - reach, y: point.y - reach, width: reach * 2, height: reach * 2))
            }
        }
        area = area.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !area.isNull, area.width >= 1, area.height >= 1 else { return nil }
        let source = try premultiplied(image)
        let x0 = Int(area.minX), y0 = Int(area.minY), w = Int(area.width), h = Int(area.height)
        var output = [UInt8](repeating: 0, count: w * h * 4)
        func weight(_ p: CGPoint) -> CGFloat {
            guard let coverage else { return 1 }
            let d = p.applying(toDocument)
            let x = Int(d.x), y = Int(d.y)
            guard (0..<documentWidth).contains(x), (0..<documentHeight).contains(y) else { return 0 }
            return CGFloat(coverage[y * documentWidth + x]) / 255
        }
        func displacement(_ p: CGPoint) -> CGPoint {
            var dx: CGFloat = 0, dy: CGFloat = 0
            for move in moves {
                let nearest = move.nearest(p)
                let t = nearest.distance / (move.radius * move.radius)
                guard t < 1 else { continue }
                let falloff = (1 - t) * (1 - t)
                dx += nearest.delta.x * falloff
                dy += nearest.delta.y * falloff
            }
            guard dx != 0 || dy != 0 else { return .zero }
            let w = weight(p)
            return CGPoint(x: dx * w, y: dy * w)
        }
        func sample(_ x: CGFloat, _ y: CGFloat, into index: Int) {
            let fx = x - 0.5, fy = y - 0.5
            let ix = Int(floor(fx)), iy = Int(floor(fy))
            let tx = fx - CGFloat(ix), ty = fy - CGFloat(iy)
            var value: [CGFloat] = [0, 0, 0, 0]
            for (dx, dy, k) in [(0, 0, (1 - tx) * (1 - ty)), (1, 0, tx * (1 - ty)), (0, 1, (1 - tx) * ty), (1, 1, tx * ty)] where k > 0 {
                let sx = min(width - 1, max(0, ix + dx)), sy = min(height - 1, max(0, iy + dy))
                let offset = (sy * width + sx) * 4
                for c in 0..<4 { value[c] += CGFloat(source[offset + c]) * k }
            }
            for c in 0..<4 { output[index + c] = UInt8(min(255, max(0, value[c].rounded()))) }
        }
        var moved = false
        for row in 0..<h {
            for column in 0..<w {
                let target = CGPoint(x: CGFloat(column + x0) + 0.5, y: CGFloat(row + y0) + 0.5)
                var from = target
                for _ in 0..<6 {
                    let d = displacement(from)
                    from = CGPoint(x: target.x - d.x, y: target.y - d.y)
                }
                let index = (row * w + column) * 4
                sample(from.x, from.y, into: index)
                if !moved {
                    let offset = ((row + y0) * width + column + x0) * 4
                    moved = (0..<4).contains { output[index + $0] != source[offset + $0] }
                }
            }
        }
        guard moved else { return nil }
        return (try Self.image(output, width: w, height: h), area)
    }

    /// `image` as premultiplied RGBA bytes, rows from the top.
    nonisolated static func premultiplied(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                          bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { throw ExportError.render }
        return bytes
    }

    /// Premultiplied RGBA bytes, rows from the top, as an image.
    nonisolated static func image(_ bytes: [UInt8], width: Int, height: Int) throws -> CGImage {
        var bytes = bytes
        return try bytes.withUnsafeMutableBytes { buffer -> CGImage in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let image = context.makeImage() else { throw ExportError.render }
            return image
        }
    }

    // MARK: Brushes

    private func brushStrokes(_ arguments: AgentArguments) async throws -> AgentResult {
        let session = try tab(arguments).session
        _ = try await editable(session)
        let mode = try arguments.requiredString("mode")
        let tools: [String: NavigationTool] = ["paint": .brush, "erase": .brush, "spot_heal": .spotHealing, "clone": .cloneStamp,
                                               "blur": .blur, "smudge": .blur, "liquify": .blur]
        guard let tool = tools[mode] else { throw AgentError("mode must be one of: \(tools.keys.sorted().joined(separator: ", ")).") }
        let (layer, mask) = try pixelTarget(arguments, in: session)
        defer { session.isMaskSelected = false }
        guard !mask || mode == "paint" || mode == "erase" else { throw AgentError("Only paint and erase work on a mask.") }
        guard session.canEditPixels else { throw cantPaint(layer, in: session) }
        guard let list = try arguments.array("strokes"), !list.isEmpty else { throw AgentError("Give at least one stroke.") }
        let strokes = try list.map { value -> [CGPoint] in
            guard let points = value as? [Any], !points.isEmpty else { throw AgentError("Each stroke is a list of [x, y] points.") }
            return try points.map { try AgentArguments.point($0, key: "strokes") }
        }
        guard strokes.reduce(0, { $0 + $1.count }) <= 5000 else { throw AgentError("Up to 5000 points at a time.") }
        let size = CGFloat(min(5000, max(1, try arguments.double("size") ?? 40)))
        var cloneSource: CGPoint?
        if mode == "clone" {
            guard let value = try arguments.array("clone_source") else { throw AgentError("clone needs clone_source, the point to copy from.") }
            cloneSource = try AgentArguments.point(value, key: "clone_source")
        }
        let healMode = try arguments.string("heal_mode").map { name -> SpotHealingMode in
            guard let found = SpotHealingMode(rawValue: name) else { throw AgentError("heal_mode must be one of: \(SpotHealingMode.allCases.map(\.rawValue).joined(separator: ", ")).") }
            return found
        }

        let saved = (tool: session.tool, settings: session.brushSettings, tips: session.parkedBrushTips, blur: session.blurMode,
                     brush: session.brushMode, heal: session.spotHealingMode, source: session.cloneSource, clone: session.cloneSettings)
        let names: [String: String] = ["paint": String(localized: "Brush"), "erase": String(localized: "Erase"),
                                       "spot_heal": String(localized: "Spot Healing"), "clone": String(localized: "Clone Stamp"),
                                       "blur": String(localized: "Blur"), "smudge": String(localized: "Smudge"), "liquify": String(localized: "Liquify")]
        let changed = try await change(session, names[mode] ?? mode) {
            defer {
                session.selectTool(saved.tool)
                session.brushSettings = saved.settings
                session.parkedBrushTips = saved.tips
                session.blurMode = saved.blur
                session.brushMode = saved.brush
                session.spotHealingMode = saved.heal
                session.cloneSource = saved.source
                session.cloneSettings = saved.clone
            }
            session.selectTool(tool)
            guard session.tool == tool else { throw AgentError("Compositor couldn’t switch to that brush just now.") }
            var settings = session.brushSettings
            settings.diameter = size
            settings.hardness = CGFloat(min(1, max(0, try arguments.double("hardness") ?? 0)))
            settings.opacity = CGFloat(min(1, max(0, try arguments.double("opacity") ?? 1)))
            settings.smoothing = 0
            if let radius = try arguments.double("blur_radius") { settings.blurRadius = CGFloat(min(100, max(1, radius))) }
            let color = try arguments.color("color") ?? session.foregroundColor
            settings.red = color.red; settings.green = color.green; settings.blue = color.blue
            session.brushSettings = settings
            session.brushMode = mode == "erase" ? .erase : .paint
            if mode == "blur" { session.blurMode = .blur } else if mode == "smudge" { session.blurMode = .smudge } else if mode == "liquify" { session.blurMode = .liquify }
            if let healMode { session.spotHealingMode = healMode }
            if mask { session.isMaskSelected = true }
            if let cloneSource, let first = strokes.first?.first {
                session.cloneSettings.aligned = true
                session.cloneSettings.sampleAllLayers = try arguments.bool("sample_all_layers") ?? false
                session.setCloneSource(cloneSource)
                session.cloneOffset = CGSize(width: (cloneSource.x - first.x).rounded(), height: (cloneSource.y - first.y).rounded())
            }
            let spacing = max(1, size * 0.1)
            for stroke in strokes {
                var points: [CGPoint] = [stroke[0]]
                for point in stroke.dropFirst() {
                    let last = points[points.count - 1]
                    let steps = max(1, Int((hypot(point.x - last.x, point.y - last.y) / spacing).rounded(.up)))
                    for step in 1...steps {
                        let t = CGFloat(step) / CGFloat(steps)
                        points.append(CGPoint(x: last.x + (point.x - last.x) * t, y: last.y + (point.y - last.y) * t))
                    }
                }
                session.brushError = nil
                session.beginBrush(at: points[0])
                if let error = session.brushError { throw AgentError(error) }
                guard session.brushStroke != nil || session.warpStroke != nil else { throw AgentError("That brush couldn’t start here.") }
                for point in points.dropFirst() { session.continueBrush(at: point) }
                for _ in 0..<600 where !session.finishBrushImmediately() { try await Task.sleep(for: .milliseconds(25)) }
                for _ in 0..<600 where session.isProjectBusy { try await Task.sleep(for: .milliseconds(25)) }
                if let error = session.brushError { throw AgentError(error) }
            }
        }
        return outcome(session, changed: changed, layerID: layer.id, extra: ["strokes": strokes.count])
    }

    // MARK: Skin

    private func smoothSkin(_ arguments: AgentArguments) async throws -> AgentResult {
        let session = try tab(arguments).session
        let document = try await editable(session)
        let layer = try target(arguments, in: session)
        session.isMaskSelected = false
        guard let image = layer.asset?.image, layer.adjustment == nil, !layer.isGroup, session.canEditPixels else { throw cantPaint(layer, in: session) }
        let strength = min(1, max(0, try arguments.double("strength") ?? 0.5))
        let detail = min(1, max(0, try arguments.double("detail") ?? 0.35))
        var radius = try arguments.double("radius")
        if radius == nil {
            let composite = try Self.flattened(try await rendered(session.projectSnapshot()), over: .white)
            let input = AgentSendable(value: composite)
            let eye = try await Task.detached(priority: .userInitiated) { try AgentPortrait.faces(in: input.value).first?.eyeWidth }.value
            radius = eye.map { max(2, min(40, Double($0) * 0.22)) } ?? 6
        }
        let toDocument = BrushRaster.pixelToDocument(layer.transform, width: image.width, height: image.height)
        let scale = Double(abs(toDocument.a * toDocument.d - toDocument.b * toDocument.c).squareRoot())
        let pixelRadius = max(1, Int(((radius ?? 6) / max(scale, 0.0001)).rounded()))
        var area = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        if let selection = session.selection, !selection.isEmpty {
            let bounds = selection.path.boundingBoxOfPath.intersection(CGRect(x: 0, y: 0, width: document.width, height: document.height))
            area = bounds.applying(toDocument.inverted()).insetBy(dx: -CGFloat(pixelRadius * 2), dy: -CGFloat(pixelRadius * 2)).integral
                .intersection(area)
        }
        guard !area.isNull, area.width >= 3, area.height >= 3, let part = image.cropping(to: area) else {
            throw AgentError("The selection doesn’t cover this layer.")
        }
        guard area.width * area.height <= 16_000_000 else { throw AgentError("That’s a large area; select the skin first (smart_select face_skin or skin).") }
        let input = AgentSendable(value: part)
        let smoothed = try await Task.detached(priority: .userInitiated) {
            AgentSendable(value: try Self.smoothed(input.value, radius: pixelRadius, strength: strength, detail: detail))
        }.value.value
        let name = String(localized: "Smooth Skin")
        let changed = try await change(session, name) {
            guard let current = session.activeLayer else { return }
            await session.applyPixelEdit(to: current, name: name) { edit in
                try edit.paint { context in
                    context.concatenate(toDocument)
                    BrushRaster.draw(smoothed, in: area, mask: false, context: context)
                }
            }
        }
        var extra: JSONObject = ["radius": radius ?? 6]
        if session.selection == nil { extra["note"] = "Nothing was selected, so the whole layer was smoothed." }
        return outcome(session, changed: changed, layerID: layer.id, extra: extra)
    }

    /// A guided filter (He, Sun and Tang), the image guiding itself: flat areas averaged over `radius`, edges kept. Fine
    /// texture is added back by `detail`, and the result mixed over the original by `strength`.
    private nonisolated static func smoothed(_ image: CGImage, radius: Int, strength: Double, detail: Double) throws -> CGImage {
        let bitmap = try AgentBitmap(image)
        let width = bitmap.width, height = bitmap.height, count = width * height
        func box(_ values: [Double], _ r: Int) -> [Double] {
            var sums = [Double](repeating: 0, count: (width + 1) * (height + 1))
            for y in 0..<height {
                var row = 0.0
                for x in 0..<width {
                    row += values[y * width + x]
                    sums[(y + 1) * (width + 1) + x + 1] = sums[y * (width + 1) + x + 1] + row
                }
            }
            var result = [Double](repeating: 0, count: count)
            for y in 0..<height {
                let a = max(0, y - r), b = min(height, y + r + 1)
                for x in 0..<width {
                    let c = max(0, x - r), d = min(width, x + r + 1)
                    let total = sums[b * (width + 1) + d] - sums[a * (width + 1) + d] - sums[b * (width + 1) + c] + sums[a * (width + 1) + c]
                    result[y * width + x] = total / Double((b - a) * (d - c))
                }
            }
            return result
        }
        let epsilon = 0.0025
        var output = bitmap.bytes
        for channel in 0..<3 {
            let values = (0..<count).map { Double(bitmap.bytes[$0 * 4 + channel]) / 255 }
            let mean = box(values, radius)
            let squares = box(values.map { $0 * $0 }, radius)
            var a = [Double](repeating: 0, count: count), b = a
            for i in 0..<count {
                let variance = max(0, squares[i] - mean[i] * mean[i])
                a[i] = variance / (variance + epsilon)
                b[i] = mean[i] - a[i] * mean[i]
            }
            let meanA = box(a, radius), meanB = box(b, radius)
            let fine = box(values, 1)
            for i in 0..<count {
                let filtered = meanA[i] * values[i] + meanB[i] + detail * (values[i] - fine[i])
                let mixed = values[i] + strength * (filtered - values[i])
                output[i * 4 + channel] = UInt8(min(255, max(0, (mixed * 255).rounded())))
            }
        }
        // Back to premultiplied, as the layer keeps its pixels.
        for i in 0..<count {
            let alpha = Int(output[i * 4 + 3])
            guard alpha < 255 else { continue }
            for c in 0..<3 { output[i * 4 + c] = UInt8((Int(output[i * 4 + c]) * alpha + 127) / 255) }
        }
        return try Self.image(output, width: width, height: height)
    }
}
