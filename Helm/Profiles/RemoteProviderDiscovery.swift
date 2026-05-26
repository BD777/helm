import Foundation

struct RemoteCodexProviderCandidate: Identifiable, Hashable, Sendable {
    var key: String
    var name: String
    var baseURL: String
    var wireAPI: Provider.WireAPI
    var requiresOpenAIAuth: Bool
    var profiles: [RemoteCodexProfileCandidate]

    var id: String { key.isEmpty ? "__default__" : key }

    var displayName: String {
        if !name.isEmpty { return name }
        return key.isEmpty ? "Default Codex provider" : key
    }

    var remoteConfigKey: String? {
        key.isEmpty ? nil : key
    }
}

struct RemoteCodexProfileCandidate: Identifiable, Hashable, Sendable {
    var profileName: String?
    var providerKey: String
    var providerName: String
    var modelId: String
    var reasoningEffort: Profile.ReasoningEffort?
    var serviceTier: Profile.ServiceTier?
    var sandboxMode: Profile.SandboxMode?

    var id: String {
        [profileName ?? "__default__", providerKey.isEmpty ? "__default_provider__" : providerKey, modelId]
            .joined(separator: "|")
    }

    var displayName: String {
        if let profileName, !profileName.isEmpty {
            return profileName
        }
        return "Default Codex config"
    }
}

struct RemoteClaudeProviderCandidate: Identifiable, Hashable, Sendable {
    static let defaultModelId = "remote default"

    var commandPath: String
    var hasSubscriptionAuth: Bool

    var id: String { commandPath }

    var displayName: String {
        hasSubscriptionAuth ? "Claude Code subscription" : "Claude Code"
    }

    var authDescription: String {
        hasSubscriptionAuth ? "Subscription OAuth" : "Remote Claude Code default auth"
    }
}

struct RemoteCodexProviderScan: Sendable {
    var providers: [RemoteCodexProviderCandidate]
    var configPath: String
    var claude: RemoteClaudeProviderCandidate?
}

enum RemoteCodexProviderDiscovery {
    static func scan(host: String) async throws -> RemoteCodexProviderScan {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            throw SSHRemoteError(message: "Missing SSH host.")
        }

        async let codexText = readRemoteCodexConfig(host: host)
        async let claude = detectRemoteClaude(host: host)
        let text = try await codexText
        let providers = RemoteCodexConfigParser.parse(text)
        return RemoteCodexProviderScan(
            providers: providers,
            configPath: "~/.codex/config.toml",
            claude: try await claude
        )
    }

    private static func readRemoteCodexConfig(host: String) async throws -> String {
        try await Task.detached(priority: .utility) {
            let command = """
            if [ -r "$HOME/.codex/config.toml" ]; then cat "$HOME/.codex/config.toml"; fi
            """
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: SSHRemote.executable)
            proc.arguments = SSHRemote.arguments(
                host: host,
                remoteCommand: command,
                batchMode: true,
                connectTimeout: 8
            )

            let stdout = Pipe()
            let stderr = Pipe()
            proc.standardOutput = stdout
            proc.standardError = stderr

            do {
                try proc.run()
            } catch {
                throw SSHRemoteError(message: error.localizedDescription)
            }
            proc.waitUntilExit()

            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(),
                                    encoding: .utf8) ?? ""
            guard proc.terminationStatus == 0 else {
                let reason = lastNonEmptyLine(stderrText)
                throw SSHRemoteError(message: reason?.isEmpty == false ? reason! : "ssh exited \(proc.terminationStatus)")
            }
            return String(data: data, encoding: .utf8) ?? ""
        }.value
    }

    private static func detectRemoteClaude(host: String) async throws -> RemoteClaudeProviderCandidate? {
        try await Task.detached(priority: .utility) {
            let command = """
            export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
            claude_path="$(command -v claude 2>/dev/null || true)"
            if [ -z "$claude_path" ]; then exit 0; fi
            printf '__HELM_CLAUDE_PATH__%s\\n' "$claude_path"
            if [ -r "$HOME/.claude/.credentials.json" ] && grep -q '"claudeAiOauth"' "$HOME/.claude/.credentials.json"; then
              printf '__HELM_CLAUDE_AUTH__subscription\\n'
            else
              printf '__HELM_CLAUDE_AUTH__default\\n'
            fi
            """
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: SSHRemote.executable)
            proc.arguments = SSHRemote.arguments(
                host: host,
                remoteCommand: command,
                batchMode: true,
                connectTimeout: 8
            )

            let stdout = Pipe()
            let stderr = Pipe()
            proc.standardOutput = stdout
            proc.standardError = stderr

            do {
                try proc.run()
            } catch {
                throw SSHRemoteError(message: error.localizedDescription)
            }
            proc.waitUntilExit()

            let stdoutText = String(data: stdout.fileHandleForReading.readDataToEndOfFile(),
                                    encoding: .utf8) ?? ""
            let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(),
                                    encoding: .utf8) ?? ""
            guard proc.terminationStatus == 0 else {
                let reason = lastNonEmptyLine(stderrText)
                throw SSHRemoteError(message: reason?.isEmpty == false ? reason! : "ssh exited \(proc.terminationStatus)")
            }

            var commandPath = ""
            var hasSubscriptionAuth = false
            for line in stdoutText.split(separator: "\n").map(String.init) {
                if line.hasPrefix("__HELM_CLAUDE_PATH__") {
                    commandPath = String(line.dropFirst("__HELM_CLAUDE_PATH__".count))
                } else if line == "__HELM_CLAUDE_AUTH__subscription" {
                    hasSubscriptionAuth = true
                }
            }
            guard !commandPath.isEmpty else { return nil }
            return RemoteClaudeProviderCandidate(
                commandPath: commandPath,
                hasSubscriptionAuth: hasSubscriptionAuth
            )
        }.value
    }

    private static func lastNonEmptyLine(_ raw: String) -> String? {
        raw.split(separator: "\n", omittingEmptySubsequences: true)
            .last
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum RemoteCodexConfigParser {
    private struct ProviderDraft {
        var key: String
        var name: String = ""
        var baseURL: String = ""
        var wireAPI: Provider.WireAPI = .responses
        var requiresOpenAIAuth: Bool = false
    }

    private struct ProfileDraft {
        var name: String?
        var providerKey: String?
        var modelId: String?
        var reasoningEffort: Profile.ReasoningEffort?
        var serviceTier: Profile.ServiceTier?
        var sandboxMode: Profile.SandboxMode?
    }

    static func parse(_ text: String) -> [RemoteCodexProviderCandidate] {
        var section: [String] = []
        var topLevel: [String: String] = [:]
        var providers: [String: ProviderDraft] = [:]
        var profiles: [String: ProfileDraft] = [:]

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = stripComment(String(rawLine))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("["), line.hasSuffix("]") {
                let inner = String(line.dropFirst().dropLast())
                section = keyPathComponents(inner)
                continue
            }

            guard let (key, rawValue) = splitAssignment(line) else { continue }
            let value = parseScalar(rawValue)

            if section.count == 2, section[0] == "model_providers" {
                let providerKey = section[1]
                var provider = providers[providerKey] ?? ProviderDraft(key: providerKey)
                switch key {
                case "name":
                    provider.name = value
                case "base_url":
                    provider.baseURL = value
                case "wire_api":
                    provider.wireAPI = Provider.WireAPI(rawValue: value) ?? provider.wireAPI
                case "requires_openai_auth":
                    provider.requiresOpenAIAuth = parseBool(rawValue)
                default:
                    break
                }
                providers[providerKey] = provider
            } else if section.count == 2, section[0] == "profiles" {
                let profileName = section[1]
                var profile = profiles[profileName] ?? ProfileDraft(name: profileName)
                switch key {
                case "model_provider":
                    profile.providerKey = value
                case "model":
                    profile.modelId = value
                case "model_reasoning_effort":
                    profile.reasoningEffort = Profile.ReasoningEffort(rawValue: value)
                case "service_tier":
                    profile.serviceTier = Profile.ServiceTier(rawValue: value)
                case "sandbox_mode":
                    profile.sandboxMode = Profile.SandboxMode(rawValue: value)
                default:
                    break
                }
                profiles[profileName] = profile
            } else if section.isEmpty {
                topLevel[key] = value
            }
        }

        for (key, provider) in providers where provider.name.isEmpty {
            providers[key] = ProviderDraft(
                key: provider.key,
                name: key,
                baseURL: provider.baseURL,
                wireAPI: provider.wireAPI,
                requiresOpenAIAuth: provider.requiresOpenAIAuth
            )
        }

        let hasTopLevelCodexConfig = topLevel["model"] != nil ||
            topLevel["model_reasoning_effort"] != nil ||
            topLevel["service_tier"] != nil ||
            topLevel["sandbox_mode"] != nil
        let defaultProviderKey = topLevel["model_provider"] ?? (hasTopLevelCodexConfig ? "" : nil)
        let defaultModel = topLevel["model"]
        var candidatesByProvider: [String: [RemoteCodexProfileCandidate]] = [:]

        if let defaultProviderKey {
            let fallbackName = defaultProviderKey.isEmpty ? "Default Codex provider" : defaultProviderKey
            let provider = providers[defaultProviderKey] ?? ProviderDraft(key: defaultProviderKey, name: fallbackName)
            candidatesByProvider[defaultProviderKey, default: []].append(
                RemoteCodexProfileCandidate(
                    profileName: nil,
                    providerKey: defaultProviderKey,
                    providerName: provider.name.isEmpty ? defaultProviderKey : provider.name,
                    modelId: defaultModel ?? "remote default",
                    reasoningEffort: topLevel["model_reasoning_effort"].flatMap {
                        Profile.ReasoningEffort(rawValue: $0)
                    },
                    serviceTier: topLevel["service_tier"].flatMap {
                        Profile.ServiceTier(rawValue: $0)
                    },
                    sandboxMode: topLevel["sandbox_mode"].flatMap {
                        Profile.SandboxMode(rawValue: $0)
                    }
                )
            )
            if providers[defaultProviderKey] == nil {
                providers[defaultProviderKey] = provider
            }
        }

        for (_, profile) in profiles {
            guard let providerKey = profile.providerKey ?? defaultProviderKey else { continue }
            let fallbackName = providerKey.isEmpty ? "Default Codex provider" : providerKey
            let provider = providers[providerKey] ?? ProviderDraft(key: providerKey, name: fallbackName)
            candidatesByProvider[providerKey, default: []].append(
                RemoteCodexProfileCandidate(
                    profileName: profile.name,
                    providerKey: providerKey,
                    providerName: provider.name.isEmpty ? providerKey : provider.name,
                    modelId: profile.modelId ?? defaultModel ?? "remote default",
                    reasoningEffort: profile.reasoningEffort,
                    serviceTier: profile.serviceTier,
                    sandboxMode: profile.sandboxMode
                )
            )
            if providers[providerKey] == nil {
                providers[providerKey] = provider
            }
        }

        return providers.values
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { provider in
                RemoteCodexProviderCandidate(
                    key: provider.key,
                    name: provider.name,
                    baseURL: provider.baseURL,
                    wireAPI: provider.wireAPI,
                    requiresOpenAIAuth: provider.requiresOpenAIAuth,
                    profiles: (candidatesByProvider[provider.key] ?? [])
                        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
                )
            }
    }

    private static func splitAssignment(_ line: String) -> (String, String)? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let key = line[..<eq].trimmingCharacters(in: .whitespacesAndNewlines)
        let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        return (key, value)
    }

    private static func stripComment(_ line: String) -> String {
        var out = ""
        var quote: Character?
        var escaped = false
        for ch in line {
            if escaped {
                out.append(ch)
                escaped = false
                continue
            }
            if ch == "\\" {
                out.append(ch)
                escaped = true
                continue
            }
            if let q = quote {
                if ch == q { quote = nil }
                out.append(ch)
                continue
            }
            if ch == "\"" || ch == "'" {
                quote = ch
                out.append(ch)
                continue
            }
            if ch == "#" { break }
            out.append(ch)
        }
        return out
    }

    private static func keyPathComponents(_ raw: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for ch in raw {
            if escaped {
                current.append(ch)
                escaped = false
                continue
            }
            if ch == "\\" {
                escaped = true
                continue
            }
            if let q = quote {
                if ch == q {
                    quote = nil
                } else {
                    current.append(ch)
                }
                continue
            }
            if ch == "\"" || ch == "'" {
                quote = ch
                continue
            }
            if ch == "." {
                parts.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
                continue
            }
            current.append(ch)
        }
        parts.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        return parts.filter { !$0.isEmpty }
    }

    private static func parseScalar(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return trimmed }
        let first = trimmed.first
        let last = trimmed.last
        if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            let inner = String(trimmed.dropFirst().dropLast())
            return inner
                .replacingOccurrences(of: #"\""#, with: "\"")
                .replacingOccurrences(of: #"\\n"#, with: "\n")
                .replacingOccurrences(of: #"\\\\"#, with: "\\")
        }
        return trimmed
    }

    private static func parseBool(_ raw: String) -> Bool {
        let value = parseScalar(raw).lowercased()
        return value == "true" || value == "1" || value == "yes"
    }
}
