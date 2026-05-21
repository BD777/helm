import SwiftUI

struct MessageListView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let s = store.selectedSession {
                    ForEach(s.messages) { msg in
                        MessageView(message: msg)
                            .frame(maxWidth: DS.messageMaxWidth, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 18)
                    }
                }
            }
            .padding(.vertical, 24)
        }
        .background(Color.helmChatBg)
    }
}

struct MessageView: View {
    let message: Message

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            head
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
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var head: some View {
        HStack(spacing: 8) {
            Text(message.who)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(isUser ? Color.accentColor : Color.primary)
            if let meta = message.meta {
                Text("· \(meta)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
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
