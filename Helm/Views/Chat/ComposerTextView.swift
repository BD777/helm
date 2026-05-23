import AppKit
import SwiftUI

/// Multi-line composer text input.
///
/// Why not TextEditor / TextField:
/// - TextEditor's overlay placeholder can't tell when the user is in IME
///   composition (marked text isn't in the bound `String`, so `text.isEmpty`
///   stays true and the placeholder lingers behind the composing characters).
/// - TextField with `axis: .vertical` on macOS treats plain Return as
///   onSubmit (the field commits and grabs select-all focus) instead of
///   inserting a newline. Option+Return becomes the only way to break a line.
///
/// This wrapper drops down to NSTextView, which has the right defaults
/// (Return → newline, AppKit-managed IME) and lets us forward ⌘+Return to a
/// send callback.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let minLines: Int
    let maxLines: Int
    let focusRequest: Int
    let onKeyDown: (NSEvent) -> Bool
    let onTextCommand: (ComposerTextCommand) -> Bool
    let onSend: () -> Void

    static let font = NSFont.systemFont(ofSize: 13.5)
    private static let inset = NSSize(width: 4, height: 4)

    func makeNSView(context: Context) -> NSScrollView {
        let tv = PlaceholderTextView()
        tv.delegate = context.coordinator
        tv.font = Self.font
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.textContainerInset = Self.inset
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        tv.placeholder = placeholder
        tv.onKeyDown = onKeyDown
        tv.onTextCommand = onTextCommand
        tv.onCommandReturn = onSend

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? PlaceholderTextView else { return }
        if tv.string != text { tv.string = text }
        tv.placeholder = placeholder
        tv.onKeyDown = onKeyDown
        tv.onTextCommand = onTextCommand
        tv.onCommandReturn = onSend
        if context.coordinator.consumeFocusRequest(focusRequest) {
            context.coordinator.focus(tv)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let tv = nsView.documentView as? PlaceholderTextView,
              let lm = tv.layoutManager,
              let tc = tv.textContainer else { return nil }
        // SwiftUI passes nil for an unconstrained dimension on early layout
        // passes. Fall back to the view's resolved bounds so we don't lock
        // the textContainer to a tiny default and wrap text mid-line.
        let width: CGFloat = {
            if let w = proposal.width, w.isFinite, w > 0 { return w }
            if nsView.bounds.width > 0 { return nsView.bounds.width }
            return 600
        }()
        let textWidth = max(0, width - tv.textContainerInset.width * 2)
        if tc.size.width != textWidth {
            tc.size = NSSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude)
        }
        lm.ensureLayout(for: tc)
        let lineHeight = lm.defaultLineHeight(for: Self.font)
        let chrome = tv.textContainerInset.height * 2
        let minH = lineHeight * CGFloat(minLines) + chrome
        let maxH = lineHeight * CGFloat(maxLines) + chrome
        let used = lm.usedRect(for: tc).height + chrome
        return CGSize(width: width, height: max(minH, min(maxH, used)))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        private var lastFocusRequest: Int

        init(_ p: ComposerTextView) {
            self.parent = p
            self.lastFocusRequest = p.focusRequest
        }

        func textDidChange(_ note: Notification) {
            guard let tv = note.object as? NSTextView else { return }
            parent.text = tv.string
        }

        func consumeFocusRequest(_ request: Int) -> Bool {
            guard request != lastFocusRequest else { return false }
            lastFocusRequest = request
            return true
        }

        func focus(_ tv: NSTextView) {
            DispatchQueue.main.async { [weak tv] in
                guard let tv else { return }
                self.focusWhenWindowIsReady(tv)
            }
        }

        private func focusWhenWindowIsReady(_ tv: NSTextView, retry: Bool = true) {
            tv.selectedRange = NSRange(location: tv.string.utf16.count, length: 0)
            if let window = tv.window {
                window.makeFirstResponder(tv)
            } else if retry {
                DispatchQueue.main.async { [weak tv] in
                    guard let tv else { return }
                    self.focusWhenWindowIsReady(tv, retry: false)
                }
            }
        }
    }
}

enum ComposerTextCommand {
    case moveUp
    case moveDown
    case accept
    case cancel
}

/// NSTextView with a placeholder string and ⌘+Return forwarding.
final class PlaceholderTextView: NSTextView {
    var placeholder: String = "" {
        didSet {
            if oldValue != placeholder {
                needsDisplay = true
            }
        }
    }
    var onCommandReturn: () -> Void = {}
    var onKeyDown: (NSEvent) -> Bool = { _ in false }
    var onTextCommand: (ComposerTextCommand) -> Bool = { _ in false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Hide while the user is mid-IME composition — `string` is still
        // empty during marked-text composition, so checking only `isEmpty`
        // would leave the placeholder visible behind the composing chars.
        guard string.isEmpty, !hasMarkedText() else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 13.5),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let origin = NSPoint(
            x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0),
            y: textContainerInset.height
        )
        (placeholder as NSString).draw(at: origin, withAttributes: attrs)
    }

    override func keyDown(with event: NSEvent) {
        if onKeyDown(event) {
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 36, flags == .command {
            onCommandReturn()
            return
        }
        super.keyDown(with: event)
    }

    override func moveUp(_ sender: Any?) {
        if onTextCommand(.moveUp) {
            return
        }
        super.moveUp(sender)
    }

    override func moveDown(_ sender: Any?) {
        if onTextCommand(.moveDown) {
            return
        }
        super.moveDown(sender)
    }

    override func insertNewline(_ sender: Any?) {
        if onTextCommand(.accept) {
            return
        }
        super.insertNewline(sender)
    }

    override func insertTab(_ sender: Any?) {
        if onTextCommand(.accept) {
            return
        }
        super.insertTab(sender)
    }

    override func cancelOperation(_ sender: Any?) {
        if onTextCommand(.cancel) {
            return
        }
        super.cancelOperation(sender)
    }
}
