import AppKit
import CryptoKit
import SwiftUI

struct ComposerView: View {
    @Environment(AppStore.self) private var store
    var externalFocusRequest: Int = 0
    @State private var text: String = ""
    @State private var pickerOpen: Bool = false
    @State private var attachments: [ImageAttachment] = []
    @State private var selectedSkills: [ComposerSkill] = []
    @State private var skillInsertionRequest: ComposerSkillInsertionRequest?
    @State private var draftSessionId: UUID?
    @State private var drafts: [UUID: ComposerDraft] = [:]
    @State private var pasteMonitor: Any? = nil
    @State private var focusRequest = 0
    @State private var footerWidth: CGFloat = 0
    @State private var skills: [ComposerSkill] = []
    @State private var isRefreshingSkills = false
    @State private var skillRefreshToken = 0
    @State private var slashFilteredSkills: [ComposerSkill] = []
    @State private var slashHighlightedId: String?
    @State private var slashScrollTargetId: String?
    @State private var slashContext: ComposerSlashContext?
    @State private var slashSuppressedSignature: String?

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
            refreshSkillsAsync()
            installPasteMonitor()
            requestComposerFocus()
        }
        .onChange(of: store.selectedSessionId) { _, newSessionId in
            saveCurrentDraft()
            loadDraft(for: newSessionId)
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
        .onDisappear { removePasteMonitor() }
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
        VStack(spacing: 0) {
            if !attachments.isEmpty {
                attachmentRow
            }
            ComposerTextView(
                text: $text,
                skillChips: $selectedSkills,
                placeholder: composerPlaceholder,
                minLines: 2,
                maxLines: 11,
                focusRequest: focusRequest,
                skillInsertionRequest: skillInsertionRequest,
                onKeyDown: handleComposerKeyDown,
                onTextCommand: handleComposerTextCommand,
                onSlashContextChange: handleSlashContextChange,
                onSend: sendIfPossible
            )
            .padding(.horizontal, 10)
            .padding(.top, attachments.isEmpty ? 8 : 6)
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
        }
        .animation(.easeOut(duration: 0.10), value: slashMenuVisible)
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

    private var isStreamingInAnotherSession: Bool {
        store.isStreaming && !store.selectedSessionIsStreaming
    }

    private var canSubmit: Bool {
        if store.selectedSessionIsStreaming { return true }
        if isStreamingInAnotherSession { return false }
        if selectedSSHSendBlockReason != nil { return false }
        return hasComposerContent
    }

    private var submitButtonTitle: String {
        if store.selectedSessionIsStreaming { return "Stop" }
        if isStreamingInAnotherSession { return "Busy" }
        return "Send"
    }

    private var submitButtonColor: Color {
        if store.selectedSessionIsStreaming { return .red }
        if isStreamingInAnotherSession { return .secondary.opacity(0.45) }
        if selectedSSHSendBlockReason != nil { return .secondary.opacity(0.45) }
        return .accentColor
    }

    private var submitButtonHelp: String {
        if store.selectedSessionIsStreaming { return "Stop current response" }
        if isStreamingInAnotherSession { return "Another conversation is running" }
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
        if store.isStreaming || !hasComposerContent || selectedSSHSendBlockReason != nil {
            return
        }
        let toSend = composedPrompt()
        let toSendAttachments = attachments
        text = ""
        selectedSkills = []
        attachments = []
        if let sessionId = draftSessionId {
            drafts[sessionId] = nil
        }
        store.send(toSend, attachments: toSendAttachments)
    }

    private func composedPrompt() -> String {
        Self.serializeComposerText(text,
                                   skillChips: selectedSkills,
                                   vendor: selectedVendor)
    }

    private var selectedVendor: Vendor {
        store.selectedSession
            .flatMap { store.profile($0.profileId) }?
            .vendor ?? .codex
    }

    private static func serializeComposerText(_ text: String,
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

    private static func skillCommand(for skill: ComposerSkill, vendor: Vendor) -> String {
        switch vendor {
        case .claude:
            return "/\(skill.name)"
        case .codex:
            return "$\(skill.name)"
        }
    }

    // MARK: - Slash skill picker

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
        guard footerWidth > 0 else { return 560 }
        return min(560, max(300, footerWidth))
    }

    private var slashMenuHeight: CGFloat {
        let visibleRows = max(1, min(6, slashFilteredSkills.count))
        return CGFloat(visibleRows * 54 + 41)
    }

    private func refreshSkillsAsync() {
        guard !isRefreshingSkills else { return }
        skillRefreshToken += 1
        let token = skillRefreshToken
        isRefreshingSkills = true

        DispatchQueue.global(qos: .userInitiated).async {
            let loadedSkills = ComposerSkillCatalog.load()
            DispatchQueue.main.async {
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

    private func handleSlashContextChange(_ context: ComposerSlashContext?) {
        let oldContext = slashContext
        slashContext = context
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
        requestComposerFocus()
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
    }

    private func exactSkillMatch(for context: ComposerSlashContext) -> ComposerSkill? {
        guard !context.query.isEmpty else { return nil }
        guard let skill = skills.first(where: { $0.searchName == context.query }) else {
            return nil
        }
        if skills.contains(where: { $0.searchName != context.query && $0.searchName.hasPrefix(context.query) }) {
            return nil
        }
        return skill
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
            case .codex:
                codexSandboxChip(session: session)
                codexApprovalChip(session: session)
                codexEffortChip(session: session)
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
            Label(text, systemImage: "checkmark")
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
            && selectedSkills.isEmpty {
            drafts[sessionId] = nil
        } else {
            drafts[sessionId] = ComposerDraft(text: text,
                                              attachments: attachments,
                                              selectedSkills: selectedSkills)
        }
    }

    private func loadDraft(for sessionId: UUID?) {
        draftSessionId = sessionId
        resetSlashPickerState()
        guard let sessionId, let draft = drafts[sessionId] else {
            text = ""
            attachments = []
            selectedSkills = []
            updateSlashResults()
            return
        }
        text = draft.text
        attachments = draft.attachments
        selectedSkills = draft.selectedSkills
        updateSlashResults()
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

private enum ComposerSkillCatalog {
    static func load(fileManager: FileManager = .default) -> [ComposerSkill] {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let env = ProcessInfo.processInfo.environment
        let codexHome = env["CODEX_HOME"].map(expandHome) ?? home.appendingPathComponent(".codex", isDirectory: true)
        let agentsHome = env["AGENTS_HOME"].map(expandHome) ?? home.appendingPathComponent(".agents", isDirectory: true)
        let claudeHome = env["CLAUDE_CONFIG_DIR"].map(expandHome) ?? home.appendingPathComponent(".claude", isDirectory: true)

        var roots: [(label: String, url: URL, depth: Int)] = [
            ("Codex", codexHome.appendingPathComponent("skills", isDirectory: true), 3),
            ("Agents", agentsHome.appendingPathComponent("skills", isDirectory: true), 2),
            ("Claude", claudeHome.appendingPathComponent("skills", isDirectory: true), 2),
            ("Plugin", codexHome.appendingPathComponent("plugins/cache", isDirectory: true), 7),
        ]
        roots.append(contentsOf: linkedSkillRoots(
            from: agentsHome.appendingPathComponent("skills/.my-skills-links.json"),
            label: "My Skills",
            fileManager: fileManager
        ))
        roots.append(contentsOf: linkedSkillRoots(
            from: claudeHome.appendingPathComponent("skills/.my-skills-links.json"),
            label: "My Skills",
            fileManager: fileManager
        ))

        var skillsByName: [String: ComposerSkill] = [:]
        var seenPaths = Set<String>()
        for root in roots {
            for fileURL in skillFiles(in: root.url, maxDepth: root.depth, fileManager: fileManager) {
                let path = fileURL.standardizedFileURL.path
                guard seenPaths.insert(path).inserted,
                      let skill = parseSkill(at: fileURL, source: sourceLabel(for: fileURL, fallback: root.label))
                else { continue }
                let key = skill.name.lowercased()
                if skillsByName[key] == nil {
                    skillsByName[key] = skill
                }
            }
        }

        return skillsByName.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
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
        walk(root, depth: maxDepth, fileManager: fileManager, out: &out)
        return out
    }

    private static func walk(_ directory: URL,
                             depth: Int,
                             fileManager: FileManager,
                             out: inout [URL]) {
        guard depth >= 0, out.count < 500 else { return }
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        ) else { return }

        if let skillFile = entries.first(where: { $0.lastPathComponent == "SKILL.md" }) {
            out.append(skillFile)
            return
        }

        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard out.count < 500 else { return }
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            walk(entry, depth: depth - 1, fileManager: fileManager, out: &out)
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

        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { return nil }
        let normalizedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let haystack = [normalizedName, normalizedDescription, source]
            .joined(separator: " ")
        let searchName = ComposerSkill.normalizedSearchText(normalizedName)
        let searchHaystack = ComposerSkill.normalizedSearchText(haystack)

        return ComposerSkill(
            id: url.standardizedFileURL.path,
            name: normalizedName,
            description: normalizedDescription,
            source: source,
            path: url.path,
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
