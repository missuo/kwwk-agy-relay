import Foundation

/// Runtime configuration for the relay.
public struct RelayConfig: Sendable {
    /// Address the HTTP server binds.
    public var host: String
    public var port: Int
    /// Shared secret callers must send as `x-relay-secret`. Nil disables the
    /// check (local development only).
    public var relaySecret: String?
    /// The `agy` executable to run.
    public var agyPath: String
    /// Root directory for per-user state (agy app-data dirs, empty
    /// placeholder workspaces).
    public var dataRoot: String
    /// Development mode: skip token checks and per-user homes and run the
    /// machine's own signed-in `agy` for every caller.
    public var systemLogin: Bool
    /// Who may use the relay: lowercase emails (`me@example.com`) and/or
    /// domains (`@example.com`). Empty allows any account whose token agy
    /// accepts.
    public var allowedUsers: Set<String>
    /// How long a parked tool call waits for the client's tool_result before
    /// the session is dropped.
    public var toolResultTimeout: TimeInterval
    /// Live ACP sessions per user. Each holds an agy worker process
    /// (~250 MB), so the least recently used idle one is closed to make room;
    /// its conversation replays into a new session on its next turn.
    public var maxSessionsPerUser: Int
    /// Idle sessions older than this are closed.
    public var sessionIdleTimeout: TimeInterval
    /// A user's agy front process with no sessions left is stopped after this.
    public var userIdleTimeout: TimeInterval

    public init(
        host: String = "127.0.0.1",
        port: Int = 8787,
        relaySecret: String? = nil,
        agyPath: String = "agy",
        dataRoot: String = FileManager.default.temporaryDirectory.appendingPathComponent("kwwk-agy-relay").path,
        systemLogin: Bool = false,
        allowedUsers: Set<String> = [],
        toolResultTimeout: TimeInterval = 15 * 60,
        maxSessionsPerUser: Int = 4,
        sessionIdleTimeout: TimeInterval = 10 * 60,
        userIdleTimeout: TimeInterval = 30 * 60
    ) {
        self.host = host
        self.port = port
        self.relaySecret = relaySecret
        self.agyPath = agyPath
        self.dataRoot = dataRoot
        self.systemLogin = systemLogin
        self.toolResultTimeout = toolResultTimeout
        self.maxSessionsPerUser = max(1, maxSessionsPerUser)
        self.sessionIdleTimeout = sessionIdleTimeout
        self.userIdleTimeout = userIdleTimeout
        self.allowedUsers = Set(allowedUsers.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    /// Whether `user` (a lowercase email) may use the relay.
    public func allows(_ user: String) -> Bool {
        guard !allowedUsers.isEmpty else { return true }
        if allowedUsers.contains(user) { return true }
        guard let at = user.lastIndex(of: "@") else { return false }
        return allowedUsers.contains(String(user[at...]))
    }
}

public enum RelayVersion {
    public static let current = "0.0.1"
}
