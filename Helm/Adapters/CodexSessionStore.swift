import Foundation

/// Reads Codex's session store at `~/.codex/sessions/<yyyy>/<mm>/<dd>/`.
/// Codex buckets logs by date rather than by cwd, so we scan session metadata
/// and match the recorded `cwd` back to Helm's project.
final class CodexSessionStore: AgentSessionStore {
    let supportsExplicitSessionId = false

    private let sessionsRoot: URL

    init(codexHome: URL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex", isDirectory: true)) {
        self.sessionsRoot = codexHome.appendingPathComponent("sessions",
                                                             isDirectory: true)
    }

    func sessions(for project: Project) async throws -> [VendorSessionRef] {
        guard !project.location.isSSH else { return [] }
        let projectPath = normalizedPath(project.location.pathString)
        var refs: [VendorSessionRef] = []

        for url in try sessionFiles() {
            guard let meta = quickMeta(at: url),
                  normalizedPath(meta.cwd) == projectPath else { continue }
            let scan = quickScan(at: url)
            let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            refs.append(VendorSessionRef(
                id: meta.id,
                lastUpdate: attrs?.contentModificationDate ?? meta.timestamp ?? .distantPast,
                messageCount: scan.count,
                preview: scan.preview))
        }

        return refs.sorted { $0.lastUpdate > $1.lastUpdate }
    }

    func history(sessionId: String, project: Project) async throws -> [TranscriptItem] {
        guard let url = try sessionURL(for: sessionId) else { return [] }
        let data = try Data(contentsOf: url)
        return CodexSessionLogParser().parse(data)
    }

    // MARK: - File lookup

    private func sessionURL(for sessionId: String) throws -> URL? {
        try sessionFiles().first {
            $0.deletingPathExtension().lastPathComponent.contains(sessionId)
        }
    }

    private func sessionFiles() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: sessionsRoot.path) else {
            return []
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var urls: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile ?? true {
                urls.append(url)
            }
        }
        return urls
    }

    private func normalizedPath(_ path: String) -> String {
        ((path as NSString).expandingTildeInPath as NSString).standardizingPath
    }

    // MARK: - Lightweight scans

    private struct Meta {
        var id: String
        var cwd: String
        var timestamp: Date?
    }

    private struct ScanResult {
        var count: Int
        var preview: String
    }

    private func quickMeta(at url: URL) -> Meta? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let obj = jsonObject(String(line)),
                  obj["type"] as? String == "session_meta",
                  let payload = obj["payload"] as? [String: Any],
                  let id = payload["id"] as? String,
                  let cwd = payload["cwd"] as? String
            else { continue }
            return Meta(
                id: id,
                cwd: cwd,
                timestamp: (payload["timestamp"] as? String).flatMap(Self.parseDate))
        }
        return nil
    }

    private func quickScan(at url: URL) -> ScanResult {
        guard let data = try? Data(contentsOf: url) else {
            return ScanResult(count: 0, preview: "")
        }
        let items = CodexSessionLogParser().parse(data)
        var count = 0
        var preview = ""
        for item in items {
            guard case .message(let msg) = item else { continue }
            switch msg.role {
            case .user:
                count += 1
                if preview.isEmpty,
                   let text = msg.parts.compactMap({ part -> String? in
                       if case .text(let s) = part { return s }
                       return nil
                   }).first {
                    preview = String(text.prefix(160))
                }
            case .assistant:
                count += 1
            }
        }
        return ScanResult(count: count, preview: preview)
    }

    private static func parseDate(_ raw: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    private func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

struct CodexSessionLogParser {
    func parse(_ data: Data) -> [TranscriptItem] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        var items: [TranscriptItem] = []
        var toolIndex: [String: (itemIdx: Int, callId: UUID)] = [:]

        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let obj = jsonObject(String(raw)) else { continue }
            switch obj["type"] as? String {
            case "event_msg":
                parseEventMessage(obj["payload"] as? [String: Any],
                                  into: &items)
            case "response_item":
                parseResponseItem(obj["payload"] as? [String: Any],
                                  into: &items,
                                  toolIndex: &toolIndex)
            default:
                continue
            }
        }

        markUnfinishedToolCalls(in: &items)
        return items
    }

    private func parseEventMessage(_ payload: [String: Any]?,
                                   into items: inout [TranscriptItem]) {
        guard payload?["type"] as? String == "user_message",
              let message = payload?["message"] as? String
        else { return }
        let text = message.trimmingCharacters(in: .newlines)
        guard !text.isEmpty else { return }
        items.append(.message(Message(
            id: UUID(), role: .user, who: "you", meta: nil,
            parts: [.text(text)])))
    }

    private func parseResponseItem(_ payload: [String: Any]?,
                                   into items: inout [TranscriptItem],
                                   toolIndex: inout [String: (itemIdx: Int, callId: UUID)]) {
        guard let payload,
              let type = payload["type"] as? String
        else { return }

        switch type {
        case "function_call":
            let callId = payload["call_id"] as? String ?? UUID().uuidString
            let rawName = payload["name"] as? String ?? "tool"
            let arguments = payload["arguments"] as? String ?? ""
            let toolCallId = UUID()
            items.append(.message(Message(
                id: UUID(),
                role: .assistant(meta: "done"),
                who: "codex",
                meta: nil,
                parts: [.toolCall(ToolCall(
                    id: toolCallId,
                    name: toolName(rawName),
                    arg: toolArgument(rawName: rawName, arguments: arguments),
                    status: .running,
                    meta: nil,
                    body: nil))])))
            toolIndex[callId] = (items.count - 1, toolCallId)

        case "function_call_output":
            guard let callId = payload["call_id"] as? String,
                  let mapping = toolIndex[callId],
                  mapping.itemIdx < items.count,
                  case .message(var msg) = items[mapping.itemIdx],
                  let partIdx = msg.parts.firstIndex(where: {
                      if case .toolCall(let call) = $0 {
                          return call.id == mapping.callId
                      }
                      return false
                  }),
                  case .toolCall(var call) = msg.parts[partIdx]
            else { return }
            let output = payload["output"] as? String ?? ""
            call.body = output
            if let exit = exitCode(from: output) {
                call.status = exit == 0 ? .ok(exit: exit) : .error(exit: exit)
            } else {
                call.status = .ok(exit: 0)
            }
            msg.parts[partIdx] = .toolCall(call)
            items[mapping.itemIdx] = .message(msg)

        case "message":
            guard payload["role"] as? String == "assistant",
                  let text = outputText(payload["content"]),
                  !text.isEmpty
            else { return }
            items.append(.message(Message(
                id: UUID(),
                role: .assistant(meta: "done"),
                who: "codex",
                meta: nil,
                parts: [.text(text)])))

        default:
            break
        }
    }

    private func markUnfinishedToolCalls(in items: inout [TranscriptItem]) {
        for idx in items.indices {
            guard case .message(var msg) = items[idx] else { continue }
            var changed = false
            msg.parts = msg.parts.map { part in
                guard case .toolCall(var call) = part else { return part }
                if case .running = call.status {
                    call.status = .stopped
                    changed = true
                }
                return .toolCall(call)
            }
            if changed {
                msg.role = .assistant(meta: "stopped")
                msg.meta = "stopped"
                items[idx] = .message(msg)
            }
        }
    }

    private func toolName(_ rawName: String) -> String {
        switch rawName {
        case "exec_command": return "Shell"
        case "apply_patch": return "Apply Patch"
        default: return rawName
        }
    }

    private func toolArgument(rawName: String, arguments: String) -> String {
        guard rawName == "exec_command",
              let data = arguments.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cmd = obj["cmd"] as? String,
              !cmd.isEmpty
        else { return arguments }
        return "/bin/bash -lc \(cmd)"
    }

    private func outputText(_ raw: Any?) -> String? {
        guard let blocks = raw as? [[String: Any]] else { return nil }
        var text = ""
        for block in blocks {
            if (block["type"] as? String) == "output_text",
               let value = block["text"] as? String {
                text += value
            }
        }
        return text.isEmpty ? nil : text
    }

    private func exitCode(from output: String) -> Int? {
        let marker = "Process exited with code "
        guard let range = output.range(of: marker) else { return nil }
        let tail = output[range.upperBound...]
        let digits = tail.prefix { $0.isNumber || $0 == "-" }
        return Int(digits)
    }

    private func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
