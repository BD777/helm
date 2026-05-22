import SwiftUI
import AppKit

@main
struct HelmApp: App {
    @NSApplicationDelegateAdaptor(HelmAppDelegate.self) private var appDelegate

    var body: some Scene {
        // Keep the AppKit delegate alive; it owns the explicit main window.
        let _ = appDelegate
        Settings {
            EmptyView()
        }
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
        window.title = ""
        window.subtitle = ""
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
    }
}

/// Bridge to AppKit lifecycle so we can run synchronous code on quit. SwiftUI's
/// scenePhase fires `.background` on macOS but `applicationWillTerminate` is
/// the durable hook for "the app is about to exit" — we use it to flush
/// debounced writes that would otherwise be killed by process exit.
final class HelmAppDelegate: NSObject, NSApplicationDelegate {
    private var store: AppStore?
    private var mainWindow: NSWindow?

    func applicationWillFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.set(true, forKey: "ApplePersistenceIgnoreState")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.showMainWindow()
            }
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated {
            if flag {
                mainWindow?.makeKeyAndOrderFront(nil)
            } else {
                showMainWindow()
            }
        }
        return true
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // applicationWillTerminate is delivered on the main thread by AppKit;
        // assume MainActor isolation so we can call the @MainActor-isolated
        // store synchronously before the process tears down.
        MainActor.assumeIsolated {
            store?.flushAll()
        }
    }

    @MainActor
    private func showMainWindow() {
        if let mainWindow {
            mainWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let store = store ?? AppStore()
        self.store = store

        let root = ContentView()
            .environment(store)
            .frame(minWidth: DS.windowMinWidth, minHeight: DS.windowMinHeight)
            .toolbarBackground(.hidden, for: .windowToolbar)
            .background(WindowTitleHider())

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = ""
        window.subtitle = ""
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unifiedCompact
        window.contentMinSize = NSSize(width: DS.windowMinWidth,
                                       height: DS.windowMinHeight)
        window.contentViewController = NSHostingController(rootView: root)
        window.isReleasedWhenClosed = false
        let defaultFrame = NSRect(x: 0, y: 0, width: 1180, height: 760)
        window.setFrame(defaultFrame, display: false)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        mainWindow = window
    }
}
