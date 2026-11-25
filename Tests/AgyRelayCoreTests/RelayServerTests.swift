import Foundation
import Testing
@testable import AgyRelayCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite("Relay HTTP server")
struct RelayServerTests {
    struct RejectAll: IdentityResolver {
        func identify(token: String) async throws -> Identity {
            throw WireError(status: 401, type: "authentication_error", message: "nope")
        }
    }

    @Test("serves /healthz, enforces the relay secret, and validates bodies")
    func healthAuthAndValidation() async throws {
        let server = RelayServer(config: RelayConfig(port: 0, relaySecret: "s3cret"), identity: RejectAll())
        let port = try await server.start()
        defer { Task { await server.stop() } }
        let base = "http://127.0.0.1:\(port)"

        let health = try await URLSession.shared.data(from: URL(string: "\(base)/healthz")!)
        #expect((health.1 as? HTTPURLResponse)?.statusCode == 200)

        func post(_ body: String, secret: String?) async throws -> (Int, JSONValue?) {
            var request = URLRequest(url: URL(string: "\(base)/v1/messages")!)
            request.httpMethod = "POST"
            request.httpBody = Data(body.utf8)
            request.setValue("Bearer ya29.test", forHTTPHeaderField: "authorization")
            if let secret { request.setValue(secret, forHTTPHeaderField: "x-relay-secret") }
            let (data, response) = try await URLSession.shared.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, try? JSONValue.decode(data))
        }
        let valid = #"{"model":"agy/gemini-3.8-flash-low","max_tokens":10,"messages":[{"role":"user","content":"hi"}]}"#

        let (badJSON, badBody) = try await post("{}", secret: "s3cret")
        #expect(badJSON == 400)
        #expect(badBody?["error"]?["type"]?.stringValue == "invalid_request_error")

        let (noSecret, _) = try await post(valid, secret: nil)
        #expect(noSecret == 401)
        let (wrongSecret, wrongBody) = try await post(valid, secret: "nope")
        #expect(wrongSecret == 401)
        #expect(wrongBody?["error"]?["message"]?.stringValue?.contains("x-relay-secret") == true)

        // Secret ok, token rejected by the identity resolver.
        let (badToken, tokenBody) = try await post(valid, secret: "s3cret")
        #expect(badToken == 401)
        #expect(tokenBody?["error"]?["message"]?.stringValue == "nope")
    }
}
