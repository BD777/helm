import AppKit
import SwiftUI

struct MessageListView: View {
    @Environment(AppStore.self) private var store

    /// Programmatic scroll handle. We bind it so we can both *drive*
    /// scrolls (`scrollTo(edge:)`) and *read* whether the user has taken
    /// over via `isPositionedByUser` — the latter only flips on real
    /// scroll-wheel / trackpad gestures, not on our own programmatic
    /// scrolls, which is exactly what we need to avoid the feedback loop
    /// the geometry-based heuristic used to fall into.
    @State private var scrollPos = ScrollPosition(idType: Never.self, edge: .bottom)

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(displayItems) { item in
                    displayRow(item)
                        .frame(maxWidth: DS.messageMaxWidth, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 18)
                }
            }
            .padding(.vertical, 24)
        }
        .background(Color.helmChatBg)
        // Initial appearance lands at the bottom. We don't ask SwiftUI to
        // anchor sizeChanges to .bottom because that fires on every
        // layout pass (window resize, sidebar collapse) too — we drive
        // streaming follow ourselves below where we can gate on user intent.
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .scrollPosition($scrollPos, anchor: .bottom)
        .onChange(of: streamTick) { _, _ in
            // Streaming token arrived (or a new message appended). Follow
            // the bottom *only* if the user hasn't manually scrolled up.
            // No `withAnimation` here — each token is a tiny scroll and
            // overlapping eased animations would fight each other and
            // visibly stutter.
            guard !scrollPos.isPositionedByUser else { return }
            scrollPos.scrollTo(edge: .bottom)
        }
        .onChange(of: store.sendTick) { _, _ in
            // "I just hit send" — snap to bottom regardless of where the
            // user was parked, and the next streamTick will resume the
            // follow because isPositionedByUser is reset by scrollTo.
            withAnimation(.easeOut(duration: 0.22)) {
                scrollPos.scrollTo(edge: .bottom)
            }
        }
        .onChange(of: store.selectedSessionId) { _, _ in
            withAnimation(.easeOut(duration: 0.22)) {
                scrollPos.scrollTo(edge: .bottom)
            }
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

    @ViewBuilder
    private func displayRow(_ item: DisplayItem) -> some View {
        switch item {
        case .userMessage(let msg):
            MessageView(message: msg)
        case .event(let event):
            SessionEventView(event: event)
        case .assistantTurn(let thinking, let answer):
            VStack(alignment: .leading, spacing: 10) {
                if !thinking.isEmpty {
                    ThinkingBlock(messages: thinking, isRunning: answer == nil)
                }
                if let answer {
                    MessageView(message: answer)
                }
            }
        }
    }

    /// Combined "did the rendered transcript grow?" signal.
    /// - transcript.count covers new-message appends.
    /// - the last message's tail-text length covers the streaming case
    ///   where row count is steady but the assistant bubble grows
    ///   character-by-character.
    private var streamTick: String {
        guard let s = store.selectedSession else { return "" }
        let lastMsg = s.transcript.reversed().lazy.compactMap { $0.message }.first
        let lastTextLen = lastMsg?.parts.reversed().compactMap { p -> Int? in
            if case .text(let t) = p { return t.count }
            return nil
        }.first ?? 0
        return "\(s.transcript.count):\(lastTextLen)"
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
        return stepCount > 0 ? "已处理 · \(stepCount) 步" : "已处理"
    }

    private var header: some View {
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
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.18)) {
                userPreference = !collapsed
            }
        }
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
