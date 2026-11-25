import Foundation
import Testing
@testable import AgyRelayCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// End-to-end against a real signed-in `agy`, the way kwwk drives the relay:
/// a tool call ends the first response, the tool result resumes the same ACP
/// turn in the second, and a follow-up continues the session.
///
/// Gated behind `RELAY_LIVE=1`. On a Mac it uses the machine's own `agy`
/// login (`--system-login`); set `RELAY_LIVE_TOKEN` to a Google access token
/// for the Antigravity client to exercise token files instead (Linux).
@Suite("Live relay against agy")
struct LiveRelayTests {
    struct Fixed: IdentityResolver {
        func identify(token: String) async throws -> Identity { Identity(user: "live", expiresIn: 3000) }
    }

    struct Frame { var event: String; var data: JSONValue }

    static func post(_ url: URL, _ body: JSONValue, token: String) async throws -> (Int, [Frame]) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try body.encoded()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        request.timeoutInterval = 240
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(decoding: data, as: UTF8.self)
        let frames = text.components(separatedBy: "\n\n").compactMap { record -> Frame? in
            var event = "", payload = ""
            for line in record.split(separator: "\n") {
                if line.hasPrefix("event: ") { event = String(line.dropFirst(7)) }
                if line.hasPrefix("data: ") { payload = String(line.dropFirst(6)) }
            }
            guard !event.isEmpty, let json = try? JSONValue.decode(Data(payload.utf8)) else { return nil }
            return Frame(event: event, data: json)
        }
        if frames.isEmpty, let json = try? JSONValue.decode(data) { return (status, [Frame(event: "json", data: json)]) }
        return (status, frames)
    }

    /// The assistant turn a client would store from these frames.
    static func assistantTurn(_ frames: [Frame]) -> (content: [JSONValue], text: String, toolUses: [(id: String, name: String)], stop: String?) {
        var content: [JSONValue] = []
        var text = ""
        var tools: [(String, String)] = []
        var current: [String: JSONValue] = [:]
        var stop: String?
        for frame in frames {
            switch frame.event {
            case "content_block_start":
                current = frame.data["content_block"]?.objectValue ?? [:]
                if current["type"] == "tool_use" { current["input"] = .string("") }
            case "content_block_delta":
                let delta = frame.data["delta"]
                if let t = delta?["text"]?.stringValue { current["text"] = .string((current["text"]?.stringValue ?? "") + t); text += t }
                if let j = delta?["partial_json"]?.stringValue { current["input"] = .string((current["input"]?.stringValue ?? "") + j) }
            case "content_block_stop":
                if current["type"] == "tool_use" {
                    let raw = current["input"]?.stringValue ?? "{}"
                    current["input"] = (try? JSONValue.decode(Data(raw.utf8))) ?? [:]
                    tools.append((current["id"]?.stringValue ?? "", current["name"]?.stringValue ?? ""))
                }
                if current["type"] != "thinking" { content.append(.object(current)) }
            case "message_delta":
                stop = frame.data["delta"]?["stop_reason"]?.stringValue
            default:
                break
            }
        }
        return (content, text, tools, stop)
    }

    @Test("tool round trip and follow-up over one ACP session")
    func toolRoundTrip() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["RELAY_LIVE"] == "1" else {
            print("[skipped] set RELAY_LIVE=1 to run")
            return
        }
        let token = env["RELAY_LIVE_TOKEN"] ?? "local"
        let systemLogin = env["RELAY_LIVE_TOKEN"] == nil
        let agy = env["AGY_PATH"] ?? (NSHomeDirectory() + "/.local/bin/agy")
        let dataRoot = FileManager.default.temporaryDirectory.appendingPathComponent("relay-live-\(UUID().uuidString)").path
        let server = RelayServer(
            config: RelayConfig(port: 0, agyPath: agy, dataRoot: dataRoot, systemLogin: systemLogin),
            identity: systemLogin ? nil : Fixed()
        )
        let port = try await server.start()
        defer { Task { await server.stop(); try? FileManager.default.removeItem(atPath: dataRoot) } }
        let url = URL(string: "http://127.0.0.1:\(port)/v1/messages")!

        let tools: JSONValue = [[
            "name": "get_secret",
            "description": "Returns the secret number for a key.",
            "input_schema": ["type": "object", "properties": ["key": ["type": "string"]], "required": ["key"]],
        ]]
        var messages: [JSONValue] = [["role": "user", "content": "Call get_secret with key alpha, then tell me the number."]]
        func body() -> JSONValue {
            ["model": "agy/gemini-3.8-flash-low", "max_tokens": 1024, "stream": true,
             "system": "You are terse.", "tools": tools, "messages": .array(messages)]
        }

        // Round 1: ends on the tool call.
        let (status1, frames1) = try await Self.post(url, body(), token: token)
        #expect(status1 == 200, "\(frames1.first?.data.compactString ?? "")")
        let turn1 = Self.assistantTurn(frames1)
        #expect(turn1.stop == "tool_use")
        let call = try #require(turn1.toolUses.first)
        #expect(call.name == "get_secret")

        // Round 2: the tool result resumes the same agy turn.
        messages.append(["role": "assistant", "content": .array(turn1.content)])
        messages.append(["role": "user", "content": [[
            "type": "tool_result", "tool_use_id": .string(call.id),
            "content": [["type": "text", "text": "the secret is 4217"]],
        ]]])
        let (status2, frames2) = try await Self.post(url, body(), token: token)
        #expect(status2 == 200)
        let turn2 = Self.assistantTurn(frames2)
        #expect(turn2.stop == "end_turn")
        #expect(turn2.text.contains("4217"))

        // Round 3: a follow-up continues the same session.
        messages.append(["role": "assistant", "content": .array(turn2.content)])
        messages.append(["role": "user", "content": "Without tools: repeat the number."])
        let (status3, frames3) = try await Self.post(url, body(), token: token)
        #expect(status3 == 200)
        let turn3 = Self.assistantTurn(frames3)
        #expect(turn3.text.contains("4217"))
        let user = systemLogin ? "local" : "live"
        #expect(await server.service.sessionsOpened(user: user) == 1)
    }
}
