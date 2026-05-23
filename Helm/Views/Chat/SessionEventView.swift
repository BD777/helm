import SwiftUI

/// Inline marker rendered between dialog turns when the agent did something
/// the user didn't directly author, such as Claude's auto-compact summary
/// or Helm attaching a built-in action to a vendor turn.
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
        case .goalApplied(_, let goal, let vendor, let appliedAt):
            divider(label: "Goal enabled for \(vendor.displayName) turn",
                    icon: "target",
                    detail: Self.goalDetail(goal: goal, vendor: vendor, appliedAt: appliedAt))
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

    private static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func goalDetail(goal: String, vendor: Vendor, appliedAt: Date) -> String {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = trimmed.isEmpty ? "" : ":\n\n\(trimmed)"
        return "Helm sent this turn to \(vendor.displayName) with /goal at \(Self.format(appliedAt))\(suffix)"
    }
}
