import AppKit

/// The note editor.
///
/// The text editing model, in full:
///
/// - The field opens **already focused** the instant a box is drawn. No click,
///   no tool switch. The caret is the only thing that moves.
/// - `return` commits the note and arms the next box — the canvas takes focus
///   back, so the next drag starts a new annotation with no intervening step.
/// - `shift-return` inserts a newline inside the note. Newlines are collapsed
///   to spaces in the generated prompt, so multi-line notes stay readable in
///   the legend without breaking the numbered list.
/// - `tab` commits and opens the *next* annotation's note, so a whole markup
///   can be revised without touching the mouse. `shift-tab` walks backwards.
/// - `esc` reverts to the last committed text. On a box that has never had a
///   note — a stray drag — it deletes the box instead, because an empty box
///   nobody meant to draw should not survive a cancel.
/// - `option-1`…`option-0` re-color the box while typing. Plain digits cannot
///   be the shortcut here for the obvious reason: they are text.
/// - `cmd-Z` is ordinary text undo while the field has focus, and annotation
///   undo when the canvas does. Two scopes, the standard key.
final class NoteFieldView: NSView {

    let textView = NoteTextView()

    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onAdvance: ((Bool) -> Void)?           // true = forward
    var onColorOverride: ((Int) -> Void)?
    var onHeightChange: (() -> Void)?

    private let inset = NSEdgeInsets(top: 9, left: 11, bottom: 9, right: 11)
    private let maxLines = 5

    var wheelIndex: Int = 0 {
        didSet { applyColor() }
    }
    var overDark: Bool = false {
        didSet { applyColor() }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.shadowOpacity = 0.16
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        layer?.shadowColor = NSColor.black.cgColor

        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        textView.onCommit        = { [weak self] in self?.onCommit?() }
        textView.onCancel        = { [weak self] in self?.onCancel?() }
        textView.onAdvance       = { [weak self] fwd in self?.onAdvance?(fwd) }
        textView.onColorOverride = { [weak self] i in self?.onColorOverride?(i) }
        textView.onTextChanged   = { [weak self] in self?.onHeightChange?() }

        addSubview(textView)
        applyColor()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Appearance

    private func applyColor() {
        let accent = Palette.color(wheelIndex)
        layer?.backgroundColor = (overDark
            ? NSColor(srgbRed: 0.11, green: 0.12, blue: 0.15, alpha: 0.97)
            : NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.98)).cgColor
        // The border is the binding: this field belongs to *that* box.
        layer?.borderColor = accent.withAlphaComponent(0.55).cgColor
        textView.insertionPointColor = accent
        textView.textColor = overDark ? .white : NSColor(calibratedWhite: 0.09, alpha: 1)
        textView.placeholderColor = accent.withAlphaComponent(overDark ? 0.55 : 0.5)
        needsDisplay = true
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        textView.frame = NSRect(
            x: inset.left, y: inset.top,
            width: max(20, bounds.width - inset.left - inset.right),
            height: max(16, bounds.height - inset.top - inset.bottom)
        )
    }

    func fittingHeight(forWidth width: CGFloat) -> CGFloat {
        let textWidth = max(20, width - inset.left - inset.right)
        guard let lm = textView.layoutManager, let tc = textView.textContainer else {
            return inset.top + 18 + inset.bottom
        }
        // The container width tracks the text view, so the view has to be at
        // its real width before measuring — setting containerSize on its own is
        // silently overwritten at the next layout pass, and the field opens one
        // line too short.
        textView.frame.size.width = textWidth
        tc.containerSize = CGSize(width: textWidth, height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        let lineHeight = lm.defaultLineHeight(for: textView.font ?? .systemFont(ofSize: 13))
        let used = max(lineHeight, lm.usedRect(for: tc).height)
        // Past five lines the field scrolls instead of eating the screenshot.
        let capped = min(used, lineHeight * CGFloat(maxLines))
        return (inset.top + capped + inset.bottom).rounded(.up)
    }

    func focus() {
        window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
    }
}

/// The keyboard contract lives here so it is in one readable place.
final class NoteTextView: NSTextView {

    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onAdvance: ((Bool) -> Void)?
    var onColorOverride: ((Int) -> Void)?
    var onTextChanged: (() -> Void)?

    var placeholder = "Describe the change…"
    var placeholderColor: NSColor = .secondaryLabelColor {
        didSet { needsDisplay = true }
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        switch event.keyCode {
        case 36, 76:                                   // return, keypad enter
            if mods.contains(.command) { onCommit?(); return }   // cmd-return finishes upstream
            if mods.contains(.shift) { super.keyDown(with: event); return }
            onCommit?()
            return
        case 53:                                       // esc
            onCancel?()
            return
        case 48:                                       // tab
            onAdvance?(!mods.contains(.shift))
            return
        default:
            break
        }

        // option-digit re-colors without leaving the field. Plain digits are
        // text here, which is why the modifier is required.
        if mods.contains(.option),
           let chars = event.charactersIgnoringModifiers,
           chars.count == 1, let digit = Int(chars) {
            onColorOverride?(digit == 0 ? 9 : digit - 1)
            return
        }

        super.keyDown(with: event)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
        onTextChanged?()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? .systemFont(ofSize: 13),
            .foregroundColor: placeholderColor
        ]
        (placeholder as NSString).draw(at: .zero, withAttributes: attrs)
    }
}
