import SwiftUI

struct ComposerView: View {
    @Environment(AppStore.self) private var store
    @State private var text: String = ""
    @State private var pickerOpen: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(spacing: 0) {
                inner
            }
            .frame(maxWidth: DS.messageMaxWidth)
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color.helmChatBg)
    }

    private var inner: some View {
        VStack(spacing: 0) {
            TextEditor(text: $text)
                .font(.system(size: 13.5))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 24, maxHeight: 200)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Message Claude (⌘↵ to send, ⇧↵ for newline, / for slash commands)")
                            .font(.system(size: 13.5))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.top, 4)
            footer
        }
        .background(
            RoundedRectangle(cornerRadius: DS.cornerRadiusLarge)
                .fill(Color.helmCard)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.cornerRadiusLarge)
                        .stroke(Color.helmBorderStrong, lineWidth: 1)
                )
        )
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button { } label: {
                Image(systemName: "paperclip")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 4)

            Button { pickerOpen.toggle() } label: {
                if let s = store.selectedSession {
                    HStack(spacing: 6) {
                        VendorBadge(vendor: s.vendor).frame(width: 14, height: 14)
                        Text(s.model).font(.system(size: 12)).foregroundStyle(.secondary)
                        Image(systemName: "chevron.down").font(.system(size: 8)).foregroundStyle(.tertiary)
                    }
                }
            }
            .buttonStyle(.plain)
            .popover(isPresented: $pickerOpen, arrowEdge: .bottom) {
                ModelPickerMenu().frame(width: 320)
            }

            Spacer()

            Text("⌘↵")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)

            Button {
                if store.isStreaming {
                    store.isStreaming = false
                } else if !text.isEmpty {
                    text = ""
                    store.isStreaming = true
                }
            } label: {
                Text(store.isStreaming ? "Stop" : "Send")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        Capsule().fill(store.isStreaming ? Color.red : Color.accentColor)
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .padding(.top, 4)
    }
}
