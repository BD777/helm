import AppKit
import SwiftUI

struct MessageListView: View {
    @Environment(AppStore.self) private var store
    var onTranscriptTap: () -> Void = {}

    @StateObject private var autoScroll = ChatAutoScrollController()

    var body: some View {
        let items = displayItems

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    displayRow(item, isLatest: index == items.count - 1)
                        .frame(maxWidth: DS.messageMaxWidth, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 18)
                }
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
            autoScroll.forceScrollToBottom(animated: true)
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
    private func displayRow(_ item: DisplayItem, isLatest: Bool) -> some View {
        switch item {
        case .userMessage(let msg):
            MessageView(message: msg)
        case .event(let event):
            SessionEventView(event: event)
        case .assistantTurn(let thinking, let answer):
            VStack(alignment: .leading, spacing: 10) {
                if !thinking.isEmpty {
                    ThinkingBlock(
                        messages: thinking,
                        isRunning: answer == nil
                            && isLatest
                            && store.selectedSessionIsStreaming
                    )
                }
                if let answer {
                    MessageView(message: answer)
                }
            }
        }
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
    private let maxScrollPasses = 6

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
        showJumpToBottom = false
    }

    func forceScrollToBottom(animated: Bool) {
        followsBottom = true
        scheduleScrollToBottom(animated: animated, force: true)
    }

    private func visibleBoundsDidChange() {
        guard !isProgrammaticScroll, let scrollView else { return }
        if isLiveUserScroll || currentEventLooksLikeUserScroll {
            userDidScroll()
        } else if distanceFromBottom(in: scrollView) <= followResumeTolerance {
            followsBottom = true
            showJumpToBottom = false
        }
    }

    private func documentFrameDidChange() {
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
        showJumpToBottom = distance > jumpButtonTolerance
    }

    private func refreshJumpButton() {
        guard let scrollView else {
            showJumpToBottom = false
            return
        }
        showJumpToBottom = distanceFromBottom(in: scrollView) > jumpButtonTolerance
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
        default: return .milliseconds(200)
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
            showJumpToBottom = false
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
        followsBottom = true
        showJumpToBottom = false
        isProgrammaticScroll = false
    }

    private var currentEventLooksLikeUserScroll: Bool {
        guard let event = NSApp.currentEvent else { return false }
        switch event.type {
        case .scrollWheel, .leftMouseDragged, .rightMouseDragged,
             .otherMouseDragged, .leftMouseDown, .keyDown:
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

/// Groups consecutive assistant messages into one `assistantTurn`. The
/// last message in such a run is treated as the "answer" if it has no
/// tool calls (Claude only stops emitting `tool_use` blocks when it's
/// done working), otherwise everything is still mid-think.
private func groupTranscript(_ items: [TranscriptItem]) -> [DisplayItem] {
    var out: [DisplayItem] = []
    var pending: [Message] = []

    func flush() {
        guard !pending.isEmpty else { return }
        let last = pending.last!
        let lastHasTool = last.parts.contains { part in
            if case .toolCall = part { return true }
            return false
        }
        if lastHasTool {
            // Still in the tool-use phase: no formal answer yet, the
            // whole run stays as thinking.
            out.append(.assistantTurn(thinking: pending, answer: nil))
        } else {
            let thinking = Array(pending.dropLast())
            out.append(.assistantTurn(thinking: thinking, answer: last))
        }
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

struct MessageView: View {
    let message: Message

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(message.parts.enumerated()), id: \.offset) { _, part in
                partView(part)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, isUser ? 12 : 0)
        .padding(.vertical, isUser ? 8 : 0)
        .background(
            isUser
            ? RoundedRectangle(cornerRadius: DS.cornerRadius)
                .fill(Color.accentColor.opacity(0.08))
            : nil
        )
    }

    private var isUser: Bool {
        if case .user = message.role { return true }
        return false
    }

    @ViewBuilder
    private func partView(_ part: Part) -> some View {
        switch part {
        case .text(let s):
            MarkdownishText(s)
                .padding(.top, 2)
        case .toolCall(let t):
            ToolCallCard(call: t)
                .padding(.vertical, 4)
        case .image(let url):
            ImagePartView(url: url)
                .padding(.vertical, 4)
        }
    }
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
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(messages) { msg in
                        MessageView(message: msg)
                    }
                }
            }
        }
    }

    private var stepCount: Int {
        messages.reduce(0) { acc, msg in
            acc + msg.parts.reduce(into: 0) { sub, part in
                if case .toolCall = part { sub += 1 }
            }
        }
    }

    private var label: String {
        if isRunning { return "处理中…" }
        if isStopped {
            return stepCount > 0 ? "已停止 · \(stepCount) 步" : "已停止"
        }
        if hasToolError {
            return stepCount > 0 ? "出错 · \(stepCount) 步" : "出错"
        }
        return stepCount > 0 ? "已处理 · \(stepCount) 步" : "已处理"
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

    private var hasToolError: Bool {
        messages.contains { message in
            message.parts.contains { part in
                if case .toolCall(let call) = part,
                   case .error = call.status {
                    return true
                }
                return false
            }
        }
    }

    private var header: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) {
                userPreference = !collapsed
            }
        } label: {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.tertiary)
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(collapsed ? "collapsed" : "expanded")
            .accessibilityHint(collapsed ? "Show steps" : "Hide steps")
        }
        .buttonStyle(.plain)
    }
}

private struct ImagePartView: View {
    let url: URL

    var body: some View {
        if let img = NSImage(contentsOf: url) {
            Image(nsImage: img)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 240, maxHeight: 240, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.helmBorderStrong, lineWidth: 0.5)
                )
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
}

/// Minimal Markdown renderer for v1: uses SwiftUI built-in inline markdown,
/// with backtick code styling. Full code-block & syntax highlighting later.
struct MarkdownishText: View {
    let raw: String
    init(_ raw: String) { self.raw = raw }

    var body: some View {
        if let attr = try? AttributedString(
            markdown: raw,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            Text(attr)
                .font(.system(size: 13.5))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(raw)
                .font(.system(size: 13.5))
                .textSelection(.enabled)
        }
    }
}
