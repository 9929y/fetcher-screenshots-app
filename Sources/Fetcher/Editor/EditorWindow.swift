import AppKit

/// The editor window.
///
/// It opens *exactly over the region that was captured*, at 1:1, with no
/// title bar and no reposition animation — so between pressing the shortcut and
/// drawing the first box, nothing on screen moves and the eye never has to
/// re-find the content. The only chrome is a strip along the bottom.
final class EditorWindowController: NSObject {

    private var window: NSWindow?
    private let canvas: CanvasView
    private let toolbar: EditorToolbar
    private let regionOnScreen: CGRect

    /// Reports the finished capture: the composited image, and the file it was
    /// written to.
    var onFinished: ((CGImage, URL?, [Annotation]) -> Void)?
    var onCancelled: (() -> Void)?

    private let toolbarHeight: CGFloat = 46

    /// The window outlives whoever opened it, and every shortcut runs through a
    /// `[weak self]` callback on this object. Without a strong reference held
    /// for exactly as long as the window is on screen, a caller that forgets to
    /// retain the controller gets a fully interactive editor whose keyboard
    /// silently does nothing — no crash, no message, just a dead cmd-return.
    /// The presentation owns itself, and hands that back at dismiss.
    private var whilePresented: EditorWindowController?

    /// The smallest editor worth opening.
    ///
    /// The width is set by the toolbar, which carries ten swatches, a live key
    /// hint and three controls; below this it overlaps itself. The height is
    /// what it takes to draw a box and read the note under it. A capture
    /// smaller than this is magnified rather than shown in a window nobody can
    /// work in.
    private static let minimumCanvas = CGSize(width: 660, height: 380)

    init(image: CGImage, scale: CGFloat, regionOnScreen: CGRect) {
        let available = (NSScreen.main?.visibleFrame.size).map {
            CGSize(width: $0.width - 80, height: $0.height - 80 - 46)
        } ?? CGSize(width: 1200, height: 800)
        let zoom = CanvasView.fittingZoom(forImage: image, scale: scale,
                                          minimum: EditorWindowController.minimumCanvas,
                                          available: available)
        self.canvas = CanvasView(image: image, scale: scale, zoom: zoom)
        self.toolbar = EditorToolbar()
        self.regionOnScreen = regionOnScreen
        super.init()
    }

    // MARK: Presentation

    func show() {
        let canvasSize = canvas.frame.size
        // Magnified captures cannot sit exactly over the region they came from,
        // so they are centred on it — the content still appears where the eye
        // already is, which is the property that mattered.
        var frame = CGRect(x: regionOnScreen.midX - canvasSize.width / 2,
                           y: regionOnScreen.midY - (canvasSize.height + toolbarHeight) / 2,
                           width: canvasSize.width,
                           height: canvasSize.height + toolbarHeight)

        // Keep the whole window on screen; the canvas may end up a few points
        // off its origin, which is far better than a clipped toolbar.
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) })
            ?? NSScreen.main {
            let visible = screen.visibleFrame
            frame.origin.y = max(frame.minY, visible.minY + 8)
            frame.origin.x = min(max(frame.minX, visible.minX + 8),
                                 visible.maxX - frame.width - 8)
        }

        let win = EditorWindow(contentRect: frame, styleMask: [.borderless],
                               backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.level = .floating
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.isMovableByWindowBackground = false

        let container = FlippedView(frame: CGRect(origin: .zero, size: frame.size))
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        canvas.frame = CGRect(origin: .zero, size: canvasSize)
        toolbar.frame = CGRect(x: 0, y: canvasSize.height,
                               width: frame.width, height: toolbarHeight)
        toolbar.autoresizingMask = [.width]
        container.addSubview(canvas)
        container.addSubview(toolbar)
        win.contentView = container

        wire(win)

        window = win
        whilePresented = self
        win.alphaValue = 0
        win.setFrame(frame.insetBy(dx: frame.width * 0.008, dy: frame.height * 0.008),
                     display: false)
        win.makeKeyAndOrderFront(nil)
        win.makeFirstResponder(canvas)
        NSApp.activate(ignoringOtherApps: true)

        Motion.animate(Motion.Duration.entrance) { _ in
            win.animator().alphaValue = 1
            win.animator().setFrame(frame, display: true)
        }

        toolbar.refresh(canvas: canvas)
        canvas.startIdleWatch(after: Settings.shared.autoFinishSeconds)
    }

    private func wire(_ win: NSWindow) {
        canvas.onFinish   = { [weak self] in self?.finish(mode: .copyImage) }
        canvas.onCopyText = { [weak self] in self?.finish(mode: .copyText) }
        canvas.onSave     = { [weak self] in self?.finish(mode: .saveOnly) }
        canvas.onCancel   = { [weak self] in self?.dismiss(cancelled: true) }
        canvas.onStateChange = { [weak self] in
            guard let self else { return }
            self.toolbar.refresh(canvas: self.canvas)
        }

        toolbar.onPickColor = { [weak self] index in
            guard let self else { return }
            if case .selected(let id) = self.canvas.mode {
                self.canvas.document.setColor(wheelIndex: index, for: id)
                self.canvas.needsDisplay = true
                self.toolbar.refresh(canvas: self.canvas)
            }
        }
        toolbar.onCopy = { [weak self] in self?.finish(mode: .copyImage) }
        toolbar.onUndo = { [weak self] in
            guard let self else { return }
            self.canvas.performUndo()
            self.toolbar.refresh(canvas: self.canvas)
        }
        toolbar.onCancel = { [weak self] in self?.dismiss(cancelled: true) }

        canvas.onIdleWithNothingMarked = { [weak self] in self?.finish(mode: .copyImage) }
    }

    // MARK: Finishing

    private enum FinishMode { case copyImage, copyText, saveOnly }

    private func finish(mode: FinishMode) {
        // A plain capture is a legitimate result. The first version refused to
        // copy until something was marked, which treated "screenshot" as an
        // error state — it is the thing the app produces.
        canvas.markFinishing()

        let options = Compositor.Options.fromSettings(
            scale: canvas.imageSizePx.width / canvas.bounds.width)
        guard let composited = Compositor.render(base: canvasImage(),
                                                 annotations: canvas.document.annotations,
                                                 options: options) else { return }

        var url: URL?
        // The file is always written: it is what the drag-out and the
        // path-copy both stand on, and Claude Code and Codex want a path.
        url = try? Output.write(composited)

        switch mode {
        case .copyImage:
            Output.copyImage(composited)
        case .copyText:
            let text = PromptGenerator.text(for: canvas.document.annotations)
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
        case .saveOnly:
            if let url { Output.copyPath(url) }
        }

        onFinished?(composited, url, canvas.document.annotations)
        dismiss(cancelled: false)
    }

    private func canvasImage() -> CGImage { canvas.baseImage }

    // MARK: Hooks for the headless state snapshots

    var canvasForTesting: CanvasView { canvas }

    /// Reopens with markup intact — the corner card's undo.
    func restore(_ annotations: [Annotation]) {
        canvas.document.load(annotations)
        canvas.needsDisplay = true
        toolbar.refresh(canvas: canvas)
    }
    var contentViewForTesting: NSView? { window?.contentView }
    func refreshToolbar() { toolbar.refresh(canvas: canvas) }

    private func dismiss(cancelled: Bool) {
        guard let win = window else { return }
        Motion.animate(Motion.Duration.quick) { _ in
            win.animator().alphaValue = 0
        } completion: { [weak self] in
            win.orderOut(nil)
            self?.window = nil
            if cancelled { self?.onCancelled?() }
            self?.whilePresented = nil
        }
    }
}

/// Borderless windows are not key by default, and every shortcut depends on it.
final class EditorWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
