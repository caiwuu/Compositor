import AppKit
import Foundation
import Testing
@testable import Compositor

@MainActor
struct AgentToolsTests {
    private func json(_ result: AgentResult) throws -> JSONObject {
        let text = AgentCoding.text(result.value)
        return try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? JSONObject)
    }

    @Test func everyToolHasAnObjectSchemaAndAUniqueName() {
        let tools = AgentTools(workspace: ProjectWorkspace()).tools
        #expect(Set(tools.map(\.name)).count == tools.count)
        #expect(tools.allSatisfy { $0.schema["type"] as? String == "object" && JSONSerialization.isValidJSONObject($0.listing) })
    }

    @Test func eachChangeIsOneUndoStep() async throws {
        let workspace = ProjectWorkspace()
        let tools = AgentTools(workspace: workspace)
        _ = try await tools.call("new_document", ["width": 200, "height": 100, "fill": "#336699"])
        let session = workspace.current.session
        #expect(session.document?.layers.count == 1)
        let shape = try json(try await tools.call("add_shape_layer", ["kind": "rectangle", "x": 10, "y": 20, "width": 50, "height": 40,
                                                                       "color": "#FF0000", "name": "Box"]))
        let layer = try #require(shape["layer"] as? JSONObject)
        #expect(layer["kind"] as? String == "shape" && layer["name"] as? String == "Box")
        #expect(layer["x"] as? Double == 10 && layer["width"] as? Double == 50)
        #expect(session.document?.layers.count == 2)
        session.undo()
        #expect(session.document?.layers.count == 1)
    }

    @Test func textLayersDescribeAsJSON() async throws {
        let workspace = ProjectWorkspace()
        let tools = AgentTools(workspace: workspace)
        _ = try await tools.call("new_document", ["width": 400, "height": 200])
        let added = try json(try await tools.call("add_text_layer", ["text": "Hi", "size": 48, "color": "#00FF00", "x": 20, "y": 30]))
        let text = try #require((added["layer"] as? JSONObject)?["text"] as? JSONObject)
        #expect(text["content"] as? String == "Hi" && text["font"] as? String == "Helvetica" && text["color"] as? String == "#00FF00")
        #expect(text["box_width"] is NSNull)
        let id = try #require((added["layer"] as? JSONObject)?["id"] as? String)
        _ = try await tools.call("update_layer", ["layer_id": id, "text": ["text": "Hello"]])
        #expect(workspace.current.session.document?.layers.last?.liveText?.style.content == "Hello")
    }

    @Test func effectsMergeAndSurviveCanvasSize() async throws {
        let workspace = ProjectWorkspace()
        let tools = AgentTools(workspace: workspace)
        _ = try await tools.call("new_document", ["width": 100, "height": 100])
        let shape = try json(try await tools.call("add_shape_layer", ["kind": "ellipse", "x": 10, "y": 10, "width": 30, "height": 30]))
        let id = try #require((shape["layer"] as? JSONObject)?["id"] as? String)
        _ = try await tools.call("update_layer", ["layer_id": id, "effects": ["stroke": ["size": 3, "color": "#FFFFFF"]]])
        let session = workspace.current.session
        let stroke = try #require(session.document?.layers.last?.effects?.stroke)
        #expect(stroke.size == 3 && stroke.red == 1 && stroke.blue == 1)
        _ = try await tools.call("resize_canvas", ["width": 150, "height": 120, "anchor": "top_left"])
        #expect(session.document?.width == 150)
        #expect(session.document?.layers.last?.effects?.stroke?.size == 3)
        #expect(session.document?.layers.last?.liveShape != nil)
        _ = try await tools.call("update_layer", ["layer_id": id, "effects": ["stroke": NSNull()]])
        #expect(session.document?.layers.last?.effects == nil)
    }

    @Test func mistakesComeBackAsPlainErrors() async throws {
        let workspace = ProjectWorkspace()
        let tools = AgentTools(workspace: workspace)
        await #expect(throws: AgentError.self) { _ = try await tools.call("add_shape_layer", ["kind": "rectangle", "x": 0, "y": 0, "width": 5, "height": 5]) }
        _ = try await tools.call("new_document", ["width": 50, "height": 50])
        await #expect(throws: AgentError.self) { _ = try await tools.call("update_layer", ["layer_id": UUID().uuidString, "opacity": 0.5]) }
        await #expect(throws: AgentError.self) { _ = try await tools.call("update_layer", ["layer_id": "nope"]) }
        await #expect(throws: AgentError.self) { _ = try await tools.call("apply_filter", ["filter": "Sharpen"]) }
        await #expect(throws: AgentError.self) { _ = try await tools.call("no_such_tool") }
    }

    @Test func patchesMergeOverDefaults() throws {
        let merged = try AgentCoding.merged(StrokeEffect(), with: ["color": "#FF8000", "inside": true])
        #expect(merged.red == 1 && abs(merged.green - 128.0 / 255) < 0.001 && merged.blue == 0 && merged.inside && merged.size == 4)
        #expect(throws: AgentError.self) { _ = try AgentCoding.merged(StrokeEffect(), with: ["size": "big"]) }
        #expect(throws: AgentError.self) { _ = try AgentCoding.merged(StrokeEffect(), with: ["sise": 3]) }
        #expect(AgentColor.parse("#abc") == PaletteColor(red: 170.0 / 255, green: 187.0 / 255, blue: 204.0 / 255))
        #expect(AgentCoding.text(["a": 0.6, "b": Optional<Int>.none as Any]).contains("\"a\" : 0.6"))
    }
}
