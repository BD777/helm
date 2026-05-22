import Foundation

/// Shared filesystem layout under `~/Library/Application Support/dev.deng.helm/`.
/// `StateStore` and `ProfileStore` predate this helper and still compute the
/// root inline — leaving them alone for now; new code (image attachments, etc.)
/// goes through here.
enum AppPaths {
    static func appSupportDir() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("dev.deng.helm", isDirectory: true)
    }

    /// `<dataRoot>/images/<sessionId>/`. Created on demand.
    static func imagesDir(for sessionId: UUID) -> URL {
        let dir = appSupportDir()
            .appendingPathComponent("images", isDirectory: true)
            .appendingPathComponent(sessionId.uuidString.lowercased(), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `<imagesDir>/manifest.json` — Helm-owned mapping of (user-message ordinal)
    /// → image filenames. We keep this instead of decoding the base64 image
    /// blocks back out of Claude's session JSONL so the UI stays free of giant
    /// blobs.
    static func imageManifestURL(for sessionId: UUID) -> URL {
        imagesDir(for: sessionId).appendingPathComponent("manifest.json")
    }

    /// `<dataRoot>/transcripts/<sessionId>.json` — Helm-owned fallback
    /// transcript snapshot, primarily for SSH sessions whose vendor logs live
    /// on a remote machine.
    static func transcriptSnapshotURL(for sessionId: UUID) -> URL {
        let dir = appSupportDir().appendingPathComponent("transcripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(sessionId.uuidString.lowercased()).json")
    }
}
