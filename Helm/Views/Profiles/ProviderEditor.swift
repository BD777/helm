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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                identitySection
                connectionSection
                if provider.vendor == .codex {
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
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
            .controlSize(.small)
        }
    }

    private var identitySection: some View {
        section("Identity") {
            field("Name") {
                TextField("super-relay", text: $provider.name)
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
                TextField("https://relay.example.com", text: $provider.baseURL)
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
                Text("requires_openai_auth")
                    .font(.system(size: 12.5))
            }
            field("HTTP headers (extra)",
                  hint: "Sent as `http_headers.extra = \"{...}\"`. Useful for relay session pinning.") {
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
