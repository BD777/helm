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
        let codexWorkingRoot: String = project.location.isSSH ? "." : projectPath

        var args = run.args
        args.append("exec")
        if let resume = session.vendorSessionId {
            args.append("resume")
            args.append(contentsOf: ["--json", "--skip-git-repo-check", resume])
        } else {
            args.append(contentsOf: ["--json", "--color", "never",
                                     "--skip-git-repo-check",
                                     "--cd", codexWorkingRoot])
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
        lock.lock()
        let p = process
        process = nil
        lock.unlock()
        guard let p else { return }
        ProcessTreeTerminator.terminate(p)
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

/// Uses Codex's app-server protocol for local sessions. Unlike `codex exec
/// --json`, app-server is bidirectional: server-initiated approval requests can
/// be answered by Helm's UI and then forwarded as JSON-RPC responses.
final class CodexAppServerAdapter: AgentAdapter, @unchecked Sendable {
    let sessionStore: AgentSessionStore = CodexSessionStore()

    private let lock = NSLock()
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var nextRequestId = 1
    private var initializeRequestId: Int?
    private var threadOpenRequestId: Int?
    private var turnStartRequestId: Int?
    private var activeThreadId: String?
    private var activeTurnId: String?
    private var prompt = ""
    private var attachments: [ImageAttachment] = []
    private var sessionSnapshot: Session?
    private var runSnapshot: RunConfig?
    private var projectSnapshot: Project?
    private var pendingApprovalMethods: [String: String] = [:]
    private var pendingApprovalRequestIds: [String: Any] = [:]
    private var pendingApprovalParams: [String: [String: Any]] = [:]

    func start(prompt: String,
               attachments: [ImageAttachment],
               session: Session,
               run: RunConfig,
               project: Project) throws -> AsyncThrowingStream<AgentEvent, Error> {
        guard !project.location.isSSH else {
            throw AdapterError.unsupportedRemoteAttachments("Codex app-server")
        }

        lock.lock()
        self.prompt = prompt
        self.attachments = attachments
        self.sessionSnapshot = session
        self.runSnapshot = run
        self.projectSnapshot = project
        self.activeThreadId = nil
        self.activeTurnId = nil
        self.pendingApprovalMethods = [:]
        self.pendingApprovalRequestIds = [:]
        self.pendingApprovalParams = [:]
        lock.unlock()

        var args = run.args
        args.append(contentsOf: ["app-server", "--listen", "stdio://"])

        var env = ProcessInfo.processInfo.environment
        let extras = ["\(NSHomeDirectory())/.local/bin",
                      "/opt/homebrew/bin", "/usr/local/bin"]
        let existing = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (extras + [existing]).joined(separator: ":")
        for (k, v) in run.env { env[k] = v }

        let proc = Process()
        let executable = try resolveCommand(run.command, vendorDefault: "codex")
        let projectPath = (project.location.pathString as NSString).expandingTildeInPath
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        proc.currentDirectoryURL = URL(fileURLWithPath: projectPath)
        proc.environment = env

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        lock.lock()
        process = proc
        stdinHandle = stdin.fileHandleForWriting
        lock.unlock()

        return AsyncThrowingStream { continuation in
            let lines = JSONLineObjectParser()
            let appParser = CodexAppServerEventParser()
            let stdoutHandle = stdout.fileHandleForReading
            let stderrHandle = stderr.fileHandleForReading
            let stderrLock = NSLock()
            var stderrTail = ""

            stdoutHandle.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty { return }
                for object in lines.feed(data) {
                    guard let self else { continue }
                    for event in self.handleServerObject(object, parser: appParser) {
                        NSLog("[helm.codex.app-server] event: %@", String(describing: event).prefix(180) as CVarArg)
                        continuation.yield(event)
                    }
                }
            }
            stderrHandle.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { return }
                guard let chunk = String(data: data, encoding: .utf8) else { return }
                NSLog("[helm.codex.app-server] stderr: %@", chunk.prefix(2048) as CVarArg)
                stderrLock.lock()
                stderrTail.append(chunk)
                if stderrTail.count > 4096 {
                    stderrTail = String(stderrTail.suffix(4096))
                }
                stderrLock.unlock()
            }
            proc.terminationHandler = { [weak self] p in
                stdoutHandle.readabilityHandler = nil
                stderrHandle.readabilityHandler = nil
                NSLog("[helm.codex.app-server] exit status=%d", p.terminationStatus)
                for object in lines.flush() {
                    guard let self else { continue }
                    for event in self.handleServerObject(object, parser: appParser) {
                        continuation.yield(event)
                    }
                }
                if p.terminationStatus != 0 {
                    stderrLock.lock()
                    let tail = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
                    stderrLock.unlock()
                    let suffix = tail.isEmpty ? "" : ": \(tail)"
                    continuation.yield(.error("codex app-server exited \(p.terminationStatus)\(suffix)"))
                }
                continuation.finish()
            }

            continuation.onTermination = { [weak self] _ in
                self?.cancel()
            }

            do {
                try proc.run()
                initializeRequestId = sendRequest(
                    method: "initialize",
                    params: [
                        "clientInfo": [
                            "name": "helm",
                            "title": "Helm",
                            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",
                        ],
                        "capabilities": [
                            "experimentalApi": true,
                        ],
                    ]
                )
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    func cancel() {
        let threadId: String?
        let turnId: String?
        lock.lock()
        threadId = activeThreadId
        turnId = activeTurnId
        lock.unlock()

        if let threadId, let turnId {
            _ = sendRequest(method: "turn/interrupt",
                            params: ["threadId": threadId, "turnId": turnId])
        }

        let p: Process?
        let stdin: FileHandle?
        lock.lock()
        p = process
        stdin = stdinHandle
        process = nil
        stdinHandle = nil
        activeTurnId = nil
        lock.unlock()

        guard let p else {
            try? stdin?.close()
            return
        }
        ProcessTreeTerminator.terminate(p, closing: stdin)
    }

    func respondToApproval(id: String, decision: AgentApprovalDecision) {
        lock.lock()
        let method = pendingApprovalMethods.removeValue(forKey: id)
        let requestId = pendingApprovalRequestIds.removeValue(forKey: id)
        let params = pendingApprovalParams.removeValue(forKey: id)
        lock.unlock()

        guard let method, let requestId else { return }
        sendResponse(id: requestId,
                     result: approvalResult(method: method,
                                            params: params,
                                            decision: decision))
    }

    private func handleServerObject(_ object: [String: Any],
                                    parser: CodexAppServerEventParser) -> [AgentEvent] {
        if object["result"] != nil || object["error"] != nil {
            return handleResponse(object)
        }

        if let requestId = object["id"],
           let method = object["method"] as? String {
            return handleServerRequest(id: requestId,
                                       method: method,
                                       params: object["params"] as? [String: Any])
        }

        guard let method = object["method"] as? String else { return [] }
        let params = object["params"] as? [String: Any]
        switch method {
        case "thread/started":
            if let thread = params?["thread"] as? [String: Any],
               let id = thread["id"] as? String {
                return [.sessionId(id)]
            }
            return []

        case "item/started":
            return parser.parseItemStarted(params?["item"] as? [String: Any])

        case "item/completed":
            return parser.parseItemCompleted(params?["item"] as? [String: Any])

        case "item/agentMessage/delta":
            if let delta = params?["delta"] as? String, !delta.isEmpty {
                return [.assistantTextDelta(delta)]
            }
            return []

        case "turn/completed":
            lock.lock()
            activeTurnId = nil
            lock.unlock()
            return parser.parseTurnCompleted(params?["turn"] as? [String: Any])

        case "serverRequest/resolved":
            if let id = params?["requestId"] {
                return [.approvalResolved(id: requestKey(id))]
            }
            return []

        case "mcpServer/startupStatus/updated":
            guard params?["name"] as? String == "computer-use",
                  params?["status"] as? String == "failed"
            else { return [] }
            let detail = params?["error"] as? String
            return [.error("Computer Use MCP failed to start\(detail.map { ": \($0)" } ?? ".")")]

        default:
            return []
        }
    }

    private func handleResponse(_ object: [String: Any]) -> [AgentEvent] {
        guard let rawId = object["id"] else { return [] }
        let key = requestKey(rawId)
        if let error = object["error"] as? [String: Any] {
            return [.error(error["message"] as? String ?? "Codex app-server request failed.")]
        }

        if key == initializeRequestId.map(String.init) {
            sendNotification(method: "initialized")
            openThread()
            return []
        }

        if key == threadOpenRequestId.map(String.init) {
            guard let result = object["result"] as? [String: Any],
                  let threadId = threadId(from: result)
            else { return [.error("Codex app-server did not return a thread id.")] }
            lock.lock()
            activeThreadId = threadId
            lock.unlock()
            startTurn(threadId: threadId)
            return [.sessionId(threadId)]
        }

        if key == turnStartRequestId.map(String.init),
           let result = object["result"] as? [String: Any],
           let turn = result["turn"] as? [String: Any],
           let turnId = turn["id"] as? String {
            lock.lock()
            activeTurnId = turnId
            lock.unlock()
        }
        return []
    }

    private func handleServerRequest(id: Any,
                                     method: String,
                                     params: [String: Any]?) -> [AgentEvent] {
        let key = requestKey(id)
        if method == "item/tool/call" {
            sendResponse(id: id, result: unsupportedDynamicToolResponse(params))
            return parserEventsForUnsupportedDynamicTool(params)
        }
        guard let request = approvalRequest(id: key, method: method, params: params) else {
            sendErrorResponse(id: id,
                              code: -32601,
                              message: "Helm does not support app-server request method '\(method)'.")
            return []
        }
        if shouldAutoApprove(method: method, params: params) {
            sendResponse(id: id,
                         result: approvalResult(method: method,
                                                params: params,
                                                decision: .acceptForSession))
            return [.approvalResolved(id: key)]
        }
        lock.lock()
        pendingApprovalMethods[key] = method
        pendingApprovalRequestIds[key] = id
        pendingApprovalParams[key] = params
        lock.unlock()
        return [.approvalRequest(request)]
    }

    private func shouldAutoApprove(method: String, params: [String: Any]?) -> Bool {
        guard sessionSnapshot?.codexApprovalMode == .never else { return false }
        switch method {
        case "item/commandExecution/requestApproval",
             "item/fileChange/requestApproval",
             "execCommandApproval",
             "applyPatchApproval",
             "item/permissions/requestApproval":
            return true
        case "mcpServer/elicitation/request":
            return mcpServerName(from: params) == "computer-use"
        default:
            return false
        }
    }

    private func approvalResult(method: String,
                                params: [String: Any]?,
                                decision: AgentApprovalDecision) -> Any {
        switch method {
        case "item/commandExecution/requestApproval":
            return ["decision": decision.commandExecutionValue]
        case "item/fileChange/requestApproval":
            return ["decision": decision.commandExecutionValue]
        case "execCommandApproval", "applyPatchApproval":
            return ["decision": decision.legacyApprovalValue]
        case "mcpServer/elicitation/request":
            switch decision {
            case .accept, .acceptForSession:
                return [
                    "action": decision.elicitationValue,
                    "content": [String: Any](),
                ]
            case .decline, .cancel:
                return ["action": decision.elicitationValue]
            }
        case "item/permissions/requestApproval":
            let requested = params?["permissions"] as? [String: Any] ?? [:]
            switch decision {
            case .accept:
                return ["permissions": requested, "scope": "turn"]
            case .acceptForSession:
                return ["permissions": requested, "scope": "session"]
            case .decline, .cancel:
                return ["permissions": [:], "scope": "turn"]
            }
        case "item/tool/requestUserInput":
            return ["answers": [:]]
        default:
            return ["decision": decision.commandExecutionValue]
        }
    }

    private func unsupportedDynamicToolResponse(_ params: [String: Any]?) -> [String: Any] {
        let tool = params?["tool"] as? String ?? "tool"
        return [
            "contentItems": [[
                "type": "inputText",
                "text": "Helm cannot run dynamic app-server tool '\(tool)'.",
            ]],
            "success": false,
        ]
    }

    private func parserEventsForUnsupportedDynamicTool(_ params: [String: Any]?) -> [AgentEvent] {
        let callId = params?["callId"] as? String ?? UUID().uuidString
        let tool = params?["tool"] as? String ?? "tool"
        let namespace = params?["namespace"] as? String
        return [
            .toolCallStart(
                id: callId,
                name: CodexToolPresentation.name(rawName: tool, namespace: namespace),
                input: CodexToolPresentation.argument(rawName: tool,
                                                      namespace: namespace,
                                                      arguments: params?["arguments"])
            ),
            .toolResult(
                id: callId,
                output: "Helm cannot run this app-server dynamic tool.",
                isError: true
            ),
        ]
    }

    private func openThread() {
        guard let sessionSnapshot,
              let runSnapshot,
              let projectSnapshot
        else { return }

        var params = threadParams(session: sessionSnapshot,
                                  run: runSnapshot,
                                  project: projectSnapshot)
        if let resume = sessionSnapshot.vendorSessionId, !resume.isEmpty {
            params["threadId"] = resume
            params["excludeTurns"] = true
            threadOpenRequestId = sendRequest(method: "thread/resume", params: params)
        } else {
            params["sessionStartSource"] = "clear"
            threadOpenRequestId = sendRequest(method: "thread/start", params: params)
        }
    }

    private func startTurn(threadId: String) {
        guard let sessionSnapshot,
              let runSnapshot,
              let projectSnapshot
        else { return }

        var input: [[String: Any]] = []
        if !prompt.isEmpty {
            input.append([
                "type": "text",
                "text": prompt,
            ])
        }
        for attachment in attachments {
            input.append([
                "type": "localImage",
                "path": attachment.fileURL.path,
            ])
        }

        var params: [String: Any] = [
            "threadId": threadId,
            "input": input,
            "cwd": projectSnapshot.location.pathString,
            "approvalPolicy": sessionSnapshot.codexApprovalMode.rawValue,
            "effort": sessionSnapshot.codexEffort.rawValue,
            "model": runSnapshot.providerModelId,
        ]
        if input.isEmpty {
            params["input"] = [["type": "text", "text": ""]]
        }
        turnStartRequestId = sendRequest(method: "turn/start", params: params)
    }

    private func threadParams(session: Session,
                              run: RunConfig,
                              project: Project) -> [String: Any] {
        let params: [String: Any] = [
            "cwd": project.location.pathString,
            "approvalPolicy": session.codexApprovalMode.rawValue,
            "sandbox": session.codexSandboxMode.rawValue,
            "model": run.providerModelId,
        ]
        return params
    }

    private func approvalRequest(id: String,
                                 method: String,
                                 params: [String: Any]?) -> AgentApprovalRequest? {
        switch method {
        case "item/commandExecution/requestApproval", "execCommandApproval":
            let command = params?["command"] as? String
            let reason = params?["reason"] as? String
            let cwd = params?["cwd"] as? String
            let detail = [command, cwd.map { "cwd: \($0)" }]
                .compactMap { $0 }
                .joined(separator: "\n")
            return AgentApprovalRequest(
                id: id,
                kind: .command,
                title: "Approve Command",
                message: reason ?? "Codex wants to run a command.",
                detail: detail.isEmpty ? nil : detail,
                allowsSessionApproval: true
            )

        case "item/fileChange/requestApproval", "applyPatchApproval":
            return AgentApprovalRequest(
                id: id,
                kind: .fileChange,
                title: "Approve File Changes",
                message: "Codex wants to apply proposed file changes.",
                detail: serialize(params),
                allowsSessionApproval: true
            )

        case "mcpServer/elicitation/request":
            let server = mcpServerName(from: params)
            let message = params?["message"] as? String ?? "An MCP server needs your approval."
            let url = params?["url"] as? String
            let detail = [server.map { "server: \($0)" }, url]
                .compactMap { $0 }
                .joined(separator: "\n")
            return AgentApprovalRequest(
                id: id,
                kind: .mcpElicitation,
                title: server == "computer-use" ? "Approve App Request" : "Approve MCP Request",
                message: message,
                detail: detail.isEmpty ? nil : detail,
                allowsSessionApproval: false
            )

        case "item/permissions/requestApproval":
            return AgentApprovalRequest(
                id: id,
                kind: .permissions,
                title: "Approve Permissions",
                message: params?["reason"] as? String ?? "Codex wants additional permissions.",
                detail: serialize(params),
                allowsSessionApproval: false
            )

        case "item/tool/requestUserInput":
            return AgentApprovalRequest(
                id: id,
                kind: .userInput,
                title: "Input Requested",
                message: "Codex requested more input for a tool call.",
                detail: serialize(params),
                allowsSessionApproval: false
            )

        default:
            return nil
        }
    }

    private func mcpServerName(from params: [String: Any]?) -> String? {
        params?["serverName"] as? String
            ?? params?["server"] as? String
            ?? params?["name"] as? String
    }

    @discardableResult
    private func sendRequest(method: String, params: Any? = nil) -> Int {
        lock.lock()
        let id = nextRequestId
        nextRequestId += 1
        var object: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
        ]
        if let params {
            object["params"] = params
        }
        writeJSONObjectLocked(object)
        lock.unlock()
        return id
    }

    private func sendNotification(method: String, params: Any? = nil) {
        lock.lock()
        var object: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
        ]
        if let params {
            object["params"] = params
        }
        writeJSONObjectLocked(object)
        lock.unlock()
    }

    private func sendResponse(id: Any, result: Any) {
        lock.lock()
        writeJSONObjectLocked([
            "jsonrpc": "2.0",
            "id": id,
            "result": result,
        ])
        lock.unlock()
    }

    private func sendErrorResponse(id: Any, code: Int, message: String) {
        lock.lock()
        writeJSONObjectLocked([
            "jsonrpc": "2.0",
            "id": id,
            "error": [
                "code": code,
                "message": message,
            ],
        ])
        lock.unlock()
    }

    private func writeJSONObjectLocked(_ object: [String: Any]) {
        guard let stdinHandle,
              JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object)
        else { return }
        var payload = data
        payload.append(0x0A)
        try? stdinHandle.write(contentsOf: payload)
    }

    private func threadId(from result: [String: Any]) -> String? {
        if let thread = result["thread"] as? [String: Any],
           let id = thread["id"] as? String {
            return id
        }
        return result["threadId"] as? String ?? result["id"] as? String
    }

    private func requestKey(_ value: Any) -> String {
        if let int = value as? Int { return String(int) }
        if let number = value as? NSNumber { return number.stringValue }
        return value as? String ?? String(describing: value)
    }

    private func serialize(_ value: Any?) -> String? {
        guard let value,
              JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty
        else { return nil }
        return text
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
        let type = item["type"] as? String ?? ""
        switch type {
        case "command_execution":
            let id = item["id"] as? String ?? UUID().uuidString
            startedToolIds.insert(id)
            return [.toolCallStart(id: id, name: "Shell", input: item["command"] as? String ?? "")]

        case "mcp_tool_call":
            let id = callId(from: item)
            startedToolIds.insert(id)
            let rawName = item["tool"] as? String ?? "tool"
            let server = item["server"] as? String
            return [.toolCallStart(
                id: id,
                name: CodexToolPresentation.name(rawName: rawName, namespace: nil, server: server),
                input: CodexToolPresentation.argument(rawName: rawName,
                                                      namespace: nil,
                                                      server: server,
                                                      arguments: item["arguments"])
            )]

        default:
            return []
        }
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

        case "function_call":
            let id = callId(from: item)
            guard !startedToolIds.contains(id) else { return [] }
            startedToolIds.insert(id)
            let rawName = item["name"] as? String ?? "tool"
            let namespace = item["namespace"] as? String
            return [.toolCallStart(
                id: id,
                name: CodexToolPresentation.name(rawName: rawName, namespace: namespace),
                input: CodexToolPresentation.argument(rawName: rawName,
                                                      namespace: namespace,
                                                      arguments: item["arguments"])
            )]

        case "function_call_output":
            let id = callId(from: item)
            var out: [AgentEvent] = []
            if !startedToolIds.contains(id) {
                startedToolIds.insert(id)
                out.append(.toolCallStart(id: id, name: "Tool", input: ""))
            }
            let status = item["status"] as? String ?? ""
            let isError = (item["is_error"] as? Bool) ?? (status == "failed")
            out.append(.toolResult(id: id,
                                   output: item["output"] as? String ?? "",
                                   isError: isError))
            return out

        case "mcp_tool_call":
            let id = callId(from: item)
            let rawName = item["tool"] as? String ?? "tool"
            let server = item["server"] as? String
            var out: [AgentEvent] = []
            if !startedToolIds.contains(id) {
                startedToolIds.insert(id)
                out.append(.toolCallStart(
                    id: id,
                    name: CodexToolPresentation.name(rawName: rawName, namespace: nil, server: server),
                    input: CodexToolPresentation.argument(rawName: rawName,
                                                          namespace: nil,
                                                          server: server,
                                                          arguments: item["arguments"])
                ))
            }
            let status = item["status"] as? String ?? ""
            let isError = status == "failed" || jsonErrorIsPresent(item["error"])
            out.append(.toolResult(id: id,
                                   output: CodexToolPresentation.resultOutput(result: item["result"],
                                                                              error: item["error"]),
                                   isError: isError))
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

    private func callId(from item: [String: Any]) -> String {
        item["call_id"] as? String
            ?? item["id"] as? String
            ?? UUID().uuidString
    }
}

private final class JSONLineObjectParser {
    private var pending = ""

    func feed(_ data: Data) -> [[String: Any]] {
        guard let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty else {
            return []
        }
        pending.append(chunk)
        var objects: [[String: Any]] = []
        while let nl = pending.firstIndex(of: "\n") {
            let line = String(pending[..<nl])
            pending.removeSubrange(...nl)
            if let object = parse(line) {
                objects.append(object)
            }
        }
        return objects
    }

    func flush() -> [[String: Any]] {
        let line = pending
        pending = ""
        guard let object = parse(line) else { return [] }
        return [object]
    }

    private func parse(_ line: String) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8)
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

private final class CodexAppServerEventParser {
    private var startedToolIds: Set<String> = []
    private var finalText = ""

    func parseItemStarted(_ item: [String: Any]?) -> [AgentEvent] {
        guard let item else { return [] }
        let type = item["type"] as? String ?? ""
        switch type {
        case "commandExecution":
            let id = item["id"] as? String ?? UUID().uuidString
            startedToolIds.insert(id)
            return [.toolCallStart(id: id,
                                   name: "Shell",
                                   input: item["command"] as? String ?? "")]

        case "mcpToolCall", "mcp_tool_call":
            let id = callId(from: item)
            startedToolIds.insert(id)
            let descriptor = mcpDescriptor(from: item)
            return [.toolCallStart(
                id: id,
                name: CodexToolPresentation.name(rawName: descriptor.tool,
                                                 namespace: nil,
                                                 server: descriptor.server),
                input: CodexToolPresentation.argument(rawName: descriptor.tool,
                                                      namespace: nil,
                                                      server: descriptor.server,
                                                      arguments: descriptor.arguments)
            )]

        default:
            return []
        }
    }

    func parseItemCompleted(_ item: [String: Any]?) -> [AgentEvent] {
        guard let item else { return [] }
        let type = item["type"] as? String ?? ""
        switch type {
        case "commandExecution":
            let id = item["id"] as? String ?? UUID().uuidString
            var out: [AgentEvent] = []
            if !startedToolIds.contains(id) {
                startedToolIds.insert(id)
                out.append(.toolCallStart(id: id,
                                          name: "Shell",
                                          input: item["command"] as? String ?? ""))
            }
            let output = item["aggregatedOutput"] as? String
                ?? item["aggregated_output"] as? String
                ?? ""
            let exit = item["exitCode"] as? Int ?? item["exit_code"] as? Int
            let status = item["status"] as? String ?? ""
            let isError = (exit ?? 0) != 0 || status == "failed" || status == "declined"
            out.append(.toolResult(id: id, output: output, isError: isError))
            return out

        case "mcpToolCall", "mcp_tool_call":
            let id = callId(from: item)
            let descriptor = mcpDescriptor(from: item)
            var out: [AgentEvent] = []
            if !startedToolIds.contains(id) {
                startedToolIds.insert(id)
                out.append(.toolCallStart(
                    id: id,
                    name: CodexToolPresentation.name(rawName: descriptor.tool,
                                                     namespace: nil,
                                                     server: descriptor.server),
                    input: CodexToolPresentation.argument(rawName: descriptor.tool,
                                                          namespace: nil,
                                                          server: descriptor.server,
                                                          arguments: descriptor.arguments)
                ))
            }
            let status = item["status"] as? String ?? ""
            let isError = status == "failed"
                || status == "declined"
                || (item["isError"] as? Bool == true)
                || jsonErrorIsPresent(item["error"])
            out.append(.toolResult(
                id: id,
                output: CodexToolPresentation.resultOutput(result: descriptor.result,
                                                           error: item["error"]),
                isError: isError
            ))
            return out

        case "agentMessage":
            finalText = item["text"] as? String ?? finalText
            return [.messageStop]

        default:
            return []
        }
    }

    func parseTurnCompleted(_ turn: [String: Any]?) -> [AgentEvent] {
        let status = turn?["status"] as? String ?? "completed"
        let error = turn?["error"]
        let isError = status != "completed" || jsonErrorIsPresent(error)
        let text = isError
            ? (CodexToolPresentation.resultOutput(result: nil, error: error).isEmpty
                ? "Codex turn failed."
                : CodexToolPresentation.resultOutput(result: nil, error: error))
            : finalText
        return [.messageStop, .finalResult(text: text, isError: isError)]
    }

    private func callId(from item: [String: Any]) -> String {
        item["callId"] as? String
            ?? item["call_id"] as? String
            ?? item["id"] as? String
            ?? UUID().uuidString
    }

    private func mcpDescriptor(from item: [String: Any]) -> (server: String?, tool: String, arguments: Any?, result: Any?) {
        let invocation = item["invocation"] as? [String: Any]
        let server = item["server"] as? String
            ?? item["serverName"] as? String
            ?? invocation?["server"] as? String
            ?? invocation?["serverName"] as? String
        let tool = item["tool"] as? String
            ?? item["toolName"] as? String
            ?? invocation?["tool"] as? String
            ?? invocation?["toolName"] as? String
            ?? "tool"
        let arguments = item["arguments"] ?? invocation?["arguments"]
        let result = item["result"]
            ?? item["output"]
            ?? item["callResult"]
            ?? item["toolResult"]
        return (server, tool, arguments, result)
    }
}

enum CodexToolPresentation {
    static func name(rawName: String, namespace: String?, server: String? = nil) -> String {
        if isComputerUse(rawName: rawName, namespace: namespace, server: server) {
            return "Computer Use"
        }
        switch rawName {
        case "exec_command": return "Shell"
        case "apply_patch": return "Apply Patch"
        default: return rawName
        }
    }

    static func argument(rawName: String, namespace: String?, server: String? = nil, arguments: Any?) -> String {
        let serialized = serialize(arguments)
        if rawName == "exec_command",
           let data = serialized.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cmd = obj["cmd"] as? String,
           !cmd.isEmpty {
            return "/bin/bash -lc \(cmd)"
        }
        if isComputerUse(rawName: rawName, namespace: namespace, server: server) {
            let tool = computerUseToolName(from: rawName) ?? rawName
            return serialized.isEmpty ? tool : "\(tool) \(serialized)"
        }
        return serialized
    }

    static func resultOutput(result: Any?, error: Any?) -> String {
        if let errorText = errorDescription(error) {
            return errorText
        }
        guard let result else { return "" }
        guard let object = result as? [String: Any] else {
            return serialize(result)
        }
        if let content = object["content"] as? [[String: Any]] {
            let text = content.compactMap { part -> String? in
                if let value = part["text"] as? String {
                    return value
                }
                if let type = part["type"] as? String {
                    return "[\(type)]"
                }
                return nil
            }.joined(separator: "\n")
            if !text.isEmpty {
                return text
            }
        }
        if let structured = object["structuredContent"] ?? object["structured_content"],
           !(structured is NSNull) {
            return serialize(structured)
        }
        return serialize(result)
    }

    private static let computerUseTools: Set<String> = [
        "list_apps",
        "get_app_state",
        "click",
        "perform_secondary_action",
        "set_value",
        "select_text",
        "scroll",
        "drag",
        "press_key",
        "type_text",
    ]

    private static func isComputerUse(rawName: String, namespace: String?, server: String?) -> Bool {
        if let namespace,
           namespace == "mcp__computer_use__" || namespace == "mcp__\(CodexComputerUseMCP.claudeServerName)__" {
            return true
        }
        if let server,
           server == "computer-use" || server == CodexComputerUseMCP.claudeServerName {
            return true
        }
        if computerUseTools.contains(rawName) {
            return true
        }
        return computerUseToolName(from: rawName).map { computerUseTools.contains($0) } ?? false
    }

    private static func computerUseToolName(from rawName: String) -> String? {
        let claudePrefix = "mcp__\(CodexComputerUseMCP.claudeServerName)__"
        if rawName.hasPrefix(claudePrefix) {
            return String(rawName.dropFirst(claudePrefix.count))
        }
        let codexPrefix = "mcp__computer_use__"
        if rawName.hasPrefix(codexPrefix) {
            return String(rawName.dropFirst(codexPrefix.count))
        }
        return nil
    }

    private static func errorDescription(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string.isEmpty ? nil : string
        case let object as [String: Any]:
            if let message = object["message"] as? String, !message.isEmpty {
                return message
            }
            if let error = object["error"] as? String, !error.isEmpty {
                return error
            }
            let serialized = serialize(object)
            return serialized.isEmpty ? nil : serialized
        case is NSNull:
            return nil
        case .some(let object):
            let serialized = serialize(object)
            return serialized.isEmpty ? nil : serialized
        case nil:
            return nil
        }
    }

    private static func serialize(_ value: Any?) -> String {
        switch value {
        case let string as String:
            return string
        case let object?:
            guard JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                  let text = String(data: data, encoding: .utf8)
            else { return "" }
            return text
        case nil:
            return ""
        }
    }
}

private extension AgentApprovalDecision {
    var commandExecutionValue: String {
        switch self {
        case .accept: return "accept"
        case .acceptForSession: return "acceptForSession"
        case .decline: return "decline"
        case .cancel: return "cancel"
        }
    }

    var legacyApprovalValue: String {
        switch self {
        case .accept: return "approved"
        case .acceptForSession: return "approved_for_session"
        case .decline: return "denied"
        case .cancel: return "abort"
        }
    }

    var elicitationValue: String {
        switch self {
        case .accept, .acceptForSession: return "accept"
        case .decline: return "decline"
        case .cancel: return "cancel"
        }
    }
}
