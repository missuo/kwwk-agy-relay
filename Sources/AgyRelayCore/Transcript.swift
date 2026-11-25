import Foundation
import Crypto

/// Pure helpers for matching Messages requests to ACP sessions and building
/// what agy is sent.
enum Transcript {
    // MARK: - Fingerprints

    /// A stable description of a turn for matching. Assistant turns reduce to
    /// their text and tool-use ids — exactly what the relay emitted and what a
    /// client replays — so dropped or rewritten thinking blocks, or text split
    /// differently into blocks, do not break the match.
    static func fingerprint(_ turn: Turn) -> String {
        switch turn.role {
        case .assistant:
            var text = ""
            var tools: [String] = []
            for block in turn.blocks {
                switch block {
                case .text(let t): text += t
                case .toolUse(let id, _, _): tools.append(id)
                default: continue
                }
            }
            return "A|\(text.trimmingCharacters(in: .whitespacesAndNewlines))|\(tools.joined(separator: ","))"
        case .user:
            let parts = turn.blocks.map { block -> String in
                switch block {
                case .text(let t): return "t:\(t)"
                case .image(let data, let mime): return "i:\(mime):\(sha256(data))"
                case .toolResult(let id, let content, let isError):
                    return "r:\(id):\(isError):\(content.map { fingerprint(Turn(role: .user, blocks: [$0])) }.joined(separator: ";"))"
                case .toolUse(let id, _, _): return "u:\(id)"
                case .thinking: return ""
                }
            }
            return "U|" + parts.joined(separator: "\u{1}")
        }
    }

    static func digest<S: Sequence>(_ turns: S) -> String where S.Element == Turn {
        var hasher = SHA256()
        for turn in turns {
            hasher.update(data: Data(fingerprint(turn).utf8))
            hasher.update(data: Data([0]))
        }
        return hex(hasher.finalize())
    }

    /// System prompt plus tool list: ACP fixes both when a session opens.
    static func setupDigest(system: String?, tools: [ToolSpec]) -> String {
        var hasher = SHA256()
        hasher.update(data: Data((system ?? "").utf8))
        hasher.update(data: Data([0]))
        for tool in tools {
            hasher.update(data: Data("\(tool.name)\u{1}\(tool.description)\u{1}\(tool.inputSchema.compactString)".utf8))
            hasher.update(data: Data([0]))
        }
        return hex(hasher.finalize())
    }

    static func sha256(_ s: String) -> String {
        hex(SHA256.hash(data: Data(s.utf8)))
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Prompt building

    /// Appended to agy's own system prompt (`_meta.antigravity.systemPrompt.append`).
    static func systemAppendix(system: String?, hasTools: Bool) -> String {
        var parts: [String] = []
        if let system = system?.trimmingCharacters(in: .whitespacesAndNewlines), !system.isEmpty {
            parts.append(system)
        }
        if hasTools {
            parts.append("""
            # Tool environment
            Your tools are provided by the client through the MCP server `\(MCPBridgeServer.serverName)` \
            (tool names start with `\(MCPBridgeServer.toolPrefix)`). Use only those tools. Your built-in tools \
            (run_command, read_file, write_file, list_dir, search_web, the browser and similar) are disabled in \
            this environment and every call to them is refused; use the `\(MCPBridgeServer.toolPrefix)` \
            equivalent instead. The workspace path your environment reports is an empty placeholder, not the \
            user's project.
            """)
        } else {
            parts.append("""
            # Tool environment
            You have no tools for this turn. Your built-in tools are disabled and every call to them is refused; \
            answer from the conversation alone.
            """)
        }
        return parts.joined(separator: "\n\n")
    }

    /// Index where the trailing input starts: after the last assistant turn.
    static func trailingInputStart(_ turns: [Turn]) -> Int {
        guard let last = turns.lastIndex(where: { $0.role == .assistant }) else { return 0 }
        return last + 1
    }

    /// The transcript before the current input as one text block, or nil.
    static func historyReplay(_ turns: [Turn]) -> String? {
        var lines: [String] = []
        for turn in turns {
            for block in turn.blocks {
                switch (turn.role, block) {
                case (.user, .text(let t)):
                    lines.append("[user]\n\(t)")
                case (.user, .image(_, let mime)):
                    lines.append("[user]\n[\(mime) image omitted]")
                case (_, .toolResult(_, let content, let isError)):
                    lines.append("[tool result\(isError ? ", error" : "")]\n\(text(of: content))")
                case (.assistant, .text(let t)) where !t.isEmpty:
                    lines.append("[assistant]\n\(t)")
                case (.assistant, .toolUse(_, let name, let input)):
                    lines.append("[assistant called tool \(name)]\n\(input.compactString)")
                default:
                    continue
                }
            }
        }
        guard !lines.isEmpty else { return nil }
        return """
        <conversation_history>
        The conversation so far, replayed because this session started fresh. Tool calls listed here already \
        ran; do not repeat them unless asked. Continue from the latest input below.

        \(lines.joined(separator: "\n\n"))
        </conversation_history>
        """
    }

    /// ACP prompt blocks for input turns. Tool results (calls this session
    /// never made) are rendered as text.
    static func inputBlocks(_ turns: [Turn], imagesSupported: Bool) -> [JSONValue] {
        var out: [JSONValue] = []
        for turn in turns where turn.role == .user {
            for block in turn.blocks {
                switch block {
                case .text(let t) where !t.isEmpty:
                    out.append(textBlock(t))
                case .image(let data, let mime):
                    out.append(imagesSupported
                        ? ["type": "image", "data": .string(data), "mimeType": .string(mime)]
                        : textBlock("[\(mime) image omitted: this model does not accept images]"))
                case .toolResult(_, let content, let isError):
                    out.append(textBlock("[tool result\(isError ? ", error" : "")]\n\(text(of: content))"))
                default:
                    continue
                }
            }
        }
        return out.isEmpty ? [textBlock("Continue.")] : out
    }

    /// A client tool result as MCP `tools/call` content.
    static func mcpContent(_ content: [Block], imagesSupported: Bool) -> [JSONValue] {
        let out: [JSONValue] = content.compactMap { block in
            switch block {
            case .text(let t):
                return ["type": "text", "text": .string(t)]
            case .image(let data, let mime):
                return imagesSupported
                    ? ["type": "image", "data": .string(data), "mimeType": .string(mime)]
                    : ["type": "text", "text": .string("[\(mime) image omitted]")]
            default:
                return nil
            }
        }
        return out.isEmpty ? [["type": "text", "text": ""]] : out
    }

    static func text(of content: [Block]) -> String {
        content.compactMap { block -> String? in
            switch block {
            case .text(let t): return t
            case .image(_, let mime): return "[\(mime) image]"
            default: return nil
            }
        }.joined(separator: "\n")
    }

    static func textBlock(_ s: String) -> JSONValue {
        ["type": "text", "text": .string(s)]
    }

    /// Whether an agy model slug accepts images (Gemini and Claude do;
    /// gpt-oss does not).
    static func supportsImages(slug: String) -> Bool {
        let lower = slug.lowercased()
        return !lower.hasPrefix("gpt-oss") && (lower.hasPrefix("gemini-") || lower.hasPrefix("claude-"))
    }
}
