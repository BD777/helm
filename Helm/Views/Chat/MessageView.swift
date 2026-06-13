import AppKit
import MarkdownUI
import SwiftUI

struct MessageListView: View {
    @Environment(AppStore.self) private var store
    var onTranscriptTap: () -> Void = {}

    @StateObject private var autoScroll = ChatAutoScrollController()

    var body: some View {
        let items = displayItems

        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                if showStreamingPlaceholder {
                    streamingPlaceholder
                        .frame(maxWidth: DS.messageMaxWidth, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 18)
                } else {
                    ForEach(items) { item in
                        displayRow(item)
                            .frame(maxWidth: DS.messageMaxWidth, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 18)
                    }
                }
            }
            .transaction { transaction in
                transaction.animation = nil
            }
            .padding(.vertical, 24)
            .background(
                ScrollViewResolver { scrollView in
                    autoScroll.attach(scrollView)
                }
            )
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded(onTranscriptTap))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.helmChatBg)
        .overlay {
            if showHistoryLoading {
                historyLoadingView
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if autoScroll.showJumpToBottom {
                Button {
                    autoScroll.forceScrollToBottom(animated: true)
                } label: {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(.regularMaterial, in: Circle())
                        .overlay(
                            Circle()
                                .stroke(Color.helmBorderStrong, lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
                .help("Jump to latest")
                .accessibilityLabel("Jump to latest")
                .padding(.trailing, 28)
                .padding(.bottom, 18)
                .transition(.opacity.combined(with: .scale(scale: 0.94)))
            }
        }
        .animation(.easeOut(duration: 0.12), value: autoScroll.showJumpToBottom)
        .animation(.easeOut(duration: 0.12), value: showHistoryLoading)
        // Initial appearance lands at the bottom. Streaming follow is driven
        // from AppKit's real scroll geometry below so it can resume when the
        // user manually returns close to the bottom.
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .onAppear {
            autoScroll.forceScrollToBottom(animated: false)
        }
        .onChange(of: streamTick) { _, _ in
            autoScroll.followIfNeeded()
        }
        .onChange(of: store.sendTick) { _, _ in
            autoScroll.forceScrollToBottom(animated: false)
        }
        .onChange(of: store.appendTick) { _, _ in
            autoScroll.forceScrollToBottom(animated: false)
        }
        .onChange(of: store.selectedSessionId) { _, _ in
            autoScroll.prepareForSessionChange()
            autoScroll.forceScrollToBottom(animated: false)
        }
    }

    /// Re-derives the rendered turn structure from the raw transcript.
    /// Consecutive assistant messages get folded into a single
    /// `assistantTurn` so the multi-step "thinking" phase can collapse as
    /// one unit, mirroring Codex.
    private var displayItems: [DisplayItem] {
        guard let s = store.selectedSession else { return [] }
        return groupTranscript(s.transcript)
    }

    private var showHistoryLoading: Bool {
        store.selectedSessionIsLoadingHistory && displayItems.isEmpty
    }

    private var showStreamingPlaceholder: Bool {
        itemsAreEmpty && store.selectedSessionIsStreaming && !showHistoryLoading
    }

    private var itemsAreEmpty: Bool {
        displayItems.isEmpty
    }

    private var streamingPlaceholder: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Starting response...")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Starting response")
    }

    private var historyLoadingView: some View {
        VStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Loading conversation...")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.cornerRadiusSmall))
        .overlay(
            RoundedRectangle(cornerRadius: DS.cornerRadiusSmall)
                .stroke(Color.helmBorderStrong, lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading conversation")
    }

    @ViewBuilder
    private func displayRow(_ item: DisplayItem) -> some View {
        switch item {
        case .userMessage(let msg):
            MessageView(message: msg)
        case .event(let event):
            SessionEventView(event: event)
        case .assistantTurn(let thinking, let answer):
            let isRunning = answer == nil && store.selectedSessionIsStreaming
            VStack(alignment: .leading, spacing: 10) {
                if !thinking.isEmpty {
                    ThinkingBlock(
                        messages: thinking,
                        isRunning: isRunning
                    )
                }
                if let answer {
                    MessageView(
                        message: answer,
                        renderMarkdown: !isLiveStreamingMessage(answer)
                    )
                }
            }
        }
    }

    private func isLiveStreamingMessage(_ message: Message) -> Bool {
        guard store.selectedSessionIsStreaming else { return false }
        if message.meta == "streaming…" || message.meta == "thinking…" {
            return true
        }
        if case .assistant(let meta) = message.role {
            return meta == "streaming…" || meta == "thinking…"
        }
        return false
    }

    /// Combined "did the rendered transcript grow?" signal.
    /// - transcript.count covers new-message appends.
    /// - the last message's visible-part signature covers streaming text,
    ///   tool input deltas, and tool result bodies while row count is steady.
    private var streamTick: String {
        guard let s = store.selectedSession else { return "" }
        let lastMsg = s.transcript.reversed().lazy.compactMap { $0.message }.first
        let lastPartSignature = lastMsg?.parts.map { part -> String in
            switch part {
            case .text(let text):
                return "t\(text.count)"
            case .skillText(let segments):
                return "s\(segments.count):\(segments.hashValue)"
            case .toolCall(let call):
                return "c\(call.id.uuidString):\(call.arg.count):\(call.body?.count ?? 0):\(call.status)"
            case .image(let url):
                return "i\(url.lastPathComponent)"
            }
        }.joined(separator: "|") ?? ""
        return "\(s.id.uuidString):\(s.transcript.count):\(lastPartSignature)"
    }
}

@MainActor
private final class ChatAutoScrollController: ObservableObject {
    @Published private(set) var showJumpToBottom = false

    private weak var scrollView: NSScrollView?
    private weak var observedDocumentView: NSView?
    private var scrollObservers: [NSObjectProtocol] = []
    private var documentObserver: NSObjectProtocol?
    private var isPinnedToBottom = true
    private var isProgrammaticScroll = false
    private var isLiveUserScroll = false
    private var scheduledScrollID = 0

    private let jumpButtonTolerance: CGFloat = 96
    private let pinnedTolerance: CGFloat = 32
    private let animatedDuration: TimeInterval = 0.16

    deinit {
        let center = NotificationCenter.default
        for observer in scrollObservers {
            center.removeObserver(observer)
        }
        if let documentObserver {
            center.removeObserver(documentObserver)
        }
    }

    func attach(_ scrollView: NSScrollView) {
        if self.scrollView !== scrollView {
            removeScrollObservers()
            removeDocumentObserver()
            self.scrollView = scrollView
            scrollView.contentView.postsBoundsChangedNotifications = true

            let center = NotificationCenter.default
            scrollObservers.append(center.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.visibleBoundsDidChange()
                }
            })
            scrollObservers.append(center.addObserver(
                forName: NSScrollView.willStartLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isLiveUserScroll = true
                    self?.refreshJumpButton()
                }
            })
            scrollObservers.append(center.addObserver(
                forName: NSScrollView.didLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isLiveUserScroll = true
                    self?.refreshPinnedState(userInitiated: true)
                }
            })
            scrollObservers.append(center.addObserver(
                forName: NSScrollView.didEndLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isLiveUserScroll = false
                    self?.refreshPinnedState(userInitiated: true)
                }
            })
            isPinnedToBottom = true
        }

        observeDocumentView(scrollView.documentView)
        refreshJumpButton()
        if isPinnedToBottom {
            scheduleScrollToBottom(animated: false, force: false)
        }
    }

    func followIfNeeded() {
        guard isPinnedToBottom else { return }
        scheduleScrollToBottom(animated: false, force: false)
    }

    func prepareForSessionChange() {
        scheduledScrollID += 1
        isPinnedToBottom = true
        setShowJumpToBottom(false)
    }

    func forceScrollToBottom(animated: Bool) {
        isPinnedToBottom = true
        scheduleScrollToBottom(animated: animated, force: true)
    }

    private func visibleBoundsDidChange() {
        guard !isProgrammaticScroll, let scrollView else { return }
        refreshPinnedState(userInitiated: isLiveUserScroll || currentEventLooksLikeUserScroll(in: scrollView))
    }

    private func documentFrameDidChange() {
        guard scrollView != nil else { return }
        refreshJumpButton()
        guard isPinnedToBottom, !isLiveUserScroll else { return }
        scheduleScrollToBottom(animated: false, force: false)
    }

    private func refreshPinnedState(userInitiated: Bool) {
        guard let scrollView else { return }
        let distance = distanceFromBottom(in: scrollView)
        if userInitiated {
            isPinnedToBottom = distance <= pinnedTolerance
        } else if distance <= pinnedTolerance {
            isPinnedToBottom = true
        }
        setShowJumpToBottom(distance > jumpButtonTolerance)
    }

    private func refreshJumpButton() {
        guard let scrollView else {
            setShowJumpToBottom(false)
            return
        }
        setShowJumpToBottom(distanceFromBottom(in: scrollView) > jumpButtonTolerance)
    }

    private func observeDocumentView(_ documentView: NSView?) {
        guard observedDocumentView !== documentView else { return }

        let center = NotificationCenter.default
        if let documentObserver {
            center.removeObserver(documentObserver)
            self.documentObserver = nil
        }

        observedDocumentView = documentView
        guard let documentView else { return }
        documentView.postsFrameChangedNotifications = true
        documentObserver = center.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: documentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.documentFrameDidChange()
            }
        }
    }

    private func removeScrollObservers() {
        let center = NotificationCenter.default
        for observer in scrollObservers {
            center.removeObserver(observer)
        }
        scrollObservers = []
    }

    private func removeDocumentObserver() {
        if let documentObserver {
            NotificationCenter.default.removeObserver(documentObserver)
            self.documentObserver = nil
        }
        observedDocumentView = nil
    }

    private func scheduleScrollToBottom(animated: Bool, force: Bool) {
        scheduledScrollID += 1
        let scrollID = scheduledScrollID
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self,
                      self.scheduledScrollID == scrollID,
                      force || self.isPinnedToBottom
                else { return }
                self.scrollToBottom(animated: animated)
            }
        }
    }

    private func scrollToBottom(animated: Bool) {
        guard let scrollView, let documentView = scrollView.documentView else { return }

        scrollView.layoutSubtreeIfNeeded()
        documentView.layoutSubtreeIfNeeded()

        let clipView = scrollView.contentView
        let targetY = bottomOriginY(documentView: documentView,
                                    visibleHeight: clipView.bounds.height)
        let requestedBounds = NSRect(
            x: clipView.bounds.origin.x,
            y: targetY,
            width: clipView.bounds.width,
            height: clipView.bounds.height
        )
        let targetOrigin = clipView.constrainBoundsRect(requestedBounds).origin
        guard abs(clipView.bounds.origin.y - targetOrigin.y) > 0.5 else {
            isPinnedToBottom = true
            setShowJumpToBottom(false)
            return
        }

        isProgrammaticScroll = true
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = animatedDuration
                context.allowsImplicitAnimation = true
                clipView.animator().setBoundsOrigin(targetOrigin)
            } completionHandler: { [weak self, weak scrollView, weak clipView] in
                MainActor.assumeIsolated {
                    if let scrollView, let clipView {
                        scrollView.reflectScrolledClipView(clipView)
                    }
                    self?.finishProgrammaticScroll()
                }
            }
        } else {
            clipView.scroll(to: targetOrigin)
            scrollView.reflectScrolledClipView(clipView)
            finishProgrammaticScroll()
        }
    }

    private func finishProgrammaticScroll() {
        isPinnedToBottom = true
        setShowJumpToBottom(false)
        isProgrammaticScroll = false
    }

    private func setShowJumpToBottom(_ isVisible: Bool) {
        guard showJumpToBottom != isVisible else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self,
                      self.showJumpToBottom != isVisible
                else { return }
                self.showJumpToBottom = isVisible
            }
        }
    }

    private func currentEventLooksLikeUserScroll(in scrollView: NSScrollView) -> Bool {
        guard let event = NSApp.currentEvent else { return false }
        guard event.window === scrollView.window else { return false }

        switch event.type {
        case .scrollWheel, .leftMouseDragged, .rightMouseDragged,
             .otherMouseDragged, .leftMouseDown:
            return eventLocationIsInside(scrollView, event)
        case .keyDown:
            return isScrollNavigationKey(event)
                && firstResponderIsInside(scrollView)
        default:
            return false
        }
    }

    private func firstResponderIsInside(_ scrollView: NSScrollView) -> Bool {
        guard let responder = scrollView.window?.firstResponder else { return false }
        if responder === scrollView || responder === scrollView.contentView {
            return true
        }
        guard let view = responder as? NSView else { return false }
        return view === scrollView || view.isDescendant(of: scrollView)
    }

    private func eventLocationIsInside(_ scrollView: NSScrollView, _ event: NSEvent) -> Bool {
        let point = scrollView.convert(event.locationInWindow, from: nil)
        return scrollView.bounds.contains(point)
    }

    private func isScrollNavigationKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 49, 115, 116, 119, 121, 123, 124, 125, 126:
            return true
        default:
            return false
        }
    }

    private func distanceFromBottom(in scrollView: NSScrollView) -> CGFloat {
        guard let documentView = scrollView.documentView else { return 0 }
        let visibleRect = scrollView.documentVisibleRect
        let documentBounds = documentView.bounds

        if documentView.isFlipped {
            return max(0, documentBounds.maxY - visibleRect.maxY)
        } else {
            return max(0, visibleRect.minY - documentBounds.minY)
        }
    }

    private func bottomOriginY(documentView: NSView, visibleHeight: CGFloat) -> CGFloat {
        let documentBounds = documentView.bounds
        if documentView.isFlipped {
            return max(documentBounds.minY, documentBounds.maxY - visibleHeight)
        } else {
            return documentBounds.minY
        }
    }
}

private struct ScrollViewResolver: NSViewRepresentable {
    var onResolve: @MainActor (NSScrollView) -> Void

    func makeNSView(context: Context) -> ResolverView {
        let view = ResolverView()
        view.onResolve = onResolve
        return view
    }

    func updateNSView(_ nsView: ResolverView, context: Context) {
        nsView.onResolve = onResolve
        nsView.resolveSoon()
    }

    final class ResolverView: NSView {
        var onResolve: (@MainActor (NSScrollView) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            resolveSoon()
        }

        func resolveSoon() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let scrollView = self.enclosingScrollView else { return }
                Task { @MainActor in
                    self.onResolve?(scrollView)
                }
            }
        }
    }
}

/// Renderable unit one step removed from `TranscriptItem`. Same content,
/// different grouping: consecutive assistant messages collapse into a
/// single `assistantTurn` so the entire multi-step phase between user
/// turns can fold as a unit.
private enum DisplayItem: Identifiable {
    case userMessage(Message)
    case event(SessionEvent)
    case assistantTurn(thinking: [Message], answer: Message?)

    /// Stable id so SwiftUI keeps view state (notably ThinkingBlock's
    /// `userPreference`) across streaming updates. For an assistant turn
    /// we anchor to the first message in the run because that one is
    /// present from the moment the turn starts.
    var id: String {
        switch self {
        case .userMessage(let m):  return "u-\(m.id.uuidString)"
        case .event(let e):        return "e-\(e.id.uuidString)"
        case .assistantTurn(let thinking, let answer):
            let key = thinking.first?.id ?? answer?.id ?? UUID()
            return "a-\(key.uuidString)"
        }
    }
}

/// Groups consecutive assistant messages into one `assistantTurn`.
/// Tool-heavy assistant messages are split so process chatter and workflow
/// recaps collapse together, while the final substantive answer remains
/// visible in the transcript.
private func groupTranscript(_ items: [TranscriptItem]) -> [DisplayItem] {
    var out: [DisplayItem] = []
    var pending: [Message] = []

    func flush() {
        guard !pending.isEmpty else { return }
        let presentation = assistantTurnPresentation(for: pending)
        out.append(.assistantTurn(thinking: presentation.thinking,
                                  answer: presentation.answer))
        pending = []
    }

    for item in items {
        switch item {
        case .message(let m):
            if case .assistant = m.role {
                pending.append(m)
            } else {
                flush()
                out.append(.userMessage(m))
            }
        case .event(let e):
            flush()
            out.append(.event(e))
        }
    }
    flush()
    return out
}

private func assistantTurnPresentation(for messages: [Message]) -> (thinking: [Message], answer: Message?) {
    guard let last = messages.last else { return ([], nil) }
    let hasProcessArtifacts = messages.contains { containsToolCall($0) || isWorkflowRecapMessage($0) }

    if hasProcessArtifacts,
       let split = splitSubstantiveAnswer(from: messages) {
        return split
    }

    if containsToolCall(last) || isWorkingPlaceholder(last) || isWorkflowRecapMessage(last) {
        return (messages.filter { message in
            !isWorkingPlaceholder(message) || message.id == last.id
        }, nil)
    }

    let thinking = messages.dropLast().filter { !isWorkingPlaceholder($0) }
    return (Array(thinking), last)
}

private func splitSubstantiveAnswer(from messages: [Message]) -> (thinking: [Message], answer: Message?)? {
    for messageIndex in messages.indices.reversed() {
        let message = messages[messageIndex]
        guard !isWorkflowRecapMessage(message) else { continue }
        for partIndex in message.parts.indices.reversed() {
            guard case .text(let text) = message.parts[partIndex],
                  isSubstantiveAnswerText(text),
                  suffixIsHousekeeping(messages: messages,
                                       messageIndex: messageIndex,
                                       partIndex: partIndex)
            else { continue }

            var thinking: [Message] = []
            for idx in messages.indices {
                if idx == messageIndex {
                    let thoughtParts = Array(message.parts[..<partIndex])
                        + Array(message.parts[message.parts.index(after: partIndex)...])
                    appendThinkingMessage(message, parts: thoughtParts, to: &thinking)
                } else {
                    appendThinkingMessage(messages[idx], parts: messages[idx].parts, to: &thinking)
                }
            }

            var answer = message
            answer.role = .assistant(meta: "done")
            answer.meta = nil
            answer.parts = [.text(text)]
            answer.tokenUsage = estimateTokens(in: answer.parts)
            return (thinking, answer)
        }
    }
    return nil
}

private func appendThinkingMessage(_ message: Message, parts: [Part], to thinking: inout [Message]) {
    guard !parts.isEmpty || isWorkingPlaceholder(message) else { return }
    var copy = message
    copy.parts = parts
    thinking.append(copy)
}

private func suffixIsHousekeeping(messages: [Message], messageIndex: Int, partIndex: Int) -> Bool {
    let message = messages[messageIndex]
    let nextIndex = message.parts.index(after: partIndex)
    if nextIndex < message.parts.endIndex {
        for part in message.parts[nextIndex...] where !isHousekeepingPart(part) {
            return false
        }
    }
    if messageIndex + 1 < messages.endIndex {
        for message in messages[(messageIndex + 1)...] where !isHousekeepingMessage(message) {
            return false
        }
    }
    return true
}

private func isHousekeepingMessage(_ message: Message) -> Bool {
    if isWorkingPlaceholder(message) || isWorkflowRecapMessage(message) {
        return true
    }
    return !message.parts.isEmpty && message.parts.allSatisfy(isHousekeepingPart)
}

private func isHousekeepingPart(_ part: Part) -> Bool {
    switch part {
    case .toolCall(let call):
        return isHousekeepingToolCall(call)
    case .text(let text):
        return isWorkflowRecapText(text)
    case .skillText, .image:
        return false
    }
}

private func containsToolCall(_ message: Message) -> Bool {
    message.parts.contains { part in
        if case .toolCall = part { return true }
        return false
    }
}

private func isHousekeepingToolCall(_ call: ToolCall) -> Bool {
    let normalized = call.name
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: " ", with: "")
        .lowercased()
    return normalized == "taskupdate"
}

private func isWorkflowRecapMessage(_ message: Message) -> Bool {
    !message.parts.isEmpty && message.parts.allSatisfy { part in
        if case .text(let text) = part {
            return isWorkflowRecapText(text)
        }
        return isHousekeepingPart(part)
    }
}

private func isWorkflowRecapText(_ text: String) -> Bool {
    let normalized = text
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    guard !normalized.isEmpty else { return false }
    return normalized.contains("## workflow recap")
        || normalized.contains("workflow recap as required by the skill contract")
        || (normalized.contains("workflow recap") && normalized.contains("node outcomes"))
}

private func isSubstantiveAnswerText(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !isWorkflowRecapText(trimmed) else { return false }
    if trimmed.count >= 180 { return true }
    if trimmed.contains("\n## ") || trimmed.contains("\n### ") { return true }
    if trimmed.contains("|") && trimmed.contains("\n|") { return true }
    let lower = trimmed.lowercased()
    let progressPrefixes = [
        "now let me",
        "let me ",
        "i'll ",
        "i will ",
        "good, ",
        "the binary is",
        "this is a different"
    ]
    return !progressPrefixes.contains { lower.hasPrefix($0) }
}

private func isWorkingPlaceholder(_ message: Message) -> Bool {
    guard message.parts.isEmpty else { return false }
    if message.meta == "thinking…" || message.meta == "streaming…" {
        return true
    }
    if case .assistant(let meta) = message.role {
        return meta == "thinking…" || meta == "streaming…"
    }
    return false
}

struct MessageView: View {
    let message: Message
    var renderMarkdown: Bool = true
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            MessagePartListView(parts: message.parts,
                                spacing: 6,
                                renderMarkdown: renderMarkdown)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, isUser ? 12 : 0)
            .padding(.top, isUser ? 9 : 0)
            .padding(.bottom, isUser ? 7 : 0)
            .background(
                isUser
                ? RoundedRectangle(cornerRadius: DS.cornerRadius)
                    .fill(Color.accentColor.opacity(0.08))
                : nil
            )

            if canCopyMarkdown {
                copyControls
            }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }

    private var isUser: Bool {
        if case .user = message.role { return true }
        return false
    }

    private var markdownForCopy: String {
        message.parts.markdownSourceForCopy()
    }

    private var canCopyMarkdown: Bool {
        !markdownForCopy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var copyControls: some View {
        HStack(spacing: 0) {
            if isUser {
                Spacer(minLength: 0)
                controlCluster
            } else {
                controlCluster
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 18, maxHeight: 18, alignment: isUser ? .trailing : .leading)
    }

    private var controlCluster: some View {
        HStack(spacing: 12) {
            if !isUser {
                CopyMarkdownButton(markdown: markdownForCopy)
                    .opacity(isHovering ? 1 : 0)
                    .allowsHitTesting(isHovering)
            }
            if let timestamp = displayTimestamp {
                Text(timestamp)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .opacity(isHovering ? 1 : 0)
            }
            if isUser {
                CopyMarkdownButton(markdown: markdownForCopy)
                    .opacity(isHovering ? 1 : 0)
                    .allowsHitTesting(isHovering)
            }
        }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private var displayTimestamp: String? {
        guard let date = message.startedAt ?? message.endedAt else { return nil }
        return Self.timestampFormatter.string(from: date)
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}

private struct CopyMarkdownButton: View {
    let markdown: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(markdown, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 18, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(copied ? "Copied" : "Copy Markdown")
        .accessibilityLabel(copied ? "Copied Markdown" : "Copy Markdown")
    }
}

private extension Array where Element == Part {
    func markdownSourceForCopy() -> String {
        var output = ""
        var previousWasText = false

        func appendBlock(_ block: String) {
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if !output.isEmpty {
                output += "\n\n"
            }
            output += trimmed
            previousWasText = false
        }

        for part in self {
            switch part {
            case .text(let text):
                guard !text.isEmpty else { continue }
                output += text
                previousWasText = true
            case .skillText(let segments):
                let text = segments.map(\.markdownSourceForCopy).joined()
                if previousWasText, !output.isEmpty {
                    output += text
                    previousWasText = true
                } else {
                    appendBlock(text)
                }
            case .image(let url):
                appendBlock("![\(url.lastPathComponent)](\(url.path))")
            case .toolCall:
                continue
            }
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension SkillTextSegment {
    var markdownSourceForCopy: String {
        if let text {
            return text
        }
        if let skillName, !skillName.isEmpty {
            return "$\(skillName)"
        }
        return ""
    }
}

private enum MessagePartDisplayItem: Identifiable {
    case textGroup(id: String, text: String)
    case single(id: String, part: Part)
    case toolGroup(id: String, calls: [ToolCall])

    var id: String {
        switch self {
        case .textGroup(let id, _):
            return id
        case .single(let id, _), .toolGroup(let id, _):
            return id
        }
    }
}

private struct MessagePartListView: View {
    let parts: [Part]
    let spacing: CGFloat
    var renderMarkdown: Bool = true
    var turnStartedAt: Date? = nil
    var isTurnRunning: Bool = false
    var turnTokenUsage: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(groupedParts) { item in
                itemView(item)
            }
        }
    }

    private var groupedParts: [MessagePartDisplayItem] {
        groupConsecutiveToolCalls(parts)
    }

    @ViewBuilder
    private func itemView(_ item: MessagePartDisplayItem) -> some View {
        switch item {
        case .textGroup(_, let text):
            textView(text)
        case .single(_, let part):
            partView(part)
        case .toolGroup(_, let calls):
            ToolCallGroupCard(
                calls: calls
            )
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func partView(_ part: Part) -> some View {
        switch part {
        case .text(let s):
            textView(s)
        case .skillText(let segments):
            InlineSkillText(segments: segments)
                .padding(.top, 2)
        case .toolCall(let t):
            ToolCallCard(call: t)
                .padding(.vertical, 4)
        case .image(let url):
            ImagePartView(url: url)
                .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func textView(_ text: String) -> some View {
        if renderMarkdown {
            MarkdownishText(text)
                .padding(.top, 2)
        } else {
            PlainStreamingText(text)
                .padding(.top, 2)
        }
    }
}

private func groupConsecutiveToolCalls(_ parts: [Part]) -> [MessagePartDisplayItem] {
    var out: [MessagePartDisplayItem] = []
    var pendingCalls: [(offset: Int, call: ToolCall)] = []
    var pendingText: [(offset: Int, text: String)] = []

    func flushPendingText() {
        guard !pendingText.isEmpty else { return }
        let text = pendingText.map(\.text).joined()
        let firstOffset = pendingText.first?.offset ?? 0
        out.append(.textGroup(
            id: "txt-\(firstOffset)-\(text.hashValue)",
            text: text
        ))
        pendingText = []
    }

    func flushPendingCalls() {
        guard !pendingCalls.isEmpty else { return }
        if pendingCalls.count == 1,
           let pending = pendingCalls.first {
            out.append(.single(
                id: "p-\(pending.offset)-\(Part.toolCall(pending.call).id)",
                part: .toolCall(pending.call)
            ))
        } else if let first = pendingCalls.first {
            out.append(.toolGroup(
                id: "tg-\(first.call.id.uuidString)",
                calls: pendingCalls.map(\.call)
            ))
        }
        pendingCalls = []
    }

    for (offset, part) in parts.enumerated() {
        switch part {
        case .text(let text):
            flushPendingCalls()
            pendingText.append((offset, text))
        case .toolCall(let call):
            flushPendingText()
            pendingCalls.append((offset, call))
        default:
            flushPendingText()
            flushPendingCalls()
            out.append(.single(id: "p-\(offset)-\(part.id)", part: part))
        }
    }
    flushPendingText()
    flushPendingCalls()
    return out
}

/// Foldable container for an entire multi-step thinking phase (one or
/// more consecutive assistant messages, each potentially with tool
/// calls). Default state tracks the running flag — open while the agent
/// is working, auto-collapsed once a formal answer arrives — but a user
/// toggle pins the state so manual choice always wins.
private struct ThinkingBlock: View {
    let messages: [Message]
    let isRunning: Bool
    @State private var userPreference: Bool? = nil

    private var collapsed: Bool { userPreference ?? !isRunning }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if !collapsed {
                MessagePartListView(
                    parts: flattenedParts,
                    spacing: 10,
                    renderMarkdown: !isRunning,
                    turnStartedAt: turnStartedAt,
                    isTurnRunning: isRunning,
                    turnTokenUsage: turnTokenUsage
                )
            }
        }
    }

    private var flattenedParts: [Part] {
        messages.flatMap { $0.parts }
    }

    private var stepCount: Int {
        messages.reduce(0) { acc, msg in
            acc + msg.parts.reduce(into: 0) { sub, part in
                if case .toolCall = part { sub += 1 }
            }
        }
    }

    private var turnStartedAt: Date? {
        messages.lazy.compactMap(\.startedAt).first
    }

    private var turnEndedAt: Date? {
        messages.lazy.compactMap(\.endedAt).max()
    }

    private var turnTokenUsage: Int {
        if let explicit = messages.lazy.compactMap(\.tokenUsage).first, explicit > 0 {
            return explicit
        }
        return estimateTokens(in: flattenedParts)
    }

    private func label(for date: Date) -> String {
        let base: String
        if isRunning {
            base = stepCount > 0 ? "处理中 · \(stepCount) 步" : "处理中"
        } else if isStopped {
            base = stepCount > 0 ? "已停止 · \(stepCount) 步" : "已停止"
        } else if hasTurnError {
            base = stepCount > 0 ? "出错 · \(stepCount) 步" : "出错"
        } else {
            base = stepCount > 0 ? "已处理 · \(stepCount) 步" : "已处理"
        }

        var segments: [String] = [base]

        if let elapsed = turnElapsed(for: date), elapsed >= 3 {
            segments.append(formatElapsed(elapsed))
        }

        let tokens = turnTokenUsage
        if tokens >= 100 {
            segments.append("↓ " + formatTokens(tokens))
        }

        return segments.joined(separator: " · ")
    }

    private func turnElapsed(for date: Date) -> TimeInterval? {
        guard let start = turnStartedAt else { return nil }
        if isRunning {
            return date.timeIntervalSince(start)
        }
        if let end = turnEndedAt {
            return end.timeIntervalSince(start)
        }
        return nil
    }

    private var hasDetails: Bool {
        messages.contains { !$0.parts.isEmpty }
    }

    private var isStopped: Bool {
        messages.contains { message in
            if message.meta == "stopped" { return true }
            if case .assistant(let meta) = message.role {
                return meta == "stopped"
            }
            return message.parts.contains { part in
                if case .toolCall(let call) = part,
                   case .stopped = call.status {
                    return true
                }
                return false
            }
        }
    }

    private var hasTurnError: Bool {
        messages.contains { message in
            if message.meta == "error" { return true }
            if case .assistant(let meta) = message.role {
                return meta == "error"
            }
            return false
        }
    }

    @ViewBuilder
    private var header: some View {
        if hasDetails {
            Button {
                userPreference = !collapsed
            } label: {
                headerContent(showChevron: true)
                    .contentShape(Rectangle())
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(currentAccessibilityLabel)
                    .accessibilityValue(collapsed ? "collapsed" : "expanded")
                    .accessibilityHint(collapsed ? "Show steps" : "Hide steps")
            }
            .buttonStyle(.plain)
        } else {
            headerContent(showChevron: false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(currentAccessibilityLabel)
        }
    }

    private var currentAccessibilityLabel: String {
        label(for: Date())
    }

    private func headerContent(showChevron: Bool) -> some View {
        Group {
            if isRunning {
                TimelineView(.periodic(from: Date(), by: 1)) { context in
                    headerRow(for: context.date, showChevron: showChevron)
                }
            } else {
                headerRow(for: turnEndedAt ?? Date(), showChevron: showChevron)
            }
        }
    }

    private func headerRow(for date: Date, showChevron: Bool) -> some View {
        HStack(spacing: 6) {
            if isRunning {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.72)
            }
            Text(label(for: date))
                .font(.system(size: 12.5))
                .foregroundStyle(.tertiary)
            if showChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .animation(Self.expandCollapseAnimation, value: collapsed)
            }
            Spacer(minLength: 0)
        }
    }

    private static let expandCollapseAnimation = Animation.easeInOut(duration: 0.18)
}

private struct ImagePartView: View {
    @Environment(AppStore.self) private var store
    let url: URL
    @State private var isHovering = false

    var body: some View {
        if let img = NSImage(contentsOf: url) {
            let size = fittedDisplaySize(for: img)
            Button {
                store.imagePreviewURL = url
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(width: size.width, height: size.height)
                        .background(Color.helmChatBg)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.helmBorderStrong, lineWidth: 0.5)
                        )

                    if isHovering {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .background(.regularMaterial, in: Circle())
                            .padding(6)
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) {
                    isHovering = hovering
                }
            }
            .help("Preview image")
            .accessibilityLabel("Preview image")
        } else {
            HStack(spacing: 6) {
                Image(systemName: "photo")
                    .foregroundStyle(.tertiary)
                Text("image unavailable")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.1))
            )
        }
    }

    private func fittedDisplaySize(for image: NSImage) -> CGSize {
        let rawSize = bitmapSize(for: image)
        guard rawSize.width > 0, rawSize.height > 0 else {
            return CGSize(width: 240, height: 160)
        }

        let maxSize = CGSize(width: 420, height: 320)
        let scale = min(maxSize.width / rawSize.width,
                        maxSize.height / rawSize.height,
                        1)

        return CGSize(width: max(1, floor(rawSize.width * scale)),
                      height: max(1, floor(rawSize.height * scale)))
    }

    private func bitmapSize(for image: NSImage) -> CGSize {
        if let bitmap = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first {
            return CGSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
        }
        return image.size
    }
}

struct ImagePreviewOverlay: View {
    let url: URL
    var onDismiss: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let cardWidth = min(860, max(280, proxy.size.width - 96))
            let cardHeight = min(620, max(260, proxy.size.height - 84))

            ZStack {
                Color.black.opacity(0.16)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onDismiss()
                    }

                previewCard(width: cardWidth, height: cardHeight)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .accessibilityAddTraits(.isModal)
    }

    private func previewCard(width: CGFloat, height: CGFloat) -> some View {
        VStack(spacing: 0) {
            header
            Divider()
            previewContent
        }
        .frame(width: width, height: height)
        .background(Color.helmChatBg)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.helmBorderStrong, lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 20, x: 0, y: 10)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture {}
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "photo")
                .foregroundStyle(.tertiary)
            Text(url.lastPathComponent)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close preview")
            .accessibilityLabel("Close preview")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    @ViewBuilder
    private var previewContent: some View {
        if let image = NSImage(contentsOf: url) {
            GeometryReader { proxy in
                let imageSize = fittedPreviewSize(
                    for: image,
                    in: CGSize(width: max(1, proxy.size.width - 36),
                               height: max(1, proxy.size.height - 36))
                )

                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: imageSize.width, height: imageSize.height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.helmChatBg)
            }
        } else {
            ContentUnavailableView(
                "Image unavailable",
                systemImage: "photo",
                description: Text("The attached image could not be loaded.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.helmChatBg)
        }
    }

    private func fittedPreviewSize(for image: NSImage, in maxSize: CGSize) -> CGSize {
        let rawSize = bitmapSize(for: image)
        guard rawSize.width > 0, rawSize.height > 0 else {
            return CGSize(width: min(240, maxSize.width),
                          height: min(160, maxSize.height))
        }

        let scale = min(maxSize.width / rawSize.width,
                        maxSize.height / rawSize.height,
                        1)
        return CGSize(width: max(1, floor(rawSize.width * scale)),
                      height: max(1, floor(rawSize.height * scale)))
    }

    private func bitmapSize(for image: NSImage) -> CGSize {
        if let bitmap = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first {
            return CGSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
        }
        return image.size
    }
}

private struct InlineSkillText: NSViewRepresentable {
    let segments: [SkillTextSegment]

    func makeNSView(context: Context) -> NSTextView {
        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = true
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.font = ComposerTextView.font
        tv.textStorage?.setAttributedString(attributedText())
        return tv
    }

    func updateNSView(_ tv: NSTextView, context: Context) {
        tv.textStorage?.setAttributedString(attributedText())
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        guard let lm = nsView.layoutManager,
              let tc = nsView.textContainer
        else { return nil }
        let width: CGFloat = {
            if let w = proposal.width, w.isFinite, w > 0 { return w }
            if nsView.bounds.width > 0 { return nsView.bounds.width }
            return 600
        }()
        if tc.size.width != width {
            tc.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc)
        return CGSize(width: width, height: max(lm.defaultLineHeight(for: ComposerTextView.font),
                                                ceil(used.height)))
    }

    private func attributedText() -> NSAttributedString {
        let out = NSMutableAttributedString()
        for segment in segments {
            if let name = segment.skillName, !name.isEmpty {
                out.append(NSAttributedString(attachment: MessageSkillTextAttachment(name: name)))
            } else if let text = segment.text, !text.isEmpty {
                out.append(NSAttributedString(string: text,
                                              attributes: ComposerTextView.plainTextAttributes))
            }
        }
        return out
    }
}

private final class MessageSkillTextAttachment: NSTextAttachment {
    init(name: String) {
        super.init(data: nil, ofType: nil)
        let image = ComposerSkillChipRenderer.image(forName: name)
        self.image = image
        self.bounds = NSRect(x: 0,
                             y: ComposerSkillChipRenderer.baselineOffset,
                             width: image.size.width,
                             height: image.size.height)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

/// Full GitHub-flavored Markdown renderer for completed chat content.
///
/// Uses a mixed rendering strategy for best results:
///
/// - **Text blocks** (paragraphs, headings, lists, code blocks, quotes) render via
///   an AppKit `NSTextView` backed by an `NSAttributedString` built from
///   MarkdownUI's HTML renderer. This gives continuous drag selection across
///   paragraphs and proper I-beam cursors — things SwiftUI Text views can't do.
///
/// - **Table blocks** render with SwiftUI `Markdown` natively. NSTextView's
///   HTML table support is too limited for good visuals, so tables fall back to
///   SwiftUI rendering where MarkdownUI's full table theme shines.
///
/// The trade-off: selection can't cross a table boundary. That's rare in
/// practice and a reasonable price for correct table visuals.
///
/// Streaming text still uses the plain-text AppKit path so partially emitted
/// Markdown does not thrash layout.
struct MarkdownishText: View {
    let raw: String

    init(_ raw: String) { self.raw = raw }

    var body: some View {
        let sanitized = MarkdownDisplaySanitizer.sanitize(raw)
        let blocks = MarkdownBlockSplitter.split(sanitized)

        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let text):
                    SelectableMarkdownTextView(markdown: text)
                        .fixedSize(horizontal: false, vertical: true)
                case .table(let text):
                    Markdown(text)
                        .markdownTheme(.helmChat)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 10)
                case .codeBlock(let text):
                    Markdown(text)
                        .markdownTheme(.helmChat)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 4)
                }
            }
        }
    }
}

/// Splits a Markdown string into blocks that are optimally handled by
/// different renderers. Currently only distinguishes table blocks from
/// everything else — tables go to SwiftUI Markdown, the rest to NSTextView.
private enum MarkdownBlockSplitter {
    enum Block {
        case text(String)
        case table(String)
        case codeBlock(String)
    }

    static func split(_ markdown: String) -> [Block] {
        let lines = markdown.components(separatedBy: .newlines)
        var blocks: [Block] = []
        var currentTextLines: [String] = []
        var i = 0

        func flushText() {
            if !currentTextLines.isEmpty {
                blocks.append(.text(currentTextLines.joined(separator: "\n")))
                currentTextLines.removeAll()
            }
        }

        while i < lines.count {
            let line = lines[i]

            // Detect a fenced code block (``` or ~~~). Route it to MarkdownUI,
            // whose `.codeBlock` theme renders far nicer line spacing, padding,
            // and background than the AppKit HTML importer.
            if let fence = fenceMarker(in: line) {
                flushText()

                var codeLines: [String] = [line] // opening fence (keeps language)
                i += 1
                while i < lines.count {
                    codeLines.append(lines[i])
                    let closed = fenceMarker(in: lines[i]) == fence
                    i += 1
                    if closed { break }
                }

                blocks.append(.codeBlock(codeLines.joined(separator: "\n")))
                continue
            }

            // Detect a potential table: line contains | and next line is a
            // separator row (| --- | --- | pattern).
            if looksLikeTableRow(line), i + 1 < lines.count, looksLikeTableSeparator(lines[i + 1]) {
                flushText()

                // Collect the full table block
                var tableLines: [String] = []
                tableLines.append(line)       // header
                tableLines.append(lines[i + 1]) // separator
                i += 2

                while i < lines.count, looksLikeTableRow(lines[i]) {
                    tableLines.append(lines[i])
                    i += 1
                }

                blocks.append(.table(tableLines.joined(separator: "\n")))
                continue
            }

            currentTextLines.append(line)
            i += 1
        }

        flushText()
        return blocks
    }

    /// Returns the fence character (` ` ``` ` or `~`) if the line opens/closes a
    /// fenced code block, else nil. A fence is 3+ identical markers, optionally
    /// indented up to 3 spaces, optionally followed by an info string.
    private static func fenceMarker(in line: String) -> Character? {
        var trimmed = Substring(line)
        var indent = 0
        while let first = trimmed.first, first == " ", indent < 3 {
            trimmed = trimmed.dropFirst()
            indent += 1
        }
        guard let marker = trimmed.first, marker == "`" || marker == "~" else { return nil }
        let run = trimmed.prefix { $0 == marker }
        return run.count >= 3 ? marker : nil
    }

    private static func looksLikeTableRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        // A table row contains at least one | and isn't a fence / hr.
        return trimmed.contains("|")
            && !trimmed.hasPrefix("```")
            && !trimmed.allSatisfy({ $0 == "-" || $0 == " " || $0 == "_" || $0 == "*" })
    }

    private static func looksLikeTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return false }
        // Strip | and whitespace; remaining characters should be only - and :
        let stripped = trimmed
            .replacingOccurrences(of: "|", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard !stripped.isEmpty else { return false }
        return stripped.allSatisfy({ $0 == "-" || $0 == ":" })
    }
}

/// AppKit-backed markdown text view with continuous multi-paragraph selection.
private struct SelectableMarkdownTextView: NSViewRepresentable {
    let markdown: String

    func makeNSView(context: Context) -> MeasuredSelectableTextView {
        let view = MeasuredSelectableTextView()
        updateContent(in: view)
        return view
    }

    func updateNSView(_ nsView: MeasuredSelectableTextView, context: Context) {
        updateContent(in: nsView)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MeasuredSelectableTextView, context: Context) -> CGSize? {
        let width: CGFloat = {
            if let w = proposal.width, w.isFinite, w > 0 { return w }
            if nsView.bounds.width > 0 { return nsView.bounds.width }
            return 600
        }()
        return nsView.sizeThatFits(width: width)
    }

    private func updateContent(in view: MeasuredSelectableTextView) {
        let attributed = ChatTextStyler.markdownAttributedString(markdown)
        view.setAttributedString(attributed,
                                 sourceText: markdown,
                                 treatsAsPlainText: false)
    }
}

/// Plain (non-markdown) streaming text rendered inside a single selectable
/// AppKit text view so multi-line drag selection works correctly.
private struct PlainStreamingText: View {
    let raw: String

    init(_ raw: String) { self.raw = raw }

    var body: some View {
        SelectablePlainTextView(text: raw)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private extension Theme {
    static let helmChat = Theme()
        .text {
            ForegroundColor(.primary)
            FontSize(15)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.9))
            BackgroundColor(Color.primary.opacity(0.08))
        }
        .strong {
            FontWeight(.semibold)
        }
        .link {
            ForegroundColor(.accentColor)
        }
        .heading1 { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.12))
                .markdownMargin(top: 4, bottom: 10)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.35))
                }
        }
        .heading2 { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.12))
                .markdownMargin(top: 4, bottom: 9)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.22))
                }
        }
        .heading3 { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.12))
                .markdownMargin(top: 3, bottom: 8)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.1))
                }
        }
        .heading4 { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.12))
                .markdownMargin(top: 2, bottom: 7)
                .markdownTextStyle {
                    FontWeight(.semibold)
                }
        }
        .heading5 { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.12))
                .markdownMargin(top: 2, bottom: 6)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(0.95))
                }
        }
        .heading6 { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.12))
                .markdownMargin(top: 2, bottom: 6)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(0.92))
                    ForegroundColor(.secondary)
                }
        }
        .paragraph { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .relativeLineSpacing(.em(0.24))
                .markdownMargin(top: 0, bottom: 8)
        }
        .blockquote { configuration in
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.helmBorderStrong)
                    .frame(width: 3)
                configuration.label
                    .markdownTextStyle {
                        ForegroundColor(.secondary)
                    }
            }
            .fixedSize(horizontal: false, vertical: true)
            .markdownMargin(top: 2, bottom: 10)
        }
        .codeBlock { configuration in
            ScrollView(.horizontal, showsIndicators: false) {
                configuration.label
                    .fixedSize(horizontal: true, vertical: true)
                    .relativeLineSpacing(.em(0.18))
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.9))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
            .background(Color.helmCard.opacity(0.75), in: RoundedRectangle(cornerRadius: DS.cornerRadiusSmall))
            .overlay(
                RoundedRectangle(cornerRadius: DS.cornerRadiusSmall)
                    .stroke(Color.helmBorderStrong, lineWidth: 0.5)
            )
            .markdownMargin(top: 2, bottom: 10)
        }
        .listItem { configuration in
            configuration.label
                .markdownMargin(top: .em(0.18))
        }
        .taskListMarker { configuration in
            Image(systemName: configuration.isCompleted ? "checkmark.square.fill" : "square")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.secondary, Color.helmCard)
                .imageScale(.small)
                .relativeFrame(minWidth: .em(1.45), alignment: .trailing)
        }
        .table { configuration in
            ScrollView(.horizontal, showsIndicators: true) {
                configuration.label
                    .fixedSize(horizontal: true, vertical: true)
                    .markdownTableBorderStyle(.init(color: Color.helmBorderStrong, width: 0.75))
                    .markdownTableBackgroundStyle(
                        .alternatingRows(
                            Color.clear,
                            Color.helmHover.opacity(0.55),
                            header: Color.helmHover.opacity(0.9)
                        )
                    )
            }
            .markdownMargin(top: 4, bottom: 12)
        }
        .tableCell { configuration in
            configuration.label
                .markdownTextStyle {
                    if configuration.row == 0 {
                        FontWeight(.semibold)
                    }
                    BackgroundColor(nil)
                }
                .fixedSize(horizontal: false, vertical: true)
                .relativeLineSpacing(.em(0.18))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
        .thematicBreak {
            Divider()
                .overlay(Color.helmBorderStrong)
                .markdownMargin(top: 10, bottom: 10)
        }
}

/// AppKit-backed plain text view with continuous multi-line selection support.
private struct SelectablePlainTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> MeasuredSelectableTextView {
        let view = MeasuredSelectableTextView()
        updateContent(in: view)
        return view
    }

    func updateNSView(_ nsView: MeasuredSelectableTextView, context: Context) {
        updateContent(in: nsView)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MeasuredSelectableTextView, context: Context) -> CGSize? {
        let width: CGFloat = {
            if let w = proposal.width, w.isFinite, w > 0 { return w }
            if nsView.bounds.width > 0 { return nsView.bounds.width }
            return 600
        }()
        return nsView.sizeThatFits(width: width)
    }

    private func updateContent(in view: MeasuredSelectableTextView) {
        let attributed = ChatTextStyler.plainTextAttributedString(text)
        view.setAttributedString(attributed,
                                 sourceText: text,
                                 treatsAsPlainText: true)
    }
}

private final class MeasuredSelectableTextView: NSView {
    private let textView = NonEditableTextView()
    private var hasContent = false
    private var lastSourceText = ""
    private var lastTreatsAsPlainText = false
    private var measuredWidth: CGFloat = 0

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureTextView()
        addSubview(textView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func setAttributedString(_ attributed: NSAttributedString,
                             sourceText: String,
                             treatsAsPlainText: Bool) {
        guard !hasContent
            || sourceText != lastSourceText
            || treatsAsPlainText != lastTreatsAsPlainText
        else { return }

        hasContent = true
        lastSourceText = sourceText
        lastTreatsAsPlainText = treatsAsPlainText
        textView.textStorage?.setAttributedString(attributed)
        invalidateMeasuredLayout()
    }

    func sizeThatFits(width: CGFloat) -> CGSize {
        let resolvedWidth = max(1, width)
        let height = measuredHeight(for: resolvedWidth)
        return CGSize(width: resolvedWidth, height: height)
    }

    override var intrinsicContentSize: NSSize {
        let width = measuredWidth > 0 ? measuredWidth : max(1, bounds.width)
        return NSSize(width: NSView.noIntrinsicMetric,
                      height: measuredHeight(for: width))
    }

    override func layout() {
        super.layout()
        textView.frame = bounds
        updateTextContainerWidth(max(1, bounds.width))
    }

    override func setFrameSize(_ newSize: NSSize) {
        let oldWidth = frame.size.width
        super.setFrameSize(newSize)
        if abs(oldWidth - newSize.width) > 0.5 {
            updateTextContainerWidth(max(1, newSize.width))
            invalidateMeasuredLayout()
        }
    }

    private func configureTextView() {
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.allowsUndo = false
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.lineBreakMode = .byWordWrapping
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.controlAccentColor,
            .underlineStyle: NSNumber(value: NSUnderlineStyle.single.rawValue)
        ]
        textView.importsGraphics = true
    }

    private func measuredHeight(for width: CGFloat) -> CGFloat {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer
        else {
            return ceil(ChatTextStyler.baseFont.pointSize * 1.3)
        }

        updateTextContainerWidth(width)
        layoutManager.ensureLayout(for: textContainer)
        let usedHeight = ceil(layoutManager.usedRect(for: textContainer).height)
        let minimumHeight = ceil(layoutManager.defaultLineHeight(for: ChatTextStyler.baseFont))
        return max(minimumHeight, usedHeight)
    }

    private func updateTextContainerWidth(_ width: CGFloat) {
        guard let textContainer = textView.textContainer else { return }
        let textWidth = max(1, width - textView.textContainerInset.width * 2)
        if abs(textContainer.size.width - textWidth) > 0.5 {
            textContainer.size = NSSize(width: textWidth,
                                        height: CGFloat.greatestFiniteMagnitude)
        }
        measuredWidth = width
    }

    private func invalidateMeasuredLayout() {
        needsLayout = true
        invalidateIntrinsicContentSize()
        superview?.needsLayout = true
    }
}

/// An `NSTextView` subclass that forces an I-beam cursor over its entire
/// bounds and opens clicked links in the default browser instead of trying to
/// edit them inline.
private final class NonEditableTextView: NSTextView {
    override var isFlipped: Bool { true }

    /// Build the view on a TextKit 1 stack that uses `InlineCodeLayoutManager`
    /// so inline code spans render as rounded, padded pills.
    convenience init() {
        let textStorage = NSTextStorage()
        let layoutManager = InlineCodeLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        self.init(frame: .zero, textContainer: container)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .iBeam)
    }

    override func mouseDown(with event: NSEvent) {
        // Only intercept single clicks that land precisely on a link.
        // Double-clicks (word selection) and drag selections always fall
        // through to super so cross-line / cross-paragraph selection works.
        guard event.clickCount == 1, event.type == .leftMouseDown else {
            super.mouseDown(with: event)
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        let length = textStorage?.length ?? 0
        guard length > 0 else {
            super.mouseDown(with: event)
            return
        }
        let glyphIndex = layoutManager?.glyphIndex(
            for: point,
            in: textContainer ?? NSTextContainer(),
            fractionOfDistanceThroughGlyph: nil
        ) ?? NSNotFound
        guard glyphIndex != NSNotFound, glyphIndex < length else {
            super.mouseDown(with: event)
            return
        }
        let charIndex = layoutManager?.characterIndexForGlyph(at: glyphIndex) ?? glyphIndex
        guard charIndex < length else {
            super.mouseDown(with: event)
            return
        }
        let fullRange = NSRange(location: 0, length: length)
        var effectiveRange = NSRange(location: NSNotFound, length: 0)
        if let storage = textStorage,
           let link = storage.attribute(.link, at: charIndex, longestEffectiveRange: &effectiveRange, in: fullRange) {
            if let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) {
                NSWorkspace.shared.open(url)
                return
            }
        }
        super.mouseDown(with: event)
    }
}

/// A layout manager that paints a rounded, padded background behind inline
/// code spans (runs carrying `inlineCodeKey`). This replaces the default
/// `.backgroundColor` rendering, which draws a tight square box with no
/// padding and looks like a flat grey rectangle.
private final class InlineCodeLayoutManager: NSLayoutManager {
    /// Visual padding painted on each side of the glyphs inside the pill.
    private let horizontalPadding = inlineCodePillPadding
    private let paddingTop: CGFloat = 2.5
    private let paddingBottom: CGFloat = 3.0
    private let cornerRadius: CGFloat = 4.5

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let textStorage, let textContainer = textContainers.first else { return }

        let fill = NSColor.labelColor.withAlphaComponent(0.075)
        let stroke = NSColor.labelColor.withAlphaComponent(0.09)

        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        textStorage.enumerateAttribute(inlineCodeKey, in: charRange, options: []) { value, runRange, _ in
            guard (value as? Bool) == true else { return }

            let font = (textStorage.attribute(.font, at: runRange.location, effectiveRange: nil) as? NSFont)
                ?? ChatTextStyler.monoFont
            let runGlyphRange = self.glyphRange(forCharacterRange: runRange, actualCharacterRange: nil)

            // `enumerateEnclosingRects` returns tight rects that start exactly at
            // the glyphs (the same geometry selection highlighting uses), so —
            // unlike `boundingRect` — a run that begins a line never has its
            // left edge snapped to the line origin. That prevents swallowing a
            // preceding list marker and prevents over-extending into the next
            // span (which made adjacent pills overlap). It also splits wrapped
            // runs into one rect per line fragment automatically.
            var rects: [CGRect] = []
            self.enumerateEnclosingRects(forGlyphRange: runGlyphRange,
                                         withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                         in: textContainer) { fragmentRect, _ in
                rects.append(fragmentRect)
            }
            guard !rects.isEmpty else { return }

            let textHeight = font.ascender - font.descender
            let pillHeight = textHeight + self.paddingTop + self.paddingBottom

            for (index, fragmentRect) in rects.enumerated() {
                // The run's last glyph carries a trailing `.kern` margin (added
                // in `addInlineCodeMargins`) which inflates the enclosing rect.
                // Trim it off the final fragment so the gap stays *outside* the
                // pill rather than padding its interior.
                var width = fragmentRect.width
                if index == rects.count - 1 {
                    width -= inlineCodeMarginKern
                }

                // Center a font-metrics-sized pill on the glyph rect so the text
                // is evenly inset top and bottom regardless of line spacing.
                let midY = fragmentRect.midY
                var rect = CGRect(x: fragmentRect.minX - self.horizontalPadding,
                                  y: midY - pillHeight / 2,
                                  width: width + self.horizontalPadding * 2,
                                  height: pillHeight)
                rect.origin.x += origin.x
                rect.origin.y += origin.y

                let path = NSBezierPath(roundedRect: rect,
                                        xRadius: self.cornerRadius,
                                        yRadius: self.cornerRadius)
                fill.setFill()
                path.fill()
                stroke.setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        }
    }
}


/// Custom attribute marking an inline code span. `InlineCodeLayoutManager`
/// paints a rounded, padded background behind runs carrying this attribute,
/// instead of relying on `.backgroundColor` (which TextKit draws as a tight,
/// square box with no padding).
let inlineCodeKey = NSAttributedString.Key("helm.inlineCode")

/// Visual padding painted on each side of the glyphs inside an inline code pill.
let inlineCodePillPadding: CGFloat = 5.0
/// Real layout space reserved on each side of an inline code run (via `.kern`)
/// so the pill keeps a margin from neighbouring characters. Must exceed
/// `inlineCodePillPadding` for a visible gap to remain after the pill is drawn.
let inlineCodeMarginKern: CGFloat = 9.0

/// Styles text for the AppKit-backed selectable text views.
private enum ChatTextStyler {
    static let baseFont = NSFont.systemFont(ofSize: 15)
    static let monoFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private static let bodyLineSpacing: CGFloat = 5.2
    private static let bodyParagraphSpacing: CGFloat = 8.0

    // MARK: - Plain text

    static func plainTextAttributedString(_ text: String) -> NSAttributedString {
        let displayText = trimTrailingWhitespaceAndNewlines(text)
        let para = NSMutableParagraphStyle()
        para.lineSpacing = bodyLineSpacing
        para.paragraphSpacing = bodyParagraphSpacing
        para.lineBreakMode = .byWordWrapping
        let attributed = NSMutableAttributedString(string: displayText, attributes: [
            .font: baseFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: para
        ])
        removeTrailingParagraphSpacing(in: attributed)
        return attributed
    }

    // MARK: - Markdown

    /// Converts Markdown into a rich `NSAttributedString` that matches Helm's
    /// chat visual style. Uses MarkdownUI's public `renderHTML()` as the
    /// parser/HTML generator (no private API usage), then normalises the
    /// AppKit HTML-importer output to line up with our design system.
    static func markdownAttributedString(_ markdown: String) -> NSAttributedString {
        let html = renderedHTML(from: markdown)
        guard !html.isEmpty, let data = html.data(using: .utf8) else {
            return plainTextAttributedString(markdown)
        }

        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]

        guard let loaded = try? NSMutableAttributedString(data: data, options: options, documentAttributes: nil) else {
            return plainTextAttributedString(markdown)
        }

        normaliseMarkdownOutput(loaded)
        trimTrailingWhitespaceAndNewlines(in: loaded)
        removeTrailingParagraphSpacing(in: loaded)
        return loaded
    }

    private static func renderedHTML(from markdown: String) -> String {
        // Use MarkdownUI's public HTML renderer — gives us GFM support
        // (tables, task lists, strikethrough, autolinks) without pulling in
        // a separate parser. We wrap the fragment in a full HTML document
        // with a base stylesheet so the AppKit HTML importer has a
        // well-defined starting point.
        let content = MarkdownContent(markdown)
        let html = content.renderHTML()
        guard !html.isEmpty else { return "" }

        // Colour palette — these are placeholder sRGB values that the
        // normalisation pass later maps to dynamic NSColor values. We use
        // distinct sentinel values so the normaliser can reliably detect
        // what each colour was intended for.
        //
        //   #000001 → primary text   → .labelColor
        //   #666666 → secondary text → .secondaryLabelColor
        //   #1f1f1f → code background (light) / code fill
        //   #999999 → border / rule
        //   #ff00ff → accent (link) placeholder, replaced with accentColor

        let style = """
        body { font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; \
        font-size: 15px; color: #000001; line-height: 1.45; } \
        p { margin: 0 0 11px; line-height: 1.45; } \
        pre, code, kbd, samp { font-family: "SF Mono", Menlo, Consolas, monospace; \
        font-size: 13px; background: transparent; padding: 0; \
        border-radius: 0; color: #000001; } \
        pre { padding: 10px 14px; border-radius: 6px; overflow-x: auto; \
        background: rgba(31,31,31,0.05) !important; margin: 6px 0 14px; \
        line-height: 1.45; } \
        pre code { background: transparent; padding: 0; font-size: 13px; \
        line-height: 1.45; border-radius: 0; } \
        h1 { font-size: 20px; font-weight: 600; margin: 22px 0 10px; line-height: 1.3; color: #000001; } \
        h2 { font-size: 18px; font-weight: 600; margin: 20px 0 9px; line-height: 1.3; color: #000001; } \
        h3 { font-size: 16.5px; font-weight: 600; margin: 18px 0 8px; line-height: 1.3; color: #000001; } \
        h4 { font-size: 15px; font-weight: 600; margin: 16px 0 7px; color: #000001; } \
        h5 { font-size: 14px; font-weight: 600; margin: 14px 0 6px; color: #000001; } \
        h6 { font-size: 13.5px; font-weight: 600; margin: 14px 0 6px; color: #666666; } \
        body > h1:first-child, body > h2:first-child, body > h3:first-child, \
        body > h4:first-child, body > h5:first-child, body > h6:first-child { margin-top: 0; } \
        blockquote { margin: 6px 0 14px; padding: 2px 0 2px 10px; \
        border-left: 3px solid #999999; color: #666666; } \
        blockquote p { color: #666666; margin-bottom: 8px; } \
        blockquote p:last-child { margin-bottom: 0; } \
        ul, ol { margin: 4px 0 12px; padding-left: 22px; } \
        li { margin: 3px 0; } \
        li > p { margin: 3px 0; } \
        ul li { list-style-type: disc; } \
        ol li { list-style-type: decimal; } \
        ul ul, ol ul, ul ol, ol ol { margin: 3px 0 4px; } \
        table { border-collapse: collapse; margin: 6px 0 14px; font-size: 14px; } \
        th, td { border: 1px solid #999999; padding: 6px 10px; text-align: left; \
        vertical-align: top; color: #000001; } \
        th { background: rgba(153,153,153,0.12); font-weight: 600; } \
        hr { border: none; border-top: 1px solid #999999; margin: 10px 0; } \
        a { color: #ff00ff; text-decoration: none; } \
        input[type="checkbox"] { transform: scale(0.85); margin-right: 4px; }
        """

        return "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><style>\(style)</style></head><body>\(html)</body></html>"
    }

    /// Walk every attribute run and make fonts / colours consistent with
    /// Helm's chat appearance. The AppKit HTML importer picks arbitrary
    /// defaults, so we explicitly clamp sizes, swap in system fonts, and
    /// honour the current effective appearance via dynamic `NSColor`s.
    private static func normaliseMarkdownOutput(_ astr: NSMutableAttributedString) {
        let full = NSRange(location: 0, length: astr.length)
        astr.enumerateAttributes(in: full, options: []) { attrs, range, _ in
            var updated = attrs
            var changed = false

            // MARK: Font

            let currentFont = updated[.font] as? NSFont
            let isMono: Bool = {
                guard let f = currentFont else { return false }
                return f.fontDescriptor.symbolicTraits.contains(.monoSpace)
                    || f.familyName?.lowercased().contains("mono") ?? false
            }()

            if let currentFont {
                var traits = currentFont.fontDescriptor.symbolicTraits
                traits.remove(.monoSpace)
                var size = currentFont.pointSize

                let base: NSFont = isMono ? monoFont : baseFont

                // Clamp size to a sensible range, then nudge headings up
                // and body text down to match our design scale.
                if size < 10 { size = 11 }
                if size > 28 { size = 28 }

                let targetSize: CGFloat = {
                    if isMono {
                        // Inline code gets a slightly smaller size for visual
                        // balance with surrounding body text. Code blocks
                        // keep their full size.
                        return isWithinCodeBlock(range, in: astr)
                            ? monoFont.pointSize
                            : round(baseFont.pointSize * 0.88)
                    }
                    if size > baseFont.pointSize + 1 {
                        // Heuristic: a size noticeably above base is a heading.
                        // Scale it relative to our base.
                        let ratio = size / 16.0 // HTML importer tends to assume 16px base
                        return baseFont.pointSize * ratio
                    }
                    return baseFont.pointSize
                }()

                var newFont: NSFont
                if traits.contains(.bold) && traits.contains(.italic) {
                    newFont = NSFontManager.shared.convert(
                        NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask),
                        toHaveTrait: .italicFontMask)
                } else if traits.contains(.bold) {
                    newFont = NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
                } else if traits.contains(.italic) {
                    newFont = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
                } else {
                    newFont = base
                }

                if abs(newFont.pointSize - targetSize) > 0.25,
                   let resized = NSFont(descriptor: newFont.fontDescriptor, size: targetSize) {
                    newFont = resized
                }

                if newFont != currentFont {
                    updated[.font] = newFont
                    changed = true
                }
            } else {
                updated[.font] = baseFont
                changed = true
            }

            // MARK: Inline code styling
            //
            // Fine-tune inline code runs directly on the attributed string
            // because CSS padding on inline elements doesn't render reliably
            // in TextKit.
            if isMono, !isWithinCodeBlock(range, in: astr) {
                // Mark the run so `InlineCodeLayoutManager` can paint a
                // rounded, padded "pill" behind it. We deliberately avoid
                // `.backgroundColor`: TextKit draws that as a tight,
                // square-cornered rectangle hugging the glyphs, which is what
                // made inline code look like flat grey boxes.
                if updated[.backgroundColor] != nil {
                    updated[.backgroundColor] = nil
                    changed = true
                }
                if updated[inlineCodeKey] == nil {
                    updated[inlineCodeKey] = true
                    changed = true
                }
                // Nudge baseline down a hair so monospace text sits at the
                // same visual baseline as surrounding body text.
                let baselineOffset: CGFloat = -0.5
                if (updated[.baselineOffset] as? CGFloat) != baselineOffset {
                    updated[.baselineOffset] = baselineOffset
                    changed = true
                }
            }

            // MARK: Colour

            let existingColor = updated[.foregroundColor] as? NSColor

            // Links: replace magenta sentinel with accent colour
            if updated[.link] != nil {
                let accent = NSColor.controlAccentColor
                let underline = NSNumber(value: NSUnderlineStyle.single.rawValue)
                if existingColor != accent
                    || (updated[.underlineStyle] as? NSNumber) != underline {
                    updated[.foregroundColor] = accent
                    updated[.underlineStyle] = underline
                    changed = true
                }
            } else {
                // Map HTML-injected absolute colours to the adaptive label
                // colour family. We use sentinel values from our stylesheet:
                //   #000001 → primary text (.labelColor)
                //   #666666 → secondary text (.secondaryLabelColor)
                //   anything else bright-ish → primary
                //   anything else dim-ish → secondary
                let target: NSColor
                if let c = existingColor,
                   let rgb = c.usingColorSpace(.sRGB) {
                    let r = rgb.redComponent, g = rgb.greenComponent, b = rgb.blueComponent
                    // #ff00ff magenta check shouldn't reach here (handled above),
                    // but guard anyway.
                    if r > 0.95 && g < 0.05 && b > 0.95 {
                        target = .controlAccentColor
                    } else if r < 0.005 && g < 0.005 && b > 0.003 && b < 0.008 {
                        // near-black with a tiny blue tint → our #000001 sentinel
                        target = .labelColor
                    } else if abs(r - 0.4) < 0.05 && abs(g - 0.4) < 0.05 && abs(b - 0.4) < 0.05 {
                        // ~#666666 → secondary text
                        target = .secondaryLabelColor
                    } else if rgb.brightnessComponent < 0.5 {
                        target = .labelColor
                    } else {
                        target = .secondaryLabelColor
                    }
                } else {
                    target = .labelColor
                }

                if existingColor != target {
                    updated[.foregroundColor] = target
                    changed = true
                }
            }

            // MARK: Paragraph style — line height

            if let para = (updated[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle {
                let targetLineHeight = baseFont.pointSize * 1.42
                if para.minimumLineHeight < targetLineHeight * 0.9 {
                    para.minimumLineHeight = targetLineHeight
                    para.maximumLineHeight = targetLineHeight
                    updated[.paragraphStyle] = para
                    changed = true
                }
            }

            if changed {
                astr.setAttributes(updated, range: range)
            }
        }

        // Second pass: walk by paragraph and tune spacing by block type.
        // We do this in a separate pass because paragraph spacing applies
        // to whole paragraphs, not individual attribute runs.
        tuneParagraphSpacing(astr)

        // Strip inline-code marking that leaked onto list-item markers before we
        // reserve margins around the (now correct) runs.
        stripListMarkersFromInlineCode(astr)

        // Third pass: reserve horizontal layout space around inline code runs
        // so the drawn pill keeps a margin from neighbouring characters.
        addInlineCodeMargins(astr)
    }

    /// Removes `inlineCodeKey` (and its baseline nudge) from any list-item
    /// marker that leaked into an inline code run.
    ///
    /// When a list item begins with inline code (`- \`foo\``), AppKit's HTML
    /// importer renders the bullet/number marker into the *same* monospace
    /// attribute run as the code that follows it, so the marker inherits
    /// `inlineCodeKey` and gets swallowed by the pill. The importer always
    /// formats a list marker as `<marker>\t` (a tab terminates it), so we strip
    /// the attribute from everything up to and including the last tab at the
    /// start of a list paragraph.
    private static func stripListMarkersFromInlineCode(_ astr: NSMutableAttributedString) {
        let string = astr.string as NSString
        let full = NSRange(location: 0, length: astr.length)
        var location = 0
        while location < full.length {
            let paraRange = string.paragraphRange(for: NSRange(location: location, length: 0))
            defer { location = NSMaxRange(paraRange) }
            guard paraRange.length > 0 else { continue }

            // Only touch paragraphs the importer marked as list items.
            let style = astr.attribute(.paragraphStyle, at: paraRange.location,
                                       effectiveRange: nil) as? NSParagraphStyle
            guard let style, !style.textLists.isEmpty else { continue }

            // Find the last tab within the leading marker region. The marker is
            // `<tab?><bullet|number><tab>`, so the real content starts right
            // after that tab.
            let paraString = string.substring(with: paraRange) as NSString
            let markerScan = NSRange(location: 0, length: min(paraString.length, 8))
            let tabRange = paraString.rangeOfCharacter(from: CharacterSet(charactersIn: "\t"),
                                                       options: .backwards, range: markerScan)
            guard tabRange.location != NSNotFound else { continue }

            let stripRange = NSRange(location: paraRange.location,
                                     length: tabRange.location + 1)
            astr.removeAttribute(inlineCodeKey, range: stripRange)
            astr.removeAttribute(.baselineOffset, range: stripRange)
        }
    }

    /// Adds `.kern` on the boundaries of each inline code run so its pill does
    /// not visually touch the surrounding text. Kern on a glyph adds space
    /// *after* it, so we kern the run's last character (trailing gap) and the
    /// character immediately preceding the run (leading gap).
    private static func addInlineCodeMargins(_ astr: NSMutableAttributedString) {
        let full = NSRange(location: 0, length: astr.length)
        astr.enumerateAttribute(inlineCodeKey, in: full, options: []) { value, runRange, _ in
            guard (value as? Bool) == true, runRange.length > 0 else { return }

            // Trailing gap: kern the last glyph of the run.
            let lastIndex = NSMaxRange(runRange) - 1
            astr.addAttribute(.kern, value: inlineCodeMarginKern,
                              range: NSRange(location: lastIndex, length: 1))

            // Leading gap: kern the character just before the run, if any, and
            // only when it isn't itself inline code (avoid double-spacing two
            // adjacent runs — the trailing kern of the first already separates
            // them).
            let before = runRange.location - 1
            if before >= 0 {
                let precededByCode = (astr.attribute(inlineCodeKey, at: before,
                                                     effectiveRange: nil) as? Bool) == true
                if !precededByCode {
                    astr.addAttribute(.kern, value: inlineCodeMarginKern,
                                      range: NSRange(location: before, length: 1))
                }
            }
        }
    }

    /// Detects the logical type of each paragraph (heading / body / list /
    /// code / blockquote) and applies precise spacing values. More reliable
    /// than trying to control spacing via CSS, which the AppKit HTML
    /// importer only partially honours.
    private static func tuneParagraphSpacing(_ astr: NSMutableAttributedString) {
        let fullRange = NSRange(location: 0, length: astr.length)
        let string = astr.string as NSString

        var paraIdx = 0
        var location = 0
        while location < fullRange.length {
            let paraRange = string.paragraphRange(for: NSRange(location: location, length: 0))
            defer { location = NSMaxRange(paraRange) }
            paraIdx += 1

            // Skip empty / whitespace-only trailing paragraphs
            let paraText = string.substring(with: paraRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !paraText.isEmpty else { continue }

            // Sample the dominant font / colour at the paragraph start
            var sampleRange = NSRange(location: 0, length: 0)
            let sampleAttrs = astr.attributes(at: paraRange.location,
                                               longestEffectiveRange: &sampleRange,
                                               in: paraRange)

            let font = sampleAttrs[.font] as? NSFont ?? baseFont
            let isMono = font.fontDescriptor.symbolicTraits.contains(.monoSpace)
                || font.familyName?.lowercased().contains("mono") ?? false
            let isBold = font.fontDescriptor.symbolicTraits.contains(.bold)
            let size = font.pointSize
            let color = sampleAttrs[.foregroundColor] as? NSColor
            let isSecondary = (color?.usingColorSpace(.sRGB)?.brightnessComponent ?? 0) > 0.45
            let para = (sampleAttrs[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy()
                as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()

            let isFirstParagraph = paraIdx == 1
            let hasIndent = para.headIndent > 0 || para.firstLineHeadIndent > 0

            // Classify
            //
            // Important: indented paragraphs (list items, blockquotes) are
            // NEVER treated as headings, even if they contain bold text.
            // Bold within a list item is just an emphasis marker, not a
            // section heading — it should be tight to the content below it.
            let kind: ParagraphKind
            if isMono {
                kind = .code
            } else if hasIndent {
                if isSecondary {
                    kind = .blockquote
                } else {
                    kind = .listItem
                }
            } else if isBold && size >= baseFont.pointSize + 0.5 {
                // Heading — only applies to non-indented bold text
                if size >= 19.5 { kind = .h1 }
                else if size >= 17.5 { kind = .h2 }
                else if size >= 16 { kind = .h3 }
                else if size >= 14.8 { kind = .h4 }
                else if size >= 13.8 { kind = .h5 }
                else { kind = .h6 }
            } else {
                kind = .body
            }

            // Apply spacing

            let (top, bottom) = kind.spacing(isFirst: isFirstParagraph)
            para.paragraphSpacing = bottom
            if !isFirstParagraph {
                para.paragraphSpacingBefore = top
            }

            astr.addAttribute(.paragraphStyle, value: para, range: paraRange)
        }
    }

    private enum ParagraphKind {
        case h1, h2, h3, h4, h5, h6
        case body
        case listItem
        case code
        case blockquote

        /// (top spacing, bottom spacing) in points. First paragraph of a
        /// text block has zero top spacing so the message bubble doesn't
        /// have dead air at the top.
        func spacing(isFirst: Bool) -> (top: CGFloat, bottom: CGFloat) {
            switch self {
            case .h1: return (isFirst ? 0 : 22, 10)
            case .h2: return (isFirst ? 0 : 20, 9)
            case .h3: return (isFirst ? 0 : 18, 8)
            case .h4: return (isFirst ? 0 : 16, 7)
            case .h5: return (isFirst ? 0 : 14, 6)
            case .h6: return (isFirst ? 0 : 14, 6)
            case .body: return (isFirst ? 0 : 0, 11)
            case .listItem: return (isFirst ? 0 : 6, 3)
            case .code: return (isFirst ? 0 : 8, 14)
            case .blockquote: return (isFirst ? 0 : 8, 12)
            }
        }
    }

    // MARK: - Helpers

    /// Returns true if the given range falls entirely within a code block
    /// (a paragraph where every character is monospace). Inline code spans
    /// within a body paragraph return false.
    private static func isWithinCodeBlock(_ range: NSRange, in astr: NSAttributedString) -> Bool {
        let string = astr.string as NSString
        let paraRange = string.paragraphRange(for: range)
        var isAllMono = true
        astr.enumerateAttribute(.font, in: paraRange, options: []) { value, _, stop in
            guard let font = value as? NSFont else { return }
            let isMono = font.fontDescriptor.symbolicTraits.contains(.monoSpace)
                || font.familyName?.lowercased().contains("mono") ?? false
            if !isMono {
                isAllMono = false
                stop.pointee = true
            }
        }
        return isAllMono
    }

    private static func trimTrailingWhitespaceAndNewlines(_ text: String) -> String {
        var output = text
        while let scalar = output.unicodeScalars.last,
              CharacterSet.whitespacesAndNewlines.contains(scalar) {
            output.removeLast()
        }
        return output
    }

    private static func trimTrailingWhitespaceAndNewlines(in attributed: NSMutableAttributedString) {
        while attributed.length > 0 {
            let tailRange = NSRange(location: attributed.length - 1, length: 1)
            let tail = attributed.attributedSubstring(from: tailRange).string
            guard let scalar = tail.unicodeScalars.first,
                  CharacterSet.whitespacesAndNewlines.contains(scalar)
            else { break }
            attributed.deleteCharacters(in: tailRange)
        }
    }

    private static func removeTrailingParagraphSpacing(in attributed: NSMutableAttributedString) {
        guard attributed.length > 0 else { return }
        let lastLocation = attributed.length - 1
        let fullRange = NSRange(location: 0, length: attributed.length)
        let paragraphRange = (attributed.string as NSString)
            .paragraphRange(for: NSRange(location: lastLocation, length: 1))
        let constrainedRange = NSIntersectionRange(paragraphRange, fullRange)
        guard constrainedRange.length > 0 else { return }

        var updates: [(NSRange, NSParagraphStyle)] = []
        attributed.enumerateAttribute(.paragraphStyle, in: constrainedRange, options: []) { value, range, _ in
            guard let paragraph = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
            else { return }
            paragraph.paragraphSpacing = 0
            updates.append((range, paragraph))
        }
        for (range, paragraph) in updates {
            attributed.addAttribute(.paragraphStyle, value: paragraph, range: range)
        }
    }
}

private enum MarkdownDisplaySanitizer {
    private struct BacktickRun {
        let range: Range<String.Index>
        let length: Int
    }

    static func sanitize(_ raw: String) -> String {
        guard raw.contains("`") || raw.contains("**") else { return raw }

        var output = ""
        var cursor = raw.startIndex
        var activeFence: Character?

        while cursor < raw.endIndex {
            let lineEnd = raw[cursor...].firstIndex(of: "\n") ?? raw.endIndex
            let line = String(raw[cursor..<lineEnd])
            let newline = lineEnd < raw.endIndex ? "\n" : ""

            if let fence = fenceMarker(in: line) {
                output += line + newline
                activeFence = activeFence == nil ? fence : (activeFence == fence ? nil : activeFence)
            } else if activeFence != nil {
                output += line + newline
            } else {
                output += sanitizeInlineMarkdown(in: line) + newline
            }

            cursor = lineEnd
            if cursor < raw.endIndex {
                cursor = raw.index(after: cursor)
            }
        }

        return output
    }

    private static func sanitizeInlineMarkdown(in line: String) -> String {
        closeUnmatchedStrongMarkers(in: repairUnmatchedInlineBackticks(in: line))
    }

    private static func repairUnmatchedInlineBackticks(in line: String) -> String {
        let runs = backtickRuns(in: line)
        let unmatched = unmatchedBacktickRunIndexes(runs)
        guard !unmatched.isEmpty else { return line }

        var output = ""
        var cursor = line.startIndex

        for index in runs.indices where unmatched.contains(index) {
            let run = runs[index]
            guard cursor <= run.range.lowerBound else { continue }

            output += line[cursor..<run.range.lowerBound]

            let tokenEnd = inlineCodeTokenEnd(after: run.range.upperBound, in: line)
            if tokenEnd > run.range.upperBound {
                output += line[run.range.lowerBound..<tokenEnd]
                output += String(repeating: "`", count: run.length)
                cursor = tokenEnd
            } else {
                output += String(repeating: "\\`", count: run.length)
                cursor = run.range.upperBound
            }
        }

        output += line[cursor..<line.endIndex]
        return output
    }

    private static func closeUnmatchedStrongMarkers(in line: String) -> String {
        guard line.contains("**") else { return line }

        let codeRanges = inlineCodeRanges(in: line)
        var markerCount = 0
        var cursor = line.startIndex

        while cursor < line.endIndex {
            if let range = codeRanges.first(where: { $0.contains(cursor) }) {
                cursor = range.upperBound
                continue
            }

            let next = line.index(after: cursor)
            if line[cursor] == "*",
               next < line.endIndex,
               line[next] == "*",
               !isEscaped(cursor, in: line) {
                markerCount += 1
                cursor = line.index(after: next)
            } else {
                cursor = next
            }
        }

        return markerCount.isMultiple(of: 2) ? line : line + "**"
    }

    private static func backtickRuns(in line: String) -> [BacktickRun] {
        var runs: [BacktickRun] = []
        var cursor = line.startIndex

        while cursor < line.endIndex {
            guard line[cursor] == "`", !isEscaped(cursor, in: line) else {
                cursor = line.index(after: cursor)
                continue
            }

            let start = cursor
            var length = 0
            while cursor < line.endIndex, line[cursor] == "`" {
                length += 1
                cursor = line.index(after: cursor)
            }

            if length < 3 {
                runs.append(BacktickRun(range: start..<cursor, length: length))
            }
        }

        return runs
    }

    private static func unmatchedBacktickRunIndexes(_ runs: [BacktickRun]) -> Set<Int> {
        var paired: Set<Int> = []

        for index in runs.indices where !paired.contains(index) {
            guard let closingIndex = runs.indices.dropFirst(index + 1).first(where: {
                !paired.contains($0) && runs[$0].length == runs[index].length
            }) else {
                continue
            }
            paired.insert(index)
            paired.insert(closingIndex)
        }

        return Set(runs.indices).subtracting(paired)
    }

    private static func inlineCodeRanges(in line: String) -> [Range<String.Index>] {
        let runs = backtickRuns(in: line)
        var ranges: [Range<String.Index>] = []
        var paired: Set<Int> = []

        for index in runs.indices where !paired.contains(index) {
            guard let closingIndex = runs.indices.dropFirst(index + 1).first(where: {
                !paired.contains($0) && runs[$0].length == runs[index].length
            }) else {
                continue
            }
            paired.insert(index)
            paired.insert(closingIndex)
            ranges.append(runs[index].range.lowerBound..<runs[closingIndex].range.upperBound)
        }

        return ranges
    }

    private static func inlineCodeTokenEnd(after start: String.Index, in line: String) -> String.Index {
        var cursor = start
        while cursor < line.endIndex,
              line[cursor] != "`",
              !isInlineCodeTokenTerminator(line[cursor]) {
            cursor = line.index(after: cursor)
        }
        return cursor
    }

    private static func isInlineCodeTokenTerminator(_ character: Character) -> Bool {
        character.isWhitespace || ",;!?)]}>\"'|*，。；！？）】》、".contains(character)
    }

    private static func fenceMarker(in line: String) -> Character? {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        if trimmed.hasPrefix("```") {
            return "`"
        }
        if trimmed.hasPrefix("~~~") {
            return "~"
        }
        return nil
    }

    private static func isEscaped(_ index: String.Index, in line: String) -> Bool {
        var cursor = index
        var slashCount = 0

        while cursor > line.startIndex {
            let previous = line.index(before: cursor)
            guard line[previous] == "\\" else { break }
            slashCount += 1
            cursor = previous
        }

        return !slashCount.isMultiple(of: 2)
    }
}
