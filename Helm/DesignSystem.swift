import SwiftUI

enum DS {
    static let sidebarWidth: CGFloat = 280
    static let messageMaxWidth: CGFloat = 760
    static let windowMinWidth: CGFloat = 560
    static let windowMinHeight: CGFloat = 520
    static let sidebarAutoHideWidth: CGFloat = 820
    static let cornerRadius: CGFloat = 8
    static let cornerRadiusSmall: CGFloat = 6
    static let cornerRadiusLarge: CGFloat = 12

    static let monoFont: Font = .system(size: 12, design: .monospaced)
    static let monoFontSmall: Font = .system(size: 11, design: .monospaced)
}

extension Color {
    static let helmSidebarBg = Color(nsColor: .windowBackgroundColor)
    static let helmChatBg    = Color(nsColor: .textBackgroundColor)
    static let helmCard      = Color(nsColor: .controlBackgroundColor)
    static let helmBorder    = Color.primary.opacity(0.10)
    static let helmBorderStrong = Color.primary.opacity(0.18)
    static let helmText2     = Color.secondary
    static let helmText3     = Color.secondary.opacity(0.7)
    static let helmHover     = Color.primary.opacity(0.05)
    static let helmSelected  = Color.accentColor.opacity(0.15)

    static let helmDiffAdd = Color.green.opacity(0.12)
    static let helmDiffDel = Color.red.opacity(0.12)
}
