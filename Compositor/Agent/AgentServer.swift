import AppKit
import Network
import Observation

/// Compositor's MCP server: AI agents (Cursor, Claude, Codex, …) connect over Streamable HTTP on this Mac only,
/// with a token, and drive the open documents through `AgentTools`. Off until it's turned on in
/// Compositor > MCP Server….
@MainActor @Observable
final class AgentServer {
    static let shared = AgentServer()
    static let defaultPort = 47821
    private static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    enum State: Equatable {
        case off, starting, listening, failed(String)
    }

    struct Activity: Identifiable {
        let id = UUID()
        let date: Date
        let tool: String
        let message: String
        let failed: Bool
    }

    private(set) var state = State.off
    private(set) var activity: [Activity] = []
    /// The tool running now, for the status bar.
    private(set) var runningTool: String?
    /// The agent that last introduced itself, such as "cursor-vscode" or "claude-code".
    private(set) var clientName: String?

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: "mcp.enabled")
            isEnabled ? listen() : stop()
        }
    }
    private(set) var port: Int
    private(set) var token: String

    var endpoint: String { "http://127.0.0.1:\(port)/mcp" }

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var connections: [ObjectIdentifier: AgentConnection] = [:]
    @ObservationIgnored private var tools: AgentTools?
    @ObservationIgnored private var callRunning = false
    @ObservationIgnored private var waitingCalls: [CheckedContinuation<Void, Never>] = []

    private init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: "mcp.enabled")
        let saved = defaults.integer(forKey: "mcp.port")
        port = (1024...65535).contains(saved) ? saved : Self.defaultPort
        if let saved = defaults.string(forKey: "mcp.token"), saved.count >= 32 {
            token = saved
        } else {
            token = Self.newToken()
            defaults.set(token, forKey: "mcp.token")
        }
    }

    /// Called once at launch: listens straight away if the server was left on.
    func start(workspace: ProjectWorkspace) {
        tools = AgentTools(workspace: workspace)
        if isEnabled { listen() }
    }

    func setPort(_ value: Int) {
        guard (1024...65535).contains(value), value != port else { return }
        port = value
        UserDefaults.standard.set(value, forKey: "mcp.port")
        if isEnabled { listen() }
    }

    /// A new token; agents set up with the old one must be given this one.
    func regenerateToken() {
        token = Self.newToken()
        UserDefaults.standard.set(token, forKey: "mcp.token")
        for connection in connections.values { connection.close() }
    }

    private static func newToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
    }

    // MARK: Listening

    private func listen() {
        stop()
        guard let port = NWEndpoint.Port(rawValue: UInt16(port)) else { state = .failed(String(localized: "The port isn’t valid.")); return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        parameters.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated { self?.update(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            self.listener = listener
            state = .starting
            listener.start(queue: .main)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.close() }
        connections = [:]
        state = .off
    }

    private func update(_ listenerState: NWListener.State) {
        switch listenerState {
        case .ready: state = .listening
        case .failed(let error):
            if case .posix(let code) = error, code == .EADDRINUSE {
                state = .failed(String(localized: "Port \(port) is in use by another app. Choose another port."))
            } else {
                state = .failed(error.localizedDescription)
            }
            listener?.cancel()
            listener = nil
        default: break
        }
    }

    private func accept(_ connection: NWConnection) {
        let handler = AgentConnection(connection: connection, server: self)
        connections[ObjectIdentifier(handler)] = handler
        handler.start()
    }

    fileprivate func remove(_ connection: AgentConnection) {
        connections.removeValue(forKey: ObjectIdentifier(connection))
    }

    // MARK: Requests

    fileprivate func respond(to request: HTTPRequest) async -> HTTPResponse {
        if let origin = request.headers["origin"], !Self.isLocal(origin) {
            return HTTPResponse(status: 403, body: Self.errorBody(String(localized: "Requests from web pages aren’t allowed.")))
        }
        let path = request.path.split(separator: "?").first.map(String.init) ?? request.path
        guard path == "/mcp" || path == "/" else { return HTTPResponse(status: 404, body: Self.errorBody("Use \(endpoint).")) }
        guard Self.constantTimeEqual(request.headers["authorization"] ?? "", "Bearer \(token)") else {
            return HTTPResponse(status: 401, headers: [("WWW-Authenticate", "Bearer")],
                                body: Self.errorBody(String(localized: "Missing or wrong token. Copy the setup from Compositor > MCP Server….")))
        }
        switch request.method {
        case "POST": break
        case "GET", "DELETE": return HTTPResponse(status: 405, headers: [("Allow", "POST")], body: Data())
        default: return HTTPResponse(status: 405, headers: [("Allow", "POST")], body: Data())
        }
        guard let message = try? JSONSerialization.jsonObject(with: request.body) else {
            return Self.json(Self.rpcError(nil, -32700, "Parse error"))
        }
        if let batch = message as? [Any] {
            var replies: [Any] = []
            for item in batch { if let reply = await handle(item) { replies.append(reply) } }
            return replies.isEmpty ? HTTPResponse(status: 202, body: Data()) : Self.json(replies)
        }
        guard let reply = await handle(message) else { return HTTPResponse(status: 202, body: Data()) }
        return Self.json(reply)
    }

    /// One JSON-RPC message; nil for notifications and responses, which get no reply.
    private func handle(_ message: Any) async -> JSONObject? {
        guard let message = message as? JSONObject else { return Self.rpcError(nil, -32600, "Invalid Request") }
        let id = message["id"]
        guard let method = message["method"] as? String else { return nil }
        guard id != nil, !(id is NSNull) else { return nil }
        let params = message["params"] as? JSONObject ?? [:]
        switch method {
        case "initialize":
            if let info = params["clientInfo"] as? JSONObject { clientName = info["name"] as? String }
            let requested = params["protocolVersion"] as? String ?? ""
            let version = Self.protocolVersions.contains(requested) ? requested : Self.protocolVersions[0]
            let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
            return Self.rpcResult(id, [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "compositor", "title": "Compositor", "version": appVersion],
                "instructions": Self.instructions,
            ])
        case "ping":
            return Self.rpcResult(id, [:])
        case "tools/list":
            return Self.rpcResult(id, ["tools": tools?.tools.map(\.listing) ?? []])
        case "tools/call":
            guard let name = params["name"] as? String, let tool = tools?.tool(named: name) else {
                return Self.rpcError(id, -32602, "Unknown tool: \(params["name"] as? String ?? "")")
            }
            let arguments = params["arguments"] as? JSONObject ?? [:]
            return Self.rpcResult(id, await call(tool, arguments))
        default:
            return Self.rpcError(id, -32601, "Method not found: \(method)")
        }
    }

    /// Runs one tool call at a time, in the order they arrive, so two agents never interleave edits.
    private func call(_ tool: AgentTool, _ arguments: JSONObject) async -> JSONObject {
        if callRunning { await withCheckedContinuation { waitingCalls.append($0) } } else { callRunning = true }
        defer {
            if waitingCalls.isEmpty { callRunning = false } else { waitingCalls.removeFirst().resume() }
        }
        runningTool = tool.title
        defer { runningTool = nil }
        do {
            let result = try await tool.run(AgentArguments(arguments))
            var content: [JSONObject] = [["type": "text", "text": AgentCoding.text(result.value)]]
            content += result.images.map { ["type": "image", "data": $0.data.base64EncodedString(), "mimeType": $0.mimeType] }
            log(tool.name, (result.value as? JSONObject)?["undo"] as? String ?? "", failed: false)
            return ["content": content, "isError": false]
        } catch {
            let message = error.localizedDescription
            log(tool.name, message, failed: true)
            return ["content": [["type": "text", "text": message]], "isError": true]
        }
    }

    private func log(_ tool: String, _ message: String, failed: Bool) {
        activity.insert(Activity(date: Date(), tool: tool, message: message, failed: failed), at: 0)
        if activity.count > 50 { activity.removeLast(activity.count - 50) }
    }

    // MARK: Encoding

    private static func rpcResult(_ id: Any?, _ result: JSONObject) -> JSONObject {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]
    }
    private static func rpcError(_ id: Any?, _ code: Int, _ message: String) -> JSONObject {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }
    private static func json(_ value: Any) -> HTTPResponse {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes]) else {
            let fallback = try? JSONSerialization.data(withJSONObject: rpcError(nil, -32603, "Internal error: the result couldn’t be encoded."))
            return HTTPResponse(status: 200, headers: [("Content-Type", "application/json")], body: fallback ?? Data())
        }
        return HTTPResponse(status: 200, headers: [("Content-Type", "application/json")], body: data)
    }
    private static func errorBody(_ message: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data()
    }

    private static func isLocal(_ origin: String) -> Bool {
        guard let host = URL(string: origin)?.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    static let instructions = """
    Compositor is a layered image editor open on the person’s Mac; they watch the canvas update as you work.
    Start with list_documents and get_document: layers come with ids, kinds and placement. Coordinates are document \
    pixels from the top-left corner, y down. Each tool call that changes something is one Undo step (history undoes \
    them). Measure before you change and check after: get_canvas_image shows the canvas (grid labels coordinates, \
    outlines mark the selection and layers); analyze_image measures tone, clipping, color cast, sharpness and noise; \
    sample_pixels reads colors and which layers make them; detect finds faces, text, subjects, salient regions and \
    the horizon; compare shows and measures what your last steps changed. A picture alone is a poor judge of exact \
    values and positions, so use the numbers. Prefer non-destructive work: adjustment \
    layers, masks (layer_mask, Remove Background), text and shape layers stay editable. Filters and draw change a \
    pixel layer inside the selection if there is one. describe_settings lists filter, adjustment and effect settings \
    and installed fonts. Files: Compositor is sandboxed and reaches ~/Pictures, ~/Downloads, folders the person \
    added in Compositor > MCP Server…, and open projects; add_image_layer also takes a URL or base64 data. \
    If a tool says something is open on screen (a dialog, text being typed), ask the person to finish it.
    """
}

fileprivate struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

fileprivate struct HTTPResponse {
    var status: Int
    var headers: [(String, String)] = []
    var body: Data
}

/// One client connection: reads HTTP/1.1 requests one at a time and answers each before reading the next.
@MainActor
fileprivate final class AgentConnection {
    private static let maxHeader = 64 * 1024
    private static let maxBody = 200 * 1024 * 1024
    let connection: NWConnection
    weak var server: AgentServer?
    private var buffer = Data()
    private var busy = false
    private var closed = false

    init(connection: NWConnection, server: AgentServer) {
        self.connection = connection
        self.server = server
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .failed, .cancelled: self?.close()
                default: break
                }
            }
        }
        connection.start(queue: .main)
        receive()
    }

    func close() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        server?.remove(self)
    }

    private func receive() {
        guard !closed else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let data { self.buffer.append(data) }
                if error != nil || (isComplete && data == nil) { self.close(); return }
                self.process()
                if isComplete { self.close() } else { self.receive() }
            }
        }
    }

    private func process() {
        guard !busy, !closed else { return }
        let separator = Data("\r\n\r\n".utf8)
        guard let end = buffer.range(of: separator) else {
            if buffer.count > Self.maxHeader { reply(HTTPResponse(status: 431, body: Data()), close: true) }
            return
        }
        guard let head = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8) else {
            reply(HTTPResponse(status: 400, body: Data()), close: true); return
        }
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ")
        guard start.count >= 2 else { reply(HTTPResponse(status: 400, body: Data()), close: true); return }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0, length <= Self.maxBody else { reply(HTTPResponse(status: 413, body: Data()), close: true); return }
        guard buffer.count - (end.upperBound - buffer.startIndex) >= length else { return }
        let bodyStart = end.upperBound
        let body = Data(buffer[bodyStart..<(bodyStart + length)])
        buffer = Data(buffer[(bodyStart + length)...])
        let request = HTTPRequest(method: String(start[0]).uppercased(), path: String(start[1]), headers: headers, body: body)
        let closes = headers["connection"]?.lowercased() == "close"
        busy = true
        Task { @MainActor in
            let response = await server?.respond(to: request) ?? HTTPResponse(status: 503, body: Data())
            busy = false
            reply(response, close: closes)
            process()
        }
    }

    private func reply(_ response: HTTPResponse, close: Bool) {
        guard !closed else { return }
        let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
                      405: "Method Not Allowed", 413: "Payload Too Large", 431: "Request Header Fields Too Large",
                      503: "Service Unavailable"][response.status] ?? "OK"
        var head = "HTTP/1.1 \(response.status) \(reason)\r\n"
        var headers = response.headers
        if !headers.contains(where: { $0.0 == "Content-Type" }), !response.body.isEmpty { headers.append(("Content-Type", "application/json")) }
        headers.append(("Content-Length", String(response.body.count)))
        headers.append(("Connection", close ? "close" : "keep-alive"))
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(response.body)
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            guard close else { return }
            MainActor.assumeIsolated { self?.close() }
        })
    }
}
