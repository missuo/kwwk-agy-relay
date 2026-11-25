import Foundation
import NIOConcurrencyHelpers

/// The relay's request logic, independent of HTTP: authenticate, find the
/// caller's `agy`, and answer Messages and model-listing requests.
public final class RelayService: Sendable {
    public let config: RelayConfig
    private let identity: IdentityResolver
    let server = MCPBridgeServer()
    private let runtimes = NIOLockedValueBox([String: UserRuntime]())
    private let sweeper = NIOLockedValueBox<Task<Void, Never>?>(nil)

    /// Sessions idle this long are closed; a user's `agy` with none left is stopped.
    public static let maxIdle: TimeInterval = 2 * 60 * 60

    public init(config: RelayConfig, identity: IdentityResolver? = nil) {
        self.config = config
        self.identity = identity ?? (config.systemLogin ? SystemLoginResolver() : GoogleTokenInfoResolver())
    }

    public func start() async throws {
        try await server.start()
        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
                await self?.sweep()
            }
        }
        sweeper.withLockedValue { $0 = task }
    }

    public func stop() async {
        sweeper.withLockedValue { $0?.cancel() }
        let all = runtimes.withLockedValue { runtimes -> [UserRuntime] in
            defer { runtimes.removeAll() }
            return Array(runtimes.values)
        }
        for runtime in all { await runtime.shutdown() }
        server.stop()
    }

    private func sweep() async {
        let all = runtimes.withLockedValue { $0 }
        for (user, runtime) in all where await runtime.sweep(maxIdle: Self.maxIdle) {
            await runtime.shutdown()
            runtimes.withLockedValue { $0[user] = nil }
        }
    }

    // MARK: - Auth

    /// Check the shared secret (constant time) and resolve the bearer token
    /// to the caller's runtime, installing the token as their credential.
    func authorize(secret: String?, bearer: String?) async throws -> UserRuntime {
        if let expected = config.relaySecret {
            guard let secret, Self.constantTimeEqual(secret, expected) else {
                throw WireError(status: 401, type: "authentication_error", message: "invalid or missing x-relay-secret")
            }
        }
        let token = bearer ?? ""
        guard config.systemLogin || !token.isEmpty else {
            throw WireError(status: 401, type: "authentication_error", message: "missing Authorization: Bearer <Google access token>")
        }
        let who: Identity
        do {
            who = try await identity.identify(token: token)
        } catch let error as WireError {
            throw error
        } catch {
            throw WireError(status: 502, type: "api_error", message: "token lookup failed: \(error.localizedDescription)")
        }
        guard config.systemLogin || config.allows(who.user) else {
            RelayLog.info("\(RelayLog.user(who.user)) refused: not in RELAY_ALLOWED_USERS")
            throw WireError(status: 403, type: "permission_error", message: "this account may not use the relay")
        }
        let runtime = runtimes.withLockedValue { runtimes -> UserRuntime in
            if let existing = runtimes[who.user] { return existing }
            let created = UserRuntime(user: who.user, config: config, server: server)
            runtimes[who.user] = created
            return created
        }
        try await runtime.install(token: token, identity: who)
        return runtime
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = UInt8(x.count == y.count ? 0 : 1)
        for i in 0..<max(x.count, y.count) {
            diff |= (i < x.count ? x[i] : 0) ^ (i < y.count ? y[i] : 0)
        }
        return diff == 0
    }

    /// Sessions opened for `user` so far (tests).
    func sessionsOpened(user: String) async -> Int {
        guard let runtime = runtimes.withLockedValue({ $0[user] }) else { return 0 }
        return await runtime.sessionsOpened
    }

    // MARK: - Endpoints

    /// `POST /v1/messages`: the event stream answering `request`.
    public func messages(_ request: MessagesRequest, secret: String?, bearer: String?) async throws -> AsyncStream<RelayEvent> {
        guard !request.turns.isEmpty else { throw WireError.invalid("messages: at least one message is required") }
        guard request.turns.last?.role == .user else {
            throw WireError.invalid("messages: the last message must have role user")
        }
        let runtime = try await authorize(secret: secret, bearer: bearer)
        do {
            return try await runtime.handle(request)
        } catch {
            throw UserRuntime.wireError(error)
        }
    }

    /// `GET /v1/agy/models`: the caller's model catalog, Anthropic list shape.
    public func models(secret: String?, bearer: String?) async throws -> JSONValue {
        let runtime = try await authorize(secret: secret, bearer: bearer)
        let available = try await runtime.availableModels()
        let data: [JSONValue] = available.compactMap { model in
            guard let id = model["modelId"]?.stringValue else { return nil }
            return [
                "type": "model",
                "id": .string("agy/" + id),
                "display_name": .string(model["name"]?.stringValue ?? id),
            ]
        }
        return ["data": .array(data), "has_more": false]
    }
}
