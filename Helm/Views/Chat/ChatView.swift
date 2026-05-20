import SwiftUI

struct ChatView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            ChatToolbar()
            Divider()
            MessageListView()
            ComposerView()
        }
        .background(Color.helmChatBg)
    }
}

#Preview {
    ChatView()
        .environment(AppStore.demo())
        .frame(width: 900, height: 700)
}
