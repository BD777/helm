import Foundation

/// Spawns the local `claude` CLI in `--print --input-format stream-json
/// --output-format stream-json --verbose --include-partial-messages` mode and
/// translates its JSONL output into `AgentEvent`s.
final class ClaudeLocalAdapter: AgentAdapter, @unchecked Sendable {
    let sessionStore: AgentSessionStore = ClaudeSessionStore()
    private var process: Process?
    private var descendantTracker: ProcessDescendantTracker?
    private var permissionBridge: ClaudePermissionBridge?
    private var stdinHandle: FileHandle?
    private var isRemoteProject = false
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

        let permissionBridge = try ClaudePermissionBridge.makeIfNeeded(session: session,
                                                                       project: project)
        if let permissionBridge {
            args.append(contentsOf: ["--plugin-dir", permissionBridge.pluginURL.path])
        }

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

        lock.lock()
        process = proc
        self.permissionBridge = permissionBridge
        stdinHandle = stdin.fileHandleForWriting
        isRemoteProject = project.location.isSSH
        lock.unlock()

        return AsyncThrowingStream { continuation in
            let parser = ClaudeStreamParser()
            let stdoutHandle = stdout.fileHandleForReading
            let stderrHandle = stderr.fileHandleForReading
            let stderrLock = NSLock()
            var stderrTail = "" // keep the most recent ~4KB for error context

            permissionBridge?.start { event in
                continuation.yield(event)
            }

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
                permissionBridge?.stop(responding: .cancel)
                let tracked = self.stopTrackingDescendants()
                self.clearProcessIfCurrent(p)
                ProcessTreeTerminator.terminate(pids: tracked, killAfter: 0.5)
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
                self.startTrackingDescendantsIfNeeded(for: run, process: proc)
            } catch {
                continuation.finish(throwing: error)
                return
            }

            do {
                let data = try Self.userRecordData(prompt: prompt,
                                                   attachments: attachments)
                try self.writeUserRecordData(data)
            } catch {
                continuation.yield(.error("stdin write failed: \(error.localizedDescription)"))
                self.cancel()
            }
        }
    }

    var supportsPromptAppend: Bool { true }

    func append(prompt: String, attachments: [ImageAttachment]) throws {
        lock.lock()
        let isRemoteProject = isRemoteProject
        lock.unlock()
        guard !isRemoteProject || attachments.isEmpty else {
            throw AdapterError.unsupportedRemoteAttachments("Claude")
        }
        let data = try Self.userRecordData(prompt: prompt,
                                           attachments: attachments)
        try writeUserRecordData(data)
    }

    func cancel() {
        lock.lock()
        let p = process
        let bridge = permissionBridge
        let stdin = stdinHandle
        let tracked = stopTrackingDescendantsLocked()
        process = nil
        permissionBridge = nil
        stdinHandle = nil
        isRemoteProject = false
        lock.unlock()
        bridge?.stop(responding: .cancel)
        guard let p else {
            try? stdin?.close()
            return
        }
        ProcessTreeTerminator.terminate(p, closing: stdin, trackedDescendants: tracked)
    }

    func respondToApproval(id: String, decision: AgentApprovalDecision) {
        lock.lock()
        let bridge = permissionBridge
        lock.unlock()
        bridge?.respondToApproval(id: id, decision: decision)
    }

    private func startTrackingDescendantsIfNeeded(for run: RunConfig, process: Process) {
        guard run.usesComputerUseMCP else { return }
        let tracker = ProcessDescendantTracker(process: process)
        tracker.start()
        lock.lock()
        descendantTracker = tracker
        lock.unlock()
    }

    private func stopTrackingDescendants() -> [Int32] {
        lock.lock()
        let tracked = stopTrackingDescendantsLocked()
        lock.unlock()
        return tracked
    }

    private func stopTrackingDescendantsLocked() -> [Int32] {
        let tracker = descendantTracker
        descendantTracker = nil
        return tracker?.stop() ?? []
    }

    private func clearProcessIfCurrent(_ process: Process) {
        lock.lock()
        if self.process === process {
            self.process = nil
            stdinHandle = nil
            permissionBridge = nil
            isRemoteProject = false
        }
        lock.unlock()
    }

    private static func userRecordData(prompt: String,
                                       attachments: [ImageAttachment]) throws -> Data {
        // Claude Code's stream-json input accepts additional user records while
        // the process is running; images must be embedded as base64 blocks.
        var content: [[String: Any]] = [["type": "text", "text": prompt]]
        for attachment in attachments {
            let bytes: Data
            do {
                bytes = try Data(contentsOf: attachment.fileURL)
            } catch {
                throw AdapterError.attachmentReadFailed(attachment.fileURL.lastPathComponent)
            }
            content.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": attachment.mediaType,
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
        var data = try JSONSerialization.data(withJSONObject: record, options: [])
        data.append(0x0A)
        return data
    }

    private func writeUserRecordData(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let handle = stdinHandle else {
            throw AdapterError.promptAppendUnavailable("Claude")
        }
        try handle.write(contentsOf: data)
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

private final class ClaudePermissionBridge: @unchecked Sendable {
    // Claude hook timeouts are seconds, but values above Int32.max
    // milliseconds are cancelled immediately by the CLI runtime. This keeps
    // approval effectively blocking without tripping that overflow path.
    private static let blockingHookTimeoutSeconds = 2_000_000

    private struct Pending {
        let requestURL: URL
        let responseURL: URL
    }

    let pluginURL: URL

    private let baseURL: URL
    private let requestsURL: URL
    private let responsesURL: URL
    private let pluginManifestURL: URL
    private let scriptURL: URL
    private let hooksURL: URL
    private let lock = NSLock()
    private var pending: [String: Pending] = [:]
    private var monitorTask: Task<Void, Never>?
    private var isStopped = false

    static func makeIfNeeded(session: Session, project: Project) throws -> ClaudePermissionBridge? {
        guard !project.location.isSSH,
              session.claudePermissionMode == .defaultMode
        else { return nil }
        return try ClaudePermissionBridge(sessionId: session.id)
    }

    private init(sessionId: UUID) throws {
        let runId = UUID().uuidString.lowercased()
        let root = AppPaths.appSupportDir()
            .appendingPathComponent("claude-permission-bridge", isDirectory: true)
            .appendingPathComponent(sessionId.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent(runId, isDirectory: true)
        baseURL = root
        pluginURL = root.appendingPathComponent("helm-permission-bridge-plugin", isDirectory: true)
        requestsURL = root.appendingPathComponent("requests", isDirectory: true)
        responsesURL = root.appendingPathComponent("responses", isDirectory: true)
        pluginManifestURL = pluginURL
            .appendingPathComponent(".claude-plugin", isDirectory: true)
            .appendingPathComponent("plugin.json")
        scriptURL = pluginURL
            .appendingPathComponent("scripts", isDirectory: true)
            .appendingPathComponent("permission-hook.sh")
        hooksURL = pluginURL
            .appendingPathComponent("hooks", isDirectory: true)
            .appendingPathComponent("hooks.json")

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: requestsURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: responsesURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: pluginManifestURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        try fileManager.createDirectory(at: scriptURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        try fileManager.createDirectory(at: hooksURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        try writePluginManifest()
        try writeHookScript()
        try writeHookConfig()
    }

    func start(_ emit: @escaping @Sendable (AgentEvent) -> Void) {
        lock.lock()
        guard monitorTask == nil, !isStopped else {
            lock.unlock()
            return
        }
        monitorTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                self?.drainRequests(emit)
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        lock.unlock()
    }

    func respondToApproval(id: String, decision: AgentApprovalDecision) {
        let pendingRequest: Pending?
        lock.lock()
        pendingRequest = pending.removeValue(forKey: id)
        lock.unlock()

        guard let pendingRequest else { return }
        writeResponse(decision: decision, pending: pendingRequest)
        try? FileManager.default.removeItem(at: pendingRequest.requestURL)
    }

    func stop(responding decision: AgentApprovalDecision) {
        let requests: [Pending]
        lock.lock()
        if isStopped {
            lock.unlock()
            return
        }
        isStopped = true
        monitorTask?.cancel()
        monitorTask = nil
        requests = Array(pending.values)
        pending.removeAll()
        lock.unlock()

        for request in requests {
            writeResponse(decision: decision, pending: request)
        }
        cancelUntrackedRequests(decision)

        let baseURL = baseURL
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
            try? FileManager.default.removeItem(at: baseURL)
        }
    }

    private func drainRequests(_ emit: @escaping @Sendable (AgentEvent) -> Void) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: requestsURL,
            includingPropertiesForKeys: nil
        )) ?? []

        for url in files where url.pathExtension == "json" {
            let id = url.deletingPathExtension().lastPathComponent
            lock.lock()
            let known = pending[id] != nil || isStopped
            lock.unlock()
            guard !known else { continue }

            guard let event = approvalEvent(id: id, requestURL: url) else {
                try? FileManager.default.removeItem(at: url)
                continue
            }

            lock.lock()
            if pending[id] == nil, !isStopped {
                pending[id] = Pending(
                    requestURL: url,
                    responseURL: responsesURL.appendingPathComponent("\(id).json")
                )
                lock.unlock()
                emit(.approvalRequest(event))
            } else {
                lock.unlock()
            }
        }
    }

    private func approvalEvent(id: String, requestURL: URL) -> AgentApprovalRequest? {
        guard let data = try? Data(contentsOf: requestURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let toolName = object["tool_name"] as? String ?? "tool"
        let toolInput = object["tool_input"] as? [String: Any] ?? [:]
        let cwd = object["cwd"] as? String
        let detail = detailText(toolName: toolName, toolInput: toolInput, cwd: cwd)
        return AgentApprovalRequest(
            id: id,
            kind: approvalKind(toolName: toolName),
            title: approvalTitle(toolName: toolName),
            message: approvalMessage(toolName: toolName, toolInput: toolInput),
            detail: detail.isEmpty ? serialize(object) : detail,
            allowsSessionApproval: false
        )
    }

    private func writeResponse(decision: AgentApprovalDecision, pending: Pending) {
        let object: [String: Any]
        switch decision {
        case .accept, .acceptForSession:
            object = [
                "hookSpecificOutput": [
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "allow",
                    "permissionDecisionReason": "Approved in Helm.",
                ],
            ]
        case .decline:
            object = [
                "hookSpecificOutput": [
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": "Denied in Helm.",
                ],
            ]
        case .cancel:
            object = [
                "hookSpecificOutput": [
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": "Cancelled in Helm.",
                ],
            ]
        }

        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object)
        else { return }
        let tmp = pending.responseURL.deletingLastPathComponent()
            .appendingPathComponent(".\(pending.responseURL.lastPathComponent).tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: pending.responseURL.path) {
                try FileManager.default.removeItem(at: pending.responseURL)
            }
            try FileManager.default.moveItem(at: tmp, to: pending.responseURL)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    private func writeHookScript() throws {
        let script = """
        #!/bin/bash
        set -u

        base_dir="$1"
        requests_dir="$base_dir/requests"
        responses_dir="$base_dir/responses"
        mkdir -p "$requests_dir" "$responses_dir"

        request_id="$(/usr/bin/uuidgen 2>/dev/null || printf '%s-%s' "$$" "$(date +%s)")"
        request_tmp="$requests_dir/$request_id.tmp"
        request_file="$requests_dir/$request_id.json"
        response_file="$responses_dir/$request_id.json"

        cat > "$request_tmp"
        mv "$request_tmp" "$request_file"

        while [ ! -f "$response_file" ]; do
          sleep 0.2
        done

        cat "$response_file"
        rm -f "$response_file" "$request_file"
        """
        try script.data(using: .utf8)?.write(to: scriptURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                              ofItemAtPath: scriptURL.path)
    }

    private func writePluginManifest() throws {
        let manifest: [String: Any] = [
            "name": "helm-permission-bridge",
            "version": "1.0.0",
            "description": "Routes Claude Code permission requests through Helm.",
            "author": [
                "name": "Helm",
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: pluginManifestURL, options: .atomic)
    }

    private func writeHookConfig() throws {
        let config: [String: Any] = [
            "description": "Helm permission approval bridge",
            "hooks": [
                "PreToolUse": [[
                    "matcher": "Bash|Edit|MultiEdit|Write|NotebookEdit",
                    "hooks": [[
                        "type": "command",
                        "command": "\(shellQuote(scriptURL.path)) \(shellQuote(baseURL.path))",
                        "timeout": Self.blockingHookTimeoutSeconds,
                        "statusMessage": "Waiting for Helm permission approval",
                    ]],
                ]],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: config,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: hooksURL, options: .atomic)
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func cancelUntrackedRequests(_ decision: AgentApprovalDecision) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: requestsURL,
            includingPropertiesForKeys: nil
        )) ?? []
        for url in files where url.pathExtension == "json" {
            let id = url.deletingPathExtension().lastPathComponent
            let pending = Pending(
                requestURL: url,
                responseURL: responsesURL.appendingPathComponent("\(id).json")
            )
            writeResponse(decision: decision, pending: pending)
        }
    }

    private func approvalKind(toolName: String) -> AgentApprovalRequest.Kind {
        switch toolName {
        case "Bash":
            return .command
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            return .fileChange
        default:
            return .permissions
        }
    }

    private func approvalTitle(toolName: String) -> String {
        switch approvalKind(toolName: toolName) {
        case .command:
            return "Approve Claude Command"
        case .fileChange:
            return "Approve Claude File Change"
        default:
            return "Approve Claude Tool"
        }
    }

    private func approvalMessage(toolName: String, toolInput: [String: Any]) -> String {
        if toolName == "Bash" {
            if let description = toolInput["description"] as? String,
               !description.isEmpty {
                return description
            }
            return "Claude wants to run a command."
        }
        if let filePath = toolInput["file_path"] as? String,
           !filePath.isEmpty {
            return "Claude wants to edit \((filePath as NSString).lastPathComponent)."
        }
        return "Claude needs permission to use \(toolName)."
    }

    private func detailText(toolName: String,
                            toolInput: [String: Any],
                            cwd: String?) -> String {
        var lines = ["tool: \(toolName)"]
        if let cwd, !cwd.isEmpty {
            lines.append("cwd: \(cwd)")
        }
        if let command = toolInput["command"] as? String, !command.isEmpty {
            lines.append(command)
        } else if let filePath = toolInput["file_path"] as? String, !filePath.isEmpty {
            lines.append("file: \(filePath)")
        }
        if lines.count <= 2, let serialized = serialize(toolInput) {
            lines.append(serialized)
        }
        return lines.joined(separator: "\n")
    }

    private func serialize(_ value: Any?) -> String? {
        guard let value,
              JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty
        else { return nil }
        return text
    }
}

enum AdapterError: LocalizedError {
    case commandNotFound(String)
    case unsupportedRemoteAttachments(String)
    case attachmentReadFailed(String)
    case promptAppendUnavailable(String)
    case promptAppendUnsupported

    var errorDescription: String? {
        switch self {
        case .commandNotFound(let c):
            return "Command not found on PATH: \(c). Install the CLI or set commandPath in the profile to an absolute path."
        case .unsupportedRemoteAttachments(let vendor):
            return "\(vendor) image attachments are not supported for SSH projects yet."
        case .attachmentReadFailed(let filename):
            return "Failed to read attachment: \(filename)."
        case .promptAppendUnavailable(let vendor):
            return "\(vendor) is not ready to accept more input for this response."
        case .promptAppendUnsupported:
            return "This agent cannot accept more input while a response is running."
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
    /// Seed-backed Claude profiles can occasionally emit their tool protocol
    /// as text. Buffer text deltas long enough to keep partial tags from
    /// flashing into the transcript.
    private var textToolBuffer: String = ""

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
        var events: [AgentEvent] = []
        if !trimmed.isEmpty, let data = trimmed.data(using: .utf8) {
            events.append(contentsOf: parseLine(data))
        }
        events.append(contentsOf: flushTextToolBuffer())
        return events
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
            let filteredResultText = SeedTextToolCallParser.textByRemovingToolCalls(from: resultText)
            let text = filteredResultText.isEmpty && isError
                ? errors.joined(separator: "\n")
                : filteredResultText
            var out: [AgentEvent] = []
            out.append(contentsOf: flushTextToolBuffer())
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
                let rawName = block["name"] as? String ?? ""
                let input = (block["input"] as? [String: Any])
                    .flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                activeToolId = id
                return [.toolCallStart(id: id,
                                       name: CodexToolPresentation.name(rawName: rawName,
                                                                        namespace: nil),
                                       input: CodexToolPresentation.argument(rawName: rawName,
                                                                             namespace: nil,
                                                                             arguments: input))]
            }
            return []

        case "content_block_delta":
            guard let delta = event["delta"] as? [String: Any] else { return [] }
            switch delta["type"] as? String {
            case "text_delta":
                if let t = delta["text"] as? String, !t.isEmpty {
                    return consumeTextDelta(t)
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
            return flushTextToolBuffer()

        case "message_stop":
            var out = flushTextToolBuffer()
            out.append(.messageStop)
            return out

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

    private func consumeTextDelta(_ text: String) -> [AgentEvent] {
        textToolBuffer += text
        let consumed = SeedTextToolCallParser.consumeCompleteSegments(from: textToolBuffer)
        textToolBuffer = consumed.remainder
        return SeedTextToolCallParser.events(from: consumed.segments)
    }

    private func flushTextToolBuffer() -> [AgentEvent] {
        guard !textToolBuffer.isEmpty else { return [] }
        let buffered = textToolBuffer
        textToolBuffer = ""
        return SeedTextToolCallParser.events(from: SeedTextToolCallParser.drainSegments(from: buffered))
    }
}

struct SeedTextToolCall {
    let vendorId: String
    let rawName: String
    let inputJSON: String
}

enum SeedTextToolCallSegment {
    case text(String)
    case toolCall(SeedTextToolCall)
}

enum SeedTextToolCallParser {
    static let blockedToolOutput =
        "Helm did not execute this tool call because Claude emitted it as plain text instead of a tool_use event."

    private static let startMarkers = ["<seed:tooltool", "<seed:tool_call"]
    private static let endMarkers = ["</seed:tool_call>", "</seed:tooltool>"]

    private static let functionRegex = try! NSRegularExpression(
        pattern: #"<function\s+name="([^"]+)"[^>]*>(.*?)</function>"#,
        options: [.dotMatchesLineSeparators]
    )
    private static let parameterRegex = try! NSRegularExpression(
        pattern: #"<parameter\s+name="([^"]+)"[^>]*>(.*?)</parameter>"#,
        options: [.dotMatchesLineSeparators]
    )

    static func consumeCompleteSegments(from text: String) -> (segments: [SeedTextToolCallSegment], remainder: String) {
        var segments: [SeedTextToolCallSegment] = []
        var cursor = text.startIndex

        while let start = nextStart(in: text, range: cursor..<text.endIndex) {
            if cursor < start.lowerBound {
                let prefix = String(text[cursor..<start.lowerBound])
                guard prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    appendText(String(text[cursor..<start.upperBound]), to: &segments)
                    cursor = start.upperBound
                    continue
                }
                appendText(prefix, to: &segments)
            }

            guard let end = nextEnd(in: text, range: start.lowerBound..<text.endIndex) else {
                return (segments, String(text[start.lowerBound...]))
            }

            let block = String(text[start.lowerBound..<end.upperBound])
            if let call = parseToolCall(from: block) {
                segments.append(.toolCall(call))
            } else {
                appendText(block, to: &segments)
            }
            cursor = end.upperBound
        }

        let tail = String(text[cursor...])
        if let remainder = partialStartRemainder(in: tail) {
            let emitCount = tail.count - remainder.count
            if emitCount > 0 {
                let emitEnd = tail.index(tail.startIndex, offsetBy: emitCount)
                appendText(String(tail[..<emitEnd]), to: &segments)
            }
            return (segments, remainder)
        }

        appendText(tail, to: &segments)
        return (segments, "")
    }

    static func drainSegments(from text: String) -> [SeedTextToolCallSegment] {
        let consumed = consumeCompleteSegments(from: text)
        var segments = consumed.segments
        appendText(consumed.remainder, to: &segments)
        return segments
    }

    static func textByRemovingToolCalls(from text: String) -> String {
        drainSegments(from: text).compactMap { segment in
            if case .text(let value) = segment {
                return value
            }
            return nil
        }.joined()
    }

    static func events(from segments: [SeedTextToolCallSegment]) -> [AgentEvent] {
        var events: [AgentEvent] = []
        for segment in segments {
            switch segment {
            case .text(let text):
                if !text.isEmpty {
                    events.append(.assistantTextDelta(text))
                }
            case .toolCall(let call):
                events.append(.toolCallStart(
                    id: call.vendorId,
                    name: displayName(for: call),
                    input: displayInput(for: call)
                ))
                events.append(.toolResult(
                    id: call.vendorId,
                    output: blockedToolOutput,
                    isError: true
                ))
            }
        }
        return events
    }

    static func parts(from text: String) -> [Part] {
        parts(from: drainSegments(from: text))
    }

    static func sanitizeTranscriptItems(_ items: [TranscriptItem]) -> [TranscriptItem] {
        items.map { item in
            guard case .message(let message) = item else { return item }
            let sanitized = sanitizeMessage(message)
            return sanitized == message ? item : .message(sanitized)
        }
    }

    private static func parts(from segments: [SeedTextToolCallSegment]) -> [Part] {
        var parts: [Part] = []
        for segment in segments {
            switch segment {
            case .text(let text):
                if !text.isEmpty {
                    appendPart(.text(text), to: &parts)
                }
            case .toolCall(let call):
                appendPart(.toolCall(ToolCall(
                    id: UUID(),
                    name: displayName(for: call),
                    arg: displayInput(for: call),
                    status: .error(exit: 1),
                    meta: "plain-text-tool-call",
                    body: blockedToolOutput
                )), to: &parts)
            }
        }
        return parts
    }

    private static func sanitizeMessage(_ message: Message) -> Message {
        guard case .assistant = message.role else { return message }

        var sanitizedParts: [Part] = []
        var didChange = false
        for part in message.parts {
            guard case .text(let text) = part else {
                appendPart(part, to: &sanitizedParts)
                continue
            }

            let replacement = parts(from: text)
            if replacement.count != 1 || replacement.first != part {
                didChange = true
            }
            for replacementPart in replacement {
                appendPart(replacementPart, to: &sanitizedParts)
            }
        }

        guard didChange else { return message }
        var copy = message
        copy.parts = sanitizedParts
        return copy
    }

    private static func displayName(for call: SeedTextToolCall) -> String {
        CodexToolPresentation.name(rawName: call.rawName, namespace: nil)
    }

    private static func displayInput(for call: SeedTextToolCall) -> String {
        CodexToolPresentation.argument(rawName: call.rawName,
                                       namespace: nil,
                                       arguments: call.inputJSON)
    }

    private static func parseToolCall(from block: String) -> SeedTextToolCall? {
        let fullRange = NSRange(block.startIndex..<block.endIndex, in: block)
        guard let match = functionRegex.firstMatch(in: block, range: fullRange),
              let name = substring(block, match.range(at: 1)),
              let body = substring(block, match.range(at: 2)) else {
            return nil
        }

        let input = parametersJSON(from: body)
        return SeedTextToolCall(vendorId: "seed-text-tool-\(UUID().uuidString)",
                                rawName: decodeEntities(name),
                                inputJSON: input)
    }

    private static func parametersJSON(from body: String) -> String {
        let fullRange = NSRange(body.startIndex..<body.endIndex, in: body)
        let matches = parameterRegex.matches(in: body, range: fullRange)
        var parameters: [String: String] = [:]
        for match in matches {
            guard let name = substring(body, match.range(at: 1)),
                  let value = substring(body, match.range(at: 2)) else {
                continue
            }
            parameters[decodeEntities(name)] = decodeEntities(value)
        }

        guard !parameters.isEmpty,
              JSONSerialization.isValidJSONObject(parameters),
              let data = try? JSONSerialization.data(withJSONObject: parameters,
                                                      options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    private static func nextStart(in text: String, range: Range<String.Index>) -> Range<String.Index>? {
        earliestRange(in: text, markers: startMarkers, range: range)
    }

    private static func nextEnd(in text: String, range: Range<String.Index>) -> Range<String.Index>? {
        earliestRange(in: text, markers: endMarkers, range: range)
    }

    private static func earliestRange(in text: String,
                                      markers: [String],
                                      range: Range<String.Index>) -> Range<String.Index>? {
        var best: Range<String.Index>?
        for marker in markers {
            guard let found = text.range(of: marker, range: range) else { continue }
            if best == nil || found.lowerBound < best!.lowerBound {
                best = found
            }
        }
        return best
    }

    private static func partialStartRemainder(in text: String) -> String? {
        guard !text.isEmpty else { return nil }

        var bestLength = 0
        for marker in startMarkers {
            let maxLength = min(text.count, marker.count - 1)
            guard maxLength >= 2 else { continue }
            for length in 2...maxLength {
                let prefix = String(marker.prefix(length))
                if text.hasSuffix(prefix) {
                    bestLength = max(bestLength, length)
                }
            }
        }

        return bestLength > 0 ? String(text.suffix(bestLength)) : nil
    }

    private static func appendText(_ text: String,
                                   to segments: inout [SeedTextToolCallSegment]) {
        guard !text.isEmpty else { return }
        if case .text(let existing) = segments.last {
            segments[segments.count - 1] = .text(existing + text)
        } else {
            segments.append(.text(text))
        }
    }

    private static func appendPart(_ part: Part, to parts: inout [Part]) {
        if case .text(let incoming) = part,
           case .text(let existing) = parts.last {
            parts[parts.count - 1] = .text(existing + incoming)
        } else {
            parts.append(part)
        }
    }

    private static func substring(_ text: String, _ range: NSRange) -> String? {
        guard let swiftRange = Range(range, in: text) else { return nil }
        return String(text[swiftRange])
    }

    private static func decodeEntities(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
