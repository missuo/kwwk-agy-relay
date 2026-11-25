import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOHTTP1

/// Loopback MCP server (streamable-HTTP transport, JSON responses only) that
/// exposes a request's client tools to `agy`.
///
/// One server per relay process; each ACP session gets its own route
/// (`/mcp/<random token>`) with that session's tool list and a call handler.
/// The handler may suspend for as long as it likes — the relay parks a call
/// there until the client sends the matching `tool_result` in a later HTTP
/// request. Requests must carry the per-process bearer secret.
final class MCPBridgeServer: Sendable {
    struct CallResult: Sendable {
        var content: [JSONValue]
        var isError: Bool
    }

    typealias CallHandler = @Sendable (_ name: String, _ arguments: JSONValue) async -> CallResult

    struct Route: Sendable {
        var tools: [ToolSpec]
        var onCall: CallHandler
    }

    /// Name of the MCP server agy sees; it prefixes each tool `mcp_<name>_`.
    static let serverName = "kwwk"
    static var toolPrefix: String { "mcp_\(serverName)_" }

    private struct State {
        var channel: Channel?
        var port: Int?
        var routes: [String: Route] = [:]
    }

    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let state = NIOLockedValueBox(State())
    let secret: String

    init(secret: String = MCPBridgeServer.randomToken()) {
        self.secret = secret
    }

    deinit {
        group.shutdownGracefully { _ in }
    }

    static func randomToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<4).map { _ in String(generator.next() as UInt64, radix: 16) }.joined()
    }

    /// Bind 127.0.0.1 on a free port. Idempotent.
    func start() async throws {
        if state.withLockedValue({ $0.channel != nil }) { return }
        let channel = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 64)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [weak self] child in
                let server = self
                return child.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    child.pipeline.addHandler(MCPHTTPHandler(server: server))
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        state.withLockedValue { state in
            state.channel = channel
            state.port = channel.localAddress?.port
        }
    }

    func stop() {
        let channel = state.withLockedValue { state -> Channel? in
            defer { state.channel = nil }
            return state.channel
        }
        _ = channel?.close()
    }

    func url(for token: String) -> String? {
        guard let port = state.withLockedValue({ $0.port }) else { return nil }
        return "http://127.0.0.1:\(port)/mcp/\(token)"
    }

    func setRoute(_ token: String, _ route: Route?) {
        state.withLockedValue { $0.routes[token] = route }
    }

    fileprivate func route(_ token: String) -> Route? {
        state.withLockedValue { $0.routes[token] }
    }

    /// The `mcpServers` entry for `session/new`.
    func serverEntry(for token: String) -> JSONValue? {
        guard let url = url(for: token) else { return nil }
        return [
            "type": "http",
            "name": .string(Self.serverName),
            "url": .string(url),
            "headers": [["name": "authorization", "value": .string("Bearer \(secret)")]],
        ]
    }

    // MARK: - JSON-RPC dispatch

    fileprivate func handle(token: String, message: JSONValue) async -> JSONValue? {
        guard case .object(let object) = message, let method = object["method"]?.stringValue else {
            return Self.error(id: .null, code: -32600, message: "invalid request")
        }
        guard let id = object["id"] else { return nil }
        let params = object["params"] ?? .null
        guard let route = route(token) else {
            return Self.error(id: id, code: -32001, message: "session closed")
        }
        switch method {
        case "initialize":
            return Self.result(id: id, [
                "protocolVersion": .string(params["protocolVersion"]?.stringValue ?? "2025-06-18"),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": .string(Self.serverName), "version": .string(RelayVersion.current)],
            ])
        case "server/discover", "ping":
            return Self.result(id: id, [:])
        case "tools/list":
            let tools: [JSONValue] = route.tools.map { tool in
                ["name": .string(tool.name), "description": .string(tool.description), "inputSchema": Self.inputSchema(tool.inputSchema)]
            }
            return Self.result(id: id, ["tools": .array(tools)])
        case "tools/call":
            guard let name = params["name"]?.stringValue else {
                return Self.error(id: id, code: -32602, message: "missing tool name")
            }
            let outcome = await route.onCall(name, params["arguments"] ?? .object([:]))
            return Self.result(id: id, ["content": .array(outcome.content), "isError": .bool(outcome.isError)])
        default:
            return Self.error(id: id, code: -32601, message: "method not found: \(method)")
        }
    }

    static func inputSchema(_ schema: JSONValue) -> JSONValue {
        guard case .object(var object) = schema else { return ["type": "object", "properties": [:]] }
        if object["type"] == nil { object["type"] = "object" }
        return .object(object)
    }

    private static func result(id: JSONValue, _ result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private static func error(id: JSONValue, code: Int, message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .int(code), "message": .string(message)]]
    }
}

private final class MCPHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private weak var server: MCPBridgeServer?
    private var head: HTTPRequestHead?
    private var body = ByteBuffer()

    init(server: MCPBridgeServer?) { self.server = server }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let h):
            head = h
            body.clear()
        case .body(var chunk):
            body.writeBuffer(&chunk)
        case .end:
            guard let head else { return }
            self.head = nil
            let bytes = body.readBytes(length: body.readableBytes) ?? []
            body.clear()
            handle(channel: context.channel, head: head, body: Data(bytes))
        }
    }

    private func handle(channel: Channel, head: HTTPRequestHead, body: Data) {
        guard let server else { return Self.respond(channel, .serviceUnavailable) }
        let path = head.uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? head.uri
        guard path.hasPrefix("/mcp/") else { return Self.respond(channel, .notFound) }
        guard head.headers["authorization"].first == "Bearer \(server.secret)" else {
            return Self.respond(channel, .unauthorized)
        }
        switch head.method {
        case .POST: break
        case .DELETE: return Self.respond(channel, .ok)
        default: return Self.respond(channel, .methodNotAllowed)
        }
        guard let message = try? JSONValue.decode(body) else { return Self.respond(channel, .badRequest) }
        let token = String(path.dropFirst("/mcp/".count))
        if message["method"]?.stringValue == "tools/call", message["id"] != nil {
            return streamToolCall(channel: channel, server: server, token: token, message: message)
        }
        Task {
            guard let reply = await server.handle(token: token, message: message) else {
                return Self.respond(channel, .accepted)
            }
            Self.respond(channel, .ok, json: (try? reply.encoded()) ?? Data())
        }
    }

    /// Answer a `tools/call` as an SSE stream. The call may be parked for
    /// minutes (until the client sends the tool result), so the stream
    /// carries a progress notification every 15 s — MCP clients reset their
    /// request timeout on progress — before the final JSON-RPC response.
    private func streamToolCall(channel: Channel, server: MCPBridgeServer, token: String, message: JSONValue) {
        var headers = HTTPHeaders()
        headers.add(name: "content-type", value: "text/event-stream")
        headers.add(name: "cache-control", value: "no-cache")
        headers.add(name: "connection", value: "close")
        let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        channel.eventLoop.execute {
            channel.writeAndFlush(HTTPServerResponsePart.head(head), promise: nil)
        }
        let progressToken = message["params"]?["_meta"]?["progressToken"]
        let heartbeat = Task {
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if Task.isCancelled { break }
                tick += 1
                let frame: String
                if let progressToken {
                    let note: JSONValue = [
                        "jsonrpc": "2.0",
                        "method": "notifications/progress",
                        "params": ["progressToken": progressToken, "progress": .int(tick), "message": "waiting for the client"],
                    ]
                    frame = "event: message\ndata: \(note.compactString)\n\n"
                } else {
                    frame = ": keepalive\n\n"
                }
                Self.writeChunk(channel, frame)
            }
        }
        Task {
            let reply = await server.handle(token: token, message: message) ?? .null
            heartbeat.cancel()
            Self.writeChunk(channel, "event: message\ndata: \(reply.compactString)\n\n")
            channel.eventLoop.execute {
                channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in
                    channel.close(promise: nil)
                }
            }
        }
    }

    private static func writeChunk(_ channel: Channel, _ text: String) {
        channel.eventLoop.execute {
            var buffer = channel.allocator.buffer(capacity: text.utf8.count)
            buffer.writeString(text)
            channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
        }
    }

    private static func respond(_ channel: Channel, _ status: HTTPResponseStatus, json: Data? = nil) {
        var headers = HTTPHeaders()
        if let json {
            headers.add(name: "content-type", value: "application/json")
            headers.add(name: "content-length", value: String(json.count))
        } else {
            headers.add(name: "content-length", value: "0")
        }
        headers.add(name: "connection", value: "close")
        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        channel.eventLoop.execute {
            channel.write(HTTPServerResponsePart.head(head), promise: nil)
            if let json {
                var buffer = channel.allocator.buffer(capacity: json.count)
                buffer.writeBytes(json)
                channel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
            }
            channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in
                channel.close(promise: nil)
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
