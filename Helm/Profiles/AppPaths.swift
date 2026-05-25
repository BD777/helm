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

enum CodexCommandLocator {
    private static let cacheLock = NSLock()
    private static var cachedCodexPath: String?
    private static var didScanCodex = false

    static func resolve(_ command: String = "codex", refresh: Bool = false) -> String? {
        let candidate = command.isEmpty ? "codex" : command
        if candidate.contains("/") {
            let expanded = (candidate as NSString).expandingTildeInPath
            return FileManager.default.isExecutableFile(atPath: expanded) ? expanded : nil
        }

        if candidate == "codex", !refresh {
            cacheLock.lock()
            let didScan = didScanCodex
            let cached = cachedCodexPath
            cacheLock.unlock()
            if didScan { return cached }
        }

        let found = findExecutable(named: candidate)
        if candidate == "codex" {
            cacheLock.lock()
            cachedCodexPath = found
            didScanCodex = true
            cacheLock.unlock()
        }
        return found
    }

    static func searchPathEntries(refresh: Bool = false) -> [String] {
        var dirs = baseSearchDirectories()
        if let path = resolve(refresh: refresh) {
            dirs.insert((path as NSString).deletingLastPathComponent, at: 0)
        }
        return unique(dirs)
    }

    static func resolveTool(_ command: String) -> String? {
        findExecutable(named: command, includeCodexAppBundles: false)
    }

    private static func findExecutable(named name: String,
                                       includeCodexAppBundles: Bool = true) -> String? {
        let fileManager = FileManager.default
        for dir in baseSearchDirectories() {
            let full = "\(dir)/\(name)"
            if fileManager.isExecutableFile(atPath: full) { return full }
        }

        if includeCodexAppBundles, name == "codex" {
            for path in codexAppExecutablePaths() {
                if fileManager.isExecutableFile(atPath: path) { return path }
            }
        }

        for path in packageManagerExecutablePaths(named: name) {
            if fileManager.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    private static func baseSearchDirectories() -> [String] {
        let home = NSHomeDirectory()
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let fallbackDirs = [
            "\(home)/.local/bin",
            "\(home)/bin",
            "\(home)/.cargo/bin",
            "\(home)/.volta/bin",
            "\(home)/.asdf/shims",
            "\(home)/.local/share/mise/shims",
            "\(home)/.npm-global/bin",
            "\(home)/.yarn/bin",
            "\(home)/.bun/bin",
            "\(home)/.deno/bin",
            "/Applications/Codex.app/Contents/Resources",
            "\(home)/Applications/Codex.app/Contents/Resources",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ]
        return unique(pathDirs + fallbackDirs)
    }

    private static func codexAppExecutablePaths() -> [String] {
        let home = NSHomeDirectory()
        let appURLs = uniqueURLs([
            URL(fileURLWithPath: "/Applications/Codex.app", isDirectory: true),
            URL(fileURLWithPath: "\(home)/Applications/Codex.app", isDirectory: true),
        ] + appBundleURLs(in: URL(fileURLWithPath: "/Applications", isDirectory: true))
          + appBundleURLs(in: URL(fileURLWithPath: "\(home)/Applications", isDirectory: true))
          + spotlightCodexAppURLs())

        let suffixes = [
            "Contents/Resources/codex",
            "Contents/MacOS/codex",
        ]
        return appURLs.flatMap { appURL in
            suffixes.map { appURL.appendingPathComponent($0).path }
        }
    }

    private static func appBundleURLs(in directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var urls: [URL] = []
        for case let url as URL in enumerator {
            if url.lastPathComponent == "Codex.app" {
                urls.append(url)
            }
        }
        return urls
    }

    private static func spotlightCodexAppURLs() -> [URL] {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/mdfind") else { return [] }
        let output = runAndCapture("/usr/bin/mdfind", [
            "kMDItemCFBundleIdentifier == 'com.openai.codex' || kMDItemFSName == 'Codex.app'"
        ])
        return output
            .split(separator: "\n")
            .map { URL(fileURLWithPath: String($0), isDirectory: true) }
    }

    private static func packageManagerExecutablePaths(named name: String) -> [String] {
        let home = NSHomeDirectory()
        let roots = [
            "\(home)/.nvm/versions/node",
            "\(home)/.fnm/node-versions",
            "\(home)/Library/Application Support/fnm/node-versions",
            "\(home)/.asdf/installs",
            "\(home)/.local/share/mise/installs",
            "\(home)/.volta/tools/image",
            "\(home)/Library/pnpm",
        ]

        var matches: [String] = []
        let fileManager = FileManager.default
        for root in roots {
            guard fileManager.fileExists(atPath: root),
                  let enumerator = fileManager.enumerator(
                    at: URL(fileURLWithPath: root, isDirectory: true),
                    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles]
                  )
            else { continue }

            var checked = 0
            for case let url as URL in enumerator {
                checked += 1
                if checked > 5000 { break }
                guard url.lastPathComponent == name else { continue }
                matches.append(url.path)
            }
        }
        return unique(matches)
    }

    private static func runAndCapture(_ executable: String, _ arguments: [String]) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ""
        }
        guard process.terminationStatus == 0 else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values where !value.isEmpty && !seen.contains(value) {
            seen.insert(value)
            result.append(value)
        }
        return result
    }

    private static func uniqueURLs(_ values: [URL]) -> [URL] {
        unique(values.map(\.path)).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
}
