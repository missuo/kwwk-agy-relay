import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// One user's `agy`: a private HOME holding their credential file, one
/// `agy acp --process-per-session` process, and the ACP sessions behind their
/// conversations.
///
/// With `--process-per-session` every session runs in a worker that reads
/// the credential file when it starts, so a new access token takes effect for
/// sessions opened after it is written. Idle sessions opened under an older
/// token are retired when the token changes; the next turn replays history
/// into a fresh session.
actor UserRuntime {
    let user: String
    private let config: RelayConfig
    private let server: MCPBridgeServer
    private let home: URL
    private let workspace: URL
    private var client: ACPClient?
    private var starting: Task<ACPClient, Error>?
    private var tokenDigest: String?
    private var conversations: [String: Conversation] = [:]
    private(set) var lastActivity = Date()
    /// `models.availableModels` from the latest `session/new`.
    private(set) var models: [JSONValue] = []
    /// Conversation sessions opened so far (tests check reuse).
    private(set) var sessionsOpened = 0

    init(user: String, config: RelayConfig, server: MCPBridgeServer) {
        self.user = user
        self.config = config
        self.server = server
        let base = URL(fileURLWithPath: config.dataRoot, isDirectory: true)
            .appendingPathComponent("users", isDirectory: true)
            .appendingPathComponent(String(Transcript.sha256(user).prefix(20)), isDirectory: true)
        self.home = base.appendingPathComponent("home", isDirectory: true)
        self.workspace = base.appendingPathComponent("workspace", isDirectory: true)
    }

    // MARK: - Credentials

    /// Install `token` as this user's agy credential when it changed.
    func install(token: String, identity: Identity) async throws {
        lastActivity = Date()
        guard !config.systemLogin else { return }
        let digest = Transcript.sha256(token)
        guard digest != tokenDigest else { return }
        try CredentialFile.write(home: home, accessToken: token, email: identity.user, expiresIn: identity.expiresIn)
        tokenDigest = digest
        RelayLog.info("\(RelayLog.user(user)) installed access token (expires in \(identity.expiresIn)s)")
        // Sessions opened under the old token keep it; retire the idle ones.
        for (id, conversation) in conversations {
            guard await conversation.isIdle else { continue }
            conversations[id] = nil
            await conversation.dispose(reason: "access token rotated")
        }
    }

    // MARK: - agy process

    private func connectedClient() async throws -> ACPClient {
        if let client, client.isAlive { return client }
        if let starting { return try await starting.value }
        for conversation in conversations.values { await conversation.dispose(reason: "agy restarted") }
        conversations.removeAll()

        let config = config
        let home = home
        let workspace = workspace
        let task = Task<ACPClient, Error> {
            let fm = FileManager.default
            try fm.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var environment = ProcessInfo.processInfo.environment
            if !config.systemLogin {
                try fm.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                // A clean environment: the user's own HOME and no desktop
                // session bus, so agy keeps credentials in its file store.
                environment = [
                    "HOME": home.path,
                    "PATH": environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin",
                    "LANG": environment["LANG"] ?? "C.UTF-8",
                ]
            }
            let client = ACPClient { method, params in
                guard method == "session/request_permission" else {
                    return .failure(ACPError("method not found: \(method)", code: -32601))
                }
                return .success(PermissionPolicy.outcome(params))
            }
            do {
                try await client.start(
                    executable: Self.resolveExecutable(config.agyPath, path: environment["PATH"]),
                    arguments: ["--process-per-session"],
                    environment: environment,
                    cwd: workspace
                )
            } catch {
                client.close()
                throw error
            }
            return client
        }
        starting = task
        defer { starting = nil }
        let connected = try await task.value
        client = connected
        return connected
    }

    static func resolveExecutable(_ name: String, path: String?) -> String {
        if name.contains("/") { return (name as NSString).expandingTildeInPath }
        for dir in (path ?? "").split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return name
    }

    func shutdown() async {
        for conversation in conversations.values { await conversation.dispose(reason: "relay shutting down") }
        conversations.removeAll()
        client?.close()
        client = nil
    }

    /// Close sessions idle past `sessionIdleTimeout`; true when no session is
    /// left and the user has been away past `userIdleTimeout`.
    func sweep() async -> Bool {
        let now = Date()
        for (id, conversation) in conversations {
            if await conversation.isIdle,
               await conversation.lastActivity < now.addingTimeInterval(-config.sessionIdleTimeout) {
                conversations[id] = nil
                await conversation.dispose(reason: "idle for \(Int(config.sessionIdleTimeout))s")
            }
        }
        return conversations.isEmpty && lastActivity < now.addingTimeInterval(-config.userIdleTimeout)
    }

    /// Close least recently used idle sessions until a new one fits under
    /// `maxSessionsPerUser`. Busy sessions are never evicted.
    private func makeRoom() async {
        var idle: [(id: String, conversation: Conversation, last: Date)] = []
        for (id, conversation) in conversations where await conversation.isIdle {
            idle.append((id, conversation, await conversation.lastActivity))
        }
        idle.sort { $0.last < $1.last }
        var excess = conversations.count + 1 - config.maxSessionsPerUser
        for entry in idle where excess > 0 {
            conversations[entry.id] = nil
            await entry.conversation.dispose(reason: "evicted to stay within \(config.maxSessionsPerUser) sessions")
            excess -= 1
        }
    }

    // MARK: - Requests

    /// Answer `request`: continue the conversation it extends, or open a
    /// session for it.
    func handle(_ request: MessagesRequest) async throws -> AsyncStream<RelayEvent> {
        lastActivity = Date()
        let client = try await connectedClient()
        let setup = Transcript.setupDigest(system: request.system, tools: request.tools)
        let (stream, sink) = AsyncStream<RelayEvent>.makeStream()

        for conversation in conversations.values {
            if let continuation = await conversation.match(request, setupDigest: setup) {
                let kind: String
                switch continuation {
                case .resume: kind = "resume tool results"
                case .prompt: kind = "continue"
                case .fresh: kind = "fresh"
                }
                RelayLog.info("\(RelayLog.user(user)) session \(conversation.sessionId.prefix(8)) \(kind) model=\(request.slug)")
                watch(sink, conversation)
                await conversation.begin(request, continuation, sink: sink)
                return stream
            }
        }

        await makeRoom()
        let conversation = try await open(request, setup: setup, client: client)
        let split = Transcript.trailingInputStart(request.turns)
        var prompt: [JSONValue] = []
        if let replay = Transcript.historyReplay(Array(request.turns[..<split])) {
            prompt.append(Transcript.textBlock(replay))
        }
        prompt += Transcript.inputBlocks(Array(request.turns[split...]), imagesSupported: Transcript.supportsImages(slug: request.slug))
        watch(sink, conversation)
        await conversation.begin(request, .fresh(prompt), sink: sink)
        return stream
    }

    private func watch(_ sink: AsyncStream<RelayEvent>.Continuation, _ conversation: Conversation) {
        sink.onTermination = { reason in
            if case .cancelled = reason {
                Task { await conversation.clientGone() }
            }
        }
    }

    private func open(_ request: MessagesRequest, setup: String, client: ACPClient) async throws -> Conversation {
        let routeToken = MCPBridgeServer.randomToken()
        let ref = ConversationRef()
        server.setRoute(routeToken, .init(tools: request.tools) { name, arguments in
            guard let conversation = ref.value else {
                return .init(content: [Transcript.textBlock("The session is not ready.")], isError: true)
            }
            return await conversation.toolCalled(name: name, arguments: arguments)
        })
        var mcpServers: [JSONValue] = []
        if !request.tools.isEmpty, let entry = server.serverEntry(for: routeToken) {
            mcpServers.append(entry)
        }
        let created: JSONValue
        do {
            created = try await client.request("session/new", params: [
                "cwd": .string(workspace.path),
                "mcpServers": .array(mcpServers),
                "_meta": ["antigravity": ["systemPrompt": [
                    "append": .string(Transcript.systemAppendix(system: request.system, hasTools: !request.tools.isEmpty)),
                ]]],
            ], timeout: 90)
        } catch {
            server.setRoute(routeToken, nil)
            throw Self.wireError(error)
        }
        guard let sessionId = created["sessionId"]?.stringValue else {
            server.setRoute(routeToken, nil)
            throw WireError(status: 502, type: "api_error", message: "agy did not return a session id")
        }
        if let available = created["models"]?["availableModels"]?.arrayValue, !available.isEmpty {
            models = available
        }
        let currentModel = created["models"]?["currentModelId"]?.stringValue
        if currentModel == nil {
            // No model catalog means agy could not reach its backend with
            // this credential.
            server.setRoute(routeToken, nil)
            _ = try? await client.request("session/close", params: ["sessionId": .string(sessionId)], timeout: 10)
            throw WireError(status: 401, type: "authentication_error",
                            message: "agy could not load models with this access token")
        }
        if currentModel != request.slug {
            do {
                _ = try await client.request("session/set_model", params: [
                    "sessionId": .string(sessionId), "modelId": .string(request.slug),
                ], timeout: 30)
            } catch {
                server.setRoute(routeToken, nil)
                _ = try? await client.request("session/close", params: ["sessionId": .string(sessionId)], timeout: 10)
                throw WireError(status: 400, type: "invalid_request_error", message: "unknown agy model \(request.slug): \(error)")
            }
        }
        sessionsOpened += 1
        RelayLog.info("\(RelayLog.user(user)) session \(sessionId.prefix(8)) opened model=\(request.slug) tools=\(request.tools.count) turns=\(request.turns.count)")
        let conversation = Conversation(
            sessionId: sessionId,
            routeToken: routeToken,
            setupDigest: setup,
            tokenDigest: tokenDigest,
            modelSlug: request.slug,
            client: client,
            server: server,
            toolResultTimeout: config.toolResultTimeout,
            onDispose: { [weak self] id in Task { await self?.forget(id) } }
        )
        ref.value = conversation
        client.setSessionHandler(sessionId) { update in conversation.receive(update: update) }
        conversations[sessionId] = conversation
        return conversation
    }

    private func forget(_ sessionId: String) {
        conversations[sessionId] = nil
    }

    /// Open (and close) a throwaway session to learn the model catalog.
    func availableModels() async throws -> [JSONValue] {
        lastActivity = Date()
        if !models.isEmpty { return models }
        let client = try await connectedClient()
        let created: JSONValue
        do {
            created = try await client.request("session/new", params: [
                "cwd": .string(workspace.path), "mcpServers": [],
            ], timeout: 90)
        } catch {
            throw Self.wireError(error)
        }
        if let id = created["sessionId"]?.stringValue {
            _ = try? await client.request("session/close", params: ["sessionId": .string(id)], timeout: 10)
        }
        models = created["models"]?["availableModels"]?.arrayValue ?? []
        return models
    }

    static func wireError(_ error: Error) -> WireError {
        if let wire = error as? WireError { return wire }
        let acp = error as? ACPError
        let message = acp?.message ?? "\(error)"
        if acp?.code == -32000 || message.lowercased().contains("auth") {
            return WireError(status: 401, type: "authentication_error", message: "agy: \(message)")
        }
        return WireError(status: 502, type: "api_error", message: "agy: \(message)")
    }
}

/// Late-bound pointer from an MCP route to its conversation (the route must
/// exist before `session/new`, the conversation only after).
final class ConversationRef: @unchecked Sendable {
    private let lock = NSLock()
    private weak var _value: Conversation?
    var value: Conversation? {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

/// agy's `session/request_permission`: allow the client's MCP tools once,
/// refuse everything else once.
enum PermissionPolicy {
    static func outcome(_ params: JSONValue) -> JSONValue {
        let call = params["toolCall"]
        let name = call?["name"]?.stringValue ?? call?["title"]?.stringValue ?? ""
        let ours = name.hasPrefix(MCPBridgeServer.toolPrefix)
        let options = params["options"]?.arrayValue ?? []
        let kinds = ours ? ["allow_once", "allow_always"] : ["reject_once", "reject_always"]
        let fallbackIds = ours ? ["allow"] : ["deny", "reject"]
        let pick = kinds.lazy.compactMap { kind in options.first { $0["kind"]?.stringValue == kind } }.first
            ?? options.first { fallbackIds.contains($0["optionId"]?.stringValue ?? "") }
        guard let optionId = pick?["optionId"] else { return ["outcome": ["outcome": "cancelled"]] }
        return ["outcome": ["outcome": "selected", "optionId": optionId]]
    }
}

/// agy's file credential store (`~/.gemini/antigravity-cli`), used on hosts
/// without a desktop keyring.
enum CredentialFile {
    static func directory(home: URL) -> URL {
        home.appendingPathComponent(".gemini/antigravity-cli", isDirectory: true)
    }

    static func write(home: URL, accessToken: String, email: String, expiresIn: Int) throws {
        let fm = FileManager.default
        let dir = directory(home: home)
        try fm.createDirectory(at: dir.appendingPathComponent("cache"), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // A little early, so agy never uses a token the client already replaced.
        let lifetime = max(60, expiresIn - 60)
        let document: JSONValue = [
            "token": [
                "access_token": .string(accessToken),
                "token_type": "Bearer",
                "expiry": .string(formatter.string(from: Date().addingTimeInterval(TimeInterval(lifetime)))),
                "expires_in": .int(lifetime),
            ],
            "auth_method": "consumer",
            "id_token_email": .string(email),
        ]
        try atomicWrite(try document.encoded(), to: dir.appendingPathComponent("antigravity-oauth-token"))
        try atomicWrite(Data(#"{"methodId":"oauth-personal"}"#.utf8), to: dir.appendingPathComponent("cache/acp-auth-state.json"))
    }

    private static func atomicWrite(_ data: Data, to url: URL) throws {
        let tmp = url.appendingPathExtension("tmp-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw WireError(status: 500, type: "api_error", message: "cannot write \(url.lastPathComponent)")
        }
        if rename(tmp.path, url.path) != 0 {
            try? FileManager.default.removeItem(at: tmp)
            throw WireError(status: 500, type: "api_error", message: "cannot replace \(url.lastPathComponent)")
        }
    }
}
