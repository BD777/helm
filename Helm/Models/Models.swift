import AppKit
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

    var isSSH: Bool {
        if case .ssh = self { return true }
        return false
    }

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

    func withSSHStatus(_ status: SSHStatus) -> ProjectLocation {
        switch self {
        case .local:
            return self
        case .ssh(let host, let path, _):
            return .ssh(host: host, path: path, status: status)
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

enum SSHStatus: Hashable, Sendable {
    case connected(path: String)
    case connecting
    case failed(reason: String)

    var color: Color {
        switch self {
        case .connected:  return .green
        case .connecting: return .yellow
        case .failed:     return .red
        }
    }

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var isConnecting: Bool {
        if case .connecting = self { return true }
        return false
    }

    var resolvedPath: String? {
        if case .connected(let path) = self { return path }
        return nil
    }

    var shortLabel: String {
        switch self {
        case .connected: return "SSH"
        case .connecting: return "SSH checking"
        case .failed: return "SSH offline"
        }
    }

    var helpText: String {
        switch self {
        case .connected(let path):
            return path.isEmpty ? "SSH connected" : "SSH connected: \(path)"
        case .connecting:
            return "Checking SSH connection"
        case .failed(let reason):
            return "SSH failed: \(reason)"
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
    /// nil = global/local profile. Non-nil profiles are owned by one SSH
    /// project and never appear in local or other SSH project pickers.
    var sshProjectId: UUID? = nil

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

struct SSHProfileAccessState: Identifiable, Hashable, Codable {
    var projectId: UUID
    var allowedGlobalProfileIds: [UUID]

    var id: UUID { projectId }

    init(projectId: UUID,
         allowedGlobalProfileIds: [UUID] = []) {
        self.projectId = projectId
        self.allowedGlobalProfileIds = allowedGlobalProfileIds
    }
}

/// Claude's `--permission-mode`. One axis covers both "what can be touched"
/// and "when to ask" — Claude doesn't separate them. Mirrored 1:1 to the CLI
/// flag's own values.
enum ClaudePermissionMode: String, CaseIterable, Hashable, Codable {
    case plan
    case defaultMode = "default"
    case acceptEdits
    case bypassPermissions

    var displayName: String {
        switch self {
        case .plan:              return "Plan"
        case .defaultMode:       return "Default"
        case .acceptEdits:       return "Accept edits"
        case .bypassPermissions: return "Bypass"
        }
    }
}

/// Codex's `approval_policy`. The CLI also accepts `untrusted` and a
/// deprecated `on-failure`; we hide both — `on-request` and `never` are the
/// two Codex itself recommends.
enum CodexApprovalMode: String, CaseIterable, Hashable, Codable {
    case onRequest = "on-request"
    case never

    var displayName: String {
        switch self {
        case .onRequest: return "On request"
        case .never:     return "Never"
        }
    }
}

/// Device-level Computer Use setting. The MCP server is a local macOS capability,
/// so it follows the machine, not a profile that may also run over SSH.
enum CodexComputerUseMode: String, CaseIterable, Hashable, Codable, Identifiable {
    case automatic
    case enabled
    case disabled

    static let userDefaultsKey = "codexComputerUseMCPMode"

    var id: Self { self }

    var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .enabled: return "Enabled"
        case .disabled: return "Disabled"
        }
    }

    var helpText: String {
        switch self {
        case .automatic:
            return "Use Codex App's bundled Computer Use MCP for local Codex and Claude sessions when it is installed and startable."
        case .enabled:
            return "Require Computer Use MCP for local Codex and Claude sessions; sending fails if the local bundle is missing or cannot start."
        case .disabled:
            return "Do not attach Computer Use MCP to Helm-launched agent sessions."
        }
    }

    static func stored(in defaults: UserDefaults = .standard) -> Self {
        guard let raw = defaults.string(forKey: userDefaultsKey),
              let mode = Self(rawValue: raw)
        else { return .automatic }
        return mode
    }
}

/// Device-level Return-key shortcut choices for composer actions.
enum MessageSendShortcut: String, CaseIterable, Hashable, Codable, Identifiable {
    case commandReturn = "commandReturn"
    case returnOnly = "return"
    case shiftReturn = "shiftReturn"
    case optionReturn = "optionReturn"
    case controlReturn = "controlReturn"

    static let userDefaultsKey = "messageSendShortcut"
    static let lineBreakUserDefaultsKey = "messageLineBreakShortcut"
    static let defaultValue: Self = .returnOnly
    static let defaultLineBreakValue: Self = .shiftReturn

    private static let returnKeyCodes: Set<UInt16> = [36, 76]
    private static let relevantAppKitModifiers: NSEvent.ModifierFlags = [
        .command, .option, .control, .shift,
    ]

    var id: Self { self }

    var displayName: String {
        switch self {
        case .commandReturn: return "Command Return"
        case .returnOnly: return "Return"
        case .shiftReturn: return "Shift Return"
        case .optionReturn: return "Option Return"
        case .controlReturn: return "Control Return"
        }
    }

    var glyph: String {
        switch self {
        case .commandReturn: return "⌘↵"
        case .returnOnly: return "↵"
        case .shiftReturn: return "⇧↵"
        case .optionReturn: return "⌥↵"
        case .controlReturn: return "⌃↵"
        }
    }

    var eventModifiers: EventModifiers {
        switch self {
        case .commandReturn: return [.command]
        case .returnOnly: return []
        case .shiftReturn: return [.shift]
        case .optionReturn: return [.option]
        case .controlReturn: return [.control]
        }
    }

    var installsButtonShortcut: Bool {
        self != .returnOnly
    }

    private var appKitModifiers: NSEvent.ModifierFlags {
        switch self {
        case .commandReturn: return [.command]
        case .returnOnly: return []
        case .shiftReturn: return [.shift]
        case .optionReturn: return [.option]
        case .controlReturn: return [.control]
        }
    }

    func matches(_ event: NSEvent) -> Bool {
        guard Self.returnKeyCodes.contains(event.keyCode) else { return false }
        let flags = event.modifierFlags.intersection(Self.relevantAppKitModifiers)
        return flags == appKitModifiers
    }

    static func normalized(_ rawValue: String) -> Self {
        Self(rawValue: rawValue) ?? defaultValue
    }

    static func normalizedLineBreak(_ rawValue: String, sendShortcut: Self) -> Self {
        let shortcut = Self(rawValue: rawValue) ?? defaultLineBreakValue
        guard shortcut == sendShortcut else { return shortcut }
        return fallback(avoiding: sendShortcut,
                        preferred: defaultLineBreakValue,
                        defaultValue: defaultLineBreakValue)
    }

    static func fallback(avoiding reserved: Self,
                         preferred: Self?,
                         defaultValue: Self) -> Self {
        if let preferred, preferred != reserved {
            return preferred
        }
        if defaultValue != reserved {
            return defaultValue
        }
        return allCases.first { $0 != reserved } ?? .commandReturn
    }

    static func stored(in defaults: UserDefaults = .standard) -> Self {
        guard let raw = defaults.string(forKey: userDefaultsKey) else {
            return defaultValue
        }
        return normalized(raw)
    }
}

struct MessageSendKeyboardShortcutModifier: ViewModifier {
    let shortcut: MessageSendShortcut

    @ViewBuilder
    func body(content: Content) -> some View {
        if shortcut.installsButtonShortcut {
            content.keyboardShortcut(.return, modifiers: shortcut.eventModifiers)
        } else {
            content
        }
    }
}

extension View {
    func messageSendKeyboardShortcut(_ shortcut: MessageSendShortcut) -> some View {
        modifier(MessageSendKeyboardShortcutModifier(shortcut: shortcut))
    }
}

/// Claude's `--effort` flag. Five levels — `max` is unique to Claude; Codex's
/// `model_reasoning_effort` tops out at `xhigh`.
enum ClaudeEffort: String, CaseIterable, Hashable, Codable {
    case low, medium, high, xhigh, max

    var displayName: String {
        switch self {
        case .low:    return "Low"
        case .medium: return "Medium"
        case .high:   return "High"
        case .xhigh:  return "Xhigh"
        case .max:    return "Max"
        }
    }
}

struct Session: Identifiable, Hashable, Codable {
    let id: UUID
    var projectId: UUID
    var title: String
    /// Profile bound to this session. UI resolves it via AppStore.
    var profileId: UUID
    /// Claude's single-axis permission knob. Used only when the session's
    /// profile vendor is Claude — left at default otherwise.
    var claudePermissionMode: ClaudePermissionMode = .defaultMode
    /// Codex sandbox scope. Reuses `Profile.SandboxMode` since the values are
    /// the same set; profile-level field stays `Optional` (its nil = "no
    /// override"), session-level always carries a concrete value.
    var codexSandboxMode: Profile.SandboxMode = .workspace
    /// Codex approval policy. Used only for Codex sessions.
    var codexApprovalMode: CodexApprovalMode = .onRequest
    /// Claude reasoning effort (`--effort`). Used only for Claude sessions.
    var claudeEffort: ClaudeEffort = .medium
    /// Codex reasoning effort (`model_reasoning_effort`). Reuses
    /// `Profile.ReasoningEffort` since the values are the same set.
    var codexEffort: Profile.ReasoningEffort = .medium
    var lastUpdate: String
    /// Ordered transcript: real dialog turns (`.message`) interleaved with
    /// runtime events (`.event` — compact summaries, etc). See [[TranscriptItem]].
    var transcript: [TranscriptItem] = []
    /// Vendor-issued session id (e.g. Claude CLI `--session-id`). nil until
    /// the agent emits its init event; used to resume across restarts.
    var vendorSessionId: String? = nil
    /// True between "user clicked New chat" and "user sent the first message".
    /// Drafts are hidden from the sidebar and excluded from state.json so an
    /// accidental click doesn't litter persistent state with empty rows.
    var isDraft: Bool = false

    // Persistence: transcript items live in the vendor's own session log
    // (~/.claude/projects/...) and isDraft is transient by design — both are
    // skipped from Codable. The three vendor-native chip fields persist so
    // the user's picks survive restart. See [[helm-storage]] for layering.
    private enum CodingKeys: String, CodingKey {
        case id, projectId, title, profileId, lastUpdate, vendorSessionId,
             claudePermissionMode, codexSandboxMode, codexApprovalMode,
             claudeEffort, codexEffort
    }

    init(id: UUID, projectId: UUID, title: String, profileId: UUID,
         claudePermissionMode: ClaudePermissionMode = .defaultMode,
         codexSandboxMode: Profile.SandboxMode = .workspace,
         codexApprovalMode: CodexApprovalMode = .onRequest,
         claudeEffort: ClaudeEffort = .medium,
         codexEffort: Profile.ReasoningEffort = .medium,
         lastUpdate: String,
         transcript: [TranscriptItem] = [], vendorSessionId: String? = nil,
         isDraft: Bool = false) {
        self.id = id
        self.projectId = projectId
        self.title = title
        self.profileId = profileId
        self.claudePermissionMode = claudePermissionMode
        self.codexSandboxMode = codexSandboxMode
        self.codexApprovalMode = codexApprovalMode
        self.claudeEffort = claudeEffort
        self.codexEffort = codexEffort
        self.lastUpdate = lastUpdate
        self.transcript = transcript
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
        self.claudePermissionMode = try c.decodeIfPresent(ClaudePermissionMode.self, forKey: .claudePermissionMode) ?? .defaultMode
        self.codexSandboxMode = try c.decodeIfPresent(Profile.SandboxMode.self, forKey: .codexSandboxMode) ?? .workspace
        self.codexApprovalMode = try c.decodeIfPresent(CodexApprovalMode.self, forKey: .codexApprovalMode) ?? .onRequest
        self.claudeEffort = try c.decodeIfPresent(ClaudeEffort.self, forKey: .claudeEffort) ?? .medium
        self.codexEffort = try c.decodeIfPresent(Profile.ReasoningEffort.self, forKey: .codexEffort) ?? .medium
        self.transcript = []
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
        try c.encode(claudePermissionMode, forKey: .claudePermissionMode)
        try c.encode(codexSandboxMode, forKey: .codexSandboxMode)
        try c.encode(codexApprovalMode, forKey: .codexApprovalMode)
        try c.encode(claudeEffort, forKey: .claudeEffort)
        try c.encode(codexEffort, forKey: .codexEffort)
    }
}

struct SessionRunConfiguration: Hashable {
    var claudePermissionMode: ClaudePermissionMode
    var codexSandboxMode: Profile.SandboxMode
    var codexApprovalMode: CodexApprovalMode
    var claudeEffort: ClaudeEffort
    var codexEffort: Profile.ReasoningEffort

    init(claudePermissionMode: ClaudePermissionMode = .defaultMode,
         codexSandboxMode: Profile.SandboxMode = .workspace,
         codexApprovalMode: CodexApprovalMode = .onRequest,
         claudeEffort: ClaudeEffort = .medium,
         codexEffort: Profile.ReasoningEffort = .medium) {
        self.claudePermissionMode = claudePermissionMode
        self.codexSandboxMode = codexSandboxMode
        self.codexApprovalMode = codexApprovalMode
        self.claudeEffort = claudeEffort
        self.codexEffort = codexEffort
    }

    static func defaults(for profile: Profile) -> SessionRunConfiguration {
        SessionRunConfiguration(
            codexSandboxMode: profile.sandboxMode ?? .workspace,
            codexEffort: profile.reasoningEffort ?? .medium
        )
    }
}

struct SidebarSession: Identifiable, Hashable {
    let id: UUID
    var projectId: UUID
    var title: String
    var profileId: UUID
    var vendorSessionId: String?

    init(_ session: Session) {
        self.id = session.id
        self.projectId = session.projectId
        self.title = session.title
        self.profileId = session.profileId
        self.vendorSessionId = session.vendorSessionId
    }
}

enum ProjectSchedulerTaskPhase: String, CaseIterable, Hashable, Codable, Identifiable {
    case planned
    case running
    case waiting
    case needsReview
    case readyToMerge
    case done

    var id: Self { self }

    var displayName: String {
        switch self {
        case .planned: return "Planned"
        case .running: return "Running"
        case .waiting: return "Waiting"
        case .needsReview: return "Waiting"
        case .readyToMerge: return "Waiting"
        case .done: return "Done"
        }
    }

    var symbolName: String {
        switch self {
        case .planned: return "list.bullet.rectangle"
        case .running: return "play.circle"
        case .waiting: return "hourglass"
        case .needsReview: return "person.crop.circle.badge.exclamationmark"
        case .readyToMerge: return "arrow.triangle.merge"
        case .done: return "checkmark.circle"
        }
    }
}

enum ProjectSchedulerInboxStatus: String, Hashable, Codable {
    case planned
    case accepted
    case archived
}

enum ProjectSchedulerHumanActionKind: String, Hashable, Codable {
    case startTask
    case reviewResult
    case answerQuestion
    case resolveConflict
    case approveMerge
    case inspectFailure

    var displayName: String {
        switch self {
        case .startTask: return "Start"
        case .reviewResult: return "Review"
        case .answerQuestion: return "Answer"
        case .resolveConflict: return "Resolve"
        case .approveMerge: return "Approve"
        case .inspectFailure: return "Inspect"
        }
    }

    var symbolName: String {
        switch self {
        case .startTask: return "play"
        case .reviewResult: return "checklist"
        case .answerQuestion: return "questionmark.bubble"
        case .resolveConflict: return "exclamationmark.triangle"
        case .approveMerge: return "arrow.triangle.merge"
        case .inspectFailure: return "stethoscope"
        }
    }
}

struct ProjectSchedulerInboxItem: Identifiable, Hashable, Codable {
    let id: UUID
    var text: String
    var createdAt: Date
    var status: ProjectSchedulerInboxStatus
    var taskId: UUID?
}

struct ProjectSchedulerTask: Identifiable, Hashable, Codable {
    let id: UUID
    var title: String
    var idea: String
    var displayParts: [Part]? = nil
    var attachments: [ImageAttachment]? = nil
    var sessionId: UUID?
    var phase: ProjectSchedulerTaskPhase
    var summary: String
    var dependencies: [UUID]
    var resourceNotes: [String]
    var worktreeHint: String?
    var createdAt: Date
    var updatedAt: Date
}

struct ProjectSchedulerHumanAction: Identifiable, Hashable, Codable {
    let id: UUID
    var taskId: UUID?
    var kind: ProjectSchedulerHumanActionKind
    var title: String
    var detail: String
    var createdAt: Date
    var resolvedAt: Date?

    var isResolved: Bool { resolvedAt != nil }
}

struct ProjectSchedulerState: Identifiable, Hashable, Codable {
    var projectId: UUID
    var defaultWorkerProfileId: UUID?
    var inbox: [ProjectSchedulerInboxItem]
    var tasks: [ProjectSchedulerTask]
    var humanActions: [ProjectSchedulerHumanAction]
    var updatedAt: Date

    var id: UUID { projectId }

    init(projectId: UUID,
         defaultWorkerProfileId: UUID? = nil,
         inbox: [ProjectSchedulerInboxItem] = [],
         tasks: [ProjectSchedulerTask] = [],
         humanActions: [ProjectSchedulerHumanAction] = [],
         updatedAt: Date = Date()) {
        self.projectId = projectId
        self.defaultWorkerProfileId = defaultWorkerProfileId
        self.inbox = inbox
        self.tasks = tasks
        self.humanActions = humanActions
        self.updatedAt = updatedAt
    }
}

struct Message: Identifiable, Hashable, Codable {
    let id: UUID
    enum Role: Hashable, Codable { case user, assistant(meta: String) }
    var role: Role
    var who: String
    var meta: String?
    var parts: [Part]
}

/// One item in a session's ordered transcript. Either a real dialog turn
/// (`.message`) or a runtime event (`.event` — compact summary, model
/// switch, etc). Events have no sender or parts; they render as inline
/// markers, not chat bubbles. Modeled as a sum at the top so adding a new
/// event kind forces every renderer/transformer to opt in.
enum TranscriptItem: Identifiable, Hashable, Codable {
    case message(Message)
    case event(SessionEvent)

    var id: UUID {
        switch self {
        case .message(let m): return m.id
        case .event(let e):   return e.id
        }
    }

    /// Convenience for code paths that need the dialog turn (sidebar
    /// preview, ordinal counters, streaming mutators). Events return nil.
    var message: Message? {
        if case .message(let m) = self { return m }
        return nil
    }
}

/// A non-dialog runtime event written into the transcript by the agent or by
/// Helm itself when it needs to acknowledge session-level runtime state.
enum SessionEvent: Identifiable, Hashable, Codable {
    /// Claude wrote a context-compaction summary. The model treats it as a
    /// user-role message internally, but to the human it's just "we hit the
    /// limit and the prior conversation was summarized." `summary` is the
    /// raw text Claude generated — useful if the user wants to inspect it.
    case compactSummary(id: UUID, summary: String)
    /// Helm sent a composer turn through the Goal action. This is a
    /// deterministic UI acknowledgement, not a model-generated message.
    case goalApplied(id: UUID, goal: String, vendor: Vendor, appliedAt: Date)

    var id: UUID {
        switch self {
        case .compactSummary(let id, _): return id
        case .goalApplied(let id, _, _, _): return id
        }
    }
}

enum Part: Hashable, Identifiable, Codable {
    case text(String)
    case skillText([SkillTextSegment])
    case toolCall(ToolCall)
    /// Local file URL for an image attached to a user message. We store the
    /// path (not bytes) so state.json / RAM stay small; the file lives under
    /// `AppPaths.imagesDir(for:)`.
    case image(URL)

    var id: String {
        switch self {
        case .text(let s):     return "t:" + String(s.hashValue)
        case .skillText(let segments):
            return "s:" + String(segments.hashValue)
        case .toolCall(let t): return "c:" + t.id.uuidString
        case .image(let u):    return "i:" + u.lastPathComponent
        }
    }
}

struct SkillTextSegment: Hashable, Codable {
    var text: String?
    var skillName: String?

    static func text(_ value: String) -> SkillTextSegment {
        SkillTextSegment(text: value, skillName: nil)
    }

    static func skill(_ name: String) -> SkillTextSegment {
        SkillTextSegment(text: nil, skillName: name)
    }
}

/// Composer-side or scheduler-side reference to a pasted image. Points at an
/// already-on-disk file so Send doesn't have to re-encode bytes.
/// `contentHash` is the hex MD5 of the PNG payload — used for dedupe so
/// pasting the same image twice doesn't add a second thumbnail.
struct ImageAttachment: Identifiable, Hashable, Codable {
    let id: UUID
    let fileURL: URL
    let mediaType: String   // "image/png" | "image/jpeg" | "image/gif" | "image/webp"
    let contentHash: String

    init(id: UUID = UUID(), fileURL: URL, mediaType: String, contentHash: String) {
        self.id = id
        self.fileURL = fileURL
        self.mediaType = mediaType
        self.contentHash = contentHash
    }
}

struct ToolCall: Hashable, Identifiable, Codable {
    let id: UUID
    var name: String
    var arg: String
    var status: Status
    var meta: String?
    var body: String?

    enum Status: Hashable, Codable {
        case ok(exit: Int)
        case error(exit: Int)
        case running
        case stopped
    }
}
