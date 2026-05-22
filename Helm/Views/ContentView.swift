import SwiftUI

struct ContentView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width < DS.sidebarAutoHideWidth {
                detailPane
            } else {
                HSplitView {
                    SidebarView()
                        .frame(width: DS.sidebarWidth)
                    detailPane
                        .frame(minWidth: 0, maxWidth: .infinity)
                }
            }
        }
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
