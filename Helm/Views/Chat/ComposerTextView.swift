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
/// This wrapper drops down to NSTextView for AppKit-managed IME handling and
/// configurable Return-key shortcuts for sending and line breaks.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var skillChips: [ComposerSkill]
    let placeholder: String
    let minLines: Int
    let maxLines: Int
    let focusRequest: Int
    let skillInsertionRequest: ComposerSkillInsertionRequest?
    let sendShortcut: MessageSendShortcut
    let lineBreakShortcut: MessageSendShortcut
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
        tv.allowsUndo = false
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
        tv.sendShortcut = sendShortcut
        tv.lineBreakShortcut = lineBreakShortcut
        tv.onKeyDown = onKeyDown
        tv.onTextCommand = onTextCommand
        tv.onSlashContextChange = onSlashContextChange
        tv.onSendShortcut = onSend

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.borderType = .noBorder
        scroll.documentView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? PlaceholderTextView else { return }
        context.coordinator.parent = self
        tv.placeholder = placeholder
        tv.sendShortcut = sendShortcut
        tv.lineBreakShortcut = lineBreakShortcut
        tv.onKeyDown = onKeyDown
        tv.onTextCommand = onTextCommand
        tv.onSlashContextChange = onSlashContextChange
        tv.onSendShortcut = onSend
        var insertedSkill = false
        let isComposingMarkedText = tv.hasMarkedText()
        if !isComposingMarkedText,
           let skillInsertionRequest,
           context.coordinator.consumeSkillInsertionRequest(skillInsertionRequest.id) {
            tv.insertSkillChip(skillInsertionRequest.skill)
            insertedSkill = true
        } else if !context.coordinator.shouldDeferExternalSync(text: text,
                                                               skillChips: skillChips,
                                                               textView: tv),
                  tv.string != text || tv.skillChips() != skillChips {
            tv.setComposerText(text, skillChips: skillChips)
        }
        if !isComposingMarkedText,
           context.coordinator.consumeFocusRequest(focusRequest) {
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

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        guard let tv = scroll.documentView as? PlaceholderTextView else { return }
        tv.delegate = nil
        tv.onKeyDown = { _ in false }
        tv.onTextCommand = { _ in false }
        tv.onSlashContextChange = { _ in }
        tv.onSendShortcut = {}
        tv.clearUndoRegistrations()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        private var lastFocusRequest: Int
        private var lastSkillInsertionRequest: UUID?
        private var pendingLocalText: String?
        private var pendingLocalSkillChips: [ComposerSkill]?
        private var pendingExternalTextBeforeLocalEdit: String?
        private var pendingExternalSkillChipsBeforeLocalEdit: [ComposerSkill]?
        private var pendingLocalEditDeadline: Date?
        private var localEditGeneration = 0

        init(_ p: ComposerTextView) {
            self.parent = p
            self.lastFocusRequest = p.focusRequest
        }

        func textDidChange(_ note: Notification) {
            guard let tv = note.object as? PlaceholderTextView else { return }
            tv.typingAttributes = ComposerTextView.plainTextAttributes
            let localText = tv.string
            let localSkillChips = tv.skillChips()
            let localSlashContext = tv.currentSlashContext()
            let externalTextBeforeLocalEdit = parent.text
            let externalSkillChipsBeforeLocalEdit = parent.skillChips
            let generation = markPendingLocalEdit(
                text: localText,
                skillChips: localSkillChips,
                externalText: externalTextBeforeLocalEdit,
                externalSkillChips: externalSkillChipsBeforeLocalEdit
            )
            DispatchQueue.main.async { [weak self] in
                guard let self, self.localEditGeneration == generation else { return }
                self.parent.text = localText
                self.parent.skillChips = localSkillChips
                self.parent.onSlashContextChange(localSlashContext)
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? PlaceholderTextView else { return }
            let localSlashContext = tv.currentSlashContext()
            DispatchQueue.main.async { [weak self] in
                self?.parent.onSlashContextChange(localSlashContext)
            }
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

        func shouldDeferExternalSync(text: String,
                                     skillChips: [ComposerSkill],
                                     textView: PlaceholderTextView) -> Bool {
            // AppKit owns marked text until the input method commits it.
            // Replacing the storage here cancels the user's active composition.
            if textView.hasMarkedText() {
                return true
            }
            guard let pendingLocalText,
                  let pendingLocalSkillChips,
                  let pendingExternalTextBeforeLocalEdit,
                  let pendingExternalSkillChipsBeforeLocalEdit,
                  let deadline = pendingLocalEditDeadline
            else { return false }

            if text == pendingLocalText && skillChips == pendingLocalSkillChips {
                clearPendingLocalEdit()
                return false
            }
            guard Date() < deadline else {
                clearPendingLocalEdit(invalidateQueuedUpdate: true)
                return false
            }
            guard text == pendingExternalTextBeforeLocalEdit &&
                skillChips == pendingExternalSkillChipsBeforeLocalEdit
            else {
                clearPendingLocalEdit(invalidateQueuedUpdate: true)
                return false
            }
            if textView.string == pendingLocalText &&
                textView.skillChips() == pendingLocalSkillChips {
                return true
            }
            clearPendingLocalEdit(invalidateQueuedUpdate: true)
            return false
        }

        private func markPendingLocalEdit(text: String,
                                          skillChips: [ComposerSkill],
                                          externalText: String,
                                          externalSkillChips: [ComposerSkill]) -> Int {
            localEditGeneration &+= 1
            pendingLocalText = text
            pendingLocalSkillChips = skillChips
            pendingExternalTextBeforeLocalEdit = externalText
            pendingExternalSkillChipsBeforeLocalEdit = externalSkillChips
            pendingLocalEditDeadline = Date().addingTimeInterval(0.35)
            return localEditGeneration
        }

        private func clearPendingLocalEdit(invalidateQueuedUpdate: Bool = false) {
            pendingLocalText = nil
            pendingLocalSkillChips = nil
            pendingExternalTextBeforeLocalEdit = nil
            pendingExternalSkillChipsBeforeLocalEdit = nil
            pendingLocalEditDeadline = nil
            if invalidateQueuedUpdate {
                localEditGeneration &+= 1
            }
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

struct HelmPlainTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let tv = UndoIsolatedTextView()
        tv.delegate = context.coordinator
        tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.textColor = .labelColor
        tv.isRichText = false
        tv.allowsUndo = false
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 8, height: 8)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        tv.string = text

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.documentView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? UndoIsolatedTextView else { return }
        context.coordinator.parent = self
        if tv.string != text {
            tv.clearUndoRegistrations()
            tv.string = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        guard let tv = scroll.documentView as? UndoIsolatedTextView else { return }
        tv.delegate = nil
        tv.clearUndoRegistrations()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: HelmPlainTextEditor

        init(_ parent: HelmPlainTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }
    }
}

private final class UndoIsolatedTextView: NSTextView {
    deinit {
        clearUndoRegistrations()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            clearUndoRegistrations()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    func clearUndoRegistrations() {
        undoManager?.removeAllActions(withTarget: self)
        breakUndoCoalescing()
    }
}

/// NSTextView with a placeholder string and configurable send forwarding.
final class PlaceholderTextView: NSTextView {
    var placeholder: String = "" {
        didSet {
            if oldValue != placeholder {
                needsDisplay = true
            }
        }
    }
    var sendShortcut: MessageSendShortcut = .defaultValue
    var lineBreakShortcut: MessageSendShortcut = .defaultLineBreakValue
    var onSendShortcut: () -> Void = {}
    var onKeyDown: (NSEvent) -> Bool = { _ in false }
    var onTextCommand: (ComposerTextCommand) -> Bool = { _ in false }
    var onSlashContextChange: (ComposerSlashContext?) -> Void = { _ in }

    func setComposerText(_ text: String, skillChips: [ComposerSkill]) {
        clearUndoRegistrations()
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

    deinit {
        clearUndoRegistrations()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            clearUndoRegistrations()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    func clearUndoRegistrations() {
        undoManager?.removeAllActions(withTarget: self)
        breakUndoCoalescing()
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
        notifySlashContextChanged()
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
        guard !hasMarkedText() else { return nil }
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
        if hasMarkedText() {
            super.keyDown(with: event)
            return
        }
        if onKeyDown(event) {
            return
        }
        if sendShortcut.matches(event) {
            onSendShortcut()
            return
        }
        if lineBreakShortcut.matches(event) {
            insertConfiguredLineBreak()
            return
        }
        super.keyDown(with: event)
    }

    private func insertConfiguredLineBreak() {
        super.insertNewline(nil)
    }

    override func moveUp(_ sender: Any?) {
        if !hasMarkedText(), onTextCommand(.moveUp) {
            return
        }
        super.moveUp(sender)
    }

    override func moveDown(_ sender: Any?) {
        if !hasMarkedText(), onTextCommand(.moveDown) {
            return
        }
        super.moveDown(sender)
    }

    override func insertNewline(_ sender: Any?) {
        if !hasMarkedText(), onTextCommand(.accept) {
            return
        }
        super.insertNewline(sender)
    }

    override func insertTab(_ sender: Any?) {
        if !hasMarkedText(), onTextCommand(.complete) {
            return
        }
        super.insertTab(sender)
    }

    override func cancelOperation(_ sender: Any?) {
        if !hasMarkedText(), onTextCommand(.cancel) {
            return
        }
        super.cancelOperation(sender)
    }

    override func deleteBackward(_ sender: Any?) {
        if !hasMarkedText(), deleteSkillChipBackward() {
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
        notifySlashContextChanged()
        return true
    }

    private func notifySlashContextChanged() {
        let slashContext = currentSlashContext()
        DispatchQueue.main.async { [weak self] in
            self?.onSlashContextChange(slashContext)
        }
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
        self.bounds = NSRect(x: 0,
                             y: ComposerSkillChipRenderer.baselineOffset,
                             width: image.size.width,
                             height: image.size.height)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

enum ComposerSkillChipRenderer {
    private static let height: CGFloat = 18
    private static let iconSize: CGFloat = 13
    private static let iconTextGap: CGFloat = 2
    static var baselineOffset: CGFloat {
        let font = ComposerTextView.font
        return (font.ascender + font.descender - height) / 2
    }

    static func image(for skill: ComposerSkill) -> NSImage {
        image(forName: skill.name)
    }

    static func image(forName skillName: String) -> NSImage {
        let accent = NSColor.controlAccentColor
        let nameAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13.5, weight: .medium),
            .foregroundColor: accent,
        ]

        let name = skillName as NSString
        let nameSize = name.size(withAttributes: nameAttributes)
        let textX = iconSize + iconTextGap
        let width = min(260, textX + ceil(nameSize.width))
        let image = NSImage(size: NSSize(width: width, height: height))

        image.lockFocus()
        if let icon = NSImage(systemSymbolName: "shippingbox", accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: iconSize,
                                            weight: .semibold)
                    .applying(.init(hierarchicalColor: accent))
            ) {
            icon.draw(in: NSRect(x: 0,
                                 y: (height - iconSize) / 2 + 0.2,
                                 width: iconSize,
                                 height: iconSize),
                      from: .zero,
                      operation: .sourceOver,
                      fraction: 1)
        }

        name.draw(with: NSRect(x: textX,
                               y: (height - nameSize.height) / 2 - 0.7,
                               width: max(0, width - textX),
                               height: nameSize.height),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                  attributes: nameAttributes)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
