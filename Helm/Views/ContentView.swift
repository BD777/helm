import SwiftUI

struct ContentView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: DS.sidebarWidth, max: 360)
        } detail: {
            if store.selectedSession != nil {
                ChatView()
            } else {
                EmptyChatView()
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}

#Preview {
    ContentView()
        .environment(AppStore.demo())
        .frame(width: 1180, height: 760)
}
