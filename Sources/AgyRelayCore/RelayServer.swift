import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOHTTP1

/// The relay's HTTP front. For now it serves `GET /healthz` and answers the
/// Anthropic Messages route with 501 until the ACP bridge lands.
public final class RelayServer: Sendable {
    public let config: RelayConfig
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    private let channel = NIOLockedValueBox<Channel?>(nil)

    public init(config: RelayConfig) {
        self.config = config
    }

    /// Bind and return the bound port.
    @discardableResult
    public func start() async throws -> Int {
        let config = config
        let bound = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { child in
                child.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    child.pipeline.addHandler(RelayHTTPHandler(config: config))
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
        try? await group.shutdownGracefully()
    }
}

/// Minimal routing; the real `/v1/messages` handler replaces the 501.
final class RelayHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let config: RelayConfig
    private var head: HTTPRequestHead?

    init(config: RelayConfig) {
        self.config = config
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let h):
            head = h
        case .body:
            break
        case .end:
            guard let head else { return }
            self.head = nil
            respond(context: context, head: head)
        }
    }

    private func respond(context: ChannelHandlerContext, head: HTTPRequestHead) {
        let path = head.uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? head.uri
        switch (head.method, path) {
        case (.GET, "/healthz"):
            write(context: context, status: .ok, json: #"{"ok":true,"version":"\#(RelayVersion.current)"}"#)
        case (.POST, "/v1/messages"):
            write(context: context, status: .notImplemented,
                  json: #"{"type":"error","error":{"type":"not_implemented","message":"ACP bridge not implemented yet"}}"#)
        default:
            write(context: context, status: .notFound,
                  json: #"{"type":"error","error":{"type":"not_found_error","message":"not found"}}"#)
        }
    }

    private func write(context: ChannelHandlerContext, status: HTTPResponseStatus, json: String) {
        let bytes = Array(json.utf8)
        var headers = HTTPHeaders()
        headers.add(name: "content-type", value: "application/json")
        headers.add(name: "content-length", value: String(bytes.count))
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))), promise: nil)
        var buffer = context.channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
