import Darwin
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

extension RunConfig {
    var usesComputerUseMCP: Bool {
        args.contains { arg in
            arg.contains("mcp_servers.computer-use")
                || arg.contains(CodexComputerUseMCP.claudeServerName)
        }
    }
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
            return try resolveClaude(profile: profile, session: session, provider: provider,
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
                                      isRemoteProject: Bool) throws -> RunConfig {
        var env: [String: String] = [:]
        if !provider.baseURL.isEmpty {
            env["ANTHROPIC_BASE_URL"] = provider.baseURL
        }
        if !provider.authToken.isEmpty {
            env["ANTHROPIC_AUTH_TOKEN"] = provider.authToken
        }
        let usesRemoteDefaultModel = isRemoteProject &&
            primary.providerModelId == RemoteClaudeProviderCandidate.defaultModelId
        if !usesRemoteDefaultModel {
            env["ANTHROPIC_MODEL"] = primary.providerModelId
        }

        let opus   = lookupModel(profile.opusModelId,   models: models) ?? primary
        let sonnet = lookupModel(profile.sonnetModelId, models: models) ?? primary
        let haiku  = lookupModel(profile.haikuModelId,  models: models) ?? primary
        if !usesRemoteDefaultModel {
            env["ANTHROPIC_DEFAULT_OPUS_MODEL"]   = opus.providerModelId
            env["ANTHROPIC_DEFAULT_SONNET_MODEL"] = sonnet.providerModelId
            env["ANTHROPIC_DEFAULT_HAIKU_MODEL"]  = haiku.providerModelId
        }

        if usesRemoteDefaultModel {
            // Leave Claude Code's remote subscription/default model selection intact.
        } else if let sub = lookupModel(profile.subagentModelId, models: models) {
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
        var args: [String] = usesRemoteDefaultModel ? [] : ["--model", primary.providerModelId]
        args.append(contentsOf: ["--permission-mode",
                                 session.claudePermissionMode.rawValue])
        args.append(contentsOf: ["--effort", session.claudeEffort.rawValue])
        if !isRemoteProject, let root = profile.configRoot, !root.isEmpty {
            args.append(contentsOf: ["--setting-sources", "user,project,local"])
        }
        args.append(contentsOf: try CodexComputerUseMCP.claudeConfigArgs(isRemoteProject: isRemoteProject))

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

        if isRemoteProject,
           profile.sshProjectId != nil,
           let delegate = profile.delegateVendorProfile,
           !delegate.isEmpty {
            args.append(contentsOf: ["--profile", delegate])
            appendCodexRuntimeConfig(profile: profile,
                                     session: session,
                                     primary: nil,
                                     to: &args)
        } else if isRemoteProject,
                  profile.sshProjectId != nil,
                  let remoteProviderKey = provider.remoteCodexProviderKey,
                  !remoteProviderKey.isEmpty {
            args.append(contentsOf: ["-c", "model_provider=\(tomlStringLiteral(remoteProviderKey))"])
            appendCodexRuntimeConfig(profile: profile,
                                     session: session,
                                     primary: primary,
                                     to: &args)
        } else if isRemoteProject,
                  profile.sshProjectId != nil {
            appendCodexRuntimeConfig(profile: profile,
                                     session: session,
                                     primary: primary,
                                     to: &args)
        } else if !isRemoteProject, let delegate = profile.delegateVendorProfile, !delegate.isEmpty {
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
            let useOpenAIAuth = provider.requiresOpenAIAuth && provider.authToken.isEmpty
            args.append(contentsOf: ["-c", "model_providers.\(providerKey).requires_openai_auth=\(useOpenAIAuth)"])
            if !useOpenAIAuth, !provider.authToken.isEmpty {
                let envKey = authEnvKey(for: provider.name)
                args.append(contentsOf: ["-c", "model_providers.\(providerKey).env_key=\(tomlStringLiteral(envKey))"])
                env[envKey] = provider.authToken
            }
            if !provider.httpHeaders.isEmpty {
                args.append(contentsOf: [
                    "-c",
                    "model_providers.\(providerKey).http_headers=\(tomlInlineStringMap(provider.httpHeaders))",
                ])
            }
            appendCodexRuntimeConfig(profile: profile,
                                     session: session,
                                     primary: primary,
                                     to: &args)
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

    private static func appendCodexRuntimeConfig(profile: Profile,
                                                 session: Session,
                                                 primary: Model?,
                                                 to args: inout [String]) {
        if let primary, primary.providerModelId != "remote default" {
            args.append(contentsOf: ["-c", "model=\"\(primary.providerModelId)\""])
        }
        args.append(contentsOf: ["-c", "model_reasoning_effort=\"\(session.codexEffort.rawValue)\""])
        if let s = profile.serviceTier {
            args.append(contentsOf: ["-c", "service_tier=\"\(s.rawValue)\""])
        }
        args.append(contentsOf: ["-c", "sandbox_mode=\"\(session.codexSandboxMode.rawValue)\""])
        args.append(contentsOf: ["-c", "approval_policy=\"\(session.codexApprovalMode.rawValue)\""])
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

    private static func authEnvKey(for providerName: String) -> String {
        "HELM_\(sanitizeKey(providerName).uppercased())_API_KEY"
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

struct ClaudeCodeVersion: Equatable, Comparable, Sendable {
    var major: Int
    var minor: Int
    var patch: Int

    var displayName: String {
        "\(major).\(minor).\(patch)"
    }

    static func < (lhs: ClaudeCodeVersion, rhs: ClaudeCodeVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    static func parse(_ raw: String) -> ClaudeCodeVersion? {
        let pattern = #"(\d+)\.(\d+)\.(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              match.numberOfRanges == 4
        else { return nil }

        func component(_ index: Int) -> Int? {
            guard let range = Range(match.range(at: index), in: raw) else { return nil }
            return Int(raw[range])
        }

        guard let major = component(1),
              let minor = component(2),
              let patch = component(3)
        else { return nil }

        return ClaudeCodeVersion(major: major, minor: minor, patch: patch)
    }
}

struct ClaudeWorkflowRuntimeDiagnostic: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case missing
        case needsUpgrade
        case ready
        case unknownVersion
        case checking
        case upgrading
        case failed
    }

    var state: State
    var title: String
    var detail: String
    var command: String?
    var installedVersion: String?
    var requiredVersion: String
    var upgradeCommand: String?

    var isReady: Bool {
        state == .ready
    }

    var canUpgrade: Bool {
        switch state {
        case .missing, .checking, .upgrading:
            return false
        case .needsUpgrade, .ready, .unknownVersion, .failed:
            return upgradeCommand != nil
        }
    }
}

enum ClaudeWorkflowRuntime {
    static let minimumDynamicWorkflowVersion = ClaudeCodeVersion(major: 2, minor: 1, patch: 154)

    static func diagnose(command: String = "claude") -> ClaudeWorkflowRuntimeDiagnostic {
        guard let executable = resolveCommand(command) else {
            return ClaudeWorkflowRuntimeDiagnostic(
                state: .missing,
                title: "Claude Code not found",
                detail: "Install Claude Code or set the Claude profile command path before using native Dynamic Workflows.",
                command: nil,
                installedVersion: nil,
                requiredVersion: minimumDynamicWorkflowVersion.displayName,
                upgradeCommand: nil
            )
        }

        let result = runProcess(executable: executable, arguments: ["--version"])
        let versionText = firstNonEmptyLine(result.stdout) ?? firstNonEmptyLine(result.stderr)
        guard result.status == 0 else {
            return ClaudeWorkflowRuntimeDiagnostic(
                state: .failed,
                title: "Cannot run Claude Code",
                detail: lastNonEmptyLine(result.stderr) ?? "claude --version exited \(result.status).",
                command: executable,
                installedVersion: versionText,
                requiredVersion: minimumDynamicWorkflowVersion.displayName,
                upgradeCommand: "\(executable) update"
            )
        }

        guard let versionText,
              let version = ClaudeCodeVersion.parse(versionText)
        else {
            return ClaudeWorkflowRuntimeDiagnostic(
                state: .unknownVersion,
                title: "Version unknown",
                detail: "Helm found Claude Code but could not parse its version. Native workflow support requires \(minimumDynamicWorkflowVersion.displayName) or newer.",
                command: executable,
                installedVersion: versionText,
                requiredVersion: minimumDynamicWorkflowVersion.displayName,
                upgradeCommand: "\(executable) update"
            )
        }

        if version >= minimumDynamicWorkflowVersion {
            return ClaudeWorkflowRuntimeDiagnostic(
                state: .ready,
                title: "Ready for Dynamic Workflows",
                detail: "Claude Code \(version.displayName) meets Helm's minimum native workflow requirement.",
                command: executable,
                installedVersion: version.displayName,
                requiredVersion: minimumDynamicWorkflowVersion.displayName,
                upgradeCommand: "\(executable) update"
            )
        }

        return ClaudeWorkflowRuntimeDiagnostic(
            state: .needsUpgrade,
            title: "Upgrade required",
            detail: "Claude Code \(version.displayName) is below Helm's minimum native workflow requirement. Helm can still fall back to prompt-guided workflow orchestration.",
            command: executable,
            installedVersion: version.displayName,
            requiredVersion: minimumDynamicWorkflowVersion.displayName,
            upgradeCommand: "\(executable) update"
        )
    }

    static func upgrade(command: String = "claude") -> ClaudeWorkflowRuntimeDiagnostic {
        guard let executable = resolveCommand(command) else {
            return diagnose(command: command)
        }

        let result = runProcess(executable: executable, arguments: ["update"])
        if result.status != 0 {
            return ClaudeWorkflowRuntimeDiagnostic(
                state: .failed,
                title: "Upgrade failed",
                detail: lastNonEmptyLine(result.stderr) ?? lastNonEmptyLine(result.stdout) ?? "claude update exited \(result.status).",
                command: executable,
                installedVersion: nil,
                requiredVersion: minimumDynamicWorkflowVersion.displayName,
                upgradeCommand: "\(executable) update"
            )
        }

        return diagnose(command: executable)
    }

    private static func resolveCommand(_ command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.isEmpty ? "claude" : trimmed
        if candidate.contains("/") {
            let path = (candidate as NSString).expandingTildeInPath
            return FileManager.default.isExecutableFile(atPath: path) ? path : nil
        }

        let envPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let search = [
            "\(NSHomeDirectory())/.local/bin",
            "\(NSHomeDirectory())/.npm-global/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ] + envPath.split(separator: ":").map(String.init)

        for dir in search {
            let full = URL(fileURLWithPath: dir)
                .appendingPathComponent(candidate)
                .path
            if FileManager.default.isExecutableFile(atPath: full) {
                return full
            }
        }
        return nil
    }

    private static func runProcess(executable: String,
                                   arguments: [String]) -> (status: Int32, stdout: String, stderr: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        let extras = ["\(NSHomeDirectory())/.local/bin",
                      "\(NSHomeDirectory())/.npm-global/bin",
                      "/opt/homebrew/bin",
                      "/usr/local/bin"]
        let existing = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (extras + [existing]).joined(separator: ":")
        proc.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr

        do {
            try proc.run()
        } catch {
            return (127, "", error.localizedDescription)
        }

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return (
            proc.terminationStatus,
            String(data: outData, encoding: .utf8) ?? "",
            String(data: errData, encoding: .utf8) ?? ""
        )
    }

    private static func firstNonEmptyLine(_ raw: String) -> String? {
        raw.split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private static func lastNonEmptyLine(_ raw: String) -> String? {
        raw.split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .last { !$0.isEmpty }
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

/// Reuses the Codex App-bundled Computer Use MCP from Helm-launched local agent
/// runs. This keeps Helm out of the macOS Accessibility / ScreenCaptureKit
/// implementation and lets Codex own the native service.
enum CodexComputerUseMCP {
    static let claudeServerName = "helm_computer_use"

    private struct Server {
        var command: String
        var cwd: String
    }

    private static let validationLock = NSLock()
    private static var validatedServerKeys: Set<String> = []
    private static var failedServerKeys: [String: String] = [:]

    static func configArgs(isRemoteProject: Bool) throws -> [String] {
        guard try attachableServer(isRemoteProject: isRemoteProject) != nil else { return [] }
        guard let executable = Bundle.main.executablePath else { return [] }

        return [
            "-c", "mcp_servers.computer-use.command=\(tomlStringLiteral(executable))",
            "-c", "mcp_servers.computer-use.args=[\"\(HelmComputerUseMCPProxy.commandLineFlag)\"]",
        ]
    }

    static func claudeConfigArgs(isRemoteProject: Bool) throws -> [String] {
        guard try attachableServer(isRemoteProject: isRemoteProject) != nil else { return [] }
        guard let executable = Bundle.main.executablePath else { return [] }
        return ["--mcp-config", claudeProxyConfigString(command: executable)]
    }

    static func localServerForProxy() throws -> (command: String, cwd: String)? {
        guard let server = try attachableServer(isRemoteProject: false) else { return nil }
        return (server.command, server.cwd)
    }

    static func directConfigArgsForProxy() throws -> [String] {
        guard let server = try attachableServer(isRemoteProject: false) else { return [] }
        return [
            "-c", "mcp_servers.computer-use.command=\(tomlStringLiteral(server.command))",
            "-c", "mcp_servers.computer-use.args=[\"mcp\"]",
            "-c", "mcp_servers.computer-use.cwd=\(tomlStringLiteral(server.cwd))",
        ]
    }

    private static func attachableServer(isRemoteProject: Bool) throws -> Server? {
        guard !isRemoteProject else { return nil }
        guard ProcessInfo.processInfo.environment["HELM_DISABLE_CODEX_COMPUTER_USE_MCP"] != "1" else { return nil }

        let mode = CodexComputerUseMode.stored()
        guard mode != .disabled else { return nil }
        guard let server = discoverServer() else {
            if mode == .enabled {
                throw ResolverError.computerUseUnavailable(missingDetail)
            }
            return nil
        }
        if let failure = startFailure(for: server, refresh: false) {
            if mode == .enabled {
                throw ResolverError.computerUseUnavailable(failure)
            }
            return nil
        }
        return server
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
                detail: "Helm will not attach Computer Use MCP to local agent sessions on this device.",
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
            detail: "Helm will attach Codex App's Computer Use MCP to local Codex and Claude sessions.",
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

    private static func claudeProxyConfigString(command: String) -> String {
        let object: [String: Any] = [
            "mcpServers": [
                claudeServerName: [
                    "command": command,
                    "args": [HelmComputerUseMCPProxy.commandLineFlag],
                ],
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
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

private final class MCPProxyOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let signal = DispatchSemaphore(value: 0)
    private let requestHandler: (Any, String, [String: Any]?) -> Void
    private var pending = ""
    private var raw = ""
    private var responses: [Int: [String: Any]] = [:]

    init(requestHandler: @escaping (Any, String, [String: Any]?) -> Void) {
        self.requestHandler = requestHandler
    }

    func append(_ data: Data) {
        guard let chunk = String(data: data, encoding: .utf8),
              !chunk.isEmpty
        else { return }

        var parsedResponseCount = 0
        var requests: [(Any, String, [String: Any]?)] = []
        lock.lock()
        raw.append(chunk)
        pending.append(chunk)
        while let newline = pending.firstIndex(of: "\n") {
            let line = String(pending[..<newline])
            pending.removeSubrange(...newline)
            guard let object = Self.parse(line),
                  let id = object["id"]
            else { continue }
            if object["result"] != nil || object["error"] != nil {
                if let responseId = Self.responseId(from: object) {
                    responses[responseId] = object
                    parsedResponseCount += 1
                }
            } else if let method = object["method"] as? String {
                requests.append((id, method, object["params"] as? [String: Any]))
            }
        }
        lock.unlock()

        for request in requests {
            requestHandler(request.0, request.1, request.2)
        }
        for _ in 0..<parsedResponseCount {
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

enum HelmComputerUseMCPProxy {
    static let commandLineFlag = "--computer-use-mcp-proxy"

    static func run() {
        while let line = readLine() {
            autoreleasepool {
                handleLine(line)
            }
        }
    }

    private static func handleLine(_ line: String) {
        guard let object = parseJSONObject(line) else { return }
        guard let id = object["id"] else { return }
        let method = object["method"] as? String ?? ""
        let params = object["params"] as? [String: Any]

        switch method {
        case "initialize":
            writeResponse(id: id, result: [
                "protocolVersion": params?["protocolVersion"] as? String ?? "2024-11-05",
                "capabilities": [
                    "tools": ["listChanged": false],
                ],
                "serverInfo": [
                    "name": CodexComputerUseMCP.claudeServerName,
                    "title": "Computer Use",
                    "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",
                ],
            ])

        case "tools/list":
            writeResponse(id: id, result: ["tools": toolDefinitions])

        case "tools/call":
            let name = params?["name"] as? String ?? ""
            let arguments = params?["arguments"] as? [String: Any] ?? [:]
            let result = callTool(name: name, arguments: arguments)
            writeResponse(id: id, result: result)

        default:
            writeError(id: id, code: -32601, message: "Unsupported method '\(method)'.")
        }
    }

    private static var toolDefinitions: [[String: Any]] {
        [
            tool("list_apps", "List running and recently used macOS apps.", [:], []),
            tool("get_app_state", "Read a macOS app window state and screenshot.",
                 ["app": string("App name, path, or bundle identifier.")], ["app"]),
            tool("click", "Click an app UI element or screen coordinate.",
                 [
                    "app": string("App name, path, or bundle identifier."),
                    "element_index": string("Accessibility element index."),
                    "x": number("X coordinate in screenshot pixels."),
                    "y": number("Y coordinate in screenshot pixels."),
                    "click_count": integer("Number of clicks."),
                    "mouse_button": enumString(["left", "right", "middle"], "Mouse button."),
                 ], ["app"]),
            tool("perform_secondary_action", "Invoke a secondary accessibility action.",
                 [
                    "app": string("App name, path, or bundle identifier."),
                    "element_index": string("Accessibility element index."),
                    "action": string("Secondary action name."),
                 ], ["app", "element_index", "action"]),
            tool("set_value", "Set the value of a settable accessibility element.",
                 [
                    "app": string("App name, path, or bundle identifier."),
                    "element_index": string("Accessibility element index."),
                    "value": string("Value to assign."),
                 ], ["app", "element_index", "value"]),
            tool("select_text", "Select text or place the cursor inside a text element.",
                 [
                    "app": string("App name, path, or bundle identifier."),
                    "element_index": string("Text element index."),
                    "text": string("Target text."),
                    "prefix": string("Text before the target."),
                    "suffix": string("Text after the target."),
                    "selection": enumString(["text", "cursor_before", "cursor_after"], "Selection mode."),
                 ], ["app", "element_index", "text"]),
            tool("scroll", "Scroll an app element.",
                 [
                    "app": string("App name, path, or bundle identifier."),
                    "element_index": string("Scrollable element index."),
                    "direction": enumString(["up", "down", "left", "right"], "Scroll direction."),
                    "pages": number("Number of pages to scroll."),
                 ], ["app", "element_index", "direction"]),
            tool("drag", "Drag between two screenshot coordinates.",
                 [
                    "app": string("App name, path, or bundle identifier."),
                    "from_x": number("Start X coordinate."),
                    "from_y": number("Start Y coordinate."),
                    "to_x": number("End X coordinate."),
                    "to_y": number("End Y coordinate."),
                 ], ["app", "from_x", "from_y", "to_x", "to_y"]),
            tool("press_key", "Press a key or key combination.",
                 [
                    "app": string("App name, path, or bundle identifier."),
                    "key": string("xdotool-style key or key combination."),
                 ], ["app", "key"]),
            tool("type_text", "Type literal text into an app.",
                 [
                    "app": string("App name, path, or bundle identifier."),
                    "text": string("Literal text to type."),
                 ], ["app", "text"]),
        ]
    }

    private static func tool(_ name: String,
                             _ description: String,
                             _ properties: [String: Any],
                             _ required: [String]) -> [String: Any] {
        [
            "name": name,
            "title": "Computer Use \(name)",
            "description": description,
            "inputSchema": [
                "type": "object",
                "properties": properties,
                "required": required,
                "additionalProperties": false,
            ],
        ]
    }

    private static func string(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    private static func number(_ description: String) -> [String: Any] {
        ["type": "number", "description": description]
    }

    private static func integer(_ description: String) -> [String: Any] {
        ["type": "integer", "description": description]
    }

    private static func enumString(_ values: [String], _ description: String) -> [String: Any] {
        ["type": "string", "enum": values, "description": description]
    }

    private static func callTool(name: String, arguments: [String: Any]) -> [String: Any] {
        guard toolDefinitions.contains(where: { ($0["name"] as? String) == name }) else {
            return textResult("Unknown Computer Use tool '\(name)'.", isError: true)
        }

        do {
            guard try CodexComputerUseMCP.localServerForProxy() != nil else {
                return textResult("Computer Use MCP is disabled or unavailable on this device.",
                                  isError: true)
            }
        } catch {
            return textResult(error.localizedDescription, isError: true)
        }

        return callCodexComputerUse(name: name, arguments: arguments)
    }

    private static func callCodexComputerUse(name: String, arguments: [String: Any]) -> [String: Any] {
        let configArgs: [String]
        do {
            configArgs = try CodexComputerUseMCP.directConfigArgsForProxy()
        } catch {
            return textResult(error.localizedDescription, isError: true)
        }
        guard !configArgs.isEmpty else {
            return textResult("Computer Use MCP is disabled or unavailable on this device.",
                              isError: true)
        }

        let prompt = """
        Use exactly one computer-use MCP tool call.
        Tool name: \(name)
        Arguments JSON: \(serialize(arguments))

        Do not use shell or any other tool. After the tool call finishes, reply exactly HELM_COMPUTER_USE_DONE.
        """

        let executable: String
        do {
            executable = try resolveCommand(ProcessInfo.processInfo.environment["HELM_CODEX_COMMAND"] ?? "codex")
        } catch {
            return textResult(error.localizedDescription, isError: true)
        }

        let codexArgs = [
            "exec",
            "--json",
            "--dangerously-bypass-approvals-and-sandbox",
            "--skip-git-repo-check",
        ] + configArgs + [prompt]
        let timeout: TimeInterval = name == "get_app_state" ? 150 : 120

        if ProcessInfo.processInfo.environment["HELM_DISABLE_CODEX_COMPUTER_USE_LAUNCHD"] != "1" {
            let result = runCodexViaLaunchd(executable: executable,
                                            arguments: codexArgs,
                                            timeout: timeout)
            if result.timedOut {
                let details = processDetails(stdout: result.stdout,
                                             stderr: result.stderr)
                let suffix = details.isEmpty ? "" : " Last output:\n\(details)"
                return textResult("Computer Use tool '\(name)' timed out.\(suffix)", isError: true)
            }

            let stdoutText = String(data: result.stdout, encoding: .utf8) ?? ""
            let parsed = parseCodexToolOutput(stdoutText, expectedTool: name)
            if let tool = parsed.tool {
                return tool
            }
            if result.status != 0 {
                let detail = processDetails(stdout: result.stdout,
                                            stderr: result.stderr)
                return textResult(detail.isEmpty ? "codex exited \(result.status)" : detail,
                                  isError: true)
            }
            if let final = parsed.final, !final.text.isEmpty {
                return textResult(final.text, isError: final.isError)
            }
            return textResult("Codex did not return a Computer Use tool result.", isError: true)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = codexArgs
        proc.environment = cleanCodexEnvironment()
        proc.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        let stdin = try? FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null"))
        if let stdin {
            proc.standardInput = stdin
        }
        let stdout = Pipe()
        let stderr = Pipe()
        let stdoutBuffer = LockedDataBuffer()
        let stderrBuffer = LockedDataBuffer()
        proc.standardOutput = stdout
        proc.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { handle in
            stdoutBuffer.append(handle.availableData)
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            stderrBuffer.append(handle.availableData)
        }

        let finished = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in finished.signal() }

        var tracker: ProcessDescendantTracker?
        do {
            try proc.run()
            tracker = ProcessDescendantTracker(process: proc)
            tracker?.start()
        } catch {
            try? stdin?.close()
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            return textResult(error.localizedDescription, isError: true)
        }

        if finished.wait(timeout: .now() + .seconds(Int(timeout))) == .timedOut {
            let tracked = tracker?.stop() ?? []
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            ProcessTreeTerminator.terminate(proc,
                                            closing: stdin,
                                            trackedDescendants: tracked,
                                            killAfter: 0.5)
            stdoutBuffer.append(stdout.fileHandleForReading.readDataToEndOfFile())
            stderrBuffer.append(stderr.fileHandleForReading.readDataToEndOfFile())
            let details = processDetails(stdout: stdoutBuffer.value(),
                                         stderr: stderrBuffer.value())
            let suffix = details.isEmpty ? "" : " Last output:\n\(details)"
            return textResult("Computer Use tool '\(name)' timed out.\(suffix)", isError: true)
        }

        let tracked = tracker?.stop() ?? []
        ProcessTreeTerminator.terminate(pids: tracked, killAfter: 0.5)
        try? stdin?.close()
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        stdoutBuffer.append(stdout.fileHandleForReading.readDataToEndOfFile())
        stderrBuffer.append(stderr.fileHandleForReading.readDataToEndOfFile())

        let stdoutText = String(data: stdoutBuffer.value(), encoding: .utf8) ?? ""
        let parsed = parseCodexToolOutput(stdoutText, expectedTool: name)
        if let tool = parsed.tool {
            return tool
        }
        if proc.terminationStatus != 0 {
            let detail = processDetails(stdout: stdoutBuffer.value(),
                                        stderr: stderrBuffer.value())
            return textResult(detail.isEmpty ? "codex exited \(proc.terminationStatus)" : detail,
                              isError: true)
        }
        if let final = parsed.final, !final.text.isEmpty {
            return textResult(final.text, isError: final.isError)
        }
        return textResult("Codex did not return a Computer Use tool result.", isError: true)
    }

    private struct CodexLaunchResult {
        var status: Int32
        var stdout: Data
        var stderr: Data
        var timedOut: Bool
    }

    private static func runCodexViaLaunchd(executable: String,
                                           arguments: [String],
                                           timeout: TimeInterval) -> CodexLaunchResult {
        let fileManager = FileManager.default
        let id = UUID().uuidString.lowercased()
        let label = "dev.deng.helm.computer-use.\(id)"
        let dir = fileManager.temporaryDirectory
            .appendingPathComponent("helm-computer-use-\(id)", isDirectory: true)
        let scriptURL = dir.appendingPathComponent("run.sh")
        let stdoutURL = dir.appendingPathComponent("stdout.jsonl")
        let stderrURL = dir.appendingPathComponent("stderr.log")
        let statusURL = dir.appendingPathComponent("status")
        let pgidURL = dir.appendingPathComponent("pgid")

        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            let envArgs = cleanCodexEnvironment()
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
            let command = (["/usr/bin/env", "-i"] + envArgs + [executable] + arguments)
                .map(shellQuote)
                .joined(separator: " ")
            let script = """
            #!/bin/bash
            pgid="$(ps -o pgid= -p $$ | tr -d ' ')"
            printf '%s\\n' "$pgid" > \(shellQuote(pgidURL.path))
            cd \(shellQuote(FileManager.default.currentDirectoryPath))
            status=$?
            if [ "$status" -ne 0 ]; then
              printf '%s\\n' "$status" > \(shellQuote(statusURL.path))
              exit "$status"
            fi
            \(command) < /dev/null
            status=$?
            if [ -n "$pgid" ]; then
              pkill -TERM -g "$pgid" -f 'SkyComputerUseClient|codex app-server --listen stdio://' 2>/dev/null || true
              sleep 0.2
              pkill -KILL -g "$pgid" -f 'SkyComputerUseClient|codex app-server --listen stdio://' 2>/dev/null || true
            fi
            printf '%s\\n' "$status" > \(shellQuote(statusURL.path))
            exit "$status"
            """
            try script.data(using: .utf8)?.write(to: scriptURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o700],
                                          ofItemAtPath: scriptURL.path)
        } catch {
            return CodexLaunchResult(status: 1,
                                     stdout: Data(),
                                     stderr: Data(error.localizedDescription.utf8),
                                     timedOut: false)
        }

        let submit = Process()
        submit.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        submit.arguments = [
            "submit",
            "-l", label,
            "-o", stdoutURL.path,
            "-e", stderrURL.path,
            "--", scriptURL.path,
        ]
        let submitStderr = Pipe()
        submit.standardError = submitStderr
        do {
            try submit.run()
        } catch {
            return CodexLaunchResult(status: 1,
                                     stdout: readData(stdoutURL),
                                     stderr: Data(error.localizedDescription.utf8),
                                     timedOut: false)
        }
        submit.waitUntilExit()
        if submit.terminationStatus != 0 {
            let stderr = submitStderr.fileHandleForReading.readDataToEndOfFile()
            return CodexLaunchResult(status: submit.terminationStatus,
                                     stdout: readData(stdoutURL),
                                     stderr: stderr,
                                     timedOut: false)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while !fileManager.fileExists(atPath: statusURL.path) {
            if Date() >= deadline {
                removeLaunchdJob(label)
                terminateLaunchdProcessGroup(pgidURL)
                let result = CodexLaunchResult(status: SIGTERM,
                                               stdout: readData(stdoutURL),
                                               stderr: readData(stderrURL),
                                               timedOut: true)
                try? fileManager.removeItem(at: dir)
                return result
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        terminateLaunchdProcessGroup(pgidURL, killAfter: 0.2)
        Thread.sleep(forTimeInterval: 0.2)

        let statusText = (try? String(contentsOf: statusURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let status = Int32(statusText ?? "") ?? 1
        let result = CodexLaunchResult(status: status,
                                       stdout: readData(stdoutURL),
                                       stderr: readData(stderrURL),
                                       timedOut: false)
        try? fileManager.removeItem(at: dir)
        return result
    }

    private static func terminateLaunchdProcessGroup(_ pgidURL: URL,
                                                     killAfter grace: TimeInterval = 0.5) {
        guard let text = try? String(contentsOf: pgidURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let pgid = Int32(text),
              pgid > 1
        else { return }
        Darwin.kill(-pgid, SIGTERM)
        Thread.sleep(forTimeInterval: grace)
        Darwin.kill(-pgid, SIGKILL)
    }

    private static func removeLaunchdJob(_ label: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = ["remove", label]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try? proc.run()
        proc.waitUntilExit()
    }

    private static func readData(_ url: URL) -> Data {
        (try? Data(contentsOf: url)) ?? Data()
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func cleanCodexEnvironment() -> [String: String] {
        var env: [String: String] = [
            "HOME": NSHomeDirectory(),
            "PATH": [
                "/opt/homebrew/opt/node@24/bin",
                "\(NSHomeDirectory())/.local/bin",
                "/opt/homebrew/bin",
                "/usr/local/bin",
                "/usr/bin",
                "/bin",
                "/usr/sbin",
                "/sbin",
            ].joined(separator: ":"),
            "TERM": "dumb",
        ]
        let inherited = ProcessInfo.processInfo.environment
        if let tmp = inherited["TMPDIR"] {
            env["TMPDIR"] = tmp
        }
        if let lang = inherited["LANG"] {
            env["LANG"] = lang
        }
        if let lcAll = inherited["LC_ALL"] {
            env["LC_ALL"] = lcAll
        }
        return env
    }

    private static func processDetails(stdout: Data, stderr: Data) -> String {
        let stderrText = String(data: stderr, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stdoutText = String(data: stdout, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return [stderrText, stdoutText]
            .compactMap { text in
                guard let text, !text.isEmpty else { return nil }
                return text
            }
            .joined(separator: "\n")
    }

    private static func callNativeComputerUse(server: (command: String, cwd: String),
                                              name: String,
                                              arguments: [String: Any]) -> [String: Any] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: server.command)
        proc.arguments = ["mcp"]
        proc.currentDirectoryURL = URL(fileURLWithPath: server.cwd, isDirectory: true)

        let stdout = Pipe()
        let stderr = Pipe()
        let stderrBuffer = LockedDataBuffer()
        let stdin = Pipe()
        let writeLock = NSLock()
        let output = MCPProxyOutput { requestId, method, params in
            let response = responseToNativeComputerUseRequest(id: requestId,
                                                              method: method,
                                                              params: params)
            writeLock.lock()
            defer { writeLock.unlock() }
            try? writeMCPObject(response, to: stdin)
        }
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { handle in
            output.append(handle.availableData)
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            stderrBuffer.append(handle.availableData)
        }

        var tracker: ProcessDescendantTracker?
        do {
            try proc.run()
            tracker = ProcessDescendantTracker(process: proc)
            tracker?.start()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            return textResult(error.localizedDescription, isError: true)
        }
        defer {
            let tracked = tracker?.stop() ?? []
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            ProcessTreeTerminator.terminate(proc,
                                            closing: stdin.fileHandleForWriting,
                                            trackedDescendants: tracked,
                                            killAfter: 0.5)
            output.append(stdout.fileHandleForReading.readDataToEndOfFile())
            stderrBuffer.append(stderr.fileHandleForReading.readDataToEndOfFile())
        }

        do {
            try writeMCPObject([
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": [
                    "protocolVersion": "2025-06-18",
                    "capabilities": [
                        "elicitation": [
                            "form": [:],
                        ],
                    ],
                    "clientInfo": [
                        "name": "helm",
                        "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",
                    ],
                ],
            ], to: stdin)
        } catch {
            return textResult("Computer Use MCP initialize write failed: \(error.localizedDescription)",
                              isError: true)
        }

        guard let initialize = output.waitForResponse(id: 1, timeout: 6) else {
            return nativeMCPTimeoutResult(stage: "initialize",
                                          output: output,
                                          stderr: stderrBuffer)
        }
        if let error = mcpErrorText(in: initialize) {
            return textResult("Computer Use MCP initialize failed: \(error)", isError: true)
        }

        do {
            try writeMCPObject([
                "jsonrpc": "2.0",
                "method": "notifications/initialized",
                "params": [:],
            ], to: stdin)
            try writeMCPObject([
                "jsonrpc": "2.0",
                "id": 2,
                "method": "tools/list",
                "params": [
                    "_meta": nativeMCPCallMeta(),
                ],
            ], to: stdin)
        } catch {
            return textResult("Computer Use MCP tools/list write failed: \(error.localizedDescription)",
                              isError: true)
        }

        guard let toolsList = output.waitForResponse(id: 2, timeout: 6) else {
            return nativeMCPTimeoutResult(stage: "tools/list",
                                          output: output,
                                          stderr: stderrBuffer)
        }
        if let error = mcpErrorText(in: toolsList) {
            return textResult("Computer Use MCP tools/list failed: \(error)", isError: true)
        }

        do {
            try writeMCPObject([
                "jsonrpc": "2.0",
                "id": 3,
                "method": "tools/call",
                "params": [
                    "name": name,
                    "arguments": arguments,
                    "_meta": nativeMCPCallMeta(),
                ],
            ], to: stdin)
        } catch {
            return textResult("Computer Use MCP tools/call write failed: \(error.localizedDescription)",
                              isError: true)
        }

        let timeout: TimeInterval = name == "get_app_state" ? 120 : 90
        guard let response = output.waitForResponse(id: 3, timeout: timeout) else {
            return nativeMCPTimeoutResult(stage: "tools/call \(name)",
                                          output: output,
                                          stderr: stderrBuffer)
        }
        if let error = mcpErrorText(in: response) {
            return textResult("Computer Use MCP tools/call failed: \(error)", isError: true)
        }
        guard var result = response["result"] as? [String: Any] else {
            return textResult("Computer Use MCP returned an unexpected response: \(serialize(response))",
                              isError: true)
        }
        if result["isError"] == nil {
            result["isError"] = false
        }
        return result
    }

    private static func responseToNativeComputerUseRequest(id: Any,
                                                           method: String,
                                                           params: [String: Any]?) -> [String: Any] {
        if method == "ping" {
            return ["jsonrpc": "2.0", "id": id, "result": [:]]
        }
        if method.lowercased().contains("elicitation") {
            var content: [String: Any] = [:]
            if let schema = params?["requestedSchema"] as? [String: Any],
               let properties = schema["properties"] as? [String: Any] {
                for key in properties.keys {
                    content[key] = true
                }
            }
            return [
                "jsonrpc": "2.0",
                "id": id,
                "result": [
                    "action": "accept",
                    "content": content,
                ],
            ]
        }
        return [
            "jsonrpc": "2.0",
            "id": id,
            "error": [
                "code": -32601,
                "message": "Unsupported Computer Use MCP request '\(method)'.",
            ],
        ]
    }

    private static func nativeMCPCallMeta() -> [String: Any] {
        let threadId = "helm-\(UUID().uuidString.lowercased())"
        let turnId = "helm-\(UUID().uuidString.lowercased())"
        return [
            "progressToken": "helm-\(UUID().uuidString.lowercased())",
            "threadId": threadId,
            "x-codex-turn-metadata": [
                "thread-id": threadId,
                "turn-id": turnId,
                "cwd": FileManager.default.currentDirectoryPath,
                "client": "helm",
            ],
        ]
    }

    private static func nativeMCPTimeoutResult(stage: String,
                                               output: MCPProxyOutput,
                                               stderr: LockedDataBuffer) -> [String: Any] {
        let stderrText = String(data: stderr.value(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stdoutText = output.text().trimmingCharacters(in: .whitespacesAndNewlines)
        let details = [stderrText, stdoutText]
            .compactMap { text in
                guard let text, !text.isEmpty else { return nil }
                return text
            }
            .joined(separator: "\n")
        let suffix = details.isEmpty ? "" : " Last output:\n\(details)"
        return textResult("Computer Use MCP did not respond to \(stage).\(suffix)",
                          isError: true)
    }

    private static func mcpErrorText(in response: [String: Any]) -> String? {
        guard let error = response["error"] else { return nil }
        return serialize(error)
    }

    private static func writeMCPObject(_ object: [String: Any], to stdin: Pipe) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try stdin.fileHandleForWriting.write(contentsOf: data)
        try stdin.fileHandleForWriting.write(contentsOf: Data([0x0A]))
    }

    private static func parseCodexToolOutput(_ output: String,
                                             expectedTool: String) -> (tool: [String: Any]?, final: (text: String, isError: Bool)?) {
        var toolResult: [String: Any]?
        var final: (text: String, isError: Bool)?

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let object = parseJSONObject(String(rawLine)) else { continue }
            switch object["type"] as? String {
            case "item.completed":
                guard let item = object["item"] as? [String: Any] else { continue }
                let itemType = item["type"] as? String
                if itemType == "mcp_tool_call",
                   (item["server"] as? String) == "computer-use",
                   (item["tool"] as? String) == expectedTool {
                    let status = item["status"] as? String ?? ""
                    toolResult = toolResultFromCodex(result: item["result"],
                                                     error: item["error"],
                                                     status: status)
                } else if itemType == "agent_message" {
                    final = (item["text"] as? String ?? "", false)
                }
            case "turn.failed":
                final = (object["message"] as? String
                    ?? object["error"] as? String
                    ?? "Codex turn failed.", true)
            default:
                continue
            }
        }

        return (toolResult, final)
    }

    private static func requiresFreshAppState(_ name: String) -> Bool {
        name != "list_apps" && name != "get_app_state"
    }

    private static func toolResultFromCodex(result: Any?,
                                            error: Any?,
                                            status: String) -> [String: Any] {
        let isError = status == "failed" || jsonErrorIsPresent(error)
        let errorText = CodexToolPresentation.resultOutput(result: nil, error: error)
        if !errorText.isEmpty {
            return textResult(errorText, isError: true)
        }

        guard let object = result as? [String: Any] else {
            let text = CodexToolPresentation.resultOutput(result: result, error: nil)
            return textResult(text.isEmpty ? "Computer Use tool returned no content." : text,
                              isError: isError)
        }

        var out: [String: Any] = [
            "content": normalizedContent(from: object["content"])
                ?? [[
                    "type": "text",
                    "text": CodexToolPresentation.resultOutput(result: result, error: nil),
                ]],
            "isError": isError,
        ]
        let structured = object["structuredContent"] ?? object["structured_content"]
        if isJSONObjectValue(structured) {
            out["structuredContent"] = structured
        }
        return out
    }

    private static func normalizedContent(from value: Any?) -> [[String: Any]]? {
        guard let content = value as? [[String: Any]] else { return nil }
        let normalized = content.compactMap { item -> [String: Any]? in
            guard let type = item["type"] as? String else { return nil }
            switch type {
            case "text":
                guard let text = item["text"] as? String else { return nil }
                return ["type": "text", "text": text]
            case "image":
                guard let data = item["data"] as? String else { return nil }
                var image: [String: Any] = ["type": "image", "data": data]
                if let mimeType = item["mimeType"] as? String ?? item["mime_type"] as? String {
                    image["mimeType"] = mimeType
                }
                return image
            default:
                return JSONSerialization.isValidJSONObject(item)
                    ? item
                    : ["type": "text", "text": serialize(item)]
            }
        }
        return normalized.isEmpty ? nil : normalized
    }

    private static func textResult(_ text: String, isError: Bool) -> [String: Any] {
        [
            "content": [[
                "type": "text",
                "text": text,
            ]],
            "isError": isError,
        ]
    }

    private static func isJSONObjectValue(_ value: Any?) -> Bool {
        guard let value, !(value is NSNull) else { return false }
        return JSONSerialization.isValidJSONObject(["value": value])
    }

    private static func resolveCommand(_ command: String) throws -> String {
        if let resolved = CodexCommandLocator.resolve(command) {
            return resolved
        }
        throw AdapterError.commandNotFound(command)
    }

    private static func parseJSONObject(_ text: String) -> [String: Any]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8)
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func writeResponse(id: Any, result: Any) {
        writeJSONObject([
            "jsonrpc": "2.0",
            "id": id,
            "result": result,
        ])
    }

    private static func writeError(id: Any, code: Int, message: String) {
        writeJSONObject([
            "jsonrpc": "2.0",
            "id": id,
            "error": [
                "code": code,
                "message": message,
            ],
        ])
    }

    private static func writeJSONObject(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8)
        else { return }
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    private static func serialize(_ value: Any?) -> String {
        switch value {
        case let string as String:
            return string
        case let object?:
            guard JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                  let text = String(data: data, encoding: .utf8)
            else { return "{}" }
            return text
        case nil:
            return "{}"
        }
    }
}
