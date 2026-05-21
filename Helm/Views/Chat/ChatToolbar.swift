import SwiftUI

struct ChatToolbar: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let session = store.selectedSession
        let project = session.flatMap { store.project(for: $0.id) }
        let path = project?.location.pathString ?? ""

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
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }
}
