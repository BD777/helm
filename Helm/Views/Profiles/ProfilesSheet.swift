import SwiftUI

/// Two-section sheet: Providers (with their Models nested underneath) and
/// Profiles. Picking any row in the sidebar swaps the right pane to the
/// corresponding editor.
struct ProfilesSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("helmAppearance") private var appearanceRawValue = HelmAppearance.system.rawValue
    @AppStorage(CodexComputerUseMode.userDefaultsKey) private var computerUseModeRawValue = CodexComputerUseMode.automatic.rawValue
    @AppStorage(MessageSendShortcut.userDefaultsKey) private var messageSendShortcutRawValue = MessageSendShortcut.defaultValue.rawValue
    @AppStorage(MessageSendShortcut.lineBreakUserDefaultsKey) private var messageLineBreakShortcutRawValue = MessageSendShortcut.defaultLineBreakValue.rawValue
    @State private var selection: Selection? = nil
    /// Set when the user clicks a provider's [+] — drives the AddModelsSheet
    /// presentation. Cleared on dismiss.
    @State private var addingForProvider: Provider? = nil
    /// Providers expanded in the sidebar. New providers default to expanded
    /// so freshly-added rows show their (initially empty) model bucket.
    @State private var expanded: Set<UUID> = []

    enum Selection: Hashable {
        case appearance
        case keyboardShortcuts
        case computerUse
        case archivedConversations
        case sshProject(UUID)
        case provider(UUID)
        case model(UUID)
        case profile(UUID)
    }

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 240, idealWidth: 260, maxWidth: 320)

            Group {
                switch selection {
                case .appearance:
                    AppearanceSettingsView(appearanceRawValue: $appearanceRawValue)
                case .keyboardShortcuts:
                    KeyboardShortcutsSettingsView(
                        sendShortcutRawValue: $messageSendShortcutRawValue,
                        lineBreakShortcutRawValue: $messageLineBreakShortcutRawValue
                    )
                case .computerUse:
                    ComputerUseSettingsView(modeRawValue: $computerUseModeRawValue)
                case .archivedConversations:
                    ArchivedConversationsSettingsView()
                case .sshProject(let id):
                    if let project = store.projects.first(where: { $0.id == id }) {
                        SSHProfileSettingsView(project: project)
                            .id(id)
                    } else { placeholder }
                case .provider(let id):
                    if let binding = providerBinding(id) {
                        ProviderEditor(provider: binding,
                                       onDelete: { store.deleteProvider(id); selection = nil })
                            .id(id)
                    } else { placeholder }
                case .model(let id):
                    if let binding = modelBinding(id) {
                        ModelEditor(model: binding,
                                    onDelete: { store.deleteModel(id); selection = nil })
                            .id(id)
                    } else { placeholder }
                case .profile(let id):
                    if let binding = profileBinding(id) {
                        ProfileEditor(profile: binding,
                                      onDelete: { store.deleteProfile(id); selection = nil })
                            .id(id)
                    } else { placeholder }
                case .none:
                    placeholder
                }
            }
            .frame(minWidth: 480)
        }
        .frame(minWidth: 820, idealWidth: 940, minHeight: 520, idealHeight: 620)
        .background(Color.helmChatBg)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .onAppear { syncSelection() }
        .sheet(item: $addingForProvider) { provider in
            AddModelsSheet(
                provider: provider,
                existingWireIds: Set(store.models(in: provider.id).map(\.providerModelId)),
                onAdd: { entries in handleAdd(entries, to: provider) }
            )
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    section(title: "General")
                    settingsRow(
                        selection: .appearance,
                        symbolName: HelmAppearance.normalized(appearanceRawValue).symbolName,
                        title: "Appearance",
                        subtitle: HelmAppearance.normalized(appearanceRawValue).title
                    )
                    settingsRow(
                        selection: .keyboardShortcuts,
                        symbolName: "keyboard",
                        title: "Shortcuts",
                        subtitle: shortcutsSubtitle
                    )
                    settingsRow(
                        selection: .computerUse,
                        symbolName: "cursorarrow.motionlines",
                        title: "Computer Use",
                        subtitle: (CodexComputerUseMode(rawValue: computerUseModeRawValue) ?? .automatic).displayName
                    )
                    settingsRow(
                        selection: .archivedConversations,
                        symbolName: "archivebox",
                        title: "Archived Conversations",
                        subtitle: archivedSubtitle
                    )
                    if !store.sshProjects.isEmpty {
                        section(title: "SSH Connections")
                        ForEach(store.sshProjects) { project in
                            settingsRow(
                                selection: .sshProject(project.id),
                                symbolName: "terminal",
                                title: project.name,
                                subtitle: sshProjectSubtitle(project)
                            )
                        }
                    }

                    section(
                        title: "Providers",
                        addMenu: AnyView(
                            Menu {
                                Button("New Claude provider") { addProvider(.claude) }
                                Button("New Codex provider")  { addProvider(.codex) }
                            } label: { Image(systemName: "plus") }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                                .help("Add provider")
                                .accessibilityLabel("Add provider")
                        )
                    )
                    if store.globalProviders.isEmpty {
                        empty("No providers yet.")
                    } else {
                        ForEach(store.globalProviders) { p in
                            providerRow(p)
                            if expanded.contains(p.id) {
                                let ms = store.models(in: p.id)
                                if ms.isEmpty {
                                    nestedEmpty("No models — click + to add.")
                                } else {
                                    ForEach(ms) { m in
                                        modelRow(m)
                                    }
                                }
                            }
                        }
                    }

                    section(
                        title: "Profiles",
                        addMenu: AnyView(
                            Menu {
                                Button("New Claude profile") { addProfile(.claude) }
                                    .disabled(!hasViableProfileTargets(.claude))
                                Button("New Codex profile")  { addProfile(.codex) }
                                    .disabled(!hasViableProfileTargets(.codex))
                            } label: { Image(systemName: "plus") }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                                .help("Add profile")
                                .accessibilityLabel("Add profile")
                        )
                    )
                    if store.globalProfiles.isEmpty {
                        empty("No profiles yet.")
                    } else {
                        ForEach(store.globalProfiles) { p in
                            profileRow(p)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .background(Color.helmSidebarBg)
    }

    private var shortcutsSubtitle: String {
        let send = MessageSendShortcut.normalized(messageSendShortcutRawValue)
        let lineBreak = MessageSendShortcut.normalizedLineBreak(messageLineBreakShortcutRawValue,
                                                                sendShortcut: send)
        return "Send \(send.glyph) · New line \(lineBreak.glyph)"
    }

    private var archivedSubtitle: String {
        let count = store.archivedSessions.count
        return count == 1 ? "1 archived" : "\(count) archived"
    }

    private func section(title: String, addMenu: AnyView? = nil) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.tertiary)
            Spacer()
            if let addMenu {
                addMenu
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private func settingsRow(selection target: Selection,
                             symbolName: String,
                             title: String,
                             subtitle: String) -> some View {
        let isActive = selection == target
        return Button {
            selection = target
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbolName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12.5, weight: isActive ? .semibold : .regular))
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: DS.cornerRadiusSmall)
                    .fill(isActive ? Color.helmSelected : Color.clear)
            )
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(subtitle)
            .accessibilityHint("Open \(title.lowercased()) settings")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
    }

    private func sshProjectSubtitle(_ project: Project) -> String {
        let localCount = store.availableProfiles(for: project.id)
            .filter { $0.sshProjectId == nil }
            .count
        let remoteCount = store.remoteProfiles(forSSHProject: project.id).count
        if localCount == 0 && remoteCount == 0 { return "No enabled profiles" }
        return "\(localCount) local, \(remoteCount) remote"
    }

    private func providerRow(_ p: Provider) -> some View {
        let isActive = selection == .provider(p.id)
        let isExpanded = expanded.contains(p.id)
        return HStack(spacing: 6) {
            Button {
                toggleExpanded(p.id)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 12, height: 12)
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Collapse \(p.name)" : "Expand \(p.name)")
            .accessibilityLabel(isExpanded ? "Collapse \(p.name)" : "Expand \(p.name)")

            Button {
                selection = .provider(p.id)
            } label: {
                HStack(spacing: 6) {
                    VendorBadge(vendor: p.vendor).frame(width: 16, height: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.name).font(.system(size: 12.5, weight: isActive ? .semibold : .regular))
                        Text(p.baseURL.isEmpty ? "no base URL" : p.baseURL)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(p.name) provider")
                .accessibilityValue("\(p.vendor.displayName), \(p.baseURL.isEmpty ? "no base URL" : p.baseURL)")
                .accessibilityHint("Edit provider")
            }
            .buttonStyle(.plain)

            Button {
                expanded.insert(p.id)
                addingForProvider = p
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Add models from \(p.name)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: DS.cornerRadiusSmall)
                .fill(isActive ? Color.helmSelected : Color.clear)
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }

    private func modelRow(_ m: Model) -> some View {
        let isActive = selection == .model(m.id)
        return Button {
            selection = .model(m.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "cube.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14, height: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(m.label)
                        .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                        .lineLimit(1)
                    if !m.alias.isEmpty {
                        Text(m.providerModelId)
                            .font(DS.monoFontSmall)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 32)
            .padding(.trailing, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: DS.cornerRadiusSmall)
                    .fill(isActive ? Color.helmSelected : Color.clear)
            )
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(m.label)
            .accessibilityValue(m.providerModelId)
            .accessibilityHint("Edit model")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
    }

    private func profileRow(_ p: Profile) -> some View {
        let isActive = selection == .profile(p.id)
        let modelLabel = store.model(p.primaryModelId)?.label ?? "missing model"
        return Button {
            selection = .profile(p.id)
        } label: {
            HStack(spacing: 8) {
                VendorBadge(vendor: p.vendor).frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(p.name)
                        .font(.system(size: 12.5, weight: isActive ? .semibold : .regular))
                    if let m = store.model(p.primaryModelId) {
                        Text(m.label)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    } else {
                        Text("missing model").font(.system(size: 10.5)).foregroundStyle(.red)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: DS.cornerRadiusSmall)
                    .fill(isActive ? Color.helmSelected : Color.clear)
            )
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(p.name) profile")
            .accessibilityValue("\(p.vendor.displayName), \(modelLabel)")
            .accessibilityHint("Edit profile")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
    }

    private func empty(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 4)
    }

    private func nestedEmpty(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 36)
            .padding(.trailing, 8)
            .padding(.vertical, 3)
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.crop.rectangle.stack")
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(.tertiary)
            Text("Pick a setting, provider, model, or profile.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private struct AppearanceSettingsView: View {
        @Binding var appearanceRawValue: String

        private var appearanceBinding: Binding<String> {
            Binding(
                get: { HelmAppearance.normalized(appearanceRawValue).rawValue },
                set: { appearanceRawValue = HelmAppearance.normalized($0).rawValue }
            )
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 18) {
                header
                section("Theme") {
                    Picker("", selection: appearanceBinding) {
                        ForEach(HelmAppearance.allCases) { appearance in
                            Label(appearance.title, systemImage: appearance.symbolName)
                                .tag(appearance.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 360)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.helmChatBg)
        }

        private var header: some View {
            HStack(spacing: 10) {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.system(size: 21, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Appearance")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Theme")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }

        private func section<Content: View>(_ title: String,
                                            @ViewBuilder content: () -> Content) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(.tertiary)
                content()
            }
            .padding(14)
            .frame(maxWidth: 420, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.cornerRadius, style: .continuous)
                    .fill(Color.helmCard)
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.cornerRadius, style: .continuous)
                            .stroke(Color.helmBorder, lineWidth: 1)
                    )
            )
        }
    }

    private struct KeyboardShortcutsSettingsView: View {
        @Binding var sendShortcutRawValue: String
        @Binding var lineBreakShortcutRawValue: String

        private var sendShortcut: MessageSendShortcut {
            MessageSendShortcut.normalized(sendShortcutRawValue)
        }

        private var lineBreakShortcut: MessageSendShortcut {
            MessageSendShortcut.normalizedLineBreak(lineBreakShortcutRawValue,
                                                    sendShortcut: sendShortcut)
        }

        private var sendShortcutBinding: Binding<MessageSendShortcut> {
            Binding(
                get: { sendShortcut },
                set: { setSendShortcut($0) }
            )
        }

        private var lineBreakShortcutBinding: Binding<MessageSendShortcut> {
            Binding(
                get: { lineBreakShortcut },
                set: { setLineBreakShortcut($0) }
            )
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 18) {
                header
                section("Messages") {
                    shortcutRow(symbolName: "paperplane.fill",
                                title: "Send message",
                                value: sendShortcut,
                                selection: sendShortcutBinding)

                    Divider()

                    shortcutRow(symbolName: "arrow.turn.down.left",
                                title: "New line",
                                value: lineBreakShortcut,
                                selection: lineBreakShortcutBinding)

                    Divider()

                    Button {
                        lineBreakShortcutRawValue = MessageSendShortcut.defaultLineBreakValue.rawValue
                        sendShortcutRawValue = MessageSendShortcut.defaultValue.rawValue
                    } label: {
                        Label("Restore Defaults", systemImage: "arrow.counterclockwise")
                    }
                    .controlSize(.small)
                    .disabled(sendShortcut == .defaultValue &&
                              lineBreakShortcut == .defaultLineBreakValue)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.helmChatBg)
        }

        private var header: some View {
            HStack(spacing: 10) {
                Image(systemName: "keyboard")
                    .font(.system(size: 21, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Shortcuts")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Message composer")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }

        private func shortcutRow(symbolName: String,
                                 title: String,
                                 value: MessageSendShortcut,
                                 selection: Binding<MessageSendShortcut>) -> some View {
            HStack(spacing: 10) {
                Image(systemName: symbolName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(value.glyph)
                        .font(DS.monoFontSmall)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Picker("", selection: selection) {
                    ForEach(MessageSendShortcut.allCases) { shortcut in
                        Text("\(shortcut.glyph)  \(shortcut.displayName)")
                            .tag(shortcut)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 220)
            }
        }

        private func setSendShortcut(_ shortcut: MessageSendShortcut) {
            let previousSendShortcut = sendShortcut
            let currentLineBreakShortcut = lineBreakShortcut
            sendShortcutRawValue = shortcut.rawValue
            guard currentLineBreakShortcut == shortcut else { return }
            lineBreakShortcutRawValue = MessageSendShortcut
                .fallback(avoiding: shortcut,
                          preferred: previousSendShortcut,
                          defaultValue: .defaultLineBreakValue)
                .rawValue
        }

        private func setLineBreakShortcut(_ shortcut: MessageSendShortcut) {
            let currentSendShortcut = sendShortcut
            let previousLineBreakShortcut = lineBreakShortcut
            lineBreakShortcutRawValue = shortcut.rawValue
            guard currentSendShortcut == shortcut else { return }
            sendShortcutRawValue = MessageSendShortcut
                .fallback(avoiding: shortcut,
                          preferred: previousLineBreakShortcut,
                          defaultValue: .defaultValue)
                .rawValue
        }

        private func section<Content: View>(_ title: String,
                                            @ViewBuilder content: () -> Content) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(.tertiary)
                content()
            }
            .padding(14)
            .frame(maxWidth: 520, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.cornerRadius, style: .continuous)
                    .fill(Color.helmCard)
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.cornerRadius, style: .continuous)
                            .stroke(Color.helmBorder, lineWidth: 1)
                    )
            )
        }
    }

    private struct ComputerUseSettingsView: View {
        @Binding var modeRawValue: String
        @State private var diagnostic = CodexComputerUseMCP.diagnose()
        @State private var isChecking = false

        private var mode: CodexComputerUseMode {
            CodexComputerUseMode(rawValue: modeRawValue) ?? .automatic
        }

        private var modeBinding: Binding<CodexComputerUseMode> {
            Binding(
                get: { mode },
                set: { modeRawValue = $0.rawValue }
            )
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 18) {
                header
                section("Local MCP") {
                    Picker("", selection: modeBinding) {
                        ForEach(CodexComputerUseMode.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 360)

                    Text(mode.helpText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider()

                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: statusIcon)
                            .foregroundStyle(statusColor)
                            .frame(width: 14)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(diagnostic.title)
                                .font(.system(size: 12, weight: .semibold))
                            Text(diagnostic.detail)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if let command = diagnostic.command {
                        infoRow("Command", command)
                    }
                    if let cwd = diagnostic.cwd {
                        infoRow("Cwd", cwd)
                    }

                    Button {
                        refresh(force: true)
                    } label: {
                        if isChecking {
                            Label("Checking", systemImage: "arrow.clockwise")
                        } else {
                            Label("Check", systemImage: "arrow.clockwise")
                        }
                    }
                    .controlSize(.small)
                    .disabled(isChecking)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.helmChatBg)
            .onAppear { refresh(force: false) }
            .onChange(of: modeRawValue) { _, _ in refresh(force: true) }
        }

        private var header: some View {
            HStack(spacing: 10) {
                Image(systemName: "cursorarrow.motionlines")
                    .font(.system(size: 21, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Computer Use")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Codex App MCP")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }

        private var statusIcon: String {
            switch diagnostic.state {
            case .ready: return "checkmark.circle.fill"
            case .disabled, .unsupportedRemote: return "minus.circle"
            case .found: return "checkmark.circle"
            case .checking: return "arrow.clockwise.circle"
            case .missing, .failed: return "exclamationmark.triangle.fill"
            }
        }

        private var statusColor: Color {
            switch diagnostic.state {
            case .ready: return .green
            case .disabled, .unsupportedRemote: return .secondary
            case .found, .checking: return .blue
            case .missing, .failed: return .orange
            }
        }

        private func refresh(force: Bool) {
            let currentMode = mode
            if !force {
                diagnostic = CodexComputerUseMCP.diagnose(mode: currentMode, refresh: false)
                return
            }

            let current = CodexComputerUseMCP.diagnose(mode: currentMode, refresh: false)
            diagnostic = CodexComputerUseDiagnostic(
                state: .checking,
                title: "Checking",
                detail: "Starting Computer Use MCP and reading its tool list on this device.",
                command: current.command,
                cwd: current.cwd
            )
            isChecking = true
            Task {
                let result = await Task.detached(priority: .userInitiated) {
                    CodexComputerUseMCP.diagnose(mode: currentMode, refresh: true)
                }.value
                guard !Task.isCancelled else { return }
                if mode == currentMode {
                    diagnostic = result
                }
                isChecking = false
            }
        }

        private func infoRow(_ label: String, _ value: String) -> some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                Text(value)
                    .font(DS.monoFontSmall)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }

        private func section<Content: View>(_ title: String,
                                            @ViewBuilder content: () -> Content) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(.tertiary)
                content()
            }
            .padding(14)
            .frame(maxWidth: 520, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.cornerRadius, style: .continuous)
                    .fill(Color.helmCard)
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.cornerRadius, style: .continuous)
                            .stroke(Color.helmBorder, lineWidth: 1)
                    )
            )
        }
    }

    private struct ArchivedConversationsSettingsView: View {
        @Environment(AppStore.self) private var store

        private var archivedSessions: [Session] {
            store.archivedSessions
        }

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if archivedSessions.isEmpty {
                        emptyState
                    } else {
                        archivedList
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.helmChatBg)
        }

        private var header: some View {
            HStack(spacing: 10) {
                Image(systemName: "archivebox")
                    .font(.system(size: 21, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Archived Conversations")
                        .font(.system(size: 16, weight: .semibold))
                    Text(archivedSessions.count == 1 ? "1 conversation" : "\(archivedSessions.count) conversations")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }

        private var emptyState: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text("No archived conversations.")
                    .font(.system(size: 12, weight: .semibold))
                Text("Finished Project Inbox sessions will appear here.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: 560, alignment: .leading)
            .background(listBackground)
        }

        private var archivedList: some View {
            VStack(spacing: 0) {
                ForEach(Array(archivedSessions.enumerated()), id: \.element.id) { pair in
                    let index = pair.offset
                    let session = pair.element
                    archivedRow(session)
                    if index < archivedSessions.count - 1 {
                        Divider()
                            .padding(.leading, 42)
                    }
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
            .background(listBackground)
        }

        private func archivedRow(_ session: Session) -> some View {
            let project = store.projects.first { $0.id == session.projectId }
            return HStack(alignment: .top, spacing: 10) {
                Image(systemName: project?.location.isSSH == true ? "cloud" : "folder")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 6) {
                        Text(projectKind(project))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(project?.name ?? "Missing project")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Text(projectPath(project))
                        .font(DS.monoFontSmall)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text("Archived \(Self.archiveFormatter.string(from: session.archivedAt ?? .distantPast))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 12)

                Button {
                    store.unarchiveSession(session.id)
                } label: {
                    Text("Unarchive")
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }

        private var listBackground: some View {
            RoundedRectangle(cornerRadius: DS.cornerRadius, style: .continuous)
                .fill(Color.helmCard)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.cornerRadius, style: .continuous)
                        .stroke(Color.helmBorder, lineWidth: 1)
                )
        }

        private func projectKind(_ project: Project?) -> String {
            guard let project else { return "missing" }
            return project.location.isSSH ? "remote" : "local"
        }

        private func projectPath(_ project: Project?) -> String {
            guard let project else { return "Project was removed" }
            switch project.location {
            case .local(let path):
                return path
            case .ssh(let host, let path, let status):
                let resolvedPath = status.resolvedPath?.isEmpty == false
                    ? status.resolvedPath!
                    : path
                return "\(host):\(resolvedPath)"
            }
        }

        private static let archiveFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter
        }()
    }

    private struct SSHProfileSettingsView: View {
        @Environment(AppStore.self) private var store
        let project: Project

        @State private var scan: RemoteCodexProviderScan?
        @State private var scanError: String?
        @State private var isScanning = false

        private var host: String {
            if case .ssh(let host, _, _) = project.location { return host }
            return ""
        }

        private var path: String {
            project.location.pathString
        }

        private var createdProfiles: [Profile] {
            store.remoteProfiles(forSSHProject: project.id)
        }

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    localProfilesSection
                    createdProfilesSection
                    remoteClaudeConfigSection
                    remoteCodexConfigSection
                    SavedIndicator(source: .state)
                }
                .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.helmChatBg)
            .onAppear { refresh(force: false) }
        }

        private var header: some View {
            HStack(spacing: 10) {
                Image(systemName: "terminal")
                    .font(.system(size: 21, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(project.name)
                        .font(.system(size: 16, weight: .semibold))
                    Text(host.isEmpty ? path : "\(host) · \(path)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button {
                    refresh(force: true)
                } label: {
                    if isScanning {
                        Label("Scanning", systemImage: "arrow.clockwise")
                    } else {
                        Label("Scan", systemImage: "arrow.clockwise")
                    }
                }
                .controlSize(.small)
                .disabled(isScanning || host.isEmpty)
            }
        }

        private var localProfilesSection: some View {
            section("Local profiles") {
                if store.globalProfiles.isEmpty {
                    Text("No global profiles.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(store.globalProfiles) { profile in
                            Toggle(isOn: Binding(
                                get: {
                                    store.isGlobalProfileAllowed(profile.id,
                                                                 inSSHProject: project.id)
                                },
                                set: { allowed in
                                    store.setGlobalProfile(profile.id,
                                                           allowed: allowed,
                                                           forSSHProject: project.id)
                                }
                            )) {
                                profileSummary(profile)
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
            }
        }

        private var createdProfilesSection: some View {
            section("Created remote profiles") {
                if createdProfiles.isEmpty {
                    Text("No remote-only profiles yet.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(createdProfiles) { profile in
                            HStack(spacing: 8) {
                                VendorBadge(vendor: profile.vendor).frame(width: 16, height: 16)
                                profileSummary(profile)
                                Spacer()
                                Button(role: .destructive) {
                                    store.deleteProfile(profile.id)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 11, weight: .medium))
                                        .frame(width: 20, height: 20)
                                }
                                .buttonStyle(.plain)
                                .help("Delete \(profile.name)")
                                .accessibilityLabel("Delete \(profile.name)")
                            }
                        }
                    }
                }
            }
        }

        private var remoteClaudeConfigSection: some View {
            section("Remote Claude config") {
                if isScanning {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Checking \(host)'s Claude Code installation")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                } else if let scanError {
                    Label(scanError, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.red)
                } else if let claude = scan?.claude {
                    remoteClaudeBlock(claude)
                } else if scan != nil {
                    Text("No Claude Code CLI found on this SSH host.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Scan this SSH host to list its Claude Code subscription profile.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
        }

        private var remoteCodexConfigSection: some View {
            section("Remote Codex config") {
                if isScanning {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Reading \(host)'s ~/.codex/config.toml")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                } else if let scanError {
                    Label(scanError, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.red)
                } else if let scan, scan.providers.isEmpty {
                    Text("No Codex config found in \(scan.configPath).")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                } else if let scan {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(scan.providers) { provider in
                            remoteProviderBlock(provider)
                        }
                    }
                } else {
                    Text("Scan this SSH host to list its Codex config provider and profiles.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
        }

        private func remoteClaudeBlock(_ candidate: RemoteClaudeProviderCandidate) -> some View {
            let exists = createdProfiles.contains { profile in
                profile.vendor == .claude &&
                profile.commandPath == candidate.commandPath &&
                store.model(profile.primaryModelId)?.providerModelId == RemoteClaudeProviderCandidate.defaultModelId
            }
            return VStack(alignment: .leading, spacing: 9) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Provider")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    HStack(spacing: 8) {
                        VendorBadge(vendor: .claude).frame(width: 16, height: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(candidate.displayName)
                                .font(.system(size: 12.5, weight: .semibold))
                            Text(candidate.authDescription)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                    }
                    infoRow("Command", candidate.commandPath)
                }

                HStack(spacing: 8) {
                    Image(systemName: exists ? "checkmark.circle.fill" : "plus.circle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(exists ? .green : .secondary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Default Claude Code config")
                            .font(.system(size: 12))
                        Text("Uses remote subscription and model defaults")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button(exists ? "Created" : "Create profile") {
                        _ = store.createRemoteClaudeProfile(candidate,
                                                            forSSHProject: project.id)
                    }
                    .controlSize(.small)
                    .disabled(exists)
                }
            }
            .padding(.vertical, 2)
        }

        private func remoteProviderBlock(_ provider: RemoteCodexProviderCandidate) -> some View {
            VStack(alignment: .leading, spacing: 9) {
                remoteProviderSummary(provider)
                if provider.profiles.isEmpty {
                    Text("No profiles reference this provider.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Profiles")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        ForEach(provider.profiles) { candidate in
                            remoteProfileCandidateRow(candidate, provider: provider)
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }

        private func remoteProviderSummary(_ provider: RemoteCodexProviderCandidate) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                Text("Provider")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
                HStack(spacing: 8) {
                    VendorBadge(vendor: .codex).frame(width: 16, height: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(provider.displayName)
                            .font(.system(size: 12.5, weight: .semibold))
                        Text(provider.key)
                            .font(DS.monoFontSmall)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                if !provider.baseURL.isEmpty {
                    infoRow("Base URL", provider.baseURL)
                }
            }
        }

        private func remoteProfileCandidateRow(_ candidate: RemoteCodexProfileCandidate,
                                               provider: RemoteCodexProviderCandidate) -> some View {
            let exists = createdProfiles.contains { profile in
                profile.delegateVendorProfile == candidate.profileName &&
                store.provider(profile.providerId)?.remoteCodexProviderKey == provider.remoteConfigKey &&
                store.model(profile.primaryModelId)?.providerModelId == candidate.modelId
            }
            return HStack(spacing: 8) {
                Image(systemName: exists ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(exists ? .green : .secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(candidate.displayName)
                        .font(.system(size: 12))
                    Text(candidate.modelId)
                        .font(DS.monoFontSmall)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button(exists ? "Created" : "Create profile") {
                    _ = store.createRemoteCodexProfile(candidate,
                                                       provider: provider,
                                                       forSSHProject: project.id)
                }
                .controlSize(.small)
                .disabled(exists)
            }
        }

        private func profileSummary(_ profile: Profile) -> some View {
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name)
                    .font(.system(size: 12.5))
                Text(profileSubtitle(profile))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }

        private func profileSubtitle(_ profile: Profile) -> String {
            let model = store.model(profile.primaryModelId)?.label ?? "missing model"
            if profile.sshProjectId == nil {
                return "\(profile.vendor.displayName) · \(model)"
            }
            if profile.vendor == .claude {
                return "Remote Claude Code · \(model)"
            }
            if let delegate = profile.delegateVendorProfile, !delegate.isEmpty {
                return "Remote Codex profile \(delegate) · \(model)"
            }
            if store.provider(profile.providerId)?.remoteCodexProviderKey == nil {
                return "Remote Codex default · \(model)"
            }
            return "Remote Codex provider · \(model)"
        }

        private func infoRow(_ label: String, _ value: String) -> some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                Text(value)
                    .font(DS.monoFontSmall)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }

        private func refresh(force: Bool) {
            if !force, scan != nil || isScanning { return }
            guard !host.isEmpty else { return }
            isScanning = true
            scanError = nil
            Task {
                do {
                    let result = try await RemoteCodexProviderDiscovery.scan(host: host)
                    guard !Task.isCancelled else { return }
                    scan = result
                } catch {
                    guard !Task.isCancelled else { return }
                    scan = nil
                    scanError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
                isScanning = false
            }
        }

        private func section<Content: View>(_ title: String,
                                            @ViewBuilder content: () -> Content) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(.tertiary)
                content()
            }
            .padding(14)
            .frame(maxWidth: 560, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.cornerRadius, style: .continuous)
                    .fill(Color.helmCard)
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.cornerRadius, style: .continuous)
                            .stroke(Color.helmBorder, lineWidth: 1)
                    )
            )
        }
    }

    // MARK: - Bindings

    private func providerBinding(_ id: UUID) -> Binding<Provider>? {
        guard store.globalProviders.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { store.providers.first { $0.id == id }! },
            set: { store.upsertProvider($0) }
        )
    }

    private func modelBinding(_ id: UUID) -> Binding<Model>? {
        guard store.models.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { store.models.first { $0.id == id }! },
            set: { store.upsertModel($0) }
        )
    }

    private func profileBinding(_ id: UUID) -> Binding<Profile>? {
        guard store.globalProfiles.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { store.profiles.first { $0.id == id }! },
            set: { store.upsertProfile($0) }
        )
    }

    // MARK: - Add actions

    private func addProvider(_ vendor: Vendor) {
        let p = Provider.newDefault(vendor: vendor, name: "new-\(vendor.rawValue)")
        store.upsertProvider(p)
        expanded.insert(p.id)
        selection = .provider(p.id)
    }

    /// Called by AddModelsSheet's onAdd callback. Each catalog entry becomes
    /// a Model row with empty alias — the user fills aliases later in the
    /// per-model editor.
    private func handleAdd(_ entries: [ModelCatalogEntry], to provider: Provider) {
        var lastId: UUID? = nil
        for entry in entries {
            let m = Model(id: UUID(),
                          providerId: provider.id,
                          providerModelId: entry.id,
                          alias: "")
            store.upsertModel(m)
            lastId = m.id
        }
        expanded.insert(provider.id)
        if entries.count == 1, let id = lastId {
            // Single add → jump straight to the editor so the user can name it.
            selection = .model(id)
        }
    }

    private func addProfile(_ vendor: Vendor) {
        guard let provider = store.providers(for: vendor).first else { return }
        guard let model = store.models(in: provider.id).first else { return }
        let p = Profile(
            id: UUID(),
            name: "new-\(vendor.rawValue)",
            vendor: vendor,
            providerId: provider.id,
            primaryModelId: model.id,
            commandPath: "",
            configRoot: nil,
            opusModelId: nil, sonnetModelId: nil, haikuModelId: nil,
            subagentModelId: nil,
            autoCompactWindow: nil,
            reasoningEffort: nil, serviceTier: nil, sandboxMode: nil,
            approvalMode: nil,
            delegateVendorProfile: nil
        )
        store.upsertProfile(p)
        selection = .profile(p.id)
    }

    private func hasViableProfileTargets(_ vendor: Vendor) -> Bool {
        store.providers(for: vendor).contains { provider in
            !store.models(in: provider.id).isEmpty
        }
    }

    private func toggleExpanded(_ id: UUID) {
        if expanded.contains(id) { expanded.remove(id) }
        else { expanded.insert(id) }
    }

    private func syncSelection() {
        if selection == nil {
            selection = .appearance
        }
        if expanded.isEmpty {
            // Default-expand all providers on first open so models are visible.
            expanded = Set(store.globalProviders.map(\.id))
        }
    }
}
