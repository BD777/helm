import SwiftUI

struct SidebarView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        return VStack(spacing: 0) {
            toolbar
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if store.projects.isEmpty {
                        emptyState
                    } else {
                        ForEach(store.projects) { project in
                            ProjectSection(project: project)
                        }
                    }
                    addProjectButton
                        .padding(.top, 4)
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
            Button {
                newChat()
            } label: {
                Label("New", systemImage: "square.and.pencil")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(store.projects.isEmpty)
            .keyboardShortcut("n", modifiers: .command)
            .help("New conversation (⌘N)")

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

    /// New chat in the active session's project, or in the first project if
    /// nothing is selected. If no profile exists yet (so newSession would
    /// silently no-op), route the user to the profiles sheet instead.
    private func newChat() {
        let projectId = store.selectedSession?.projectId ?? store.projects.first?.id
        guard let projectId else { return }
        if store.newSession(in: projectId) == nil {
            store.showProfilesSheet = true
        }
    }
}

private struct ProjectSection: View {
    @Environment(AppStore.self) private var store
    let project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            header
            if !project.collapsed {
                ForEach(store.sessions(in: project.id)) { s in
                    SessionRow(session: s, isActive: s.id == store.selectedSessionId)
                        .onTapGesture { store.selectedSessionId = s.id }
                }
                newChatRow
            }
        }
    }

    private var header: some View {
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
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture { store.toggleCollapsed(project.id) }
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
        case .connecting: return "Connecting…"
        case .failed(let r): return "Failed: \(r)"
        }
    }

    private var newChatRow: some View {
        Button {
            if store.newSession(in: project.id) == nil {
                store.showProfilesSheet = true
            }
        } label: {
            Text("+ New chat in \(project.name)")
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SessionRow: View {
    @Environment(AppStore.self) private var store
    let session: Session
    let isActive: Bool

    var body: some View {
        let profile = store.profile(session.profileId)
        let model = profile.flatMap { store.model($0.primaryModelId) }
        let modelLabel = model?.label ?? "no model"
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
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .font(.system(size: 12.5, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(modelLabel).font(.system(size: 10.5))
                    Text("·").font(.system(size: 10.5))
                    if isRunning {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.55)
                            .frame(width: 10, height: 10)
                        Text("running").font(.system(size: 10.5))
                    } else {
                        Text(session.lastUpdate).font(.system(size: 10.5))
                    }
                }
                .foregroundStyle(isRunning ? .secondary : .tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: DS.cornerRadiusSmall)
                .fill(isActive ? Color.helmSelected : Color.clear)
        )
        .contentShape(Rectangle())
        .help(isRunning ? "Conversation is running" : session.title)
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
