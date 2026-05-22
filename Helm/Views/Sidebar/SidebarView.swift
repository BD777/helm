import AppKit
import SwiftUI

struct SidebarView: View {
    @Environment(AppStore.self) private var store
    var onCollapseSidebar: (() -> Void)? = nil

    @State private var settingsHovered = false
    @State private var draggingProjectId: UUID?
    @State private var projectDropTargetId: UUID?
    @State private var projectDropPlacement: ProjectDropPlacement = .after
    @State private var projectHeaderFrames: [UUID: CGRect] = [:]
    @State private var projectDragLocation: CGPoint?
    @State private var projectDragAnchorYOffset: CGFloat = 0

    var body: some View {
        @Bindable var store = store
        return VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    sidebarHeader
                        .padding(.bottom, 2)
                    if store.projects.isEmpty {
                        emptyState
                    } else {
                        ForEach(store.projects) { project in
                            ProjectSection(
                                project: project,
                                isDragging: draggingProjectId == project.id,
                                dropPlacement: projectDropTargetId == project.id ? projectDropPlacement : nil,
                                onDragChanged: { value in
                                    updateProjectDrag(project.id, value: value)
                                },
                                onDragEnded: { value in
                                    updateProjectDrag(project.id, value: value)
                                    finishProjectDrag()
                                }
                            )
                        }
                    }
                }
                .padding(.top, DS.sidebarHeaderTopPadding)
                .padding(.horizontal, 8)
                .padding(.bottom, 24)
                .onPreferenceChange(ProjectHeaderFramePreferenceKey.self) { frames in
                    projectHeaderFrames = frames
                }
            }
            .coordinateSpace(name: SidebarCoordinateSpace.projectList)
            .overlay(alignment: .topLeading) {
                projectDragPreview
            }
            settingsBar
        }
        .background(Color.helmSidebarBg)
        .sheet(isPresented: $store.showProfilesSheet) {
            ProfilesSheet()
                .environment(store)
        }
        .sheet(isPresented: $store.showSSHProjectSheet) {
            SSHProjectSheet()
                .environment(store)
        }
    }

    private func updateProjectDrag(_ projectId: UUID, value: DragGesture.Value) {
        if draggingProjectId != projectId {
            projectDragAnchorYOffset = value.location.y - (projectHeaderFrames[projectId]?.midY ?? value.location.y)
        }
        draggingProjectId = projectId
        projectDragLocation = value.location
        updateProjectDropTarget(for: value.location.y)
    }

    private func updateProjectDropTarget(for locationY: CGFloat) {
        guard let draggingProjectId else {
            projectDropTargetId = nil
            return
        }

        let targets = store.projects.compactMap { project -> (id: UUID, frame: CGRect)? in
            guard project.id != draggingProjectId,
                  let frame = projectHeaderFrames[project.id]
            else { return nil }
            return (project.id, frame)
        }
        guard !targets.isEmpty else {
            projectDropTargetId = nil
            return
        }

        if let target = targets.first(where: { locationY < $0.frame.midY }) {
            projectDropTargetId = target.id
            projectDropPlacement = .before
        } else if let target = targets.last {
            projectDropTargetId = target.id
            projectDropPlacement = .after
        }
    }

    private func finishProjectDrag() {
        defer {
            draggingProjectId = nil
            projectDropTargetId = nil
            projectDragLocation = nil
            projectDragAnchorYOffset = 0
        }
        guard let sourceId = draggingProjectId,
              let targetId = projectDropTargetId,
              sourceId != targetId
        else { return }

        withAnimation(.easeOut(duration: 0.16)) {
            store.moveProject(sourceId,
                              around: targetId,
                              after: projectDropPlacement == .after)
        }
    }

    @ViewBuilder
    private var projectDragPreview: some View {
        if let draggingProjectId,
           let projectDragLocation,
           let project = store.projects.first(where: { $0.id == draggingProjectId }) {
            ProjectDragPreview(project: project)
                .frame(width: DS.sidebarWidth - 16)
                .position(
                    x: DS.sidebarWidth / 2,
                    y: projectDragLocation.y - projectDragAnchorYOffset
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .allowsHitTesting(false)
                .zIndex(10)
        }
    }

    private var sidebarHeader: some View {
        HStack(spacing: 4) {
            addProjectButton
            if let onCollapseSidebar {
                SidebarChromeButton(symbolName: "sidebar.left",
                                    accessibilityLabel: "Hide sidebar",
                                    help: "Hide sidebar",
                                    action: onCollapseSidebar)
            }
        }
        .frame(height: 30)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No projects yet")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Add a local or SSH project to start.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
    }

    private var addProjectButton: some View {
        Menu {
            Button {
                store.addLocalProjectViaPicker()
            } label: {
                Label("Local folder", systemImage: "folder.badge.plus")
            }
            Button {
                store.showSSHProjectSheet = true
            } label: {
                Label("SSH remote...", systemImage: "terminal")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                Text("Add project")
                    .font(.system(size: 12))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(.secondary)
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var settingsBar: some View {
        Button {
            store.showProfilesSheet = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "gearshape")
                    .font(.system(size: 14, weight: .medium))
                Text("Settings")
                    .font(.system(size: 12.5, weight: .medium))
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.leading, 16)
            .padding(.trailing, 12)
            .frame(height: 42)
            .background(
                RoundedRectangle(cornerRadius: DS.cornerRadiusSmall)
                    .fill(settingsHovered ? Color.helmHover : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .onHover { settingsHovered = $0 }
        .help("Profiles & vendor settings")
    }
}

private struct ProjectSection: View {
    @Environment(AppStore.self) private var store
    let project: Project
    let isDragging: Bool
    let dropPlacement: ProjectDropPlacement?
    var onDragChanged: (DragGesture.Value) -> Void
    var onDragEnded: (DragGesture.Value) -> Void

    @State private var hoveredSessionId: UUID?
    @State private var pendingDelete: Session?
    @State private var pendingRename: Session?
    @State private var renameTitle = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            header
            if !project.collapsed {
                ForEach(store.sessions(in: project.id)) { s in
                    Button {
                        store.selectedSessionId = s.id
                    } label: {
                        SessionRow(
                            session: s,
                            isActive: s.id == store.selectedSessionId,
                            isHovered: hoveredSessionId == s.id
                        )
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        hoveredSessionId = hovering ? s.id : (hoveredSessionId == s.id ? nil : hoveredSessionId)
                    }
                    .contextMenu {
                        Button {
                            beginRename(s)
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        Button {
                            copyToPasteboard(s.id.uuidString.lowercased())
                        } label: {
                            Label("Copy Helm ID", systemImage: "doc.on.doc")
                        }
                        if let vendorSessionId = s.vendorSessionId {
                            Button {
                                copyToPasteboard(vendorSessionId)
                            } label: {
                                Label("Copy Vendor ID", systemImage: "terminal")
                            }
                        }
                        Divider()
                        Button(role: .destructive) {
                            pendingDelete = s
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .disabled(store.isSessionStreaming(s.id))
                    }
                }
            }
        }
        .opacity(isDragging ? 0.28 : 1)
        .scaleEffect(isDragging ? 0.985 : 1, anchor: .center)
        .background(alignment: .top) {
            if isDragging {
                ProjectDragPlaceholder()
                    .padding(.horizontal, 6)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.86), value: isDragging)
        .overlay(alignment: dropPlacement == .before ? .top : .bottom) {
            if let dropPlacement {
                ProjectDropIndicator()
                    .padding(.horizontal, 14)
                    .offset(y: dropPlacement == .before ? -2 : 2)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.interactiveSpring(response: 0.16, dampingFraction: 0.84), value: dropPlacement)
        .alert("Delete session?", isPresented: deleteBinding) {
            Button("Delete", role: .destructive) {
                if let pendingDelete {
                    store.deleteSession(pendingDelete.id)
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
        } message: {
            Text("This removes the conversation from Helm's sidebar. Vendor history files are left untouched.")
        }
        .alert("Rename session", isPresented: renameBinding) {
            TextField("Session title", text: $renameTitle)
            Button("Rename") {
                if let pendingRename {
                    store.renameSession(pendingRename.id, title: renameTitle)
                }
                pendingRename = nil
            }
            .disabled(renameTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {
                pendingRename = nil
            }
        } message: {
            Text("Choose a short title for this session.")
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Button {
                store.toggleCollapsed(project.id)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: project.collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)
                    Text(project.name.uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(.secondary)
                    locationLabel
                    Spacer()
                }
                .contentShape(Rectangle())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(project.name)
                .accessibilityValue(project.collapsed ? "collapsed" : "expanded")
                .accessibilityHint(project.collapsed ? "Expand project" : "Collapse project")
            }
            .buttonStyle(.plain)

            sshRetryButton

            Button {
                if store.newSession(in: project.id) == nil {
                    store.showProfilesSheet = true
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New chat in \(project.name)")
            .accessibilityLabel("New chat in \(project.name)")
        }
        .padding(.vertical, 4)
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .contentShape(Rectangle())
        .background(ProjectHeaderFrameReader(projectId: project.id))
        .simultaneousGesture(projectDragGesture)
    }

    private var projectDragGesture: some Gesture {
        DragGesture(minimumDistance: 4,
                    coordinateSpace: .named(SidebarCoordinateSpace.projectList))
            .onChanged(onDragChanged)
            .onEnded(onDragEnded)
    }

    @ViewBuilder
    private var sshRetryButton: some View {
        if case .ssh(_, _, let status) = project.location {
            Button {
                store.retrySSHProject(project.id)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(status.isConnected ? .tertiary : .secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(status.isConnecting)
            .opacity(status.isConnecting ? 0.45 : 1)
            .help("Check SSH connection")
            .accessibilityLabel("Check SSH connection for \(project.name)")
        }
    }

    private var deleteBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    private var renameBinding: Binding<Bool> {
        Binding(
            get: { pendingRename != nil },
            set: { if !$0 { pendingRename = nil } }
        )
    }

    private func beginRename(_ session: Session) {
        renameTitle = session.title
        pendingRename = session
    }

    private func copyToPasteboard(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    @ViewBuilder
    private var locationLabel: some View {
        switch project.location {
        case .local:
            HStack(spacing: 3) {
                Image(systemName: "folder")
                    .font(.system(size: 9))
                Text("local")
                    .font(.system(size: 10))
            }
            .foregroundStyle(.tertiary)
        case .ssh(let host, _, let status):
            HStack(spacing: 4) {
                if status.isConnecting {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.45)
                        .frame(width: 7, height: 7)
                } else {
                    Circle()
                        .fill(status.color)
                        .frame(width: 6, height: 6)
                }
                Text("ssh \(host)")
                    .font(.system(size: 10))
            }
            .foregroundStyle(.tertiary)
            .help(status.helpText)
        }
    }
}

private enum ProjectDropPlacement {
    case before
    case after
}

private struct ProjectDropIndicator: View {
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.accentColor.opacity(0.78))
                .frame(width: 5, height: 5)
            Capsule()
                .fill(Color.accentColor.opacity(0.70))
                .frame(height: 2)
        }
            .shadow(color: Color.accentColor.opacity(0.12), radius: 3, x: 0, y: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct ProjectDragPlaceholder: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(0.035))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.helmBorderStrong.opacity(0.45), lineWidth: 0.5)
            )
            .frame(height: 28)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct ProjectDragPreview: View {
    let project: Project

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: project.collapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 10)
            Text(project.name.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            locationChip
            Spacer(minLength: 0)
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 30)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.helmBorderStrong.opacity(0.72), lineWidth: 0.5)
        )
        .opacity(0.86)
        .shadow(color: Color.primary.opacity(0.10), radius: 9, x: 0, y: 5)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var locationChip: some View {
        switch project.location {
        case .local:
            HStack(spacing: 3) {
                Image(systemName: "folder")
                    .font(.system(size: 9))
                Text("local")
                    .font(.system(size: 10))
            }
                .foregroundStyle(.tertiary)
        case .ssh(let host, _, let status):
            HStack(spacing: 4) {
                Circle()
                    .fill(status.color)
                    .frame(width: 6, height: 6)
                Text(host)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }
}

private enum SidebarCoordinateSpace {
    static let projectList = "sidebarProjectList"
}

private struct ProjectHeaderFrameReader: View {
    let projectId: UUID

    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: ProjectHeaderFramePreferenceKey.self,
                value: [projectId: proxy.frame(in: .named(SidebarCoordinateSpace.projectList))]
            )
        }
    }
}

private struct ProjectHeaderFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct SessionRow: View {
    @Environment(AppStore.self) private var store
    let session: Session
    let isActive: Bool
    let isHovered: Bool

    var body: some View {
        let profile = store.profile(session.profileId)
        let isRunning = store.isSessionStreaming(session.id)
        return HStack(spacing: 8) {
            if let profile {
                VendorBadge(vendor: profile.vendor)
                    .frame(width: 18, height: 18)
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: 18, height: 18)
            }
            Text(session.title)
                .font(.system(size: 12.5, weight: isActive ? .semibold : .regular))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if isRunning {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.82)
                    .frame(width: 16, height: 16)
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: DS.cornerRadiusSmall)
                .fill(background)
        )
        .contentShape(Rectangle())
        .help(isRunning ? "Conversation is running" : session.title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(session.title)
        .accessibilityValue(isRunning ? "running" : "")
        .accessibilityHint(isRunning ? "Conversation is running" : "Open conversation")
    }

    private var background: Color {
        if isActive { return Color.helmSelected }
        if isHovered { return Color.helmHover }
        return Color.clear
    }
}

struct VendorBadge: View {
    let vendor: Vendor

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(vendor.badgeColor)
            Text(vendor.shortLabel)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
        }
    }
}

private struct SSHProjectSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var path = "~"
    @State private var name = ""
    @State private var knownHosts: [String] = []
    @State private var testStatus: SSHStatus?
    @State private var isTestingConnection = false
    @State private var directories: [String] = []
    @State private var directoryError: String?
    @State private var isLoadingDirectory = false
    @State private var browseTask: Task<Void, Never>?
    @State private var lastBrowsedHost = ""
    @State private var lastBrowsedPath = ""
    @State private var userEditedName = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("SSH project")
                .font(.system(size: 18, weight: .semibold))

            VStack(alignment: .leading, spacing: 10) {
                hostPicker
                remotePathField
                directoryBrowser
                nameField
                connectionStatus
            }

            HStack {
                Button("Test") {
                    testConnection()
                }
                .disabled(!canAdd || isTestingConnection)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    if store.addSSHProject(host: host, path: path, name: name) != nil {
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdd || isTestingConnection)
            }
        }
        .padding(22)
        .frame(width: 560)
        .onAppear {
            knownHosts = SSHConfigHosts.load()
            if host.isEmpty, let first = knownHosts.first {
                host = first
                if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    name = first
                }
            }
            scheduleDirectoryBrowse(debounce: false)
        }
        .onDisappear {
            browseTask?.cancel()
        }
        .onChange(of: host) { _, _ in
            resetTestStatus()
            scheduleDirectoryBrowse()
        }
        .onChange(of: path) { _, _ in
            resetTestStatus()
            syncDefaultNameIfNeeded()
            scheduleDirectoryBrowse()
        }
        .onChange(of: name) { _, newValue in
            userEditedName = !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                newValue != defaultName
        }
    }

    private var canAdd: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var defaultName: String {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = (p as NSString).lastPathComponent
        guard !h.isEmpty, !tail.isEmpty, tail != "~" else { return h.isEmpty ? "Project name" : h }
        return "\(h):\(tail)"
    }

    private var nameField: some View {
        labeledField("Name", text: $name, prompt: defaultName)
    }

    private var canBrowse: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canGoToParentDirectory: Bool {
        let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return !p.isEmpty && p != "/" && p != "~"
    }

    private var hostPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Host")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Menu {
                if knownHosts.isEmpty {
                    Text("No hosts in ~/.ssh/config")
                } else {
                    ForEach(knownHosts, id: \.self) { host in
                        Button(host) {
                            selectHost(host)
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 13, weight: .medium))
                    Text(host.isEmpty ? "No known hosts" : host)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(host.isEmpty ? .tertiary : .primary)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: DS.cornerRadiusSmall, style: .continuous)
                        .fill(Color.helmCard)
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.cornerRadiusSmall, style: .continuous)
                                .stroke(Color.helmBorderStrong.opacity(0.55), lineWidth: 1)
                        )
                )
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .disabled(knownHosts.isEmpty)
            .accessibilityLabel("Host")
            .accessibilityValue(host.isEmpty ? "No known hosts" : host)
        }
    }

    private var remotePathField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Remote path")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button {
                    goToParentDirectory()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(canGoToParentDirectory ? .secondary : .tertiary)
                .disabled(!canGoToParentDirectory)
                .help("Parent directory")
                .accessibilityLabel("Parent directory")

                TextField("~/workspace/repo", text: $path)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        scheduleDirectoryBrowse(debounce: false, force: true)
                    }

                Button {
                    scheduleDirectoryBrowse(debounce: false, force: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(!canBrowse || isLoadingDirectory)
                .help("Refresh directories")
                .accessibilityLabel("Refresh directories")
            }
        }
    }

    private var directoryBrowser: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: DS.cornerRadius, style: .continuous)
                .fill(Color.helmCard.opacity(0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.cornerRadius, style: .continuous)
                        .stroke(Color.helmBorderStrong.opacity(0.55), lineWidth: 1)
                )

            directoryBrowserContent
                .padding(8)
        }
        .frame(height: 210)
    }

    @ViewBuilder
    private var directoryBrowserContent: some View {
        if !canBrowse {
            browserMessage(symbolName: "server.rack",
                           text: "Choose a host to browse remote folders.",
                           foreground: .secondary)
        } else if isLoadingDirectory {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading directories...")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let directoryError {
            browserMessage(symbolName: "exclamationmark.triangle",
                           text: directoryError,
                           foreground: .red)
        } else if directories.isEmpty {
            browserMessage(symbolName: "folder",
                           text: "No directories in this path.",
                           foreground: .secondary)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(directories, id: \.self) { directory in
                        Button {
                            openDirectory(directory)
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: "folder")
                                    .font(.system(size: 13, weight: .regular))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18)
                                Text(directory)
                                    .font(.system(size: 12.5))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 28)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func browserMessage(symbolName: String,
                                text: String,
                                foreground: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbolName)
                .font(.system(size: 13, weight: .medium))
            Text(text)
                .font(.system(size: 12))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(foreground)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var connectionStatus: some View {
        if isTestingConnection {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Testing connection...")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        } else if let testStatus {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(testStatus.color)
                    .frame(width: 7, height: 7)
                    .padding(.top, 4)
                Text(statusText(testStatus))
                    .font(.system(size: 12))
                    .foregroundStyle(statusForeground(testStatus))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)
        }
    }

    private func statusText(_ status: SSHStatus) -> String {
        switch status {
        case .connected(let path):
            return path.isEmpty ? "Connected" : "Connected: \(path)"
        case .connecting:
            return "Testing connection..."
        case .failed(let reason):
            return "Failed: \(reason)"
        }
    }

    private func statusForeground(_ status: SSHStatus) -> Color {
        switch status {
        case .connected: return .secondary
        case .connecting: return .secondary
        case .failed: return .red
        }
    }

    private func resetTestStatus() {
        if !isTestingConnection {
            testStatus = nil
        }
    }

    private func selectHost(_ host: String) {
        guard self.host != host else { return }
        self.host = host
        path = "~"
        directories = []
        directoryError = nil
        lastBrowsedHost = ""
        lastBrowsedPath = ""
        resetTestStatus()
        syncDefaultNameIfNeeded()
    }

    private func syncDefaultNameIfNeeded() {
        if !userEditedName {
            name = defaultName
        }
    }

    private func scheduleDirectoryBrowse(debounce: Bool = true, force: Bool = false) {
        browseTask?.cancel()

        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !path.isEmpty else {
            directories = []
            directoryError = nil
            isLoadingDirectory = false
            return
        }

        if !force, host == lastBrowsedHost, path == lastBrowsedPath {
            return
        }

        isLoadingDirectory = true
        directoryError = nil
        browseTask = Task {
            if debounce {
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
            }

            do {
                let listing = try await SSHDirectoryBrowser.list(host: host, path: path)
                guard !Task.isCancelled,
                      self.host.trimmingCharacters(in: .whitespacesAndNewlines) == host,
                      self.path.trimmingCharacters(in: .whitespacesAndNewlines) == path
                else { return }

                directories = listing.directories
                directoryError = nil
                isLoadingDirectory = false
                if !listing.resolvedPath.isEmpty {
                    lastBrowsedHost = host
                    lastBrowsedPath = listing.resolvedPath
                    if listing.resolvedPath != path {
                        self.path = listing.resolvedPath
                    }
                } else {
                    lastBrowsedHost = host
                    lastBrowsedPath = path
                }
            } catch {
                guard !Task.isCancelled,
                      self.host.trimmingCharacters(in: .whitespacesAndNewlines) == host,
                      self.path.trimmingCharacters(in: .whitespacesAndNewlines) == path
                else { return }

                directories = []
                directoryError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                isLoadingDirectory = false
            }
        }
    }

    private func openDirectory(_ directory: String) {
        let base = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty || base == "." {
            path = directory
        } else if base == "/" {
            path = "/" + directory
        } else if base.hasSuffix("/") {
            path = base + directory
        } else {
            path = base + "/" + directory
        }
    }

    private func goToParentDirectory() {
        let current = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty, current != "/" else { return }

        if current.hasPrefix("~/") {
            let parent = (current as NSString).deletingLastPathComponent
            path = parent.isEmpty || parent == "." ? "~" : parent
            return
        }

        let parent = (current as NSString).deletingLastPathComponent
        path = parent.isEmpty ? "/" : parent
    }

    private func testConnection() {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !path.isEmpty else { return }
        testStatus = nil
        isTestingConnection = true

        Task {
            let status = await SSHProbe.check(host: host, path: path)
            guard self.host.trimmingCharacters(in: .whitespacesAndNewlines) == host,
                  self.path.trimmingCharacters(in: .whitespacesAndNewlines) == path
            else {
                isTestingConnection = false
                return
            }
            testStatus = status
            isTestingConnection = false
        }
    }

    private func labeledField(_ title: String,
                              text: Binding<String>,
                              prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }
}

private enum SSHConfigHosts {
    static func load() -> [String] {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".ssh", isDirectory: true)
            .appendingPathComponent("config", isDirectory: false)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }

        var hosts: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let withoutComment = rawLine.split(separator: "#", maxSplits: 1).first ?? ""
            let parts = withoutComment
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2,
                  parts[0].lowercased() == "host"
            else { continue }

            for part in parts.dropFirst() {
                let host = String(part)
                if isConcreteHost(host) {
                    hosts.append(host)
                }
            }
        }
        return Array(NSOrderedSet(array: hosts)) as? [String] ?? hosts
    }

    private static func isConcreteHost(_ host: String) -> Bool {
        !host.contains("*") &&
        !host.contains("?") &&
        !host.contains("!") &&
        !host.contains("[")
    }
}
