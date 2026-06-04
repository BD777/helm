import AppKit
import SwiftUI

/// Editor for a Provider record. Vendor is fixed once created (changing it
/// would invalidate Models attached to it).
struct ProviderEditor: View {
    @Binding var provider: Provider
    var onDelete: () -> Void

    @State private var revealToken = false
    @State private var newHeaderKey = ""
    @State private var newHeaderValue = ""
    @State private var newEnvKey = ""
    @State private var newEnvValue = ""
    @State private var showPasteSheet = false
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                identitySection
                connectionSection
                if provider.vendor == .codex {
                    CodexRuntimeGuide()
                    codexExtrasSection
                }
                if provider.vendor == .claude {
                    claudeExtraEnvSection
                }
                Spacer(minLength: 4)
                SavedIndicator()
            }
            .padding(20)
        }
        .background(Color.helmChatBg)
        .sheet(isPresented: $showPasteSheet) {
            PasteShellSheet { parsed in
                applyParsed(parsed)
            }
        }
        .alert("Delete provider?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will also delete the provider's models and profiles that depend on them.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VendorBadge(vendor: provider.vendor).frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(provider.name.isEmpty ? "Untitled" : provider.name)
                    .font(.system(size: 16, weight: .semibold))
                Text("\(provider.vendor.displayName) provider")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .controlSize(.small)
        }
    }

    private var identitySection: some View {
        section("Identity") {
            field("Name") {
                TextField("team gateway", text: $provider.name)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var connectionSection: some View {
        section("Connection") {
            field("Base URL",
                  hint: provider.vendor == .claude
                  ? "Sent as ANTHROPIC_BASE_URL. Leave blank for anthropic.com."
                  : "Codex provider base_url. e.g. http://127.0.0.1:8787/v1") {
                TextField("https://api-proxy.example.com", text: $provider.baseURL)
                    .textFieldStyle(.roundedBorder)
                    .font(DS.monoFontSmall)
            }
            field("Auth token",
                  hint: "Stored in plaintext for now — Keychain integration pending.") {
                HStack(spacing: 6) {
                    Group {
                        if revealToken {
                            TextField("plat_…", text: $provider.authToken)
                        } else {
                            SecureField("plat_…", text: $provider.authToken)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .font(DS.monoFontSmall)
                    Button(revealToken ? "Hide" : "Reveal") { revealToken.toggle() }
                        .controlSize(.small)
                    Button {
                        showPasteSheet = true
                    } label: {
                        Label("Paste shell", systemImage: "doc.on.clipboard")
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private var codexExtrasSection: some View {
        section("Codex wire") {
            field("Wire API") {
                Picker("", selection: $provider.wireAPI) {
                    ForEach(Provider.WireAPI.allCases, id: \.self) { w in
                        Text(w.displayName).tag(w)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 320)
            }
            Toggle(isOn: $provider.requiresOpenAIAuth) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use Codex OpenAI account auth")
                        .font(.system(size: 12.5))
                    Text("Leave off for relay/provider tokens. When Auth token is filled, Helm sends it through Codex env_key.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
            field("HTTP headers",
                  hint: "Sent as `http_headers = { ... }`. Useful for relay session pinning.") {
                headerTable
                HStack(spacing: 6) {
                    TextField("KEY", text: $newHeaderKey)
                        .textFieldStyle(.roundedBorder)
                        .font(DS.monoFontSmall)
                        .frame(maxWidth: 220)
                    TextField("value", text: $newHeaderValue)
                        .textFieldStyle(.roundedBorder)
                        .font(DS.monoFontSmall)
                    Button("Add") {
                        let k = newHeaderKey.trimmingCharacters(in: .whitespaces)
                        guard !k.isEmpty else { return }
                        provider.httpHeaders[k] = newHeaderValue
                        newHeaderKey = ""; newHeaderValue = ""
                    }
                    .disabled(newHeaderKey.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private var headerTable: some View {
        let keys = provider.httpHeaders.keys.sorted()
        return VStack(spacing: 0) {
            if keys.isEmpty {
                Text("No headers.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ForEach(keys, id: \.self) { key in
                    HStack(spacing: 8) {
                        Text(key)
                            .font(DS.monoFontSmall)
                            .frame(width: 200, alignment: .leading)
                            .lineLimit(1)
                        TextField("", text: Binding(
                            get: { provider.httpHeaders[key] ?? "" },
                            set: { provider.httpHeaders[key] = $0 }
                        ))
                        .textFieldStyle(.plain)
                        .font(DS.monoFontSmall)
                        Button {
                            provider.httpHeaders.removeValue(forKey: key)
                        } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                            .buttonStyle(.plain)
                    }
                    .padding(.vertical, 4)
                    if key != keys.last { Divider() }
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: DS.cornerRadiusSmall)
                .fill(Color.helmCard)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.cornerRadiusSmall)
                        .stroke(Color.helmBorder, lineWidth: 1)
                )
        )
    }

    private var claudeExtraEnvSection: some View {
        section("Extra environment") {
            Text("Layered on top of resolver-generated ANTHROPIC_* env. Use this for things like CLAUDE_CODE_AUTO_COMPACT_WINDOW that aren't part of a profile.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            envTable
            HStack(spacing: 6) {
                TextField("KEY", text: $newEnvKey)
                    .textFieldStyle(.roundedBorder)
                    .font(DS.monoFontSmall)
                    .frame(maxWidth: 220)
                TextField("value", text: $newEnvValue)
                    .textFieldStyle(.roundedBorder)
                    .font(DS.monoFontSmall)
                Button("Add") {
                    let k = newEnvKey.trimmingCharacters(in: .whitespaces)
                    guard !k.isEmpty else { return }
                    provider.extraEnv[k] = newEnvValue
                    newEnvKey = ""; newEnvValue = ""
                }
                .disabled(newEnvKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var envTable: some View {
        let keys = provider.extraEnv.keys.sorted()
        return VStack(spacing: 0) {
            if keys.isEmpty {
                Text("No extras.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ForEach(keys, id: \.self) { key in
                    HStack(spacing: 8) {
                        Text(key)
                            .font(DS.monoFontSmall)
                            .frame(width: 240, alignment: .leading)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        TextField("", text: Binding(
                            get: { provider.extraEnv[key] ?? "" },
                            set: { provider.extraEnv[key] = $0 }
                        ))
                        .textFieldStyle(.plain)
                        .font(DS.monoFontSmall)
                        Button {
                            provider.extraEnv.removeValue(forKey: key)
                        } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                            .buttonStyle(.plain)
                    }
                    .padding(.vertical, 4)
                    if key != keys.last { Divider() }
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: DS.cornerRadiusSmall)
                .fill(Color.helmCard)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.cornerRadiusSmall)
                        .stroke(Color.helmBorder, lineWidth: 1)
                )
        )
    }

    // MARK: paste-shell

    private func applyParsed(_ parsed: ShellEnvParser.Parsed) {
        // Provider-level mapping: pull base URL, auth token, headers, extras.
        if let url = parsed.env["ANTHROPIC_BASE_URL"], !url.isEmpty {
            provider.baseURL = url
        }
        if let tok = parsed.env["ANTHROPIC_AUTH_TOKEN"]
            ?? parsed.env["ANTHROPIC_API_KEY"]
            ?? parsed.env["OPENAI_API_KEY"], !tok.isEmpty {
            provider.authToken = tok
        }
        let consumed: Set<String> = [
            "ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY",
            "ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL",
            "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL",
            "CLAUDE_CODE_SUBAGENT_MODEL",
            "OPENAI_API_KEY", "OPENAI_BASE_URL",
        ]
        for (k, v) in parsed.env where !consumed.contains(k) {
            provider.extraEnv[k] = v
        }
    }

    // MARK: layout helpers

    @ViewBuilder
    private func section<V: View>(_ title: String, @ViewBuilder content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.tertiary)
            content()
        }
    }

    @ViewBuilder
    private func field<V: View>(_ label: String, hint: String? = nil, @ViewBuilder content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
            content()
            if let hint {
                Text(hint).font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
        }
    }
}

struct CodexRuntimeGuide: View {
    var commandPath: Binding<String>? = nil

    @State private var resolvedCommandPath: String? = CodexCommandLocator.resolve()
    @State private var copiedInstallCommand = false
    @State private var isInstalling = false
    @State private var installMessage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CODEX RUNTIME")
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.tertiary)

            HStack(alignment: .top, spacing: 9) {
                Image(systemName: resolvedCommandPath == nil ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(resolvedCommandPath == nil ? .orange : .green)
                    .frame(width: 16, height: 16)

                VStack(alignment: .leading, spacing: 4) {
                    Text(resolvedCommandPath == nil ? "Codex CLI not found" : "Codex CLI found")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(detailText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let path = resolvedCommandPath {
                        Text(path)
                            .font(DS.monoFontSmall)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }

                    if let installMessage {
                        Text(installMessage)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
            }

            HStack(spacing: 8) {
                if let commandPath, let path = resolvedCommandPath {
                    Button {
                        commandPath.wrappedValue = path
                    } label: {
                        Label("Use this path", systemImage: "link")
                    }
                    .controlSize(.small)
                    .disabled(commandPath.wrappedValue == path)
                    .help("Write the detected Codex executable path into this profile.")
                }

                if commandPath != nil {
                    Button {
                        chooseCodexCommand()
                    } label: {
                        Label("Choose", systemImage: "folder")
                    }
                    .controlSize(.small)
                    .help("Pick a codex executable or Codex.app manually.")
                }

                Menu {
                    ForEach(CodexInstallMethod.allCases) { method in
                        Button(method.title) {
                            install(method)
                        }
                        .disabled(!method.isAvailable || isInstalling)
                    }
                } label: {
                    if isInstalling {
                        Label("Installing", systemImage: "arrow.down.circle")
                    } else {
                        Label("Install", systemImage: "arrow.down.circle")
                    }
                }
                .controlSize(.small)
                .disabled(isInstalling || !CodexInstallMethod.hasAvailableInstaller)

                Button {
                    CodexCommandDiscovery.openInstallDocs()
                } label: {
                    Label("Install guide", systemImage: "safari")
                }
                .controlSize(.small)

                Button {
                    CodexCommandDiscovery.copyInstallCommand()
                    copiedInstallCommand = true
                } label: {
                    Label(copiedInstallCommand ? "Copied" : "Copy npm install", systemImage: "doc.on.doc")
                }
                .controlSize(.small)

                Button {
                    resolvedCommandPath = CodexCommandLocator.resolve(refresh: true)
                    copiedInstallCommand = false
                    installMessage = nil
                } label: {
                    Label("Check", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: 520, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.cornerRadiusSmall, style: .continuous)
                .fill(Color.helmCard)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.cornerRadiusSmall, style: .continuous)
                        .stroke(Color.helmBorder, lineWidth: 1)
                )
        )
    }

    private var detailText: String {
        if resolvedCommandPath == nil {
            return "Helm needs a local codex command to run Codex profiles. Provider setup only defines API routing; install Codex or set an absolute command path on the profile."
        }
        return "Helm needs a local codex command to run Codex profiles. Provider setup only defines API routing; this runtime will be used automatically unless a profile overrides it."
    }

    private func chooseCodexCommand() {
        guard let commandPath else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Codex"
        panel.message = "Select a codex executable or Codex.app."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = CodexCommandDiscovery.executablePath(from: url)
        commandPath.wrappedValue = path
        resolvedCommandPath = CodexCommandLocator.resolve(path, refresh: true) ?? path
        installMessage = nil
    }

    private func install(_ method: CodexInstallMethod) {
        isInstalling = true
        copiedInstallCommand = false
        installMessage = "Running \(method.commandPreview)..."
        Task {
            let result = await CodexCommandDiscovery.install(method)
            await MainActor.run {
                isInstalling = false
                resolvedCommandPath = CodexCommandLocator.resolve(refresh: true)
                installMessage = result.message
            }
        }
    }
}

enum CodexCommandDiscovery {
    static let installDocsURLString = "https://help.openai.com/en/articles/11096431"
    static let installCommand = "npm install -g @openai/codex"

    static func openInstallDocs() {
        guard let url = URL(string: installDocsURLString) else { return }
        NSWorkspace.shared.open(url)
    }

    static func copyInstallCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(installCommand, forType: .string)
    }

    static func executablePath(from url: URL) -> String {
        if url.pathExtension == "app" {
            let resourcePath = url.appendingPathComponent("Contents/Resources/codex").path
            if FileManager.default.isExecutableFile(atPath: resourcePath) {
                return resourcePath
            }
            let macOSPath = url.appendingPathComponent("Contents/MacOS/codex").path
            if FileManager.default.isExecutableFile(atPath: macOSPath) {
                return macOSPath
            }
        }
        return url.path
    }

    static func install(_ method: CodexInstallMethod) async -> CodexInstallResult {
        guard let executable = method.executablePath else {
            return CodexInstallResult(success: false,
                                      message: "\(method.executableName) was not found. Use the install guide instead.")
        }

        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("helm-codex-install-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = method.arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = CodexCommandLocator.searchPathEntries().joined(separator: ":")
        process.environment = env

        do {
            let handle = try FileHandle(forWritingTo: logURL)
            process.standardOutput = handle
            process.standardError = handle
            try process.run()
            process.waitUntilExit()
            try? handle.close()
        } catch {
            return CodexInstallResult(success: false,
                                      message: "Install failed to start: \(error.localizedDescription)")
        }

        let output = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        let summary = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if process.terminationStatus == 0 {
            return CodexInstallResult(success: true,
                                      message: "Install finished. \(CodexCommandLocator.resolve(refresh: true) ?? "Click Check to refresh.")")
        }
        let tail = summary.isEmpty ? "No installer output." : String(summary.suffix(240))
        return CodexInstallResult(success: false,
                                  message: "Install exited \(process.terminationStatus): \(tail)")
    }
}

struct CodexInstallResult {
    let success: Bool
    let message: String
}

enum CodexInstallMethod: String, CaseIterable, Identifiable {
    case homebrew
    case npm

    var id: String { rawValue }

    var title: String {
        switch self {
        case .homebrew: return "Homebrew cask"
        case .npm: return "npm global"
        }
    }

    var executableName: String {
        switch self {
        case .homebrew: return "brew"
        case .npm: return "npm"
        }
    }

    var executablePath: String? {
        CodexCommandLocator.resolveTool(executableName)
    }

    var arguments: [String] {
        switch self {
        case .homebrew: return ["install", "--cask", "codex"]
        case .npm: return ["install", "-g", "@openai/codex"]
        }
    }

    var commandPreview: String {
        ([executableName] + arguments).joined(separator: " ")
    }

    var isAvailable: Bool {
        executablePath != nil
    }

    static var hasAvailableInstaller: Bool {
        allCases.contains { $0.isAvailable }
    }
}
