import Foundation

/// Spawns the local `codex exec --json` CLI and translates its JSONL stream
/// into Helm's vendor-neutral `AgentEvent`s.
final class CodexLocalAdapter: AgentAdapter, @unchecked Sendable {
    let sessionStore: AgentSessionStore = CodexSessionStore()
    private var process: Process?
    private let lock = NSLock()

    func start(prompt: String,
               attachments: [ImageAttachment],
               session: Session,
               run: RunConfig,
               project: Project) throws -> AsyncThrowingStream<AgentEvent, Error> {
        let projectPath = project.location.pathString

        var args = run.args
        args.append("exec")
        if let resume = session.vendorSessionId {
            args.append("resume")
            args.append(contentsOf: ["--json", resume])
        } else {
            args.append(contentsOf: ["--json", "--color", "never", "--cd", projectPath])
        }
        for att in attachments {
            args.append(contentsOf: ["--image", att.fileURL.path])
        }
        args.append("-")

        var env = ProcessInfo.processInfo.environment
        let extras = ["\(NSHomeDirectory())/.local/bin",
                      "/opt/homebrew/bin", "/usr/local/bin"]
        let existing = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (extras + [existing]).joined(separator: ":")
        for (k, v) in run.env { env[k] = v }

        let proc = Process()
        switch project.location {
        case .local:
            let executable = try resolveCommand(run.command, vendorDefault: "codex")
            let expandedPath = (projectPath as NSString).expandingTildeInPath
            proc.executableURL = URL(fileURLWithPath: executable)
            proc.arguments = args
            proc.currentDirectoryURL = URL(fileURLWithPath: expandedPath)
        case .ssh(let host, let path, _):
            guard attachments.isEmpty else {
                throw AdapterError.unsupportedRemoteAttachments("Codex")
            }
            let remote = SSHRemote.commandLine(
                command: run.command.isEmpty ? "codex" : run.command,
                args: args,
                env: run.env,
                workingDirectory: path
            )
            proc.executableURL = URL(fileURLWithPath: SSHRemote.executable)
            proc.arguments = SSHRemote.arguments(
                host: host,
                remoteCommand: remote,
                batchMode: true
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
            let parser = CodexStreamParser()
            let stdoutHandle = stdout.fileHandleForReading
            let stderrHandle = stderr.fileHandleForReading
            let stderrLock = NSLock()
            var stderrTail = ""

            stdoutHandle.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { return }
                for event in parser.feed(data) {
                    NSLog("[helm.codex] event: %@", String(describing: event).prefix(180) as CVarArg)
                    continuation.yield(event)
                }
            }
            stderrHandle.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { return }
                guard let chunk = String(data: data, encoding: .utf8) else { return }
                NSLog("[helm.codex] stderr: %@", chunk.prefix(2048) as CVarArg)
                stderrLock.lock()
                stderrTail.append(chunk)
                if stderrTail.count > 4096 {
                    stderrTail = String(stderrTail.suffix(4096))
                }
                stderrLock.unlock()
            }
            proc.terminationHandler = { p in
                stdoutHandle.readabilityHandler = nil
                stderrHandle.readabilityHandler = nil
                NSLog("[helm.codex] exit status=%d", p.terminationStatus)
                for event in parser.flush() {
                    continuation.yield(event)
                }
                if p.terminationStatus != 0 {
                    stderrLock.lock()
                    let tail = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
                    stderrLock.unlock()
                    let suffix = tail.isEmpty ? "" : ": \(tail)"
                    continuation.yield(.error("codex exited \(p.terminationStatus)\(suffix)"))
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

            do {
                try stdin.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
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

final class CodexStreamParser {
    private var pending = ""
    private var startedToolIds: Set<String> = []

    func feed(_ data: Data) -> [AgentEvent] {
        guard let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty else {
            return []
        }
        pending.append(chunk)
        var events: [AgentEvent] = []
        while let nl = pending.firstIndex(of: "\n") {
            let line = String(pending[..<nl])
            pending.removeSubrange(...nl)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard let lineData = trimmed.data(using: .utf8) else { continue }
            events.append(contentsOf: parseLine(lineData))
        }
        return events
    }

    func flush() -> [AgentEvent] {
        let trimmed = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        pending = ""
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return [] }
        return parseLine(data)
    }

    private func parseLine(_ data: Data) -> [AgentEvent] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        switch obj["type"] as? String {
        case "thread.started":
            if let id = obj["thread_id"] as? String {
                return [.sessionId(id)]
            }
            return []

        case "item.started":
            guard let item = obj["item"] as? [String: Any] else { return [] }
            return parseItemStarted(item)

        case "item.completed":
            guard let item = obj["item"] as? [String: Any] else { return [] }
            return parseItemCompleted(item)

        case "turn.failed":
            let message = obj["message"] as? String
                ?? obj["error"] as? String
                ?? "Codex turn failed."
            return [.finalResult(text: message, isError: true)]

        default:
            return []
        }
    }

    private func parseItemStarted(_ item: [String: Any]) -> [AgentEvent] {
        guard (item["type"] as? String) == "command_execution" else { return [] }
        let id = item["id"] as? String ?? UUID().uuidString
        startedToolIds.insert(id)
        return [.toolCallStart(id: id, name: "Shell", input: item["command"] as? String ?? "")]
    }

    private func parseItemCompleted(_ item: [String: Any]) -> [AgentEvent] {
        let type = item["type"] as? String ?? ""
        switch type {
        case "command_execution":
            let id = item["id"] as? String ?? UUID().uuidString
            var out: [AgentEvent] = []
            if !startedToolIds.contains(id) {
                startedToolIds.insert(id)
                out.append(.toolCallStart(id: id, name: "Shell", input: item["command"] as? String ?? ""))
            }
            let output = item["aggregated_output"] as? String ?? ""
            let exit = item["exit_code"] as? Int
            let status = item["status"] as? String ?? ""
            let isError = (exit ?? 0) != 0 || status == "failed"
            out.append(.toolResult(id: id, output: output, isError: isError))
            return out

        case "agent_message":
            let text = item["text"] as? String ?? ""
            var out: [AgentEvent] = []
            if !text.isEmpty {
                out.append(.assistantTextDelta(text))
            }
            out.append(.messageStop)
            out.append(.finalResult(text: text, isError: false))
            return out

        default:
            return []
        }
    }
}
