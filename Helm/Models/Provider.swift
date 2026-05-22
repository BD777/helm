import Foundation

/// A remote endpoint that speaks a vendor's wire protocol. Multiple Models
/// can hang off one Provider — e.g. relay.example.com exposes both
/// `model_hub/es2_orange_o47` and `model_hub/es1_orange_o47`.
struct Provider: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var vendor: Vendor

    /// `ANTHROPIC_BASE_URL` for Claude or `[model_providers.X].base_url` for
    /// Codex. May be empty when the user wants to hit the vendor default.
    var baseURL: String

    /// API token. v1: stored plaintext alongside the JSON file. Future: move
    /// to Keychain and keep only a reference key here.
    var authToken: String

    // MARK: Codex-only

    /// Maps to Codex's `wire_api`. Defaults to .responses.
    var wireAPI: WireAPI

    /// `[model_providers.X].http_headers` — extra outbound HTTP headers for
    /// Codex providers. Empty = no extras.
    var httpHeaders: [String: String]

    /// `requires_openai_auth` — whether Codex should attach the OpenAI auth
    /// header to outgoing requests. Most relay providers want this true.
    var requiresOpenAIAuth: Bool

    // MARK: Claude-only

    /// Extra env vars layered on top of the resolver-generated set.
    /// e.g. `CLAUDE_CODE_AUTO_COMPACT_WINDOW=200000`. Per-tier model envs
    /// are *not* placed here — they're computed from the Profile.
    var extraEnv: [String: String]

    enum WireAPI: String, Codable, CaseIterable, Hashable {
        case responses
        case chat

        var displayName: String {
            switch self {
            case .responses: return "Responses"
            case .chat:      return "Chat completions"
            }
        }
    }

    static func newDefault(vendor: Vendor, name: String) -> Provider {
        Provider(
            id: UUID(),
            name: name,
            vendor: vendor,
            baseURL: "",
            authToken: "",
            wireAPI: .responses,
            httpHeaders: [:],
            requiresOpenAIAuth: vendor == .codex,
            extraEnv: [:]
        )
    }
}

/// One model exposed by a provider. The wire id (`providerModelId`) is what
/// gets sent over the network; `alias` is an optional human-readable label
/// the user picks themselves (e.g. "es2 sonnet 4.6"). Empty alias falls back
/// to the wire id.
struct Model: Identifiable, Hashable, Codable {
    let id: UUID
    var providerId: UUID
    var providerModelId: String
    /// Display label. Empty = render `providerModelId`.
    var alias: String

    /// User-visible label for sidebars / pickers / chat header.
    var label: String {
        alias.isEmpty ? providerModelId : alias
    }

    // Persistence: the v0 schema had `canonical: CanonicalModel` and
    // `displayName: String`. The user opted to drop both — `canonical` was
    // the wrong abstraction, and old `displayName` values would carry stale
    // mappings. Decode silently ignores them.
    private enum CodingKeys: String, CodingKey {
        case id, providerId, providerModelId, alias
    }

    init(id: UUID, providerId: UUID, providerModelId: String, alias: String) {
        self.id = id
        self.providerId = providerId
        self.providerModelId = providerModelId
        self.alias = alias
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.providerId = try c.decode(UUID.self, forKey: .providerId)
        self.providerModelId = try c.decode(String.self, forKey: .providerModelId)
        self.alias = try c.decodeIfPresent(String.self, forKey: .alias) ?? ""
    }
}
