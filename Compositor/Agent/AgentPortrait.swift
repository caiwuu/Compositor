import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Vision

/// A face Vision found, in the picture's pixels with y down.
nonisolated struct AgentFace: @unchecked Sendable {
    let bounds: CGRect
    let confidence: Float
    let roll: Double?
    let yaw: Double?
    /// Outlines and lines by name: face_contour (ear to ear under the chin), eyes, eyebrows, nose, nose_crest,
    /// median_line, outer_lips, inner_lips, pupils.
    let regions: [String: [CGPoint]]

    var eyeWidth: CGFloat {
        guard let eye = regions["left_eye"] ?? regions["right_eye"], let minX = eye.map(\.x).min(), let maxX = eye.map(\.x).max() else {
            return bounds.width / 5
        }
        return maxX - minX
    }
}

/// What portrait retouching needs to know about a picture: faces in detail, the person, their skin, pose and arms, and
/// blemishes. Positions are the picture's pixels from its top-left corner.
nonisolated enum AgentPortrait {
    static let faceParts = ["face", "face_skin", "lips", "mouth", "eyes", "left_eye", "right_eye", "eyebrows", "nose"]

    // MARK: Faces

    static func faces(in image: CGImage) throws -> [AgentFace] {
        let request = VNDetectFaceLandmarksRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let size = CGSize(width: image.width, height: image.height)
        return (request.results ?? []).map { face in
            let box = VNImageRectForNormalizedRect(face.boundingBox, image.width, image.height)
            var regions: [String: [CGPoint]] = [:]
            if let marks = face.landmarks {
                let named: [(String, VNFaceLandmarkRegion2D?)] = [
                    ("face_contour", marks.faceContour), ("left_eye", marks.leftEye), ("right_eye", marks.rightEye),
                    ("left_eyebrow", marks.leftEyebrow), ("right_eyebrow", marks.rightEyebrow), ("nose", marks.nose),
                    ("nose_crest", marks.noseCrest), ("median_line", marks.medianLine), ("outer_lips", marks.outerLips),
                    ("inner_lips", marks.innerLips), ("left_pupil", marks.leftPupil), ("right_pupil", marks.rightPupil),
                ]
                for (name, region) in named {
                    guard let region, region.pointCount > 0 else { continue }
                    regions[name] = region.pointsInImage(imageSize: size).map { CGPoint(x: $0.x, y: size.height - $0.y) }
                }
            }
            return AgentFace(bounds: CGRect(x: box.minX, y: size.height - box.maxY, width: box.width, height: box.height),
                             confidence: face.confidence, roll: face.roll.map { $0.doubleValue * 180 / .pi },
                             yaw: face.yaw.map { $0.doubleValue * 180 / .pi }, regions: regions)
        }.sorted { $0.bounds.width * $0.bounds.height > $1.bounds.width * $1.bounds.height }
    }

    static func describe(_ face: AgentFace, offset: CGPoint) -> JSONObject {
        func point(_ p: CGPoint) -> [Double] { [Double(((p.x + offset.x) * 10).rounded() / 10), Double(((p.y + offset.y) * 10).rounded() / 10)] }
        func center(_ points: [CGPoint]) -> CGPoint {
            CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count), y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
        }
        var landmarks: JSONObject = [:]
        for key in ["left_eye", "right_eye", "nose", "outer_lips", "left_eyebrow", "right_eyebrow", "left_pupil", "right_pupil"] {
            if let points = face.regions[key], !points.isEmpty { landmarks[key == "outer_lips" ? "mouth" : key] = point(center(points)) }
        }
        return ["bounds": ["x": (face.bounds.minX + offset.x).rounded(), "y": (face.bounds.minY + offset.y).rounded(),
                           "width": face.bounds.width.rounded(), "height": face.bounds.height.rounded()],
                "confidence": face.confidence, "roll_degrees": AgentTools.orNull(face.roll), "yaw_degrees": AgentTools.orNull(face.yaw),
                "landmarks": landmarks, "contours": face.regions.mapValues { $0.map(point) }]
    }

    /// The outline of part of `face`, in the picture's pixels. Nil when Vision didn't find that part.
    static func path(of part: String, in face: AgentFace) -> CGPath? {
        func polygon(_ key: String) -> CGPath? {
            guard let points = face.regions[key], points.count >= 3 else { return nil }
            let path = CGMutablePath()
            path.addLines(between: points)
            path.closeSubpath()
            return path
        }
        func union(_ paths: [CGPath?]) -> CGPath? {
            paths.compactMap { $0 }.reduce(nil as CGPath?) { sum, path in sum.map { $0.union(path, using: .winding) } ?? path }
        }
        // Eyebrows are thin outlines; given some thickness they cover the hairs.
        func brow(_ key: String) -> CGPath? {
            guard let outline = polygon(key) else { return nil }
            return outline.union(outline.copy(strokingWithWidth: face.eyeWidth * 0.18, lineCap: .round, lineJoin: .round, miterLimit: 1))
        }
        switch part {
        case "lips":
            guard let outer = polygon("outer_lips") else { return nil }
            return polygon("inner_lips").map { outer.subtracting($0) } ?? outer
        case "mouth": return polygon("inner_lips")
        case "left_eye": return polygon("left_eye")
        case "right_eye": return polygon("right_eye")
        case "eyes": return union([polygon("left_eye"), polygon("right_eye")])
        case "eyebrows": return union([brow("left_eyebrow"), brow("right_eyebrow")])
        case "nose":
            guard let nose = face.regions["nose"], let crest = face.regions["nose_crest"] else { return polygon("nose") }
            return hull(nose + crest).map(closed)
        case "face": return faceOutline(face)
        case "face_skin":
            guard let outline = faceOutline(face) else { return nil }
            let width = face.eyeWidth
            let features = union([polygon("left_eye"), polygon("right_eye"), brow("left_eyebrow"), brow("right_eyebrow"), polygon("outer_lips")])
            let grown = features.map { $0.union($0.copy(strokingWithWidth: width * 0.25, lineCap: .round, lineJoin: .round, miterLimit: 1)) }
            return grown.map { outline.subtracting($0) } ?? outline
        default: return nil
        }
    }

    /// The face from the jaw up over the forehead, which Vision's contour stops short of: the contour, the eyebrows,
    /// and the eyebrows raised by half the distance from them to the chin.
    private static func faceOutline(_ face: AgentFace) -> CGPath? {
        guard let contour = face.regions["face_contour"], contour.count >= 3 else { return nil }
        let brows = (face.regions["left_eyebrow"] ?? []) + (face.regions["right_eyebrow"] ?? [])
        guard !brows.isEmpty else { return hull(contour).map(closed) }
        let middle = CGPoint(x: brows.map(\.x).reduce(0, +) / CGFloat(brows.count), y: brows.map(\.y).reduce(0, +) / CGFloat(brows.count))
        let chin = contour.max { hypot($0.x - middle.x, $0.y - middle.y) < hypot($1.x - middle.x, $1.y - middle.y) }!
        let up = CGPoint(x: (middle.x - chin.x) * 0.5, y: (middle.y - chin.y) * 0.5)
        return hull(contour + brows + brows.map { CGPoint(x: $0.x + up.x, y: $0.y + up.y) }).map(closed)
    }

    private static func closed(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: points)
        path.closeSubpath()
        return path
    }

    /// The convex hull, by Andrew's monotone chain.
    static func hull(_ points: [CGPoint]) -> [CGPoint]? {
        let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard sorted.count >= 3 else { return nil }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        var lower: [CGPoint] = [], upper: [CGPoint] = []
        for p in sorted {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        for p in sorted.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    // MARK: The person and their skin

    /// Where people are, one byte per pixel of `image` (255 is a person), with edges following the picture's. Empty when
    /// no person is found: segmentation alone marks something in any picture.
    static func personMask(_ image: CGImage) throws -> [UInt8] {
        let empty = [UInt8](repeating: 0, count: image.width * image.height)
        let humans = VNDetectHumanRectanglesRequest()
        humans.upperBodyOnly = false
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let faces = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([humans, faces, request])
        guard humans.results?.isEmpty == false || faces.results?.isEmpty == false else { return empty }
        guard let buffer = request.results?.first?.pixelBuffer else { return empty }
        let coarse = CIImage(cvPixelBuffer: buffer)
        var refined = coarse.transformed(by: CGAffineTransform(scaleX: CGFloat(image.width) / coarse.extent.width,
                                                               y: CGFloat(image.height) / coarse.extent.height))
        if let filter = CIFilter(name: "CIEdgePreserveUpsampleFilter") {
            filter.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
            filter.setValue(coarse, forKey: "inputSmallImage")
            filter.setValue(5, forKey: "inputSpatialSigma")
            filter.setValue(0.15, forKey: "inputLumaSigma")
            if let output = filter.outputImage { refined = output }
        }
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        guard let rendered = context.createCGImage(refined, from: CGRect(x: 0, y: 0, width: image.width, height: image.height)) else {
            throw ExportError.render
        }
        return try AgentBitmap.gray(rendered, width: image.width, height: image.height).map { $0 >= 128 ? 255 : 0 }
    }

    /// Skin, one byte per pixel (255 is skin): colors near the faces' own skin (or, with no face, a usual skin range) in
    /// chroma, within `person` when given, with specks cleaned away.
    static func skinMask(_ bitmap: AgentBitmap, faces: [AgentFace], person: [UInt8]?) -> [UInt8] {
        let width = bitmap.width, height = bitmap.height
        func chroma(_ index: Int) -> (cb: Double, cr: Double, y: Double) {
            let r = Double(bitmap.bytes[index * 4]), g = Double(bitmap.bytes[index * 4 + 1]), b = Double(bitmap.bytes[index * 4 + 2])
            return (128 - 0.168736 * r - 0.331264 * g + 0.5 * b, 128 + 0.5 * r - 0.418688 * g - 0.081312 * b, 0.299 * r + 0.587 * g + 0.114 * b)
        }
        // The faces' skin sets what counts, so dark, light, warm and cool skin are all found.
        var cb = (mean: 110.0, spread: 9.0), cr = (mean: 152.0, spread: 11.0), darkest = 25.0
        let samples = faces.compactMap { path(of: "face_skin", in: $0) }
        if !samples.isEmpty, let sample = rasterized(samples, width: width, height: height) {
            var n = 0.0, sb = 0.0, sr = 0.0, sb2 = 0.0, sr2 = 0.0, sy = 0.0
            for index in 0..<(width * height) where sample[index] != 0 && bitmap.bytes[index * 4 + 3] > 200 {
                let c = chroma(index)
                n += 1; sb += c.cb; sr += c.cr; sb2 += c.cb * c.cb; sr2 += c.cr * c.cr; sy += c.y
            }
            if n > 50 {
                cb = (sb / n, max(4, (sb2 / n - (sb / n) * (sb / n)).squareRoot()))
                cr = (sr / n, max(4, (sr2 / n - (sr / n) * (sr / n)).squareRoot()))
                // Dark hair can share skin's hue; skin in shadow is rarely under half the face's brightness.
                darkest = max(darkest, sy / n * 0.5)
            }
        }
        var mask = [UInt8](repeating: 0, count: width * height)
        for index in 0..<(width * height) where bitmap.bytes[index * 4 + 3] > 128 && (person.map { $0[index] != 0 } ?? true) {
            let c = chroma(index)
            let distance = pow((c.cb - cb.mean) / cb.spread, 2) + pow((c.cr - cr.mean) / cr.spread, 2)
            if distance < 6.25, c.y > darkest { mask[index] = 255 }
        }
        return majority(mask, width: width, height: height, radius: 2)
    }

    /// `paths` filled, one byte per pixel.
    static func rasterized(_ paths: [CGPath], width: Int, height: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: width * height)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.setFillColor(gray: 1, alpha: 1)
            for path in paths { context.addPath(path) }
            context.fillPath(using: .winding)
            return true
        }
        return drawn ? bytes.map { $0 >= 128 ? 255 : 0 } : nil
    }

    /// Each pixel set when most of the square `radius` around it is: specks go, holes close.
    private static func majority(_ mask: [UInt8], width: Int, height: Int, radius: Int) -> [UInt8] {
        var sums = [Int](repeating: 0, count: (width + 1) * (height + 1))
        for y in 0..<height {
            var row = 0
            for x in 0..<width {
                row += mask[y * width + x] != 0 ? 1 : 0
                sums[(y + 1) * (width + 1) + x + 1] = sums[y * (width + 1) + x + 1] + row
            }
        }
        var result = mask
        for y in 0..<height {
            let y0 = max(0, y - radius), y1 = min(height, y + radius + 1)
            for x in 0..<width {
                let x0 = max(0, x - radius), x1 = min(width, x + radius + 1)
                let count = sums[y1 * (width + 1) + x1] - sums[y0 * (width + 1) + x1] - sums[y1 * (width + 1) + x0] + sums[y0 * (width + 1) + x0]
                result[y * width + x] = count * 2 > (y1 - y0) * (x1 - x0) ? 255 : 0
            }
        }
        return result
    }

    // MARK: Pose and arms

    private static let joints: [(VNHumanBodyPoseObservation.JointName, String)] = [
        (.nose, "nose"), (.leftEye, "left_eye"), (.rightEye, "right_eye"), (.leftEar, "left_ear"), (.rightEar, "right_ear"),
        (.neck, "neck"), (.leftShoulder, "left_shoulder"), (.rightShoulder, "right_shoulder"), (.leftElbow, "left_elbow"),
        (.rightElbow, "right_elbow"), (.leftWrist, "left_wrist"), (.rightWrist, "right_wrist"), (.root, "root"),
        (.leftHip, "left_hip"), (.rightHip, "right_hip"), (.leftKnee, "left_knee"), (.rightKnee, "right_knee"),
        (.leftAnkle, "left_ankle"), (.rightAnkle, "right_ankle"),
    ]

    /// Each person's joints Vision is fairly sure of, by name (left and right are the person's own).
    static func poses(in image: CGImage) throws -> [[String: (point: CGPoint, confidence: Float)]] {
        let request = VNDetectHumanBodyPoseRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return try (request.results ?? []).map { observation in
            let found = try observation.recognizedPoints(.all)
            var result: [String: (CGPoint, Float)] = [:]
            for (joint, name) in joints {
                guard let point = found[joint], point.confidence > 0.2 else { continue }
                result[name] = (CGPoint(x: point.location.x * CGFloat(image.width), y: (1 - point.location.y) * CGFloat(image.height)), point.confidence)
            }
            return result
        }
    }

    /// Across each arm at a few places along the upper arm and forearm: the arm's two edges, and its width there. A bare
    /// arm ends where its skin does, which parts it from clothes and a body it rests against; a sleeve ends where the
    /// person does. An edge that runs into the body (or past where an arm could reach) is marked, as its width is no guide.
    static func arms(_ pose: [String: (point: CGPoint, confidence: Float)], person: [UInt8], skin: [UInt8], width: Int, height: Int,
                     offset: CGPoint) -> JSONObject {
        var bare = false
        func inside(_ p: CGPoint) -> Bool {
            let x = Int(p.x), y = Int(p.y)
            guard (0..<width).contains(x), (0..<height).contains(y) else { return false }
            return (bare ? skin : person)[y * width + x] != 0
        }
        func round(_ p: CGPoint) -> [Double] { [Double((p.x + offset.x).rounded()), Double((p.y + offset.y).rounded())] }
        var result: JSONObject = [:]
        for side in ["left", "right"] {
            var segments: [JSONObject] = []
            for (name, from, to) in [("upper_arm", "\(side)_shoulder", "\(side)_elbow"), ("forearm", "\(side)_elbow", "\(side)_wrist")] {
                guard let a = pose[from]?.point, let b = pose[to]?.point else { continue }
                let length = hypot(b.x - a.x, b.y - a.y)
                guard length > 4 else { continue }
                let along = CGPoint(x: (b.x - a.x) / length, y: (b.y - a.y) / length), across = CGPoint(x: -along.y, y: along.x)
                let reach = length * 0.45
                var samples: [JSONObject] = []
                for t in [0.2, 0.35, 0.5, 0.65, 0.8] {
                    let center = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                    bare = false
                    guard inside(center) else { continue }
                    bare = skin[Int(center.y) * width + Int(center.x)] != 0
                    func edge(_ sign: CGFloat) -> (point: CGPoint, open: Bool) {
                        var distance: CGFloat = 0
                        while distance < reach {
                            let next = CGPoint(x: center.x + across.x * sign * (distance + 1), y: center.y + across.y * sign * (distance + 1))
                            if !inside(next) { return (CGPoint(x: center.x + across.x * sign * distance, y: center.y + across.y * sign * distance), false) }
                            distance += 1
                        }
                        return (CGPoint(x: center.x + across.x * sign * reach, y: center.y + across.y * sign * reach), true)
                    }
                    let one = edge(1), two = edge(-1)
                    var sample: JSONObject = ["at": t, "center": round(center), "edge_a": round(one.point), "edge_b": round(two.point),
                                              "width": Double(hypot(one.point.x - two.point.x, one.point.y - two.point.y).rounded())]
                    if one.open { sample["edge_a_touches_body"] = true }
                    if two.open { sample["edge_b_touches_body"] = true }
                    if bare { sample["bare"] = true }
                    samples.append(sample)
                }
                segments.append(["segment": name, "from": round(a), "to": round(b), "across": [Double(across.x), Double(across.y)], "samples": samples])
            }
            if !segments.isEmpty { result["\(side)_arm"] = segments }
        }
        return result
    }

    // MARK: Skin detail

    /// The face's skin: its average color, how even it is, its redness, and small dark spots on it (blemishes, moles)
    /// with their size, darkest first. `skin` is the face's skin, one byte per pixel of `bitmap`.
    static func skinReport(_ bitmap: AgentBitmap, face: AgentFace, skin: [UInt8], offset: CGPoint) -> JSONObject {
        let width = bitmap.width, height = bitmap.height
        let box = face.bounds.insetBy(dx: -face.bounds.width * 0.1, dy: -face.bounds.height * 0.3).integral
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !box.isNull, box.width > 8, box.height > 8 else { return [:] }
        let x0 = Int(box.minX), y0 = Int(box.minY), w = Int(box.width), h = Int(box.height)
        var luma = [Double](repeating: 0, count: w * h), redness = [Double](repeating: 0, count: w * h)
        var inside = [Bool](repeating: false, count: w * h)
        var n = 0.0, sr = 0.0, sg = 0.0, sb = 0.0, sl = 0.0, sl2 = 0.0, red = 0.0
        for y in 0..<h {
            for x in 0..<w {
                let index = (y + y0) * width + x + x0
                let p = bitmap.pixel(x + x0, y + y0)
                let l = 0.2126 * Double(p.r) + 0.7152 * Double(p.g) + 0.0722 * Double(p.b)
                let cr = 0.5 * Double(p.r) - 0.418688 * Double(p.g) - 0.081312 * Double(p.b)
                luma[y * w + x] = l
                redness[y * w + x] = cr
                guard skin[index] != 0 else { continue }
                inside[y * w + x] = true
                n += 1; sr += Double(p.r); sg += Double(p.g); sb += Double(p.b); sl += l; sl2 += l * l
                red += cr
            }
        }
        guard n > 100 else { return ["note": "Too little skin showing on this face to measure."] }
        func integral(_ value: (Int) -> Double) -> [Double] {
            var sums = [Double](repeating: 0, count: (w + 1) * (h + 1))
            for y in 0..<h {
                var row = 0.0
                for x in 0..<w {
                    row += value(y * w + x)
                    sums[(y + 1) * (w + 1) + x + 1] = sums[y * (w + 1) + x + 1] + row
                }
            }
            return sums
        }
        func total(_ sums: [Double], _ x: Int, _ y: Int, _ radius: Int) -> Double {
            let a = max(0, y - radius), b = min(h, y + radius + 1), c = max(0, x - radius), d = min(w, x + radius + 1)
            return sums[b * (w + 1) + d] - sums[a * (w + 1) + d] - sums[b * (w + 1) + c] + sums[a * (w + 1) + c]
        }
        let counts = integral { inside[$0] ? 1 : 0 }
        let lumas = integral { inside[$0] ? luma[$0] : 0 }, reds = integral { inside[$0] ? redness[$0] : 0 }
        // Spots are only looked for well inside the skin, where the edges of eyes, nostrils, lips and hair can't pass for one.
        let margin = max(2, Int(face.eyeWidth * 0.12))
        var nostrils = [UInt8](repeating: 0, count: w * h)
        if let nose = face.regions["nose"], nose.count >= 3 {
            let shifted = nose.map { CGPoint(x: $0.x - CGFloat(x0), y: $0.y - CGFloat(y0)) }
            let outline = closed(shifted)
            let grown = outline.union(outline.copy(strokingWithWidth: face.eyeWidth * 0.3, lineCap: .round, lineJoin: .round, miterLimit: 1))
            nostrils = rasterized([grown], width: w, height: h) ?? nostrils
        }
        var candidate = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            for x in 0..<w where inside[y * w + x] && nostrils[y * w + x] == 0 {
                let side = min(h, y + margin + 1) - max(0, y - margin), across = min(w, x + margin + 1) - max(0, x - margin)
                candidate[y * w + x] = total(counts, x, y, margin) == Double(side * across)
            }
        }
        // Spots stand out from the skin around them, darker (moles, marks) or redder (blemishes), against a local
        // average a few spots across.
        let radius = max(3, Int(face.eyeWidth * 0.35))
        var contrast = [Double](repeating: 0, count: w * h)
        var deviations = 0.0, deviationCount = 0.0
        for y in 0..<h {
            for x in 0..<w where candidate[y * w + x] {
                let count = total(counts, x, y, radius)
                guard count > 0 else { continue }
                let value = (total(lumas, x, y, radius) / count - luma[y * w + x]) + 1.5 * (redness[y * w + x] - total(reds, x, y, radius) / count)
                contrast[y * w + x] = value
                deviations += value * value; deviationCount += 1
            }
        }
        let sigma = (deviations / max(1, deviationCount)).squareRoot()
        let threshold = max(5, sigma * 2.2)
        let maxArea = Double.pi * pow(Double(face.eyeWidth) * 0.25, 2)
        var seen = [Bool](repeating: false, count: w * h)
        var spots: [(x: Double, y: Double, radius: Double, contrast: Double)] = []
        for start in 0..<(w * h) where !seen[start] && candidate[start] && contrast[start] > threshold {
            var stack = [start], area = 0.0, cx = 0.0, cy = 0.0, depth = 0.0
            seen[start] = true
            while let index = stack.popLast() {
                let x = index % w, y = index / w
                area += 1; cx += Double(x); cy += Double(y); depth = max(depth, contrast[index])
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < w && ny < h {
                    let next = ny * w + nx
                    if !seen[next], candidate[next], contrast[next] > threshold * 0.6 { seen[next] = true; stack.append(next) }
                }
            }
            guard area >= 2, area <= maxArea else { continue }
            spots.append((cx / area + Double(x0) + offset.x, cy / area + Double(y0) + offset.y, (area / .pi).squareRoot() + 1, depth))
        }
        spots.sort { $0.contrast * $0.radius > $1.contrast * $1.radius }
        let mean = sl / n
        return ["color": AgentColor.hex(red: sr / n / 255, green: sg / n / 255, blue: sb / n / 255),
                "luminance": mean, "unevenness": (max(0, sl2 / n - mean * mean)).squareRoot(), "redness": red / n,
                "pixels": Int(n),
                "spots": spots.prefix(60).map { ["x": $0.x.rounded(), "y": $0.y.rounded(), "radius": ($0.radius * 10).rounded() / 10,
                                                  "contrast": ($0.contrast * 10).rounded() / 10] as JSONObject }]
    }
}
