import SwiftUI

struct EmptyChatView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(.tertiary)
            Text(store.projects.isEmpty ? "No projects yet" : "No conversation selected")
                .font(.system(size: 18, weight: .semibold))
            Text(store.projects.isEmpty
                 ? "Add a project folder, then start a conversation in it."
                 : "Pick a session on the left, or start a new conversation in a project.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            HStack(spacing: 8) {
                if store.projects.isEmpty {
                    Button("Add project") {
                        store.addLocalProjectViaPicker()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Menu {
                        ForEach(store.projects) { project in
                            Button {
                                if store.newSession(in: project.id) == nil {
                                    store.showProfilesSheet = true
                                }
                            } label: {
                                Label(project.name, systemImage: iconName(for: project))
                            }
                        }
                    } label: {
                        Label("New chat", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Add project") {
                        store.addLocalProjectViaPicker()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.helmChatBg)
    }

    private func iconName(for project: Project) -> String {
        switch project.location {
        case .local:
            return "folder"
        case .ssh:
            return "terminal"
        }
    }
}
