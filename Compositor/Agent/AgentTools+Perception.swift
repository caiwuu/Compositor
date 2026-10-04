import AppKit
import UniformTypeIdentifiers

extension AgentTools {
    var perceptionTools: [AgentTool] {
        [
            AgentTool(name: "analyze_image", title: "Measure Image",
                description: "Measures what a picture can't tell you exactly: luminance and per-channel statistics (mean, spread, percentiles, histograms), clipped highlights and crushed shadows, a color cast in the midtones, saturation and colorfulness, the main colors, sharpness (variance of the Laplacian) and noise (its standard deviation, in levels of 255), and the opaque content's bounds, with hints on what looks off. Measures the canvas as it exports, or one layer's own pixels; optionally only a region or the selection. Use it before correcting tone or color, and again after, to check the correction worked.",
                schema: Schema.object([
                    "document_id": Schema.documentID,
                    "layer_id": Schema.string("Measure only this layer’s own pixels, unplaced; region is then in the layer’s pixels."),
                    "within_selection": Schema.boolean("Count only selected pixels (the canvas only)."),
                    "histogram_bins": Schema.integer("Bars in each histogram. Default 32.", minimum: 8, maximum: 256),
                ].merging(Schema.rect("the part to measure")) { a, _ in a }), readOnly: true) { [unowned self] arguments in
                    try await analyzeImage(arguments)
                },
            AgentTool(name: "sample_pixels", title: "Sample Pixels",
                description: "Reads the color at points of the canvas as it exports (averaged over a square around each with radius), and lists the layers that have pixels there, top first: each one's own color and alpha at the point, its mask value, opacity, blend mode and whether it shows. Use it to match colors for a repair, check a fill or mask, or find which layer makes something look the way it does.",
                schema: Schema.object([
                    "document_id": Schema.documentID,
                    "points": Schema.points,
                    "radius": Schema.integer("Average over the square this many pixels around each point. Default 0 (the one pixel).", minimum: 0, maximum: 50),
                    "layers": Schema.boolean("List the layers under each point. Default true."),
                ], required: ["points"]), readOnly: true) { [unowned self] arguments in
                    try await samplePixels(arguments)
                },
            AgentTool(name: "detect", title: "Detect Content",
                description: "Finds what's in the picture with the Mac's own Vision framework, as positions in document pixels: faces (with eyes, nose, mouth and eyebrows, head roll and yaw, capture quality), text (read in English and Chinese), salient regions (where the eye goes), the horizon's tilt and the rotation that levels it, separate foreground subjects, people, animals, rectangles such as documents or screens (corners, for perspective), and labels classifying the scene. Use it to find what to select, crop to, straighten or repair. Looks at the canvas as it exports, or a layer's own pixels, optionally a region.",
                schema: Schema.object([
                    "document_id": Schema.documentID,
                    "layer_id": Schema.string("Look at only this layer’s own pixels; positions are then in the layer’s pixels."),
                    "features": Schema.array("What to look for. Default faces, text, saliency, horizon, subjects, labels.",
                                             items: Schema.string("A feature.", choices: AgentVision.features)),
                ].merging(Schema.rect("the part to look at")) { a, _ in a }), readOnly: true) { [unowned self] arguments in
                    try await detect(arguments)
                },
            AgentTool(name: "compare", title: "Compare with Before",
                description: "Shows what your last steps changed: the canvas as it was steps_back undo steps ago beside how it is now, and a map of the changed pixels in red. Reports the fraction of pixels changed, their bounds, how much they changed and the mean luminance before and after, so you can check an edit stayed where it should and did what you meant. Nothing is undone.",
                schema: Schema.object([
                    "document_id": Schema.documentID,
                    "steps_back": Schema.integer("How many undo steps back to compare with. Default 1, the last change.", minimum: 1, maximum: 100),
                    "threshold": Schema.number("How different a pixel has to be to count as changed, 0 to 1. Default 0.02.", minimum: 0, maximum: 1),
                    "max_size": Schema.integer("Longest side of each picture. Default 768.", minimum: 64, maximum: 2048),
                ].merging(Schema.rect("the part to compare")) { a, _ in a }), readOnly: true) { [unowned self] arguments in
                    try await compare(arguments)
                },
        ]
    }

    // MARK: What the tools look at

    /// The canvas as it would export.
    func rendered(_ snapshot: ProjectSnapshot?) async throws -> CGImage {
        guard let snapshot else { throw AgentError("Nothing to show yet.") }
        return try await ImageExporter.shared.render(snapshot).image
    }

    /// What a perception tool looks at: the canvas, or with layer_id that layer's own pixels; cut to the region given.
    /// `origin` is where the picture's top-left is in the coordinates the caller uses.
    private func subject(_ arguments: AgentArguments, session: EditorSession) async throws -> (image: CGImage, origin: CGPoint, described: JSONObject) {
        _ = try canvas(session)
        var image: CGImage
        var described: JSONObject = [:]
        if let id = try arguments.uuid("layer_id") {
            let layer = try layer(id, in: session)
            guard let pixels = layer.asset?.image else { throw AgentError("“\(layer.name)” has no pixels of its own (it’s \(layerJSON(layer)["kind"] ?? "empty")).") }
            image = pixels
            described["layer_id"] = id.uuidString
            described["coordinates"] = "the layer’s own pixels"
        } else {
            image = try await rendered(session.projectSnapshot())
            described["coordinates"] = "document pixels"
        }
        var origin = CGPoint.zero
        if let region = try arguments.rect() {
            let bounds = region.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard !bounds.isNull, bounds.width >= 1, bounds.height >= 1, let cropped = image.cropping(to: bounds) else {
                throw AgentError("That region is outside the \(image.width) × \(image.height) \(described["layer_id"] == nil ? "canvas" : "layer").")
            }
            image = cropped
            origin = bounds.origin
            described["region"] = ["x": bounds.minX, "y": bounds.minY, "width": bounds.width, "height": bounds.height]
        }
        return (image, origin, described)
    }

    // MARK: Tools

    private func analyzeImage(_ arguments: AgentArguments) async throws -> AgentResult {
        let session = try tab(arguments).session
        let document = try canvas(session)
        let (image, origin, described) = try await subject(arguments, session: session)
        var coverage: CGImage?
        if try arguments.bool("within_selection") == true {
            guard described["layer_id"] == nil else { throw AgentError("within_selection measures the canvas; leave out layer_id.") }
            guard let selection = session.selection, !selection.isEmpty else { throw AgentError("Nothing is selected.") }
            let full = try selection.coverage(width: document.width, height: document.height)
            coverage = full.cropping(to: CGRect(origin: origin, size: CGSize(width: image.width, height: image.height)))
        }
        var bins = 32
        if let asked = try arguments.int("histogram_bins") { bins = [8, 16, 32, 64, 128, 256].last { $0 <= asked } ?? 8 }
        let input = AgentSendable(value: (image, coverage, bins))
        let measured = try await Task.detached(priority: .userInitiated) {
            AgentSendable(value: try AgentPixels.analyze(input.value.0, coverage: input.value.1, bins: input.value.2))
        }.value.value
        var result = described.merging(measured) { a, _ in a }
        if let bounds = try await Task.detached(priority: .userInitiated, operation: { try AgentPixels.contentBounds(input.value.0) }).value {
            result["content_bounds"] = ["x": bounds.minX + origin.x, "y": bounds.minY + origin.y, "width": bounds.width, "height": bounds.height]
        } else {
            result["content_bounds"] = NSNull()
        }
        if var detail = result["detail"] as? JSONObject, let measuredRect = detail["measured"] as? JSONObject,
           let x = measuredRect["x"] as? CGFloat, let y = measuredRect["y"] as? CGFloat {
            detail["measured"] = measuredRect.merging(["x": x + origin.x, "y": y + origin.y]) { _, new in new }
            result["detail"] = detail
        }
        return AgentResult(value: result)
    }

    private func samplePixels(_ arguments: AgentArguments) async throws -> AgentResult {
        let session = try tab(arguments).session
        let document = try canvas(session)
        guard let points = try arguments.points("points"), !points.isEmpty else { throw AgentError("Give at least one point.") }
        guard points.count <= 100 else { throw AgentError("Sample up to 100 points at a time.") }
        let radius = min(50, max(0, try arguments.int("radius") ?? 0))
        let listLayers = try arguments.bool("layers") ?? true
        let image = try await rendered(session.projectSnapshot())
        let input = AgentSendable(value: image)
        let bitmap = try await Task.detached(priority: .userInitiated) { AgentSendable(value: try AgentBitmap(input.value)) }.value.value
        let visible = document.effectiveVisibleIDs
        let byID = Dictionary(uniqueKeysWithValues: document.layers.map { ($0.id, $0) })
        let stack = LayerHierarchy.entries(document.layers.map(\.hierarchyRecord), topFirst: true).compactMap { byID[$0.layer.id] }
        let samples = try points.map { point -> JSONObject in
            var json: JSONObject = ["x": point.x, "y": point.y]
            guard let color = bitmap.average(x: Int(point.x.rounded(.down)), y: Int(point.y.rounded(.down)), radius: radius) else {
                json["outside_canvas"] = true
                return json
            }
            json["color"] = AgentColor.hex(red: color.r / 255, green: color.g / 255, blue: color.b / 255)
            json["rgb"] = [Int(color.r.rounded()), Int(color.g.rounded()), Int(color.b.rounded())]
            json["alpha"] = color.a
            json["luminance"] = AgentPixels.luma(Int(color.r), Int(color.g), Int(color.b))
            if listLayers {
                json["layers"] = try stack.compactMap { try layerSample($0, at: point, shown: visible.contains($0.id)) }
            }
            return json
        }
        return AgentResult(value: ["samples": samples, "radius": radius])
    }

    /// `layer`'s own pixel under `point` (document pixels), with its mask there; nil when it has nothing there.
    private func layerSample(_ layer: ImageLayer, at point: CGPoint, shown: Bool) throws -> JSONObject? {
        guard let image = layer.asset?.image, layer.adjustment == nil else { return nil }
        func value(_ image: CGImage, _ transform: LayerTransform) throws -> (r: Int, g: Int, b: Int, a: Int)? {
            let unit = point.applying(transform.unitToDocument.inverted())
            guard (0..<1).contains(unit.x), (0..<1).contains(unit.y) else { return nil }
            let x = Int(unit.x * CGFloat(image.width)), y = Int(unit.y * CGFloat(image.height))
            guard let pixel = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }
            return try AgentBitmap(pixel).pixel(0, 0)
        }
        guard let own = try value(image, layer.transform), own.a > 0 else { return nil }
        var json: JSONObject = ["id": layer.id.uuidString, "name": layer.name, "shown": shown,
                                "color": AgentColor.hex(red: CGFloat(own.r) / 255, green: CGFloat(own.g) / 255, blue: CGFloat(own.b) / 255),
                                "alpha": Double(own.a) / 255, "opacity": layer.opacity, "blend_mode": layer.blendMode.rawValue]
        if let mask = layer.mask {
            let covered = try value(mask.asset.image, mask.placement ?? layer.transform)
            json["mask"] = mask.isEnabled ? Double(covered?.r ?? 0) / 255 as Any : "disabled"
        }
        return json
    }

    private func detect(_ arguments: AgentArguments) async throws -> AgentResult {
        let session = try tab(arguments).session
        _ = try canvas(session)
        var features = AgentVision.defaultFeatures
        if let asked = try arguments.array("features") {
            let names = asked.compactMap { $0 as? String }
            let unknown = names.filter { !AgentVision.features.contains($0) }
            guard unknown.isEmpty, !names.isEmpty else {
                throw AgentError("features can be: \(AgentVision.features.joined(separator: ", ")).")
            }
            features = Set(names)
        }
        let (image, origin, described) = try await subject(arguments, session: session)
        // Vision reads transparency as black, so the picture is put over white first.
        let flat = try Self.flattened(image, over: .white)
        let input = AgentSendable(value: (flat, features, origin))
        let found = try await Task.detached(priority: .userInitiated) {
            AgentSendable(value: try AgentVision.detect(input.value.0, features: input.value.1, offset: input.value.2))
        }.value.value
        return AgentResult(value: described.merging(found) { a, _ in a })
    }

    private func compare(_ arguments: AgentArguments) async throws -> AgentResult {
        let session = try tab(arguments).session
        _ = try canvas(session)
        let steps = try arguments.int("steps_back") ?? 1
        guard let earlier = session.history.earlier(steps) else {
            throw AgentError("There \(session.history.undoCount == 1 ? "is 1 step" : "are \(session.history.undoCount) steps") to go back; steps_back can’t be more.")
        }
        guard let old = earlier.document else { throw AgentError("\(steps) steps back the document had no canvas yet.") }
        let threshold = try arguments.double("threshold") ?? 0.02
        let longSide = min(2048, max(64, try arguments.int("max_size") ?? 768))
        var before = try await rendered(session.projectSnapshot(of: old))
        var after = try await rendered(session.projectSnapshot())
        var result: JSONObject = ["steps": earlier.names, "before_size": ["width": before.width, "height": before.height],
                                  "after_size": ["width": after.width, "height": after.height]]
        var origin = CGPoint.zero
        if let region = try arguments.rect() {
            let bounds = region.integral.intersection(CGRect(x: 0, y: 0, width: min(before.width, after.width), height: min(before.height, after.height)))
            guard !bounds.isNull, bounds.width >= 1, bounds.height >= 1,
                  let a = before.cropping(to: bounds), let b = after.cropping(to: bounds) else { throw AgentError("That region is outside the canvas.") }
            before = a; after = b
            origin = bounds.origin
            result["region"] = ["x": bounds.minX, "y": bounds.minY, "width": bounds.width, "height": bounds.height]
        }
        var images: [AgentImage] = []
        let pair = try sideBySide(try Self.scaled(before, longSide: longSide), try Self.scaled(after, longSide: longSide))
        images.append(AgentImage(data: try Self.encode(pair, as: .jpeg, background: PaletteColor(red: 0.5, green: 0.5, blue: 0.5)), mimeType: "image/jpeg"))
        if before.width == after.width, before.height == after.height {
            let input = AgentSendable(value: (before, after, threshold))
            let (measured, map) = try await Task.detached(priority: .userInitiated) {
                AgentSendable(value: try AgentPixels.difference(input.value.0, input.value.1, threshold: input.value.2))
            }.value.value
            var difference = measured
            if let bounds = difference["changed_bounds"] as? JSONObject, let x = bounds["x"] as? Double, let y = bounds["y"] as? Double {
                difference["changed_bounds"] = bounds.merging(["x": x + origin.x, "y": y + origin.y]) { _, new in new }
            }
            result["difference"] = difference
            images.append(AgentImage(data: try Self.encode(try Self.scaled(map, longSide: longSide), as: .jpeg), mimeType: "image/jpeg"))
            result["pictures"] = "First: before (left) and after (right). Second: changed pixels in red over a faded after."
        } else {
            result["pictures"] = "Before (left) and after (right). The canvas changed size, so there is no map of changed pixels."
        }
        return AgentResult(value: result, images: images)
    }

    /// `left` and `right` beside each other, labeled Before and After.
    private func sideBySide(_ left: CGImage, _ right: CGImage) throws -> CGImage {
        let gap = 12, label = 22
        let width = left.width + gap + right.width, height = max(left.height, right.height) + label
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ExportError.render }
        context.setFillColor(gray: 0.18, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let top = CGFloat(height - label)
        context.draw(left, in: CGRect(x: 0, y: top - CGFloat(left.height), width: CGFloat(left.width), height: CGFloat(left.height)))
        context.draw(right, in: CGRect(x: CGFloat(left.width + gap), y: top - CGFloat(right.height), width: CGFloat(right.width), height: CGFloat(right.height)))
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: NSColor.white]
        ("Before" as NSString).draw(at: CGPoint(x: 6, y: top + 3), withAttributes: attributes)
        ("After" as NSString).draw(at: CGPoint(x: CGFloat(left.width + gap + 6), y: top + 3), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { throw ExportError.render }
        return image
    }

    // MARK: Marks on a picture of the canvas

    /// The opaque part of `layer`'s own pixels as placed on the canvas: its four corners in document pixels, and their bounds.
    /// Nil for a layer without pixels or with none opaque.
    func contentPlacement(_ layer: ImageLayer) -> (corners: [CGPoint], bounds: CGRect)? {
        guard let image = layer.asset?.image else { return nil }
        let key = ObjectIdentifier(image)
        let local: CGRect?
        if let cached = contentBoundsCache[key], cached.image === image {
            local = cached.bounds
        } else {
            local = try? AgentPixels.contentBounds(image)
            if contentBoundsCache.count > 256 { contentBoundsCache.removeAll() }
            contentBoundsCache[key] = (image, local)
        }
        guard let local else { return nil }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let map = layer.transform.unitToDocument
        let corners = [CGPoint(x: local.minX / w, y: local.minY / h), CGPoint(x: local.maxX / w, y: local.minY / h),
                       CGPoint(x: local.maxX / w, y: local.maxY / h), CGPoint(x: local.minX / w, y: local.maxY / h)].map { $0.applying(map) }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        let bounds = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        return (corners, bounds)
    }

    /// A round spacing for grid lines, about eight across `length`.
    static func gridSpacing(for length: CGFloat) -> CGFloat {
        let raw = max(1, length / 8)
        let power = pow(10, floor(log10(raw)))
        return [1, 2, 5, 10].map { $0 * power }.first { $0 >= raw } ?? raw
    }

    /// `picture` (showing `origin` onward at `scale` pictures pixels per pixel) with a labeled coordinate grid, the
    /// selection's outline, and outlines around layers' content.
    func marked(_ picture: CGImage, scale: CGFloat, origin: CGPoint, grid: CGFloat?, selection: CGPath?,
                outlines: [(name: String, corners: [CGPoint])]) throws -> CGImage {
        let width = picture.width, height = picture.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ExportError.render }
        context.draw(picture, in: CGRect(x: 0, y: 0, width: width, height: height))
        // From here on y runs down, as in the document.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        func place(_ point: CGPoint) -> CGPoint { CGPoint(x: (point.x - origin.x) * scale, y: (point.y - origin.y) * scale) }
        let graphics = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        defer { NSGraphicsContext.restoreGraphicsState() }
        func tag(_ text: String, at point: CGPoint, color: NSColor = .white) {
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold), .foregroundColor: color]
            let string = text as NSString
            let size = string.size(withAttributes: attributes)
            let box = CGRect(x: point.x, y: point.y, width: size.width + 6, height: size.height + 2)
            context.setFillColor(NSColor.black.withAlphaComponent(0.65).cgColor)
            context.fill(box)
            string.draw(at: CGPoint(x: box.minX + 3, y: box.minY + 1), withAttributes: attributes)
        }
        if let grid {
            let visible = CGRect(x: origin.x, y: origin.y, width: CGFloat(width) / scale, height: CGFloat(height) / scale)
            let lines = CGMutablePath()
            var labels: [(String, CGPoint)] = []
            var x = (visible.minX / grid).rounded(.up) * grid
            while x <= visible.maxX {
                let at = place(CGPoint(x: x, y: 0)).x
                lines.move(to: CGPoint(x: at, y: 0)); lines.addLine(to: CGPoint(x: at, y: CGFloat(height)))
                labels.append(("\(Int(x))", CGPoint(x: at + 2, y: 2)))
                x += grid
            }
            var y = (visible.minY / grid).rounded(.up) * grid
            while y <= visible.maxY {
                let at = place(CGPoint(x: 0, y: y)).y
                lines.move(to: CGPoint(x: 0, y: at)); lines.addLine(to: CGPoint(x: CGFloat(width), y: at))
                if y > visible.minY + grid / 2 { labels.append(("\(Int(y))", CGPoint(x: 2, y: at + 2))) }
                y += grid
            }
            context.setLineWidth(1)
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.45).cgColor)
            context.addPath(lines)
            context.strokePath()
            context.setLineDash(phase: 0, lengths: [4, 4])
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.8).cgColor)
            context.addPath(lines)
            context.strokePath()
            context.setLineDash(phase: 0, lengths: [])
            for (text, point) in labels { tag(text, at: point) }
        }
        if let selection {
            var toPicture = CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: -origin.x, y: -origin.y)
            if let path = selection.copy(using: &toPicture) {
                context.setLineWidth(1.5)
                context.setStrokeColor(NSColor.white.cgColor)
                context.addPath(path)
                context.strokePath()
                context.setLineDash(phase: 0, lengths: [5, 5])
                context.setStrokeColor(NSColor.black.cgColor)
                context.addPath(path)
                context.strokePath()
                context.setLineDash(phase: 0, lengths: [])
            }
        }
        let colors: [NSColor] = [.systemRed, .systemCyan, .systemYellow, .systemPink, .systemGreen, .systemOrange]
        for (index, outline) in outlines.enumerated() {
            let color = colors[index % colors.count]
            let points = outline.corners.map(place)
            context.setLineWidth(2)
            context.setStrokeColor(color.cgColor)
            context.addLines(between: points)
            context.closePath()
            context.strokePath()
            if let first = points.min(by: { $0.y + $0.x < $1.y + $1.x }) {
                tag(outline.name, at: CGPoint(x: max(0, first.x), y: max(0, first.y - 16)), color: color)
            }
        }
        guard let image = context.makeImage() else { throw ExportError.render }
        return image
    }
}
