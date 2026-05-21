import Foundation

/// Per-session, append-only mapping of user-message ordinals → image filenames.
/// Lives at `AppPaths.imageManifestURL(for:)` and is the source of truth for
/// re-rendering pasted-image thumbnails after a restart. We deliberately do
/// **not** decode the base64 image blocks back out of Claude's session JSONL
/// — keeping the path-only manifest means Helm's RAM stays small.
enum ImageManifestStore {
    struct Manifest: Codable {
        var version: Int
        var entries: [Entry]
    }

    struct Entry: Codable, Hashable {
        var userMessageOrdinal: Int
        var imagePaths: [String]   // filenames relative to imagesDir(for:)
    }

    private static let currentVersion = 1
    private static let lock = NSLock()

    static func load(sessionId: UUID) -> Manifest {
        let url = AppPaths.imageManifestURL(for: sessionId)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let m = try? JSONDecoder().decode(Manifest.self, from: data)
        else {
            return Manifest(version: currentVersion, entries: [])
        }
        return m
    }

    static func append(sessionId: UUID,
                       userMessageOrdinal: Int,
                       filenames: [String]) {
        guard !filenames.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        var manifest = load(sessionId: sessionId)
        // Replace any existing entry for the same ordinal (last write wins);
        // this guards against retries.
        manifest.entries.removeAll { $0.userMessageOrdinal == userMessageOrdinal }
        manifest.entries.append(.init(userMessageOrdinal: userMessageOrdinal,
                                      imagePaths: filenames))
        manifest.entries.sort { $0.userMessageOrdinal < $1.userMessageOrdinal }
        write(manifest, sessionId: sessionId)
    }

    private static func write(_ manifest: Manifest, sessionId: UUID) {
        let url = AppPaths.imageManifestURL(for: sessionId)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(manifest)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("[helm.images] manifest write failed: %@", error.localizedDescription)
        }
    }
}
