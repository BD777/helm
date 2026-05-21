import Foundation

/// Skeleton for reading Codex's session store at `~/.codex/sessions/...`.
/// Codex sessions are bucketed by date (year/month/day), not by cwd; the
/// `~/.codex/session_index.jsonl` file indexes them with cwd metadata so we
/// can filter to a project. Codex CLI does not currently expose a
/// `--session-id <uuid>` flag for new sessions, so the adapter must capture
/// the vendor-issued id from its event stream and write it back to
/// `Session.vendorSessionId`.
///
/// History parsing and `sessions(for:)` are left as TODO until the Codex
/// adapter is wired up — this file exists so `AgentAdapter.sessionStore` has
/// a concrete impl on the Codex side too, and so the rest of the app doesn't
/// need to special-case the vendor.
final class CodexSessionStore: AgentSessionStore {
    let supportsExplicitSessionId = false

    private let sessionsRoot: URL
    private let indexURL: URL

    init(codexHome: URL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex", isDirectory: true)) {
        self.sessionsRoot = codexHome.appendingPathComponent("sessions",
                                                             isDirectory: true)
        self.indexURL = codexHome.appendingPathComponent("session_index.jsonl",
                                                         isDirectory: false)
    }

    func sessions(for project: Project) async throws -> [VendorSessionRef] {
        // TODO: parse ~/.codex/session_index.jsonl, filter by project's cwd.
        return []
    }

    func history(sessionId: String, project: Project) async throws -> [Message] {
        // TODO: locate the session file under ~/.codex/sessions/<yyyy>/<mm>/<dd>/
        // and translate its event log into our Message[] model.
        return []
    }
}
