import AppKit
import CryptoKit
import Darwin
import SwiftUI

struct ComposerView: View {
    @Environment(AppStore.self) private var store
    @AppStorage(CodexComputerUseMode.userDefaultsKey) private var computerUseModeRawValue = CodexComputerUseMode.automatic.rawValue
    var externalFocusRequest: Int = 0
    @State private var text: String = ""
    @State private var pickerOpen: Bool = false
    @State private var attachments: [ImageAttachment] = []
    @State private var selectedSkills: [ComposerSkill] = []
    @State private var draftSessionId: UUID?
    @State private var drafts: [UUID: ComposerDraft] = [:]
    @State private var pasteMonitor: Any? = nil
    @State private var focusRequest = 0
    @State private var footerWidth: CGFloat = 0
    @State private var composerInteractionResetRequest = 0
    @State private var activeBuiltinAction: BuiltinAction.Kind?
    @State private var goalActionActive = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                inner
            }
            .frame(maxWidth: DS.messageMaxWidth)
            .background(ComposerWidthReader(width: $footerWidth))
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color.helmChatBg)
        .onAppear {
            loadDraft(for: store.selectedSessionId)
            installPasteMonitor()
            requestComposerFocus()
        }
        .onChange(of: store.selectedSessionId) { _, newSessionId in
            saveCurrentDraft()
            loadDraft(for: newSessionId)
            activeBuiltinAction = nil
            requestComposerFocus()
        }
        .onChange(of: pickerOpen) { _, isOpen in
            if !isOpen {
                requestComposerFocus()
            }
        }
        .onChange(of: externalFocusRequest) { _, _ in
            requestComposerFocus()
        }
        .onDisappear {
            removePasteMonitor()
        }
    }

    private func requestComposerFocus() {
        focusRequest += 1
    }

    private func refocusComposerAfterMenuSelection() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            requestComposerFocus()
        }
    }

    private var inner: some View {
        VStack(spacing: 6) {
            box
            footer
        }
    }

    private var box: some View {
        SkillAwareComposerBox(
            text: $text,
            skillChips: $selectedSkills,
            placeholder: composerPlaceholder,
            minLines: 2,
            maxLines: 11,
            focusRequest: focusRequest,
            resetRequest: composerInteractionResetRequest,
            menuWidthSource: footerWidth,
            textTopPadding: attachments.isEmpty ? 8 : 6,
            skillProfile: selectedProfile,
            skillProject: selectedProject,
            onSlashActivityChange: { isActive in
                if isActive {
                    activeBuiltinAction = nil
                }
            },
            onSend: sendIfPossible,
            topContent: {
                if !attachments.isEmpty {
                    attachmentRow
                }
            },
            accessoryOverlay: { slashMenuVisible in
                if let activeBuiltinAction, !slashMenuVisible {
                    let height = builtinActionPanelHeight(for: activeBuiltinAction)
                    BuiltinActionPanel(
                        kind: activeBuiltinAction,
                        onClose: closeBuiltinActionPanel
                    )
                    .frame(width: builtinActionPanelWidth, height: height)
                    .offset(x: 0, y: -(height + 8))
                    .transition(.opacity.combined(with: .scale(scale: 0.985, anchor: .bottomLeading)))
                    .zIndex(9)
                }
            }
        )
        .animation(.easeOut(duration: 0.10), value: activeBuiltinAction)
        .animation(.easeOut(duration: 0.10), value: goalActionActive)
    }

    private var hasComposerContent: Bool {
        !selectedSkills.isEmpty
            || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !attachments.isEmpty
    }

    private var composerPlaceholder: String {
        if let status = store.selectedSSHStatus,
           !status.isConnected {
            return status.isConnecting ? "Checking SSH connection..." : "Reconnect SSH to send"
        }
        let vendor = store.selectedSession
            .flatMap { store.profile($0.profileId) }?
            .vendor.displayName ?? "agent"
        return "Message \(vendor) (⌘V to attach image · ⌘↵ to send)"
    }

    private var canSubmit: Bool {
        if store.selectedSessionIsStreaming { return true }
        if selectedSSHSendBlockReason != nil { return false }
        return hasComposerContent
    }

    private var submitButtonTitle: String {
        if store.selectedSessionIsStreaming { return "Stop" }
        return "Send"
    }

    private var submitButtonColor: Color {
        if store.selectedSessionIsStreaming { return .red }
        if selectedSSHSendBlockReason != nil { return .secondary.opacity(0.45) }
        return .accentColor
    }

    private var submitButtonHelp: String {
        if store.selectedSessionIsStreaming { return "Stop current response" }
        if let reason = selectedSSHSendBlockReason { return reason }
        return "Send message"
    }

    private var selectedSSHSendBlockReason: String? {
        guard let status = store.selectedSSHStatus,
              !status.isConnected
        else { return nil }
        switch status {
        case .connected:
            return nil
        case .connecting:
            return "SSH connection is still being checked"
        case .failed(let reason):
            return "SSH connection failed: \(reason)"
        }
    }

    private func sendIfPossible() {
        if store.selectedSessionIsStreaming {
            store.cancelStreaming()
            return
        }
        if !hasComposerContent || selectedSSHSendBlockReason != nil {
            return
        }
        let toSend = composedPrompt()
        let agentPrompt = goalActionActive ? Self.promptWithGoalAction(toSend) : toSend
        let displayParts = composerDisplayParts()
        let toSendAttachments = attachments
        let goalEvent: SessionEvent? = goalActionActive
            ? .goalApplied(id: UUID(),
                           goal: toSend,
                           vendor: selectedVendor,
                           appliedAt: Date())
            : nil
        text = ""
        selectedSkills = []
        attachments = []
        activeBuiltinAction = nil
        goalActionActive = false
        if let sessionId = draftSessionId {
            drafts[sessionId] = nil
        }
        store.send(toSend,
                   displayParts: displayParts,
                   attachments: toSendAttachments,
                   agentPrompt: agentPrompt,
                   preUserEvents: goalEvent.map { [$0] } ?? [])
    }

    private func composedPrompt() -> String {
        ComposerPromptSerializer.serialize(text,
                                           skillChips: selectedSkills,
                                           vendor: selectedVendor)
    }

    private func composerDisplayParts() -> [Part] {
        ComposerPromptSerializer.displayParts(text,
                                              skillChips: selectedSkills,
                                              fallbackText: composedPrompt())
    }

    private var selectedVendor: Vendor {
        selectedProfile?.vendor ?? .codex
    }

    private var selectedProfile: Profile? {
        store.selectedSession.flatMap { store.profile($0.profileId) }
    }

    private var selectedProject: Project? {
        guard let session = store.selectedSession else { return nil }
        return store.project(for: session.id)
    }

    private static func promptWithGoalAction(_ prompt: String) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/goal" }
        return "/goal \(trimmed)"
    }

    // MARK: - Built-in actions

    private var builtinActionPanelWidth: CGFloat {
        guard footerWidth > 0 else { return 620 }
        return min(680, max(320, footerWidth))
    }

    private func builtinActionPanelHeight(for kind: BuiltinAction.Kind) -> CGFloat {
        switch kind {
        case .status:
            return 246
        case .compact:
            return 156
        case .goal:
            return 156
        case .help:
            return 286
        }
    }

    private func builtinActionButton(profile: Profile?) -> some View {
        let vendor = profile?.vendor ?? selectedVendor
        return Menu {
            ForEach(BuiltinAction.catalog(for: vendor)) { action in
                Button {
                    selectBuiltinAction(action.kind)
                } label: {
                    Label(action.title, systemImage: action.symbolName)
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("\(vendor.displayName) actions")
        .accessibilityLabel("\(vendor.displayName) actions")
    }

    private func selectBuiltinAction(_ kind: BuiltinAction.Kind) {
        composerInteractionResetRequest &+= 1
        switch kind {
        case .compact:
            sendBuiltinCommand(BuiltinAction.definition(for: kind, vendor: selectedVendor).commandName)
        case .goal:
            goalActionActive = true
            activeBuiltinAction = nil
            refocusComposerAfterMenuSelection()
        case .status, .help:
            activeBuiltinAction = kind
        }
    }

    private func closeBuiltinActionPanel() {
        activeBuiltinAction = nil
        requestComposerFocus()
    }

    private func sendBuiltinCommand(_ command: String) {
        guard !store.selectedSessionIsStreaming,
              selectedSSHSendBlockReason == nil
        else {
            requestComposerFocus()
            return
        }
        activeBuiltinAction = nil
        store.send(command, displayParts: [.text(command)], attachments: [])
        refocusComposerAfterMenuSelection()
    }

    // MARK: - Goal

    @ViewBuilder
    private var goalActionChip: some View {
        if goalActionActive {
            HStack(spacing: 6) {
                Image(systemName: "target")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                Text("Goal")
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                Button {
                    goalActionActive = false
                    requestComposerFocus()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Remove goal action")
                .accessibilityLabel("Remove goal action")
            }
            .padding(.leading, 8)
            .padding(.trailing, 4)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: DS.cornerRadiusSmall)
                    .fill(Color.accentColor.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.cornerRadiusSmall)
                            .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
                    )
            )
            .fixedSize()
            .help("Send the next prompt to \(selectedVendor.displayName) as /goal")
            .accessibilityLabel("Goal action active")
        }
    }

    private var attachmentRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { att in
                    attachmentChip(att)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
        }
    }

    private func attachmentChip(_ att: ImageAttachment) -> some View {
        Group {
            if let img = NSImage(contentsOf: att.fileURL) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.secondary.opacity(0.15)
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.helmBorderStrong, lineWidth: 0.5)
        )
        .overlay(alignment: .topTrailing) {
            // .overlay (not ZStack + offset) keeps the button's hit area
            // inside the chip's layout frame; offset moves visuals but leaves
            // hit-testing at the original position, which is why the earlier
            // version of this button looked clickable but did nothing.
            Button {
                removeAttachment(att)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.7))
            }
            .buttonStyle(.plain)
            .padding(2)
        }
        .padding(.top, 6)
        .padding(.trailing, 6)
    }

    private var footer: some View {
        let session = store.selectedSession
        let profile = session.flatMap { store.profile($0.profileId) }
        let model = profile.flatMap { store.model($0.primaryModelId) }
        let modelLabel = model?.label ?? "no model"
        let configLocked = session.map { store.isSessionStreaming($0.id) } ?? false

        return Group {
            if footerWidth >= 600 {
                wideFooter(session: session,
                           profile: profile,
                           modelLabel: modelLabel,
                           configLocked: configLocked)
            } else {
                compactFooter(session: session,
                              profile: profile,
                              modelLabel: modelLabel,
                              configLocked: configLocked)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .padding(.top, 4)
    }

    private func wideFooter(session: Session?,
                            profile: Profile?,
                            modelLabel: String,
                            configLocked: Bool) -> some View {
        HStack(spacing: 8) {
            builtinActionButton(profile: profile)
            goalActionChip
            modelPickerButton(profile: profile,
                              modelLabel: modelLabel,
                              configLocked: configLocked,
                              maxWidth: 240)
            runConfigControls(session: session, profile: profile)
            sshStatusControl
            Spacer(minLength: 8)
            sendShortcut
            submitButton
        }
    }

    private func compactFooter(session: Session?,
                               profile: Profile?,
                               modelLabel: String,
                               configLocked: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                builtinActionButton(profile: profile)
                goalActionChip
                modelPickerButton(profile: profile,
                                  modelLabel: modelLabel,
                                  configLocked: configLocked,
                                  maxWidth: .infinity)
                Spacer(minLength: 8)
                sendShortcut
                submitButton
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    runConfigControls(session: session, profile: profile)
                    sshStatusControl
                }
                .padding(.vertical, 1)
            }
        }
    }

    private func modelPickerButton(profile: Profile?,
                                   modelLabel: String,
                                   configLocked: Bool,
                                   maxWidth: CGFloat) -> some View {
        Button { pickerOpen.toggle() } label: {
            HStack(spacing: 6) {
                if let profile {
                    VendorBadge(vendor: profile.vendor).frame(width: 14, height: 14)
                }
                Text(modelLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: maxWidth, alignment: .leading)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $pickerOpen, arrowEdge: .bottom) {
            ModelPickerMenu().frame(width: 360)
        }
        .disabled(configLocked)
        .help(runConfigHelp(configLocked, "Change model"))
    }

    @ViewBuilder
    private func runConfigControls(session: Session?, profile: Profile?) -> some View {
        if let session, let profile {
            switch profile.vendor {
            case .claude:
                claudePermissionChip(session: session)
                claudeEffortChip(session: session)
                computerUseChip(session: session)
            case .codex:
                codexSandboxChip(session: session)
                codexApprovalChip(session: session)
                codexEffortChip(session: session)
                computerUseChip(session: session)
            }
        }
    }

    @ViewBuilder
    private var sshStatusControl: some View {
        if let sshStatus = store.selectedSSHStatus {
            sshStatusChip(sshStatus)
        }
    }

    private var sendShortcut: some View {
        Text("⌘↵")
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
    }

    private var submitButton: some View {
        Button {
            sendIfPossible()
        } label: {
            Text(submitButtonTitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(submitButtonColor)
                )
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!canSubmit)
        .help(submitButtonHelp)
    }

    private func runConfigHelp(_ isLocked: Bool, _ unlockedHelp: String) -> String {
        isLocked ? "Cannot change while response is running" : unlockedHelp
    }

    private func computerUseChipText(_ mode: CodexComputerUseMode) -> String {
        switch mode {
        case .automatic: return "CU auto"
        case .enabled: return "CU on"
        case .disabled: return "CU off"
        }
    }

    private func computerUseHelp(isLocked: Bool,
                                 isRemote: Bool,
                                 mode: CodexComputerUseMode) -> String {
        if isLocked {
            return "Cannot change while response is running"
        }
        if isRemote {
            return "Computer Use is local-only and is skipped for SSH sessions."
        }
        return mode.helpText
    }

    private func sshStatusChip(_ status: SSHStatus) -> some View {
        HStack(spacing: 5) {
            if status.isConnecting {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.5)
                    .frame(width: 10, height: 10)
            } else {
                Circle()
                    .fill(status.color)
                    .frame(width: 6, height: 6)
            }
            Text(status.shortLabel)
                .font(.system(size: 12))
                .foregroundStyle(status.isConnected ? Color.secondary : status.color)
                .lineLimit(1)
            if !status.isConnected && !status.isConnecting {
                Button {
                    store.retrySelectedSSHProject()
                    refocusComposerAfterMenuSelection()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .help("Check SSH connection")
                .accessibilityLabel("Check SSH connection")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(
            RoundedRectangle(cornerRadius: DS.cornerRadiusSmall)
                .fill(Color.helmCard)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.cornerRadiusSmall)
                        .stroke(Color.helmBorder, lineWidth: 1)
                )
        )
        .help(status.helpText)
    }

    private func claudePermissionChip(session: Session) -> some View {
        let isLocked = store.isSessionStreaming(session.id)
        return Menu {
            ForEach(ClaudePermissionMode.allCases, id: \.self) { mode in
                Button {
                    store.setClaudePermission(mode, on: session.id)
                    refocusComposerAfterMenuSelection()
                } label: {
                    menuSelectionLabel(mode.displayName,
                                       selected: mode == session.claudePermissionMode)
                }
            }
        } label: {
            chipLabel(icon: "lock.shield", text: session.claudePermissionMode.displayName)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(isLocked)
        .help(runConfigHelp(isLocked, "Claude --permission-mode"))
    }

    private func codexSandboxChip(session: Session) -> some View {
        let isLocked = store.isSessionStreaming(session.id)
        return Menu {
            ForEach(Profile.SandboxMode.allCases, id: \.self) { mode in
                Button {
                    store.setCodexSandbox(mode, on: session.id)
                    refocusComposerAfterMenuSelection()
                } label: {
                    menuSelectionLabel(mode.displayName,
                                       selected: mode == session.codexSandboxMode)
                }
            }
        } label: {
            chipLabel(icon: "lock.shield", text: session.codexSandboxMode.displayName)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(isLocked)
        .help(runConfigHelp(isLocked, "Codex sandbox_mode"))
    }

    private func codexApprovalChip(session: Session) -> some View {
        let isLocked = store.isSessionStreaming(session.id)
        return Menu {
            ForEach(CodexApprovalMode.allCases, id: \.self) { mode in
                Button {
                    store.setCodexApproval(mode, on: session.id)
                    refocusComposerAfterMenuSelection()
                } label: {
                    menuSelectionLabel(mode.displayName,
                                       selected: mode == session.codexApprovalMode)
                }
            }
        } label: {
            chipLabel(icon: "hand.raised", text: session.codexApprovalMode.displayName)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(isLocked)
        .help(runConfigHelp(isLocked, "Codex approval_policy"))
    }

    private func claudeEffortChip(session: Session) -> some View {
        let isLocked = store.isSessionStreaming(session.id)
        return Menu {
            ForEach(ClaudeEffort.allCases, id: \.self) { mode in
                Button {
                    store.setClaudeEffort(mode, on: session.id)
                    refocusComposerAfterMenuSelection()
                } label: {
                    menuSelectionLabel(mode.displayName,
                                       selected: mode == session.claudeEffort)
                }
            }
        } label: {
            chipLabel(icon: "bolt", text: session.claudeEffort.displayName)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(isLocked)
        .help(runConfigHelp(isLocked, "Claude --effort"))
    }

    private func codexEffortChip(session: Session) -> some View {
        let isLocked = store.isSessionStreaming(session.id)
        return Menu {
            ForEach(Profile.ReasoningEffort.allCases, id: \.self) { mode in
                Button {
                    store.setCodexEffort(mode, on: session.id)
                    refocusComposerAfterMenuSelection()
                } label: {
                    menuSelectionLabel(mode.displayName,
                                       selected: mode == session.codexEffort)
                }
            }
        } label: {
            chipLabel(icon: "bolt", text: session.codexEffort.displayName)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(isLocked)
        .help(runConfigHelp(isLocked, "Codex model_reasoning_effort"))
    }

    private func computerUseChip(session: Session) -> some View {
        let isLocked = store.isSessionStreaming(session.id)
        let isRemote = store.selectedProject?.location.isSSH == true
        let current = CodexComputerUseMode(rawValue: computerUseModeRawValue) ?? .automatic
        return Menu {
            ForEach(CodexComputerUseMode.allCases) { mode in
                Button {
                    computerUseModeRawValue = mode.rawValue
                    refocusComposerAfterMenuSelection()
                } label: {
                    menuSelectionLabel(mode.displayName,
                                       selected: mode == current)
                }
            }
            Divider()
            if isRemote {
                Text("SSH sessions skip local Computer Use")
            } else {
                Text(CodexComputerUseMCP.diagnose(mode: current).title)
            }
        } label: {
            chipLabel(icon: "cursorarrow.motionlines",
                      text: isRemote ? "CU off" : computerUseChipText(current))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(isLocked)
        .help(computerUseHelp(isLocked: isLocked, isRemote: isRemote, mode: current))
    }

    private func chipLabel(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
            Image(systemName: "chevron.down").font(.system(size: 8)).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func menuSelectionLabel(_ text: String, selected: Bool) -> some View {
        if selected {
            Label {
                Text(text)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.accentColor)
            } icon: {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.accentColor)
            }
        } else {
            Text(text)
        }
    }

    // MARK: - Paste handling
    //
    // TextEditor's underlying NSTextView swallows ⌘V before SwiftUI's
    // `.onPasteCommand` ever sees it (NSTextView only knows how to paste text,
    // so an image-only pasteboard turns into a silent no-op). To make image
    // pastes work we install an NSEvent local monitor at the app level: when
    // ⌘V fires, peek at NSPasteboard. If there's an image on it, eat the
    // event and append. If not, return the event so TextEditor handles text
    // paste normally.

    private func installPasteMonitor() {
        guard pasteMonitor == nil else { return }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard isCommandV(event) else { return event }
            return tryPasteImagesFromPasteboard() ? nil : event
        }
    }

    private func removePasteMonitor() {
        if let m = pasteMonitor { NSEvent.removeMonitor(m) }
        pasteMonitor = nil
    }

    private func isCommandV(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), !flags.contains(.shift), !flags.contains(.option), !flags.contains(.control) else {
            return false
        }
        let chars = (event.charactersIgnoringModifiers ?? "").lowercased()
        return chars == "v"
    }

    /// Returns true if the pasteboard had image data and we consumed it.
    private func tryPasteImagesFromPasteboard() -> Bool {
        let pb = NSPasteboard.general
        guard pb.canReadObject(forClasses: [NSImage.self], options: nil) else { return false }

        var pngs: [Data] = []
        if let items = pb.pasteboardItems {
            for item in items {
                if let png = item.data(forType: .png) {
                    pngs.append(png)
                } else if let tiff = item.data(forType: .tiff),
                          let rep = NSBitmapImageRep(data: tiff),
                          let png = rep.representation(using: .png, properties: [:]) {
                    pngs.append(png)
                } else if let jpeg = item.data(forType: NSPasteboard.PasteboardType("public.jpeg")),
                          let rep = NSBitmapImageRep(data: jpeg),
                          let png = rep.representation(using: .png, properties: [:]) {
                    pngs.append(png)
                }
            }
        }
        // Fallback: NSImage round-trip if direct items didn't yield bytes.
        if pngs.isEmpty,
           let images = pb.readObjects(forClasses: [NSImage.self]) as? [NSImage] {
            for img in images {
                guard let tiff = img.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else { continue }
                pngs.append(png)
            }
        }
        guard !pngs.isEmpty else { return false }
        for png in pngs { saveAndAppend(png: png) }
        return true
    }

    private func saveAndAppend(png: Data) {
        guard let session = store.selectedSession else { return }
        let hash = md5Hex(png)
        // Dedupe: if the same image is already attached (e.g. user pastes the
        // same screenshot twice), drop it silently — the second paste is
        // almost always a finger-stutter, not a deliberate re-attach.
        if attachments.contains(where: { $0.contentHash == hash }) { return }

        let dir = AppPaths.imagesDir(for: session.id)
        let url = dir.appendingPathComponent("\(UUID().uuidString.lowercased()).png")
        do {
            try png.write(to: url, options: .atomic)
            attachments.append(ImageAttachment(fileURL: url,
                                               mediaType: "image/png",
                                               contentHash: hash))
        } catch {
            NSLog("[helm.composer] paste write failed: %@", error.localizedDescription)
        }
    }

    private func md5Hex(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func removeAttachment(_ att: ImageAttachment) {
        attachments.removeAll { $0.id == att.id }
        try? FileManager.default.removeItem(at: att.fileURL)
    }

    private func saveCurrentDraft() {
        guard let sessionId = draftSessionId else { return }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && attachments.isEmpty
            && selectedSkills.isEmpty
            && !goalActionActive {
            drafts[sessionId] = nil
        } else {
            drafts[sessionId] = ComposerDraft(text: text,
                                              attachments: attachments,
                                              selectedSkills: selectedSkills,
                                              goalActionActive: goalActionActive)
        }
    }

    private func loadDraft(for sessionId: UUID?) {
        draftSessionId = sessionId
        composerInteractionResetRequest &+= 1
        guard let sessionId, let draft = drafts[sessionId] else {
            text = ""
            attachments = []
            selectedSkills = []
            goalActionActive = false
            return
        }
        text = draft.text
        attachments = draft.attachments
        selectedSkills = draft.selectedSkills
        goalActionActive = draft.goalActionActive
    }
}

enum ComposerPromptSerializer {
    static func serialize(_ text: String,
                          skillChips: [ComposerSkill],
                          vendor: Vendor) -> String {
        var output = ""
        var skillIndex = 0
        for character in text {
            if String(character) == ComposerTextView.attachmentPlaceholder,
               skillIndex < skillChips.count {
                output += skillCommand(for: skillChips[skillIndex], vendor: vendor)
                skillIndex += 1
            } else {
                output.append(character)
            }
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func displayParts(_ text: String,
                             skillChips: [ComposerSkill],
                             fallbackText: String) -> [Part] {
        guard text.contains(ComposerTextView.attachmentPlaceholder),
              !skillChips.isEmpty
        else {
            return fallbackText.isEmpty ? [] : [.text(fallbackText)]
        }

        var segments: [SkillTextSegment] = []
        var textBuffer = ""
        var skillIndex = 0

        func flushText() {
            guard !textBuffer.isEmpty else { return }
            segments.append(.text(textBuffer))
            textBuffer = ""
        }

        for character in text {
            if String(character) == ComposerTextView.attachmentPlaceholder,
               skillIndex < skillChips.count {
                flushText()
                segments.append(.skill(skillChips[skillIndex].name))
                skillIndex += 1
            } else {
                textBuffer.append(character)
            }
        }
        flushText()
        trimOuterWhitespace(in: &segments)
        return segments.isEmpty ? [] : [.skillText(segments)]
    }

    private static func skillCommand(for skill: ComposerSkill, vendor: Vendor) -> String {
        switch vendor {
        case .claude:
            return "/\(skill.name)"
        case .codex:
            return "$\(skill.name)"
        }
    }

    private static func trimOuterWhitespace(in segments: inout [SkillTextSegment]) {
        while let first = segments.first,
              first.skillName == nil,
              (first.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            segments.removeFirst()
        }
        if let first = segments.first,
           first.skillName == nil,
           let text = first.text {
            segments[0] = .text(trimLeadingWhitespace(text))
        }

        while let last = segments.last,
              last.skillName == nil,
              (last.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            segments.removeLast()
        }
        if let last = segments.last,
           last.skillName == nil,
           let text = last.text {
            segments[segments.count - 1] = .text(trimTrailingWhitespace(text))
        }
    }

    private static func trimLeadingWhitespace(_ value: String) -> String {
        String(value.drop(while: { $0.isWhitespace }))
    }

    private static func trimTrailingWhitespace(_ value: String) -> String {
        var result = value
        while result.last?.isWhitespace == true {
            result.removeLast()
        }
        return result
    }
}

struct SkillAwareComposerBox<TopContent: View, AccessoryOverlay: View>: View {
    @Binding var text: String
    @Binding var skillChips: [ComposerSkill]

    let placeholder: String
    let minLines: Int
    let maxLines: Int
    let focusRequest: Int
    let resetRequest: Int
    let menuWidthSource: CGFloat
    let textTopPadding: CGFloat
    let skillProfile: Profile?
    let skillProject: Project?
    let onSlashActivityChange: (Bool) -> Void
    let onSend: () -> Void
    let topContent: () -> TopContent
    let accessoryOverlay: (Bool) -> AccessoryOverlay

    @State private var localFocusRequest = 0
    @State private var skillInsertionRequest: ComposerSkillInsertionRequest?
    @State private var skills: [ComposerSkill] = []
    @State private var isRefreshingSkills = false
    @State private var skillRefreshToken = 0
    @State private var skillCatalogSignature: String?
    @State private var skillCatalogWatcher: SkillCatalogWatcher?
    @State private var skillWatchSignature: String?
    @State private var slashFilteredSkills: [ComposerSkill] = []
    @State private var slashHighlightedId: String?
    @State private var slashScrollTargetId: String?
    @State private var slashContext: ComposerSlashContext?
    @State private var slashSuppressedSignature: String?

    init(text: Binding<String>,
         skillChips: Binding<[ComposerSkill]>,
         placeholder: String,
         minLines: Int,
         maxLines: Int,
         focusRequest: Int,
         resetRequest: Int,
         menuWidthSource: CGFloat,
         textTopPadding: CGFloat,
         skillProfile: Profile?,
         skillProject: Project?,
         onSlashActivityChange: @escaping (Bool) -> Void,
         onSend: @escaping () -> Void,
         @ViewBuilder topContent: @escaping () -> TopContent,
         @ViewBuilder accessoryOverlay: @escaping (Bool) -> AccessoryOverlay) {
        self._text = text
        self._skillChips = skillChips
        self.placeholder = placeholder
        self.minLines = minLines
        self.maxLines = maxLines
        self.focusRequest = focusRequest
        self.resetRequest = resetRequest
        self.menuWidthSource = menuWidthSource
        self.textTopPadding = textTopPadding
        self.skillProfile = skillProfile
        self.skillProject = skillProject
        self.onSlashActivityChange = onSlashActivityChange
        self.onSend = onSend
        self.topContent = topContent
        self.accessoryOverlay = accessoryOverlay
    }

    var body: some View {
        VStack(spacing: 0) {
            topContent()
            ComposerTextView(
                text: $text,
                skillChips: $skillChips,
                placeholder: placeholder,
                minLines: minLines,
                maxLines: maxLines,
                focusRequest: focusRequest &+ localFocusRequest,
                skillInsertionRequest: skillInsertionRequest,
                onKeyDown: handleComposerKeyDown,
                onTextCommand: handleComposerTextCommand,
                onSlashContextChange: handleSlashContextChange,
                onSend: onSend
            )
            .padding(.horizontal, 10)
            .padding(.top, textTopPadding)
            .padding(.bottom, 8)
        }
        .background(
            RoundedRectangle(cornerRadius: DS.cornerRadiusLarge)
                .fill(Color.helmCard)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.cornerRadiusLarge)
                        .stroke(Color.helmBorderStrong, lineWidth: 1)
                )
        )
        .overlay(alignment: .topLeading) {
            if slashMenuVisible {
                SlashSkillMenu(
                    skills: slashFilteredSkills,
                    isLoading: isRefreshingSkills && slashFilteredSkills.isEmpty,
                    highlightedId: currentSlashHighlight,
                    scrollTargetId: slashScrollTargetId,
                    query: slashQuery ?? "",
                    onHover: { slashHighlightedId = $0 },
                    onSelect: insertSkillCommand
                )
                .frame(width: slashMenuWidth, height: slashMenuHeight)
                .offset(x: 0, y: -(slashMenuHeight + 8))
                .transition(.opacity.combined(with: .scale(scale: 0.985, anchor: .bottomLeading)))
                .zIndex(10)
            }
            accessoryOverlay(slashMenuVisible)
        }
        .animation(.easeOut(duration: 0.10), value: slashMenuVisible)
        .onAppear {
            refreshSkillsAsync(force: true)
            configureSkillCatalogWatcher()
        }
        .onChange(of: currentSkillCatalogContext?.signature) { _, _ in
            resetSlashPickerState()
            refreshSkillsAsync(force: true)
            configureSkillCatalogWatcher()
        }
        .onChange(of: resetRequest) { _, _ in
            resetSlashPickerState()
        }
        .onDisappear {
            skillCatalogWatcher?.invalidate()
            skillCatalogWatcher = nil
            skillWatchSignature = nil
        }
    }

    private var currentSkillCatalogContext: ComposerSkillCatalog.Context? {
        guard let profile = skillProfile,
              let project = skillProject
        else { return nil }

        let sshHost: String?
        if case .ssh(let host, _, _) = project.location {
            sshHost = host
        } else {
            sshHost = nil
        }
        return ComposerSkillCatalog.Context(
            vendor: profile.vendor,
            projectPath: project.location.pathString,
            sshHost: sshHost,
            configRoot: profile.configRoot
        )
    }

    private var slashQuery: String? {
        slashContext?.query
    }

    private var slashMenuVisible: Bool {
        guard let slashContext else { return false }
        return slashSuppressedSignature != slashContext.signature
    }

    private var currentSlashHighlight: String? {
        if let slashHighlightedId,
           slashFilteredSkills.contains(where: { $0.id == slashHighlightedId }) {
            return slashHighlightedId
        }
        return slashFilteredSkills.first?.id
    }

    private var slashMenuWidth: CGFloat {
        guard menuWidthSource > 0 else { return 560 }
        return min(560, max(300, menuWidthSource))
    }

    private var slashMenuHeight: CGFloat {
        let visibleRows = max(1, min(6, slashFilteredSkills.count))
        return CGFloat(visibleRows * 54 + 41)
    }

    private func refreshSkillsAsync(force: Bool = false) {
        guard let context = currentSkillCatalogContext else {
            skills = []
            isRefreshingSkills = false
            updateSlashResults()
            return
        }
        guard force || skillCatalogSignature != context.signature || skills.isEmpty else { return }
        skillRefreshToken += 1
        let token = skillRefreshToken
        skillCatalogSignature = context.signature
        isRefreshingSkills = true

        Task.detached(priority: .userInitiated) {
            let loadedSkills = await ComposerSkillCatalog.load(context: context)
            await MainActor.run {
                guard token == skillRefreshToken else { return }
                skills = loadedSkills
                isRefreshingSkills = false

                if let slashContext,
                   let skill = exactSkillMatch(for: slashContext) {
                    requestSkillInsertion(skill)
                }
                updateSlashResults()
            }
        }
    }

    private func configureSkillCatalogWatcher() {
        guard let context = currentSkillCatalogContext else {
            skillCatalogWatcher?.invalidate()
            skillCatalogWatcher = nil
            skillWatchSignature = nil
            return
        }

        let roots = ComposerSkillCatalog.watchRoots(context: context)
        let signature = SkillCatalogWatcher.signature(for: roots)
        guard signature != skillWatchSignature else { return }

        skillCatalogWatcher?.invalidate()
        skillWatchSignature = signature
        skillCatalogWatcher = SkillCatalogWatcher(roots: roots) {
            skillCatalogSignature = nil
            skillWatchSignature = nil
            refreshSkillsAsync(force: true)
            configureSkillCatalogWatcher()
        }
    }

    private func handleSlashContextChange(_ context: ComposerSlashContext?) {
        let oldContext = slashContext
        slashContext = context
        if oldContext == nil, context != nil {
            onSlashActivityChange(true)
        } else if oldContext != nil, context == nil {
            onSlashActivityChange(false)
        }
        if oldContext?.signature != context?.signature {
            slashHighlightedId = nil
            slashScrollTargetId = nil
        }
        if slashSuppressedSignature != context?.signature {
            slashSuppressedSignature = nil
        }
        if context != nil && oldContext == nil {
            refreshSkillsAsync()
        }
        if let context,
           let skill = exactSkillMatch(for: context) {
            requestSkillInsertion(skill)
            return
        }
        updateSlashResults()
    }

    private func updateSlashResults() {
        guard let query = slashQuery else {
            if !slashFilteredSkills.isEmpty {
                slashFilteredSkills = []
            }
            syncSlashHighlight()
            return
        }

        let filtered: [ComposerSkill]
        if query.isEmpty {
            filtered = skills
        } else {
            filtered = skills
                .compactMap { skill -> (skill: ComposerSkill, score: ComposerSkillMatchScore)? in
                    guard let score = skill.matchScore(for: query) else { return nil }
                    return (skill, score)
                }
                .sorted {
                    if $0.score != $1.score {
                        return $0.score < $1.score
                    }
                    return $0.skill.name.localizedCaseInsensitiveCompare($1.skill.name) == .orderedAscending
                }
                .map(\.skill)
        }

        if slashFilteredSkills.map(\.id) != filtered.map(\.id) {
            slashFilteredSkills = filtered
        }
        syncSlashHighlight()
    }

    private func syncSlashHighlight() {
        guard slashQuery != nil else {
            slashHighlightedId = nil
            slashScrollTargetId = nil
            return
        }
        if let slashHighlightedId,
           slashFilteredSkills.contains(where: { $0.id == slashHighlightedId }) {
            return
        }
        let firstId = slashFilteredSkills.first?.id
        slashHighlightedId = firstId
        slashScrollTargetId = firstId
    }

    private func handleComposerKeyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.isEmpty else { return false }

        guard slashMenuVisible else { return false }

        switch event.keyCode {
        case 125:
            moveSlashHighlight(by: 1)
            return true
        case 126:
            moveSlashHighlight(by: -1)
            return true
        case 36, 76:
            return insertHighlightedSkillCommand()
        case 48:
            return insertHighlightedSkillCommand()
        case 53:
            slashSuppressedSignature = slashContext?.signature
            return true
        default:
            return false
        }
    }

    private func handleComposerTextCommand(_ command: ComposerTextCommand) -> Bool {
        guard slashMenuVisible else { return false }
        switch command {
        case .moveUp:
            moveSlashHighlight(by: -1)
            return true
        case .moveDown:
            moveSlashHighlight(by: 1)
            return true
        case .accept:
            return insertHighlightedSkillCommand()
        case .complete:
            return insertHighlightedSkillCommand()
        case .cancel:
            slashSuppressedSignature = slashContext?.signature
            return true
        }
    }

    private func moveSlashHighlight(by offset: Int) {
        let list = slashFilteredSkills
        guard !list.isEmpty else { return }
        let current = currentSlashHighlight.flatMap { id in
            list.firstIndex { $0.id == id }
        } ?? 0
        let nextId = list[(current + offset + list.count) % list.count].id
        slashHighlightedId = nextId
        slashScrollTargetId = nextId
    }

    private func insertHighlightedSkillCommand() -> Bool {
        guard let id = currentSlashHighlight,
              let skill = slashFilteredSkills.first(where: { $0.id == id })
        else { return false }
        insertSkillCommand(skill)
        return true
    }

    private func insertSkillCommand(_ skill: ComposerSkill) {
        requestSkillInsertion(skill)
    }

    private func requestSkillInsertion(_ skill: ComposerSkill) {
        skillInsertionRequest = ComposerSkillInsertionRequest(skill: skill)
        localFocusRequest &+= 1
        resetSlashPickerState()
    }

    private func resetSlashPickerState() {
        slashHighlightedId = nil
        slashScrollTargetId = nil
        slashSuppressedSignature = nil
        slashContext = nil
        if !slashFilteredSkills.isEmpty {
            slashFilteredSkills = []
        }
        onSlashActivityChange(false)
    }

    private func exactSkillMatch(for context: ComposerSlashContext) -> ComposerSkill? {
        guard !context.query.isEmpty else { return nil }
        let exactMatches = skills.filter { $0.searchName == context.query }
        guard exactMatches.count == 1,
              let skill = exactMatches.first
        else { return nil }
        if skills.contains(where: { $0.searchName != context.query && $0.searchName.hasPrefix(context.query) }) {
            return nil
        }
        return skill
    }
}

private struct SlashSkillMenu: View {
    let skills: [ComposerSkill]
    let isLoading: Bool
    let highlightedId: String?
    let scrollTargetId: String?
    let query: String
    let onHover: (String) -> Void
    let onSelect: (ComposerSkill) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text("Skills")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !query.isEmpty {
                    Text("/\(query)")
                        .font(DS.monoFontSmall)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 40)

            Rectangle()
                .fill(Color.helmBorder)
                .frame(height: 1)

            if isLoading {
                HStack(spacing: 9) {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.55)
                        .frame(width: 14, height: 14)
                    Text("Loading skills...")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .frame(height: 54)
            } else if skills.isEmpty {
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                    Text("No matching skills")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .frame(height: 54)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(skills) { skill in
                                Button {
                                    onSelect(skill)
                                } label: {
                                    SlashSkillRow(
                                        skill: skill,
                                        isHighlighted: skill.id == highlightedId
                                    )
                                }
                                .buttonStyle(.plain)
                                .id(skill.id)
                                .onHover { hovering in
                                    if hovering {
                                        onHover(skill.id)
                                    }
                                }
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: scrollTargetId) { _, newValue in
                        guard let newValue else { return }
                        withAnimation(.easeOut(duration: 0.08)) {
                            proxy.scrollTo(newValue, anchor: .center)
                        }
                    }
                }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.cornerRadiusLarge, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.cornerRadiusLarge, style: .continuous)
                .stroke(Color.helmBorderStrong, lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.16), radius: 18, x: 0, y: 10)
    }
}

private struct SlashSkillRow: View {
    let skill: ComposerSkill
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isHighlighted ? Color.accentColor : Color.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("/\(skill.name)")
                        .font(DS.monoFontSmall)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(skill.source)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Text(skill.description.isEmpty ? skill.path : skill.description)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 52)
        .background(
            RoundedRectangle(cornerRadius: DS.cornerRadiusSmall)
                .fill(isHighlighted ? Color.helmSelected : Color.clear)
        )
        .contentShape(Rectangle())
    }
}

private struct BuiltinAction: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case status
        case compact
        case goal
        case help
    }

    let kind: Kind
    let title: String
    let commandName: String
    let summary: String
    let symbolName: String

    var id: Kind { kind }

    static func catalog(for vendor: Vendor) -> [BuiltinAction] {
        switch vendor {
        case .codex:
            return [
                BuiltinAction(kind: .status,
                              title: "Status",
                              commandName: "/status",
                              summary: "Show session, model, context, and run configuration.",
                              symbolName: "info.circle"),
                BuiltinAction(kind: .compact,
                              title: "Compact",
                              commandName: "/compact",
                              summary: "Ask Codex to compact the current conversation context.",
                              symbolName: "rectangle.compress.vertical"),
                BuiltinAction(kind: .goal,
                              title: "Goal",
                              commandName: "/goal",
                              summary: "Send the next prompt as a Codex goal.",
                              symbolName: "target"),
                BuiltinAction(kind: .help,
                              title: "Help",
                              commandName: "/help",
                              summary: "Show Codex actions available in Helm.",
                              symbolName: "questionmark.circle"),
            ]
        case .claude:
            return [
                BuiltinAction(kind: .status,
                              title: "Status",
                              commandName: "/status",
                              summary: "Show session, model, context, and run configuration.",
                              symbolName: "info.circle"),
                BuiltinAction(kind: .compact,
                              title: "Compact",
                              commandName: "/compact",
                              summary: "Ask Claude to compact the current conversation context.",
                              symbolName: "rectangle.compress.vertical"),
                BuiltinAction(kind: .goal,
                              title: "Goal",
                              commandName: "/goal",
                              summary: "Send the next prompt as a Claude goal.",
                              symbolName: "target"),
                BuiltinAction(kind: .help,
                              title: "Help",
                              commandName: "/help",
                              summary: "Show Claude actions available in Helm.",
                              symbolName: "questionmark.circle"),
            ]
        }
    }

    static func definition(for kind: Kind, vendor: Vendor) -> BuiltinAction {
        catalog(for: vendor).first { $0.kind == kind }
            ?? BuiltinAction(kind: kind,
                             title: kind.rawValue.capitalized,
                             commandName: "/" + kind.rawValue,
                             summary: "",
                             symbolName: "sparkle")
    }
}

private struct BuiltinActionPanel: View {
    @Environment(AppStore.self) private var store
    @AppStorage(CodexComputerUseMode.userDefaultsKey) private var computerUseModeRawValue = CodexComputerUseMode.automatic.rawValue

    let kind: BuiltinAction.Kind
    let onClose: () -> Void

    private var session: Session? { store.selectedSession }

    private var profile: Profile? {
        session.flatMap { store.profile($0.profileId) }
    }

    private var model: Model? {
        profile.flatMap { store.model($0.primaryModelId) }
    }

    private var vendor: Vendor {
        profile?.vendor ?? .codex
    }

    private var action: BuiltinAction {
        BuiltinAction.definition(for: kind, vendor: vendor)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle()
                .fill(Color.helmBorder)
                .frame(height: 1)
            content
                .padding(14)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.cornerRadiusLarge, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.cornerRadiusLarge, style: .continuous)
                .stroke(Color.helmBorderStrong, lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.16), radius: 18, x: 0, y: 10)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: action.symbolName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(action.title)
                .font(.system(size: 13.5, weight: .semibold))
            Text(action.commandName)
                .font(DS.monoFontSmall)
                .foregroundStyle(.tertiary)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close")
            .accessibilityLabel("Close action panel")
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
    }

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .status:
            statusBody
        case .compact:
            compactBody
        case .goal:
            goalBody
        case .help:
            helpBody
        }
    }

    private var statusBody: some View {
        VStack(alignment: .leading, spacing: 9) {
            infoRow("Session", sessionDisplayId, mono: true)
            infoRow("Model", model?.label ?? "No model")
            infoRow("Profile", profile?.name ?? "No profile")
            infoRow("Project", projectDisplayPath, mono: true)
            infoRow("Context", estimatedContextText)
            infoRow("Quota", "Unavailable")
            if let session, let profile {
                switch profile.vendor {
                case .codex:
                    let computerUseMode = CodexComputerUseMode(rawValue: computerUseModeRawValue) ?? .automatic
                    infoRow("Runtime", "\(session.codexSandboxMode.displayName), \(session.codexApprovalMode.displayName), \(session.codexEffort.displayName), \(computerUseMode.displayName) CU")
                case .claude:
                    let computerUseMode = CodexComputerUseMode(rawValue: computerUseModeRawValue) ?? .automatic
                    infoRow("Runtime", "\(session.claudePermissionMode.displayName), \(session.claudeEffort.displayName), \(computerUseMode.displayName) CU")
                }
            }
        }
    }

    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 9) {
            infoRow("Command", action.commandName, mono: true)
            emptyPanelText("Compact runs immediately from the action menu and sends /compact to \(vendor.displayName).")
        }
    }

    private var goalBody: some View {
        VStack(alignment: .leading, spacing: 9) {
            infoRow("Command", action.commandName, mono: true)
            emptyPanelText("Goal marks the next composer send as /goal. Write the goal in the main input, then send normally.")
        }
    }

    private var helpBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(BuiltinAction.catalog(for: vendor)) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: item.symbolName)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Text(item.title)
                                    .font(.system(size: 12.5, weight: .medium))
                                Text(item.commandName)
                                    .font(DS.monoFontSmall)
                                    .foregroundStyle(.tertiary)
                            }
                            Text(item.summary)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: DS.cornerRadiusSmall)
                            .fill(Color.clear)
                    )
                }
            }
        }
    }

    private func infoRow(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label + ":")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(mono ? DS.monoFontSmall : .system(size: 12.5))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func emptyPanelText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sessionDisplayId: String {
        if let vendorSessionId = session?.vendorSessionId,
           !vendorSessionId.isEmpty {
            return vendorSessionId
        }
        return session?.id.uuidString.lowercased() ?? "Unavailable"
    }

    private var projectDisplayPath: String {
        guard let project = store.selectedProject else { return "No project" }
        switch project.location {
        case .local(let path):
            return path
        case .ssh(let host, let path, let status):
            let resolved = status.resolvedPath?.isEmpty == false
                ? status.resolvedPath!
                : path
            return "\(host):\(resolved)"
        }
    }

    private var estimatedContextText: String {
        guard let session else { return "Unavailable" }
        let characters = session.transcript.reduce(0) { total, item in
            guard let message = item.message else { return total }
            return total + message.parts.reduce(0) { partTotal, part in
                switch part {
                case .text(let text):
                    return partTotal + text.count
                case .skillText(let segments):
                    return partTotal + segments.reduce(0) { segmentTotal, segment in
                        segmentTotal + (segment.text?.count ?? 0) + (segment.skillName?.count ?? 0)
                    }
                case .toolCall(let call):
                    return partTotal + call.arg.count + (call.body?.count ?? 0)
                case .image:
                    return partTotal + 6000
                }
            }
        }
        guard characters > 0 else { return "0 tokens estimated" }
        let tokens = max(1, characters / 4)
        return "\(tokens) tokens estimated"
    }

}

struct ComposerSkill: Identifiable, Hashable {
    let id: String
    let name: String
    let description: String
    let source: String
    let path: String
    let haystack: String
    let searchName: String
    let searchHaystack: String
    let searchNameCharacters: [Character]

    fileprivate func matchScore(for rawQuery: String) -> ComposerSkillMatchScore? {
        let query = Self.normalizedSearchText(rawQuery)
        guard !query.isEmpty else { return nil }

        var candidates = [
            literalScore(query: query, in: searchName, targetPriority: 0),
            literalScore(query: query, in: searchHaystack, targetPriority: 1),
        ].compactMap(\.self)

        if query.count >= 3,
           let nameSubsequenceScore = subsequenceScore(
            queryCharacters: Array(query),
            in: searchNameCharacters,
            targetPriority: 0
           ) {
            candidates.append(nameSubsequenceScore)
        }

        return candidates.min()
    }

    static func normalizedSearchText(_ raw: String) -> String {
        raw.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
    }

    private func literalScore(query: String,
                              in target: String,
                              targetPriority: Int) -> ComposerSkillMatchScore? {
        guard let range = target.range(of: query) else { return nil }
        let startsAtBeginning = range.lowerBound == target.startIndex
        let tier: Int
        if targetPriority == 0 {
            tier = startsAtBeginning ? 0 : 1
        } else {
            tier = 2
        }
        return ComposerSkillMatchScore(
            tier: tier,
            gaps: 0,
            span: query.count,
            start: target.distance(from: target.startIndex, to: range.lowerBound),
            targetPriority: targetPriority,
            targetLength: target.count
        )
    }

    private func subsequenceScore(queryCharacters: [Character],
                                  in targetCharacters: [Character],
                                  targetPriority: Int) -> ComposerSkillMatchScore? {
        guard let firstQueryCharacter = queryCharacters.first else { return nil }

        var bestScore: ComposerSkillMatchScore?
        for start in targetCharacters.indices where targetCharacters[start] == firstQueryCharacter {
            var queryOffset = 0
            var lastMatch = start

            for targetOffset in start..<targetCharacters.count {
                guard targetCharacters[targetOffset] == queryCharacters[queryOffset] else {
                    continue
                }
                lastMatch = targetOffset
                queryOffset += 1
                if queryOffset == queryCharacters.count {
                    break
                }
            }

            guard queryOffset == queryCharacters.count else { continue }

            let span = lastMatch - start + 1
            let gaps = span - queryCharacters.count
            guard gaps <= max(2, queryCharacters.count) else { continue }

            let score = ComposerSkillMatchScore(
                tier: targetPriority == 0 ? 3 : 4,
                gaps: gaps,
                span: span,
                start: start,
                targetPriority: targetPriority,
                targetLength: targetCharacters.count
            )
            if bestScore.map({ score < $0 }) ?? true {
                bestScore = score
            }
        }
        return bestScore
    }
}

private struct ComposerSkillMatchScore: Comparable, Equatable {
    let tier: Int
    let gaps: Int
    let span: Int
    let start: Int
    let targetPriority: Int
    let targetLength: Int

    static func < (lhs: ComposerSkillMatchScore, rhs: ComposerSkillMatchScore) -> Bool {
        if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
        if lhs.gaps != rhs.gaps { return lhs.gaps < rhs.gaps }
        if lhs.span != rhs.span { return lhs.span < rhs.span }
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        if lhs.targetPriority != rhs.targetPriority { return lhs.targetPriority < rhs.targetPriority }
        return lhs.targetLength < rhs.targetLength
    }
}

private final class SkillCatalogWatcher {
    private let queue = DispatchQueue(label: "dev.deng.helm.skill-catalog-watcher")
    private var sources: [DispatchSourceFileSystemObject] = []
    private var descriptors: [CInt] = []
    private var pendingChange: DispatchWorkItem?
    private var isInvalidated = false

    init(roots: [URL], onChange: @escaping @MainActor () -> Void) {
        let paths = Self.watchPaths(for: roots)
        for path in paths {
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename, .revoke],
                queue: queue
            )
            source.setEventHandler { [weak self] in
                guard let self, !self.isInvalidated else { return }
                self.scheduleChange(onChange)
            }
            source.setCancelHandler {
                close(descriptor)
            }
            descriptors.append(descriptor)
            sources.append(source)
            source.resume()
        }
    }

    deinit {
        invalidate()
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        pendingChange?.cancel()
        pendingChange = nil
        sources.forEach { $0.cancel() }
        sources = []
        descriptors = []
    }

    private func scheduleChange(_ onChange: @escaping @MainActor () -> Void) {
        pendingChange?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.isInvalidated else { return }
            Task { @MainActor in onChange() }
        }
        pendingChange = item
        queue.asyncAfter(deadline: .now() + .milliseconds(250), execute: item)
    }

    static func signature(for roots: [URL]) -> String {
        watchPaths(for: roots).joined(separator: "|")
    }

    private static func watchPaths(for roots: [URL],
                                   fileManager: FileManager = .default) -> [String] {
        var seen: Set<String> = []
        return roots
            .compactMap { watchPath(for: $0, fileManager: fileManager) }
            .map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
            .filter { seen.insert($0).inserted }
            .sorted()
    }

    private static func watchPath(for url: URL,
                                  fileManager: FileManager) -> URL? {
        let target = url.standardizedFileURL
        if fileManager.fileExists(atPath: target.path) {
            return target
        }

        let parent = target.deletingLastPathComponent()
        guard parent.path != target.path,
              fileManager.fileExists(atPath: parent.path)
        else { return nil }

        return parent
    }
}

private enum ComposerSkillCatalog {
    struct Context: Equatable {
        let vendor: Vendor
        let projectPath: String
        let sshHost: String?
        let configRoot: String?

        var signature: String {
            [
                vendor.rawValue,
                sshHost ?? "local",
                projectPath,
                configRoot ?? "",
            ].joined(separator: "|")
        }
    }

    static func load(context: Context,
                     fileManager: FileManager = .default) async -> [ComposerSkill] {
        if let host = context.sshHost {
            return await loadRemote(context: context, host: host)
        }
        return loadLocal(context: context, fileManager: fileManager)
    }

    private static func loadLocal(context: Context,
                                  fileManager: FileManager) -> [ComposerSkill] {
        let roots = localRoots(context: context, fileManager: fileManager)

        var loadedSkills: [ComposerSkill] = []
        var seenPaths = Set<String>()
        for root in roots {
            for fileURL in skillFiles(in: root.url, maxDepth: root.depth, fileManager: fileManager) {
                let path = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
                guard seenPaths.insert(path).inserted,
                      let skill = parseSkill(at: fileURL, source: sourceLabel(for: fileURL, fallback: root.label))
                else { continue }
                loadedSkills.append(skill)
            }
        }

        return loadedSkills.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    static func watchRoots(context: Context,
                           fileManager: FileManager = .default) -> [URL] {
        guard context.sshHost == nil else { return [] }
        let roots = localRoots(context: context, fileManager: fileManager)
        let manifests = linkedSkillManifestURLs(context: context)
        var seen: Set<String> = []
        return (roots.map(\.url) + manifests)
            .filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private static func localRoots(context: Context,
                                   fileManager: FileManager) -> [(label: String, url: URL, depth: Int)] {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let env = ProcessInfo.processInfo.environment
        let project = expandHome(context.projectPath)

        switch context.vendor {
        case .claude:
            let claudeHome = context.configRoot.map(expandHome)
                ?? env["CLAUDE_CONFIG_DIR"].map(expandHome)
                ?? home.appendingPathComponent(".claude", isDirectory: true)
            return projectSkillRoots(project: project,
                                     component: ".claude/skills",
                                     label: "Project",
                                     fileManager: fileManager)
                + [("Claude", claudeHome.appendingPathComponent("skills", isDirectory: true), 2)]
                + linkedSkillRoots(from: claudeHome.appendingPathComponent("skills/.my-skills-links.json"),
                                   label: "My Skills",
                                   fileManager: fileManager)
        case .codex:
            let codexHome = context.configRoot.map(expandHome)
                ?? env["CODEX_HOME"].map(expandHome)
                ?? home.appendingPathComponent(".codex", isDirectory: true)
            let agentsHome = home.appendingPathComponent(".agents", isDirectory: true)
            return codexProjectSkillRoots(project: project, fileManager: fileManager)
                + [
                    ("User", agentsHome.appendingPathComponent("skills", isDirectory: true), 3),
                    ("Codex", codexHome.appendingPathComponent("skills", isDirectory: true), 3),
                    ("Admin", URL(fileURLWithPath: "/etc/codex/skills", isDirectory: true), 3),
                    ("Plugin", codexHome.appendingPathComponent("plugins/cache", isDirectory: true), 7),
                ]
                + linkedSkillRoots(from: agentsHome.appendingPathComponent("skills/.my-skills-links.json"),
                                   label: "My Skills",
                                   fileManager: fileManager)
        }
    }

    private static func linkedSkillManifestURLs(context: Context) -> [URL] {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let env = ProcessInfo.processInfo.environment

        switch context.vendor {
        case .claude:
            let claudeHome = context.configRoot.map(expandHome)
                ?? env["CLAUDE_CONFIG_DIR"].map(expandHome)
                ?? home.appendingPathComponent(".claude", isDirectory: true)
            return [claudeHome.appendingPathComponent("skills/.my-skills-links.json")]
        case .codex:
            let agentsHome = home.appendingPathComponent(".agents", isDirectory: true)
            return [agentsHome.appendingPathComponent("skills/.my-skills-links.json")]
        }
    }

    private static func codexProjectSkillRoots(project: URL,
                                               fileManager: FileManager) -> [(label: String, url: URL, depth: Int)] {
        let start = project.standardizedFileURL
        let stop = nearestGitRoot(from: start, fileManager: fileManager) ?? start
        var cursor = start
        var roots: [(label: String, url: URL, depth: Int)] = []

        while true {
            roots.append(("Project", cursor.appendingPathComponent(".agents/skills", isDirectory: true), 3))
            if cursor.path == stop.path { break }
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path { break }
            cursor = parent
        }

        return roots
    }

    private static func projectSkillRoots(project: URL,
                                          component: String,
                                          label: String,
                                          fileManager: FileManager) -> [(label: String, url: URL, depth: Int)] {
        let start = project.standardizedFileURL
        let stop = nearestGitRoot(from: start, fileManager: fileManager) ?? start
        var cursor = start
        var roots: [(label: String, url: URL, depth: Int)] = []

        while true {
            roots.append((label, cursor.appendingPathComponent(component, isDirectory: true), 3))
            if cursor.path == stop.path { break }
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path { break }
            cursor = parent
        }
        return roots
    }

    private static func nearestGitRoot(from url: URL, fileManager: FileManager) -> URL? {
        var cursor = url
        while true {
            if fileManager.fileExists(atPath: cursor.appendingPathComponent(".git").path) {
                return cursor
            }
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path { return nil }
            cursor = parent
        }
    }

    private static func loadRemote(context: Context, host: String) async -> [ComposerSkill] {
        await Task.detached(priority: .userInitiated) {
            let command = remoteSkillDiscoveryCommand(context: context)
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: SSHRemote.executable)
            proc.arguments = SSHRemote.arguments(host: host,
                                                 remoteCommand: command,
                                                 batchMode: true,
                                                 connectTimeout: 10)

            let stdout = Pipe()
            proc.standardOutput = stdout
            proc.standardError = Pipe()

            do {
                try proc.run()
            } catch {
                return []
            }
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return [] }

            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            guard let records = try? JSONDecoder().decode([RemoteSkillRecord].self, from: data) else {
                return []
            }

            var loadedSkills: [ComposerSkill] = []
            var seenPaths = Set<String>()
            for record in records {
                guard seenPaths.insert(record.path).inserted,
                      let skill = makeSkill(name: record.name,
                                            description: record.description,
                                            source: record.source,
                                            path: "\(host):\(record.path)")
                else { continue }
                loadedSkills.append(skill)
            }
            return loadedSkills.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }.value
    }

    private static func remoteSkillDiscoveryCommand(context: Context) -> String {
        let vendor = SSHRemote.shellQuote(context.vendor.rawValue)
        let project = SSHRemote.shellQuote(context.projectPath)
        return """
        HELM_VENDOR=\(vendor); export HELM_VENDOR
        HELM_PROJECT_PATH=\(project); export HELM_PROJECT_PATH
        if command -v python3 >/dev/null 2>&1; then
          python3 - <<'PY'
        \(remoteSkillDiscoveryScript)
        PY
        elif command -v python >/dev/null 2>&1; then
          python - <<'PY'
        \(remoteSkillDiscoveryScript)
        PY
        else
          printf '[]'
        fi
        """
    }

    private static let remoteSkillDiscoveryScript = #"""
import json
import os

vendor = os.environ.get("HELM_VENDOR", "codex")
project = os.path.expanduser(os.environ.get("HELM_PROJECT_PATH", "."))
home = os.path.expanduser("~")

def root(path):
    return os.path.abspath(os.path.expanduser(path))

def git_root(path):
    cursor = root(path)
    while True:
        if os.path.exists(os.path.join(cursor, ".git")):
            return cursor
        parent = os.path.dirname(cursor)
        if parent == cursor:
            return None
        cursor = parent

def parent_project_roots(path, components):
    cursor = root(path)
    stop = git_root(cursor) or cursor
    out = []
    while True:
        out.append(("Project", root(os.path.join(cursor, *components)), 3))
        if cursor == stop:
            break
        parent = os.path.dirname(cursor)
        if parent == cursor:
            break
        cursor = parent
    return out

if vendor == "claude":
    config = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(home, ".claude")
    roots = parent_project_roots(project, [".claude", "skills"]) + [
        ("Claude", root(os.path.join(config, "skills")), 2),
    ]
else:
    config = os.environ.get("CODEX_HOME") or os.path.join(home, ".codex")
    agents_home = root(os.path.join(home, ".agents"))

    roots = parent_project_roots(project, [".agents", "skills"]) + [
        ("User", root(os.path.join(agents_home, "skills")), 3),
        ("Codex", root(os.path.join(config, "skills")), 3),
        ("Admin", "/etc/codex/skills", 3),
        ("Plugin", root(os.path.join(config, "plugins", "cache")), 7),
    ]

def frontmatter(raw):
    out = {}
    if not raw.startswith("---"):
        return out
    lines = raw.splitlines()
    for line in lines[1:]:
        stripped = line.strip()
        if stripped == "---":
            break
        if not stripped or stripped.startswith("#") or ":" not in stripped:
            continue
        key, value = stripped.split(":", 1)
        value = value.strip().strip('"').strip("'")
        out[key.strip().lower()] = value
    return out

def body_summary(raw):
    for line in raw.splitlines():
        text = line.strip()
        if text and text != "---" and not text.startswith("#"):
            return text[:240]
    return ""

def parse_skill(path, source):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            raw = fh.read(20000)
    except Exception:
        return None
    meta = frontmatter(raw)
    name = (meta.get("name") or os.path.basename(os.path.dirname(path))).strip()
    if not name:
        return None
    return {
        "name": name,
        "description": (meta.get("description") or body_summary(raw)).strip(),
        "source": source,
        "path": path,
    }

def skill_files(start, depth, out, visited):
    if len(out) >= 500 or depth < 0 or not os.path.exists(start):
        return
    real = os.path.realpath(start)
    if real in visited:
        return
    visited.add(real)
    try:
        entries = list(os.scandir(start))
    except Exception:
        return
    for entry in entries:
        if entry.name == "SKILL.md" and entry.is_file(follow_symlinks=True):
            out.append(entry.path)
            return
    dirs = [entry for entry in entries if entry.is_dir(follow_symlinks=True)]
    for entry in sorted(dirs, key=lambda item: item.name.lower()):
        skill_files(entry.path, depth - 1, out, visited)
        if len(out) >= 500:
            return

records = []
seen_paths = set()
for label, start, depth in roots:
    paths = []
    skill_files(start, depth, paths, set())
    for path in paths:
        real = os.path.realpath(path)
        if real in seen_paths:
            continue
        seen_paths.add(real)
        record = parse_skill(path, label)
        if record:
            records.append(record)

print(json.dumps(records, ensure_ascii=False))
"""#

    private struct RemoteSkillRecord: Decodable {
        let name: String
        let description: String
        let source: String
        let path: String
    }

    private static func linkedSkillRoots(from manifestURL: URL,
                                         label: String,
                                         fileManager: FileManager) -> [(label: String, url: URL, depth: Int)] {
        guard fileManager.fileExists(atPath: manifestURL.path),
              let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(LinkedSkillsManifest.self, from: data)
        else { return [] }

        let skillsRoot = expandHome(manifest.sourceRoot)
            .appendingPathComponent("skills", isDirectory: true)
        return manifest.links
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { skillName in
                (label, skillsRoot.appendingPathComponent(skillName, isDirectory: true), 1)
            }
    }

    private static func skillFiles(in root: URL,
                                   maxDepth: Int,
                                   fileManager: FileManager) -> [URL] {
        guard maxDepth >= 0,
              fileManager.fileExists(atPath: root.path)
        else { return [] }

        var out: [URL] = []
        var visited: Set<String> = []
        walk(root, depth: maxDepth, fileManager: fileManager, visited: &visited, out: &out)
        return out
    }

    private static func walk(_ directory: URL,
                             depth: Int,
                             fileManager: FileManager,
                             visited: inout Set<String>,
                             out: inout [URL]) {
        guard depth >= 0, out.count < 500 else { return }
        let realURL = directory.resolvingSymlinksInPath().standardizedFileURL
        let realPath = realURL.path
        guard visited.insert(realPath).inserted else { return }
        guard let entries = try? fileManager.contentsOfDirectory(
            at: realURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        ) else { return }

        if let skillFile = entries.first(where: { $0.lastPathComponent == "SKILL.md" }) {
            out.append(skillFile)
            return
        }

        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard out.count < 500 else { return }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else {
                continue
            }
            walk(entry, depth: depth - 1, fileManager: fileManager, visited: &visited, out: &out)
        }
    }

    private static func parseSkill(at url: URL, source: String) -> ComposerSkill? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let raw = String(data: data, encoding: .utf8)
        else { return nil }

        var name = url.deletingLastPathComponent().lastPathComponent
        var description = ""

        if raw.hasPrefix("---") {
            let frontmatter = frontmatterValues(in: raw)
            if let frontmatterName = frontmatter["name"] {
                name = frontmatterName
            }
            if let frontmatterDescription = frontmatter["description"] {
                description = frontmatterDescription
            }
        }

        if description.isEmpty {
            description = firstBodySummary(raw)
        }

        return makeSkill(name: name,
                         description: description,
                         source: source,
                         path: url.path)
    }

    private static func makeSkill(name: String,
                                  description: String,
                                  source: String,
                                  path: String) -> ComposerSkill? {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { return nil }
        let normalizedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let haystack = [normalizedName, normalizedDescription, source]
            .joined(separator: " ")
        let searchName = ComposerSkill.normalizedSearchText(normalizedName)
        let searchHaystack = ComposerSkill.normalizedSearchText(haystack)

        return ComposerSkill(
            id: path,
            name: normalizedName,
            description: normalizedDescription,
            source: source,
            path: path,
            haystack: haystack,
            searchName: searchName,
            searchHaystack: searchHaystack,
            searchNameCharacters: Array(searchName)
        )
    }

    private static func sourceLabel(for url: URL, fallback: String) -> String {
        let path = url.path
        if path.contains("/.codex/skills/.system/") {
            return "System"
        }
        if path.contains("/.codex/plugins/cache/") {
            return "Plugin"
        }
        return fallback
    }

    private static func expandHome(_ raw: String) -> URL {
        URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
    }

    private static func cleanYAMLScalar(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return trimmed }
        if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) ||
            (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }

    private static func frontmatterValues(in raw: String) -> [String: String] {
        let lines = raw.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else {
            return [:]
        }

        var values: [String: String] = [:]
        var index = 1
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "---" { break }
            guard !trimmed.isEmpty,
                  !trimmed.hasPrefix("#"),
                  let colon = trimmed.firstIndex(of: ":")
            else {
                index += 1
                continue
            }

            let key = trimmed[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let rawValue = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if isYAMLBlockScalar(String(rawValue)) {
                var blockLines: [String] = []
                index += 1
                while index < lines.count {
                    let next = lines[index]
                    let nextTrimmed = next.trimmingCharacters(in: .whitespacesAndNewlines)
                    if nextTrimmed == "---" { break }
                    if !nextTrimmed.isEmpty && !startsWithWhitespace(next) {
                        break
                    }
                    blockLines.append(next)
                    index += 1
                }
                values[key] = cleanYAMLBlockScalar(blockLines)
                continue
            }

            values[key] = cleanYAMLScalar(String(rawValue))
            index += 1
        }
        return values
    }

    private static func isYAMLBlockScalar(_ raw: String) -> Bool {
        guard let first = raw.trimmingCharacters(in: .whitespacesAndNewlines).first else {
            return false
        }
        return first == "|" || first == ">"
    }

    private static func startsWithWhitespace(_ raw: String) -> Bool {
        guard let first = raw.unicodeScalars.first else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(first)
    }

    private static func cleanYAMLBlockScalar(_ lines: [String]) -> String {
        let nonEmptyLines = lines.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let commonIndent = nonEmptyLines
            .map(leadingWhitespaceCount)
            .min() ?? 0
        return lines
            .map { line in
                String(line.dropFirst(min(commonIndent, line.count)))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func leadingWhitespaceCount(_ raw: String) -> Int {
        var count = 0
        for scalar in raw.unicodeScalars {
            guard CharacterSet.whitespaces.contains(scalar) else { break }
            count += 1
        }
        return count
    }

    private static func firstBodySummary(_ raw: String) -> String {
        let lines = raw.components(separatedBy: .newlines)
        var inFrontmatter = raw.hasPrefix("---")
        var skippedOpening = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if inFrontmatter {
                if !skippedOpening {
                    skippedOpening = true
                    continue
                }
                if trimmed == "---" {
                    inFrontmatter = false
                }
                continue
            }
            guard !trimmed.isEmpty,
                  !trimmed.hasPrefix("#"),
                  !trimmed.hasPrefix("```")
            else { continue }
            return String(trimmed.prefix(160))
        }
        return ""
    }

    private struct LinkedSkillsManifest: Decodable {
        let sourceRoot: String
        let links: [String]

        private enum CodingKeys: String, CodingKey {
            case sourceRoot = "source_root"
            case links
        }
    }
}

private struct ComposerDraft {
    var text: String
    var attachments: [ImageAttachment]
    var selectedSkills: [ComposerSkill]
    var goalActionActive: Bool
}

private struct ComposerWidthReader: View {
    @Binding var width: CGFloat

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .preference(key: ComposerWidthPreferenceKey.self,
                            value: proxy.size.width)
        }
        .onPreferenceChange(ComposerWidthPreferenceKey.self) { newWidth in
            DispatchQueue.main.async {
                let roundedWidth = newWidth.rounded()
                guard abs(width - roundedWidth) > 0.5 else { return }
                width = roundedWidth
            }
        }
    }
}

private struct ComposerWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
