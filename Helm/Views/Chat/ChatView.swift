import SwiftUI

struct ChatView: View {
    @Environment(AppStore.self) private var store
    @State private var composerFocusRequest = 0

    var body: some View {
        VStack(spacing: 0) {
            ChatToolbar()
                .zIndex(1)
            MessageListView {
                requestComposerFocus()
            }
            .overlay(alignment: .top) {
                headerEdgeFade
            }
            ComposerView(externalFocusRequest: composerFocusRequest + store.composerFocusTick)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.helmChatBg)
    }

    private func requestComposerFocus() {
        composerFocusRequest += 1
    }

    private var headerEdgeFade: some View {
        LinearGradient(
            stops: [
                .init(color: Color.helmChatBg, location: 0),
                .init(color: Color.helmChatBg.opacity(0.72), location: 0.42),
                .init(color: Color.helmChatBg.opacity(0), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 14)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
