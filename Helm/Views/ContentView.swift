import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(AppStore.self) private var store
    @AppStorage("sidebarVisible") private var sidebarVisible = true

    var body: some View {
        GeometryReader { proxy in
            let isCompact = proxy.size.width < DS.sidebarAutoHideWidth

            HStack(spacing: 0) {
                sidebarContainer(isCompact: isCompact)
                mainSurface(isFloating: !isCompact)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .background(Color.helmSidebarBg)
            .animation(Self.sidebarAnimation, value: sidebarVisible)
            .animation(Self.sidebarAnimation, value: isCompact)
            .overlay {
                if let previewURL = store.imagePreviewURL {
                    ImagePreviewOverlay(url: previewURL) {
                        store.imagePreviewURL = nil
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
                    .zIndex(20)
                }
            }
            .overlay {
                if store.showQuickSwitcher {
                    QuickSwitcherView()
                        .transition(.opacity.combined(with: .scale(scale: 0.985)))
                        .zIndex(30)
                }
            }
            .animation(.easeOut(duration: 0.14), value: store.imagePreviewURL)
            .animation(.easeOut(duration: 0.12), value: store.showQuickSwitcher)
            .onAppear {
                HelmCommandCenter.shared.bind(store: store)
            }
        }
    }

    private func sidebarContainer(isCompact: Bool) -> some View {
        ZStack(alignment: .leading) {
            if !isCompact {
                if sidebarVisible {
                    SidebarView {
                        setSidebarVisible(false)
                    }
                    .frame(width: DS.sidebarWidth)
                    .transition(Self.sidebarTransition)
                } else {
                    CollapsedSidebarRail {
                        setSidebarVisible(true)
                    } onOpenSettings: {
                        store.showProfilesSheet = true
                    }
                    .transition(Self.sidebarTransition)
                }
            }
        }
        .frame(width: sidebarWidth(isCompact: isCompact), alignment: .leading)
        .frame(maxHeight: .infinity)
        .clipped()
        .opacity(isCompact ? 0 : 1)
    }

    private func mainSurface(isFloating: Bool) -> some View {
        detailPane
            .clipShape(RoundedRectangle(cornerRadius: isFloating ? DS.cornerRadiusLarge : 0,
                                        style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: isFloating ? DS.cornerRadiusLarge : 0,
                                 style: .continuous)
                    .stroke(Color.helmBorder, lineWidth: 1)
                    .opacity(isFloating ? 1 : 0)
            )
            .shadow(color: Color.black.opacity(isFloating ? 0.06 : 0),
                    radius: isFloating ? 12 : 0,
                    x: 0,
                    y: isFloating ? 4 : 0)
            .padding(.leading, isFloating ? 6 : 0)
            .padding(.trailing, isFloating ? 8 : 0)
            .padding(.vertical, isFloating ? 8 : 0)
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

    private func sidebarWidth(isCompact: Bool) -> CGFloat {
        if isCompact { return 0 }
        return sidebarVisible ? DS.sidebarWidth : DS.sidebarCollapsedRailWidth
    }

    private func setSidebarVisible(_ visible: Bool) {
        withAnimation(Self.sidebarAnimation) {
            sidebarVisible = visible
        }
    }

    private static let sidebarAnimation = Animation.interactiveSpring(
        response: 0.26,
        dampingFraction: 0.9,
        blendDuration: 0.04
    )

    private static let sidebarTransition = AnyTransition
        .asymmetric(
            insertion: .move(edge: .leading).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
}

private struct QuickSwitcherView: View {
    @Environment(AppStore.self) private var store
    @State private var query = ""
    @State private var highlightedId: UUID?
    @State private var keyMonitor: Any?
    @FocusState private var searchFocused: Bool

    private var entries: [QuickSwitcherEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allEntries = store.visibleSessions.compactMap { session -> QuickSwitcherEntry? in
            guard let project = store.project(for: session.id) else { return nil }
            let profile = store.profile(session.profileId)
            let path = displayPath(for: project)
            let headline = store.sessionHeadline(session)
            return QuickSwitcherEntry(
                session: session,
                project: project,
                vendor: profile?.vendor,
                headline: headline,
                path: path,
                haystack: [
                    session.title,
                    project.name,
                    path,
                    headline,
                    profile?.name ?? "",
                    profile?.vendor.displayName ?? "",
                ].joined(separator: " ").lowercased()
            )
        }
        guard !needle.isEmpty else { return allEntries }
        let terms = needle.split(whereSeparator: \.isWhitespace).map(String.init)
        return allEntries.filter { entry in
            terms.allSatisfy { entry.haystack.contains($0) }
        }
    }

    private var currentHighlight: UUID? {
        highlightedId.flatMap { id in
            entries.contains { $0.id == id } ? id : nil
        } ?? entries.first?.id
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.14)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: close)

            panel
        }
        .onAppear {
            highlightedId = entries.first?.id
            focusSearch()
            installKeyMonitor()
        }
        .onChange(of: query) { _, _ in
            highlightedId = entries.first?.id
        }
        .onDisappear(perform: removeKeyMonitor)
        .onExitCommand(perform: close)
    }

    private var panel: some View {
        VStack(spacing: 0) {
            searchRow
            Divider()
            results
        }
        .frame(width: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.cornerRadiusLarge, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.cornerRadiusLarge, style: .continuous)
                .stroke(Color.helmBorderStrong, lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 24, x: 0, y: 12)
        .padding(.horizontal, 28)
    }

    private var searchRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.tertiary)
            TextField("Jump to session or project", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($searchFocused)
                .onSubmit(openHighlighted)
            Text("⌘K")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
    }

    @ViewBuilder
    private var results: some View {
        if entries.isEmpty {
            ContentUnavailableView(
                "No matches",
                systemImage: "magnifyingglass",
                description: Text("Try a session title, project name, or path.")
            )
            .frame(height: 180)
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(entries) { entry in
                        Button {
                            open(entry)
                        } label: {
                            QuickSwitcherRow(
                                entry: entry,
                                isHighlighted: entry.id == currentHighlight
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 360)
            .onMoveCommand { direction in
                switch direction {
                case .up:
                    moveHighlight(by: -1)
                case .down:
                    moveHighlight(by: 1)
                default:
                    break
                }
            }
        }
    }

    private func moveHighlight(by offset: Int) {
        guard !entries.isEmpty else { return }
        let current = currentHighlight.flatMap { id in
            entries.firstIndex { $0.id == id }
        } ?? 0
        highlightedId = entries[(current + offset + entries.count) % entries.count].id
    }

    private func openHighlighted() {
        guard let id = currentHighlight,
              let entry = entries.first(where: { $0.id == id })
        else { return }
        open(entry)
    }

    private func open(_ entry: QuickSwitcherEntry) {
        store.selectedSessionId = entry.session.id
        close()
    }

    private func close() {
        store.hideQuickSwitcherPanel()
        store.requestComposerFocus()
    }

    private func focusSearch() {
        DispatchQueue.main.async {
            searchFocused = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            searchFocused = true
        }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleKeyDown(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let commandFlags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard commandFlags.isEmpty else { return false }

        switch event.keyCode {
        case 125:
            moveHighlight(by: 1)
            return true
        case 126:
            moveHighlight(by: -1)
            return true
        case 36, 76:
            openHighlighted()
            return true
        case 53:
            close()
            return true
        default:
            return false
        }
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

private struct QuickSwitcherEntry: Identifiable {
    let session: Session
    let project: Project
    let vendor: Vendor?
    let headline: String
    let path: String
    let haystack: String

    var id: UUID { session.id }
}

private struct QuickSwitcherRow: View {
    let entry: QuickSwitcherEntry
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 10) {
            if let vendor = entry.vendor {
                VendorBadge(vendor: vendor)
                    .frame(width: 20, height: 20)
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.18))
                    .frame(width: 20, height: 20)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.session.title)
                        .font(.system(size: 13.5, weight: .medium))
                        .lineLimit(1)
                    Text(entry.project.name)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Text("\(entry.headline) · \(entry.path)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 50)
        .background(
            RoundedRectangle(cornerRadius: DS.cornerRadiusSmall)
                .fill(isHighlighted ? Color.helmSelected : Color.clear)
        )
        .contentShape(Rectangle())
    }
}

private struct CollapsedSidebarRail: View {
    var onExpandSidebar: () -> Void
    var onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SidebarChromeButton(symbolName: "sidebar.left",
                                accessibilityLabel: "Show sidebar",
                                help: "Show sidebar",
                                action: onExpandSidebar)
                .padding(.top, DS.sidebarHeaderTopPadding)

            Spacer()

            SidebarChromeButton(symbolName: "gearshape",
                                accessibilityLabel: "Settings",
                                help: "Profiles & vendor settings",
                                action: onOpenSettings)
                .padding(.bottom, 13)
        }
        .frame(width: DS.sidebarCollapsedRailWidth)
        .background(Color.helmSidebarBg)
    }
}

struct SidebarChromeButton: View {
    let symbolName: String
    let accessibilityLabel: String
    let help: String
    var action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbolName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: DS.cornerRadiusSmall)
                        .fill(hovered ? Color.helmHover : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
        .accessibilityLabel(accessibilityLabel)
    }
}
