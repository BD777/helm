import SwiftUI

/// Inline rendering of a tool invocation. Mirrors the Codex CLI app's quiet
/// style: a single muted-gray line per call (`▶ Bash xcodebuild ...`) that
/// expands to reveal the captured stdout/stderr below. No card, no border —
/// the row sits in the message flow alongside text so a turn that intersperses
/// thought + commands reads as one paragraph instead of a stack of boxes.
struct ToolCallCard: View {
    let call: ToolCall
    @State private var collapsed: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if !collapsed, let bodyText = call.body, !bodyText.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(bodyText)
                        .font(DS.monoFontSmall)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
                // Indent under the icon so the body visually attaches to
                // the row above it.
                .padding(.leading, 22)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var header: some View {
        if hasBody {
            Button {
                collapsed.toggle()
            } label: {
                headerContent
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(call.name) \(argDisplay)")
                    .accessibilityValue(collapsed ? "collapsed" : "expanded")
                    .accessibilityHint(collapsed ? "Show output" : "Hide output")
            }
            .buttonStyle(.plain)
        } else {
            headerContent
        }
    }

    private var headerContent: some View {
        HStack(spacing: 8) {
            leadingIcon
                .frame(width: 14, alignment: .center)
            Text(call.name)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.secondary)
            Text(argDisplay)
                .font(DS.monoFontSmall)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if hasBody {
                Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }

    /// One-line preview of the call's args. Newlines collapse to spaces so
    /// the row stays single-line; the full payload is in the expanded body.
    private var argDisplay: String {
        call.arg.replacingOccurrences(of: "\n", with: " ")
    }

    @ViewBuilder
    private var leadingIcon: some View {
        switch call.status {
        case .ok:
            Image(systemName: "terminal")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        case .error:
            Image(systemName: "terminal")
                .font(.system(size: 11))
                .foregroundStyle(.red.opacity(0.75))
        case .running:
            ProgressView()
                .controlSize(.mini)
        case .stopped:
            Image(systemName: "stop.circle")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    private var hasBody: Bool {
        if let b = call.body { return !b.isEmpty }
        return false
    }
}
