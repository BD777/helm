import Foundation

/// Persisted runtime state — projects + sessions + selection. Sits next to
/// `profiles.json` (configuration) under `~/Library/Application Support/dev.deng.helm/`.
/// Configuration vs. runtime state are split so profiles can be exported /
/// imported independently and so future SwiftData migration only touches this
/// file (where session/message rows will eventually accumulate).
struct AppStateFile: Codable {
    var version: Int
    var projects: [Project]
    var sessions: [Session]
    var selectedSessionId: UUID?
    var selectedProjectId: UUID?
    var schedulers: [ProjectSchedulerState]
    var sshProfileAccess: [SSHProfileAccessState]

    static let currentVersion = 3
    static let empty = AppStateFile(version: currentVersion,
                                    projects: [],
                                    sessions: [],
                                    selectedSessionId: nil,
                                    selectedProjectId: nil,
                                    schedulers: [],
                                    sshProfileAccess: [])

    private enum CodingKeys: String, CodingKey {
        case version, projects, sessions, selectedSessionId,
             selectedProjectId, schedulers, sshProfileAccess
    }

    init(version: Int,
         projects: [Project],
         sessions: [Session],
         selectedSessionId: UUID?,
         selectedProjectId: UUID?,
         schedulers: [ProjectSchedulerState],
         sshProfileAccess: [SSHProfileAccessState] = []) {
        self.version = version
        self.projects = projects
        self.sessions = sessions
        self.selectedSessionId = selectedSessionId
        self.selectedProjectId = selectedProjectId
        self.schedulers = schedulers
        self.sshProfileAccess = sshProfileAccess
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try c.decode(Int.self, forKey: .version)
        self.projects = try c.decode([Project].self, forKey: .projects)
        self.sessions = try c.decode([Session].self, forKey: .sessions)
        self.selectedSessionId = try c.decodeIfPresent(UUID.self, forKey: .selectedSessionId)
        self.selectedProjectId = try c.decodeIfPresent(UUID.self, forKey: .selectedProjectId)
        self.schedulers = try c.decodeIfPresent([ProjectSchedulerState].self,
                                                forKey: .schedulers) ?? []
        self.sshProfileAccess = try c.decodeIfPresent([SSHProfileAccessState].self,
                                                       forKey: .sshProfileAccess) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(projects, forKey: .projects)
        try c.encode(sessions, forKey: .sessions)
        try c.encodeIfPresent(selectedSessionId, forKey: .selectedSessionId)
        try c.encodeIfPresent(selectedProjectId, forKey: .selectedProjectId)
        try c.encode(schedulers, forKey: .schedulers)
        try c.encode(sshProfileAccess, forKey: .sshProfileAccess)
    }
}

/// Synchronous load + debounced save of the runtime state file. App lifetime;
/// one instance owned by `AppStore` (parallel to `ProfileStore`).
final class StateStore: @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "dev.deng.helm.statestore")
    private var pendingWork: DispatchWorkItem?

    /// Called on the main thread after a successful write.
    var onSaved: (@Sendable () -> Void)?

    init(url: URL = StateStore.defaultURL()) {
        self.url = url
    }

    static func defaultURL() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("dev.deng.helm", isDirectory: true)
            .appendingPathComponent("state.json")
    }

    func load() -> AppStateFile {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .empty
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(AppStateFile.self, from: data)
        } catch {
            NSLog("[helm.state] load failed: %@ — falling back to empty",
                  error.localizedDescription)
            return .empty
        }
    }

    /// Schedule a write 200ms in the future, coalescing rapid edits.
    func scheduleSave(_ snapshot: AppStateFile) {
        pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.write(snapshot) }
        pendingWork = work
        queue.asyncAfter(deadline: .now() + .milliseconds(200), execute: work)
    }

    /// Synchronous flush — used on app shutdown to make sure any in-flight
    /// debounced write actually lands.
    func flush(_ snapshot: AppStateFile) {
        pendingWork?.cancel()
        pendingWork = nil
        queue.sync { write(snapshot) }
    }

    private func write(_ snapshot: AppStateFile) {
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            let tmp = url.appendingPathExtension("tmp")
            try data.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
            NSLog("[helm.state] saved %d projects / %d sessions",
                  snapshot.projects.count, snapshot.sessions.count)
            if let cb = onSaved {
                DispatchQueue.main.async { cb() }
            }
        } catch {
            NSLog("[helm.state] save failed: %@", error.localizedDescription)
        }
    }
}

private struct TranscriptSnapshotFile: Codable {
    var version: Int
    var sessionId: UUID
    var updatedAt: Date
    var items: [TranscriptItem]

    static let currentVersion = 1
}

enum TranscriptSnapshotStore {
    static func exists(sessionId: UUID) -> Bool {
        FileManager.default.fileExists(atPath: AppPaths.transcriptSnapshotURL(for: sessionId).path)
    }

    static func load(sessionId: UUID) -> [TranscriptItem] {
        let url = AppPaths.transcriptSnapshotURL(for: sessionId)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            let file = try JSONDecoder().decode(TranscriptSnapshotFile.self, from: data)
            return file.items
        } catch {
            NSLog("[helm.transcript] load failed for %@: %@",
                  sessionId.uuidString, error.localizedDescription)
            return []
        }
    }

    static func save(sessionId: UUID, items: [TranscriptItem]) {
        guard !items.isEmpty else {
            delete(sessionId: sessionId)
            return
        }
        let url = AppPaths.transcriptSnapshotURL(for: sessionId)
        do {
            let file = TranscriptSnapshotFile(version: TranscriptSnapshotFile.currentVersion,
                                              sessionId: sessionId,
                                              updatedAt: Date(),
                                              items: items)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(file)
            try data.write(to: url, options: .atomic)
            NSLog("[helm.transcript] saved %ld items for %@",
                  items.count, sessionId.uuidString)
        } catch {
            NSLog("[helm.transcript] save failed for %@: %@",
                  sessionId.uuidString, error.localizedDescription)
        }
    }

    static func delete(sessionId: UUID) {
        let url = AppPaths.transcriptSnapshotURL(for: sessionId)
        try? FileManager.default.removeItem(at: url)
    }
}

enum TargetSessionIndexLocation: Hashable {
    case local
    case ssh(host: String)
}

struct TargetSessionIndexEntry: Codable, Hashable, Identifiable {
    var id: UUID
    var projectPath: String
    var projectName: String
    var vendor: Vendor
    var title: String
    var lastUpdate: String
    var updatedAt: String
    var vendorSessionId: String
    var profileName: String
    var claudePermissionMode: ClaudePermissionMode
    var codexSandboxMode: Profile.SandboxMode
    var codexApprovalMode: CodexApprovalMode
    var claudeEffort: ClaudeEffort
    var codexEffort: Profile.ReasoningEffort
}

struct TargetSessionIndexFile: Codable {
    var version: Int
    var updatedAt: String
    var sessions: [TargetSessionIndexEntry]

    static let currentVersion = 1
    static let empty = TargetSessionIndexFile(version: currentVersion,
                                              updatedAt: TargetSessionIndexStore.timestamp(),
                                              sessions: [])
}

private struct TargetSessionIndexDeletionPayload: Encodable {
    var updatedAt: String
    var ids: [UUID]
}

/// Small target-machine mirror of Helm-owned session metadata.
///
/// Helm's full app state stays in the macOS app-support state file. This index
/// only mirrors enough information to show/rebind restorable sessions when a
/// different client connects to the same local or SSH target.
enum TargetSessionIndexStore {
    static func localURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".helm", isDirectory: true)
            .appendingPathComponent("sessions.json", isDirectory: false)
    }

    static func timestamp(_ date: Date = Date()) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    static func canonicalProjectPath(for project: Project) -> String {
        switch project.location {
        case .local(let path):
            return normalizedLocalPath(path)
        case .ssh(_, let path, let status):
            return normalizedRemotePath(status.resolvedPath ?? path)
        }
    }

    static func projectPathCandidates(for project: Project) -> Set<String> {
        switch project.location {
        case .local(let path):
            return Set([path, normalizedLocalPath(path)])
        case .ssh(_, let path, let status):
            var values = Set([path, normalizedRemotePath(path)])
            if let resolved = status.resolvedPath, !resolved.isEmpty {
                values.insert(resolved)
                values.insert(normalizedRemotePath(resolved))
            }
            return values
        }
    }

    static func targetLocation(for project: Project) -> TargetSessionIndexLocation? {
        switch project.location {
        case .local:
            return .local
        case .ssh(let host, _, let status):
            guard status.isConnected else { return nil }
            return .ssh(host: host)
        }
    }

    static func loadLocal() -> TargetSessionIndexFile {
        decodeFile(at: localURL())
    }

    static func loadRemote(host: String) async throws -> TargetSessionIndexFile {
        let command = """
        file="$HOME/.helm/sessions.json"
        if [ -f "$file" ]; then cat -- "$file"; fi
        """
        let data = try await sshOutput(host: host, remoteCommand: command)
        guard !data.isEmpty else { return .empty }
        return try decode(data)
    }

    static func upsert(_ entriesByTarget: [TargetSessionIndexLocation: [TargetSessionIndexEntry]]) async {
        for (target, entries) in entriesByTarget where !entries.isEmpty {
            do {
                switch target {
                case .local:
                    try upsertLocal(entries)
                case .ssh(let host):
                    try await upsertRemote(host: host, entries: entries)
                }
            } catch {
                NSLog("[helm.target-sessions] save failed: %@", error.localizedDescription)
            }
        }
    }

    static func remove(_ idsByTarget: [TargetSessionIndexLocation: [UUID]]) async {
        for (target, ids) in idsByTarget where !ids.isEmpty {
            do {
                switch target {
                case .local:
                    try removeLocal(ids)
                case .ssh(let host):
                    try await removeRemote(host: host, ids: ids)
                }
            } catch {
                NSLog("[helm.target-sessions] delete failed: %@", error.localizedDescription)
            }
        }
    }

    static func upsertLocal(_ entries: [TargetSessionIndexEntry]) throws {
        let url = localURL()
        let existing = decodeFile(at: url)
        let merged = merge(existing: existing, entries: entries)
        try write(merged, to: url)
    }

    static func upsertRemote(host: String, entries: [TargetSessionIndexEntry]) async throws {
        let payload = TargetSessionIndexFile(version: TargetSessionIndexFile.currentVersion,
                                             updatedAt: timestamp(),
                                             sessions: entries)
        let data = try encode(payload)
        let script = #"""
import json
import os
import sys

path = os.path.expanduser("~/.helm/sessions.json")
payload = json.load(sys.stdin)
try:
    with open(path, "r", encoding="utf-8") as handle:
        existing = json.load(handle)
except Exception:
    existing = {}

sessions = existing.get("sessions", [])
if not isinstance(sessions, list):
    sessions = []

by_id = {}
for item in sessions:
    if isinstance(item, dict) and item.get("id"):
        by_id[str(item["id"])] = item

for item in payload.get("sessions", []):
    if isinstance(item, dict) and item.get("id"):
        by_id[str(item["id"])] = item

out = dict(existing) if isinstance(existing, dict) else {}
out["version"] = 1
out["updatedAt"] = payload.get("updatedAt", "")
out["sessions"] = sorted(
    by_id.values(),
    key=lambda item: str(item.get("updatedAt") or ""),
    reverse=True,
)

os.makedirs(os.path.dirname(path), exist_ok=True)
tmp = f"{path}.tmp.{os.getpid()}"
with open(tmp, "w", encoding="utf-8") as handle:
    json.dump(out, handle, indent=2, sort_keys=True)
    handle.write("\n")
os.replace(tmp, path)
"""#
        let command = """
        py=$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)
        if [ -z "$py" ]; then echo "python not found" >&2; exit 127; fi
        "$py" -c \(SSHRemote.shellQuote(script))
        """
        try await sshInput(host: host, remoteCommand: command, input: data)
    }

    static func removeLocal(_ ids: [UUID]) throws {
        let url = localURL()
        let existing = decodeFile(at: url)
        let idSet = Set(ids)
        let updated = TargetSessionIndexFile(
            version: TargetSessionIndexFile.currentVersion,
            updatedAt: timestamp(),
            sessions: existing.sessions.filter { !idSet.contains($0.id) }
        )
        try write(updated, to: url)
    }

    static func removeRemote(host: String, ids: [UUID]) async throws {
        let payload = TargetSessionIndexDeletionPayload(updatedAt: timestamp(), ids: ids)
        let data = try encode(payload)
        let script = #"""
import json
import os
import sys

path = os.path.expanduser("~/.helm/sessions.json")
payload = json.load(sys.stdin)
ids = set(str(item) for item in payload.get("ids", []))
try:
    with open(path, "r", encoding="utf-8") as handle:
        existing = json.load(handle)
except Exception:
    existing = {}

sessions = existing.get("sessions", [])
if not isinstance(sessions, list):
    sessions = []

out = dict(existing) if isinstance(existing, dict) else {}
out["version"] = 1
out["updatedAt"] = payload.get("updatedAt", "")
out["sessions"] = [
    item for item in sessions
    if not (isinstance(item, dict) and str(item.get("id")) in ids)
]

os.makedirs(os.path.dirname(path), exist_ok=True)
tmp = f"{path}.tmp.{os.getpid()}"
with open(tmp, "w", encoding="utf-8") as handle:
    json.dump(out, handle, indent=2, sort_keys=True)
    handle.write("\n")
os.replace(tmp, path)
"""#
        let command = """
        py=$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)
        if [ -z "$py" ]; then echo "python not found" >&2; exit 127; fi
        "$py" -c \(SSHRemote.shellQuote(script))
        """
        try await sshInput(host: host, remoteCommand: command, input: data)
    }

    private static func merge(existing: TargetSessionIndexFile,
                              entries: [TargetSessionIndexEntry]) -> TargetSessionIndexFile {
        var byId = Dictionary(uniqueKeysWithValues:
            existing.sessions.map { ($0.id, $0) })
        for entry in entries {
            byId[entry.id] = entry
        }
        let sessions = byId.values.sorted { lhs, rhs in
            lhs.updatedAt > rhs.updatedAt
        }
        return TargetSessionIndexFile(version: TargetSessionIndexFile.currentVersion,
                                      updatedAt: timestamp(),
                                      sessions: sessions)
    }

    private static func write(_ file: TargetSessionIndexFile, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try encode(file)
        try data.write(to: url, options: .atomic)
    }

    private static func decodeFile(at url: URL) -> TargetSessionIndexFile {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url)
        else { return .empty }
        do {
            return try decode(data)
        } catch {
            NSLog("[helm.target-sessions] load failed %@: %@",
                  url.path, error.localizedDescription)
            return .empty
        }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }

    private static func decode(_ data: Data) throws -> TargetSessionIndexFile {
        try JSONDecoder().decode(TargetSessionIndexFile.self, from: data)
    }

    private static func normalizedLocalPath(_ path: String) -> String {
        ((path as NSString).expandingTildeInPath as NSString).standardizingPath
    }

    private static func normalizedRemotePath(_ path: String) -> String {
        path.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sshOutput(host: String, remoteCommand: String) async throws -> Data {
        try await runSSH(host: host, remoteCommand: remoteCommand, input: nil)
    }

    private static func sshInput(host: String,
                                 remoteCommand: String,
                                 input: Data) async throws {
        _ = try await runSSH(host: host, remoteCommand: remoteCommand, input: input)
    }

    private static func runSSH(host: String,
                               remoteCommand: String,
                               input: Data?) async throws -> Data {
        try await Task.detached(priority: .utility) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: SSHRemote.executable)
            proc.arguments = SSHRemote.arguments(
                host: host,
                remoteCommand: remoteCommand,
                batchMode: true,
                connectTimeout: 8
            )

            let stdout = Pipe()
            let stderr = Pipe()
            proc.standardOutput = stdout
            proc.standardError = stderr
            if input != nil {
                proc.standardInput = Pipe()
            }

            try proc.run()

            if let input, let stdin = proc.standardInput as? Pipe {
                stdin.fileHandleForWriting.write(input)
                try? stdin.fileHandleForWriting.close()
            }

            proc.waitUntilExit()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            guard proc.terminationStatus == 0 else {
                let reason = String(data: errData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw NSError(
                    domain: "Helm.TargetSessionIndex",
                    code: Int(proc.terminationStatus),
                    userInfo: [
                        NSLocalizedDescriptionKey: reason?.isEmpty == false
                            ? reason!
                            : "ssh exited \(proc.terminationStatus)"
                    ]
                )
            }
            return data
        }.value
    }
}
