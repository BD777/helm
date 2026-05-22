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
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") {
                    HelmCommandCenter.shared.newChat()
                }
                .keyboardShortcut("n", modifiers: [.command])

                Button("New Project") {
                    HelmCommandCenter.shared.addProject()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }

            CommandMenu("Navigate") {
                Button("Quick Switcher") {
                    HelmCommandCenter.shared.openQuickSwitcher()
                }
                .keyboardShortcut("k", modifiers: [.command])

                Button("Focus Composer") {
                    HelmCommandCenter.shared.focusComposer()
                }
                .keyboardShortcut("/", modifiers: [.command])

                Divider()

                Button("Previous Session") {
                    HelmCommandCenter.shared.selectPreviousSession()
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])

                Button("Next Session") {
                    HelmCommandCenter.shared.selectNextSession()
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])

                Divider()

                Button("Hide Sidebar") {
                    HelmCommandCenter.shared.setSidebarVisible(false)
                }
                .keyboardShortcut("[", modifiers: [.command])

                Button("Show Sidebar") {
                    HelmCommandCenter.shared.setSidebarVisible(true)
                }
                .keyboardShortcut("]", modifiers: [.command])

                Divider()

                ForEach(1...9, id: \.self) { index in
                    Button("Select Sidebar Item \(index)") {
                        HelmCommandCenter.shared.selectSidebarItem(index)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: [.command])
                }
            }

            CommandMenu("Run") {
                Button("Stop Response") {
                    HelmCommandCenter.shared.stopResponse()
                }
                .keyboardShortcut(".", modifiers: [.command])
            }
        }
    }
}

@MainActor
final class HelmCommandCenter {
    static let shared = HelmCommandCenter()

    private weak var store: AppStore?
    private var keyMonitor: Any?

    private init() {}

    func bind(store: AppStore) {
        self.store = store
        installKeyMonitorIfNeeded()
    }

    func newChat() {
        store?.newSessionInCurrentProject()
    }

    func addProject() {
        store?.addLocalProjectViaPicker()
    }

    func openQuickSwitcher() {
        store?.showQuickSwitcherPanel()
    }

    func focusComposer() {
        store?.requestComposerFocus()
    }

    func stopResponse() {
        store?.cancelStreaming()
    }

    func selectPreviousSession() {
        store?.selectRelativeSession(offset: -1)
    }

    func selectNextSession() {
        store?.selectRelativeSession(offset: 1)
    }

    func selectSidebarItem(_ index: Int) {
        store?.selectSidebarItem(index)
    }

    func setSidebarVisible(_ visible: Bool) {
        UserDefaults.standard.set(visible, forKey: "sidebarVisible")
    }

    private func installKeyMonitorIfNeeded() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let command = HelmKeyboardCommand(event: event)
            let consumed = MainActor.assumeIsolated {
                self?.handle(command) ?? false
            }
            return consumed ? nil : event
        }
    }

    private func handle(_ command: HelmKeyboardCommand) -> Bool {
        guard NSApp.isActive else { return false }
        if store?.showQuickSwitcher == true, command.keyCode == 53 {
            store?.hideQuickSwitcherPanel()
            return true
        }
        guard command.hasCommand else { return false }

        guard !command.hasControl else { return false }

        if command.hasOption {
            switch command.keyCode {
            case 123:
                selectPreviousSession()
                return true
            case 124:
                selectNextSession()
                return true
            default:
                return false
            }
        }

        if command.hasShift {
            if command.characters == "n" {
                addProject()
                return true
            }
            return false
        }

        switch command.characters {
        case "n":
            newChat()
            return true
        case "k":
            openQuickSwitcher()
            return true
        case "/":
            focusComposer()
            return true
        case ".":
            stopResponse()
            return true
        case "[":
            setSidebarVisible(false)
            return true
        case "]":
            setSidebarVisible(true)
            return true
        case "1", "2", "3", "4", "5", "6", "7", "8", "9":
            if let index = Int(command.characters) {
                selectSidebarItem(index)
                return true
            }
            return false
        default:
            return false
        }
    }
}

private struct HelmKeyboardCommand {
    let keyCode: UInt16
    let characters: String
    let hasCommand: Bool
    let hasOption: Bool
    let hasShift: Bool
    let hasControl: Bool

    init(event: NSEvent) {
        keyCode = event.keyCode
        characters = (event.charactersIgnoringModifiers ?? "").lowercased()
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        hasCommand = flags.contains(.command)
        hasOption = flags.contains(.option)
        hasShift = flags.contains(.shift)
        hasControl = flags.contains(.control)
    }
}

private struct AppRootView: View {
    @AppStorage("helmAppearance") private var appearanceRawValue = HelmAppearance.system.rawValue

    private var appearance: HelmAppearance {
        HelmAppearance.normalized(appearanceRawValue)
    }

    var body: some View {
        ContentView()
            .preferredColorScheme(appearance.colorScheme)
            .animation(.easeOut(duration: 0.16), value: appearanceRawValue)
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

        let root = AppRootView()
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
