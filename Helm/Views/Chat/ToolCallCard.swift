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

/// Compact wrapper for a run of adjacent tool calls. This keeps long command
/// bursts as one transcript row while preserving the existing per-call detail
/// view once the user expands the group.
struct ToolCallGroupCard: View {
    let calls: [ToolCall]
    @State private var collapsed: Bool = true

    var body: some View {
        if let onlyCall = calls.first, calls.count == 1 {
            ToolCallCard(call: onlyCall)
        } else if !calls.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(.easeOut(duration: 0.16)) {
                        collapsed.toggle()
                    }
                } label: {
                    headerContent
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(summary)
                        .accessibilityValue(collapsed ? "collapsed" : "expanded")
                        .accessibilityHint(collapsed ? "Show tool calls" : "Hide tool calls")
                }
                .buttonStyle(.plain)

                if !collapsed {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(calls) { call in
                            ToolCallCard(call: call)
                        }
                    }
                    .padding(.top, 2)
                    .padding(.leading, 22)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var headerContent: some View {
        HStack(spacing: 8) {
            leadingIcon
                .frame(width: 14, alignment: .center)
            Text(summary)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: DS.cornerRadiusSmall))
        .overlay(
            RoundedRectangle(cornerRadius: DS.cornerRadiusSmall)
                .stroke(Color.helmBorder.opacity(0.75), lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: DS.cornerRadiusSmall))
    }

    @ViewBuilder
    private var leadingIcon: some View {
        if hasRunningCall {
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.72)
        } else if allErrorCalls {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10.5))
                .foregroundStyle(.red.opacity(0.75))
        } else if hasErrorCall {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10.5))
                .foregroundStyle(.orange.opacity(0.82))
        } else if allStoppedCalls {
            Image(systemName: "stop.circle")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        } else {
            Image(systemName: "terminal")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    private var summary: String {
        ([statusLabel, toolSummary] + outcomeSummary).joined(separator: " · ")
    }

    private var statusLabel: String {
        if hasRunningCall { return "处理中" }
        if allErrorCalls { return "出错" }
        if allStoppedCalls { return "已停止" }
        return allShellCalls ? "已运行" : "已处理"
    }

    private var outcomeSummary: [String] {
        var summary: [String] = []
        if hasErrorCall, !allErrorCalls {
            summary.append("\(errorCallCount) 个出错")
        }
        if hasStoppedCall, !allStoppedCalls {
            summary.append("\(stoppedCallCount) 个已停止")
        }
        return summary
    }

    private var toolSummary: String {
        var buckets: [(count: Int, label: String)] = []
        let commandCount = calls.filter { bucket(for: $0) == .command }.count
        let editCount = calls.filter { bucket(for: $0) == .edit }.count
        let fileCount = calls.filter { bucket(for: $0) == .file }.count
        let searchCount = calls.filter { bucket(for: $0) == .search }.count
        let computerUseCount = calls.filter { bucket(for: $0) == .computerUse }.count
        let knownCount = commandCount + editCount + fileCount + searchCount + computerUseCount
        let otherCount = calls.count - knownCount

        if fileCount > 0 { buckets.append((fileCount, "个文件")) }
        if searchCount > 0 { buckets.append((searchCount, "次搜索")) }
        if commandCount > 0 { buckets.append((commandCount, "条命令")) }
        if editCount > 0 { buckets.append((editCount, "次改动")) }
        if computerUseCount > 0 { buckets.append((computerUseCount, "次界面操作")) }
        if otherCount > 0 { buckets.append((otherCount, "个工具调用")) }

        guard !buckets.isEmpty else {
            return "\(calls.count) 个工具调用"
        }
        return buckets
            .map { "\($0.count) \($0.label)" }
            .joined(separator: " · ")
    }

    private var allShellCalls: Bool {
        !calls.isEmpty && calls.allSatisfy { bucket(for: $0) == .command }
    }

    private var hasRunningCall: Bool {
        calls.contains { call in
            if case .running = call.status { return true }
            return false
        }
    }

    private var hasErrorCall: Bool {
        errorCallCount > 0
    }

    private var hasStoppedCall: Bool {
        stoppedCallCount > 0
    }

    private var allErrorCalls: Bool {
        !calls.isEmpty && errorCallCount == calls.count
    }

    private var allStoppedCalls: Bool {
        !calls.isEmpty && stoppedCallCount == calls.count
    }

    private var errorCallCount: Int {
        calls.filter { call in
            if case .error = call.status { return true }
            return false
        }.count
    }

    private var stoppedCallCount: Int {
        calls.filter { call in
            if case .stopped = call.status { return true }
            return false
        }.count
    }

    private enum ToolBucket {
        case command
        case edit
        case file
        case search
        case computerUse
        case other
    }

    private func bucket(for call: ToolCall) -> ToolBucket {
        let name = call.name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if name == "shell" || name == "bash" || name == "terminal" {
            return .command
        }
        if name == "apply patch" || name.contains("edit") || name.contains("write") {
            return .edit
        }
        if name.contains("search") || name == "rg" || name == "grep" || name.contains("find") {
            return .search
        }
        if name.contains("read") || name.contains("open") || name.contains("file") || name.contains("view") {
            return .file
        }
        if name == "computer use" {
            return .computerUse
        }
        return .other
    }
}
