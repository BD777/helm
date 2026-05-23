import Foundation

/// Spawns the local `claude` CLI in `--print --input-format stream-json
/// --output-format stream-json --verbose --include-partial-messages` mode and
/// translates its JSONL output into `AgentEvent`s.
final class ClaudeLocalAdapter: AgentAdapter, @unchecked Sendable {
    let sessionStore: AgentSessionStore = ClaudeSessionStore()
    private var process: Process?
    private let lock = NSLock()

    func start(prompt: String,
               attachments: [ImageAttachment],
               session: Session,
               run: RunConfig,
               project: Project) throws -> AsyncThrowingStream<AgentEvent, Error> {
        var args: [String] = [
            "--print",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
        ]
        if let resume = session.vendorSessionId {
            args.append(contentsOf: ["--resume", resume])
        } else {
            // Use our session.id as the vendor session id so the on-disk file
            // (`~/.claude/projects/<bucket>/<id>.jsonl`) matches what Helm
            // tracks. Once Claude reports it back via .sessionId we stash it
            // on session.vendorSessionId for resume.
            args.append(contentsOf: ["--session-id",
                                     session.id.uuidString.lowercased()])
        }
        // Resolver-provided args (e.g. --model, --setting-sources).
        args.append(contentsOf: run.args)

        var env = ProcessInfo.processInfo.environment
        // GUI apps inherit a stripped PATH — add the usual command locations
        // so a bare `claude` resolves and so child tools work. ~/.local/bin
        // (new native installer) goes first so it wins over older brew npm
        // installs at /opt/homebrew/bin.
        let extras = ["\(NSHomeDirectory())/.local/bin",
                      "/opt/homebrew/bin", "/usr/local/bin"]
        let existing = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (extras + [existing]).joined(separator: ":")
        for (k, v) in run.env { env[k] = v }

        let proc = Process()
        switch project.location {
        case .local(let path):
            let executable = try resolveCommand(run.command, vendorDefault: "claude")
            proc.executableURL = URL(fileURLWithPath: executable)
            proc.arguments = args
            proc.currentDirectoryURL = URL(fileURLWithPath:
                (path as NSString).expandingTildeInPath)
        case .ssh(let host, let path, _):
            guard attachments.isEmpty else {
                throw AdapterError.unsupportedRemoteAttachments("Claude")
            }
            let remote = SSHRemote.commandLine(
                command: run.command.isEmpty ? "claude" : run.command,
                args: args,
                env: run.env,
                workingDirectory: path
            )
            proc.executableURL = URL(fileURLWithPath: SSHRemote.executable)
            proc.arguments = SSHRemote.arguments(
                host: host,
                remoteCommand: remote,
                batchMode: true,
                connectTimeout: 15
            )
        }
        proc.environment = env

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        lock.lock(); process = proc; lock.unlock()

        return AsyncThrowingStream { continuation in
            let parser = ClaudeStreamParser()
            let stdoutHandle = stdout.fileHandleForReading
            let stderrHandle = stderr.fileHandleForReading
            let stderrLock = NSLock()
            var stderrTail = "" // keep the most recent ~4KB for error context

            stdoutHandle.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { return }
                for event in parser.feed(data) {
                    NSLog("[helm.claude] event: %@", String(describing: event).prefix(180) as CVarArg)
                    continuation.yield(event)
                }
            }
            stderrHandle.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { return }
                guard let chunk = String(data: data, encoding: .utf8) else { return }
                NSLog("[helm.claude] stderr: %@", chunk as CVarArg)
                stderrLock.lock()
                stderrTail.append(chunk)
                if stderrTail.count > 4096 {
                    stderrTail = String(stderrTail.suffix(4096))
                }
                stderrLock.unlock()
                // Surface stderr lines live so the UI doesn't go silent.
                for line in chunk.split(separator: "\n", omittingEmptySubsequences: true) {
                    continuation.yield(.error(String(line)))
                }
            }
            proc.terminationHandler = { p in
                stdoutHandle.readabilityHandler = nil
                stderrHandle.readabilityHandler = nil
                NSLog("[helm.claude] exit status=%d", p.terminationStatus)
                for event in parser.flush() {
                    NSLog("[helm.claude] flush event: %@", String(describing: event).prefix(180) as CVarArg)
                    continuation.yield(event)
                }
                if p.terminationStatus != 0 {
                    stderrLock.lock()
                    let tail = stderrTail
                    stderrLock.unlock()
                    let suffix = tail.isEmpty ? "" : ": \(tail.trimmingCharacters(in: .whitespacesAndNewlines))"
                    continuation.yield(.error("claude exited \(p.terminationStatus)\(suffix)"))
                }
                continuation.finish()
            }

            continuation.onTermination = { [weak self] _ in
                self?.cancel()
            }

            do {
                try proc.run()
            } catch {
                continuation.finish(throwing: error)
                return
            }

            // Send the user's prompt as a single stream-json record, then
            // close stdin so the CLI knows the input is done. Image
            // attachments become base64 image content blocks alongside the
            // text — the Anthropic API's only on-disk option (URL sources
            // require HTTP, no file://). This base64 ends up in Claude's own
            // session JSONL on disk; Helm uses its own image manifest for
            // history rehydration so we don't pay that cost twice.
            var content: [[String: Any]] = [["type": "text", "text": prompt]]
            for att in attachments {
                guard let bytes = try? Data(contentsOf: att.fileURL) else {
                    continuation.yield(.error("failed to read attachment: \(att.fileURL.lastPathComponent)"))
                    continue
                }
                content.append([
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": att.mediaType,
                        "data": bytes.base64EncodedString(),
                    ],
                ])
            }
            let record: [String: Any] = [
                "type": "user",
                "message": [
                    "role": "user",
                    "content": content,
                ],
            ]
            do {
                let json = try JSONSerialization.data(withJSONObject: record, options: [])
                try stdin.fileHandleForWriting.write(contentsOf: json)
                try stdin.fileHandleForWriting.write(contentsOf: Data([0x0A]))
                try stdin.fileHandleForWriting.close()
            } catch {
                continuation.yield(.error("stdin write failed: \(error.localizedDescription)"))
                self.cancel()
            }
        }
    }

    func cancel() {
        lock.lock(); let p = process; lock.unlock()
        guard let p, p.isRunning else { return }
        p.terminate()
    }

    // MARK: -

    private func resolveCommand(_ path: String, vendorDefault: String) throws -> String {
        let candidate = path.isEmpty ? vendorDefault : path
        if candidate.contains("/") {
            return (candidate as NSString).expandingTildeInPath
        }
        for dir in ["\(NSHomeDirectory())/.local/bin",
                    "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            let full = "\(dir)/\(candidate)"
            if FileManager.default.isExecutableFile(atPath: full) { return full }
        }
        throw AdapterError.commandNotFound(candidate)
    }
}

enum AdapterError: LocalizedError {
    case commandNotFound(String)
    case unsupportedRemoteAttachments(String)

    var errorDescription: String? {
        switch self {
        case .commandNotFound(let c):
            return "Command not found on PATH: \(c). Set commandPath in the profile to an absolute path."
        case .unsupportedRemoteAttachments(let vendor):
            return "\(vendor) image attachments are not supported for SSH projects yet."
        }
    }
}

// MARK: - Stream parser

/// Buffered line-delimited JSON parser that turns Claude's stream-json output
/// into `AgentEvent`s.
final class ClaudeStreamParser {
    /// String buffer of incomplete trailing line content. Using String (not
    /// Data) sidesteps the slice-startIndex gotcha and makes incremental
    /// JSONL parsing reliable.
    private var pending: String = ""
    /// Most recent in-flight tool_use id, so `input_json_delta` events can
    /// be attached to the right call.
    private var activeToolId: String?

    func feed(_ data: Data) -> [AgentEvent] {
        guard let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty else {
            return []
        }
        pending.append(chunk)
        var events: [AgentEvent] = []
        while let nl = pending.firstIndex(of: "\n") {
            let line = String(pending[..<nl])
            pending.removeSubrange(...nl)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard let lineData = trimmed.data(using: .utf8) else { continue }
            events.append(contentsOf: parseLine(lineData))
        }
        return events
    }

    /// Drain any incomplete trailing line — called once on EOF / process exit
    /// so we don't lose a `result` event that arrives without a final newline.
    func flush() -> [AgentEvent] {
        let trimmed = pending.trimmingCharacters(in: .whitespaces)
        pending = ""
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return [] }
        return parseLine(data)
    }

    private func parseLine(_ data: Data) -> [AgentEvent] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        let type = obj["type"] as? String ?? ""
        switch type {
        case "system":
            if let sid = obj["session_id"] as? String {
                return [.sessionId(sid)]
            }
            return []

        case "stream_event":
            guard let event = obj["event"] as? [String: Any] else { return [] }
            return parseStreamEvent(event)

        case "assistant":
            // Full snapshot emitted after deltas — we already streamed text, so
            // only surface the message boundary if the deltas didn't.
            return []

        case "user":
            // Echoed user message containing tool_result blocks from the
            // agent's own tool runs.
            guard let msg = obj["message"] as? [String: Any],
                  let blocks = msg["content"] as? [[String: Any]] else { return [] }
            var out: [AgentEvent] = []
            for block in blocks where (block["type"] as? String) == "tool_result" {
                let id = block["tool_use_id"] as? String ?? ""
                let isError = block["is_error"] as? Bool ?? false
                let output = flattenContent(block["content"]) ?? ""
                out.append(.toolResult(id: id, output: output, isError: isError))
            }
            return out

        case "result":
            let isError = obj["is_error"] as? Bool ?? false
            let errors = obj["errors"] as? [String] ?? []
            let resultText = obj["result"] as? String ?? ""
            let text = resultText.isEmpty && isError
                ? errors.joined(separator: "\n")
                : resultText
            var out: [AgentEvent] = []
            if let sid = obj["session_id"] as? String { out.append(.sessionId(sid)) }
            out.append(.finalResult(text: text, isError: isError))
            return out

        default:
            return []
        }
    }

    private func parseStreamEvent(_ event: [String: Any]) -> [AgentEvent] {
        let etype = event["type"] as? String ?? ""
        switch etype {
        case "content_block_start":
            guard let block = event["content_block"] as? [String: Any] else { return [] }
            if (block["type"] as? String) == "tool_use" {
                let id = block["id"] as? String ?? ""
                let name = block["name"] as? String ?? ""
                let input = (block["input"] as? [String: Any])
                    .flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                activeToolId = id
                return [.toolCallStart(id: id, name: name, input: input)]
            }
            return []

        case "content_block_delta":
            guard let delta = event["delta"] as? [String: Any] else { return [] }
            switch delta["type"] as? String {
            case "text_delta":
                if let t = delta["text"] as? String, !t.isEmpty {
                    return [.assistantTextDelta(t)]
                }
            case "input_json_delta":
                if let frag = delta["partial_json"] as? String,
                   !frag.isEmpty, let id = activeToolId {
                    return [.toolInputDelta(id: id, fragment: frag)]
                }
            default: break
            }
            return []

        case "content_block_stop":
            activeToolId = nil
            return []

        case "message_stop":
            return [.messageStop]

        default:
            return []
        }
    }

    private func flattenContent(_ raw: Any?) -> String? {
        if let s = raw as? String { return s }
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
