import AppKit
import Foundation
import Testing
@testable import Compositor

@MainActor
struct AgentPerceptionTests {
    private func json(_ result: AgentResult) throws -> JSONObject {
        try #require(try JSONSerialization.jsonObject(with: Data(AgentCoding.text(result.value).utf8)) as? JSONObject)
    }

    /// A 200 × 100 blue canvas with a red 50 × 40 box at (10, 20); returns the box's layer id.
    private func boxOnBlue(_ tools: AgentTools) async throws -> String {
        _ = try await tools.call("new_document", ["width": 200, "height": 100, "fill": "#336699"])
        let shape = try json(try await tools.call("add_shape_layer", ["kind": "rectangle", "x": 10, "y": 20, "width": 50, "height": 40,
                                                                       "color": "#FF0000", "name": "Box"]))
        return try #require((shape["layer"] as? JSONObject)?["id"] as? String)
    }

    private func number(_ object: Any?, _ key: String) -> Double? { ((object as? JSONObject)?[key] as? NSNumber)?.doubleValue }

    @Test func layersReportWhereTheirContentIs() async throws {
        let tools = AgentTools(workspace: ProjectWorkspace())
        let id = try await boxOnBlue(tools)
        let document = try json(try await tools.call("get_document"))
        let box = try #require((document["layers"] as? [JSONObject])?.first { $0["id"] as? String == id })
        let bounds = box["content_bounds"]
        #expect(abs((number(bounds, "x") ?? 0) - 10) <= 1 && abs((number(bounds, "y") ?? 0) - 20) <= 1)
        #expect(abs((number(bounds, "width") ?? 0) - 50) <= 2 && abs((number(bounds, "height") ?? 0) - 40) <= 2)
    }

    @Test func samplesReadTheCanvasAndTheLayersUnderIt() async throws {
        let tools = AgentTools(workspace: ProjectWorkspace())
        _ = try await boxOnBlue(tools)
        let result = try json(try await tools.call("sample_pixels", ["points": [[30, 40], [150, 50], [500, 5]], "radius": 1]))
        let samples = try #require(result["samples"] as? [JSONObject])
        #expect(samples[0]["color"] as? String == "#FF0000")
        let layers = try #require(samples[0]["layers"] as? [JSONObject])
        #expect(layers.first?["name"] as? String == "Box" && layers.count == 2)
        #expect(samples[1]["color"] as? String == "#336699")
        #expect((samples[1]["layers"] as? [JSONObject])?.count == 1)
        #expect(samples[2]["outside_canvas"] as? Bool == true)
    }

    @Test func analysisMeasuresToneAndCast() async throws {
        let tools = AgentTools(workspace: ProjectWorkspace())
        _ = try await boxOnBlue(tools)
        let result = try json(try await tools.call("analyze_image", ["x": 100, "y": 0, "width": 100, "height": 100]))
        let median = try #require(number(result["luminance"], "median"))
        #expect(abs(median - 95) <= 2)
        let cast = try #require(result["cast"] as? JSONObject)
        #expect((cast["verdict"] as? String)?.contains("cool") == true)
        #expect(number(result["clipping"], "highlights_fraction") == 0)
        #expect(number(result["content_bounds"], "x") == 100)
        #expect((result["luminance"] as? JSONObject)?["histogram_percent"] as? [Any] != nil)

        _ = try await tools.call("select", ["action": "rectangle", "x": 10, "y": 20, "width": 50, "height": 40])
        let selected = try json(try await tools.call("analyze_image", ["within_selection": true]))
        #expect(number(selected["clipping"], "red_fraction") ?? 0 > 0.9)
    }

    @Test func compareFindsWhatTheLastStepChanged() async throws {
        let tools = AgentTools(workspace: ProjectWorkspace())
        let id = try await boxOnBlue(tools)
        _ = try await tools.call("update_layer", ["layer_id": id, "dx": 100])
        let result = try await tools.call("compare")
        #expect(result.images.count == 2)
        let value = try json(result)
        #expect((value["steps"] as? [String])?.count == 1)
        let difference = try #require(value["difference"] as? JSONObject)
        let bounds = difference["changed_bounds"]
        #expect(abs((number(bounds, "x") ?? 0) - 10) <= 1 && abs((number(bounds, "width") ?? 0) - 150) <= 2)
        #expect(abs((number(bounds, "y") ?? 0) - 20) <= 1 && abs((number(bounds, "height") ?? 0) - 40) <= 2)
        await #expect(throws: AgentError.self) { try await tools.call("compare", ["steps_back": 50]) }
    }

    @Test func picturesCanCarryAGridAndOutlines() async throws {
        let tools = AgentTools(workspace: ProjectWorkspace())
        let id = try await boxOnBlue(tools)
        _ = try await tools.call("select", ["action": "ellipse", "x": 100, "y": 10, "width": 60, "height": 60])
        let result = try await tools.call("get_canvas_image", ["grid": true, "show_selection": true, "outline_layer_ids": [id], "format": "png"])
        #expect(result.images.count == 1)
        #expect(number(try json(result), "grid_spacing") == 50)
        await #expect(throws: AgentError.self) {
            try await tools.call("get_canvas_image", ["layer_id": id, "show_selection": true])
        }
    }

    @Test func detectionRunsAndReadsText() async throws {
        let workspace = ProjectWorkspace()
        let tools = AgentTools(workspace: workspace)
        _ = try await tools.call("new_document", ["width": 900, "height": 240, "fill": "#FFFFFF"])
        _ = try await tools.call("add_text_layer", ["text": "COMPOSITOR", "size": 120, "color": "#000000", "x": 40, "y": 50])
        let result = try json(try await tools.call("detect", ["features": ["text", "labels", "saliency", "horizon"]]))
        #expect(result["labels"] is [Any] && result["salient_regions"] is [Any] && result["horizon"] != nil)
        let lines = try #require(result["text"] as? [JSONObject])
        #expect(lines.contains { ($0["text"] as? String)?.uppercased().contains("COMPOSITOR") == true })
        await #expect(throws: AgentError.self) { try await tools.call("detect", ["features": ["nope"]]) }
    }
}
