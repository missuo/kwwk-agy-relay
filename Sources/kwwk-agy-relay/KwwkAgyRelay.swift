import ArgumentParser
import AgyRelayCore
import Foundation

@main
struct KwwkAgyRelay: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "kwwk-agy-relay",
        abstract: "Serve the Antigravity CLI (agy acp) as an Anthropic Messages endpoint for kwwk.",
        version: RelayVersion.current
    )

    @Option(help: "Address to bind.")
    var host = ProcessInfo.processInfo.environment["RELAY_HOST"] ?? "127.0.0.1"

    @Option(help: "Port to listen on.")
    var port = Int(ProcessInfo.processInfo.environment["RELAY_PORT"] ?? "") ?? 8787

    @Option(help: "Path to the agy executable.")
    var agy = ProcessInfo.processInfo.environment["AGY_PATH"] ?? "agy"

    @Option(help: "Directory for per-user agy state.")
    var dataRoot = ProcessInfo.processInfo.environment["RELAY_DATA_ROOT"]
        ?? FileManager.default.temporaryDirectory.appendingPathComponent("kwwk-agy-relay").path

    @Flag(help: "Development: skip token checks and use this machine's own signed-in agy for every caller.")
    var systemLogin = false

    static func seconds(_ key: String) -> TimeInterval? {
        ProcessInfo.processInfo.environment[key].flatMap(TimeInterval.init)
    }

    func run() async throws {
        let secret = ProcessInfo.processInfo.environment["RELAY_SECRET"].flatMap { $0.isEmpty ? nil : $0 }
        let allowed = Set((ProcessInfo.processInfo.environment["RELAY_ALLOWED_USERS"] ?? "")
            .split(separator: ",").map(String.init))
        let config = RelayConfig(host: host, port: port, relaySecret: secret, agyPath: agy, dataRoot: dataRoot,
                                 systemLogin: systemLogin, allowedUsers: allowed,
                                 toolResultTimeout: Self.seconds("RELAY_TOOL_TIMEOUT") ?? 15 * 60,
                                 maxSessionsPerUser: Int(ProcessInfo.processInfo.environment["RELAY_MAX_SESSIONS"] ?? "") ?? 4,
                                 sessionIdleTimeout: Self.seconds("RELAY_SESSION_IDLE") ?? 10 * 60,
                                 userIdleTimeout: Self.seconds("RELAY_USER_IDLE") ?? 30 * 60)
        let server = RelayServer(config: config)
        let bound = try await server.start()
        FileHandle.standardError.write(Data("kwwk-agy-relay \(RelayVersion.current) listening on \(host):\(bound)\n".utf8))
        if allowed.isEmpty && !systemLogin {
            FileHandle.standardError.write(Data("warning: RELAY_ALLOWED_USERS is not set; any Google account agy accepts may use this relay\n".utf8))
        }
        try await server.wait()
    }
}
