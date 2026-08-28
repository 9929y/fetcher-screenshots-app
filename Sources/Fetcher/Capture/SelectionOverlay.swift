import AppKit

/// The region picker.
///
/// One borderless window per display, each showing that display's *frozen*
/// pixels. The overlay never shows the live screen, so nothing it draws can
/// end up in the capture, and there is no window animation to wait on.
final class SelectionOverlay {

    /// Called with the display and the selected rect in that display's view
    /// coordinates (points, bottom-left origin), or nil if cancelled.
    typealias Completion = (FrozenDisplay, CGRect)?

    private var windows: [OverlayWindow] = []

    /// For the end-to-end driver: the live overlay views, in display order.
    var viewsForTesting: [OverlayView] { windows.map(\.overlayView) }
    private var completion: ((Completion) -> Void)?
    private var finished = false

    func present(_ displays: [FrozenDisplay], preselect: CGRect? = nil,
                 completion: @escaping (Completion) -> Void) {
        self.completion = completion
        self.finished = false

        for display in displays {
            let w = OverlayWindow(display: display, owner: self)
            if let pre = preselect, display.screen == displays.first?.screen {
                w.overlayView.preselect(pre)
            }
            windows.append(w)
            w.orderFrontRegardless()
        }
        // The window under the cursor takes the keyboard, so esc always lands.
        let mouse = NSEvent.mouseLocation
        let keyWin = windows.first { $0.frame.contains(mouse) } ?? windows.first
        keyWin?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The pointer moved onto a display, so its overlay takes the keyboard.
    ///
    /// Without this the keyboard stays with whichever display the pointer
    /// happened to be on when the crosshair appeared. On one screen that is
    /// invisible. On two it means hovering a frame on the *other* display and
    /// pressing return does nothing at all — the key window has no candidate to
    /// accept, and the keystroke lands there rather than where you are looking.
    fileprivate func focusFollowed(by window: OverlayWindow) {
        guard !window.isKeyWindow else { return }
        window.makeKey()
    }

    /// A drag started somewhere — everything else stops drawing a crosshair.
    fileprivate func claimDrag(by window: OverlayWindow) {
        for w in windows where w !== window {
            w.overlayView.relinquish()
        }
    }

    fileprivate func finish(_ result: Completion) {
        guard !finished else { return }
        finished = true
        let cb = completion
        completion = nil
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
        cb?(result)
    }

    fileprivate func cancel() { finish(nil) }
}

// MARK: - Window

final class OverlayWindow: NSWindow {
    let overlayView: OverlayView

    init(display: FrozenDisplay, owner: SelectionOverlay) {
        overlayView = OverlayView(display: display, owner: owner)
        super.init(contentRect: display.screen.frame,
                   styleMask: [.borderless],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        contentView = overlayView
        setFrame(display.screen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var acceptsFirstResponder: Bool { true }
}

// MARK: - View

final class OverlayView: NSView {

    private let display: FrozenDisplay
    private weak var owner: SelectionOverlay?
    private let frozen: NSImage

    private var anchor: CGPoint?
    private var current: CGPoint?
    private var selection: CGRect?
    private var cursor: CGPoint?
    private var isActive = true
    private var snap: CGRect?          // in view points
    private var snapSuppressed = false

    private static let hudFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)

    init(display: FrozenDisplay, owner: SelectionOverlay) {
        self.display = display
        self.owner = owner
        self.frozen = NSImage(cgImage: display.image, size: display.screen.frame.size)
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    func preselect(_ r: CGRect) { selection = r; needsDisplay = true }

    /// For the end-to-end driver.
    var snapForTesting: CGRect? { snap }
    func relinquish() { isActive = false; cursor = nil; needsDisplay = true }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        frozen.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)

        let sel = liveSelection()

        NSColor(calibratedWhite: 0.04, alpha: 0.46).setFill()
        bounds.fill()

        if let sel, sel.width >= 1, sel.height >= 1 {
            // Punch the selection back to full brightness by redrawing the
            // frozen pixels clipped to it — cheaper and more predictable than
            // compositing a hole in the scrim.
            ctx.saveGState()
            ctx.clip(to: sel)
            frozen.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
            ctx.restoreGState()

            drawSelectionChrome(sel, ctx: ctx)
            drawHUD(for: sel)
        } else if isActive, let snapped = snap {
            drawSnapCandidate(snapped)
            if let c = cursor { drawCrosshair(at: c) }
        } else if isActive, let c = cursor {
            drawCrosshair(at: c)
        }
    }

    private func drawSelectionChrome(_ sel: CGRect, ctx: CGContext) {
        // White halo under a thin accent stroke, so the edge reads on any
        // underlying pixels.
        NSColor(calibratedWhite: 1, alpha: 0.9).setStroke()
        let halo = NSBezierPath(rect: sel.insetBy(dx: -1, dy: -1))
        halo.lineWidth = 1
        halo.stroke()

        Theme.accent.setStroke()
        let border = NSBezierPath(rect: sel)
        border.lineWidth = 1
        border.stroke()

        // Corner ticks: cheap, and they make a 20px selection legible.
        Theme.accent.setFill()
        let t: CGFloat = 5, w: CGFloat = 2
        for cx in [sel.minX, sel.maxX - w] {
            for cy in [sel.minY, sel.maxY - t] {
                CGRect(x: cx, y: cy, width: w, height: t).fill()
            }
        }
        for cy in [sel.minY, sel.maxY - w] {
            for cx in [sel.minX, sel.maxX - t] {
                CGRect(x: cx, y: cy, width: t, height: w).fill()
            }
        }
    }

    /// The frame under the cursor, offered rather than imposed: the crosshair
    /// stays visible, and dragging past it ignores it entirely.
    private func drawSnapCandidate(_ r: CGRect) {
        Theme.accentSoft.withAlphaComponent(0.16).setFill()
        NSBezierPath(rect: r).fill()

        NSColor(calibratedWhite: 1, alpha: 0.85).setStroke()
        let halo = NSBezierPath(rect: r.insetBy(dx: -1, dy: -1))
        halo.lineWidth = 1
        halo.stroke()

        Theme.accent.setStroke()
        let border = NSBezierPath(rect: r)
        border.lineWidth = 1.5
        border.stroke()

        drawHUD(for: r)
    }

    private func drawCrosshair(at p: CGPoint) {
        NSColor(calibratedWhite: 1, alpha: 0.55).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        path.move(to: CGPoint(x: bounds.minX, y: p.y.rounded() + 0.5))
        path.line(to: CGPoint(x: bounds.maxX, y: p.y.rounded() + 0.5))
        path.move(to: CGPoint(x: p.x.rounded() + 0.5, y: bounds.minY))
        path.line(to: CGPoint(x: p.x.rounded() + 0.5, y: bounds.maxY))
        path.stroke()
    }

    /// Live pixel dimensions, in the units that actually matter to the user:
    /// the pixels the export will contain.
    private func drawHUD(for sel: CGRect) {
        let px = Int((sel.width * display.scale).rounded())
        let py = Int((sel.height * display.scale).rounded())
        let text = "\(px) x \(py)"

        let attrs: [NSAttributedString.Key: Any] = [
            .font: Self.hudFont,
            .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let padX: CGFloat = 7, padY: CGFloat = 3
        let boxW = size.width + padX * 2, boxH = size.height + padY * 2

        // Prefer above the selection; flip below when there is no room.
        var y = sel.maxY + 6
        if y + boxH > bounds.maxY { y = sel.minY - boxH - 6 }
        if y < bounds.minY { y = sel.minY + 6 }
        var x = sel.minX
        if x + boxW > bounds.maxX { x = bounds.maxX - boxW }

        let box = CGRect(x: x, y: y, width: boxW, height: boxH)
        Theme.accent.setFill()
        NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
        (text as NSString).draw(
            at: CGPoint(x: box.minX + padX, y: box.minY + padY), withAttributes: attrs
        )
    }

    /// View points (bottom-left origin) to image pixels (top-left origin).
    private func imagePoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * display.scale, y: (bounds.height - p.y) * display.scale)
    }

    /// And back again.
    private func viewRect(fromImage r: CGRect) -> CGRect {
        CGRect(x: r.minX / display.scale,
               y: bounds.height - r.maxY / display.scale,
               width: r.width / display.scale,
               height: r.height / display.scale)
    }

    private func recomputeSnap() {
        guard Settings.shared.frameSnapEnabled,
              isActive, !snapSuppressed, anchor == nil, let c = cursor,
              let edges = display.edges else {
            if snap != nil { snap = nil; needsDisplay = true }
            return
        }
        let found = edges.candidate(
            atPixel: imagePoint(c),
            imageSize: CGSize(width: display.image.width, height: display.image.height)
        ).map(viewRect(fromImage:))

        if found != snap {
            snap = found
            needsDisplay = true
        }
    }

    private func liveSelection() -> CGRect? {
        if let a = anchor, let c = current { return normalized(a, c) }
        return selection
    }

    private func normalized(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    // MARK: Events

    override func mouseMoved(with event: NSEvent) {
        if let window = window as? OverlayWindow { owner?.focusFollowed(by: window) }
        cursor = convert(event.locationInWindow, from: nil)
        snapSuppressed = event.modifierFlags.contains(.option)
        recomputeSnap()
        needsDisplay = true
    }

    /// Holding option turns snapping off mid-hover, for the cases where the
    /// detected rectangle is right about the pixels and wrong about the intent.
    override func flagsChanged(with event: NSEvent) {
        let suppress = event.modifierFlags.contains(.option)
        if suppress != snapSuppressed {
            snapSuppressed = suppress
            recomputeSnap()
        }
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseDown(with event: NSEvent) {
        if let window = window as? OverlayWindow { owner?.focusFollowed(by: window) }
        let p = convert(event.locationInWindow, from: nil)
        anchor = p
        current = p
        selection = nil
        snap = nil
        isActive = true
        owner?.claimDrag(by: window as! OverlayWindow)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let a = anchor else { return }
        let released = convert(event.locationInWindow, from: nil)
        let r = normalized(a, released)
        anchor = nil
        current = nil

        // A click, not a drag. If a frame was being offered under the cursor,
        // that click means "take it" — which is the whole point of detecting it.
        guard r.width >= 6, r.height >= 6 else {
            cursor = released
            recomputeSnap()
            if let snapped = snap {
                owner?.finish((display, snapped))
                return
            }
            selection = nil
            needsDisplay = true
            return
        }
        selection = r
        owner?.finish((display, r))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { owner?.cancel(); return }        // esc
        // Return takes the outlined frame, so the whole capture can happen
        // without the hand leaving the keyboard once the pointer is in place.
        if event.keyCode == 36 || event.keyCode == 76 {
            if let snapped = snap { owner?.finish((display, snapped)) }
            return
        }
        super.keyDown(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }
}

/// Chrome colors. Muted to match the palette — a saturated selection border
/// against a Morandi box set looks like it came from a different application.
enum Theme {
    /// Slate, dark enough to carry white HUD text at 4.5:1.
    static let accent = NSColor(srgbRed: 0x5E/255, green: 0x6A/255, blue: 0x86/255, alpha: 1)
    static let accentSoft = NSColor(srgbRed: 0x8A/255, green: 0x95/255, blue: 0xAD/255, alpha: 1)
}
