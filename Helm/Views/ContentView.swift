import SwiftUI

struct ContentView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width < DS.sidebarAutoHideWidth {
                detailPane
            } else {
                HStack(spacing: 0) {
                    SidebarView()
                        .frame(width: DS.sidebarWidth)
                    mainSurface
                }
                .background(Color.helmSidebarBg)
            }
        }
    }

    private var mainSurface: some View {
        detailPane
            .clipShape(RoundedRectangle(cornerRadius: DS.cornerRadiusLarge,
                                        style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.cornerRadiusLarge,
                                 style: .continuous)
                    .stroke(Color.helmBorder, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.06), radius: 12, x: 0, y: 4)
            .padding(.leading, 6)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .frame(minWidth: 0, maxWidth: .infinity)
    }

    private var detailPane: some View {
        Group {
            if store.selectedSession != nil {
                ChatView()
            } else {
                EmptyChatView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.helmChatBg)
    }
}
