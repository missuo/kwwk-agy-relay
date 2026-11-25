import Foundation
import NIOConcurrencyHelpers
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Error from an `agy acp` connection.
public struct ACPError: Error, Sendable, CustomStringConvertible {
    public let message: String
    /// JSON-RPC error code when the agent answered with an error.
    public let code: Int?
    public init(_ message: String, code: Int? = nil) {
        self.message = message
        self.code = code
    }
    public var description: String { message }
}

/// Minimal Agent Client Protocol client: newline-delimited JSON-RPC 2.0 over
/// the stdio of a spawned `agy acp`.
///
/// Responses resume the matching `request`; `session/update` notifications go
/// to the handler registered for their `sessionId`; agent-to-client requests
/// (permission prompts) go to `agentRequestHandler`.
final class ACPClient: Sendable {
    typealias UpdateHandler = @Sendable (JSONValue) -> Void
    typealias AgentRequestHandler = @Sendable (_ method: String, _ params: JSONValue) async -> Result<JSONValue, ACPError>

    private struct State {
        var nextId = 1
        var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
        var sessionHandlers: [String: UpdateHandler] = [:]
        var stdin: FileHandle?
        var process: Process?
        var closed = false
        var closeReason: String?
        var stderrTail = Data()
    }

    private let state = NIOLockedValueBox(State())
    private let writeLock = NIOLock()
    private let agentRequestHandler: AgentRequestHandler

    /// What `initialize` answered, once `start` returned.
    let agentCapabilities = NIOLockedValueBox<JSONValue>(.null)

    init(agentRequestHandler: @escaping AgentRequestHandler) {
        self.agentRequestHandler = agentRequestHandler
    }

    var isAlive: Bool {
        state.withLockedValue { !$0.closed && $0.stdin != nil }
    }

    /// The last bytes `agy` wrote to stderr, for error messages.
    var diagnostics: String? {
        let tail = state.withLockedValue { $0.stderrTail }
        let text = String(decoding: tail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    // MARK: - Lifecycle

    /// Spawn `executable acp <arguments>` with `environment` in `cwd` and run
    /// the ACP `initialize` handshake.
    func start(executable: String, arguments: [String], environment: [String: String], cwd: URL) async throws {
        Self.ignoreSIGPIPE
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["acp"] + arguments
        process.currentDirectoryURL = cwd
        process.environment = environment
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        process.terminationHandler = { [weak self] proc in
            self?.shutdown(reason: "agy acp exited with status \(proc.terminationStatus)")
        }
        state.withLockedValue { state in
            state.process = process
            state.stdin = stdin.fileHandleForWriting
        }
        do {
            try process.run()
        } catch {
            shutdown(reason: "could not start \(executable): \(error.localizedDescription)")
            throw ACPError("could not start \(executable): \(error.localizedDescription)")
        }

        let stdoutReader = stdout.fileHandleForReading
        Thread.detachNewThread { [self] in
            var buffer = Data()
            while true {
                let chunk = stdoutReader.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    if !line.isEmpty { receive(Data(line)) }
                }
            }
            shutdown(reason: "agy acp closed its output")
        }
        let stderrReader = stderr.fileHandleForReading
        Thread.detachNewThread { [self] in
            while true {
                let chunk = stderrReader.availableData
                if chunk.isEmpty { break }
                state.withLockedValue { state in
                    state.stderrTail.append(chunk)
                    if state.stderrTail.count > 4096 { state.stderrTail = state.stderrTail.suffix(4096) }
                }
            }
        }

        let result = try await request("initialize", params: [
            "protocolVersion": 1,
            "clientCapabilities": [
                "fs": ["readTextFile": false, "writeTextFile": false],
                "terminal": false,
            ],
            "clientInfo": ["name": "kwwk-agy-relay", "version": .string(RelayVersion.current)],
        ], timeout: 60)
        agentCapabilities.withLockedValue { $0 = result }
    }

    /// Stop the agent process and fail every pending request.
    func close() {
        shutdown(reason: "closed")
        let process = state.withLockedValue { $0.process }
        if let process, process.isRunning { process.terminate() }
    }

    private static let ignoreSIGPIPE: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()

    private func shutdown(reason: String) {
        let (pending, stdin): ([CheckedContinuation<JSONValue, Error>], FileHandle?) = state.withLockedValue { state in
            if state.closed { return ([], nil) }
            state.closed = true
            state.closeReason = reason
            let pending = Array(state.pending.values)
            state.pending.removeAll()
            let stdin = state.stdin
            state.stdin = nil
            return (pending, stdin)
        }
        try? stdin?.close()
        let detail = diagnostics.map { "\(reason): \($0)" } ?? reason
        for cont in pending { cont.resume(throwing: ACPError(detail)) }
    }

    // MARK: - Sessions

    func setSessionHandler(_ sessionId: String, _ handler: UpdateHandler?) {
        state.withLockedValue { $0.sessionHandlers[sessionId] = handler }
    }

    // MARK: - Outgoing

    /// Send a request and await its result; with `timeout`, a request agy has
    /// not answered by then fails instead of hanging.
    func request(_ method: String, params: JSONValue, timeout: TimeInterval? = nil) async throws -> JSONValue {
        try await withCheckedThrowingContinuation { cont in
            let id: Int? = state.withLockedValue { state in
                if state.closed { return nil }
                let id = state.nextId
                state.nextId += 1
                state.pending[id] = cont
                return id
            }
            guard let id else {
                let reason = state.withLockedValue { $0.closeReason } ?? "closed"
                cont.resume(throwing: ACPError("agy acp is not running (\(reason))"))
                return
            }
            do {
                try write(["jsonrpc": "2.0", "id": .int(id), "method": .string(method), "params": params])
            } catch {
                let cont = state.withLockedValue { $0.pending.removeValue(forKey: id) }
                cont?.resume(throwing: error)
                return
            }
            if let timeout {
                Task { [self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    let cont = state.withLockedValue { $0.pending.removeValue(forKey: id) }
                    cont?.resume(throwing: ACPError("agy acp did not answer \(method) within \(Int(timeout))s"))
                }
            }
        }
    }

    /// Send a notification (no response expected).
    func notify(_ method: String, params: JSONValue) {
        try? write(["jsonrpc": "2.0", "method": .string(method), "params": params])
    }

    private func write(_ message: JSONValue) throws {
        var data = try message.encoded()
        data.append(UInt8(ascii: "\n"))
        guard let handle = state.withLockedValue({ $0.closed ? nil : $0.stdin }) else {
            throw ACPError("agy acp is not running")
        }
        do {
            try writeLock.withLock { try handle.write(contentsOf: data) }
        } catch {
            throw ACPError("writing to agy acp failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Incoming

    private func receive(_ line: Data) {
        guard let message = try? JSONValue.decode(line), case .object(let object) = message else { return }
        let id = object["id"]
        if let method = object["method"]?.stringValue {
            let params = object["params"] ?? .null
            if let id {
                Task { [self] in
                    switch await agentRequestHandler(method, params) {
                    case .success(let value):
                        try? write(["jsonrpc": "2.0", "id": id, "result": value])
                    case .failure(let error):
                        try? write([
                            "jsonrpc": "2.0",
                            "id": id,
                            "error": ["code": .int(error.code ?? -32601), "message": .string(error.message)],
                        ])
                    }
                }
            } else if method == "session/update",
                      let sessionId = params["sessionId"]?.stringValue,
                      let update = params["update"] {
                let handler = state.withLockedValue { $0.sessionHandlers[sessionId] }
                handler?(update)
            }
            return
        }
        guard let id = id?.intValue else { return }
        guard let cont = state.withLockedValue({ $0.pending.removeValue(forKey: id) }) else { return }
        if case .object(let error)? = object["error"] {
            let text = error["message"]?.stringValue ?? "agy acp request failed"
            let detail = error["data"].map { $0.stringValue ?? $0.compactString }
            cont.resume(throwing: ACPError(detail.map { "\(text): \($0)" } ?? text, code: error["code"]?.intValue))
        } else {
            cont.resume(returning: object["result"] ?? .null)
        }
    }
}
