import AppKit
import SwiftUI

struct SidebarView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        return VStack(spacing: 0) {
            toolbar
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    addProjectButton
                        .padding(.bottom, 2)
                    if store.projects.isEmpty {
                        emptyState
                    } else {
                        ForEach(store.projects) { project in
                            ProjectSection(project: project)
                        }
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, 12)
            }
        }
        .sheet(isPresented: $store.showProfilesSheet) {
            ProfilesSheet()
                .environment(store)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Spacer()

            Button {
                store.showProfilesSheet = true
            } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .help("Profiles & vendor settings")
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No projects yet")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Add a folder to start a conversation in it.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
    }

    private var addProjectButton: some View {
        Button {
            store.addLocalProjectViaPicker()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                Text("Add project (folder)")
                    .font(.system(size: 12))
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
            .buttonStyle(.plain)
    }
}

private struct ProjectSection: View {
    @Environment(AppStore.self) private var store
    let project: Project
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
                            copySessionId(s)
                        } label: {
                            Label("Copy ID", systemImage: "doc.on.doc")
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
        .padding(.horizontal, 8)
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

    private func copySessionId(_ session: Session) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(session.id.uuidString.lowercased(), forType: .string)
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
                Circle()
                    .fill(status.color)
                    .frame(width: 6, height: 6)
                Text("ssh \(host)")
                    .font(.system(size: 10))
            }
            .foregroundStyle(.tertiary)
            .help(sshHelp(status))
        }
    }

    private func sshHelp(_ s: SSHStatus) -> String {
        switch s {
        case .connected: return "Connected"
        case .connecting: return "Connecting..."
        case .failed(let r): return "Failed: \(r)"
        }
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
                    .controlSize(.mini)
                    .scaleEffect(0.55)
                    .frame(width: 12, height: 12)
            }
        }
        .padding(.horizontal, 8)
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
