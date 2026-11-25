import Foundation

/// One ACP session serving one client conversation across HTTP requests.
///
/// A *round* is one HTTP response. A prompt that calls client tools spans
/// several rounds: when agy calls a tool, the round ends with a `tool_use`
/// block and the MCP call stays parked; the client's next request carries
/// the `tool_result`, which un-parks the call, and the same ACP prompt
/// streams on into the new response.
///
/// Everything agy produces — session updates, tool calls, the prompt's end —
/// goes through one ordered inbox, so a tool call can never overtake the text
/// streamed before it.
actor Conversation {
    enum Phase: Sendable { case idle, running, awaitingTools }

    /// How a request continues this conversation.
    enum Continuation: Sendable {
        /// Un-park the pending tool calls with these results (keyed by
        /// tool-use id); `note` is user text sent alongside them.
        case resume(results: [String: (content: [Block], isError: Bool)], note: String?)
        /// Send these new user turns as a fresh prompt into the idle session.
        case prompt([Turn])
        /// First round of a new session: send these prompt blocks.
        case fresh([JSONValue])
    }

    private enum Inbound: Sendable {
        case update(JSONValue)
        case toolCall(name: String, arguments: JSONValue, reply: CheckedContinuation<MCPBridgeServer.CallResult, Never>)
        case promptDone(Result<JSONValue, ACPErrorBox>)
    }

    struct ACPErrorBox: Error, Sendable { let message: String; let code: Int? }

    let sessionId: String
    let routeToken: String
    let setupDigest: String
    let tokenDigest: String?
    private let client: ACPClient
    private let server: MCPBridgeServer
    private(set) var modelSlug: String

    private(set) var phase: Phase = .idle
    private(set) var lastActivity = Date()
    private(set) var disposed = false
    private var consumedCount = 0
    private var consumedDigest = ""
    private var sink: AsyncStream<RelayEvent>.Continuation?
    private var roundTurns: [Turn] = []
    private var replyText = ""
    private var replyToolIds: [String] = []
    private var pending: [(id: String, reply: CheckedContinuation<MCPBridgeServer.CallResult, Never>)] = []
    private var imagesSupported: Bool
    private var finalUsage = RelayUsage()

    private let inbox: AsyncStream<Inbound>.Continuation
    private let onDispose: @Sendable (String) -> Void

    /// How long parked tool calls wait for the client before the session is dropped.
    private let toolResultTimeout: TimeInterval

    init(
        sessionId: String,
        routeToken: String,
        setupDigest: String,
        tokenDigest: String?,
        modelSlug: String,
        client: ACPClient,
        server: MCPBridgeServer,
        toolResultTimeout: TimeInterval = 15 * 60,
        onDispose: @escaping @Sendable (String) -> Void
    ) {
        self.toolResultTimeout = toolResultTimeout
        self.sessionId = sessionId
        self.routeToken = routeToken
        self.setupDigest = setupDigest
        self.tokenDigest = tokenDigest
        self.modelSlug = modelSlug
        self.client = client
        self.server = server
        self.onDispose = onDispose
        self.imagesSupported = Transcript.supportsImages(slug: modelSlug)
        let (stream, inbox) = AsyncStream<Inbound>.makeStream()
        self.inbox = inbox
        Task { [weak self] in
            for await item in stream {
                guard let self else { return }
                await self.handle(item)
            }
        }
    }

    // MARK: - Entry points from agy (any thread)

    nonisolated func receive(update: JSONValue) {
        inbox.yield(.update(update))
    }

    /// MCP `tools/call` for this session: parks until the client answers.
    nonisolated func toolCalled(name: String, arguments: JSONValue) async -> MCPBridgeServer.CallResult {
        await withCheckedContinuation { reply in
            if case .terminated = inbox.yield(.toolCall(name: name, arguments: arguments, reply: reply)) {
                reply.resume(returning: .init(content: [Transcript.textBlock("The session has ended.")], isError: true))
            }
        }
    }

    // MARK: - Matching

    /// How `request` continues this conversation, or nil when it does not.
    func match(_ request: MessagesRequest, setupDigest: String) -> Continuation? {
        guard !disposed, sink == nil, consumedCount > 0, setupDigest == self.setupDigest else { return nil }
        let turns = request.turns
        guard turns.count > consumedCount,
              Transcript.digest(turns[..<consumedCount]) == consumedDigest else { return nil }
        let trailing = Array(turns[consumedCount...])
        guard trailing.allSatisfy({ $0.role == .user }) else { return nil }

        switch phase {
        case .awaitingTools:
            var results: [String: (content: [Block], isError: Bool)] = [:]
            var notes: [String] = []
            for block in trailing.flatMap(\.blocks) {
                switch block {
                case .toolResult(let id, let content, let isError): results[id] = (content, isError)
                case .text(let t) where !t.isEmpty: notes.append(t)
                default: continue
                }
            }
            guard pending.allSatisfy({ results[$0.id] != nil }) else { return nil }
            return .resume(results: results, note: notes.isEmpty ? nil : notes.joined(separator: "\n"))
        case .idle:
            return .prompt(trailing)
        case .running:
            return nil
        }
    }

    /// Idle with nothing parked: safe to drop.
    var isIdle: Bool { !disposed && sink == nil && phase == .idle }

    // MARK: - Rounds

    /// Start a round answering `request`, streaming into `sink`.
    func begin(_ request: MessagesRequest, _ continuation: Continuation, sink: AsyncStream<RelayEvent>.Continuation) async {
        self.sink = sink
        roundTurns = request.turns
        replyText = ""
        replyToolIds = []
        lastActivity = Date()

        switch continuation {
        case .resume(let results, let note):
            phase = .running
            let parked = pending
            pending = []
            for (index, call) in parked.enumerated() {
                let result = results[call.id] ?? (content: [], isError: true)
                var content = Transcript.mcpContent(result.content, imagesSupported: imagesSupported)
                if let note, index == parked.count - 1 {
                    content.append(Transcript.textBlock("[the user added]\n\(note)"))
                }
                call.reply.resume(returning: .init(content: content, isError: result.isError))
            }
        case .prompt(let turns):
            if request.slug != modelSlug {
                do {
                    _ = try await client.request("session/set_model", params: [
                        "sessionId": .string(sessionId), "modelId": .string(request.slug),
                    ], timeout: 30)
                    modelSlug = request.slug
                    imagesSupported = Transcript.supportsImages(slug: modelSlug)
                } catch {
                    fail(status: 400, type: "invalid_request_error", message: "agy rejected model \(request.slug): \(error)")
                    return
                }
            }
            startPrompt(Transcript.inputBlocks(turns, imagesSupported: imagesSupported))
        case .fresh(let blocks):
            startPrompt(blocks)
        }
    }

    private func startPrompt(_ blocks: [JSONValue]) {
        phase = .running
        finalUsage = RelayUsage()
        let client = client
        let sessionId = sessionId
        let inbox = inbox
        Task {
            do {
                let result = try await client.request("session/prompt", params: [
                    "sessionId": .string(sessionId), "prompt": .array(blocks),
                ])
                inbox.yield(.promptDone(.success(result)))
            } catch {
                let acp = error as? ACPError
                inbox.yield(.promptDone(.failure(ACPErrorBox(message: acp?.message ?? "\(error)", code: acp?.code))))
            }
        }
    }

    /// The client hung up mid-round: stop agy and drop the session.
    func clientGone() {
        guard sink != nil else { return }
        sink = nil
        dispose(reason: "the client disconnected")
    }

    // MARK: - Inbox

    private func handle(_ item: Inbound) {
        lastActivity = Date()
        switch item {
        case .update(let update):
            switch update["sessionUpdate"]?.stringValue {
            case "agent_message_chunk":
                if let text = update["content"]?["text"]?.stringValue, !text.isEmpty {
                    replyText += text
                    sink?.yield(.text(text))
                }
            case "agent_thought_chunk":
                if let text = update["content"]?["text"]?.stringValue, !text.isEmpty {
                    sink?.yield(.thinking(text))
                }
            default:
                break
            }

        case .toolCall(let name, let arguments, let reply):
            guard !disposed, sink != nil else {
                reply.resume(returning: .init(content: [Transcript.textBlock("No client is attached to this session.")], isError: true))
                return
            }
            let id = "toolu_agy_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24)
            replyToolIds.append(String(id))
            pending.append((String(id), reply))
            phase = .awaitingTools
            sink?.yield(.toolUse(id: String(id), name: name, input: arguments))
            // agy runs tools one at a time today; a short grace lets any
            // parallel calls join this round before it closes.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 150_000_000)
                await self?.closeToolRound()
            }

        case .promptDone(let result):
            switch result {
            case .success(let value):
                if case .object(let usage)? = value["usage"] {
                    finalUsage = RelayUsage(
                        input: usage["inputTokens"]?.intValue ?? 0,
                        output: (usage["outputTokens"]?.intValue ?? 0) + (usage["thoughtTokens"]?.intValue ?? 0),
                        cacheRead: usage["cachedReadTokens"]?.intValue ?? 0,
                        cacheWrite: usage["cachedWriteTokens"]?.intValue ?? 0
                    )
                }
                let stop: String
                switch value["stopReason"]?.stringValue {
                case "max_tokens": stop = "max_tokens"
                case "refusal": stop = "refusal"
                default: stop = "end_turn"
                }
                phase = .idle
                finishRound(stopReason: stop, usage: finalUsage)
            case .failure(let error):
                let auth = error.message.lowercased().contains("auth") || error.code == -32000
                fail(status: auth ? 401 : 502,
                     type: auth ? "authentication_error" : "api_error",
                     message: "agy: \(error.message)")
            }
        }
    }

    private func closeToolRound() {
        guard phase == .awaitingTools, sink != nil, !pending.isEmpty else { return }
        finishRound(stopReason: "tool_use", usage: RelayUsage())
        let parkedIds = pending.map(\.id)
        let timeout = toolResultTimeout
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            await self?.expireParkedCalls(parkedIds)
        }
    }

    private func expireParkedCalls(_ ids: [String]) {
        guard phase == .awaitingTools, pending.map(\.id) == ids else { return }
        dispose(reason: "no tool result arrived within \(Int(toolResultTimeout))s")
    }

    private func finishRound(stopReason: String, usage: RelayUsage) {
        sink?.yield(.finish(stopReason: stopReason, usage: usage))
        let reply = Turn(
            role: .assistant,
            blocks: [.text(replyText)] + replyToolIds.map { .toolUse(id: $0, name: "", input: .null) }
        )
        consumedCount = roundTurns.count + 1
        consumedDigest = Transcript.digest(roundTurns + [reply])
        let done = sink
        sink = nil
        done?.finish()
    }

    private func fail(status: Int, type: String, message: String) {
        sink?.yield(.failure(WireErrorEvent(status: status, type: type, message: message)))
        sink?.finish()
        sink = nil
        dispose(reason: message)
    }

    /// Stop agy's turn, release parked calls, and retire the session.
    func dispose(reason: String) {
        guard !disposed else { return }
        disposed = true
        RelayLog.info("session \(sessionId.prefix(8)) closed: \(reason)")
        if phase != .idle {
            client.notify("session/cancel", params: ["sessionId": .string(sessionId)])
        }
        for call in pending {
            call.reply.resume(returning: .init(content: [Transcript.textBlock("The relay dropped this call: \(reason)")], isError: true))
        }
        pending = []
        if let sink {
            sink.yield(.failure(WireErrorEvent(status: 502, type: "api_error", message: reason)))
            sink.finish()
            self.sink = nil
        }
        server.setRoute(routeToken, nil)
        client.setSessionHandler(sessionId, nil)
        let client = client
        let sessionId = sessionId
        Task { _ = try? await client.request("session/close", params: ["sessionId": .string(sessionId)], timeout: 30) }
        inbox.finish()
        onDispose(sessionId)
    }
}
