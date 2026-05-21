import Foundation

/// Reads sessions out of `~/.claude/projects/<encoded-cwd>/<uuid>.jsonl`.
/// Path encoding: every `/` in the absolute path becomes `-`. Each session
/// file is a JSONL of Claude's internal session log (NOT stream-json output);
/// the schema overlaps but adds attachment / permission-mode / ai-title etc.
final class ClaudeSessionStore: AgentSessionStore {
    let supportsExplicitSessionId = true

    private let projectsRoot: URL

    init(claudeHome: URL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude", isDirectory: true)) {
        self.projectsRoot = claudeHome.appendingPathComponent("projects",
                                                              isDirectory: true)
    }

    /// `/Users/x/y` → `-Users-x-y`. Tilde is expanded first.
    static func bucketName(for path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return expanded.replacingOccurrences(of: "/", with: "-")
    }

    func bucketURL(for project: Project) -> URL {
        projectsRoot.appendingPathComponent(
            Self.bucketName(for: project.location.pathString),
            isDirectory: true)
    }

    // MARK: - AgentSessionStore

    func sessions(for project: Project) async throws -> [VendorSessionRef] {
        let bucket = bucketURL(for: project)
        guard FileManager.default.fileExists(atPath: bucket.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(
            at: bucket,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])
        var refs: [VendorSessionRef] = []
        for url in urls where url.pathExtension == "jsonl" {
            let id = url.deletingPathExtension().lastPathComponent
            let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            let mtime = attrs?.contentModificationDate ?? Date.distantPast
            let scan = quickScan(at: url)
            refs.append(VendorSessionRef(
                id: id,
                lastUpdate: mtime,
                messageCount: scan.count,
                preview: scan.preview))
        }
        return refs.sorted { $0.lastUpdate > $1.lastUpdate }
    }

    func history(sessionId: String, project: Project) async throws -> [Message] {
        let url = bucketURL(for: project)
            .appendingPathComponent("\(sessionId).jsonl", isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return ClaudeSessionLogParser().parse(data)
    }

    // MARK: -

    private struct ScanResult { var count: Int; var preview: String }

    /// Single-pass over the file: count user/assistant lines, capture first
    /// user-text content for preview.
    private func quickScan(at url: URL) -> ScanResult {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return ScanResult(count: 0, preview: "")
        }
        var count = 0
        var preview = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
            let type = obj["type"] as? String ?? ""
            if type == "user" || type == "assistant" { count += 1 }
            if preview.isEmpty, type == "user",
               let msg = obj["message"] as? [String: Any],
               (msg["role"] as? String) == "user",
               let extracted = ClaudeSessionLogParser.extractFirstText(msg["content"]) {
                preview = String(extracted.prefix(160))
            }
        }
        return ScanResult(count: count, preview: preview)
    }
}

/// Parses Claude's session log jsonl into our Message model. Only `user` and
/// `assistant` entries become messages; `tool_result` blocks (which arrive
/// inside `user` entries echoed by the runtime) are stitched onto the
/// originating assistant ToolCall part.
struct ClaudeSessionLogParser {

    func parse(_ data: Data) -> [Message] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        var messages: [Message] = []
        // tool_use_id (from vendor) → (index of owning assistant Message,
        // ToolCall.id we generated). Lets us mutate the ToolCall part when a
        // matching tool_result comes in later.
        var toolIndex: [String: (msgIdx: Int, callId: UUID)] = [:]

        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
            let type = obj["type"] as? String ?? ""
            if obj["isSidechain"] as? Bool == true { continue }

            switch type {
            case "user":
                guard let msg = obj["message"] as? [String: Any],
                      (msg["role"] as? String) == "user" else { continue }
                let content = msg["content"]
                if let s = content as? String, !s.isEmpty {
                    messages.append(Message(
                        id: UUID(), role: .user, who: "you", meta: nil,
                        parts: [.text(s)]))
                } else if let blocks = content as? [[String: Any]] {
                    var textParts: [String] = []
                    for block in blocks {
                        let btype = block["type"] as? String
                        switch btype {
                        case "text":
                            if let t = block["text"] as? String, !t.isEmpty {
                                textParts.append(t)
                            }
                        case "tool_result":
                            applyToolResult(block, into: &messages, toolIndex: toolIndex)
                        default: break
                        }
                    }
                    if !textParts.isEmpty {
                        messages.append(Message(
                            id: UUID(), role: .user, who: "you", meta: nil,
                            parts: [.text(textParts.joined())]))
                    }
                }

            case "assistant":
                guard let msg = obj["message"] as? [String: Any],
                      let blocks = msg["content"] as? [[String: Any]] else { continue }
                var parts: [Part] = []
                let willBeIndex = messages.count
                var pendingToolMappings: [(useId: String, callId: UUID)] = []
                for block in blocks {
                    let btype = block["type"] as? String
                    switch btype {
                    case "text":
                        if let t = block["text"] as? String, !t.isEmpty {
                            parts.append(.text(t))
                        }
                    case "tool_use":
                        let useId = block["id"] as? String ?? ""
                        let name = block["name"] as? String ?? ""
                        let input = (block["input"] as? [String: Any])
                            .flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                        let callId = UUID()
                        parts.append(.toolCall(ToolCall(
                            id: callId, name: name, arg: input,
                            status: .running, meta: nil, body: nil)))
                        pendingToolMappings.append((useId, callId))
                    default: break
                    }
                }
                guard !parts.isEmpty else { continue }
                messages.append(Message(
                    id: UUID(), role: .assistant(meta: "done"),
                    who: "claude", meta: nil, parts: parts))
                for m in pendingToolMappings {
                    toolIndex[m.useId] = (willBeIndex, m.callId)
                }

            default:
                continue
            }
        }
        return messages
    }

    private func applyToolResult(_ block: [String: Any],
                                 into messages: inout [Message],
                                 toolIndex: [String: (msgIdx: Int, callId: UUID)]) {
        let useId = block["tool_use_id"] as? String ?? ""
        guard let mapping = toolIndex[useId],
              mapping.msgIdx < messages.count else { return }
        let isError = block["is_error"] as? Bool ?? false
        let output = Self.extractFirstText(block["content"]) ?? ""
        var msg = messages[mapping.msgIdx]
        guard let pIdx = msg.parts.firstIndex(where: {
            if case .toolCall(let t) = $0 { return t.id == mapping.callId } else { return false }
        }), case .toolCall(var call) = msg.parts[pIdx] else { return }
        call.body = output
        call.status = isError ? .error(exit: 1) : .ok(exit: 0)
        msg.parts[pIdx] = .toolCall(call)
        messages[mapping.msgIdx] = msg
    }

    /// Extracts text out of either a bare string or an array of `{type, text}`
    /// blocks. Used both for previews and for tool_result bodies.
    static func extractFirstText(_ raw: Any?) -> String? {
        if let s = raw as? String { return s.isEmpty ? nil : s }
        if let arr = raw as? [[String: Any]] {
            var out = ""
            for item in arr {
                if let t = item["text"] as? String { out += t }
            }
            return out.isEmpty ? nil : out
        }
        return nil
    }
}
