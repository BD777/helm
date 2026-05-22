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

    var errorDescription: String? {
        switch self {
        case .providerMissing(let id):    return "Profile points to a provider that no longer exists (\(id))."
        case .modelMissing(let id):       return "Profile points to a model that no longer exists (\(id))."
        case .profileVendorMismatch:      return "Profile vendor doesn't match its provider."
        }
    }
}

/// Vendor-aware resolver. Pure function over (Profile, Provider, Model index).
enum RunConfigResolver {
    static func resolve(profile: Profile,
                        session: Session,
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
                                 primary: primary, models: models)
        case .codex:
            return resolveCodex(profile: profile, session: session, provider: provider,
                                primary: primary, models: models)
        }
    }

    // MARK: - Claude

    private static func resolveClaude(profile: Profile,
                                      session: Session,
                                      provider: Provider,
                                      primary: Model,
                                      models: [Model]) -> RunConfig {
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
        if let root = profile.configRoot, !root.isEmpty {
            env["CLAUDE_CONFIG_DIR"] = (root as NSString).expandingTildeInPath
        }
        for (k, v) in provider.extraEnv { env[k] = v }

        // CLI args: --model is also passed for clarity; CLI honors env first
        // but the explicit flag makes the chosen model visible in `ps`.
        var args = ["--model", primary.providerModelId]
        args.append(contentsOf: ["--permission-mode",
                                 session.claudePermissionMode.rawValue])
        args.append(contentsOf: ["--effort", session.claudeEffort.rawValue])
        if let root = profile.configRoot, !root.isEmpty {
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
                                     models: [Model]) -> RunConfig {
        var env: [String: String] = [:]
        if let root = profile.configRoot, !root.isEmpty {
            env["CODEX_HOME"] = (root as NSString).expandingTildeInPath
        }

        var args: [String] = []

        if let delegate = profile.delegateVendorProfile, !delegate.isEmpty {
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
