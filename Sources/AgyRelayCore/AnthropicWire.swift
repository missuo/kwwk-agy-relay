import Foundation

// MARK: - Request model

public enum Role: String, Sendable, Hashable {
    case user
    case assistant
}

/// One content block of an Anthropic message, reduced to what the relay
/// forwards to agy.
public enum Block: Sendable, Hashable {
    case text(String)
    case image(data: String, mimeType: String)
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(toolUseId: String, content: [Block], isError: Bool)
    /// Reasoning the client replays; never sent back to agy.
    case thinking(String)
}

public struct Turn: Sendable, Hashable {
    public var role: Role
    public var blocks: [Block]
    public init(role: Role, blocks: [Block]) {
        self.role = role
        self.blocks = blocks
    }
}

public struct ToolSpec: Sendable, Hashable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue
}

/// A decoded `POST /v1/messages` body.
public struct MessagesRequest: Sendable {
    /// The model id as sent (`agy/<slug>` or a bare slug).
    public var model: String
    public var system: String?
    public var turns: [Turn]
    public var tools: [ToolSpec]
    public var stream: Bool

    /// The `agy` model slug.
    public var slug: String {
        model.hasPrefix("agy/") ? String(model.dropFirst(4)) : model
    }
}

public struct WireError: Error, Sendable {
    public var status: Int
    public var type: String
    public var message: String

    public static func invalid(_ message: String) -> WireError {
        WireError(status: 400, type: "invalid_request_error", message: message)
    }

    /// The Anthropic error body.
    public var body: JSONValue {
        ["type": "error", "error": ["type": .string(type), "message": .string(message)]]
    }
}

public enum AnthropicWire {
    /// Parse a Messages request body.
    public static func parseRequest(_ body: Data) throws -> MessagesRequest {
        guard let json = try? JSONValue.decode(body), case .object(let root) = json else {
            throw WireError.invalid("request body must be a JSON object")
        }
        guard let model = root["model"]?.stringValue, !model.isEmpty else {
            throw WireError.invalid("model: field required")
        }
        guard let messages = root["messages"]?.arrayValue else {
            throw WireError.invalid("messages: field required")
        }
        let turns = try messages.enumerated().map { index, message -> Turn in
            guard let roleName = message["role"]?.stringValue, let role = Role(rawValue: roleName) else {
                throw WireError.invalid("messages.\(index).role: must be user or assistant")
            }
            return Turn(role: role, blocks: try blocks(message["content"], path: "messages.\(index).content"))
        }
        let tools = (root["tools"]?.arrayValue ?? []).compactMap { tool -> ToolSpec? in
            // Server tools (web_search_…) carry a `type`; only client tools are forwarded.
            guard let name = tool["name"]?.stringValue, tool["input_schema"] != nil || tool["type"] == nil else {
                return nil
            }
            return ToolSpec(
                name: name,
                description: tool["description"]?.stringValue ?? "",
                inputSchema: tool["input_schema"] ?? ["type": "object", "properties": [:]]
            )
        }
        return MessagesRequest(
            model: model,
            system: systemText(root["system"]),
            turns: turns,
            tools: tools,
            stream: root["stream"]?.boolValue ?? false
        )
    }

    static func systemText(_ value: JSONValue?) -> String? {
        switch value {
        case .string(let s)?:
            return s.isEmpty ? nil : s
        case .array(let parts)?:
            let text = parts.compactMap { $0["text"]?.stringValue }.joined(separator: "\n\n")
            return text.isEmpty ? nil : text
        default:
            return nil
        }
    }

    static func blocks(_ content: JSONValue?, path: String) throws -> [Block] {
        switch content {
        case .string(let s)?:
            return [.text(s)]
        case .array(let items)?:
            return try items.enumerated().compactMap { index, item in try block(item, path: "\(path).\(index)") }
        default:
            throw WireError.invalid("\(path): must be a string or an array of content blocks")
        }
    }

    static func block(_ item: JSONValue, path: String) throws -> Block? {
        switch item["type"]?.stringValue {
        case "text":
            return .text(item["text"]?.stringValue ?? "")
        case "image":
            let source = item["source"]
            if source?["type"]?.stringValue == "base64",
               let data = source?["data"]?.stringValue,
               let mime = source?["media_type"]?.stringValue {
                return .image(data: data, mimeType: mime)
            }
            let url = source?["url"]?.stringValue ?? "?"
            return .text("[image: \(url)]")
        case "tool_use":
            guard let id = item["id"]?.stringValue, let name = item["name"]?.stringValue else {
                throw WireError.invalid("\(path): tool_use needs id and name")
            }
            return .toolUse(id: id, name: name, input: item["input"] ?? .object([:]))
        case "tool_result":
            guard let id = item["tool_use_id"]?.stringValue else {
                throw WireError.invalid("\(path): tool_result needs tool_use_id")
            }
            let content: [Block]
            switch item["content"] {
            case nil, .null?: content = []
            default: content = try blocks(item["content"], path: "\(path).content")
            }
            return .toolResult(toolUseId: id, content: content, isError: item["is_error"]?.boolValue ?? false)
        case "thinking":
            return .thinking(item["thinking"]?.stringValue ?? "")
        case "redacted_thinking":
            return nil
        case "document":
            let title = item["title"]?.stringValue ?? item["source"]?["type"]?.stringValue ?? "document"
            if let text = item["source"]?["data"]?.stringValue, item["source"]?["type"]?.stringValue == "text" {
                return .text("[document: \(title)]\n\(text)")
            }
            return .text("[document omitted: \(title)]")
        default:
            // Unknown block types (server tool results, citations…) carry
            // nothing agy can use.
            return nil
        }
    }
}

// MARK: - Response events

public struct RelayUsage: Sendable, Hashable {
    public var input = 0
    public var output = 0
    public var cacheRead = 0
    public var cacheWrite = 0
    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }
}

/// What the relay produces for one HTTP response, in order.
public enum RelayEvent: Sendable, Hashable {
    case text(String)
    case thinking(String)
    case toolUse(id: String, name: String, input: JSONValue)
    /// The response ends (`end_turn`, `tool_use`, `max_tokens`, …).
    case finish(stopReason: String, usage: RelayUsage)
    case failure(WireErrorEvent)
}

public struct WireErrorEvent: Sendable, Hashable {
    public var status: Int
    public var type: String
    public var message: String
    public init(status: Int, type: String, message: String) {
        self.status = status
        self.type = type
        self.message = message
    }

    public init(_ error: WireError) {
        self.init(status: error.status, type: error.type, message: error.message)
    }

    public var body: JSONValue {
        ["type": "error", "error": ["type": .string(type), "message": .string(message)]]
    }
}

/// Turns `RelayEvent`s into Anthropic SSE frames.
public struct AnthropicSSEEncoder {
    private enum Open { case text, thinking }
    private let messageId: String
    private let model: String
    private var started = false
    private var index = -1
    private var open: Open?

    public init(messageId: String, model: String) {
        self.messageId = messageId
        self.model = model
    }

    /// SSE frames for `event` (each a complete `event:`/`data:` record).
    public mutating func encode(_ event: RelayEvent) -> [String] {
        var out: [String] = []
        var isFailure = false
        if case .failure = event { isFailure = true }
        // An error before any output stands alone, without a message_start.
        if !started && !isFailure {
            started = true
            out.append(frame("message_start", [
                "type": "message_start",
                "message": [
                    "id": .string(messageId),
                    "type": "message",
                    "role": "assistant",
                    "model": .string(model),
                    "content": [],
                    "stop_reason": nil,
                    "stop_sequence": nil,
                    "usage": ["input_tokens": 0, "output_tokens": 0],
                ],
            ]))
        }
        switch event {
        case .text(let text):
            if open != .text { out += closeBlock(); out += openBlock(.text, ["type": "text", "text": ""]) }
            out.append(delta(["type": "text_delta", "text": .string(text)]))
        case .thinking(let text):
            if open != .thinking { out += closeBlock(); out += openBlock(.thinking, ["type": "thinking", "thinking": ""]) }
            out.append(delta(["type": "thinking_delta", "thinking": .string(text)]))
        case .toolUse(let id, let name, let input):
            out += closeBlock()
            index += 1
            out.append(frame("content_block_start", [
                "type": "content_block_start",
                "index": .int(index),
                "content_block": ["type": "tool_use", "id": .string(id), "name": .string(name), "input": [:]],
            ]))
            out.append(delta(["type": "input_json_delta", "partial_json": .string(input.compactString)]))
            out.append(frame("content_block_stop", ["type": "content_block_stop", "index": .int(index)]))
        case .finish(let stopReason, let usage):
            out += closeBlock()
            out.append(frame("message_delta", [
                "type": "message_delta",
                "delta": ["stop_reason": .string(stopReason), "stop_sequence": nil],
                "usage": [
                    "input_tokens": .int(usage.input),
                    "output_tokens": .int(usage.output),
                    "cache_read_input_tokens": .int(usage.cacheRead),
                    "cache_creation_input_tokens": .int(usage.cacheWrite),
                ],
            ]))
            out.append(frame("message_stop", ["type": "message_stop"]))
        case .failure(let error):
            out.append(frame("error", error.body))
        }
        return out
    }

    public static let ping = "event: ping\ndata: {\"type\":\"ping\"}\n\n"

    private mutating func openBlock(_ kind: Open, _ block: JSONValue) -> [String] {
        index += 1
        open = kind
        return [frame("content_block_start", ["type": "content_block_start", "index": .int(index), "content_block": block])]
    }

    private mutating func closeBlock() -> [String] {
        guard open != nil else { return [] }
        open = nil
        return [frame("content_block_stop", ["type": "content_block_stop", "index": .int(index)])]
    }

    private func delta(_ delta: JSONValue) -> String {
        frame("content_block_delta", ["type": "content_block_delta", "index": .int(index), "delta": delta])
    }

    private func frame(_ name: String, _ data: JSONValue) -> String {
        "event: \(name)\ndata: \(data.compactString)\n\n"
    }
}

/// Collects `RelayEvent`s into a non-streaming Messages response body.
public struct AnthropicMessageAggregator {
    private let messageId: String
    private let model: String
    private var content: [JSONValue] = []
    private var stopReason: String?
    private var usage = RelayUsage()
    public private(set) var failure: WireErrorEvent?

    public init(messageId: String, model: String) {
        self.messageId = messageId
        self.model = model
    }

    public mutating func add(_ event: RelayEvent) {
        switch event {
        case .text(let text):
            if case .object(var last)? = content.last, last["type"] == "text" {
                last["text"] = .string((last["text"]?.stringValue ?? "") + text)
                content[content.count - 1] = .object(last)
            } else {
                content.append(["type": "text", "text": .string(text)])
            }
        case .thinking(let text):
            if case .object(var last)? = content.last, last["type"] == "thinking" {
                last["thinking"] = .string((last["thinking"]?.stringValue ?? "") + text)
                content[content.count - 1] = .object(last)
            } else {
                content.append(["type": "thinking", "thinking": .string(text)])
            }
        case .toolUse(let id, let name, let input):
            content.append(["type": "tool_use", "id": .string(id), "name": .string(name), "input": input])
        case .finish(let reason, let usage):
            stopReason = reason
            self.usage = usage
        case .failure(let error):
            failure = error
        }
    }

    public var body: JSONValue {
        [
            "id": .string(messageId),
            "type": "message",
            "role": "assistant",
            "model": .string(model),
            "content": .array(content),
            "stop_reason": stopReason.map { .string($0) } ?? .null,
            "stop_sequence": nil,
            "usage": [
                "input_tokens": .int(usage.input),
                "output_tokens": .int(usage.output),
                "cache_read_input_tokens": .int(usage.cacheRead),
                "cache_creation_input_tokens": .int(usage.cacheWrite),
            ],
        ]
    }
}
