import SwiftUI

struct ToolCallCard: View {
    let call: ToolCall
    @State private var collapsed: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            header
            if !collapsed, let body = call.body {
                Divider()
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(body)
                        .font(DS.monoFontSmall)
                        .foregroundStyle(.secondary)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: DS.cornerRadius)
                .fill(Color.helmCard)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.cornerRadius)
                        .stroke(Color.helmBorder, lineWidth: 1)
                )
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 10)
            Text(call.name)
                .font(.system(size: 12, weight: .semibold))
            Text(call.arg)
                .font(DS.monoFontSmall)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let m = call.meta {
                Text(m)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            statusBadge
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture { collapsed.toggle() }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch call.status {
        case .ok(let exit):
            Text("exit \(exit)")
                .badgeStyle(bg: .green.opacity(0.18), fg: .green)
        case .error(let exit):
            Text("exit \(exit)")
                .badgeStyle(bg: .red.opacity(0.18), fg: .red)
        case .running:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("running")
            }
            .badgeStyle(bg: .orange.opacity(0.18), fg: .orange)
        }
    }
}

private extension View {
    func badgeStyle(bg: Color, fg: Color) -> some View {
        self
            .font(.system(size: 10.5))
            .foregroundStyle(fg)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(bg))
    }
}
