import AppKit
import Foundation
import Testing
@testable import Compositor

@MainActor
struct AgentPortraitTests {
    private func json(_ result: AgentResult) throws -> JSONObject {
        try #require(try JSONSerialization.jsonObject(with: Data(AgentCoding.text(result.value).utf8)) as? JSONObject)
    }

    /// A white 200 × 100 canvas with a red block from x 20 to 60, y 30 to 70, painted into its one layer.
    private func redBlock(_ tools: AgentTools) async throws {
        _ = try await tools.call("new_document", ["width": 200, "height": 100, "fill": "#FFFFFF"])
        _ = try await tools.call("draw", ["shapes": [["type": "rectangle", "x": 20, "y": 30, "width": 40, "height": 40, "color": "#FF0000"]]])
    }

    private func colors(_ tools: AgentTools, _ points: [[Double]]) async throws -> [String] {
        let result = try json(try await tools.call("sample_pixels", ["points": points, "layers": false]))
        return try #require(result["samples"] as? [JSONObject]).map { $0["color"] as? String ?? "" }
    }

    @Test func warpMovesAnEdgeAndRespectsTheSelection() async throws {
        let workspace = ProjectWorkspace()
        let tools = AgentTools(workspace: workspace)
        try await redBlock(tools)
        let session = workspace.current.session
        _ = try await tools.call("warp", ["moves": [["from": [60, 50], "to": [50, 50], "radius": 30]]])
        let after = try await colors(tools, [[57, 50], [35, 50], [150, 50]])
        #expect(after[0] == "#FFFFFF" && after[1] == "#FF0000" && after[2] == "#FFFFFF")
        #expect(session.history.undoName == String(localized: "Liquify"))

        // Selected elsewhere, the block stays as it is, and compare finds nothing changed outside the selection.
        _ = try await tools.call("select", ["action": "rectangle", "x": 120, "y": 0, "width": 80, "height": 100])
        let moved = try json(try await tools.call("warp", ["moves": [["from": [50, 50], "to": [40, 50]]], "radius": 30]))
        #expect(moved["changed"] as? Bool == false)
        _ = try await tools.call("select", ["action": "rectangle", "x": 0, "y": 0, "width": 100, "height": 100])
        _ = try await tools.call("warp", ["moves": [["from": [50, 50], "to": [45, 50]]], "radius": 30])
        let outside = try json(try await tools.call("compare", ["outside_selection": true]))
        #expect(((outside["difference"] as? JSONObject)?["changed_fraction"] as? NSNumber)?.doubleValue == 0)
        await #expect(throws: AgentError.self) { try await tools.call("warp", ["moves": [["from": [50, 50], "to": [0, 50], "radius": 30]]]) }
    }

    @Test func brushStrokesPaintAndHeal() async throws {
        let workspace = ProjectWorkspace()
        let tools = AgentTools(workspace: workspace)
        _ = try await tools.call("new_document", ["width": 200, "height": 100, "fill": "#FFFFFF"])
        let session = workspace.current.session
        let tool = session.tool, size = session.brushSettings.diameter
        _ = try await tools.call("brush_stroke", ["mode": "paint", "strokes": [[[20, 20], [180, 20]]], "size": 12, "hardness": 1, "color": "#00FF00"])
        #expect(try await colors(tools, [[100, 20]]) == ["#00FF00"])
        #expect(session.tool == tool && session.brushSettings.diameter == size)

        _ = try await tools.call("draw", ["shapes": [["type": "ellipse", "x": 98, "y": 68, "width": 5, "height": 5, "color": "#000000"]]])
        _ = try await tools.call("brush_stroke", ["mode": "spot_heal", "strokes": [[[100, 70]]], "size": 16])
        let healed = try json(try await tools.call("sample_pixels", ["points": [[100, 70]], "layers": false]))
        let luminance = (try #require(healed["samples"] as? [JSONObject]).first?["luminance"] as? NSNumber)?.intValue ?? 0
        #expect(luminance > 200)
        await #expect(throws: AgentError.self) { try await tools.call("brush_stroke", ["mode": "clone", "strokes": [[[10, 10]]]]) }
    }

    @Test func colorRangeSelectsByColor() async throws {
        let workspace = ProjectWorkspace()
        let tools = AgentTools(workspace: workspace)
        try await redBlock(tools)
        let result = try json(try await tools.call("smart_select", ["method": "color_range", "colors": ["#FF0000"], "fuzziness": 20]))
        let selection = try #require(result["selection"] as? JSONObject)
        #expect((selection["x"] as? NSNumber)?.doubleValue == 20 && (selection["width"] as? NSNumber)?.doubleValue == 40)
        #expect(workspace.current.session.colorRange == nil)
        let grown = try json(try await tools.call("smart_select", ["method": "color_range", "points": [[40, 50]], "grow": 5]))
        #expect(((grown["selection"] as? JSONObject)?["width"] as? NSNumber)?.doubleValue ?? 0 >= 49)
    }

    @Test func smoothingSkinLowersNoise() async throws {
        let workspace = ProjectWorkspace()
        let tools = AgentTools(workspace: workspace)
        _ = try await tools.call("new_document", ["width": 300, "height": 200, "fill": "#C89070"])
        _ = try await tools.call("apply_filter", ["filter": "Add Noise"])
        let before = try json(try await tools.call("analyze_image"))
        _ = try await tools.call("select", ["action": "all"])
        _ = try await tools.call("smooth_skin", ["strength": 1, "radius": 4, "detail": 0])
        let after = try json(try await tools.call("analyze_image"))
        func noise(_ value: JSONObject) -> Double { ((value["detail"] as? JSONObject)?["noise"] as? NSNumber)?.doubleValue ?? 0 }
        #expect(noise(before) > 1 && noise(after) < noise(before) / 2)
    }

    @Test func facePartsNeedAFace() async throws {
        let tools = AgentTools(workspace: ProjectWorkspace())
        try await redBlock(tools)
        await #expect(throws: AgentError.self) { try await tools.call("smart_select", ["method": "lips"]) }
        let found = try json(try await tools.call("detect", ["features": ["faces", "pose", "skin"]]))
        #expect((found["faces"] as? [Any])?.isEmpty == true && (found["poses"] as? [Any])?.isEmpty == true)
    }

    @Test func faceOutlinesComeFromLandmarks() throws {
        let contour = (0...16).map { i -> CGPoint in
            let angle = Double.pi * Double(i) / 16
            return CGPoint(x: 100 - 40 * cos(angle), y: 100 + 50 * sin(angle))
        }
        let face = AgentFace(bounds: CGRect(x: 60, y: 40, width: 80, height: 110), confidence: 1, roll: 0, yaw: 0, regions: [
            "face_contour": contour,
            "left_eyebrow": [CGPoint(x: 75, y: 80), CGPoint(x: 85, y: 77), CGPoint(x: 95, y: 80)],
            "right_eyebrow": [CGPoint(x: 105, y: 80), CGPoint(x: 115, y: 77), CGPoint(x: 125, y: 80)],
            "left_eye": [CGPoint(x: 78, y: 90), CGPoint(x: 85, y: 87), CGPoint(x: 92, y: 90), CGPoint(x: 85, y: 93)],
            "outer_lips": [CGPoint(x: 88, y: 125), CGPoint(x: 100, y: 120), CGPoint(x: 112, y: 125), CGPoint(x: 100, y: 132)],
            "inner_lips": [CGPoint(x: 92, y: 126), CGPoint(x: 100, y: 124), CGPoint(x: 108, y: 126), CGPoint(x: 100, y: 128)],
        ])
        let outline = try #require(AgentPortrait.path(of: "face", in: face))
        #expect(outline.boundingBoxOfPath.minY < 77 - 20, "the forehead is above the eyebrows")
        let lips = try #require(AgentPortrait.path(of: "lips", in: face))
        #expect(lips.contains(CGPoint(x: 100, y: 122)) && !lips.contains(CGPoint(x: 100, y: 126)))
        let skin = try #require(AgentPortrait.path(of: "face_skin", in: face))
        #expect(skin.contains(CGPoint(x: 70, y: 110)) && !skin.contains(CGPoint(x: 85, y: 90)))
    }
}
