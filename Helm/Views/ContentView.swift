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
            .animation(.easeOut(duration: 0.14), value: store.imagePreviewURL)
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
