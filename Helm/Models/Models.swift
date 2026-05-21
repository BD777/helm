import SwiftUI

enum Vendor: String, CaseIterable, Codable, Hashable {
    case claude
    case codex

    var shortLabel: String {
        switch self {
        case .claude: return "CC"
        case .codex:  return "Cx"
        }
    }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex:  return "Codex"
        }
    }

    var badgeColor: Color {
        switch self {
        case .claude: return Color(red: 0.85, green: 0.45, blue: 0.04)
        case .codex:  return Color(red: 0.18, green: 0.22, blue: 0.28)
        }
    }
}

enum ProjectLocation: Hashable, Codable {
    case local(path: String)
    case ssh(host: String, path: String, status: SSHStatus)

    var pathString: String {
        switch self {
        case .local(let p): return p
        case .ssh(_, let p, _): return p
        }
    }

    var subtitle: String {
        switch self {
        case .local: return "local"
        case .ssh(let host, _, _): return "ssh \(host)"
        }
    }

    // Persistence: encode the path/host but NOT the SSHStatus (it's runtime
    // state that gets recomputed on connect). On decode, ssh sessions come
    // back as .connecting until the SSH adapter probes.
    private enum CodingKeys: String, CodingKey { case kind, path, host }
    private enum Kind: String, Codable { case local, ssh }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        let path = try c.decode(String.self, forKey: .path)
        switch kind {
        case .local:
            self = .local(path: path)
        case .ssh:
            let host = try c.decode(String.self, forKey: .host)
            self = .ssh(host: host, path: path, status: .connecting)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .local(let p):
            try c.encode(Kind.local, forKey: .kind)
            try c.encode(p, forKey: .path)
        case .ssh(let host, let path, _):
            try c.encode(Kind.ssh, forKey: .kind)
            try c.encode(host, forKey: .host)
            try c.encode(path, forKey: .path)
        }
    }
}

enum SSHStatus: Hashable {
    case connected
    case connecting
    case failed(reason: String)

    var color: Color {
        switch self {
        case .connected:  return .green
        case .connecting: return .yellow
        case .failed:     return .red
        }
    }
}

/// A named run-config: which provider to talk to, which model to use, plus
/// per-vendor knobs. The UI uses Profile as the unit a session binds to;
/// the resolver expands it to env + CLI args at spawn time.
struct Profile: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var vendor: Vendor

    var providerId: UUID
    /// Primary model id (UUID into the Models table). For Claude, this also
    /// fills any tier override that's left nil.
    var primaryModelId: UUID

    /// Optional override for the executable. Empty = bare command.
    var commandPath: String
    /// Optional `--config-dir` / `CODEX_HOME` override. nil = vendor default.
    var configRoot: String?

    // Claude-only — per-tier overrides. nil = inherit from primary.
    var opusModelId: UUID?
    var sonnetModelId: UUID?
    var haikuModelId: UUID?
    var subagentModelId: UUID?
    /// Sent as `CLAUDE_CODE_AUTO_COMPACT_WINDOW`. nil = leave to vendor.
    var autoCompactWindow: Int?

    // Codex-only — knobs the resolver turns into `-c key=value`.
    var reasoningEffort: ReasoningEffort?
    var serviceTier: ServiceTier?
    var sandboxMode: SandboxMode?
    /// If non-nil, spawn `codex --profile X` and let codex resolve its own
    /// `[profiles.X]`. The other Codex-only fields are then ignored.
    var delegateVendorProfile: String?

    enum ReasoningEffort: String, Codable, CaseIterable, Hashable {
        case low, medium, high, xhigh
        var displayName: String { rawValue.capitalized }
    }
    enum ServiceTier: String, Codable, CaseIterable, Hashable {
        case auto, fast
        var displayName: String { rawValue.capitalized }
    }
    enum SandboxMode: String, Codable, CaseIterable, Hashable {
        case workspace = "workspace-write"
        case readOnly = "read-only"
        case dangerFullAccess = "danger-full-access"
        var displayName: String { rawValue }
    }

    /// Bare command name to use when `commandPath` is empty.
    var resolvedCommand: String {
        commandPath.isEmpty ? Profile.defaultCommand(for: vendor) : commandPath
    }

    static func defaultCommand(for vendor: Vendor) -> String {
        switch vendor {
        case .claude: return "claude"
        case .codex:  return "codex"
        }
    }
}

struct Project: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var location: ProjectLocation
    var collapsed: Bool = false
}

enum ApprovalMode: String, CaseIterable, Hashable {
    case readOnly = "Read-only"
    case ask = "Ask"
    case auto = "Auto"
}

struct Session: Identifiable, Hashable, Codable {
    let id: UUID
    var projectId: UUID
    var title: String
    /// Profile bound to this session. UI resolves it via AppStore.
    var profileId: UUID
    var approvalMode: ApprovalMode = .ask
    var lastUpdate: String
    var messages: [Message] = []
    /// Vendor-issued session id (e.g. Claude CLI `--session-id`). nil until
    /// the agent emits its init event; used to resume across restarts.
    var vendorSessionId: String? = nil
    /// True between "user clicked New chat" and "user sent the first message".
    /// Drafts are hidden from the sidebar and excluded from state.json so an
    /// accidental click doesn't litter persistent state with empty rows.
    var isDraft: Bool = false

    // Persistence: messages live in the vendor's own session log
    // (~/.claude/projects/...), approvalMode is runtime UI state, and
    // isDraft is transient by design — all three are skipped from Codable.
    // See [[helm-storage]] for the layering.
    private enum CodingKeys: String, CodingKey {
        case id, projectId, title, profileId, lastUpdate, vendorSessionId
    }

    init(id: UUID, projectId: UUID, title: String, profileId: UUID,
         approvalMode: ApprovalMode = .ask, lastUpdate: String,
         messages: [Message] = [], vendorSessionId: String? = nil,
         isDraft: Bool = false) {
        self.id = id
        self.projectId = projectId
        self.title = title
        self.profileId = profileId
        self.approvalMode = approvalMode
        self.lastUpdate = lastUpdate
        self.messages = messages
        self.vendorSessionId = vendorSessionId
        self.isDraft = isDraft
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.projectId = try c.decode(UUID.self, forKey: .projectId)
        self.title = try c.decode(String.self, forKey: .title)
        self.profileId = try c.decode(UUID.self, forKey: .profileId)
        self.lastUpdate = try c.decode(String.self, forKey: .lastUpdate)
        self.vendorSessionId = try c.decodeIfPresent(String.self, forKey: .vendorSessionId)
        self.approvalMode = .ask
        self.messages = []
        self.isDraft = false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(projectId, forKey: .projectId)
        try c.encode(title, forKey: .title)
        try c.encode(profileId, forKey: .profileId)
        try c.encode(lastUpdate, forKey: .lastUpdate)
        try c.encodeIfPresent(vendorSessionId, forKey: .vendorSessionId)
    }
}

struct Message: Identifiable, Hashable {
    let id: UUID
    enum Role: Hashable { case user, assistant(meta: String) }
    var role: Role
    var who: String
    var meta: String?
    var parts: [Part]
}

enum Part: Hashable, Identifiable {
    case text(String)
    case toolCall(ToolCall)

    var id: String {
        switch self {
        case .text(let s):     return "t:" + String(s.hashValue)
        case .toolCall(let t): return "c:" + t.id.uuidString
        }
    }
}

struct ToolCall: Hashable, Identifiable {
    let id: UUID
    var name: String
    var arg: String
    var status: Status
    var meta: String?
    var body: String?

    enum Status: Hashable {
        case ok(exit: Int)
        case error(exit: Int)
        case running
    }
}
