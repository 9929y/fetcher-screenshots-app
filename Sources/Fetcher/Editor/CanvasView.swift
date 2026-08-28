import AppKit

/// The annotation surface.
///
/// Coordinates: the view is `isFlipped`, measured in points; annotation rects
/// are in image pixels. One conversion at the boundary, and the drawing code is
/// shared with the exporter by scaling the CTM — so the canvas is a preview of
/// the export rather than a second implementation that has to agree with it.
final class CanvasView: NSView {

    // MARK: State

    /// Every interactive state the surface can be in. Naming them explicitly —
    /// rather than inferring from a pile of booleans — is what keeps the
    /// feedback for each one honest.
    enum Mode: Equatable {
        case idle                                  // nothing selected
        case hovering(Annotation.ID)               // pointer over a box
        case drawing(anchor: CGPoint, to: CGPoint) // dragging out a new box
        case selected(Annotation.ID)               // handles visible
        case moving(Annotation.ID)                 // dragging a box
        case resizing(Annotation.ID, Handle)       // dragging a handle
        case editing(Annotation.ID)                // note field open and focused
        case finishing                             // export in flight, input ignored
    }

    enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        var cursor: NSCursor {
            switch self {
            case .top, .bottom:               return .resizeUpDown
            case .left, .right:               return .resizeLeftRight
            default:                          return .crosshair
            }
        }
    }

    private(set) var mode: Mode = .idle {
        didSet { if mode != oldValue { modeChanged(from: oldValue) } }
    }

    // MARK: Model & wiring

    let document = MarkupDocument()
    private let image: CGImage
    private let imageScale: CGFloat
    private let overDark: Bool

    var onFinish: (() -> Void)?
    var onCopyText: (() -> Void)?
    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?
    var onStateChange: (() -> Void)?

    private var motions: [Annotation.ID: AnnotationMotion] = [:]
    private var emptyHint = Tween(1)
    private var ticker: Timer?

    /// Fires when a capture has been sitting untouched with nothing marked on
    /// it. A plain screenshot should not need a keystroke to become useful.
    var onIdleWithNothingMarked: (() -> Void)?
    private var idleTimer: Timer?

    private var noteField: NoteFieldView?
    private var noteBackup: String = ""
    private var dragOrigin: CGRect = .zero
    private var grabOffset: CGSize = .zero

    private var now: CFTimeInterval { CACurrentMediaTime() }

    // MARK: Init

    init(image: CGImage, scale: CGFloat) {
        self.image = image
        self.imageScale = scale
        self.overDark = Compositor.isDark(image)
        super.init(frame: NSRect(x: 0, y: 0,
                                 width: CGFloat(image.width) / scale,
                                 height: CGFloat(image.height) / scale))
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }

    var imageSizePx: CGSize { CGSize(width: image.width, height: image.height) }
    var baseImage: CGImage { image }
    var isOverDark: Bool { overDark }

    // MARK: Coordinates

    private func px(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * imageScale, y: p.y * imageScale) }
    private func pt(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX / imageScale, y: r.minY / imageScale,
               width: r.width / imageScale, height: r.height / imageScale)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let t = now

        NSImage(cgImage: image, size: bounds.size).draw(in: bounds)

        // Annotations, drawn by the exporter's own code at 1/scale.
        ctx.saveGState()
        ctx.scaleBy(x: 1 / imageScale, y: 1 / imageScale)
        for (i, a) in document.annotations.enumerated() {
            let m = motions[a.id] ?? AnnotationMotion()
            let alive = m.alive.value(at: t)
            guard alive > 0.01 else { continue }
            Compositor.drawAnnotation(
                a, number: i + 1, scale: imageScale, imageSize: imageSizePx,
                overDark: overDark,
                alpha: m.dim.value(at: t) * alive,
                badgeScale: m.badgePulse.value(at: t)
            )
        }
        ctx.restoreGState()

        // Editor-only chrome. None of this reaches the PNG.
        for (i, a) in document.annotations.enumerated() {
            let m = motions[a.id] ?? AnnotationMotion()
            drawHoverGlow(a, amount: m.hover.value(at: t) * m.dim.value(at: t))
            drawHandles(a, amount: m.select.value(at: t))
            drawNoteLabel(a, number: i + 1, dim: m.dim.value(at: t) * m.alive.value(at: t))
        }

        if case .drawing(let anchor, let to) = mode {
            drawPendingBox(from: anchor, to: to)
        }
        if case .moving(let id) = mode, let a = document.annotation(id) {
            drawSizeChip(for: pt(a.rect), text: offsetText(a.rect))
        }
        if case .resizing(let id, _) = mode, let a = document.annotation(id) {
            drawSizeChip(for: pt(a.rect), text: sizeText(a.rect))
        }

        reconcileEmptyHint()
        drawEmptyHint(amount: emptyHint.value(at: t))
        scheduleTickIfNeeded()
    }

    /// Derived from the document rather than set at the end of a drag — the
    /// hint is a statement about whether anything is marked, so any path that
    /// adds or removes a box has to affect it, not just the mouse path.
    private func reconcileEmptyHint() {
        emptyHint.set(document.isEmpty ? 1 : 0,
                      duration: Motion.Duration.standard, now: now)
    }

    /// A committed note, shown under its box.
    ///
    /// The export deliberately keeps notes off the image — a sentence pasted
    /// over a design covers the thing being judged. The *editor* is a different
    /// surface: here you need to see what you already wrote, or you are marking
    /// up blind and cannot tell an empty box from a described one. So the note
    /// is on the canvas while working and in the legend when exported.
    private func noteLabelRect(_ a: Annotation) -> CGRect? {
        let note = a.note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { return nil }

        let box = pt(a.rect)
        let width = min(max(200, box.width), bounds.width - 24)
        let inset: CGFloat = 8
        let textWidth = width - inset * 2
        let shown = displayNote(a, width: textWidth)
        let bounding = (shown as NSString).boundingRect(
            with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: noteLabelAttributes(a))
        let height = bounding.height.rounded(.up) + inset * 2

        var x = min(max(8, box.minX), max(8, bounds.width - width - 8))
        var y = box.maxY + 6
        if y + height > bounds.height - 8 { y = box.minY - height - 6 }
        y = min(max(8, y), max(8, bounds.height - height - 8))
        _ = x
        x = min(max(8, box.minX), max(8, bounds.width - width - 8))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private var labelLineHeight: CGFloat { 15 }

    /// Always word-wrapping.
    ///
    /// `byTruncatingTail` does not mean "wrap, then ellipsize the last line" —
    /// it means "put it all on one line and ellipsize". Using it to measure
    /// reports one line's height; using it to draw renders one line. Both were
    /// wrong here in different ways. Wrapping is the only correct mode, and the
    /// ellipsis has to be produced by shortening the string.
    private func noteLabelAttributes(_ a: Annotation) -> [NSAttributedString.Key: Any] {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        return [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: Palette.color(a.wheelIndex),
            .paragraphStyle: para
        ]
    }

    /// The note shortened to whatever fits in two lines, with an ellipsis if
    /// anything was dropped. Exposed so a test can assert on the actual string
    /// rather than on a height that happens to look right.
    func displayNote(_ a: Annotation, width: CGFloat) -> String {
        let note = a.note.trimmingCharacters(in: .whitespacesAndNewlines)
        let attrs = noteLabelAttributes(a)
        let limit = labelLineHeight * 2 + 1

        func height(_ text: String) -> CGFloat {
            (text as NSString).boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attrs).height
        }
        guard height(note) > limit else { return note }

        // Longest prefix that still fits, by word.
        let words = note.split(separator: " ", omittingEmptySubsequences: false)
        var low = 0, high = words.count
        while low < high {
            let mid = (low + high + 1) / 2
            if height(words.prefix(mid).joined(separator: " ") + "…") <= limit {
                low = mid
            } else {
                high = mid - 1
            }
            if low == high { break }
        }
        return words.prefix(max(1, low)).joined(separator: " ") + "…"
    }

    private func drawNoteLabel(_ a: Annotation, number: Int, dim: CGFloat) {
        // While a note is being edited the field itself is there; two of them
        // would be one too many.
        if case .editing(let id) = mode, id == a.id { return }
        guard dim > 0.02, let r = noteLabelRect(a) else { return }

        let ctx = NSGraphicsContext.current?.cgContext
        ctx?.saveGState()
        ctx?.setAlpha(dim)

        let ground = overDark ? NSColor(calibratedWhite: 0.11, alpha: 0.96)
                              : NSColor(calibratedWhite: 1.0, alpha: 0.96)
        ground.setFill()
        let path = NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7)
        path.fill()
        Palette.color(a.wheelIndex).withAlphaComponent(0.45).setStroke()
        path.lineWidth = 1
        path.stroke()

        let shown = displayNote(a, width: r.width - 16)
        (shown as NSString).draw(
            with: r.insetBy(dx: 8, dy: 8),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: noteLabelAttributes(a))

        ctx?.restoreGState()
    }

    private func drawHoverGlow(_ a: Annotation, amount: CGFloat) {
        guard amount > 0.01 else { return }
        let r = pt(a.rect).insetBy(dx: -3, dy: -3)
        Palette.color(a.wheelIndex).withAlphaComponent(0.22 * amount).setStroke()
        let path = NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5)
        path.lineWidth = 4 * amount
        path.stroke()
    }

    private func drawHandles(_ a: Annotation, amount: CGFloat) {
        guard amount > 0.01 else { return }
        let r = pt(a.rect)
        let color = Palette.color(a.wheelIndex)
        let side = 8 * (0.7 + 0.3 * amount)

        let badge = Compositor.badgeRect(for: a.rect, scale: imageScale,
                                         imageSize: imageSizePx)
        for h in Handle.allCases {
            // The badge sits on the top-left corner and carries the number, so
            // that corner is not available for a handle. bottomRight resizes
            // from the opposite corner and does the same job.
            if h == .topLeft && !badge.leader { continue }
            let c = handleCenter(h, in: r)
            let box = CGRect(x: c.x - side / 2, y: c.y - side / 2, width: side, height: side)
            NSColor.white.withAlphaComponent(amount).setFill()
            let path = NSBezierPath(roundedRect: box, xRadius: 2, yRadius: 2)
            path.fill()
            color.withAlphaComponent(amount).setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }
    }

    private func drawPendingBox(from anchor: CGPoint, to: CGPoint) {
        let r = normalized(anchor, to)
        let color = Palette.color(document.nextWheelIndex)

        // Dashed while provisional, solid once committed — the transition is
        // the confirmation that a box now exists.
        let path = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
        path.lineWidth = 2
        path.setLineDash([5, 3], count: 2, phase: 0)
        color.setStroke()
        path.stroke()

        color.withAlphaComponent(0.07).setFill()
        path.fill()

        drawSizeChip(for: r, text: sizeText(CGRect(x: 0, y: 0,
                                                   width: r.width * imageScale,
                                                   height: r.height * imageScale)))
    }

    private func sizeText(_ pxRect: CGRect) -> String {
        "\(Int(pxRect.width.rounded())) × \(Int(pxRect.height.rounded()))"
    }

    private func offsetText(_ pxRect: CGRect) -> String {
        "\(Int(pxRect.minX.rounded())), \(Int(pxRect.minY.rounded()))"
    }

    private func drawSizeChip(for viewRect: CGRect, text: String) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let padX: CGFloat = 6, padY: CGFloat = 3
        var chip = CGRect(x: viewRect.minX,
                          y: viewRect.maxY + 6,
                          width: size.width + padX * 2,
                          height: size.height + padY * 2)
        if chip.maxY > bounds.maxY - 4 { chip.origin.y = viewRect.minY - chip.height - 6 }
        chip.origin.y = max(4, chip.origin.y)
        chip.origin.x = min(max(4, chip.origin.x), bounds.maxX - chip.width - 4)

        Theme.accent.withAlphaComponent(0.94).setFill()
        NSBezierPath(roundedRect: chip, xRadius: 4, yRadius: 4).fill()
        (text as NSString).draw(at: CGPoint(x: chip.minX + padX, y: chip.minY + padY),
                                withAttributes: attrs)
    }

    /// Reads as a control, not a watermark.
    ///
    /// The first version was translucent white text on a translucent white
    /// ground: over a light screenshot it disappeared into whatever was behind
    /// it, which is the one thing a hint must not do.
    private func drawEmptyHint(amount: CGFloat) {
        guard amount > 0.01 else { return }
        let text = "Drag to mark an area"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
            .foregroundColor: (overDark ? NSColor.white : NSColor(calibratedWhite: 0.12, alpha: 1))
                .withAlphaComponent(amount)
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let padX: CGFloat = 16, padY: CGFloat = 10
        let chip = CGRect(x: (bounds.width - (size.width + padX * 2)) / 2,
                          y: (bounds.height - (size.height + padY * 2)) / 2,
                          width: size.width + padX * 2,
                          height: size.height + padY * 2)

        let ctx = NSGraphicsContext.current?.cgContext
        ctx?.saveGState()
        ctx?.setAlpha(amount)
        ctx?.setShadow(offset: CGSize(width: 0, height: -2), blur: 10,
                       color: NSColor.black.withAlphaComponent(0.18).cgColor)

        (overDark ? NSColor(calibratedWhite: 0.14, alpha: 1)
                  : NSColor(calibratedWhite: 1, alpha: 1)).setFill()
        let path = NSBezierPath(roundedRect: chip, xRadius: 9, yRadius: 9)
        path.fill()
        ctx?.setShadow(offset: .zero, blur: 0, color: nil)

        Theme.accent.withAlphaComponent(0.55).setStroke()
        path.lineWidth = 1.5
        path.stroke()
        ctx?.restoreGState()

        (text as NSString).draw(at: CGPoint(x: chip.minX + padX, y: chip.minY + padY),
                                withAttributes: attrs)
    }

    // MARK: Geometry

    private func normalized(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private func handleCenter(_ h: Handle, in r: CGRect) -> CGPoint {
        switch h {
        case .topLeft:     return CGPoint(x: r.minX, y: r.minY)
        case .top:         return CGPoint(x: r.midX, y: r.minY)
        case .topRight:    return CGPoint(x: r.maxX, y: r.minY)
        case .right:       return CGPoint(x: r.maxX, y: r.midY)
        case .bottomRight: return CGPoint(x: r.maxX, y: r.maxY)
        case .bottom:      return CGPoint(x: r.midX, y: r.maxY)
        case .bottomLeft:  return CGPoint(x: r.minX, y: r.maxY)
        case .left:        return CGPoint(x: r.minX, y: r.midY)
        }
    }

    private func handle(at p: CGPoint, of a: Annotation) -> Handle? {
        let r = pt(a.rect)
        let badge = Compositor.badgeRect(for: a.rect, scale: imageScale,
                                         imageSize: imageSizePx)
        return Handle.allCases.first { h in
            if h == .topLeft && !badge.leader { return false }
            let c = handleCenter(h, in: r)
            return abs(c.x - p.x) <= 6 && abs(c.y - p.y) <= 6
        }
    }

    private func resized(_ r: CGRect, handle h: Handle, to p: CGPoint) -> CGRect {
        var out = r
        switch h {
        case .topLeft:     out = CGRect(x: p.x, y: p.y, width: r.maxX - p.x, height: r.maxY - p.y)
        case .top:         out = CGRect(x: r.minX, y: p.y, width: r.width, height: r.maxY - p.y)
        case .topRight:    out = CGRect(x: r.minX, y: p.y, width: p.x - r.minX, height: r.maxY - p.y)
        case .right:       out = CGRect(x: r.minX, y: r.minY, width: p.x - r.minX, height: r.height)
        case .bottomRight: out = CGRect(x: r.minX, y: r.minY, width: p.x - r.minX, height: p.y - r.minY)
        case .bottom:      out = CGRect(x: r.minX, y: r.minY, width: r.width, height: p.y - r.minY)
        case .bottomLeft:  out = CGRect(x: p.x, y: r.minY, width: r.maxX - p.x, height: p.y - r.minY)
        case .left:        out = CGRect(x: p.x, y: r.minY, width: r.maxX - p.x, height: r.height)
        }
        return CGRect(x: out.minX, y: out.minY,
                      width: max(8 * imageScale, out.width),
                      height: max(8 * imageScale, out.height))
    }

    // MARK: Animation

    private func motion(_ id: Annotation.ID) -> AnnotationMotion {
        motions[id] ?? AnnotationMotion()
    }

    private func mutate(_ id: Annotation.ID, _ body: (inout AnnotationMotion) -> Void) {
        var m = motion(id)
        body(&m)
        motions[id] = m
        needsDisplay = true
    }

    private func scheduleTickIfNeeded() {
        let t = now
        let busy = motions.values.contains { $0.isAnimating(at: t) }
            || emptyHint.isAnimating(at: t)
        if busy && ticker == nil {
            ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.needsDisplay = true
                let t = self.now
                let stillBusy = self.motions.values.contains { $0.isAnimating(at: t) }
                    || self.emptyHint.isAnimating(at: t)
                if !stillBusy { self.ticker?.invalidate(); self.ticker = nil }
            }
            RunLoop.main.add(ticker!, forMode: .eventTracking)
        }
    }

    private func modeChanged(from old: Mode) {
        let t = now
        // Dimming: while a note is being written, every other box steps back so
        // there is no question which one the words belong to.
        let focused: Annotation.ID? = {
            if case .editing(let id) = mode { return id }
            return nil
        }()
        for a in document.annotations {
            mutate(a.id) { $0.dim.set(focused == nil || focused == a.id ? 1 : 0.32,
                                      duration: Motion.Duration.standard, now: t) }
        }

        let selected: Annotation.ID? = {
            switch mode {
            case .selected(let id), .moving(let id), .resizing(let id, _), .editing(let id):
                return id
            default: return nil
            }
        }()
        for a in document.annotations {
            mutate(a.id) { $0.select.set(selected == a.id ? 1 : 0,
                                         duration: Motion.Duration.quick, now: t) }
        }

        let hovered: Annotation.ID? = {
            if case .hovering(let id) = mode { return id }
            return nil
        }()
        for a in document.annotations {
            mutate(a.id) { $0.hover.set(hovered == a.id ? 1 : 0,
                                        duration: Motion.Duration.quick, now: t) }
        }

        _ = old
        onStateChange?()
        needsDisplay = true
    }

    // MARK: Mouse

    override func mouseMoved(with event: NSEvent) {
        cancelIdleWatch()
        guard !isEditing else { return }
        let p = convert(event.locationInWindow, from: nil)

        if case .selected(let id) = mode, let a = document.annotation(id),
           let h = handle(at: p, of: a) {
            h.cursor.set()
            return
        }
        if let hit = document.hits(at: px(p)).first {
            NSCursor.openHand.set()
            if case .selected = mode {} else { mode = .hovering(hit.id) }
        } else {
            NSCursor.crosshair.set()
            if case .hovering = mode { mode = .idle }
        }
    }

    override func mouseDown(with event: NSEvent) {
        cancelIdleWatch()
        guard !isFinishing else { return }
        let p = convert(event.locationInWindow, from: nil)

        // Committing whatever is being typed before starting something new is
        // what makes drag-type-return-drag work without an explicit step.
        if isEditing { commitNote(advance: false) }

        if case .selected(let id) = mode, let a = document.annotation(id),
           let h = handle(at: p, of: a) {
            dragOrigin = a.rect
            mode = .resizing(id, h)
            return
        }

        // A visible note is an editable note — clicking the label opens it.
        if let labelled = document.annotations.reversed().first(where: {
            noteLabelRect($0)?.contains(p) == true
        }) {
            beginEditing(labelled.id)
            return
        }

        if let hit = document.hits(at: px(p)).first {
            if event.clickCount >= 2 { beginEditing(hit.id); return }
            dragOrigin = hit.rect
            grabOffset = CGSize(width: px(p).x - hit.rect.minX, height: px(p).y - hit.rect.minY)
            mode = .moving(hit.id)
            return
        }

        mode = .drawing(anchor: p, to: p)
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch mode {
        case .drawing(let anchor, _):
            mode = .drawing(anchor: anchor, to: p)
        case .moving(let id):
            let target = CGRect(x: px(p).x - grabOffset.width, y: px(p).y - grabOffset.height,
                                width: dragOrigin.width, height: dragOrigin.height)
            document.setRect(clamped(target), for: id, checkpointing: false)
            needsDisplay = true
        case .resizing(let id, let h):
            document.setRect(clamped(resized(dragOrigin, handle: h, to: px(p))),
                             for: id, checkpointing: false)
            needsDisplay = true
        default:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch mode {
        case .drawing(let anchor, _):
            let r = normalized(anchor, p)
            // A click is not a box. Below the threshold, deselect instead —
            // throwing the markup away over a stray click would be hostile.
            guard r.width >= 6, r.height >= 6 else { mode = .idle; return }
            let a = document.add(rect: clamped(CGRect(x: r.minX * imageScale,
                                                      y: r.minY * imageScale,
                                                      width: r.width * imageScale,
                                                      height: r.height * imageScale)))
            motions[a.id] = AnnotationMotion()
            beginEditing(a.id)
        case .moving(let id), .resizing(let id, _):
            mode = .selected(id)
        default:
            break
        }
    }

    private func clamped(_ r: CGRect) -> CGRect {
        var out = r
        out.size.width = min(out.width, imageSizePx.width)
        out.size.height = min(out.height, imageSizePx.height)
        out.origin.x = min(max(0, out.minX), imageSizePx.width - out.width)
        out.origin.y = min(max(0, out.minY), imageSizePx.height - out.height)
        return out
    }

    // MARK: Note editing

    private var isEditing: Bool { if case .editing = mode { return true }; return false }
    private var isFinishing: Bool { if case .finishing = mode { return true }; return false }

    func beginEditing(_ id: Annotation.ID) {
        guard let a = document.annotation(id) else { return }
        noteBackup = a.note
        document.beginNoteEdit(id)

        let field = noteField ?? makeNoteField()
        field.wheelIndex = a.wheelIndex
        field.overDark = overDark
        field.textView.string = a.note
        field.alphaValue = 0
        if field.superview == nil { addSubview(field) }

        mode = .editing(id)
        layoutNoteField()
        field.focus()

        // A short rise-and-fade in. Anything longer gets in the way of typing.
        let target = field.frame
        field.frame = target.offsetBy(dx: 0, dy: 6)
        Motion.animate(Motion.Duration.standard) { _ in
            field.animator().alphaValue = 1
            field.animator().frame = target
        }
    }

    private func makeNoteField() -> NoteFieldView {
        let field = NoteFieldView()
        field.onCommit = { [weak self] in self?.commitNote(advance: true) }
        field.onCancel = { [weak self] in self?.cancelNote() }
        field.onAdvance = { [weak self] fwd in self?.commitAndWalk(forward: fwd) }
        field.onHeightChange = { [weak self] in self?.layoutNoteField() }
        field.onColorOverride = { [weak self] index in
            guard let self, case .editing(let id) = self.mode else { return }
            self.document.setColor(wheelIndex: index, for: id)
            self.noteField?.wheelIndex = index
            self.needsDisplay = true
        }
        noteField = field
        return field
    }

    private func layoutNoteField() {
        guard let field = noteField, case .editing(let id) = mode,
              let a = document.annotation(id) else { return }
        let box = pt(a.rect)
        let width = min(max(260, box.width), bounds.width - 24)
        let height = field.fittingHeight(forWidth: width)

        var x = box.minX
        x = min(max(12, x), max(12, bounds.width - width - 12))
        var y = box.maxY + 8
        if y + height > bounds.height - 12 { y = box.minY - height - 8 }
        y = min(max(12, y), max(12, bounds.height - height - 12))

        field.frame = CGRect(x: x, y: y, width: width, height: height)
        field.layoutSubtreeIfNeeded()
    }

    private func liveNote() -> String {
        noteField?.textView.string ?? ""
    }

    /// Commit and, by default, arm the next box: focus returns to the canvas so
    /// the very next drag starts a new annotation.
    func commitNote(advance: Bool) {
        guard case .editing(let id) = mode else { return }
        document.setNote(liveNote(), for: id)
        closeNoteField()

        if document.annotation(id)?.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            pulseBadge(id)
        }
        mode = advance ? .idle : .selected(id)
        window?.makeFirstResponder(self)
        onStateChange?()
    }

    /// esc: put the text back. On a box that never had a note, the box itself
    /// was the accident — remove it.
    private func cancelNote() {
        guard case .editing(let id) = mode else { return }
        let neverHadANote = noteBackup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        closeNoteField()

        if neverHadANote {
            deleteAnnotation(id)
        } else {
            document.setNote(noteBackup, for: id)
            mode = .selected(id)
        }
        window?.makeFirstResponder(self)
        onStateChange?()
    }

    /// tab: commit and edit the neighbour, so a markup can be revised entirely
    /// from the keyboard.
    private func commitAndWalk(forward: Bool) {
        guard case .editing(let id) = mode,
              let i = document.annotations.firstIndex(where: { $0.id == id }) else { return }
        document.setNote(liveNote(), for: id)
        let n = document.count
        guard n > 1 else { commitNote(advance: false); return }
        let next = document.annotations[(i + (forward ? 1 : n - 1)) % n].id
        closeNoteField()
        beginEditing(next)
    }

    private func closeNoteField() {
        guard let field = noteField else { return }
        Motion.animate(Motion.Duration.quick) { _ in
            field.animator().alphaValue = 0
        } completion: {
            field.removeFromSuperview()
        }
        noteField = nil
    }

    private func pulseBadge(_ id: Annotation.ID) {
        mutate(id) { $0.badgePulse.set(1.18, duration: 0.13, curve: .spring, now: now) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) { [weak self] in
            guard let self else { return }
            self.mutate(id) { $0.badgePulse.set(1, duration: 0.17, curve: .easeOut, now: self.now) }
        }
    }

    private func deleteAnnotation(_ id: Annotation.ID) {
        mutate(id) { $0.alive.set(0, duration: Motion.Duration.quick, now: now) }
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.Duration.quick) { [weak self] in
            guard let self else { return }
            self.document.delete(id)
            self.motions[id] = nil
            self.mode = .idle
            self.needsDisplay = true
            self.onStateChange?()
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        cancelIdleWatch()
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers ?? ""
        if mods.contains(.command) {
            switch chars.lowercased() {
            case "\r": onFinish?(); return
            case "z":
                mods.contains(.shift) ? performRedo() : performUndo()
                return
            case "s": onSave?(); return
            // cmd-C is what every hand reaches for. cmd-return stays as the
            // one that also means "and I'm done here".
            case "c" where !mods.contains(.option): onFinish?(); return
            case "c" where mods.contains(.option): onCopyText?(); return
            default: break
            }
        }
        if event.keyCode == 36, mods.contains(.command) { onFinish?(); return }

        switch event.keyCode {
        case 36:                                   // return
            switch mode {
            case .selected(let id), .hovering(let id): beginEditing(id)
            case .idle:
                if let first = document.annotations.first { mode = .selected(first.id) }
            default: break
            }
            return
        case 53:                                   // esc — one level at a time
            switch mode {
            case .selected, .hovering: mode = .idle
            case .idle: onCancel?()
            default: mode = .idle
            }
            return
        case 48:                                   // tab
            cycleSelection(forward: !mods.contains(.shift))
            return
        case 51, 117:                              // delete / forward delete
            if case .selected(let id) = mode { deleteAnnotation(id) }
            return
        case 123, 124, 125, 126:                   // arrows
            nudge(keyCode: event.keyCode, mods: mods)
            return
        default:
            break
        }

        // 1–0 recolor the selection. Unmodified here because the canvas has no
        // text entry; inside the note field the same job needs option.
        if !mods.contains(.command), chars.count == 1, let digit = Int(chars),
           case .selected(let id) = mode {
            document.setColor(wheelIndex: digit == 0 ? 9 : digit - 1, for: id)
            needsDisplay = true
            onStateChange?()
            return
        }

        super.keyDown(with: event)
    }

    private func cycleSelection(forward: Bool) {
        guard !document.isEmpty else { return }
        let n = document.count
        let currentIndex: Int? = {
            if case .selected(let id) = mode {
                return document.annotations.firstIndex { $0.id == id }
            }
            return nil
        }()
        let next = currentIndex.map { ($0 + (forward ? 1 : n - 1)) % n } ?? (forward ? 0 : n - 1)
        mode = .selected(document.annotations[next].id)
    }

    private func nudge(keyCode: UInt16, mods: NSEvent.ModifierFlags) {
        guard case .selected(let id) = mode, let a = document.annotation(id) else { return }
        let step: CGFloat = (mods.contains(.shift) ? 10 : 1) * imageScale
        let dx: CGFloat = keyCode == 123 ? -step : (keyCode == 124 ? step : 0)
        let dy: CGFloat = keyCode == 126 ? -step : (keyCode == 125 ? step : 0)

        // option turns the arrows into a resize, which is the only way to size
        // a box precisely without a mouse.
        let r = mods.contains(.option)
            ? CGRect(x: a.rect.minX, y: a.rect.minY,
                     width: max(8 * imageScale, a.rect.width + dx),
                     height: max(8 * imageScale, a.rect.height + dy))
            : a.rect.offsetBy(dx: dx, dy: dy)

        document.setRect(clamped(r), for: id, checkpointing: true)
        needsDisplay = true
    }

    func performUndo() {
        document.undo()
        rebuildMotionsAfterHistory()
    }

    func performRedo() {
        document.redo()
        rebuildMotionsAfterHistory()
    }

    private func rebuildMotionsAfterHistory() {
        // History jumps are not transitions the user performed on each box, so
        // the motion state is snapped rather than animated.
        var rebuilt: [Annotation.ID: AnnotationMotion] = [:]
        for a in document.annotations {
            rebuilt[a.id] = motions[a.id] ?? AnnotationMotion()
        }
        motions = rebuilt
        emptyHint.snap(document.isEmpty ? 1 : 0)
        mode = .idle
        needsDisplay = true
        onStateChange?()
    }

    // MARK: Tracking

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        ))
        emptyHint.snap(document.isEmpty ? 1 : 0)
    }

    func markFinishing() {
        cancelIdleWatch()
        mode = .finishing
    }

    /// Starts the countdown for an untouched, unmarked capture. Any input at
    /// all cancels it permanently — if you are here, you are using it.
    func startIdleWatch(after seconds: TimeInterval) {
        cancelIdleWatch()
        guard seconds > 0 else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) {
            [weak self] _ in
            guard let self, self.document.isEmpty else { return }
            self.onIdleWithNothingMarked?()
        }
    }

    private func cancelIdleWatch() {
        idleTimer?.invalidate()
        idleTimer = nil
    }

    /// The on-canvas note label, for the end-to-end driver.
    func noteLabelRectForTesting(_ a: Annotation) -> CGRect? { noteLabelRect(a) }

    /// Drives the surface into a state without input, for the headless
    /// state snapshots. Not reachable from the UI.
    func debugSetMode(_ m: Mode) { mode = m }
}
