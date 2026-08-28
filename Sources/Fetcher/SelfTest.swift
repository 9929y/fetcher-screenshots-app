import AppKit

/// Two tiers, deliberately separated.
///
/// The pure tier — model, prompt text, compositor geometry — needs no
/// permission and no display, so it runs anywhere including CI. The capture
/// tier needs Screen Recording, which only a human can grant. Splitting them
/// means a missing permission blocks one leg instead of the whole suite.
enum SelfTest {

    private static var failures = 0
    private static var checks = 0

    static func run() {
        Task { @MainActor in
            print("[fetcher] self test\n")

            print("  model")
            documentChecks()
            print("\n  prompt text")
            promptChecks()
            print("\n  palette")
            paletteChecks()
            print("\n  compositor")
            compositorChecks()
            print("\n  settings")
            settingsChecks()
            print("\n  drag payload")
            dragPayloadChecks()
            print("\n  frame detection")
            frameDetectionChecks()
            print("\n  capture")
            await captureChecks()

            print("\n[fetcher] \(checks) checks, \(failures) failed")
            NSApp.terminate(nil)
        }
    }

    // MARK: Harness

    private static func check(_ label: String, _ ok: Bool, _ detail: String = "") {
        checks += 1
        if !ok { failures += 1 }
        let mark = ok ? "pass" : "FAIL"
        print("    \(mark)  \(label)" + (detail.isEmpty ? "" : "  [\(detail)]"))
    }

    // MARK: Model

    private static func documentChecks() {
        let doc = MarkupDocument()
        let a = doc.add(rect: CGRect(x: 10, y: 10, width: 100, height: 60))
        let b = doc.add(rect: CGRect(x: 200, y: 10, width: 100, height: 60))
        let c = doc.add(rect: CGRect(x: 400, y: 10, width: 100, height: 60))

        check("three boxes", doc.count == 3)
        check("numbers are 1-based and contiguous",
              doc.number(of: a.id) == 1 && doc.number(of: b.id) == 2 && doc.number(of: c.id) == 3)
        let assigned: [Int] = [a.wheelIndex, b.wheelIndex, c.wheelIndex]
        check("auto colors follow the assignment order",
              assigned == [0, 5, 2],
              "\(Palette.name(a.wheelIndex)), \(Palette.name(b.wheelIndex)), \(Palette.name(c.wheelIndex))")

        doc.delete(b.id)
        check("delete renumbers the survivors",
              doc.number(of: a.id) == 1 && doc.number(of: c.id) == 2)
        check("delete leaves colors alone",
              doc.annotation(c.id)?.wheelIndex == 2, "still \(Palette.name(2))")

        doc.undo()
        check("undo restores the deleted box", doc.count == 3 && doc.number(of: c.id) == 3)
        doc.redo()
        check("redo re-applies it", doc.count == 2)

        doc.setColor(wheelIndex: 9, for: a.id)
        check("manual color override", doc.annotation(a.id)?.wheelIndex == 9,
              Palette.name(9))
        doc.undo()
        check("override is undoable", doc.annotation(a.id)?.wheelIndex == 0)

        doc.beginNoteEdit(a.id)
        doc.setNote("first", for: a.id)
        doc.setNote("first draft", for: a.id)
        doc.undo()
        check("note keystrokes coalesce into one undo step",
              doc.annotation(a.id)?.note.isEmpty == true)

        let hits = doc.hits(at: CGPoint(x: 50, y: 40))
        check("hit test finds the box under the point", hits.first?.id == a.id)
        check("hit test misses empty space", doc.hits(at: CGPoint(x: 1000, y: 1000)).isEmpty)
    }

    // MARK: Prompt

    private static func promptChecks() {
        let doc = MarkupDocument()
        let a = doc.add(rect: .init(x: 0, y: 0, width: 10, height: 10))
        let b = doc.add(rect: .init(x: 0, y: 0, width: 10, height: 10))
        _ = doc.add(rect: .init(x: 0, y: 0, width: 10, height: 10))
        doc.setNote("Heading is competing with the price.", for: a.id)
        doc.setNote("Line one\n\nline two", for: b.id)
        // c left empty on purpose

        let text = PromptGenerator.text(for: doc.annotations)
        check("numbers items in order",
              text.contains("1. (red) Heading is competing with the price."))
        check("names the color alongside the number", text.contains("2. (teal)"))
        check("collapses newlines inside a note", text.contains("Line one line two"))
        check("skips boxes with no note", !text.contains("3."))
        check("keeps the scope-limiting closer", text.contains("Change only what's listed"))

        let empty = PromptGenerator.text(for: [Annotation(rect: .zero, wheelIndex: 0)])
        check("no items means no prompt at all", empty.isEmpty)
    }

    // MARK: Palette

    private static func paletteChecks() {
        check("ten colors", Palette.wheel.count == 10)
        check("assignment covers every color once",
              Set(Palette.assignment).count == 10)

        var worst: CGFloat = 360
        for i in 0..<(Palette.assignment.count - 1) {
            let a = hue(Palette.assignment[i]), b = hue(Palette.assignment[i + 1])
            var gap = abs(a - b)
            if gap > 180 { gap = 360 - gap }
            worst = min(worst, gap)
        }
        check("consecutive assigned colors stay far apart on the wheel",
              worst >= 100, "min gap \(Int(worst))deg")

        // The common case is 3-4 boxes, so the first four matter most.
        var worstFour: CGFloat = 360
        for i in 0..<3 {
            let a = hue(Palette.assignment[i]), b = hue(Palette.assignment[i + 1])
            var gap = abs(a - b)
            if gap > 180 { gap = 360 - gap }
            worstFour = min(worstFour, gap)
        }
        check("first four are the widely separated ones",
              worstFour >= 120, "min gap \(Int(worstFour))deg")

        check("colors cycle past ten but stay distinct from their neighbour",
              Palette.wheelIndex(forAnnotation: 10) == Palette.wheelIndex(forAnnotation: 0))
    }

    private static func hue(_ wheelIndex: Int) -> CGFloat {
        (Palette.color(wheelIndex).usingColorSpace(.sRGB)?.hueComponent ?? 0) * 360
    }

    // MARK: Compositor

    private static func compositorChecks() {
        let scale: CGFloat = 2
        let pad = Compositor.M.margin * scale
        let gap = Compositor.M.marginGap * scale

        for dark in [false, true] {
            guard let base = SyntheticScreen.make(
                size: CGSize(width: 900, height: 560), scale: scale, dark: dark
            ) else { check("synthetic fixture", false); continue }

            let label = dark ? "dark" : "light"
            check("fixture renders (\(label))",
                  base.width == 1800 && base.height == 1120,
                  "\(base.width)x\(base.height)")

            var doc = MarkupDocument()
            annotate(&doc, scale: scale)

            var opts = Compositor.Options()
            opts.scale = scale

            guard let out = Compositor.render(base: base, annotations: doc.annotations,
                                              options: opts) else {
                check("render (\(label))", false); continue
            }

            check("the capture is inset on a ground (\(label))",
                  CGFloat(out.width) == CGFloat(base.width) + pad * 2,
                  "\(out.width) = \(base.width) + 2×\(Int(pad))")
            check("the notes go below it (\(label))",
                  CGFloat(out.height) > CGFloat(base.height) + pad * 2 + gap,
                  "\(out.height)")

            // The ground carries a slight blue bias; the fixture capture is
            // neutral grey. One relationship identifies both zones in light and
            // dark without hardcoding either color.
            check("the margin is ground, not capture (\(label))",
                  blueBias(sample(out, 12, 12)) > 0.012,
                  describe(sample(out, 12, 12)))
            check("inside the inset is capture, not ground (\(label))",
                  blueBias(sample(out, Int(pad) + 20, Int(pad) + 20)) < 0.012,
                  describe(sample(out, Int(pad) + 20, Int(pad) + 20)))

            // The shadow is the whole point of the inset — an untested shadow
            // is decoration that silently stops being drawn.
            let underCapture = sample(out, out.width / 2, base.height + Int(pad) + 5)
            let farGround = sample(out, 6, out.height - 6)
            let shadowed = dark
                ? luminance(underCapture) > luminance(farGround) + 0.004    // a halo
                : luminance(underCapture) < luminance(farGround) - 0.004    // a shadow
            check("the capture casts a shadow onto the ground (\(label))", shadowed,
                  "\(describe(underCapture)) under vs \(describe(farGround)) away")

            // Box 1's badge overlaps its top-left corner, now offset by the
            // margin. Probe just inside it, off-centre — dead centre is the
            // numeral, which flips to near-black on a light swatch.
            let badgeSide = 21 * scale
            let corner = doc.annotations[0].rect.origin
            let probe = CGPoint(x: corner.x + pad - badgeSide / 2 + 4,
                                y: corner.y + pad - badgeSide / 2 + 4)
            check("box 1 badge sits on its corner (\(label))",
                  isRed(sample(out, Int(probe.x), Int(probe.y))),
                  describe(sample(out, Int(probe.x), Int(probe.y))))

            // First legend swatch lines up with the capture's left edge.
            let swatchY = Int(pad + CGFloat(base.height) + gap
                              + Compositor.M.legendPad * scale + 1.5 * scale + 4)
            check("legend row 1 lines up under the capture (\(label))",
                  isRed(sample(out, Int(pad) + 4, swatchY)),
                  describe(sample(out, Int(pad) + 4, swatchY)))
            check("legend content is not mirrored into the capture (\(label))",
                  !isRed(sample(out, Int(pad) + 4, out.height - swatchY)))

            // No notes: the inset stays, the notes area does not appear.
            let bare = doc.annotations.map { Annotation(rect: $0.rect, wheelIndex: $0.wheelIndex) }
            if let noLegend = Compositor.render(base: base, annotations: bare, options: opts) {
                check("all-empty notes means no notes area (\(label))",
                      CGFloat(noLegend.height) == CGFloat(base.height) + pad * 2,
                      "\(noLegend.height)")
            } else {
                check("render with empty notes (\(label))", false)
            }

            // And the inset is optional, for anyone who wants exact pixels.
            opts.margin = false
            if let flush = Compositor.render(base: base, annotations: bare, options: opts) {
                check("the inset can be turned off (\(label))",
                      flush.width == base.width && flush.height == base.height,
                      "\(flush.width)x\(flush.height)")
            } else {
                check("render without the inset (\(label))", false)
            }
            opts.margin = true

            let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("dist", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("selftest-\(label).png")
            if let data = Output.pngData(out) {
                try? data.write(to: url)
                check("wrote sample (\(label))", true, url.lastPathComponent)
            } else {
                check("encode sample (\(label))", false)
            }
        }

        // Legend beside the capture, for tall frames.
        if let tall = SyntheticScreen.make(size: CGSize(width: 380, height: 800),
                                           scale: 2, dark: false) {
            var opts = Compositor.Options()
            opts.scale = 2
            opts.placement = .right
            let notes = [Annotation(rect: CGRect(x: 40, y: 40, width: 200, height: 90),
                                    wheelIndex: 0, note: "This heading needs to be smaller.")]
            if let out = Compositor.render(base: tall, annotations: notes, options: opts) {
                check("legend beside the capture widens instead of lengthening",
                      out.width > tall.width + Int(pad * 2),
                      "\(out.width)x\(out.height) from \(tall.width)x\(tall.height)")

                let columnX = Int(pad + CGFloat(tall.width) + gap
                                  + Compositor.M.legendPad * 2 + 4)
                let rowY = Int(pad + Compositor.M.legendPad * 2 + 1.5 * 2 + 4)
                check("its first swatch is in the right-hand column",
                      isRed(sample(out, columnX, rowY)),
                      describe(sample(out, columnX, rowY)))
            } else {
                check("legend beside the capture", false)
            }

            opts.halveOutput = true
            if let small = Compositor.render(base: tall, annotations: notes, options: opts),
               let full = { () -> CGImage? in
                   var o = opts; o.halveOutput = false
                   return Compositor.render(base: tall, annotations: notes, options: o)
               }() {
                check("1x export halves the pixels",
                      abs(small.width - full.width / 2) <= 1,
                      "\(full.width) -> \(small.width)")
            } else {
                check("1x export", false)
            }
        }

        // Geometry edge cases the badge logic exists for.
        guard let base = SyntheticScreen.make(size: CGSize(width: 400, height: 300),
                                              scale: 2, dark: false) else { return }
        var opts = Compositor.Options()
        opts.scale = 2
        let edges = [
            Annotation(rect: CGRect(x: 0, y: 0, width: 20, height: 20),
                       wheelIndex: 0, note: "tiny box at the top-left corner"),
            Annotation(rect: CGRect(x: 740, y: 550, width: 50, height: 40),
                       wheelIndex: 5, note: "box against the bottom-right edge")
        ]
        check("badges survive tiny boxes and image edges",
              Compositor.render(base: base, annotations: edges, options: opts) != nil)
    }

    private static func annotate(_ doc: inout MarkupDocument, scale: CGFloat) {
        let s = scale
        let a = doc.add(rect: CGRect(x: 48 * s, y: 64 * s, width: 400 * s, height: 34 * s))
        doc.setNote("Heading — drop to 28/34, weight 600. It's competing with the price.", for: a.id)
        let b = doc.add(rect: CGRect(x: 318 * s, y: 210 * s, width: 264 * s, height: 190 * s))
        doc.setNote("Middle card — this is the recommended plan. Add the accent border and a \"Popular\" pill.", for: b.id)
        let c = doc.add(rect: CGRect(x: 48 * s, y: 452 * s, width: 170 * s, height: 40 * s))
        doc.setNote("Button — full width on mobile, and the label should read \"Start free trial\".", for: c.id)
    }

    // MARK: Settings

    private static func settingsChecks() {
        // Prompt names are derived from the color, never stored — a stored name
        // survives a recolor and then lies to the model.
        let derived = (0..<10).map { Palette.name($0) }
        check("every default color gets a distinct prompt name",
              Set(derived).count == 10, derived.joined(separator: ", "))
        check("display names stay the designed ones",
              Palette.displayName(5) == "Eucalyptus", Palette.displayName(5))

        let settings = Settings.shared
        let original = settings.paletteHex
        settings.paletteHex = original.enumerated().map { i, hex in
            i == 0 ? "#2E86D8" : hex          // recolor slot one to blue (hue 209)
        }
        check("a recolored slot renames itself in the prompt",
              Palette.name(0) == "blue", Palette.name(0))
        // Slot 0 is now blue, and slot 6 (Mist) already was. The prompt has to
        // stop naming both of them "blue" rather than say it twice.
        let clashing = [Annotation(rect: .zero, wheelIndex: 0, note: "first"),
                        Annotation(rect: .zero, wheelIndex: 6, note: "second"),
                        Annotation(rect: .zero, wheelIndex: 4, note: "third")]
        let clashText = PromptGenerator.text(for: clashing,
                                             template: "{{items}}")
        check("a duplicated color name is dropped, not repeated",
              clashText.contains("1. first") && clashText.contains("2. second"),
              clashText.replacingOccurrences(of: "\n", with: " | "))
        check("colors that are still unique keep their name",
              clashText.contains("3. (green) third"))
        check("its display name is unchanged", Palette.displayName(0) == "Rose")

        settings.paletteHex[0] = "not a color"
        check("an unparseable color falls back instead of vanishing",
              Palette.color(0).usingColorSpace(.sRGB) != nil
                  && Palette.wheel.count == 10)
        settings.paletteHex = original

        check("legend placement resolves by shape",
              LegendPlacement.automatic.resolved(
                  forImageSize: CGSize(width: 400, height: 900)) == .right
              && LegendPlacement.automatic.resolved(
                  forImageSize: CGSize(width: 1600, height: 900)) == .below)

        check("a bare key is refused as a global shortcut",
              !HotkeyCombo(keyCode: 4, modifiers: 0).isValid
              && HotkeyCombo.defaultCapture.isValid)
        check("shortcuts render the way macOS writes them",
              HotkeyCombo.defaultCapture.display == "⌃⌘C",
              HotkeyCombo.defaultCapture.display)
        check("the pair shares a modifier, so they read as one tool",
              HotkeyCombo.defaultCapture.display.hasPrefix("⌃⌘")
                  && HotkeyCombo.defaultRecapture.display.hasPrefix("⌃⌘"),
              "\(HotkeyCombo.defaultCapture.display) / \(HotkeyCombo.defaultRecapture.display)")
        check("the two defaults do not collide",
              HotkeyCombo.defaultCapture != HotkeyCombo.defaultRecapture,
              "\(HotkeyCombo.defaultCapture.display) and \(HotkeyCombo.defaultRecapture.display)")
    }

    // MARK: Drag payload

    /// `NSDraggingItem` is constructed from a pasteboard writer, so writing the
    /// same object to a scratch pasteboard exercises exactly what a drop target
    /// will receive — without needing anyone to perform a drag.
    private static func dragPayloadChecks() {
        guard let base = SyntheticScreen.make(size: CGSize(width: 200, height: 120),
                                              scale: 2, dark: false),
              let url = try? Output.write(base) else {
            check("wrote a file to drag", false); return
        }
        check("wrote a file to drag", FileManager.default.fileExists(atPath: url.path),
              url.lastPathComponent)

        let pb = NSPasteboard(name: NSPasteboard.Name("com.fetcher.dragtest"))
        pb.clearContents()
        pb.writeObjects([url as NSURL])

        let readBack = (pb.readObjects(forClasses: [NSURL.self]) as? [URL])?.first
        check("drag payload is a real file URL", readBack == url,
              readBack?.lastPathComponent ?? "nothing")
        check("payload advertises the file-url type",
              pb.types?.contains(.fileURL) == true,
              pb.types?.map(\.rawValue).joined(separator: ", ") ?? "none")

        // The file has to still be a decodable PNG on the other side.
        let reopened = NSImage(contentsOf: url)
        check("dropped file decodes as an image", reopened?.isValid == true,
              reopened.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "invalid")

        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Frame detection

    /// The synthetic fixture has three cards at known coordinates, which makes
    /// this testable to the pixel without capturing anything real.
    private static func frameDetectionChecks() {
        let scale: CGFloat = 2
        guard let base = SyntheticScreen.make(size: CGSize(width: 900, height: 560),
                                              scale: scale, dark: false),
              let map = EdgeMap.build(from: base) else {
            check("edge map", false); return
        }
        check("edge map built", map.width > 400, "\(map.width)x\(map.height) cells, "
              + "\(String(format: "%.1f", map.cell))px each")

        let size = CGSize(width: base.width, height: base.height)

        // Orientation, asserted rather than eyeballed. The fixture's cards
        // occupy rows 210-400; above and below them is empty white. A mirrored
        // map passes every other check in here and finds nothing at all.
        let insideCards = map.meanLuminance(row: 300)
        let emptyBelow = map.meanLuminance(row: 520)
        check("edge map is top-left oriented", insideCards < emptyBelow - 0.01,
              "row 300 -> \(String(format: "%.3f", insideCards)), "
              + "row 520 -> \(String(format: "%.3f", emptyBelow))")

        // Middle card: x 644..1152, y 420..800 in image pixels.
        let expected = CGRect(x: 644, y: 420, width: 508, height: 380)
        let hit = map.candidate(atPixel: CGPoint(x: expected.midX, y: expected.midY),
                                imageSize: size)
        if let hit {
            let slop = max(abs(hit.minX - expected.minX), abs(hit.minY - expected.minY),
                           abs(hit.maxX - expected.maxX), abs(hit.maxY - expected.maxY))
            check("snaps to the card under the cursor", slop <= 8,
                  "off by \(Int(slop))px — got \(Int(hit.width))x\(Int(hit.height))")
        } else {
            check("snaps to the card under the cursor", false, "no candidate")
        }

        // The third card should give a different answer, not the same one.
        let third = CGRect(x: 1192, y: 420, width: 508, height: 380)
        if let hit3 = map.candidate(atPixel: CGPoint(x: third.midX, y: third.midY),
                                    imageSize: size) {
            check("finds the card the cursor is actually over",
                  abs(hit3.minX - third.minX) <= 8, "left edge \(Int(hit3.minX))")
        } else {
            check("finds the card the cursor is actually over", false, "no candidate")
        }

        // The same card, on a dark fixture. Dark UIs are most of what gets
        // captured — Figma in dark mode, VS Code, Cursor — so detection that
        // only works on white is detection that mostly does not work.
        if let darkBase = SyntheticScreen.make(size: CGSize(width: 900, height: 560),
                                               scale: scale, dark: true),
           let darkMap = EdgeMap.build(from: darkBase) {
            let darkHit = darkMap.candidate(
                atPixel: CGPoint(x: expected.midX, y: expected.midY),
                imageSize: CGSize(width: darkBase.width, height: darkBase.height))
            if let darkHit {
                let slop = max(abs(darkHit.minX - expected.minX),
                               abs(darkHit.maxX - expected.maxX))
                check("snaps on a dark interface too", slop <= 8, "off by \(Int(slop))px")
            } else {
                check("snaps on a dark interface too", false, "no candidate")
            }
        }

        // The same thing at the size of a real display. Detection used to work
        // on a small fixture and silently stop on a large screen, because the
        // downsample cell grew with the image and averaged thin borders away.
        if let big = SyntheticScreen.make(size: CGSize(width: 1792, height: 1120),
                                          scale: 2, dark: true),
           let bigMap = EdgeMap.build(from: big) {
            check("the cell stays fine enough on a large display",
                  bigMap.cell <= 2, "\(String(format: "%.1f", bigMap.cell))px per cell")
            let bigHit = bigMap.candidate(
                atPixel: CGPoint(x: expected.midX, y: expected.midY),
                imageSize: CGSize(width: big.width, height: big.height))
            check("snaps on a large dark display", bigHit != nil,
                  bigHit.map { "\(Int($0.width))x\(Int($0.height))" } ?? "no candidate")
        }

        // Empty background between the heading and the cards: there is nothing
        // to snap to, and inventing something would move the selection out from
        // under the user.
        let empty = map.candidate(atPixel: CGPoint(x: 1500, y: 1000), imageSize: size)
        check("declines when there is no rectangle", empty == nil,
              empty.map { "invented \(Int($0.width))x\(Int($0.height))" } ?? "nil")
    }

    // MARK: Pixel sampling

    /// `NSBitmapImageRep.colorAt` is documented as top-left origin, which is
    /// the same space annotations live in — so these coordinates read the same
    /// way as the ones under test.
    private static func sample(_ image: CGImage, _ x: Int, _ y: Int) -> NSColor? {
        NSBitmapImageRep(cgImage: image).colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
    }

    private static func near(_ a: NSColor?, _ b: NSColor, tol: CGFloat) -> Bool {
        guard let a, let b = b.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent   - b.redComponent)   < tol
            && abs(a.greenComponent - b.greenComponent) < tol
            && abs(a.blueComponent  - b.blueComponent)  < tol
    }

    /// Legend grounds are blue-biased; captures in the fixture are neutral.
    private static func blueBias(_ c: NSColor?) -> CGFloat {
        guard let c else { return 0 }
        return c.blueComponent - c.redComponent
    }

    /// Hue-relationship test, immune to the gamma shift in colorAt.
    private static func isRed(_ c: NSColor?) -> Bool {
        guard let c else { return false }
        return c.redComponent > c.greenComponent + 0.15
            && c.redComponent > c.blueComponent + 0.15
    }

    private static func luminance(_ c: NSColor?) -> CGFloat {
        guard let c else { return 0 }
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
    }

    private static func describe(_ c: NSColor?) -> String {
        guard let c else { return "no pixel" }
        return String(format: "#%02X%02X%02X",
                      Int(c.redComponent * 255), Int(c.greenComponent * 255),
                      Int(c.blueComponent * 255))
    }

    // MARK: Capture

    private static func captureChecks() async {
        guard Permissions.hasScreenCapture else {
            check("screen recording permission", false,
                  "grant Fetcher in Privacy & Security, then re-run")
            return
        }
        check("screen recording permission", true)

        do {
            let displays = try await ScreenFreeze.freezeAll()
            check("froze displays", !displays.isEmpty, "\(displays.count)")

            for d in displays {
                let expected = Int((d.screen.frame.width * d.scale).rounded())
                check("bitmap matches display \(d.displayID)",
                      abs(d.image.width - expected) <= 2,
                      "\(d.image.width)x\(d.image.height) @\(Int(d.scale))x")
            }

            let d = displays[0]
            let viewRect = CGRect(x: 120, y: 140, width: 640, height: 400)
            let px = d.pixelRect(fromViewRect: viewRect, viewHeight: d.screen.frame.height)
            check("point to pixel mapping",
                  px.width == 640 * d.scale && px.height == 400 * d.scale,
                  "640x400pt -> \(Int(px.width))x\(Int(px.height))px")

            guard let cropped = d.image.cropping(to: px) else {
                check("crop", false); return
            }
            check("crop", cropped.width == Int(px.width), "\(cropped.width)x\(cropped.height)")

            Output.copyImage(cropped)
            check("png on clipboard", NSPasteboard.general.data(forType: .png) != nil)

            let url = try Output.write(cropped)
            check("wrote file", ((try? Data(contentsOf: url).count) ?? 0) > 1000, url.path)

            Output.copyPath(url)
            check("path on clipboard",
                  NSPasteboard.general.string(forType: .string) == url.path)
        } catch {
            check("capture", false, error.localizedDescription)
        }
    }
}

/// A stand-in for a design screenshot, drawn in code.
///
/// Exists so the compositor can be verified without capturing anything real —
/// which keeps the visual output testable on any machine, in CI, and without
/// putting someone's actual screen into a test fixture.
enum SyntheticScreen {

    static func make(size: CGSize, scale: CGFloat, dark: Bool) -> CGImage? {
        let W = Int(size.width * scale), H = Int(size.height * scale)
        guard let ctx = CGContext(
            data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        var result: CGImage?
        FlippedDraw.into(ctx, height: H) {
        let bg   = dark ? gray(0x14) : gray(0xFF)
        let el   = dark ? gray(0x2C) : gray(0xE2)
        let el2  = dark ? gray(0x1F) : gray(0xF4)
        let s = scale

        bg.setFill()
        CGRect(x: 0, y: 0, width: CGFloat(W), height: CGFloat(H)).fill()

        // Window dots
        for i in 0..<3 {
            el.setFill()
            NSBezierPath(ovalIn: CGRect(x: (24 + CGFloat(i) * 14) * s, y: 24 * s,
                                        width: 8 * s, height: 8 * s)).fill()
        }
        // Heading + subhead
        rounded(CGRect(x: 48 * s, y: 68 * s, width: 380 * s, height: 22 * s), 4 * s, el)
        rounded(CGRect(x: 48 * s, y: 102 * s, width: 520 * s, height: 11 * s), 3 * s, el2)

        // Three plan cards
        for i in 0..<3 {
            let x = (48 + CGFloat(i) * 274) * s
            let card = CGRect(x: x, y: 210 * s, width: 254 * s, height: 190 * s)
            rounded(card, 6 * s, el2)
            el.setStroke()
            let stroke = NSBezierPath(roundedRect: card, xRadius: 6 * s, yRadius: 6 * s)
            stroke.lineWidth = s
            stroke.stroke()
            rounded(CGRect(x: x + 18 * s, y: 232 * s, width: 90 * s, height: 10 * s), 3 * s, el)
            rounded(CGRect(x: x + 18 * s, y: 262 * s, width: 120 * s, height: 22 * s), 4 * s, el)
            for r in 0..<3 {
                rounded(CGRect(x: x + 18 * s, y: (306 + CGFloat(r) * 20) * s,
                               width: CGFloat([190, 160, 120][r]) * s, height: 9 * s), 3 * s, el)
            }
        }

        // CTA
        rounded(CGRect(x: 48 * s, y: 452 * s, width: 170 * s, height: 40 * s), 6 * s,
                dark ? gray(0x33) : gray(0xEC))

        }
        result = ctx.makeImage()
        return result
    }

    private static func gray(_ v: Int) -> NSColor {
        NSColor(calibratedWhite: CGFloat(v) / 255, alpha: 1)
    }

    private static func rounded(_ r: CGRect, _ radius: CGFloat, _ color: NSColor) {
        color.setFill()
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
    }
}
