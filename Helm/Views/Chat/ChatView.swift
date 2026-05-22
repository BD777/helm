import SwiftUI

struct ChatView: View {
    @Environment(AppStore.self) private var store
    @State private var composerFocusRequest = 0

    var body: some View {
        VStack(spacing: 0) {
            ChatToolbar()
            Divider()
            MessageListView {
                requestComposerFocus()
            }
            ComposerView(externalFocusRequest: composerFocusRequest)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.helmChatBg)
    }

    private func requestComposerFocus() {
        composerFocusRequest += 1
    }
}
