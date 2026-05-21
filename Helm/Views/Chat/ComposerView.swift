import AppKit
import CryptoKit
import SwiftUI

struct ComposerView: View {
    @Environment(AppStore.self) private var store
    @State private var text: String = ""
    @State private var pickerOpen: Bool = false
    @State private var attachments: [ImageAttachment] = []
    @State private var draftSessionId: UUID?
    @State private var drafts: [UUID: ComposerDraft] = [:]
    @State private var pasteMonitor: Any? = nil

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                inner
            }
            .frame(maxWidth: DS.messageMaxWidth)
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color.helmChatBg)
        .onAppear {
            loadDraft(for: store.selectedSessionId)
            installPasteMonitor()
        }
        .onChange(of: store.selectedSessionId) { _, newSessionId in
            saveCurrentDraft()
            loadDraft(for: newSessionId)
        }
        .onDisappear { removePasteMonitor() }
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
                placeholder: "Message Claude (⌘V to attach image · ⌘↵ to send)",
                minLines: 2,
                maxLines: 11,
                onSend: sendIfPossible
            )
            .padding(.horizontal, 10)
            .padding(.top, 8)
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
    }

    private var hasComposerContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    private var isStreamingInAnotherSession: Bool {
        store.isStreaming && !store.selectedSessionIsStreaming
    }

    private var canSubmit: Bool {
        if store.selectedSessionIsStreaming { return true }
        if isStreamingInAnotherSession { return false }
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
        return .accentColor
    }

    private var submitButtonHelp: String {
        if store.selectedSessionIsStreaming { return "Stop current response" }
        if isStreamingInAnotherSession { return "Another conversation is running" }
        return "Send message"
    }

    private func sendIfPossible() {
        if store.selectedSessionIsStreaming {
            store.cancelStreaming()
            return
        }
        if store.isStreaming || !hasComposerContent {
            return
        }
        let toSend = text
        let toSendAttachments = attachments
        text = ""
        attachments = []
        if let sessionId = draftSessionId {
            drafts[sessionId] = nil
        }
        store.send(toSend, attachments: toSendAttachments)
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

        return HStack(spacing: 8) {
            Button { pickerOpen.toggle() } label: {
                if let profile {
                    HStack(spacing: 6) {
                        VendorBadge(vendor: profile.vendor).frame(width: 14, height: 14)
                        Text(modelLabel).font(.system(size: 12)).foregroundStyle(.secondary)
                        Image(systemName: "chevron.down").font(.system(size: 8)).foregroundStyle(.tertiary)
                    }
                }
            }
            .buttonStyle(.plain)
            .popover(isPresented: $pickerOpen, arrowEdge: .bottom) {
                ModelPickerMenu().frame(width: 360)
            }

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

            Spacer()

            Text("⌘↵")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)

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
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .padding(.top, 4)
    }

    private func claudePermissionChip(session: Session) -> some View {
        let binding = Binding<ClaudePermissionMode>(
            get: { session.claudePermissionMode },
            set: { store.setClaudePermission($0, on: session.id) }
        )
        return Menu {
            Picker("Mode", selection: binding) {
                ForEach(ClaudePermissionMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
        } label: {
            chipLabel(icon: "lock.shield", text: session.claudePermissionMode.displayName)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Claude --permission-mode")
    }

    private func codexSandboxChip(session: Session) -> some View {
        let binding = Binding<Profile.SandboxMode>(
            get: { session.codexSandboxMode },
            set: { store.setCodexSandbox($0, on: session.id) }
        )
        return Menu {
            Picker("Sandbox", selection: binding) {
                ForEach(Profile.SandboxMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
        } label: {
            chipLabel(icon: "lock.shield", text: session.codexSandboxMode.displayName)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Codex sandbox_mode")
    }

    private func codexApprovalChip(session: Session) -> some View {
        let binding = Binding<CodexApprovalMode>(
            get: { session.codexApprovalMode },
            set: { store.setCodexApproval($0, on: session.id) }
        )
        return Menu {
            Picker("Approval", selection: binding) {
                ForEach(CodexApprovalMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
        } label: {
            chipLabel(icon: "hand.raised", text: session.codexApprovalMode.displayName)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Codex approval_policy")
    }

    private func claudeEffortChip(session: Session) -> some View {
        let binding = Binding<ClaudeEffort>(
            get: { session.claudeEffort },
            set: { store.setClaudeEffort($0, on: session.id) }
        )
        return Menu {
            Picker("Effort", selection: binding) {
                ForEach(ClaudeEffort.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
        } label: {
            chipLabel(icon: "bolt", text: session.claudeEffort.displayName)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Claude --effort")
    }

    private func codexEffortChip(session: Session) -> some View {
        let binding = Binding<Profile.ReasoningEffort>(
            get: { session.codexEffort },
            set: { store.setCodexEffort($0, on: session.id) }
        )
        return Menu {
            Picker("Effort", selection: binding) {
                ForEach(Profile.ReasoningEffort.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
        } label: {
            chipLabel(icon: "bolt", text: session.codexEffort.displayName)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Codex model_reasoning_effort")
    }

    private func chipLabel(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
            Image(systemName: "chevron.down").font(.system(size: 8)).foregroundStyle(.tertiary)
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
            && attachments.isEmpty {
            drafts[sessionId] = nil
        } else {
            drafts[sessionId] = ComposerDraft(text: text,
                                              attachments: attachments)
        }
    }

    private func loadDraft(for sessionId: UUID?) {
        draftSessionId = sessionId
        guard let sessionId, let draft = drafts[sessionId] else {
            text = ""
            attachments = []
            return
        }
        text = draft.text
        attachments = draft.attachments
    }
}

private struct ComposerDraft {
    var text: String
    var attachments: [ImageAttachment]
}
