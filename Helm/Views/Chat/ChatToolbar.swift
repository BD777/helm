import SwiftUI

struct ChatToolbar: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let session = store.selectedSession
        let project = session.flatMap { store.project(for: $0.id) }
        let path = project.map(displayPath) ?? ""

        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(session?.title ?? "—")
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(path)
                    .font(DS.monoFontSmall)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
            if store.selectedSessionIsStreaming {
                RunningStatusPill(startedAt: store.activeRunStartedAt) {
                    store.cancelStreaming()
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .animation(.easeOut(duration: 0.14), value: store.selectedSessionIsStreaming)
    }

    private func displayPath(for project: Project) -> String {
        switch project.location {
        case .local(let path):
            return path
        case .ssh(let host, let path, let status):
            let resolved = status.resolvedPath?.isEmpty == false
                ? status.resolvedPath!
                : path
            return "\(host):\(resolved)"
        }
    }
}

private struct RunningStatusPill: View {
    let startedAt: Date?
    var onStop: () -> Void

    var body: some View {
        TimelineView(.periodic(from: startedAt ?? Date(), by: 1)) { context in
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.72)
                    .frame(width: 12, height: 12)
                Text("Running · \(elapsedText(now: context.date))")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button {
                    onStop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Color.red, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Stop response")
                .accessibilityLabel("Stop response")
            }
            .padding(.leading, 9)
            .padding(.trailing, 5)
            .frame(height: 26)
            .background(
                Capsule()
                    .fill(Color.helmCard)
                    .overlay(
                        Capsule()
                            .stroke(Color.helmBorderStrong, lineWidth: 0.5)
                    )
            )
        }
    }

    private func elapsedText(now: Date) -> String {
        guard let startedAt else { return "0:00" }
        let elapsed = max(0, Int(now.timeIntervalSince(startedAt)))
        return "\(elapsed / 60):\(String(format: "%02d", elapsed % 60))"
    }
}
