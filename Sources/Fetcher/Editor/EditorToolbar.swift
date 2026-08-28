import AppKit

/// The strip along the bottom of the editor.
///
/// Its real job is discoverability. Everything here can be done from the
/// keyboard, and a keyboard-first tool that never shows its keys is a tool
/// nobody learns — so the hint text is bound to the canvas state and always
/// names the keys that work *right now*.
final class EditorToolbar: NSView {

    var onPickColor: ((Int) -> Void)?
    var onCopy: (() -> Void)?
    var onUndo: (() -> Void)?
    var onCancel: (() -> Void)?

    private let swatches = PaletteStrip()
    private let hint = NSTextField(labelWithString: "")
    private let copyButton = SoftButton(title: "Copy", shortcut: "⌘C")
    // Undo and cancel were reachable only by shortcut, which is the same as not
    // existing for anyone who has not read the docs.
    private let undoButton = IconButton(symbol: "arrow.uturn.backward",
                                        label: "Undo", shortcut: "⌘Z")
    private let cancelButton = IconButton(symbol: "xmark",
                                          label: "Discard this capture", shortcut: "esc")
    private var hintResetWork: DispatchWorkItem?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true

        hint.font = .systemFont(ofSize: 11.5, weight: .regular)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byTruncatingTail

        swatches.onPick = { [weak self] i in self?.onPickColor?(i) }
        copyButton.onClick = { [weak self] in self?.onCopy?() }

        undoButton.onClick = { [weak self] in self?.onUndo?() }
        cancelButton.onClick = { [weak self] in self?.onCancel?() }

        addSubview(swatches)
        addSubview(hint)
        addSubview(undoButton)
        addSubview(cancelButton)
        addSubview(copyButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.separatorColor.setFill()
        CGRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 12
        let swatchWidth = swatches.intrinsicContentSize.width
        swatches.frame = CGRect(x: pad, y: (bounds.height - 18) / 2,
                                width: swatchWidth, height: 18)

        let buttonWidth = copyButton.intrinsicContentSize.width
        copyButton.frame = CGRect(x: bounds.width - pad - buttonWidth,
                                  y: (bounds.height - 26) / 2,
                                  width: buttonWidth, height: 26)

        let icon = undoButton.intrinsicContentSize
        cancelButton.frame = CGRect(x: copyButton.frame.minX - 8 - icon.width,
                                    y: (bounds.height - icon.height) / 2,
                                    width: icon.width, height: icon.height)
        undoButton.frame = CGRect(x: cancelButton.frame.minX - 2 - icon.width,
                                  y: (bounds.height - icon.height) / 2,
                                  width: icon.width, height: icon.height)

        let hintX = swatches.frame.maxX + 14
        hint.frame = CGRect(x: hintX, y: (bounds.height - 16) / 2,
                            width: max(0, undoButton.frame.minX - hintX - 12), height: 16)
    }

    // MARK: State binding

    func refresh(canvas: CanvasView) {
        let doc = canvas.document
        var selected: Int?
        if case .selected(let id) = canvas.mode, let a = doc.annotation(id) {
            selected = a.wheelIndex
        }
        swatches.update(next: doc.nextWheelIndex, selected: selected)
        undoButton.isEnabled = doc.canUndo

        hintResetWork?.cancel()
        hint.stringValue = hintText(for: canvas)
        needsLayout = true
    }

    /// The hint names only keys that are live in the current state. A key list
    /// that includes things that do nothing right now is worse than none.
    private func hintText(for canvas: CanvasView) -> String {
        switch canvas.mode {
        case .editing:
            return "⏎ commit  ·  ⇧⏎ newline  ·  ⇥ next note  ·  ⌥1–0 recolor  ·  esc cancel"
        case .drawing:
            return "Release to write the note"
        case .selected:
            return "1–0 recolor  ·  ⌫ delete  ·  arrows nudge  ·  ⌥arrows resize  ·  ⏎ edit note"
        case .moving, .resizing:
            return "Release to place"
        case .finishing:
            return "Copying…"
        case .idle, .hovering:
            if canvas.document.isEmpty {
                return "⌘C copy as-is  ·  or drag a box to mark it up"
            }
            return "⌘C copy image  ·  ⌥⌘C copy text only  ·  ⇥ select  ·  ⌘Z undo"
        }
    }

    func flashHint(_ message: String) {
        hint.stringValue = message
        hint.textColor = .systemRed
        let work = DispatchWorkItem { [weak self] in
            self?.hint.textColor = .secondaryLabelColor
        }
        hintResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4, execute: work)
    }

    func shakeCopy() { copyButton.shake() }
}

/// The ten colors, with the next-to-be-assigned one ringed.
final class PaletteStrip: NSView {

    var onPick: ((Int) -> Void)?

    private var next: Int = 0
    private var selected: Int?
    private var hovered: Int?

    private let dot: CGFloat = 13
    private let gap: CGFloat = 5

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: CGFloat(Palette.wheel.count) * (dot + gap) - gap, height: dot + 5)
    }

    func update(next: Int, selected: Int?) {
        self.next = next
        self.selected = selected
        needsDisplay = true
    }

    private func rect(_ i: Int) -> CGRect {
        CGRect(x: CGFloat(i) * (dot + gap), y: (bounds.height - dot) / 2,
               width: dot, height: dot)
    }

    override func draw(_ dirtyRect: NSRect) {
        for i in 0..<Palette.wheel.count {
            var r = rect(i)
            let isSelected = selected == i
            let isNext = selected == nil && next == i
            let isHovered = hovered == i

            if isHovered || isSelected { r = r.insetBy(dx: -1.5, dy: -1.5) }

            Palette.color(i).setFill()
            NSBezierPath(ovalIn: r).fill()

            // A ring, not a fill change: the swatch has to keep showing its own
            // color while also showing that it is the one queued up next.
            if isSelected || isNext {
                (isSelected ? NSColor.labelColor : NSColor.tertiaryLabelColor).setStroke()
                let ring = NSBezierPath(ovalIn: r.insetBy(dx: -2.5, dy: -2.5))
                ring.lineWidth = isSelected ? 1.5 : 1
                ring.stroke()
            }
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let hit = (0..<Palette.wheel.count).first { rect($0).insetBy(dx: -3, dy: -3).contains(p) }
        if hit != hovered { hovered = hit; needsDisplay = true }
        (hit == nil ? NSCursor.arrow : NSCursor.pointingHand).set()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let hit = (0..<Palette.wheel.count).first(where: { rect($0).insetBy(dx: -3, dy: -3).contains(p) }) {
            onPick?(hit)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }
}

/// A button with all four states drawn explicitly: idle, hover, pressed and
/// disabled. Pressed is a real state, not an afterthought — without it a click
/// on a custom-drawn control feels like nothing happened.
final class SoftButton: NSView {

    var onClick: (() -> Void)?
    var isEnabled: Bool = true { didSet { needsDisplay = true } }

    private let title: String
    private let shortcut: String
    private var isHovered = false { didSet { needsDisplay = true } }
    private var isPressed = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    init(title: String, shortcut: String) {
        self.title = title
        self.shortcut = shortcut
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    private var titleAttrs: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 12, weight: .medium),
         .foregroundColor: isEnabled ? NSColor.white : NSColor.tertiaryLabelColor]
    }

    private var shortcutAttrs: [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
         .foregroundColor: (isEnabled ? NSColor.white : NSColor.tertiaryLabelColor)
            .withAlphaComponent(isEnabled ? 0.65 : 1)]
    }

    override var intrinsicContentSize: NSSize {
        let t = (title as NSString).size(withAttributes: titleAttrs).width
        let s = (shortcut as NSString).size(withAttributes: shortcutAttrs).width
        return NSSize(width: t + s + 30, height: 26)
    }

    override func draw(_ dirtyRect: NSRect) {
        let base = Theme.accent
        let fill: NSColor
        if !isEnabled          { fill = NSColor.quaternaryLabelColor }
        else if isPressed      { fill = base.blended(withFraction: 0.18, of: .black) ?? base }
        else if isHovered      { fill = base.blended(withFraction: 0.12, of: .white) ?? base }
        else                   { fill = base }

        fill.setFill()
        let path = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        path.fill()

        let t = title as NSString
        let s = shortcut as NSString
        let tSize = t.size(withAttributes: titleAttrs)
        let sSize = s.size(withAttributes: shortcutAttrs)
        let total = tSize.width + 8 + sSize.width
        let x = (bounds.width - total) / 2
        t.draw(at: CGPoint(x: x, y: (bounds.height - tSize.height) / 2), withAttributes: titleAttrs)
        s.draw(at: CGPoint(x: x + tSize.width + 8, y: (bounds.height - sSize.height) / 2),
               withAttributes: shortcutAttrs)
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent)  { isHovered = false; isPressed = false }
    override func mouseDown(with event: NSEvent)    { isPressed = true }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
        let p = convert(event.locationInWindow, from: nil)
        if bounds.contains(p) { onClick?() }
    }

    /// The blocked state: a short lateral shake rather than a dialog. It says
    /// "not yet" without taking the screen away from you.
    func shake() {
        guard !Motion.reduced else { return }
        let shake = CAKeyframeAnimation(keyPath: "position.x")
        shake.values = [0, -5, 4, -3, 2, 0].map { layer!.position.x + $0 }
        shake.keyTimes = [0, 0.16, 0.36, 0.56, 0.78, 1]
        shake.duration = 0.34
        shake.timingFunction = Motion.timing
        layer?.add(shake, forKey: "shake")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }
}
