import SwiftUI

struct ContentView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: DS.sidebarWidth, max: 360)
        } detail: {
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
        .navigationSplitViewStyle(.balanced)
    }
}
