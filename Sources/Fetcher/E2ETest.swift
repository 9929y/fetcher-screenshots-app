import AppKit

/// End-to-end tests that drive the real event handlers.
///
/// The unit checks cover the model, the compositor and the detector; the state
/// snapshots cover what things look like. Neither covers the part the whole
/// design rests on — that a drag really produces a box, that the caret really
/// lands in the note field without a click, that return really commits and
/// re-arms. Those are event-chain claims, and the only honest way to check them
/// is to send events.
///
/// Synthetic `NSEvent`s dispatched straight to the views, in-process: no
/// Accessibility grant, no window server automation, and every real handler,
/// responder and animation on the path.
@MainActor
enum E2ETest {

    private static var failures = 0
    private static var checks = 0

    static func run() {
        Task { @MainActor in
            print("[fetcher] end-to-end\n")

            await coreLoop()
            await keyboardEditing()
            await cancelling()
            await promptOutput()
            await regionSelection()
            await multipleDisplays()
            await plainCapture()
            await visibleNotes()

            print("\n[fetcher] \(checks) checks, \(failures) failed")
            NSApp.terminate(nil)
        }
    }

    // MARK: Harness

    private static func check(_ label: String, _ ok: Bool, _ detail: String = "") {
        checks += 1
        if !ok { failures += 1 }
        print("    \(ok ? "pass" : "FAIL")  \(label)" + (detail.isEmpty ? "" : "  [\(detail)]"))
    }

    private static func settle(_ seconds: Double = 0.25) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static func makeEditor() -> (EditorWindowController, CanvasView, CGImage)? {
        guard let base = SyntheticScreen.make(size: CGSize(width: 900, height: 560),
                                              scale: 2, dark: false) else { return nil }
        let controller = EditorWindowController(
            image: base, scale: 2,
            regionOnScreen: CGRect(x: 120, y: 240, width: 900, height: 560))
        controller.show()
        return (controller, controller.canvasForTesting, base)
    }

    // MARK: Event construction

    private static func mouse(_ type: NSEvent.EventType, at canvasPoint: CGPoint,
                              in view: NSView, clickCount: Int = 1) -> NSEvent? {
        guard let window = view.window else { return nil }
        let inWindow = view.convert(canvasPoint, to: nil)
        return NSEvent.mouseEvent(
            with: type, location: inWindow, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: clickCount, pressure: 1)
    }

    private static func key(_ keyCode: UInt16, _ chars: String = "",
                            _ flags: NSEvent.ModifierFlags = [],
                            in view: NSView) -> NSEvent? {
        guard let window = view.window else { return nil }
        return NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            characters: chars, charactersIgnoringModifiers: chars,
            isARepeat: false, keyCode: keyCode)
    }

    /// One drag, as three events, exactly as a trackpad delivers it.
    private static func drag(from: CGPoint, to: CGPoint, in canvas: CanvasView) async {
        if let e = mouse(.leftMouseDown, at: from, in: canvas) { canvas.mouseDown(with: e) }
        let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
        if let e = mouse(.leftMouseDragged, at: mid, in: canvas) { canvas.mouseDragged(with: e) }
        if let e = mouse(.leftMouseDragged, at: to, in: canvas) { canvas.mouseDragged(with: e) }
        if let e = mouse(.leftMouseUp, at: to, in: canvas) { canvas.mouseUp(with: e) }
        await settle(0.12)
    }

    private static func type(_ text: String, in canvas: CanvasView) {
        guard let field = canvas.window?.firstResponder as? NoteTextView else { return }
        field.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    private static func press(_ keyCode: UInt16, _ chars: String = "",
                              _ flags: NSEvent.ModifierFlags = [],
                              in canvas: CanvasView) {
        // Route to whatever actually has focus, the way the window would.
        let target = (canvas.window?.firstResponder as? NSView) ?? canvas
        if let e = key(keyCode, chars, flags, in: canvas) { target.keyDown(with: e) }
    }

    private enum K {
        static let ret: UInt16 = 36, tab: UInt16 = 48, esc: UInt16 = 53, delete: UInt16 = 51
        static let left: UInt16 = 123, right: UInt16 = 124
    }

    // MARK: Scenario 1 — the loop the product is

    private static func coreLoop() async {
        print("  drag, type, return — twice, then ship")
        guard let (controller, canvas, _) = makeEditor() else {
            check("editor opened", false); return
        }
        await settle(0.4)

        var finished: (image: CGImage, url: URL?)?
        controller.onFinished = { image, url, _ in finished = (image, url) }

        await drag(from: CGPoint(x: 60, y: 70), to: CGPoint(x: 460, y: 108), in: canvas)
        check("a drag creates one box", canvas.document.count == 1)
        check("its color is the first in the assignment order",
              canvas.document.annotations.first?.wheelIndex == 0,
              Palette.displayName(canvas.document.annotations.first?.wheelIndex ?? -1))

        // The core promise: no click, no tool switch — the caret is already live.
        let focused = canvas.window?.firstResponder is NoteTextView
        check("the note field takes focus with no extra input", focused)

        type("Heading is competing with the price.", in: canvas)
        press(K.ret, "\r", in: canvas)
        await settle(0.2)

        check("return commits the note",
              canvas.document.annotations.first?.note.hasPrefix("Heading") == true,
              canvas.document.annotations.first?.note ?? "empty")
        check("return hands focus back to the canvas",
              canvas.window?.firstResponder === canvas)

        // Second box, straight into another drag — nothing in between.
        await drag(from: CGPoint(x: 330, y: 215), to: CGPoint(x: 580, y: 400), in: canvas)
        check("the next drag starts a second box", canvas.document.count == 2)
        check("the second box takes the second assigned color",
              canvas.document.annotations.last?.wheelIndex == 5,
              Palette.displayName(canvas.document.annotations.last?.wheelIndex ?? -1))
        type("Middle card needs the accent border.", in: canvas)
        press(K.ret, "\r", in: canvas)
        await settle(0.2)

        NSPasteboard.general.clearContents()
        press(K.ret, "\r", .command, in: canvas)
        await settle(0.5)

        check("cmd-return produces a composited image", finished != nil,
              finished.map { "\($0.image.width)x\($0.image.height)" } ?? "nothing")
        check("the notes area is on it, below the capture",
              CGFloat(finished?.image.height ?? 0)
                  > 1120 + Compositor.M.margin * 4 + Compositor.M.marginGap * 2,
              "\(finished?.image.height ?? 0)")
        check("the PNG lands on the clipboard",
              NSPasteboard.general.data(forType: .png) != nil)
        check("a real file is written for the path-based tools",
              finished?.url.map { FileManager.default.fileExists(atPath: $0.path) } == true,
              finished?.url?.lastPathComponent ?? "none")

        if let url = finished?.url { try? FileManager.default.removeItem(at: url) }
        await settle(0.2)
    }

    // MARK: Scenario 2 — everything from the keyboard

    private static func keyboardEditing() async {
        print("\n  keyboard editing")
        guard let (_, canvas, _) = makeEditor() else { check("editor opened", false); return }
        await settle(0.4)

        for i in 0..<3 {
            await drag(from: CGPoint(x: 60 + CGFloat(i) * 120, y: 300),
                       to: CGPoint(x: 150 + CGFloat(i) * 120, y: 380), in: canvas)
            type("note \(i + 1)", in: canvas)
            press(K.ret, "\r", in: canvas)
            await settle(0.1)
        }
        check("three boxes", canvas.document.count == 3)

        press(K.tab, "\t", in: canvas)
        var selected = selectedID(canvas)
        check("tab selects the first box", selected == canvas.document.annotations[0].id)

        press(K.tab, "\t", in: canvas)
        selected = selectedID(canvas)
        check("tab again moves to the second", selected == canvas.document.annotations[1].id)

        press(0, "7", in: canvas)
        check("a digit recolors the selection",
              canvas.document.annotations[1].wheelIndex == 6,
              Palette.displayName(canvas.document.annotations[1].wheelIndex))

        let beforeNudge = canvas.document.annotations[1].rect
        press(K.right, in: canvas)
        check("an arrow nudges by one point",
              canvas.document.annotations[1].rect.minX == beforeNudge.minX + 2,
              "moved \(Int(canvas.document.annotations[1].rect.minX - beforeNudge.minX))px at 2x")

        let survivor = canvas.document.annotations[2].id
        press(K.delete, in: canvas)
        await settle(0.3)
        check("delete removes the selected box", canvas.document.count == 2)
        check("the survivors renumber", canvas.document.number(of: survivor) == 2,
              "was 3, now \(canvas.document.number(of: survivor).map(String.init) ?? "gone")")

        press(0, "z", .command, in: canvas)
        check("cmd-Z brings it back", canvas.document.count == 3)
    }

    private static func selectedID(_ canvas: CanvasView) -> Annotation.ID? {
        if case .selected(let id) = canvas.mode { return id }
        return nil
    }

    // MARK: Scenario 3 — the two meanings of escape

    private static func cancelling() async {
        print("\n  escape")
        guard let (_, canvas, _) = makeEditor() else { check("editor opened", false); return }
        await settle(0.4)

        await drag(from: CGPoint(x: 60, y: 70), to: CGPoint(x: 300, y: 140), in: canvas)
        type("this one stays", in: canvas)
        press(K.ret, "\r", in: canvas)
        await settle(0.1)

        // A stray drag nobody meant: escape should take the box with it.
        await drag(from: CGPoint(x: 400, y: 300), to: CGPoint(x: 520, y: 360), in: canvas)
        check("a second box exists before cancelling", canvas.document.count == 2)
        press(K.esc, in: canvas)
        await settle(0.35)
        check("escape on a never-noted box deletes the box too",
              canvas.document.count == 1, "\(canvas.document.count) left")

        // A box that already had a note keeps it, and keeps existing.
        press(K.tab, "\t", in: canvas)
        press(K.ret, "\r", in: canvas)
        await settle(0.25)
        check("return reopens the note for editing",
              canvas.window?.firstResponder is NoteTextView)
        type(" — edited", in: canvas)
        press(K.esc, in: canvas)
        await settle(0.25)
        check("escape reverts the text instead of deleting",
              canvas.document.count == 1
                  && canvas.document.annotations[0].note == "this one stays",
              canvas.document.annotations.first?.note ?? "gone")
    }

    // MARK: Scenario 4 — the other output

    private static func promptOutput() async {
        print("\n  prompt text")
        guard let (_, canvas, _) = makeEditor() else { check("editor opened", false); return }
        await settle(0.4)

        await drag(from: CGPoint(x: 60, y: 70), to: CGPoint(x: 300, y: 140), in: canvas)
        type("Drop the heading to 28/34.", in: canvas)
        press(K.ret, "\r", in: canvas)
        await settle(0.1)
        await drag(from: CGPoint(x: 330, y: 215), to: CGPoint(x: 580, y: 400), in: canvas)
        type("Add the accent border.", in: canvas)
        press(K.ret, "\r", in: canvas)
        await settle(0.1)

        // Deliberately discards the controller. A visible window whose
        // shortcuts have quietly stopped working is the failure this guards.
        NSPasteboard.general.clearContents()
        press(0, "c", [.command, .option], in: canvas)
        await settle(0.4)

        let text = NSPasteboard.general.string(forType: .string) ?? ""
        check("opt-cmd-C puts the instruction list on the clipboard", !text.isEmpty)
        check("items are numbered to match the badges",
              text.contains("1. (red) Drop the heading to 28/34.")
                  && text.contains("2. (teal) Add the accent border."),
              text.replacingOccurrences(of: "\n", with: " | "))
        check("the scope-limiting closer survives",
              text.contains("Change only what's listed"))
    }

    // MARK: Scenario 8 — more than one screen

    /// The pointer decides which display is being captured, including for the
    /// keyboard.
    ///
    /// This machine has one screen, so the test builds two frozen displays over
    /// it. That is enough: what is under test is the routing — which overlay
    /// owns the pointer, which owns the keyboard, and which one comes back in
    /// the result — none of which depends on the panels being physically apart.
    private static func multipleDisplays() async {
        print("\n  more than one screen")
        guard let screen = NSScreen.main,
              let left = SyntheticScreen.make(size: screen.frame.size,
                                              scale: screen.backingScaleFactor, dark: false),
              let right = SyntheticScreen.make(size: screen.frame.size,
                                               scale: screen.backingScaleFactor, dark: true)
        else { check("two fixtures", false); return }

        let scale = screen.backingScaleFactor
        let displays = [
            FrozenDisplay(screen: screen, displayID: 1, image: left, scale: scale,
                          edges: EdgeMap.build(from: left)),
            FrozenDisplay(screen: screen, displayID: 2, image: right, scale: scale,
                          edges: EdgeMap.build(from: right))
        ]

        var result: SelectionOverlay.Completion = nil
        var done = false
        let overlay = SelectionOverlay()
        overlay.present(displays) { result = $0; done = true }
        await settle(0.4)

        let views = overlay.viewsForTesting
        check("one overlay per display", views.count == 2, "\(views.count)")
        guard views.count == 2 else { return }

        let second = views[1]
        check("the second display does not hold the keyboard to begin with",
              second.window?.isKeyWindow == false)

        // Moving onto it is what hands it the keyboard. Before this fix the
        // keystroke went to whichever display the pointer started on.
        let hover = CGPoint(x: 322 * scale / scale + 254 / 2,
                            y: second.bounds.height - (210 + 190 / 2))
        if let e = mouse(.mouseMoved, at: hover, in: second) { second.mouseMoved(with: e) }
        await settle(0.2)
        check("moving the pointer onto it hands it the keyboard",
              second.window?.isKeyWindow == true)

        // The real pointer has an opinion too: making a window key prompts
        // AppKit to deliver an actual mouseMoved, which overwrites the position
        // this test just synthesised. In use that is exactly right — the
        // pointer really is where the user is hovering — so the test restates
        // where it is pretending to be, rather than the app pretending not to
        // notice.
        if let e = mouse(.mouseMoved, at: hover, in: second) { second.mouseMoved(with: e) }

        check("the frame under the pointer is found on that display",
              second.snapForTesting != nil,
              second.snapForTesting.map { "\(Int($0.width))x\(Int($0.height))pt" } ?? "nothing")

        // And return there takes that display's frame, not the other one's.
        if let e = key(36, "\r", [], in: second) { second.keyDown(with: e) }
        await settle(0.25)

        check("return on the hovered display finishes the capture", done)
        check("the capture comes from the display under the pointer",
              result?.0.displayID == 2,
              result.map { "display \($0.0.displayID)" } ?? "cancelled")
    }

    // MARK: Scenario 6 — a capture nobody marked up

    private static func plainCapture() async {
        print("\n  unmarked captures")
        let previous = Settings.shared.autoFinishSeconds
        Settings.shared.autoFinishSeconds = 0        // test the manual path first
        defer { Settings.shared.autoFinishSeconds = previous }

        guard let (controller, canvas, base) = makeEditor() else {
            check("editor opened", false); return
        }
        await settle(0.4)

        var finished: (image: CGImage, url: URL?)?
        controller.onFinished = { image, url, _ in finished = (image, url) }

        // The first version refused this outright: Copy was disabled and shook
        // when pressed. A screenshot with nothing marked on it is a screenshot.
        NSPasteboard.general.clearContents()
        press(0, "c", .command, in: canvas)
        await settle(0.5)

        check("cmd-C works with nothing marked", finished != nil)
        // Inset on its ground, but with no notes area added under it.
        let pad = Compositor.M.margin * 2
        check("and produces just the capture, with no notes area",
              CGFloat(finished?.image.height ?? 0) == CGFloat(base.height) + pad * 2,
              "\(finished?.image.height ?? 0) vs \(CGFloat(base.height) + pad * 2)")
        check("the PNG is on the clipboard",
              NSPasteboard.general.data(forType: .png) != nil)
        if let url = finished?.url { try? FileManager.default.removeItem(at: url) }

        // And left alone, it finishes itself.
        Settings.shared.autoFinishSeconds = 0.4
        guard let (controller2, _, _) = makeEditor() else {
            check("second editor opened", false); return
        }
        var autoFinished = false
        controller2.onFinished = { image, url, _ in
            autoFinished = true
            if let url { try? FileManager.default.removeItem(at: url) }
            _ = image
        }
        await settle(1.2)
        check("an untouched, unmarked capture finishes itself", autoFinished)
    }

    // MARK: Scenario 7 — notes you can see and change

    private static func visibleNotes() async {
        print("\n  notes on the canvas")
        let previous = Settings.shared.autoFinishSeconds
        Settings.shared.autoFinishSeconds = 0
        defer { Settings.shared.autoFinishSeconds = previous }

        guard let (_, canvas, _) = makeEditor() else { check("editor opened", false); return }
        await settle(0.4)

        await drag(from: CGPoint(x: 60, y: 70), to: CGPoint(x: 300, y: 140), in: canvas)
        type("Drop the heading to 28/34, weight 600 — right now it is competing with the price and pulling the eye away from it.", in: canvas)
        press(K.ret, "\r", in: canvas)
        await settle(0.25)

        guard let a = canvas.document.annotations.first else {
            check("one box", false); return
        }
        guard let label = canvas.noteLabelRectForTesting(a) else {
            check("a committed note shows on the canvas", false, "no label")
            return
        }
        check("a committed note shows on the canvas", true,
              "\(Int(label.width))x\(Int(label.height))pt")
        check("the label sits under its box",
              label.minY >= (a.rect.maxY / 2) - 1,
              "label at y \(Int(label.minY)), box ends at \(Int(a.rect.maxY / 2))")
        // Height alone was not enough: the first fix produced a two-line-tall
        // label containing one truncated line. The string being drawn has to be
        // checked, not the box around it.
        check("a note too long for one line gets two",
              label.height > 36, "\(Int(label.height))pt tall")
        let full = canvas.document.annotations[0].note
        let shown = canvas.displayNote(a, width: label.width - 16)
        let body = shown.hasSuffix("…") ? String(shown.dropLast()) : shown
        check("the ellipsis comes after two lines, not after one",
              shown.hasSuffix("…") && body.count > 45 && full.hasPrefix(body),
              "\(body.count) of \(full.count) chars kept: …\(String(body.suffix(24)))")

        // And a note short enough to fit is never shortened.
        let brief = Annotation(rect: a.rect, wheelIndex: 0, note: "Make it smaller.")
        check("a short note is left alone",
              canvas.displayNote(brief, width: 200) == "Make it smaller.",
              canvas.displayNote(brief, width: 200))

        // Clicking the label is how you change your mind about what you wrote.
        if let e = mouse(.leftMouseDown, at: CGPoint(x: label.midX, y: label.midY),
                         in: canvas) {
            canvas.mouseDown(with: e)
        }
        await settle(0.3)
        check("clicking the note reopens it for editing",
              canvas.window?.firstResponder is NoteTextView)

        type(" Bold it too.", in: canvas)
        press(K.ret, "\r", in: canvas)
        await settle(0.2)
        check("the edit is kept",
              canvas.document.annotations.first?.note.hasSuffix("Bold it too.") == true,
              String((canvas.document.annotations.first?.note ?? "gone").suffix(28)))
    }

    // MARK: Scenario 5 — picking the region

    private static func regionSelection() async {
        print("\n  region selection")
        guard let base = SyntheticScreen.make(size: CGSize(width: 900, height: 560),
                                              scale: 2, dark: false),
              let screen = NSScreen.main else {
            check("fixture", false); return
        }
        let display = FrozenDisplay(screen: screen, displayID: 0, image: base, scale: 2,
                                    edges: EdgeMap.build(from: base))

        // A plain drag returns what was dragged.
        var result: SelectionOverlay.Completion = nil
        var done = false
        let overlay = SelectionOverlay()
        overlay.present([display]) { result = $0; done = true }
        await settle(0.35)

        guard let view = overlay.viewsForTesting.first else {
            check("overlay presented", false); return
        }
        check("overlay covers the display",
              abs(view.bounds.width - screen.frame.width) < 1)

        let from = CGPoint(x: 200, y: 200), to = CGPoint(x: 500, y: 420)
        if let e = mouse(.leftMouseDown, at: from, in: view) { view.mouseDown(with: e) }
        if let e = mouse(.leftMouseDragged, at: to, in: view) { view.mouseDragged(with: e) }
        if let e = mouse(.leftMouseUp, at: to, in: view) { view.mouseUp(with: e) }
        await settle(0.2)

        check("a drag finishes the selection", done)
        if let (_, rect) = result {
            check("the selected rect is what was dragged",
                  abs(rect.width - 300) < 1 && abs(rect.height - 220) < 1,
                  "\(Int(rect.width))x\(Int(rect.height))pt")
        } else {
            check("the selected rect is what was dragged", false, "cancelled")
        }

        await frameSnapClick(on: screen)
    }

    /// Hover a card, click without dragging, get the card.
    ///
    /// The fixture is built at the screen's own size so the point-to-pixel
    /// mapping under test is the real one — a mismatched fixture would make
    /// this pass for the wrong reason.
    private static func frameSnapClick(on screen: NSScreen) async {
        let scale = screen.backingScaleFactor
        guard let base = SyntheticScreen.make(size: screen.frame.size, scale: scale,
                                              dark: false) else {
            check("full-size fixture", false); return
        }
        let display = FrozenDisplay(screen: screen, displayID: 0, image: base,
                                    scale: scale, edges: EdgeMap.build(from: base))

        var result: SelectionOverlay.Completion = nil
        var done = false
        let overlay = SelectionOverlay()
        overlay.present([display]) { result = $0; done = true }
        await settle(0.35)
        guard let view = overlay.viewsForTesting.first else {
            check("overlay presented for snapping", false); return
        }

        // Centre of the middle card, converted into the overlay's bottom-left
        // point space.
        let cardPx = CGRect(x: 322 * scale, y: 210 * scale,
                            width: 254 * scale, height: 190 * scale)
        let hover = CGPoint(x: cardPx.midX / scale,
                            y: view.bounds.height - cardPx.midY / scale)

        if let e = mouse(.mouseMoved, at: hover, in: view) { view.mouseMoved(with: e) }
        await settle(0.15)
        if let e = mouse(.leftMouseDown, at: hover, in: view) { view.mouseDown(with: e) }
        if let e = mouse(.leftMouseUp, at: hover, in: view) { view.mouseUp(with: e) }
        await settle(0.2)

        check("a click on an outlined frame takes it", done)
        if let (_, rect) = result {
            let expected = CGRect(x: cardPx.minX / scale,
                                  y: view.bounds.height - cardPx.maxY / scale,
                                  width: cardPx.width / scale,
                                  height: cardPx.height / scale)
            let slop = max(abs(rect.minX - expected.minX), abs(rect.minY - expected.minY),
                           abs(rect.maxX - expected.maxX), abs(rect.maxY - expected.maxY))
            check("the frame it takes is the card under the pointer", slop <= 4,
                  "off by \(Int(slop))pt — \(Int(rect.width))x\(Int(rect.height))pt")
        } else {
            check("the frame it takes is the card under the pointer", false, "nothing")
        }
    }
}
