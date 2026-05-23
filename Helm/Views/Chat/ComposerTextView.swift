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
    @Binding var skillChips: [ComposerSkill]
    let placeholder: String
    let minLines: Int
    let maxLines: Int
    let focusRequest: Int
    let skillInsertionRequest: ComposerSkillInsertionRequest?
    let onKeyDown: (NSEvent) -> Bool
    let onTextCommand: (ComposerTextCommand) -> Bool
    let onSlashContextChange: (ComposerSlashContext?) -> Void
    let onSend: () -> Void

    static let font = NSFont.systemFont(ofSize: 13.5)
    private static let inset = NSSize(width: 4, height: 4)
    static let attachmentPlaceholder = "\u{fffc}"

    func makeNSView(context: Context) -> NSScrollView {
        let tv = PlaceholderTextView()
        tv.delegate = context.coordinator
        tv.font = Self.font
        tv.isRichText = true
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.textContainerInset = Self.inset
        tv.typingAttributes = Self.plainTextAttributes
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
        tv.onSlashContextChange = onSlashContextChange
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
        if tv.string != text || tv.skillChips() != skillChips {
            tv.setComposerText(text, skillChips: skillChips)
        }
        tv.placeholder = placeholder
        tv.onKeyDown = onKeyDown
        tv.onTextCommand = onTextCommand
        tv.onSlashContextChange = onSlashContextChange
        tv.onCommandReturn = onSend
        var insertedSkill = false
        if let skillInsertionRequest,
           context.coordinator.consumeSkillInsertionRequest(skillInsertionRequest.id) {
            tv.insertSkillChip(skillInsertionRequest.skill)
            insertedSkill = true
        }
        if context.coordinator.consumeFocusRequest(focusRequest) {
            context.coordinator.focus(tv, moveCursorToEnd: !insertedSkill)
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
        private var lastSkillInsertionRequest: UUID?

        init(_ p: ComposerTextView) {
            self.parent = p
            self.lastFocusRequest = p.focusRequest
        }

        func textDidChange(_ note: Notification) {
            guard let tv = note.object as? PlaceholderTextView else { return }
            tv.typingAttributes = ComposerTextView.plainTextAttributes
            parent.text = tv.string
            parent.skillChips = tv.skillChips()
            parent.onSlashContextChange(tv.currentSlashContext())
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? PlaceholderTextView else { return }
            parent.onSlashContextChange(tv.currentSlashContext())
        }

        func consumeFocusRequest(_ request: Int) -> Bool {
            guard request != lastFocusRequest else { return false }
            lastFocusRequest = request
            return true
        }

        func consumeSkillInsertionRequest(_ request: UUID) -> Bool {
            guard request != lastSkillInsertionRequest else { return false }
            lastSkillInsertionRequest = request
            return true
        }

        func focus(_ tv: NSTextView, moveCursorToEnd: Bool) {
            DispatchQueue.main.async { [weak tv] in
                guard let tv else { return }
                self.focusWhenWindowIsReady(tv, moveCursorToEnd: moveCursorToEnd)
            }
        }

        private func focusWhenWindowIsReady(_ tv: NSTextView,
                                            moveCursorToEnd: Bool,
                                            retry: Bool = true) {
            if moveCursorToEnd {
                tv.selectedRange = NSRange(location: tv.string.utf16.count, length: 0)
            }
            if let window = tv.window {
                window.makeFirstResponder(tv)
            } else if retry {
                DispatchQueue.main.async { [weak tv] in
                    guard let tv else { return }
                    self.focusWhenWindowIsReady(tv,
                                                moveCursorToEnd: moveCursorToEnd,
                                                retry: false)
                }
            }
        }
    }

    static var plainTextAttributes: [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ]
    }
}

enum ComposerTextCommand {
    case moveUp
    case moveDown
    case accept
    case complete
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
    var onSlashContextChange: (ComposerSlashContext?) -> Void = { _ in }

    func setComposerText(_ text: String, skillChips: [ComposerSkill]) {
        let selectedRange = selectedRange()
        let attributed = NSMutableAttributedString()
        var chipIndex = 0
        for character in text {
            if String(character) == ComposerTextView.attachmentPlaceholder,
               chipIndex < skillChips.count {
                attributed.append(Self.skillAttachmentString(for: skillChips[chipIndex]))
                chipIndex += 1
            } else {
                attributed.append(NSAttributedString(string: String(character),
                                                     attributes: ComposerTextView.plainTextAttributes))
            }
        }
        textStorage?.setAttributedString(attributed)
        typingAttributes = ComposerTextView.plainTextAttributes
        self.selectedRange = NSRange(location: min(selectedRange.location, attributed.length), length: 0)
        needsDisplay = true
    }

    func insertSkillChip(_ skill: ComposerSkill) {
        let replacementRange = currentSlashContext()?.range ?? selectedRange()
        let insertion = NSMutableAttributedString()
        insertion.append(Self.skillAttachmentString(for: skill))
        insertion.append(NSAttributedString(string: " ", attributes: ComposerTextView.plainTextAttributes))

        guard shouldChangeText(in: replacementRange, replacementString: insertion.string) else { return }
        textStorage?.replaceCharacters(in: replacementRange, with: insertion)
        didChangeText()
        selectedRange = NSRange(location: replacementRange.location + insertion.length, length: 0)
        typingAttributes = ComposerTextView.plainTextAttributes
        onSlashContextChange(currentSlashContext())
    }

    func skillChips() -> [ComposerSkill] {
        guard let storage = textStorage else { return [] }
        var chips: [ComposerSkill] = []
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.attachment, in: fullRange) { value, _, _ in
            if let attachment = value as? ComposerSkillTextAttachment {
                chips.append(attachment.skill)
            }
        }
        return chips
    }

    func currentSlashContext() -> ComposerSlashContext? {
        let selected = selectedRange()
        guard selected.length == 0 else { return nil }

        let value = string as NSString
        let location = min(selected.location, value.length)
        var start = location
        while start > 0 {
            let scalar = value.character(at: start - 1)
            if Self.isTokenBoundary(scalar) {
                break
            }
            start -= 1
        }

        let range = NSRange(location: start, length: location - start)
        guard range.length > 0 else { return nil }
        let token = value.substring(with: range)
        guard token.hasPrefix("/") else { return nil }
        let rawQuery = String(token.dropFirst())
        guard rawQuery.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            return nil
        }
        return ComposerSlashContext(rawQuery: rawQuery,
                                    query: ComposerSkill.normalizedSearchText(rawQuery),
                                    range: range)
    }

    private static func isTokenBoundary(_ scalar: unichar) -> Bool {
        if scalar == 0xfffc { return true }
        guard let unicodeScalar = UnicodeScalar(Int(scalar)) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(unicodeScalar)
    }

    private static func skillAttachmentString(for skill: ComposerSkill) -> NSAttributedString {
        let attachment = ComposerSkillTextAttachment(skill: skill)
        return NSAttributedString(attachment: attachment)
    }

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
        if onTextCommand(.complete) {
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

    override func deleteBackward(_ sender: Any?) {
        if deleteSkillChipBackward() {
            return
        }
        super.deleteBackward(sender)
    }

    private func deleteSkillChipBackward() -> Bool {
        let selected = selectedRange()
        guard selected.length == 0,
              selected.location > 0,
              let storage = textStorage
        else { return false }

        let location = min(selected.location, storage.length)
        guard location > 0 else { return false }

        var range = NSRange(location: location - 1, length: 1)
        let value = string as NSString
        if value.character(at: range.location) != 0xfffc {
            guard let scalar = UnicodeScalar(Int(value.character(at: range.location))),
                  CharacterSet.whitespaces.contains(scalar),
                  range.location > 0,
                  value.character(at: range.location - 1) == 0xfffc
            else { return false }
            range = NSRange(location: range.location - 1, length: 2)
        }

        guard shouldChangeText(in: range, replacementString: "") else { return false }
        storage.replaceCharacters(in: range, with: "")
        didChangeText()
        selectedRange = NSRange(location: range.location, length: 0)
        onSlashContextChange(currentSlashContext())
        return true
    }
}

struct ComposerSlashContext: Equatable {
    let rawQuery: String
    let query: String
    let range: NSRange

    var signature: String {
        "\(range.location):\(range.length):\(rawQuery)"
    }
}

struct ComposerSkillInsertionRequest: Equatable {
    let id = UUID()
    let skill: ComposerSkill
}

private final class ComposerSkillTextAttachment: NSTextAttachment {
    let skill: ComposerSkill

    init(skill: ComposerSkill) {
        self.skill = skill
        super.init(data: nil, ofType: nil)
        let image = ComposerSkillChipRenderer.image(for: skill)
        self.image = image
        self.bounds = NSRect(x: 0, y: -6, width: image.size.width, height: image.size.height)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

private enum ComposerSkillChipRenderer {
    private static let height: CGFloat = 26

    static func image(for skill: ComposerSkill) -> NSImage {
        let nameAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]
        let sourceAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]

        let name = "/\(skill.name)" as NSString
        let source = skill.source as NSString
        let nameSize = name.size(withAttributes: nameAttributes)
        let sourceSize = source.size(withAttributes: sourceAttributes)
        let width = min(300, 10 + 13 + 7 + nameSize.width + 8 + sourceSize.width + 10)
        let image = NSImage(size: NSSize(width: width, height: height))

        image.lockFocus()
        NSColor.controlAccentColor.withAlphaComponent(0.13).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0.5, y: 0.5, width: width - 1, height: height - 1),
                     xRadius: height / 2,
                     yRadius: height / 2).fill()
        NSColor.separatorColor.withAlphaComponent(0.55).setStroke()
        NSBezierPath(roundedRect: NSRect(x: 0.5, y: 0.5, width: width - 1, height: height - 1),
                     xRadius: height / 2,
                     yRadius: height / 2).stroke()

        if let sparkle = NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil) {
            sparkle.withSymbolConfiguration(.init(pointSize: 11.5, weight: .semibold))?
                .draw(in: NSRect(x: 10, y: 6.5, width: 13, height: 13),
                      from: .zero,
                      operation: .sourceOver,
                      fraction: 1)
        }

        var x: CGFloat = 30
        name.draw(at: NSPoint(x: x, y: 5.4), withAttributes: nameAttributes)
        x += nameSize.width + 8
        let remaining = width - x - 10
        if remaining > 12 {
            source.draw(with: NSRect(x: x, y: 6.1, width: remaining, height: sourceSize.height),
                        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                        attributes: sourceAttributes)
        }
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
