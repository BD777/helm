import Foundation

/// On-disk format for the providers / models / profiles tables. Single JSON
/// file at `~/Library/Application Support/dev.deng.helm/profiles.json`.
struct ProfileStoreFile: Codable {
    var version: Int
    var providers: [Provider]
    var models: [Model]
    var profiles: [Profile]

    static let currentVersion = 1
    static let empty = ProfileStoreFile(version: currentVersion,
                                        providers: [], models: [], profiles: [])
}

/// Synchronous load + debounced save of the profiles file. App lifetime; one
/// instance owned by `AppStore`.
final class ProfileStore: @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "dev.deng.helm.profilestore")
    private var pendingWork: DispatchWorkItem?

    /// Called on the main thread after a successful write — used by AppStore
    /// to publish a `lastProfilesSaveAt` timestamp the editors can show.
    var onSaved: (@Sendable () -> Void)?

    init(url: URL = ProfileStore.defaultURL()) {
        self.url = url
    }

    static func defaultURL() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("dev.deng.helm", isDirectory: true)
            .appendingPathComponent("profiles.json")
    }

    func load() -> ProfileStoreFile {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .empty
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            return try decoder.decode(ProfileStoreFile.self, from: data)
        } catch {
            NSLog("[helm.store] load failed: %@ — falling back to empty", error.localizedDescription)
            return .empty
        }
    }

    /// Schedule a write 200ms in the future, coalescing rapid edits.
    func scheduleSave(_ snapshot: ProfileStoreFile) {
        pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.write(snapshot)
        }
        pendingWork = work
        queue.asyncAfter(deadline: .now() + .milliseconds(200), execute: work)
    }

    /// Synchronous flush — used on app shutdown.
    func flush(_ snapshot: ProfileStoreFile) {
        pendingWork?.cancel()
        pendingWork = nil
        queue.sync { write(snapshot) }
    }

    private func write(_ snapshot: ProfileStoreFile) {
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            // Atomic replace via tmp file.
            let tmp = url.appendingPathExtension("tmp")
            try data.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
            NSLog("[helm.store] saved %d providers / %d models / %d profiles",
                  snapshot.providers.count, snapshot.models.count, snapshot.profiles.count)
            if let cb = onSaved {
                DispatchQueue.main.async { cb() }
            }
        } catch {
            NSLog("[helm.store] save failed: %@", error.localizedDescription)
        }
    }
}
