import SwiftUI

@main
struct HelmApp: App {
    @State private var store = AppStore.demo()

    var body: some Scene {
        Window("Helm", id: "main") {
            ContentView()
                .environment(store)
                .frame(minWidth: 880, minHeight: 560)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 1180, height: 760)
    }
}
