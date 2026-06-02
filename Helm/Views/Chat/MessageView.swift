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
            autoScroll.forceScrollToBottom(animated: true)
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
                HStack {
                    Spacer(minLength: 0)
                    CopyMarkdownButton(markdown: markdownForCopy)
                        .opacity(isHovering ? 1 : 0)
                        .allowsHitTesting(isHovering)
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
                calls: calls,
                turnStartedAt: turnStartedAt,
                isTurnRunning: isTurnRunning,
                turnTokenUsage: turnTokenUsage
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
        messages.lazy.compactMap(\.endedAt).first
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
        TimelineView(.periodic(from: Date(), by: 1)) { context in
            HStack(spacing: 6) {
                if isRunning {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.72)
                }
                Text(label(for: context.date))
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
struct MarkdownishText: View {
    let raw: String
    @Environment(\.colorScheme) private var colorScheme

    init(_ raw: String) { self.raw = raw }

    var body: some View {
        SelectableRichText(raw: raw,
                           renderMarkdown: true,
                           colorScheme: colorScheme)
    }
}

private struct PlainStreamingText: View {
    let raw: String
    @Environment(\.colorScheme) private var colorScheme

    init(_ raw: String) { self.raw = raw }

    var body: some View {
        SelectableRichText(raw: raw,
                           renderMarkdown: false,
                           colorScheme: colorScheme)
    }
}

private struct SelectableRichText: NSViewRepresentable {
    let raw: String
    let renderMarkdown: Bool
    let colorScheme: ColorScheme

    func makeNSView(context: Context) -> ChatTextView {
        let tv = ChatTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = true
        tv.allowsUndo = false
        tv.drawsBackground = false
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.linkTextAttributes = [
            .foregroundColor: NSColor.controlAccentColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        tv.textStorage?.setAttributedString(attributedText())
        return tv
    }

    func updateNSView(_ tv: ChatTextView, context: Context) {
        let signature = "\(renderMarkdown)-\(colorScheme)-\(raw.hashValue)"
        guard context.coordinator.signature != signature else { return }
        context.coordinator.signature = signature
        let selectedRange = tv.selectedRange()
        tv.textStorage?.setAttributedString(attributedText())
        tv.selectedRange = NSRange(location: min(selectedRange.location, tv.string.utf16.count),
                                   length: 0)
        tv.invalidateIntrinsicContentSize()
        tv.needsLayout = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ChatTextView, context: Context) -> CGSize? {
        guard let lm = nsView.layoutManager,
              let tc = nsView.textContainer
        else { return nil }
        let width: CGFloat = {
            if let w = proposal.width, w.isFinite, w > 0 { return w }
            if nsView.bounds.width > 0 { return nsView.bounds.width }
            return DS.messageMaxWidth
        }()
        if tc.size.width != width {
            tc.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc)
        let fallbackHeight = lm.defaultLineHeight(for: ChatMarkdownAttributedRenderer.baseFont)
        return CGSize(width: width, height: max(ceil(used.height), fallbackHeight))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    private func attributedText() -> NSAttributedString {
        if renderMarkdown {
            return ChatMarkdownAttributedRenderer.markdown(raw, colorScheme: colorScheme)
        }
        return ChatMarkdownAttributedRenderer.plain(raw, colorScheme: colorScheme)
    }

    final class Coordinator {
        var signature: String?
    }
}

private final class ChatTextView: NSTextView {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .iBeam)
    }
}

private enum ChatMarkdownAttributedRenderer {
    static let baseFont = NSFont.systemFont(ofSize: 13.5)

    static func plain(_ raw: String, colorScheme: ColorScheme) -> NSAttributedString {
        NSAttributedString(string: raw, attributes: [
            .font: baseFont,
            .foregroundColor: labelColor(for: colorScheme),
            .paragraphStyle: paragraphStyle,
        ])
    }

    static func markdown(_ raw: String, colorScheme: ColorScheme) -> NSAttributedString {
        let attributed: NSMutableAttributedString
        do {
            let parsed = try AttributedString(
                markdown: raw,
                options: .init(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace,
                    failurePolicy: .returnPartiallyParsedIfPossible
                )
            )
            attributed = NSMutableAttributedString(attributedString: NSAttributedString(parsed))
        } catch {
            attributed = NSMutableAttributedString(string: raw)
        }

        applyBaseStyle(to: attributed, colorScheme: colorScheme)
        applyHeadingStyle(to: attributed, colorScheme: colorScheme)
        applyInlineMarkdownStyle(to: attributed, colorScheme: colorScheme)
        return attributed
    }

    private static var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2.2
        style.paragraphSpacing = 6
        return style
    }

    private static func applyBaseStyle(to attributed: NSMutableAttributedString,
                                       colorScheme: ColorScheme) {
        guard attributed.length > 0 else { return }
        attributed.addAttributes([
            .font: baseFont,
            .foregroundColor: labelColor(for: colorScheme),
            .paragraphStyle: paragraphStyle,
        ], range: NSRange(location: 0, length: attributed.length))
    }

    private static func applyHeadingStyle(to attributed: NSMutableAttributedString,
                                          colorScheme: ColorScheme) {
        let value = attributed.string as NSString
        var lineRanges: [NSRange] = []
        value.enumerateSubstrings(
            in: NSRange(location: 0, length: value.length),
            options: [.byLines, .substringNotRequired]
        ) { _, range, _, _ in
            lineRanges.append(range)
        }

        for range in lineRanges.reversed() {
            guard range.length >= 3 else { continue }
            let line = value.substring(with: range)
            let hashes = line.prefix { $0 == "#" }.count
            guard (1...4).contains(hashes),
                  line.dropFirst(hashes).first == " "
            else { continue }

            attributed.deleteCharacters(in: NSRange(location: range.location, length: hashes + 1))
            let contentRange = NSRange(location: range.location,
                                       length: range.length - hashes - 1)
            guard contentRange.length > 0 else { continue }
            attributed.addAttributes([
                .font: headingFont(level: hashes),
                .foregroundColor: labelColor(for: colorScheme),
            ], range: contentRange)
        }
    }

    private static func applyInlineMarkdownStyle(to attributed: NSMutableAttributedString,
                                                 colorScheme: ColorScheme) {
        guard attributed.length > 0 else { return }

        attributed.enumerateAttribute(
            .inlinePresentationIntent,
            in: NSRange(location: 0, length: attributed.length)
        ) { value, range, _ in
            let rawValue = inlineIntentRawValue(value)
            guard rawValue != 0 else { return }

            let isEmphasized = rawValue & 1 != 0
            let isStrong = rawValue & 2 != 0
            let isCode = rawValue & 4 != 0
            let isStrikethrough = rawValue & 32 != 0

            if isCode {
                attributed.addAttributes([
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                    .backgroundColor: codeBackground(for: colorScheme),
                    .foregroundColor: labelColor(for: colorScheme),
                ], range: range)
            } else if isStrong || isEmphasized {
                attributed.addAttribute(.font,
                                        value: inlineFont(strong: isStrong,
                                                          emphasized: isEmphasized),
                                        range: range)
            }
            if isStrikethrough {
                attributed.addAttribute(.strikethroughStyle,
                                        value: NSUnderlineStyle.single.rawValue,
                                        range: range)
            }
        }

        attributed.enumerateAttribute(
            .link,
            in: NSRange(location: 0, length: attributed.length)
        ) { value, range, _ in
            guard value != nil else { return }
            attributed.addAttributes([
                .foregroundColor: NSColor.controlAccentColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ], range: range)
        }
    }

    private static func inlineIntentRawValue(_ value: Any?) -> Int {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let value {
            return Mirror(reflecting: value).descendant("rawValue") as? Int ?? 0
        }
        return 0
    }

    private static func inlineFont(strong: Bool, emphasized: Bool) -> NSFont {
        var traits: NSFontTraitMask = []
        if strong {
            traits.insert(.boldFontMask)
        }
        if emphasized {
            traits.insert(.italicFontMask)
        }
        return NSFontManager.shared.convert(baseFont, toHaveTrait: traits)
    }

    private static func headingFont(level: Int) -> NSFont {
        let size: CGFloat
        switch level {
        case 1: size = 18
        case 2: size = 16.2
        case 3: size = 14.6
        default: size = 13.5
        }
        return NSFont.systemFont(ofSize: size, weight: .semibold)
    }

    private static func labelColor(for colorScheme: ColorScheme) -> NSColor {
        colorScheme == .dark
        ? NSColor(calibratedWhite: 0.92, alpha: 1)
        : NSColor(calibratedWhite: 0.08, alpha: 1)
    }

    private static func codeBackground(for colorScheme: ColorScheme) -> NSColor {
        colorScheme == .dark
        ? NSColor(calibratedWhite: 0.22, alpha: 1)
        : NSColor(calibratedWhite: 0.92, alpha: 1)
    }
}

private struct HelmMarkdownImageProvider: ImageProvider {
    func makeImage(url: URL?) -> some View {
        HelmMarkdownImageView(url: url)
    }
}

private struct HelmMarkdownImageView: View {
    let url: URL?
    @State private var image: NSImage?
    @State private var didFail = false

    var body: some View {
        Group {
            if let image {
                let size = fittedDisplaySize(for: image)
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size.width, height: size.height)
                    .background(Color.helmChatBg)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.helmBorderStrong, lineWidth: 0.5)
                    )
            } else if didFail {
                imageUnavailableView
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 36, height: 28)
            }
        }
        .task(id: url?.absoluteString ?? "") {
            await loadImage()
        }
    }

    private var imageUnavailableView: some View {
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

    @MainActor
    private func loadImage() async {
        image = nil
        didFail = false

        guard let url else {
            didFail = true
            return
        }

        if let fileURL = HelmMarkdownImageURL.localFileURL(from: url) {
            image = NSImage(contentsOf: fileURL)
            didFail = image == nil
            return
        }

        guard HelmMarkdownImageURL.isNetworkURL(url) else {
            didFail = true
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            image = NSImage(data: data)
            didFail = image == nil
        } catch {
            didFail = true
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

private struct HelmMarkdownInlineImageProvider: InlineImageProvider {
    func image(with url: URL, label: String) async throws -> Image {
        if let fileURL = HelmMarkdownImageURL.localFileURL(from: url),
           let image = NSImage(contentsOf: fileURL) {
            return Image(nsImage: image)
        }

        guard HelmMarkdownImageURL.isNetworkURL(url) else {
            throw URLError(.unsupportedURL)
        }

        let (data, _) = try await URLSession.shared.data(from: url)
        guard let image = NSImage(data: data) else {
            throw URLError(.cannotDecodeContentData)
        }
        return Image(nsImage: image)
    }
}

private enum HelmMarkdownImageURL {
    static func localFileURL(from url: URL) -> URL? {
        if url.isFileURL {
            return url
        }
        if url.scheme == nil, url.path.hasPrefix("/") {
            return URL(fileURLWithPath: url.path)
        }
        return nil
    }

    static func isNetworkURL(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return scheme == "http" || scheme == "https"
    }
}

private extension Theme {
    static let helmChat = Theme.gitHub
        .text {
            ForegroundColor(.primary)
            BackgroundColor(nil)
            FontSize(13.5)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.88))
            ForegroundColor(.primary)
            BackgroundColor(Color.secondary.opacity(0.12))
        }
        .strong {
            FontWeight(.semibold)
        }
        .link {
            ForegroundColor(.accentColor)
        }
        .heading1 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.35))
                }
                .markdownMargin(top: 12, bottom: 8)
        }
        .heading2 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.2))
                }
                .markdownMargin(top: 12, bottom: 8)
        }
        .heading3 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.08))
                }
                .markdownMargin(top: 10, bottom: 6)
        }
        .heading4 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                }
                .markdownMargin(top: 8, bottom: 5)
        }
        .paragraph { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .relativeLineSpacing(.em(0.18))
                .markdownMargin(top: 0, bottom: 8)
        }
        .blockquote { configuration in
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.helmBorderStrong.opacity(0.75))
                    .relativeFrame(width: .em(0.18))
                configuration.label
                    .markdownTextStyle {
                        ForegroundColor(.secondary)
                    }
                    .relativePadding(.leading, length: .em(0.75))
            }
            .fixedSize(horizontal: false, vertical: true)
            .markdownMargin(top: 2, bottom: 8)
        }
        .codeBlock { configuration in
            ScrollView(.horizontal, showsIndicators: false) {
                configuration.label
                    .fixedSize(horizontal: true, vertical: true)
                    .relativeLineSpacing(.em(0.18))
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.88))
                        ForegroundColor(.primary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: DS.cornerRadiusSmall))
            .overlay(
                RoundedRectangle(cornerRadius: DS.cornerRadiusSmall)
                    .stroke(Color.helmBorder, lineWidth: 1)
            )
            .markdownMargin(top: 2, bottom: 10)
        }
        .listItem { configuration in
            configuration.label
                .markdownMargin(top: .em(0.18))
        }
        .table { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .markdownTableBorderStyle(.init(color: Color.helmBorderStrong.opacity(0.75)))
                .markdownTableBackgroundStyle(
                    .alternatingRows(Color.clear, Color.secondary.opacity(0.06))
                )
                .markdownMargin(top: 2, bottom: 10)
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
                .padding(.vertical, 5)
                .padding(.horizontal, 10)
        }
        .image { configuration in
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .markdownMargin(top: 4, bottom: 10)
        }
}
