import SwiftUI

struct DiffCard: View {
    let diff: Diff
    @State private var collapsed: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if !collapsed {
                Divider()
                VStack(spacing: 0) {
                    ForEach(diff.lines) { line in
                        DiffLineView(line: line)
                    }
                }
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
        .clipShape(RoundedRectangle(cornerRadius: DS.cornerRadius))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 10)
            Text("Edit")
                .font(.system(size: 12, weight: .semibold))
            Text(diff.path)
                .font(DS.monoFontSmall)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("+\(diff.plus)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.green)
            Text("-\(diff.minus)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.red)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture { collapsed.toggle() }
    }
}

private struct DiffLineView: View {
    let line: Diff.Line

    var body: some View {
        HStack(spacing: 0) {
            Text(line.lineNo)
                .font(DS.monoFontSmall)
                .frame(width: 36, alignment: .trailing)
                .foregroundStyle(gutterColor)
                .padding(.horizontal, 6)
            Text(line.text.isEmpty ? " " : line.text)
                .font(DS.monoFontSmall)
                .foregroundStyle(.primary)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(bgColor)
    }

    private var bgColor: Color {
        switch line.kind {
        case .add: return Color.helmDiffAdd
        case .del: return Color.helmDiffDel
        case .context: return .clear
        }
    }
    private var gutterColor: Color {
        switch line.kind {
        case .add: return .green
        case .del: return .red
        case .context: return .secondary.opacity(0.6)
        }
    }
}
