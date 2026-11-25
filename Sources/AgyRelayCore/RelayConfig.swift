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

    public init(
        host: String = "127.0.0.1",
        port: Int = 8787,
        relaySecret: String? = nil,
        agyPath: String = "agy",
        dataRoot: String = FileManager.default.temporaryDirectory.appendingPathComponent("kwwk-agy-relay").path
    ) {
        self.host = host
        self.port = port
        self.relaySecret = relaySecret
        self.agyPath = agyPath
        self.dataRoot = dataRoot
    }
}

public enum RelayVersion {
    public static let current = "0.0.1"
}
