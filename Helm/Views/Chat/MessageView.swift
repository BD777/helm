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
            LazyVStack(alignment: .leading, spacing: 0) {
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
        .id(scrollContentIdentity)
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
        .onChange(of: scrollContentIdentity) { _, _ in
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

    private var scrollContentIdentity: String {
        let sessionID = store.selectedSessionId?.uuidString ?? "none"
        let loadPhase = showHistoryLoading ? "loading" : "ready"
        return "\(sessionID)-\(loadPhase)"
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
    private var followsBottom = true
    private var isProgrammaticScroll = false
    private var isLiveUserScroll = false
    private var scheduledScrollID = 0
    private var userScrollResumeID = 0

    private let jumpButtonTolerance: CGFloat = 96
    private let followResumeTolerance: CGFloat = 18
    private let animatedDuration: TimeInterval = 0.18
    private let maxScrollPasses = 8

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
                    self?.suspendBottomFollow()
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
                    self?.userDidScroll()
                }
            })
            scrollObservers.append(center.addObserver(
                forName: NSScrollView.didEndLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isLiveUserScroll = false
                    self?.updateFollowPreference(resumeTolerance: self?.followResumeTolerance ?? 0)
                }
            })
            followsBottom = true
        }

        observeDocumentView(scrollView.documentView)
        refreshJumpButton()
        if followsBottom {
            scheduleScrollToBottom(animated: false, force: false)
        }
    }

    func followIfNeeded() {
        guard followsBottom else { return }
        scheduleScrollToBottom(animated: false, force: false)
    }

    func prepareForSessionChange() {
        scheduledScrollID += 1
        followsBottom = true
        setShowJumpToBottom(false)
    }

    func forceScrollToBottom(animated: Bool) {
        followsBottom = true
        scheduleScrollToBottom(animated: animated, force: true)
    }

    private func visibleBoundsDidChange() {
        guard !isProgrammaticScroll, let scrollView else { return }
        if clampVisibleBoundsIfNeeded(in: scrollView) {
            updateFollowPreference(resumeTolerance: followResumeTolerance)
            return
        }
        if isLiveUserScroll || currentEventLooksLikeUserScroll(in: scrollView) {
            userDidScroll()
        } else if distanceFromBottom(in: scrollView) <= followResumeTolerance {
            followsBottom = true
            setShowJumpToBottom(false)
        }
    }

    private func documentFrameDidChange() {
        guard let scrollView else { return }
        if clampVisibleBoundsIfNeeded(in: scrollView) {
            followsBottom = distanceFromBottom(in: scrollView) <= jumpButtonTolerance
        }
        refreshJumpButton()
        guard followsBottom, !isLiveUserScroll else { return }
        scheduleScrollToBottom(animated: false, force: false)
    }

    private func suspendBottomFollow() {
        scheduledScrollID += 1
        followsBottom = false
    }

    private func userDidScroll() {
        suspendBottomFollow()
        refreshJumpButton()
        scheduleUserScrollResumeCheck()
    }

    private func scheduleUserScrollResumeCheck() {
        userScrollResumeID += 1
        let resumeID = userScrollResumeID
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(180)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self,
                      self.userScrollResumeID == resumeID,
                      !self.isLiveUserScroll,
                      !self.isProgrammaticScroll
                else { return }
                self.updateFollowPreference(resumeTolerance: self.followResumeTolerance)
            }
        }
    }

    private func updateFollowPreference(resumeTolerance: CGFloat) {
        guard let scrollView else { return }
        let distance = distanceFromBottom(in: scrollView)
        followsBottom = distance <= resumeTolerance
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

    private func scheduleScrollToBottom(animated: Bool, force: Bool) {
        scheduledScrollID += 1
        let scrollID = scheduledScrollID
        scheduleScrollPass(scrollID: scrollID, animated: animated, force: force, pass: 0)
    }

    private func scheduleScrollPass(scrollID: Int,
                                    animated: Bool,
                                    force: Bool,
                                    pass: Int) {
        let delay = scrollDelay(forPass: pass)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self,
                      self.scheduledScrollID == scrollID,
                      force || self.followsBottom
                else { return }
                self.scrollToBottom(animated: animated && pass == 0)
                if pass + 1 < self.maxScrollPasses {
                    self.scheduleScrollPass(scrollID: scrollID,
                                            animated: false,
                                            force: force,
                                            pass: pass + 1)
                }
            }
        }
    }

    private func scrollDelay(forPass pass: Int) -> DispatchTimeInterval {
        switch pass {
        case 0: return .nanoseconds(0)
        case 1: return .milliseconds(16)
        case 2: return .milliseconds(33)
        case 3: return .milliseconds(66)
        case 4: return .milliseconds(120)
        case 5: return .milliseconds(200)
        case 6: return .milliseconds(320)
        default: return .milliseconds(500)
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
            followsBottom = true
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

    @discardableResult
    private func clampVisibleBoundsIfNeeded(in scrollView: NSScrollView) -> Bool {
        guard let documentView = scrollView.documentView else { return false }

        scrollView.layoutSubtreeIfNeeded()
        documentView.layoutSubtreeIfNeeded()

        let clipView = scrollView.contentView
        let constrainedOrigin = clipView
            .constrainBoundsRect(clipView.bounds)
            .origin
        let currentOrigin = clipView.bounds.origin
        guard abs(currentOrigin.x - constrainedOrigin.x) > 0.5
            || abs(currentOrigin.y - constrainedOrigin.y) > 0.5
        else { return false }

        isProgrammaticScroll = true
        clipView.scroll(to: constrainedOrigin)
        scrollView.reflectScrolledClipView(clipView)
        isProgrammaticScroll = false
        return true
    }

    private func finishProgrammaticScroll() {
        followsBottom = true
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
            .padding(.vertical, isUser ? 8 : 0)
            .background(
                isUser
                ? RoundedRectangle(cornerRadius: DS.cornerRadius)
                    .fill(Color.accentColor.opacity(0.08))
                : nil
            )

            if canCopyMarkdown {
                HStack(spacing: 6) {
                    if !isUser {
                        CopyMarkdownButton(markdown: markdownForCopy)
                            .opacity(isHovering ? 1 : 0)
                            .allowsHitTesting(isHovering)
                    }
                    if isHovering, let timestamp = displayTimestamp {
                        Text(timestamp)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if isUser {
                        if isHovering, let timestamp = displayTimestamp {
                            Text(timestamp)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        CopyMarkdownButton(markdown: markdownForCopy)
                            .opacity(isHovering ? 1 : 0)
                            .allowsHitTesting(isHovering)
                    }
                }
                .frame(height: 20)
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
                .frame(width: 24, height: 20)
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
                withAnimation(.easeOut(duration: 0.18)) {
                    userPreference = !collapsed
                }
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
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
    }
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

/// Full block-level Markdown renderer for chat content.
///
/// Uses a single AppKit `NSTextView` (via `NSAttributedString` built from the
/// Markdown source) so drag selection works across wrapped lines, paragraphs,
/// list items and headings. SwiftUI's `.textSelection(.enabled)` only works
/// within a single `Text` view, which is why MarkdownUI-backed rendering kept
/// selection stuck inside one logical block.
struct MarkdownishText: View {
    let raw: String

    init(_ raw: String) { self.raw = raw }

    var body: some View {
        SelectableMarkdownTextView(markdown: MarkdownDisplaySanitizer.sanitize(raw))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Plain (non-markdown) streaming text rendered inside a single selectable
/// AppKit text view so multi-line drag selection works correctly.
private struct PlainStreamingText: View {
    let raw: String

    init(_ raw: String) { self.raw = raw }

    var body: some View {
        SelectableMarkdownTextView(markdown: raw, treatAsPlainText: true)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// AppKit-backed text view that renders Markdown (or plain text) with full
/// continuous multi-line / cross-paragraph selection support.
private struct SelectableMarkdownTextView: NSViewRepresentable {
    let markdown: String
    var treatAsPlainText: Bool = false

    func makeNSView(context: Context) -> NSTextView {
        let tv = NonEditableTextView()
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
        tv.linkTextAttributes = [
            .foregroundColor: NSColor.controlAccentColor,
            .underlineStyle: NSNumber(value: NSUnderlineStyle.single.rawValue)
        ]
        tv.importsGraphics = true
        updateContent(in: tv)
        return tv
    }

    func updateNSView(_ nsView: NSTextView, context: Context) {
        updateContent(in: nsView)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        guard let lm = nsView.layoutManager, let tc = nsView.textContainer else { return nil }
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
        let minHeight = lm.defaultLineHeight(for: ChatTextStyler.baseFont)
        return CGSize(width: width, height: max(minHeight, ceil(used.height)))
    }

    private func updateContent(in tv: NSTextView) {
        let attributed: NSAttributedString = {
            if treatAsPlainText {
                return ChatTextStyler.plainTextAttributedString(markdown)
            }
            return ChatTextStyler.attributedString(fromMarkdown: markdown)
        }()
        tv.textStorage?.setAttributedString(attributed)
    }
}

/// An `NSTextView` subclass that forces an I-beam cursor over its entire
/// bounds and opens clicked links in the default browser instead of trying to
/// edit them inline.
private final class NonEditableTextView: NSTextView {
    override var isFlipped: Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .iBeam)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        let range = NSRange(location: 0, length: textStorage?.length ?? 0)
        var effectiveRange = NSRange(location: NSNotFound, length: 0)
        if let storage = textStorage,
           range.contains(index),
           let link = storage.attribute(.link, at: index, longestEffectiveRange: &effectiveRange, in: range) {
            if let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) {
                NSWorkspace.shared.open(url)
                return
            }
        }
        super.mouseDown(with: event)
    }
}

/// Converts Markdown (and plain text) into rich `NSAttributedString` values
/// that match Helm's chat visual style. The pipeline uses cmark-gfm (via
/// MarkdownUI) for HTML generation and AppKit's HTML importer for the
/// initial styling pass, then normalises font sizes / colors to match the
/// rest of the chat surface.
private enum ChatTextStyler {
    static let baseFont = NSFont.systemFont(ofSize: 13.5)
    static let monoFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    static func plainTextAttributedString(_ text: String) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 0.18 * baseFont.pointSize
        para.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: text, attributes: [
            .font: baseFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: para
        ])
    }

    static func attributedString(fromMarkdown markdown: String) -> NSAttributedString {
        let html = renderedHTML(from: markdown)
        guard let data = html.data(using: .utf8) else {
            return plainTextAttributedString(markdown)
        }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        guard let loaded = try? NSMutableAttributedString(data: data, options: options, documentAttributes: nil) else {
            return plainTextAttributedString(markdown)
        }
        normalise(loaded)
        return loaded
    }

    // MARK: - Helpers

    private static func renderedHTML(from markdown: String) -> String {
        // MarkdownUI ships a cmark-gfm parser; going through HTML lets us
        // keep GFM support (tables, task lists, strikethrough, autolinks)
        // without pulling in a separate parser.
        let content = MarkdownContent(markdown)
        let html = content.renderHTML()
        if html.isEmpty { return "" }

        // Wrap the fragment in a full HTML document with a base style so the
        // AppKit HTML importer has a well-defined starting point. We still
        // run a normalisation pass afterwards to line up with Helm's metrics.
        let escapedBaseColor = "#000000" // colour is fixed up later; this is a placeholder
        let style = """
        body { font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; \
        font-size: 13.5px; color: \(escapedBaseColor); line-height: 1.45; } \
        pre, code, kbd, samp { font-family: "SF Mono", Menlo, Consolas, monospace; \
        font-size: 12px; background: rgba(127,127,127,0.12); padding: 0 0.25em; \
        border-radius: 3px; } \
        pre { padding: 10px 12px; border-radius: 6px; overflow-x: auto; } \
        pre code { background: transparent; padding: 0; } \
        h1 { font-size: 18px; font-weight: 600; margin: 12px 0 8px; } \
        h2 { font-size: 16px; font-weight: 600; margin: 12px 0 8px; } \
        h3 { font-size: 14.5px; font-weight: 600; margin: 10px 0 6px; } \
        h4 { font-size: 13.5px; font-weight: 600; margin: 8px 0 5px; } \
        blockquote { margin: 2px 0 8px; padding: 2px 0 2px 10px; \
        border-left: 3px solid rgba(0,0,0,0.25); color: rgba(0,0,0,0.55); } \
        p { margin: 0 0 8px; } \
        ul, ol { margin: 0 0 8px; padding-left: 22px; } \
        li { margin: 2px 0; } \
        table { border-collapse: collapse; margin: 2px 0 10px; } \
        th, td { border: 1px solid rgba(127,127,127,0.35); padding: 5px 10px; font-size: 13px; } \
        th { background: rgba(127,127,127,0.08); font-weight: 600; } \
        hr { border: none; border-top: 1px solid rgba(127,127,127,0.35); margin: 10px 0; }
        """
        return "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><style>\(style)</style></head><body>\(html)</body></html>"
    }

    /// Walk every run and make fonts / colours consistent with Helm's chat
    /// appearance. AppKit's HTML importer picks arbitrary defaults, so we
    /// explicitly clamp sizes, swap in system fonts and honour the current
    /// effective appearance via `NSColor.labelColor`/`.secondaryLabelColor`.
    private static func normalise(_ astr: NSMutableAttributedString) {
        let full = NSRange(location: 0, length: astr.length)
        astr.enumerateAttributes(in: full, options: []) { attrs, range, _ in
            var updated = attrs
            var changed = false

            // Font: keep monospaced runs as monospaced; everything else uses
            // the chat base font. Preserve bold / italic traits and clamp size
            // to a sensible range so headings stay readable.
            if let currentFont = updated[.font] as? NSFont {
                let isMono = currentFont.fontDescriptor.symbolicTraits.contains(.monoSpace)
                    || currentFont.familyName?.lowercased().contains("mono") ?? false
                var traits = currentFont.fontDescriptor.symbolicTraits
                traits.remove(.monoSpace) // trait doesn't combine cleanly with NSFont()
                var size = currentFont.pointSize
                if size < 10 { size = 11 }
                if size > 24 { size = 24 }
                // Heuristic: if HTML gave us a size noticeably larger than
                // base, it is probably a heading — preserve the bump.
                let headingScale: CGFloat = size > baseFont.pointSize + 0.5
                    ? size / 16.0 * 1.0
                    : 1.0
                let targetSize = max(baseFont.pointSize, min(size, baseFont.pointSize * headingScale + 4))

                let base: NSFont = isMono ? monoFont : baseFont
                var newFont: NSFont
                if traits.contains(.bold) && traits.contains(.italic) {
                    newFont = NSFontManager.shared.convert(
                        NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask),
                        toHaveTrait: .italicFontMask
                    )
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

            // Colour: links keep accent; everything else falls back to the
            // current effective foreground. We specifically do NOT use an
            // absolute `NSColor.black` so dark mode stays readable.
            if updated[.link] != nil {
                let accent = NSColor.controlAccentColor
                let underline = NSNumber(value: NSUnderlineStyle.single.rawValue)
                if updated[.foregroundColor] as? NSColor != accent
                    || (updated[.underlineStyle] as? NSNumber) != underline {
                    updated[.foregroundColor] = accent
                    updated[.underlineStyle] = underline
                    changed = true
                }
            } else {
                // Always map HTML-injected absolute colours to the adaptive
                // label colour family so dark mode stays readable. Blockquote
                // text from the HTML pipeline tends to render as a mid-gray;
                // detect those via brightness and promote to `.secondaryLabel`.
                let existingColor = updated[.foregroundColor] as? NSColor
                let brightness: CGFloat
                if let existing = existingColor {
                    if let rgb = existing.usingColorSpace(.sRGB) {
                        brightness = rgb.brightnessComponent
                    } else if let gray = existing.usingColorSpace(.genericGray) {
                        brightness = gray.whiteComponent
                    } else {
                        brightness = 0.5
                    }
                } else {
                    brightness = 0.0
                }
                let target: NSColor = brightness < 0.55
                    ? NSColor.labelColor
                    : NSColor.secondaryLabelColor
                if existingColor != target {
                    updated[.foregroundColor] = target
                    changed = true
                }
            }

            // Line height — bump leading slightly for readability, matching
            // the SwiftUI `.relativeLineSpacing(.em(0.18))` used previously.
            if let para = (updated[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle {
                let lineHeight = baseFont.pointSize * 1.18
                if para.minimumLineHeight < lineHeight * 0.9 {
                    para.minimumLineHeight = lineHeight
                    para.maximumLineHeight = lineHeight
                    updated[.paragraphStyle] = para
                    changed = true
                }
            }

            // Strikethrough / underline already set by the HTML importer —
            // keep them as long as the values aren't `nil` placeholders.

            if changed {
                astr.setAttributes(updated, range: range)
            }
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
