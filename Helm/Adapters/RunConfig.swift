import Foundation

/// Resolved bag of env / args / command for one agent invocation. Adapters
/// take this; they don't reach back into Profile / Provider directly.
struct RunConfig {
    /// Absolute path or bare command to spawn.
    var command: String
    /// Extra CLI args (vendor-specific).
    var args: [String]
    /// Env layered on top of the inherited environment.
    var env: [String: String]
    /// Helpful description for the picker / chat header (e.g.
    /// "Claude Sonnet 4.6 · es2-relay").
    var headlineModel: String
    /// Provider model id sent over the wire (e.g. "model_hub/es2_orange_o47").
    var providerModelId: String
}

enum ResolverError: LocalizedError {
    case providerMissing(UUID)
    case modelMissing(UUID)
    case profileVendorMismatch
    case computerUseUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .providerMissing(let id):    return "Profile points to a provider that no longer exists (\(id))."
        case .modelMissing(let id):       return "Profile points to a model that no longer exists (\(id))."
        case .profileVendorMismatch:      return "Profile vendor doesn't match its provider."
        case .computerUseUnavailable(let reason):
            return "Computer Use MCP is enabled but unavailable: \(reason)"
        }
    }
}

/// Vendor-aware resolver. Pure function over (Profile, Provider, Model index).
enum RunConfigResolver {
    static func resolve(profile: Profile,
                        session: Session,
                        isRemoteProject: Bool = false,
                        providers: [Provider],
                        models: [Model]) throws -> RunConfig {
        guard let provider = providers.first(where: { $0.id == profile.providerId }) else {
            throw ResolverError.providerMissing(profile.providerId)
        }
        guard provider.vendor == profile.vendor else {
            throw ResolverError.profileVendorMismatch
        }
        guard let primary = models.first(where: { $0.id == profile.primaryModelId }) else {
            throw ResolverError.modelMissing(profile.primaryModelId)
        }

        switch profile.vendor {
        case .claude:
            return resolveClaude(profile: profile, session: session, provider: provider,
                                 primary: primary, models: models,
                                 isRemoteProject: isRemoteProject)
        case .codex:
            return try resolveCodex(profile: profile, session: session, provider: provider,
                                    primary: primary, models: models,
                                    isRemoteProject: isRemoteProject)
        }
    }

    // MARK: - Claude

    private static func resolveClaude(profile: Profile,
                                      session: Session,
                                      provider: Provider,
                                      primary: Model,
                                      models: [Model],
                                      isRemoteProject: Bool) -> RunConfig {
        var env: [String: String] = [:]
        if !provider.baseURL.isEmpty {
            env["ANTHROPIC_BASE_URL"] = provider.baseURL
        }
        if !provider.authToken.isEmpty {
            env["ANTHROPIC_AUTH_TOKEN"] = provider.authToken
        }
        env["ANTHROPIC_MODEL"] = primary.providerModelId

        let opus   = lookupModel(profile.opusModelId,   models: models) ?? primary
        let sonnet = lookupModel(profile.sonnetModelId, models: models) ?? primary
        let haiku  = lookupModel(profile.haikuModelId,  models: models) ?? primary
        env["ANTHROPIC_DEFAULT_OPUS_MODEL"]   = opus.providerModelId
        env["ANTHROPIC_DEFAULT_SONNET_MODEL"] = sonnet.providerModelId
        env["ANTHROPIC_DEFAULT_HAIKU_MODEL"]  = haiku.providerModelId

        if let sub = lookupModel(profile.subagentModelId, models: models) {
            env["CLAUDE_CODE_SUBAGENT_MODEL"] = sub.providerModelId
        } else {
            env["CLAUDE_CODE_SUBAGENT_MODEL"] = primary.providerModelId
        }
        if let win = profile.autoCompactWindow {
            env["CLAUDE_CODE_AUTO_COMPACT_WINDOW"] = String(win)
        }
        if !isRemoteProject, let root = profile.configRoot, !root.isEmpty {
            env["CLAUDE_CONFIG_DIR"] = (root as NSString).expandingTildeInPath
        }
        for (k, v) in provider.extraEnv { env[k] = v }

        // CLI args: --model is also passed for clarity; CLI honors env first
        // but the explicit flag makes the chosen model visible in `ps`.
        var args = ["--model", primary.providerModelId]
        args.append(contentsOf: ["--permission-mode",
                                 session.claudePermissionMode.rawValue])
        args.append(contentsOf: ["--effort", session.claudeEffort.rawValue])
        if !isRemoteProject, let root = profile.configRoot, !root.isEmpty {
            args.append(contentsOf: ["--setting-sources", "user,project,local"])
        }

        let head = primary.label
        return RunConfig(
            command: profile.resolvedCommand,
            args: args,
            env: env,
            headlineModel: head + " · " + profile.name,
            providerModelId: primary.providerModelId
        )
    }

    // MARK: - Codex

    private static func resolveCodex(profile: Profile,
                                     session: Session,
                                     provider: Provider,
                                     primary: Model,
                                     models: [Model],
                                     isRemoteProject: Bool) throws -> RunConfig {
        var env: [String: String] = [:]
        if !isRemoteProject, let root = profile.configRoot, !root.isEmpty {
            env["CODEX_HOME"] = (root as NSString).expandingTildeInPath
        }

        var args: [String] = []

        if !isRemoteProject, let delegate = profile.delegateVendorProfile, !delegate.isEmpty {
            args.append(contentsOf: ["--profile", delegate])
        } else {
            // Inline -c overrides. Provider gets a synthesized name; safe
            // because we re-emit it on every spawn.
            let providerKey = sanitizeKey("helm_" + provider.name)
            args.append(contentsOf: ["-c", "model_provider=\(providerKey)"])
            args.append(contentsOf: ["-c", "model_providers.\(providerKey).name=\"\(provider.name)\""])
            if !provider.baseURL.isEmpty {
                args.append(contentsOf: ["-c", "model_providers.\(providerKey).base_url=\"\(provider.baseURL)\""])
            }
            args.append(contentsOf: ["-c", "model_providers.\(providerKey).wire_api=\"\(provider.wireAPI.rawValue)\""])
            args.append(contentsOf: ["-c", "model_providers.\(providerKey).requires_openai_auth=\(provider.requiresOpenAIAuth)"])
            if !provider.httpHeaders.isEmpty {
                args.append(contentsOf: [
                    "-c",
                    "model_providers.\(providerKey).http_headers=\(tomlInlineStringMap(provider.httpHeaders))",
                ])
            }
            args.append(contentsOf: ["-c", "model=\"\(primary.providerModelId)\""])
            args.append(contentsOf: ["-c", "model_reasoning_effort=\"\(session.codexEffort.rawValue)\""])
            if let s = profile.serviceTier {
                args.append(contentsOf: ["-c", "service_tier=\"\(s.rawValue)\""])
            }
            args.append(contentsOf: ["-c", "sandbox_mode=\"\(session.codexSandboxMode.rawValue)\""])
            args.append(contentsOf: ["-c", "approval_policy=\"\(session.codexApprovalMode.rawValue)\""])
        }

        if !provider.authToken.isEmpty {
            // Codex reads OPENAI_API_KEY (and similar) from env when
            // requires_openai_auth is set; route the provider's token there.
            env["OPENAI_API_KEY"] = provider.authToken
        }

        args.append(contentsOf: try CodexComputerUseMCP.configArgs(isRemoteProject: isRemoteProject))

        let head = primary.label
        return RunConfig(
            command: profile.resolvedCommand,
            args: args,
            env: env,
            headlineModel: head + " · " + profile.name,
            providerModelId: primary.providerModelId
        )
    }

    // MARK: -

    private static func lookupModel(_ id: UUID?, models: [Model]) -> Model? {
        guard let id else { return nil }
        return models.first { $0.id == id }
    }

    /// `-c key=value` keys must be plain TOML identifiers.
    private static func sanitizeKey(_ s: String) -> String {
        var out = ""
        for ch in s {
            if ch.isLetter || ch.isNumber || ch == "_" {
                out.append(ch)
            } else {
                out.append("_")
            }
        }
        return out.isEmpty ? "helm" : out
    }

    private static func tomlInlineStringMap(_ values: [String: String]) -> String {
        let pairs = values
            .sorted { $0.key < $1.key }
            .map { "\(tomlStringLiteral($0.key)) = \(tomlStringLiteral($0.value))" }
        return "{ \(pairs.joined(separator: ", ")) }"
    }

    private static func tomlStringLiteral(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\":
                out += "\\\\"
            case "\"":
                out += "\\\""
            case "\n":
                out += "\\n"
            case "\r":
                out += "\\r"
            case "\t":
                out += "\\t"
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
        return out
    }
}

struct CodexComputerUseDiagnostic: Equatable {
    enum State: Equatable {
        case disabled
        case unsupportedRemote
        case missing
        case found
        case checking
        case ready
        case failed
    }

    var state: State
    var title: String
    var detail: String
    var command: String?
    var cwd: String?

    var isReady: Bool {
        state == .ready
    }
}

/// Reuses the Codex App-bundled Computer Use MCP from Helm-launched local Codex
/// runs. This keeps Helm out of the macOS Accessibility / ScreenCaptureKit
/// implementation and lets Codex own the native service.
enum CodexComputerUseMCP {
    private struct Server {
        var command: String
        var cwd: String
    }

    private static let validationLock = NSLock()
    private static var validatedServerKeys: Set<String> = []
    private static var failedServerKeys: [String: String] = [:]

    static func configArgs(isRemoteProject: Bool) throws -> [String] {
        guard !isRemoteProject else { return [] }
        guard ProcessInfo.processInfo.environment["HELM_DISABLE_CODEX_COMPUTER_USE_MCP"] != "1" else { return [] }

        let mode = CodexComputerUseMode.stored()
        guard mode != .disabled else { return [] }
        guard let server = discoverServer() else {
            if mode == .enabled {
                throw ResolverError.computerUseUnavailable(missingDetail)
            }
            return []
        }
        if let failure = cachedFailure(for: server) {
            if mode == .enabled {
                throw ResolverError.computerUseUnavailable(failure)
            }
            return []
        }

        return [
            "-c", "mcp_servers.computer-use.command=\(tomlStringLiteral(server.command))",
            "-c", "mcp_servers.computer-use.args=[\"mcp\"]",
            "-c", "mcp_servers.computer-use.cwd=\(tomlStringLiteral(server.cwd))",
        ]
    }

    static func diagnose(mode: CodexComputerUseMode = CodexComputerUseMode.stored(),
                         isRemoteProject: Bool = false,
                         refresh: Bool = false) -> CodexComputerUseDiagnostic {
        if isRemoteProject {
            return CodexComputerUseDiagnostic(
                state: .unsupportedRemote,
                title: "Unavailable for SSH",
                detail: "Computer Use is a local macOS capability. Helm skips it for SSH-backed sessions.",
                command: nil,
                cwd: nil
            )
        }
        if ProcessInfo.processInfo.environment["HELM_DISABLE_CODEX_COMPUTER_USE_MCP"] == "1" || mode == .disabled {
            return CodexComputerUseDiagnostic(
                state: .disabled,
                title: "Disabled",
                detail: "Helm will not attach Computer Use MCP to Codex sessions on this device.",
                command: nil,
                cwd: nil
            )
        }
        guard let server = discoverServer() else {
            return CodexComputerUseDiagnostic(
                state: .missing,
                title: "Not installed",
                detail: missingDetail,
                command: nil,
                cwd: nil
            )
        }
        if refresh {
            if let failure = startFailure(for: server, refresh: true) {
                return CodexComputerUseDiagnostic(
                    state: .failed,
                    title: "Cannot start",
                    detail: failure,
                    command: server.command,
                    cwd: server.cwd
                )
            }
            return readyDiagnostic(for: server)
        }

        let cacheState = cachedState(for: server)
        if cacheState.ready {
            return readyDiagnostic(for: server)
        }
        if let failure = cacheState.failure {
            return CodexComputerUseDiagnostic(
                state: .failed,
                title: "Cannot start",
                detail: failure,
                command: server.command,
                cwd: server.cwd
            )
        }

        return CodexComputerUseDiagnostic(
            state: .found,
            title: "Installed",
            detail: "Helm found Codex App's Computer Use MCP. Use Check to verify it can start and advertise Computer Use tools.",
            command: server.command,
            cwd: server.cwd
        )
    }

    private static func discoverServer() -> Server? {
        for root in pluginRoots() {
            if let server = serverFromMCPJSON(root: root) {
                return server
            }
        }
        return serverFromInstalledCopy()
    }

    private static func pluginRoots() -> [URL] {
        let base = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".codex/plugins/cache/openai-bundled/computer-use", isDirectory: true)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
    }

    private static func serverFromMCPJSON(root: URL) -> Server? {
        let jsonURL = root.appendingPathComponent(".mcp.json")
        guard let data = try? Data(contentsOf: jsonURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = object["mcpServers"] as? [String: Any],
              let computerUse = servers["computer-use"] as? [String: Any],
              let command = computerUse["command"] as? String
        else { return nil }

        let cwdValue = computerUse["cwd"] as? String ?? "."
        let commandURL = absoluteURL(command, relativeTo: root)
        let cwdURL = absoluteURL(cwdValue, relativeTo: root)
        guard FileManager.default.isExecutableFile(atPath: commandURL.path) else { return nil }
        return Server(command: commandURL.path, cwd: cwdURL.path)
    }

    private static func serverFromInstalledCopy() -> Server? {
        let root = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".codex/computer-use", isDirectory: true)
        let commandURL = root
            .appendingPathComponent("Codex Computer Use.app", isDirectory: true)
            .appendingPathComponent("Contents/SharedSupport/SkyComputerUseClient.app", isDirectory: true)
            .appendingPathComponent("Contents/MacOS/SkyComputerUseClient")
        guard FileManager.default.isExecutableFile(atPath: commandURL.path) else { return nil }
        return Server(command: commandURL.path, cwd: root.path)
    }

    private static var missingDetail: String {
        "Install or run Codex App's Computer Use plugin so Helm can find \(NSHomeDirectory())/.codex/plugins/cache/openai-bundled/computer-use/<version>/.mcp.json."
    }

    private static func readyDiagnostic(for server: Server) -> CodexComputerUseDiagnostic {
        CodexComputerUseDiagnostic(
            state: .ready,
            title: "Ready",
            detail: "Helm will attach Codex App's Computer Use MCP to local Codex sessions.",
            command: server.command,
            cwd: server.cwd
        )
    }

    private static func cachedFailure(for server: Server) -> String? {
        cachedState(for: server).failure
    }

    private static func cachedState(for server: Server) -> (ready: Bool, failure: String?) {
        let key = "\(server.command)\n\(server.cwd)"
        validationLock.lock()
        let ready = validatedServerKeys.contains(key)
        let failure = failedServerKeys[key]
        validationLock.unlock()
        return (ready, failure)
    }

    private static func startFailure(for server: Server, refresh: Bool) -> String? {
        let key = "\(server.command)\n\(server.cwd)"
        validationLock.lock()
        if refresh {
            validatedServerKeys.remove(key)
            failedServerKeys.removeValue(forKey: key)
        } else if validatedServerKeys.contains(key) {
            validationLock.unlock()
            return nil
        } else if let failure = failedServerKeys[key] {
            validationLock.unlock()
            return failure
        }
        validationLock.unlock()

        let failure = launchProbeFailure(for: server)
        validationLock.lock()
        if let failure {
            failedServerKeys[key] = failure
        } else {
            validatedServerKeys.insert(key)
            failedServerKeys.removeValue(forKey: key)
        }
        validationLock.unlock()
        return failure
    }

    private static func launchProbeFailure(for server: Server) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: server.command)
        proc.arguments = ["mcp"]
        proc.currentDirectoryURL = URL(fileURLWithPath: server.cwd, isDirectory: true)

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        let stdoutProbe = MCPProbeOutput()
        let stderrBuffer = LockedDataBuffer()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            stdoutProbe.append(data)
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            stderrBuffer.append(data)
        }

        do {
            try proc.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            return error.localizedDescription
        }
        defer {
            try? stdin.fileHandleForWriting.close()
            if proc.isRunning {
                proc.terminate()
                proc.waitUntilExit()
            }
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            stdoutProbe.append(stdout.fileHandleForReading.readDataToEndOfFile())
            stderrBuffer.append(stderr.fileHandleForReading.readDataToEndOfFile())
        }

        do {
            try writeMCPProbeRequest(
                [
                    "jsonrpc": "2.0",
                    "id": 1,
                    "method": "initialize",
                    "params": [
                        "protocolVersion": "2024-11-05",
                        "capabilities": [:],
                        "clientInfo": [
                            "name": "helm",
                            "version": "0",
                        ],
                    ],
                ] as [String: Any],
                to: stdin
            )
        } catch {
            return "MCP initialize write failed: \(error.localizedDescription)"
        }

        guard let initialize = stdoutProbe.waitForResponse(id: 1, timeout: 4) else {
            return probeTimeoutMessage(stage: "initialize", stdout: stdoutProbe.text(), stderr: stderrBuffer.value())
        }
        if let error = probeError(in: initialize) {
            return "MCP initialize failed: \(error)"
        }
        guard let result = initialize["result"] as? [String: Any],
              result["serverInfo"] is [String: Any]
        else {
            return "MCP initialize returned an unexpected response: \(serialize(initialize))"
        }

        do {
            try writeMCPProbeRequest(
                [
                    "jsonrpc": "2.0",
                    "method": "notifications/initialized",
                    "params": [:],
                ],
                to: stdin
            )
            try writeMCPProbeRequest(
                [
                    "jsonrpc": "2.0",
                    "id": 2,
                    "method": "tools/list",
                    "params": [:],
                ],
                to: stdin
            )
        } catch {
            return "MCP tools/list write failed: \(error.localizedDescription)"
        }

        guard let toolsList = stdoutProbe.waitForResponse(id: 2, timeout: 4) else {
            return probeTimeoutMessage(stage: "tools/list", stdout: stdoutProbe.text(), stderr: stderrBuffer.value())
        }
        if let error = probeError(in: toolsList) {
            return "MCP tools/list failed: \(error)"
        }
        guard let listResult = toolsList["result"] as? [String: Any],
              let tools = listResult["tools"] as? [[String: Any]],
              tools.contains(where: { ($0["name"] as? String) == "list_apps" })
        else {
            return "Computer Use MCP did not advertise list_apps."
        }
        return nil
    }

    private static func writeMCPProbeRequest(_ request: [String: Any], to stdin: Pipe) throws {
        let data = try JSONSerialization.data(withJSONObject: request)
        try stdin.fileHandleForWriting.write(contentsOf: data)
        try stdin.fileHandleForWriting.write(contentsOf: Data([0x0A]))
    }

    private static func probeError(in response: [String: Any]) -> String? {
        guard let error = response["error"] else { return nil }
        return serialize(error)
    }

    private static func probeTimeoutMessage(stage: String, stdout: String, stderr: Data) -> String {
        let stderrText = String(data: stderr, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stdoutText = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let output = [stderrText, stdoutText]
            .compactMap { text in
                guard let text, !text.isEmpty else { return nil }
                return text
            }
            .joined(separator: "\n")
        return output.isEmpty
            ? "Computer Use MCP did not respond to \(stage)."
            : "Computer Use MCP did not respond to \(stage). Last output:\n\(output)"
    }

    private static func serialize(_ value: Any?) -> String {
        switch value {
        case let string as String:
            return string
        case let object?:
            guard JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                  let text = String(data: data, encoding: .utf8)
            else { return String(describing: object) }
            return text
        case nil:
            return ""
        }
    }

    private static func absoluteURL(_ value: String, relativeTo root: URL) -> URL {
        if value.hasPrefix("/") {
            return URL(fileURLWithPath: value)
        }
        return root.appendingPathComponent(value)
    }

    private static func tomlStringLiteral(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\":
                out += "\\\\"
            case "\"":
                out += "\\\""
            case "\n":
                out += "\\n"
            case "\r":
                out += "\\r"
            case "\t":
                out += "\\t"
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
        return out
    }
}

private final class MCPProbeOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let signal = DispatchSemaphore(value: 0)
    private var pending = ""
    private var raw = ""
    private var responses: [Int: [String: Any]] = [:]

    func append(_ data: Data) {
        guard let chunk = String(data: data, encoding: .utf8),
              !chunk.isEmpty
        else { return }

        var parsedCount = 0
        lock.lock()
        raw.append(chunk)
        pending.append(chunk)
        while let newline = pending.firstIndex(of: "\n") {
            let line = String(pending[..<newline])
            pending.removeSubrange(...newline)
            if let object = Self.parse(line),
               let id = Self.responseId(from: object) {
                responses[id] = object
                parsedCount += 1
            }
        }
        lock.unlock()

        for _ in 0..<parsedCount {
            signal.signal()
        }
    }

    func waitForResponse(id: Int, timeout: TimeInterval) -> [String: Any]? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            lock.lock()
            let response = responses[id]
            lock.unlock()
            if let response {
                return response
            }

            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                return nil
            }
            let milliseconds = max(1, Int(min(remaining, 0.1) * 1_000))
            _ = signal.wait(timeout: .now() + .milliseconds(milliseconds))
        }
    }

    func text() -> String {
        lock.lock()
        let snapshot = raw
        lock.unlock()
        return snapshot
    }

    private static func parse(_ line: String) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8)
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func responseId(from object: [String: Any]) -> Int? {
        if let id = object["id"] as? Int {
            return id
        }
        if let id = object["id"] as? NSNumber {
            return id.intValue
        }
        return nil
    }
}

private final class LockedDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func value() -> Data {
        lock.lock()
        let snapshot = data
        lock.unlock()
        return snapshot
    }
}
