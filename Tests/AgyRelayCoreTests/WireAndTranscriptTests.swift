import Foundation
import Testing
@testable import AgyRelayCore

@Suite("Anthropic wire, transcript matching, credentials")
struct WireAndTranscriptTests {
    // MARK: - Request parsing

    @Test("parses system, string and block content, tools, images and tool results")
    func parseRequest() throws {
        let body = #"""
        {"model":"agy/claude-sonnet-5-5-high","stream":true,
         "system":[{"type":"text","text":"Be terse."}],
         "tools":[{"name":"read","description":"Read a file","input_schema":{"type":"object"}},
                  {"type":"web_search_20250305","name":"web_search"}],
         "messages":[
           {"role":"user","content":"hi"},
           {"role":"assistant","content":[{"type":"thinking","thinking":"hmm","signature":"x"},
                                          {"type":"tool_use","id":"t1","name":"read","input":{"path":"a"}}]},
           {"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"body"}]},
                                     {"type":"image","source":{"type":"base64","media_type":"image/png","data":"AAAA"}}]}
         ]}
        """#
        let request = try AnthropicWire.parseRequest(Data(body.utf8))
        #expect(request.slug == "claude-sonnet-5-5-high")
        #expect(request.stream)
        #expect(request.system == "Be terse.")
        #expect(request.tools.map(\.name) == ["read"])
        #expect(request.turns.count == 3)
        #expect(request.turns[0].blocks == [.text("hi")])
        #expect(request.turns[1].blocks == [.thinking("hmm"), .toolUse(id: "t1", name: "read", input: ["path": "a"])])
        #expect(request.turns[2].blocks == [
            .toolResult(toolUseId: "t1", content: [.text("body")], isError: false),
            .image(data: "AAAA", mimeType: "image/png"),
        ])
    }

    @Test("rejects malformed bodies with invalid_request_error")
    func parseErrors() {
        for body in ["[]", #"{"messages":[]}"#, #"{"model":"m"}"#, #"{"model":"m","messages":[{"role":"system","content":"x"}]}"#] {
            #expect(throws: WireError.self) { try AnthropicWire.parseRequest(Data(body.utf8)) }
        }
    }

    // MARK: - Responses

    @Test("SSE encoder emits the Anthropic event sequence")
    func sseEncoding() {
        var encoder = AnthropicSSEEncoder(messageId: "msg_1", model: "agy/x")
        var frames: [String] = []
        for event: RelayEvent in [
            .thinking("plan"), .text("Hel"), .text("lo"),
            .toolUse(id: "toolu_1", name: "read", input: ["path": "a"]),
            .finish(stopReason: "tool_use", usage: RelayUsage(input: 3, output: 2)),
        ] {
            frames += encoder.encode(event)
        }
        let names = frames.map { $0.split(separator: "\n").first.map(String.init) ?? "" }
        #expect(names == [
            "event: message_start",
            "event: content_block_start", "event: content_block_delta",   // thinking
            "event: content_block_stop",
            "event: content_block_start", "event: content_block_delta", "event: content_block_delta", // text
            "event: content_block_stop",
            "event: content_block_start", "event: content_block_delta", "event: content_block_stop", // tool_use
            "event: message_delta", "event: message_stop",
        ])
        #expect(frames.contains { $0.contains(#""partial_json":"{\"path\":\"a\"}""#) })
        #expect(frames.contains { $0.contains(#""stop_reason":"tool_use""#) })
    }

    @Test("aggregator builds a non-streaming message body")
    func aggregation() {
        var aggregate = AnthropicMessageAggregator(messageId: "msg_1", model: "agy/x")
        for event: RelayEvent in [.text("a"), .text("b"), .toolUse(id: "t", name: "n", input: [:]), .finish(stopReason: "tool_use", usage: RelayUsage())] {
            aggregate.add(event)
        }
        let content = aggregate.body["content"]?.arrayValue ?? []
        #expect(content.count == 2)
        #expect(content[0]["text"]?.stringValue == "ab")
        #expect(content[1]["id"]?.stringValue == "t")
        #expect(aggregate.body["stop_reason"]?.stringValue == "tool_use")
    }

    // MARK: - Transcript

    @Test("assistant fingerprints ignore thinking and how text is split")
    func fingerprints() {
        let emitted = Turn(role: .assistant, blocks: [.text("Hello world"), .toolUse(id: "t1", name: "", input: .null)])
        let replayed = Turn(role: .assistant, blocks: [
            .thinking("hidden"), .text("Hello "), .text("world"),
            .toolUse(id: "t1", name: "read", input: ["path": "a"]),
        ])
        #expect(Transcript.fingerprint(emitted) == Transcript.fingerprint(replayed))
        let other = Turn(role: .assistant, blocks: [.text("Hello world"), .toolUse(id: "t2", name: "", input: .null)])
        #expect(Transcript.fingerprint(emitted) != Transcript.fingerprint(other))
    }

    @Test("history replay and input blocks")
    func promptBuilding() throws {
        let turns = [
            Turn(role: .user, blocks: [.text("read a")]),
            Turn(role: .assistant, blocks: [.toolUse(id: "t1", name: "read", input: ["path": "a"])]),
            Turn(role: .user, blocks: [.toolResult(toolUseId: "t1", content: [.text("body")], isError: false)]),
            Turn(role: .assistant, blocks: [.text("it says body")]),
            Turn(role: .user, blocks: [.text("thanks"), .image(data: "AA", mimeType: "image/png")]),
        ]
        let split = Transcript.trailingInputStart(turns)
        #expect(split == 4)
        let replay = try #require(Transcript.historyReplay(Array(turns[..<split])))
        #expect(replay.contains("[assistant called tool read]\n{\"path\":\"a\"}"))
        #expect(replay.contains("[tool result]\nbody"))
        let input = Transcript.inputBlocks(Array(turns[split...]), imagesSupported: false)
        #expect(input.first?["text"]?.stringValue == "thanks")
        #expect(input.last?["text"]?.stringValue?.contains("image omitted") == true)
        #expect(Transcript.supportsImages(slug: "gemini-4-neon-high"))
        #expect(!Transcript.supportsImages(slug: "gpt-oss-120b-medium"))
    }

    // MARK: - Policy & credentials

    @Test("permission policy allows client MCP tools only")
    func permissions() {
        let options: JSONValue = [
            ["optionId": "allow", "kind": "allow_once"],
            ["optionId": "deny", "kind": "reject_once"],
        ]
        #expect(PermissionPolicy.outcome(["toolCall": ["name": "mcp_kwwk_read"], "options": options])
            == ["outcome": ["outcome": "selected", "optionId": "allow"]])
        #expect(PermissionPolicy.outcome(["toolCall": ["name": "read_file"], "options": options])
            == ["outcome": ["outcome": "selected", "optionId": "deny"]])
    }

    @Test("credential file matches agy's file store format")
    func credentialFile() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("relay-cred-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try CredentialFile.write(home: home, accessToken: "ya29.abc", email: "me@example.com", expiresIn: 3600)
        let dir = CredentialFile.directory(home: home)
        let token = try JSONValue.decode(Data(contentsOf: dir.appendingPathComponent("antigravity-oauth-token")))
        #expect(token["token"]?["access_token"]?.stringValue == "ya29.abc")
        #expect(token["token"]?["token_type"]?.stringValue == "Bearer")
        #expect(token["token"]?["refresh_token"] == nil)
        #expect(token["auth_method"]?.stringValue == "consumer")
        #expect(token["id_token_email"]?.stringValue == "me@example.com")
        let expiry = try #require(token["token"]?["expiry"]?.stringValue)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        #expect(try #require(formatter.date(from: expiry)) > Date())
        let state = try JSONValue.decode(Data(contentsOf: dir.appendingPathComponent("cache/acp-auth-state.json")))
        #expect(state["methodId"]?.stringValue == "oauth-personal")
        let attributes = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("antigravity-oauth-token").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("constant-time secret comparison")
    func secretCompare() {
        #expect(RelayService.constantTimeEqual("abc", "abc"))
        #expect(!RelayService.constantTimeEqual("abc", "abd"))
        #expect(!RelayService.constantTimeEqual("abc", "abcd"))
    }
}

@Suite("Access control")
struct AccessControlTests {
    @Test("the allowlist matches emails and domains, case-insensitively")
    func allowlist() {
        let open = RelayConfig()
        #expect(open.allows("anyone@example.com"))
        let config = RelayConfig(allowedUsers: ["Me@Example.com", "@team.dev"])
        #expect(config.allows("me@example.com"))
        #expect(config.allows("alice@team.dev"))
        #expect(!config.allows("eve@example.com"))
        #expect(!config.allows("bob@evilteam.dev"))
    }
}
