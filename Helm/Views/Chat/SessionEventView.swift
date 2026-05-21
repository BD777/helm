import SwiftUI

/// Inline marker rendered between dialog turns when the agent did something
/// the user didn't directly author — today only Claude's auto-compact
/// summary, but the layout (hairline rules + small label) is generic so
/// future event kinds (model switch, permission change) can reuse it.
///
/// Click expands the captured summary text. We keep it collapsed by default
/// because the summary is verbose and almost always uninteresting once the
/// next turn has happened.
struct SessionEventView: View {
    let event: SessionEvent
    @State private var expanded = false

    var body: some View {
        switch event {
        case .compactSummary(_, let summary):
            divider(label: "Conversation compacted",
                    icon: "arrow.triangle.merge",
                    detail: summary)
        }
    }

    @ViewBuilder
    private func divider(label: String, icon: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 10) {
                    rule
                    HStack(spacing: 6) {
                        Image(systemName: icon)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Text(label)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    rule
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)
                    .padding(.horizontal, 4)
            }
        }
    }

    private var rule: some View {
        Rectangle()
            .fill(Color.helmBorderStrong.opacity(0.35))
            .frame(height: 0.5)
            .frame(maxWidth: .infinity)
    }
}
