import SwiftUI

struct EmptyChatView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(.tertiary)
            Text("No conversation selected")
                .font(.system(size: 18, weight: .semibold))
            Text("Pick a session on the left, or press ⌘N to start a new conversation.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            HStack(spacing: 8) {
                Button("+ New chat") { }
                    .buttonStyle(.borderedProminent)
                Button("Add project") { }
                    .buttonStyle(.bordered)
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.helmChatBg)
    }
}
