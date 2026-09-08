import AppKit
import UniformTypeIdentifiers

/// The finished capture, parked in the corner.
///
/// The loop is iterative — you shoot the same frame, adjust, shoot it again —
/// so the result outliving the gesture that made it is the point. It stays
/// until dismissed or replaced, and can be dragged or copied any number of
/// times in between.
final class ShelfController {

    private var panel: NSPanel?
    private let view = ShelfView()

    var onDismiss: (() -> Void)?
    var onReopen: (() -> Void)?

    /// For the headless state snapshots.
    var viewForTesting: NSView { view }

    func present(image: CGImage, fileURL: URL?) {
        view.configure(image: image, fileURL: fileURL)

        let size = view.preferredSize
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let target = CGRect(x: visible.maxX - size.width - 20,
                            y: visible.minY + 20,
                            width: size.width, height: size.height)

        if let panel {
            // Replacing: no entrance animation, just new contents. Re-animating
            // would read as a second capture having happened.
            panel.setFrame(target, display: true)
            view.frame = CGRect(origin: .zero, size: size)
            view.startCountdown(seconds: Settings.shared.shelfSeconds)
            return
        }

        let p = NSPanel(contentRect: target,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isMovableByWindowBackground = true
        // Never take focus: the whole value is that it sits beside whatever you
        // are actually working in.
        p.becomesKeyOnlyIfNeeded = true

        view.frame = CGRect(origin: .zero, size: size)
        view.onDismiss = { [weak self] in self?.dismiss() }
        view.onExpire = { [weak self] in self?.dismiss() }
        view.onReopen = { [weak self] in
            self?.onReopen?()
            self?.dismiss()
        }
        p.contentView = view
        panel = p

        p.alphaValue = 0
        p.setFrame(target.offsetBy(dx: 0, dy: -10), display: false)
        p.orderFrontRegardless()
        Motion.animate(Motion.Duration.entrance) { _ in
            p.animator().alphaValue = 1
            p.animator().setFrame(target, display: true)
        } completion: { [weak self] in
            self?.view.startCountdown(seconds: Settings.shared.shelfSeconds)
        }
    }

    func dismiss() {
        view.stopCountdown()
        guard let p = panel else { return }
        Motion.animate(Motion.Duration.quick) { _ in
            p.animator().alphaValue = 0
        } completion: { [weak self] in
            p.orderOut(nil)
            self?.panel = nil
            self?.onDismiss?()
        }
    }
}

final class ShelfView: NSView, NSDraggingSource {

    var onDismiss: (() -> Void)?
    var onReopen: (() -> Void)?
    var onExpire: (() -> Void)?

    private var image: NSImage?
    private var cgImage: CGImage?
    private var fileURL: URL?
    private var isHovered = false { didSet { needsDisplay = true } }
    private var flash: String?
    private var flashWork: DispatchWorkItem?

    // The card puts itself away after a while. It is a handle on something
    // already saved to disk, not the thing itself — but a card that might or
    // might not still be there is unsettling, so the countdown is visible and
    // hovering stops it for good.
    private var countdownStart: CFTimeInterval?
    private var countdownLength: CFTimeInterval = 0
    private var countdownTimer: Timer?

    private let thumbWidth: CGFloat = 232
    private let barHeight: CGFloat = 30
    private let progressHeight: CGFloat = 2
    private var thumbHeight: CGFloat = 130

    /// Back to the editor with the markup intact. For a capture that finished
    /// itself because nobody touched it, this is the undo — the decision was
    /// made on your behalf, so taking it back has to be one click.
    private let reopenButton = IconButton(symbol: "arrow.uturn.backward",
                                          label: "Back to editing")
    private let copyButton = IconButton(symbol: "doc.on.doc", label: "Copy image")
    private let pathButton = IconButton(symbol: "terminal", label: "Copy file path")
    private let dismissButton = IconButton(symbol: "xmark", label: "Put away")

    override var isFlipped: Bool { true }

    var preferredSize: NSSize { NSSize(width: thumbWidth, height: thumbHeight + barHeight) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        reopenButton.onClick = { [weak self] in self?.onReopen?() }
        copyButton.onClick = { [weak self] in
            guard let self, let cgImage = self.cgImage else { return }
            Output.copyImage(cgImage)
            self.showFlash("Image copied")
        }
        pathButton.onClick = { [weak self] in
            guard let self, let url = self.fileURL else { return }
            Output.copyPath(url)
            self.showFlash("Path copied")
        }
        dismissButton.onClick = { [weak self] in self?.onDismiss?() }

        [reopenButton, copyButton, pathButton, dismissButton].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(image cg: CGImage, fileURL url: URL?) {
        let aspect = CGFloat(cg.height) / CGFloat(cg.width)
        thumbHeight = min(240, max(80, (thumbWidth * aspect).rounded()))
        self.image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        self.cgImage = cg
        self.fileURL = url
        pathButton.isEnabled = url != nil
        flash = nil
        stopCountdown()
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let size = reopenButton.intrinsicContentSize
        let y = thumbHeight + (barHeight - size.height) / 2
        var x: CGFloat = 6
        for button in [reopenButton, copyButton, pathButton] {
            button.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
            x += size.width + 2
        }
        dismissButton.frame = CGRect(x: bounds.width - 6 - size.width, y: y,
                                     width: size.width, height: size.height)
    }

    // MARK: Drawing

    private var thumbRect: CGRect { CGRect(x: 0, y: 0, width: bounds.width, height: thumbHeight) }
    private var progressRect: CGRect {
        CGRect(x: 0, y: bounds.height - progressHeight,
               width: bounds.width, height: progressHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()

        if let cgImage, let ctx = NSGraphicsContext.current?.cgContext {
            FlippedDraw.image(cgImage, in: thumbRect, ctx: ctx)
        }
        if isHovered {
            NSColor.black.withAlphaComponent(0.06).setFill()
            thumbRect.fill()
        }

        NSColor.separatorColor.setFill()
        CGRect(x: 0, y: thumbHeight, width: bounds.width, height: 1).fill()

        if let flash {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
                .foregroundColor: Theme.accent
            ]
            let text = flash as NSString
            let size = text.size(withAttributes: attrs)
            text.draw(at: CGPoint(x: bounds.width - 34 - size.width,
                                  y: thumbHeight + (barHeight - size.height) / 2),
                      withAttributes: attrs)
        }

        drawCountdown()
    }

    /// A bar that drains. It says "this card is going away", not "your capture
    /// is going away" — the PNG is already on disk either way.
    private func drawCountdown() {
        guard let start = countdownStart, countdownLength > 0 else { return }
        let elapsed = CACurrentMediaTime() - start
        let remaining = max(0, 1 - CGFloat(elapsed / countdownLength))
        guard remaining > 0 else { return }

        NSColor.separatorColor.withAlphaComponent(0.35).setFill()
        progressRect.fill()
        Theme.accent.withAlphaComponent(0.75).setFill()
        CGRect(x: 0, y: progressRect.minY,
               width: bounds.width * remaining, height: progressHeight).fill()
    }

    // MARK: Interaction

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        // Reaching for it is the clearest possible statement that you want it.
        stopCountdown()
    }

    override func mouseExited(with event: NSEvent) { isHovered = false }

    /// Dragging the thumbnail hands over the real file.
    ///
    /// Not a file promise: promises exist for files that do not exist yet, and
    /// every capture is already written to disk before it reaches the shelf. A
    /// plain file URL is simpler and lands in more places — Finder, Figma, a
    /// browser file field, a chat attachment — because it is what a drag from
    /// Finder itself looks like.
    override func mouseDragged(with event: NSEvent) {
        guard let fileURL, let image, thumbRect.contains(convert(event.locationInWindow, from: nil))
        else { return }

        let item = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
        let dragSize = NSSize(width: thumbWidth * 0.8, height: thumbHeight * 0.8)
        item.setDraggingFrame(
            CGRect(origin: convert(event.locationInWindow, from: nil)
                        .applying(.init(translationX: -dragSize.width / 2,
                                        y: -dragSize.height / 2)),
                   size: dragSize),
            contents: image
        )
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Copy everywhere: dragging a capture out should never move the file
        // out from under the path someone already pasted.
        .copy
    }

    // MARK: Countdown

    func startCountdown(seconds: TimeInterval) {
        stopCountdown()
        guard seconds > 0 else { return }
        countdownLength = seconds
        countdownStart = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self, let start = self.countdownStart else { return }
            self.needsDisplay = true
            if CACurrentMediaTime() - start >= self.countdownLength {
                self.stopCountdown()
                self.onExpire?()
            }
        }
        countdownTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        needsDisplay = true
    }

    func stopCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownStart = nil
        needsDisplay = true
    }

    private func showFlash(_ message: String) {
        // Acting on the card means keeping it.
        stopCountdown()
        flashWork?.cancel()
        flash = message
        needsDisplay = true
        let work = DispatchWorkItem { [weak self] in
            self?.flash = nil
            self?.needsDisplay = true
        }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }
}
