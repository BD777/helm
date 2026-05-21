import Foundation

/// A thin reference to a session that lives in some vendor's own session store
/// (`~/.claude/projects/...`, `~/.codex/sessions/...`). Used both to import
/// existing sessions and to display history without copying messages into Helm.
struct VendorSessionRef: Hashable, Identifiable {
    /// Vendor's session uuid string. For Claude this is the file basename.
    var id: String
    var lastUpdate: Date
    var messageCount: Int
    /// First user message excerpt, used as a default title.
    var preview: String
}

/// Vendor-specific glue between Helm's project/session model and where the
/// agent CLI actually keeps its sessions on disk. Each `AgentAdapter` owns one.
protocol AgentSessionStore: AnyObject, Sendable {
    /// Whether `start()` honors a caller-provided session id. Claude CLI does
    /// (`--session-id <uuid>`); Codex does not as of now. When false the
    /// adapter must surface `vendorSessionId` via the event stream so the
    /// host can record it.
    var supportsExplicitSessionId: Bool { get }

    /// Sessions the vendor has on disk for this project's working directory.
    /// Sorted newest-first.
    func sessions(for project: Project) async throws -> [VendorSessionRef]

    /// Parse a single session's persistent log into our transcript model
    /// (messages + runtime events, in order). Returns an empty array if the
    /// file is missing.
    func history(sessionId: String, project: Project) async throws -> [TranscriptItem]
}
