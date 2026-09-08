import AppKit

/// A compact symbol button with every state drawn.
///
/// The icons are SF Symbols — Apple's own set, already on the machine. That is
/// not a shortcut: a downloaded icon pack cannot match the weight of the text
/// beside it, cannot follow the accent color, cannot re-render for dark mode,
/// and turns into a folder of assets someone has to keep in step. The system
/// set does all of that on its own.
final class IconButton: NSView {

    var onClick: (() -> Void)?
    var isEnabled: Bool = true { didSet { needsDisplay = true } }

    private let symbol: String
    private let label: String
    private let prominent: Bool
    private var isHovered = false { didSet { needsDisplay = true } }
    private var isPressed = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    init(symbol: String, label: String, shortcut: String? = nil, prominent: Bool = false) {
        self.symbol = symbol
        self.label = label
        self.prominent = prominent
        super.init(frame: .zero)
        wantsLayer = true
        toolTip = shortcut.map { "\(label)  \($0)" } ?? label
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 26, height: 24) }

    private var tint: NSColor {
        if !isEnabled { return .tertiaryLabelColor }
        if prominent { return Theme.accent }
        return isHovered ? NSColor(YYStudioTokens.ink) : NSColor(YYStudioTokens.muted)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isEnabled, isHovered || isPressed {
            NSColor.white.withAlphaComponent(isPressed ? 0.88 : 0.64).setFill()
            let hoverPath = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
            hoverPath.fill()
            NSColor(YYStudioTokens.hairline).withAlphaComponent(0.7).setStroke()
            hoverPath.lineWidth = 1
            hoverPath.stroke()
        }

        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(config) else { return }

        let image = IconButton.tinted(base, tint)
        let size = image.size
        image.draw(in: CGRect(x: (bounds.width - size.width) / 2,
                              y: (bounds.height - size.height) / 2,
                              width: size.width, height: size.height))
    }

    /// Template images do not pick up a fill color when drawn by hand, so the
    /// tint has to be baked in.
    private static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        let out = NSImage(size: image.size)
        out.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: image.size))
        color.set()
        NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
        out.unlockFocus()
        return out
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; isPressed = false }
    override func mouseDown(with event: NSEvent) { if isEnabled { isPressed = true } }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }
}
