import SwiftUI

struct ModelPickerMenu: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            group("Model · Claude") {
                item(check: true,  title: "Opus 4.7",   sub: "latest · best")
                item(check: false, title: "Sonnet 4.6", sub: "balanced")
                item(check: false, title: "Haiku 4.5",  sub: "fast")
            }
            divider
            group("Profile · Claude", hint: "switch keeps this session") {
                item(check: true,  title: "super-relay", sub: "env overlay")
                item(check: false, title: "direct (anthropic.com)", sub: "~/.claude default")
                item(check: false, title: "modelhub-bridge", sub: "mhclaude wrapper")
            }
            divider
            group("Claude settings") {
                toggleRow(title: "Extended thinking", on: true)
                pickerRow(title: "Compaction window", value: "200k")
                pickerRow(title: "Subagent model", value: "same")
            }
            divider
            group("Switch ecosystem", hint: "starts new session") {
                ecosystemItem(label: "Cx", title: "Codex · gpt-5", sub: "reasoning effort: medium")
            }
        }
        .padding(6)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.helmBorder)
            .frame(height: 1)
            .padding(.vertical, 4)
    }

    private func group<V: View>(_ label: String, hint: String? = nil, @ViewBuilder content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text(label.uppercased())
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(.tertiary)
                if let hint {
                    Text(" — \(hint)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary.opacity(0.8))
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 4)
            content()
        }
    }

    private func item(check: Bool, title: String, sub: String) -> some View {
        Button { } label: {
            HStack(spacing: 10) {
                Image(systemName: check ? "checkmark" : "")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.tint)
                    .frame(width: 12)
                Text(title).font(.system(size: 12.5))
                Spacer()
                Text(sub).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggleRow(title: String, on: Bool) -> some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 12)
            Text(title).font(.system(size: 12.5))
            Spacer()
            Toggle("", isOn: .constant(on))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private func pickerRow(title: String, value: String) -> some View {
        Button { } label: {
            HStack(spacing: 10) {
                Color.clear.frame(width: 12)
                Text(title).font(.system(size: 12.5))
                Spacer()
                HStack(spacing: 3) {
                    Text(value).font(.system(size: 11))
                    Image(systemName: "chevron.down").font(.system(size: 8))
                }
                .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func ecosystemItem(label: String, title: String, sub: String) -> some View {
        Button { } label: {
            HStack(spacing: 10) {
                VendorBadge(vendor: .codex).frame(width: 14, height: 14)
                Text(title).font(.system(size: 12.5))
                Spacer()
                Text(sub).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
