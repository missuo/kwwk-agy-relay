import Foundation
import Testing
@testable import AgyRelayCore

@Suite("Relay HTTP server")
struct RelayServerTests {
    @Test("serves /healthz and reports the messages route as not implemented yet")
    func healthAndStub() async throws {
        let server = RelayServer(config: RelayConfig(port: 0))
        let port = try await server.start()
        defer { Task { await server.stop() } }

        let health = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/healthz")!)
        #expect((health.1 as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: health.0, as: UTF8.self).contains(#""ok":true"#))

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/messages")!)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        let messages = try await URLSession.shared.data(for: request)
        #expect((messages.1 as? HTTPURLResponse)?.statusCode == 501)
    }
}
