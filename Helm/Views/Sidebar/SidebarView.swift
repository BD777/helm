import SwiftUI

struct SidebarView: View {
    @Environment(AppStore.self) private var store
    @State private var search: String = ""

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            searchField
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(store.projects) { project in
                        ProjectSection(project: project)
                    }
                    addProjectButton
                        .padding(.top, 4)
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 12)
            }
        }
        .background(Color.helmSidebarBg)
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Button {
                // new chat
            } label: {
                Label("New", systemImage: "square.and.pencil")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help("New conversation (⌘N)")

            Spacer()

            Button {
                // refresh
            } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Refresh")
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            TextField("Search sessions…", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            Text("⌘K")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: DS.cornerRadiusSmall)
                .fill(Color.helmChatBg)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.cornerRadiusSmall)
                        .stroke(Color.helmBorder, lineWidth: 1)
                )
        )
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private var addProjectButton: some View {
        Button {
            // add project
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                Text("Add project (folder or SSH host)")
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
        .padding(.horizontal, 6)
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
            // new chat in this project
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
    let session: Session
    let isActive: Bool

    var body: some View {
        HStack(spacing: 8) {
            VendorBadge(vendor: session.vendor)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .font(.system(size: 12.5, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(session.model.lowercased()).font(.system(size: 10.5))
                    Text("·").font(.system(size: 10.5))
                    Text(session.lastUpdate).font(.system(size: 10.5))
                }
                .foregroundStyle(.tertiary)
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

#Preview {
    SidebarView()
        .environment(AppStore.demo())
        .frame(width: 280, height: 600)
}
