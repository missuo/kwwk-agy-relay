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

    func run() async throws {
        let secret = ProcessInfo.processInfo.environment["RELAY_SECRET"].flatMap { $0.isEmpty ? nil : $0 }
        let config = RelayConfig(host: host, port: port, relaySecret: secret, agyPath: agy, dataRoot: dataRoot)
        let server = RelayServer(config: config)
        let bound = try await server.start()
        FileHandle.standardError.write(Data("kwwk-agy-relay \(RelayVersion.current) listening on \(host):\(bound)\n".utf8))
        if secret == nil {
            FileHandle.standardError.write(Data("warning: RELAY_SECRET is not set; the relay accepts any caller\n".utf8))
        }
        try await server.wait()
    }
}
