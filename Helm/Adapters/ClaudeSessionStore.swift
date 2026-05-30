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
        guard !project.location.isSSH else { return [] }
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

    func history(sessionId: String, project: Project) async throws -> [TranscriptItem] {
        if case .ssh(let host, let path, let status) = project.location {
            return try await remoteHistory(sessionId: sessionId,
                                           host: host,
                                           path: path,
                                           status: status)
        }
        let url = bucketURL(for: project)
            .appendingPathComponent("\(sessionId).jsonl", isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        var items = ClaudeSessionLogParser().parse(data)
        // Layer in pasted-image thumbnails from Helm's own per-session
        // manifest. We do this here (not in the parser) so the parser stays
        // pure / vendor-agnostic and so we don't have to decode the base64
        // image blocks back out of Claude's session JSONL.
        if let helmId = UUID(uuidString: sessionId) {
            applyImageManifest(into: &items, sessionId: helmId)
        }
        return items
    }

    private func remoteHistory(sessionId: String,
                               host: String,
                               path: String,
                               status: SSHStatus) async throws -> [TranscriptItem] {
        let cwd = try await remoteWorkingDirectory(host: host,
                                                   path: path,
                                                   status: status)
        let bucket = Self.bucketName(for: cwd)
        let file = "$HOME/.claude/projects/"
            + SSHRemote.shellQuote(bucket)
            + "/"
            + SSHRemote.shellQuote("\(sessionId).jsonl")
        let command = "if [ -f \(file) ]; then cat -- \(file); fi"
        let data = try await sshOutput(host: host, remoteCommand: command)
        guard !data.isEmpty else { return [] }
        var items = ClaudeSessionLogParser().parse(data)
        if let helmId = UUID(uuidString: sessionId) {
            applyImageManifest(into: &items, sessionId: helmId)
        }
        return items
    }

    private func remoteWorkingDirectory(host: String,
                                        path: String,
                                        status: SSHStatus) async throws -> String {
        if let resolved = status.resolvedPath, !resolved.isEmpty {
            return resolved
        }
        let command = "cd -- \(SSHRemote.shellPath(path)) && pwd -P"
        let data = try await sshOutput(host: host, remoteCommand: command)
        let raw = String(data: data, encoding: .utf8) ?? ""
        return raw
            .split(separator: "\n", omittingEmptySubsequences: true)
            .last
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? path
    }

    private func sshOutput(host: String, remoteCommand: String) async throws -> Data {
        try await Task.detached(priority: .utility) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: SSHRemote.executable)
            proc.arguments = SSHRemote.arguments(
                host: host,
                remoteCommand: remoteCommand,
                batchMode: true,
                connectTimeout: 8
            )

            let stdout = Pipe()
            let stderr = Pipe()
            proc.standardOutput = stdout
            proc.standardError = stderr
            let stdoutBuffer = PipeBuffer()
            let stderrBuffer = PipeBuffer()
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                stdoutBuffer.append(chunk)
            }
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                stderrBuffer.append(chunk)
            }
            defer {
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
            }

            try proc.run()
            proc.waitUntilExit()
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            let remainingOut = stdout.fileHandleForReading.readDataToEndOfFile()
            let remainingErr = stderr.fileHandleForReading.readDataToEndOfFile()

            stdoutBuffer.append(remainingOut)
            stderrBuffer.append(remainingErr)
            let data = stdoutBuffer.value()
            let errData = stderrBuffer.value()
            guard proc.terminationStatus == 0 else {
                let reason = String(data: errData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw NSError(
                    domain: "Helm.SSH",
                    code: Int(proc.terminationStatus),
                    userInfo: [
                        NSLocalizedDescriptionKey: reason?.isEmpty == false
                            ? reason!
                            : "ssh exited \(proc.terminationStatus)"
                    ]
                )
            }
            return data
        }.value
    }

    private func applyImageManifest(into items: inout [TranscriptItem], sessionId: UUID) {
        let manifest = ImageManifestStore.load(sessionId: sessionId)
        guard !manifest.entries.isEmpty else { return }
        let dir = AppPaths.imagesDir(for: sessionId)
        let entriesByOrdinal = Dictionary(uniqueKeysWithValues:
            manifest.entries.map { ($0.userMessageOrdinal, $0.imagePaths) })

        var ordinal = 0
        for idx in items.indices {
            guard case .message(var msg) = items[idx], case .user = msg.role else { continue }
            if let names = entriesByOrdinal[ordinal] {
                for name in names {
                    msg.parts.append(.image(dir.appendingPathComponent(name)))
                }
                items[idx] = .message(msg)
            }
            ordinal += 1
        }
    }

    // MARK: -

    private struct ScanResult { var count: Int; var preview: String }

    /// Single-pass over the file: count user/assistant lines, capture first
    /// real user-text content for preview. Compact-summary entries (which
    /// Claude writes as `type: "user"` with `isCompactSummary: true`) are
    /// excluded from both — otherwise the sidebar would count summary as a
    /// turn and grab its first line as the preview.
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
            if obj["isCompactSummary"] as? Bool == true { continue }
            if obj["isVisibleInTranscriptOnly"] as? Bool == true { continue }
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

private final class PipeBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        storage.append(chunk)
        lock.unlock()
    }

    func value() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// Parses Claude's session log jsonl into our TranscriptItem model. Dialog
/// turns become `.message`; runtime events (compact summaries) become
/// `.event`. `tool_result` blocks (which arrive inside `user` entries echoed
/// by the runtime) are stitched onto the originating assistant ToolCall part.
struct ClaudeSessionLogParser {

    func parse(_ data: Data) -> [TranscriptItem] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        var items: [TranscriptItem] = []
        // tool_use_id (from vendor) → (index of owning assistant TranscriptItem,
        // ToolCall.id we generated). Lets us mutate the ToolCall part when a
        // matching tool_result comes in later.
        var toolIndex: [String: (itemIdx: Int, callId: UUID)] = [:]

        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
            let type = obj["type"] as? String ?? ""
            if obj["isSidechain"] as? Bool == true { continue }

            // Compact-summary entries arrive as type:"user" but are not user
            // input — they're Claude's own summary of the prior conversation
            // injected to seed the next context window. Render as an event.
            if obj["isCompactSummary"] as? Bool == true {
                if let msg = obj["message"] as? [String: Any],
                   let summary = Self.extractFirstText(msg["content"]),
                   !summary.isEmpty {
                    items.append(.event(.compactSummary(id: UUID(), summary: summary)))
                }
                continue
            }
            // Other transcript-only entries (system reminders, etc) are
            // context for the model, not chat content. Skip until we have
            // a concrete event kind for each.
            if obj["isVisibleInTranscriptOnly"] as? Bool == true { continue }

            switch type {
            case "user":
                guard let msg = obj["message"] as? [String: Any],
                      (msg["role"] as? String) == "user" else { continue }
                let content = msg["content"]
                if let s = content as? String, !s.isEmpty {
                    items.append(.message(Message(
                        id: UUID(), role: .user, who: "you", meta: nil,
                        parts: [.text(s)])))
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
                            applyToolResult(block, into: &items, toolIndex: toolIndex)
                        default: break
                        }
                    }
                    if !textParts.isEmpty {
                        items.append(.message(Message(
                            id: UUID(), role: .user, who: "you", meta: nil,
                            parts: [.text(textParts.joined())])))
                    }
                }

            case "assistant":
                guard let msg = obj["message"] as? [String: Any],
                      let blocks = msg["content"] as? [[String: Any]] else { continue }
                var parts: [Part] = []
                let willBeIndex = items.count
                var pendingToolMappings: [(useId: String, callId: UUID)] = []
                for block in blocks {
                    let btype = block["type"] as? String
                    switch btype {
                    case "text":
                        if let t = block["text"] as? String, !t.isEmpty {
                            parts.append(contentsOf: SeedTextToolCallParser.parts(from: t))
                        }
                    case "tool_use":
                        let useId = block["id"] as? String ?? ""
                        let name = block["name"] as? String ?? ""
                        let input = (block["input"] as? [String: Any])
                            .flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                        let callId = UUID()
                        parts.append(.toolCall(ToolCall(
                            id: callId,
                            name: CodexToolPresentation.name(rawName: name,
                                                             namespace: nil),
                            arg: CodexToolPresentation.argument(rawName: name,
                                                                namespace: nil,
                                                                arguments: input),
                            status: .running, meta: nil, body: nil)))
                        pendingToolMappings.append((useId, callId))
                    default: break
                    }
                }
                guard !parts.isEmpty else { continue }
                items.append(.message(Message(
                    id: UUID(), role: .assistant(meta: "done"),
                    who: "claude", meta: nil, parts: parts)))
                for m in pendingToolMappings {
                    toolIndex[m.useId] = (willBeIndex, m.callId)
                }

            default:
                continue
            }
        }
        markUnfinishedToolCalls(in: &items)
        return items
    }

    /// A session log loaded from disk is never an active Helm stream. If a
    /// tool_use has no matching tool_result by the end of the file, the
    /// previous process was interrupted or stopped; render that as stopped
    /// instead of leaving a stale spinner after relaunch.
    private func markUnfinishedToolCalls(in items: inout [TranscriptItem]) {
        for idx in items.indices {
            guard case .message(var msg) = items[idx] else { continue }
            var didStopTool = false
            msg.parts = msg.parts.map { part in
                guard case .toolCall(var call) = part else { return part }
                if case .running = call.status {
                    call.status = .stopped
                    didStopTool = true
                }
                return .toolCall(call)
            }
            if didStopTool {
                msg.role = .assistant(meta: "stopped")
                msg.meta = "stopped"
                items[idx] = .message(msg)
            }
        }
    }

    private func applyToolResult(_ block: [String: Any],
                                 into items: inout [TranscriptItem],
                                 toolIndex: [String: (itemIdx: Int, callId: UUID)]) {
        let useId = block["tool_use_id"] as? String ?? ""
        guard let mapping = toolIndex[useId],
              mapping.itemIdx < items.count,
              case .message(var msg) = items[mapping.itemIdx] else { return }
        let output = Self.extractFirstText(block["content"]) ?? ""
        guard let pIdx = msg.parts.firstIndex(where: {
            if case .toolCall(let t) = $0 { return t.id == mapping.callId } else { return false }
        }), case .toolCall(var call) = msg.parts[pIdx] else { return }
        call.body = output
        if Self.isStoppedToolOutput(output) {
            call.status = .stopped
            msg.role = .assistant(meta: "stopped")
            msg.meta = "stopped"
        } else {
            let isError = block["is_error"] as? Bool ?? false
            call.status = isError ? .error(exit: 1) : .ok(exit: 0)
        }
        msg.parts[pIdx] = .toolCall(call)
        items[mapping.itemIdx] = .message(msg)
    }

    private static func isStoppedToolOutput(_ output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("<status>killed</status>")
            || lower.contains("\"status\":\"killed\"")
            || lower.contains("was stopped")
            || lower.contains("exit_code>137")
            || lower.contains("\"exitcode\":137")
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
