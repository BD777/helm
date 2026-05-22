import SwiftUI
import AppKit

@main
struct HelmApp: App {
    @State private var store = AppStore()
    @NSApplicationDelegateAdaptor(HelmAppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Helm", id: "main") {
            ContentView()
                .environment(store)
                .frame(minWidth: 880, minHeight: 560)
                .toolbarBackground(.hidden, for: .windowToolbar)
                .background(WindowTitleHider())
                .onAppear {
                    // Hand the live store to the AppKit delegate so
                    // applicationWillTerminate can synchronously flush both
                    // JSON files and we don't lose in-flight debounced writes.
                    appDelegate.store = store
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 1180, height: 760)
    }
}

private struct WindowTitleHider: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            hideTitle(for: view)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            hideTitle(for: view)
        }
    }

    private func hideTitle(for view: NSView) {
        guard let window = view.window else { return }
        window.titleVisibility = .hidden
    }
}

/// Bridge to AppKit lifecycle so we can run synchronous code on quit. SwiftUI's
/// scenePhase fires `.background` on macOS but `applicationWillTerminate` is
/// the durable hook for "the app is about to exit" — we use it to flush
/// debounced writes that would otherwise be killed by process exit.
final class HelmAppDelegate: NSObject, NSApplicationDelegate {
    weak var store: AppStore?

    func applicationWillFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.set(true, forKey: "ApplePersistenceIgnoreState")
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // applicationWillTerminate is delivered on the main thread by AppKit;
        // assume MainActor isolation so we can call the @MainActor-isolated
        // store synchronously before the process tears down.
        MainActor.assumeIsolated {
            store?.flushAll()
        }
    }
}
