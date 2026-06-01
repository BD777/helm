import SwiftUI

/// Editor for a Profile — the run-config that a session binds to. Picks a
/// provider + primary model, plus optional per-vendor knobs.
struct ProfileEditor: View {
    @Binding var profile: Profile
    var onDelete: () -> Void

    @Environment(AppStore.self) private var store
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                identitySection
                bindingSection
                if profile.vendor == .claude {
                    claudeKnobsSection
                }
                if profile.vendor == .codex {
                    CodexRuntimeGuide(commandPath: $profile.commandPath)
                    codexKnobsSection
                }
                advancedSection
                Spacer(minLength: 4)
                SavedIndicator()
            }
            .padding(20)
        }
        .background(Color.helmChatBg)
        .alert("Delete profile?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This profile will be removed from the sidebar and future conversations.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VendorBadge(vendor: profile.vendor).frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name.isEmpty ? "Untitled" : profile.name)
                    .font(.system(size: 16, weight: .semibold))
                Text("\(profile.vendor.displayName) profile")
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
                TextField("es2-relay", text: $profile.name)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var bindingSection: some View {
        let providerOptions = store.providers(for: profile.vendor)
        let modelOptions = store.models(in: profile.providerId)
        return section("Binding") {
            field("Provider") {
                Picker("", selection: $profile.providerId) {
                    if providerOptions.isEmpty {
                        Text("(no \(profile.vendor.displayName) providers)").tag(profile.providerId)
                    }
                    ForEach(providerOptions) { p in
                        Text(p.name).tag(p.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 360)
                .onChange(of: profile.providerId) { _, newId in
                    if !store.models(in: newId).contains(where: { $0.id == profile.primaryModelId }),
                       let first = store.models(in: newId).first {
                        profile.primaryModelId = first.id
                    }
                }
            }
            field("Primary model",
                  hint: "Sent as the request's main model. Per-tier overrides below default to this.") {
                Picker("", selection: $profile.primaryModelId) {
                    if modelOptions.isEmpty {
                        Text("(provider has no models)").tag(profile.primaryModelId)
                    }
                    ForEach(modelOptions) { m in
                        Text(modelLabel(m)).tag(m.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 460)
            }
        }
    }

    private var claudeKnobsSection: some View {
        section("Claude per-tier overrides") {
            Text("Claude Code dispatches to opus / sonnet / haiku based on workload. Bind each tier to a model — by default, all three use the primary.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            tierPicker("Opus tier",   binding: $profile.opusModelId)
            tierPicker("Sonnet tier", binding: $profile.sonnetModelId)
            tierPicker("Haiku tier",  binding: $profile.haikuModelId)
            tierPicker("Subagent",    binding: $profile.subagentModelId)
            field("Auto-compact window",
                  hint: "CLAUDE_CODE_AUTO_COMPACT_WINDOW. Blank = vendor default.") {
                let bind = Binding<String>(
                    get: { profile.autoCompactWindow.map(String.init) ?? "" },
                    set: { profile.autoCompactWindow = Int($0.filter { $0.isNumber }) }
                )
                TextField("200000", text: bind)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
            }
            field("Permission mode") {
                Picker("", selection: Binding<ClaudePermissionMode?>(
                    get: { profile.claudePermissionMode },
                    set: { profile.claudePermissionMode = $0 }
                )) {
                    Text("(default)").tag(ClaudePermissionMode?.none)
                    ForEach(ClaudePermissionMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(ClaudePermissionMode?.some(mode))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            field("Effort") {
                Picker("", selection: Binding<ClaudeEffort?>(
                    get: { profile.claudeEffort },
                    set: { profile.claudeEffort = $0 }
                )) {
                    Text("(default)").tag(ClaudeEffort?.none)
                    ForEach(ClaudeEffort.allCases, id: \.self) { e in
                        Text(e.displayName).tag(ClaudeEffort?.some(e))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    private func tierPicker(_ label: String, binding: Binding<UUID?>) -> some View {
        let opts = store.models(in: profile.providerId)
        return field(label) {
            Picker("", selection: binding) {
                Text("Use primary").tag(UUID?.none)
                ForEach(opts) { m in
                    Text(modelLabel(m)).tag(UUID?.some(m.id))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 460)
        }
    }

    private var codexKnobsSection: some View {
        section("Codex run-config") {
            field("Reasoning effort") {
                Picker("", selection: Binding<Profile.ReasoningEffort?>(
                    get: { profile.reasoningEffort },
                    set: { profile.reasoningEffort = $0 }
                )) {
                    Text("(default)").tag(Profile.ReasoningEffort?.none)
                    ForEach(Profile.ReasoningEffort.allCases, id: \.self) { r in
                        Text(r.displayName).tag(Profile.ReasoningEffort?.some(r))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            field("Service tier") {
                Picker("", selection: Binding<Profile.ServiceTier?>(
                    get: { profile.serviceTier },
                    set: { profile.serviceTier = $0 }
                )) {
                    Text("(default)").tag(Profile.ServiceTier?.none)
                    ForEach(Profile.ServiceTier.allCases, id: \.self) { s in
                        Text(s.displayName).tag(Profile.ServiceTier?.some(s))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            field("Sandbox mode") {
                Picker("", selection: Binding<Profile.SandboxMode?>(
                    get: { profile.sandboxMode },
                    set: { profile.sandboxMode = $0 }
                )) {
                    Text("(default)").tag(Profile.SandboxMode?.none)
                    ForEach(Profile.SandboxMode.allCases, id: \.self) { sb in
                        Text(sb.displayName).tag(Profile.SandboxMode?.some(sb))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 280)
            }
            field("Approval policy") {
                Picker("", selection: Binding<CodexApprovalMode?>(
                    get: { profile.approvalMode },
                    set: { profile.approvalMode = $0 }
                )) {
                    Text("(default)").tag(CodexApprovalMode?.none)
                    ForEach(CodexApprovalMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(CodexApprovalMode?.some(mode))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 280)
            }
            field("Delegate to vendor profile",
                  hint: "Local projects only. SSH projects always use Helm's local profile settings instead of remote [profiles.X].") {
                TextField("optional — e.g. aidp", text: Binding(
                    get: { profile.delegateVendorProfile ?? "" },
                    set: { profile.delegateVendorProfile = $0.isEmpty ? nil : $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .font(DS.monoFontSmall)
                .frame(maxWidth: 280)
            }
        }
    }

    private var advancedSection: some View {
        section("Advanced") {
            field("Command path",
                  hint: commandPathHint) {
                TextField(Profile.defaultCommand(for: profile.vendor), text: $profile.commandPath)
                    .textFieldStyle(.roundedBorder)
                    .font(DS.monoFontSmall)
            }
            field("Config root",
                  hint: profile.vendor == .claude
                  ? "Override CLAUDE_CONFIG_DIR for local projects. SSH keeps profile resolution in Helm."
                  : "Override CODEX_HOME for local projects. SSH keeps profile resolution in Helm.") {
                TextField("~/.claude or ~/.codex", text: Binding(
                    get: { profile.configRoot ?? "" },
                    set: { profile.configRoot = $0.isEmpty ? nil : $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .font(DS.monoFontSmall)
            }
        }
    }

    private func modelLabel(_ m: Model) -> String {
        if m.alias.isEmpty { return m.providerModelId }
        if m.providerModelId.isEmpty { return m.alias }
        return "\(m.alias)  ·  \(m.providerModelId)"
    }

    private var commandPathHint: String {
        if profile.vendor == .codex {
            return "Optional override. Helm searches PATH, Codex.app, Homebrew, npm/nvm/fnm/asdf/mise/volta-style installs, then this absolute path if set."
        }
        return "Bare name (looked up on PATH) or absolute path. Default: \(Profile.defaultCommand(for: profile.vendor))"
    }

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

// MARK: - Paste-shell helper (used by ProviderEditor)

struct PasteShellSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""
    var onApply: (ShellEnvParser.Parsed) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Paste shell snippet")
                    .font(.system(size: 14, weight: .semibold))
                Text("Paste a `claude-relay() { … }` function body or a block of `KEY=VALUE` env lines. The parser extracts env vars and (if present) the trailing command path. Anthropic-recognized keys map to provider fields; everything else lands in extra env.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            HelmPlainTextEditor(text: $text)
                .frame(minHeight: 220)
                .background(
                    RoundedRectangle(cornerRadius: DS.cornerRadiusSmall)
                        .fill(Color.helmCard)
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.cornerRadiusSmall)
                                .stroke(Color.helmBorder, lineWidth: 1)
                        )
                )

            let preview = ShellEnvParser.parse(text)
            if !preview.env.isEmpty || preview.commandPath != nil {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Will import")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    if let cmd = preview.commandPath {
                        Text("• command: \(cmd)")
                            .font(DS.monoFontSmall)
                            .foregroundStyle(.secondary)
                    }
                    Text("• \(preview.env.count) env var\(preview.env.count == 1 ? "" : "s"): \(preview.env.keys.sorted().joined(separator: ", "))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    onApply(ShellEnvParser.parse(text))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 360)
    }
}
