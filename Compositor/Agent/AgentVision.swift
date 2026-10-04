import CoreGraphics
import CoreVideo
import Foundation
import Vision

/// What Vision finds in a picture, on this Mac: positions in the picture's pixels from its top-left corner.
nonisolated enum AgentVision {
    static let features = ["faces", "text", "saliency", "horizon", "subjects", "people", "animals", "rectangles", "labels", "pose", "arms", "skin"]
    static let defaultFeatures: Set<String> = ["faces", "text", "saliency", "horizon", "subjects", "labels"]

    static func detect(_ image: CGImage, features: Set<String>, offset: CGPoint) throws -> JSONObject {
        let size = CGSize(width: image.width, height: image.height)
        // Vision's rectangles are normalized with y up.
        func box(_ normalized: CGRect) -> JSONObject {
            let rect = VNImageRectForNormalizedRect(normalized, image.width, image.height)
            return ["x": (rect.minX + offset.x).rounded(), "y": (size.height - rect.maxY + offset.y).rounded(),
                    "width": rect.width.rounded(), "height": rect.height.rounded()]
        }
        func point(_ normalized: CGPoint) -> JSONObject {
            ["x": (normalized.x * size.width + offset.x).rounded(), "y": ((1 - normalized.y) * size.height + offset.y).rounded()]
        }
        var requests: [VNRequest] = []
        let quality = VNDetectFaceCaptureQualityRequest()
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = true
        text.recognitionLanguages = ["zh-Hans", "en-US"]
        text.automaticallyDetectsLanguage = true
        let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
        let horizon = VNDetectHorizonRequest()
        let subjects = VNGenerateForegroundInstanceMaskRequest()
        let people = VNDetectHumanRectanglesRequest()
        people.upperBodyOnly = false
        let animals = VNRecognizeAnimalsRequest()
        let rectangles = VNDetectRectanglesRequest()
        rectangles.maximumObservations = 8
        rectangles.minimumConfidence = 0.6
        let labels = VNClassifyImageRequest()
        if features.contains("faces") { requests.append(quality) }
        if features.contains("text") { requests.append(text) }
        if features.contains("saliency") { requests.append(saliency) }
        if features.contains("horizon") { requests.append(horizon) }
        if features.contains("subjects") { requests.append(subjects) }
        if features.contains("people") { requests.append(people) }
        if features.contains("animals") { requests.append(animals) }
        if features.contains("rectangles") { requests.append(rectangles) }
        if features.contains("labels") { requests.append(labels) }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        var result: JSONObject = [:]
        var failures: JSONObject = [:]
        // One at a time, so a request this Mac can't run fails alone.
        for request in requests {
            do { try handler.perform([request]) } catch { failures[name(of: request)] = error.localizedDescription }
        }

        let needsFaces = !features.isDisjoint(with: ["faces", "skin"])
        let faces = needsFaces ? try AgentPortrait.faces(in: image) : []
        if features.contains("faces") {
            let qualities = quality.results ?? []
            result["faces"] = faces.map { face -> JSONObject in
                var json = AgentPortrait.describe(face, offset: offset)
                let normalized = VNNormalizedRectForImageRect(CGRect(x: face.bounds.minX, y: size.height - face.bounds.maxY,
                                                                     width: face.bounds.width, height: face.bounds.height), image.width, image.height)
                if let match = qualities.first(where: { $0.boundingBox.intersects(normalized) }), let value = match.faceCaptureQuality {
                    json["capture_quality"] = value
                }
                return json
            }
        }
        let needsPerson = !features.isDisjoint(with: ["arms", "skin"])
        let person = needsPerson ? try AgentPortrait.personMask(image) : nil
        if !features.isDisjoint(with: ["pose", "arms"]) {
            let poses = try AgentPortrait.poses(in: image)
            if features.contains("pose") {
                result["poses"] = poses.map { joints in
                    joints.mapValues { ["x": Double(($0.point.x + offset.x).rounded()), "y": Double(($0.point.y + offset.y).rounded()),
                                        "confidence": $0.confidence] as JSONObject }
                }
            }
            if features.contains("arms"), let person {
                result["arms"] = poses.map { AgentPortrait.arms($0, person: person, width: image.width, height: image.height, offset: offset) }
            }
        }
        if features.contains("skin") {
            let bitmap = try AgentBitmap(image)
            let skin = AgentPortrait.skinMask(bitmap, faces: faces, person: person)
            result["skin"] = faces.enumerated().map { index, face -> JSONObject in
                var report: JSONObject = ["face_index": index]
                if let outline = AgentPortrait.path(of: "face_skin", in: face),
                   let area = AgentPortrait.rasterized([outline], width: image.width, height: image.height) {
                    let facial = zip(area, skin).map { $0 != 0 && $1 != 0 ? UInt8(255) : 0 }
                    report.merge(AgentPortrait.skinReport(bitmap, face: face, skin: facial, offset: offset)) { _, new in new }
                }
                return report
            }
            result["skin_fraction"] = Double(skin.filter { $0 != 0 }.count) / Double(max(1, skin.count))
        }
        if features.contains("text") {
            result["text"] = (text.results ?? []).prefix(200).compactMap { line -> JSONObject? in
                guard let best = line.topCandidates(1).first else { return nil }
                return ["text": best.string, "confidence": best.confidence, "bounds": box(line.boundingBox)]
            }
        }
        if features.contains("saliency") {
            result["salient_regions"] = (saliency.results?.first?.salientObjects ?? []).map {
                ["bounds": box($0.boundingBox), "confidence": $0.confidence] as JSONObject
            }
        }
        if features.contains("horizon") {
            if let found = horizon.results?.first {
                // The leveling transform turns counterclockwise with y up; on screen, with y down, that's clockwise negated.
                let level = -Double(atan2(found.transform.b, found.transform.a)) * 180 / .pi
                result["horizon"] = ["tilt_degrees": Double(found.angle) * 180 / .pi, "rotate_clockwise_to_level": level,
                                     "note": "Rotating the content clockwise by rotate_clockwise_to_level (negative is counterclockwise) levels the horizon, e.g. update_layer rotation."]
            } else {
                result["horizon"] = NSNull()
            }
        }
        if features.contains("subjects") {
            result["subjects"] = try subjectBounds(subjects.results?.first, size: size, offset: offset)
        }
        if features.contains("people") {
            result["people"] = (people.results ?? []).map { ["bounds": box($0.boundingBox), "confidence": $0.confidence] as JSONObject }
        }
        if features.contains("animals") {
            result["animals"] = (animals.results ?? []).map {
                ["bounds": box($0.boundingBox), "labels": $0.labels.prefix(3).map { ["label": $0.identifier, "confidence": $0.confidence] }] as JSONObject
            }
        }
        if features.contains("rectangles") {
            result["rectangles"] = (rectangles.results ?? []).map {
                ["corners": ["top_left": point($0.topLeft), "top_right": point($0.topRight),
                             "bottom_right": point($0.bottomRight), "bottom_left": point($0.bottomLeft)],
                 "confidence": $0.confidence] as JSONObject
            }
        }
        if features.contains("labels") {
            result["labels"] = (labels.results ?? []).filter { $0.confidence >= 0.1 }.prefix(10).map {
                ["label": $0.identifier, "confidence": $0.confidence] as JSONObject
            }
        }
        if !failures.isEmpty { result["unavailable"] = failures }
        return result
    }

    private static func name(of request: VNRequest) -> String {
        switch request {
        case is VNDetectFaceCaptureQualityRequest: "faces"
        case is VNRecognizeTextRequest: "text"
        case is VNGenerateAttentionBasedSaliencyImageRequest: "saliency"
        case is VNDetectHorizonRequest: "horizon"
        case is VNGenerateForegroundInstanceMaskRequest: "subjects"
        case is VNDetectHumanRectanglesRequest: "people"
        case is VNRecognizeAnimalsRequest: "animals"
        case is VNDetectRectanglesRequest: "rectangles"
        default: "labels"
        }
    }

    /// Each foreground object Vision separates: its bounds and how much of the picture it covers.
    private static func subjectBounds(_ observation: VNInstanceMaskObservation?, size: CGSize, offset: CGPoint) throws -> [JSONObject] {
        guard let observation else { return [] }
        let buffer = observation.instanceMask
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 0, height > 0, let base = CVPixelBufferGetBaseAddress(buffer) else { return [] }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var boxes: [Int: (minX: Int, minY: Int, maxX: Int, maxY: Int, count: Int)] = [:]
        for y in 0..<height {
            for x in 0..<width {
                let instance = Int(bytes[y * stride + x])
                guard instance > 0 else { continue }
                var entry = boxes[instance] ?? (x, y, x, y, 0)
                entry.minX = min(entry.minX, x); entry.maxX = max(entry.maxX, x)
                entry.minY = min(entry.minY, y); entry.maxY = max(entry.maxY, y)
                entry.count += 1
                boxes[instance] = entry
            }
        }
        let sx = size.width / CGFloat(width), sy = size.height / CGFloat(height)
        return boxes.sorted { $0.value.count > $1.value.count }.map { instance, entry in
            ["instance": instance, "coverage": Double(entry.count) / Double(width * height),
             "bounds": ["x": (CGFloat(entry.minX) * sx + offset.x).rounded(.down), "y": (CGFloat(entry.minY) * sy + offset.y).rounded(.down),
                        "width": (CGFloat(entry.maxX - entry.minX + 1) * sx).rounded(.up), "height": (CGFloat(entry.maxY - entry.minY + 1) * sy).rounded(.up)]]
        }
    }
}
