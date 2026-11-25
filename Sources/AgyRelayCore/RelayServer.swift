import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOHTTP1

/// The relay's HTTP front:
///   - `POST /v1/messages` — Anthropic Messages, streaming (SSE) or not
///   - `GET /v1/agy/models` — the caller's agy model catalog
///   - `GET /healthz`
public final class RelayServer: Sendable {
    public let config: RelayConfig
    public let service: RelayService
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    private let channel = NIOLockedValueBox<Channel?>(nil)

    /// Largest request body accepted (images ride inline as base64).
    static let maxBody = 64 * 1024 * 1024

    public init(config: RelayConfig, identity: IdentityResolver? = nil) {
        self.config = config
        self.service = RelayService(config: config, identity: identity)
    }

    /// Bind and return the bound port.
    @discardableResult
    public func start() async throws -> Int {
        try await service.start()
        let service = service
        let bound = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { child in
                child.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    child.pipeline.addHandler(RelayHTTPHandler(service: service))
                }
            }
            .bind(host: config.host, port: config.port)
            .get()
        channel.withLockedValue { $0 = bound }
        return bound.localAddress?.port ?? config.port
    }

    /// Run until the server channel closes.
    public func wait() async throws {
        guard let bound = channel.withLockedValue({ $0 }) else { return }
        try await bound.closeFuture.get()
    }

    public func stop() async {
        let bound = channel.withLockedValue { state -> Channel? in
            defer { state = nil }
            return state
        }
        try? await bound?.close()
        await service.stop()
        try? await group.shutdownGracefully()
    }
}

final class RelayHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let service: RelayService
    private var head: HTTPRequestHead?
    private var body = ByteBuffer()
    private var tooLarge = false
    private var work: Task<Void, Never>?

    init(service: RelayService) {
        self.service = service
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let h):
            head = h
            body.clear()
            tooLarge = false
        case .body(var chunk):
            if body.readableBytes + chunk.readableBytes > RelayServer.maxBody {
                tooLarge = true
            } else {
                body.writeBuffer(&chunk)
            }
        case .end:
            guard let head else { return }
            self.head = nil
            let bytes = Data(body.readBytes(length: body.readableBytes) ?? [])
            body.clear()
            let channel = context.channel
            if tooLarge {
                return Self.respondJSON(channel, 413, WireError(status: 413, type: "request_too_large", message: "request body too large").body, keepAlive: false)
            }
            let keepAlive = head.isKeepAlive
            let service = service
            work = Task {
                await Self.route(service: service, head: head, body: bytes, channel: channel, keepAlive: keepAlive)
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        // The client hung up: cancelling the consumer cancels its event
        // stream, which stops agy's turn.
        work?.cancel()
        work = nil
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    // MARK: - Routing

    private static func route(service: RelayService, head: HTTPRequestHead, body: Data, channel: Channel, keepAlive: Bool) async {
        let path = head.uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? head.uri
        let secret = head.headers["x-relay-secret"].first
        let bearer = bearerToken(head.headers)
        switch (head.method, path) {
        case (.GET, "/healthz"):
            respondJSON(channel, 200, ["ok": true, "version": .string(RelayVersion.current)], keepAlive: keepAlive)
        case (.GET, "/v1/agy/models"), (.GET, "/v1/models"):
            do {
                respondJSON(channel, 200, try await service.models(secret: secret, bearer: bearer), keepAlive: keepAlive)
            } catch {
                let wire = UserRuntime.wireError(error)
                respondJSON(channel, wire.status, wire.body, keepAlive: keepAlive)
            }
        case (.POST, "/v1/messages"):
            await messages(service: service, body: body, secret: secret, bearer: bearer, channel: channel, keepAlive: keepAlive)
        default:
            respondJSON(channel, 404, WireError(status: 404, type: "not_found_error", message: "no route for \(head.method) \(path)").body, keepAlive: keepAlive)
        }
    }

    static func bearerToken(_ headers: HTTPHeaders) -> String? {
        if let auth = headers["authorization"].first {
            let trimmed = auth.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("bearer ") {
                return String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            }
            return trimmed
        }
        return headers["x-api-key"].first
    }

    private static func messages(service: RelayService, body: Data, secret: String?, bearer: String?, channel: Channel, keepAlive: Bool) async {
        let request: MessagesRequest
        let events: AsyncStream<RelayEvent>
        do {
            request = try AnthropicWire.parseRequest(body)
            events = try await service.messages(request, secret: secret, bearer: bearer)
        } catch {
            let wire = UserRuntime.wireError(error)
            return respondJSON(channel, wire.status, wire.body, keepAlive: keepAlive)
        }
        let messageId = "msg_agy_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24)

        var iterator = events.makeAsyncIterator()
        // Hold the head until the first event: an error that arrives before
        // any output gets its real HTTP status.
        guard let first = await iterator.next() else {
            return respondJSON(channel, 502, WireErrorEvent(status: 502, type: "api_error", message: "agy produced no response").body, keepAlive: keepAlive)
        }
        if case .failure(let error) = first {
            return respondJSON(channel, error.status, error.body, keepAlive: keepAlive)
        }

        if !request.stream {
            var aggregate = AnthropicMessageAggregator(messageId: String(messageId), model: request.model)
            aggregate.add(first)
            while let event = await iterator.next() { aggregate.add(event) }
            if let failure = aggregate.failure {
                return respondJSON(channel, failure.status, failure.body, keepAlive: keepAlive)
            }
            return respondJSON(channel, 200, aggregate.body, keepAlive: keepAlive)
        }

        var headers = HTTPHeaders()
        headers.add(name: "content-type", value: "text/event-stream")
        headers.add(name: "cache-control", value: "no-cache")
        headers.add(name: "connection", value: "close")
        writeHead(channel, HTTPResponseHead(version: .http1_1, status: .ok, headers: headers))
        let pinger = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if Task.isCancelled { break }
                writeBody(channel, AnthropicSSEEncoder.ping)
            }
        }
        var encoder = AnthropicSSEEncoder(messageId: String(messageId), model: request.model)
        writeBody(channel, encoder.encode(first).joined())
        while let event = await iterator.next() {
            writeBody(channel, encoder.encode(event).joined())
        }
        pinger.cancel()
        end(channel, keepAlive: false)
    }

    // MARK: - Writing (event-loop safe)

    static func respondJSON(_ channel: Channel, _ status: Int, _ json: JSONValue, keepAlive: Bool) {
        let data = (try? json.encoded()) ?? Data()
        var headers = HTTPHeaders()
        headers.add(name: "content-type", value: "application/json")
        headers.add(name: "content-length", value: String(data.count))
        if !keepAlive { headers.add(name: "connection", value: "close") }
        writeHead(channel, HTTPResponseHead(version: .http1_1, status: HTTPResponseStatus(statusCode: status), headers: headers))
        channel.eventLoop.execute {
            var buffer = channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            channel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
        }
        end(channel, keepAlive: keepAlive)
    }

    private static func writeHead(_ channel: Channel, _ head: HTTPResponseHead) {
        channel.eventLoop.execute {
            channel.writeAndFlush(HTTPServerResponsePart.head(head), promise: nil)
        }
    }

    private static func writeBody(_ channel: Channel, _ text: String) {
        guard !text.isEmpty else { return }
        channel.eventLoop.execute {
            var buffer = channel.allocator.buffer(capacity: text.utf8.count)
            buffer.writeString(text)
            channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
        }
    }

    private static func end(_ channel: Channel, keepAlive: Bool) {
        channel.eventLoop.execute {
            let done = channel.writeAndFlush(HTTPServerResponsePart.end(nil))
            if !keepAlive { done.whenComplete { _ in channel.close(promise: nil) } }
        }
    }
}
