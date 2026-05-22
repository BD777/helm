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

    static let currentVersion = 1
    static let empty = AppStateFile(version: currentVersion,
                                    projects: [],
                                    sessions: [],
                                    selectedSessionId: nil)
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
        guard !items.isEmpty else { return }
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
