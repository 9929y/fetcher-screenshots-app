import AppKit

/// Draws into a CGContext using top-left origin coordinates.
///
/// `NSGraphicsContext(cgContext:flipped:)` only *declares* the orientation — it
/// installs no transform. Passing `flipped: true` without also flipping the CTM
/// silently draws everything mirrored vertically, with upside-down text. This
/// helper does both halves, which is the only correct combination.
enum FlippedDraw {
    static func into(_ ctx: CGContext, height: Int, _ body: () -> Void) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        body()
        NSGraphicsContext.restoreGraphicsState()

        ctx.restoreGState()
    }

    /// Draws a CGImage into a rect given in top-left coordinates, upright.
    ///
    /// `NSImage.draw(in:)` inside a flipped view is not reliably upright — it
    /// depends on how the image was constructed and how it is being scaled, and
    /// the failure is a silently inverted picture rather than an error. Going
    /// through CoreGraphics with an explicit flip about the destination rect
    /// has one behaviour, always.
    static func image(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: rect.minY + rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: rect)
        ctx.restoreGState()
    }
}

/// Turns a capture plus its annotations into the exported PNG.
///
/// Deliberately a pure function of (image, annotations, options) with no view
/// state and no I/O, because that is what makes golden-image testing cheap —
/// and badge placement is exactly the kind of geometry that regresses silently.
enum Compositor {

    struct Options {
        var legend: Bool = true
        var placement: LegendPlacement = .automatic
        /// Halve the exported pixels. A 2x capture of a large frame makes a
        /// file big enough that some chat inputs downscale it themselves, badly.
        var halveOutput: Bool = false
        /// Inset the capture on a ground with a shadow under it.
        var margin: Bool = true
        /// Pixels per point of the source capture. All design constants below
        /// are in points and scaled by this, so a 1x and a 2x capture produce
        /// visually identical output.
        var scale: CGFloat = 2
        var legendIsDark: Bool? = nil   // nil = decide from the image

        static let `default` = Options()

        static func fromSettings(scale: CGFloat) -> Options {
            var o = Options()
            o.scale = scale
            o.legend = Settings.shared.legendEnabled
            o.placement = Settings.shared.legendPlacement
            o.halveOutput = Settings.shared.exportAtOneX
            o.margin = Settings.shared.marginedExport
            return o
        }
    }

    // Design constants, in points.
    enum M {
        /// Breathing room around the capture, in points.
        static let margin: CGFloat = 26
        /// Between the capture and the notes behind it.
        static let marginGap: CGFloat = 16
        /// Close to a macOS window's own corner, so an exported capture reads
        /// as a window rather than a cropped rectangle.
        static let captureRadius: CGFloat = 12
        static let shadowBlur: CGFloat = 22
        static let shadowDrop: CGFloat = 6

        static let stroke: CGFloat = 2.5
        static let boxRadius: CGFloat = 3
        static let halo: CGFloat = 1
        static let badge: CGFloat = 21
        static let badgeRadius: CGFloat = 5
        static let badgeFont: CGFloat = 12
        static let legendPad: CGFloat = 14
        static let legendRowGap: CGFloat = 8
        static let legendSwatch: CGFloat = 17
        static let legendSwatchGap: CGFloat = 10
        static let legendFont: CGFloat = 13.5
        static let legendLead: CGFloat = 1.42
    }

    // MARK: Entry point

    static func render(base: CGImage,
                       annotations: [Annotation],
                       options: Options = .default) -> CGImage? {

        let s = options.scale
        let baseW = CGFloat(base.width)
        let baseH = CGFloat(base.height)

        let dark = options.legendIsDark ?? isDark(base)
        let rows = annotations.enumerated().compactMap { i, a -> LegendRow? in
            let note = a.note.trimmingCharacters(in: .whitespacesAndNewlines)
            // A box with no note is a pure pointer: it keeps its badge on the
            // image but contributes no legend row. Numbering is unaffected —
            // renumbering here would break image/text correspondence.
            guard !note.isEmpty else { return nil }
            return LegendRow(number: i + 1, wheelIndex: a.wheelIndex, note: note)
        }

        let showLegend = options.legend && !rows.isEmpty
        let placement = options.placement.resolved(
            forImageSize: CGSize(width: baseW, height: baseH))

        // The capture sits inset on a ground with a shadow under it, rather
        // than running to the edges of the file.
        //
        // This replaces an earlier patch. The complaint was that the capture
        // and its notes ran together, and the first answer was a rule between
        // them — a line drawn to assert a separation the layout did not have.
        // Lifting the capture off the ground gives it that separation for real:
        // it becomes an object, and the notes are plainly on the surface behind
        // it. The rule is gone; it has nothing left to do.
        let pad = options.margin ? M.margin * s : 0
        let gap = options.margin ? M.marginGap * s : 0

        let captureOrigin = CGPoint(x: pad, y: pad)   // top-left space
        var legendFrame = CGRect.zero
        var W = baseW + pad * 2
        var H = baseH + pad * 2

        if showLegend {
            switch placement {
            case .right:
                // Wide enough to read, never so wide it dwarfs the capture.
                let width = min(max(240 * s, baseW * 0.42), 420 * s)
                let height = legendHeight(rows: rows, width: width, scale: s, dark: dark)
                W = pad * 2 + baseW + gap + width
                H = max(baseH, height) + pad * 2
                legendFrame = CGRect(x: pad + baseW + gap, y: pad,
                                     width: width, height: height)
            case .below, .automatic:
                // Pull the legend's own padding out to the margin, so the
                // swatches line up with the capture's left edge.
                let inset = M.legendPad * s
                let width = baseW + inset * 2
                let height = legendHeight(rows: rows, width: width, scale: s, dark: dark)
                W = baseW + pad * 2
                H = pad * 2 + baseH + gap + height
                legendFrame = CGRect(x: pad - inset, y: pad + baseH + gap,
                                     width: width, height: height)
            }
        }

        let outW = Int(W.rounded(.up)), outH = Int(H.rounded(.up))
        guard let ctx = CGContext(
            data: nil, width: outW, height: outH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high

        // Phase 1 — raw CoreGraphics, bottom-left origin.
        ctx.setFillColor(legendBackground(dark: dark).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

        // The capture, in CoreGraphics' space.
        let captureRect = CGRect(x: captureOrigin.x,
                                 y: H - captureOrigin.y - baseH,
                                 width: baseW, height: baseH)
        let radius = pad > 0 ? M.captureRadius * s : 0
        let card = CGPath(roundedRect: captureRect, cornerWidth: radius,
                          cornerHeight: radius, transform: nil)

        if pad > 0 {
            // Light ground: a grey drop shadow, falling the way light falls.
            // Dark ground: a shadow would be invisible, so the card is lifted
            // with a soft light halo instead — the same job, inverted.
            ctx.saveGState()
            if dark {
                ctx.setShadow(offset: .zero, blur: M.shadowBlur * s,
                              color: NSColor(calibratedWhite: 1, alpha: 0.16).cgColor)
            } else {
                ctx.setShadow(offset: CGSize(width: 0, height: -M.shadowDrop * s),
                              blur: M.shadowBlur * s,
                              color: NSColor(calibratedWhite: 0.05, alpha: 0.22).cgColor)
            }
            ctx.setFillColor(legendBackground(dark: dark).cgColor)
            ctx.addPath(card)
            ctx.fillPath()
            ctx.restoreGState()
        }

        ctx.saveGState()
        if radius > 0 { ctx.addPath(card); ctx.clip() }
        ctx.draw(base, in: captureRect)
        ctx.restoreGState()

        // A hairline around everything, so a pasted export reads as one object
        // on whatever background it lands on — a chat bubble, a doc, a canvas.
        ctx.setStrokeColor(divider(dark: dark).cgColor)
        ctx.setLineWidth(max(1, (s * 0.75).rounded()))
        ctx.stroke(CGRect(x: 0, y: 0, width: W, height: H)
                    .insetBy(dx: max(0.5, s * 0.375), dy: max(0.5, s * 0.375)))

        // Phase 2 — AppKit in a genuinely flipped context, so annotation rects
        // (already top-left) and text draw in the same orientation. Mixing the
        // two phases is what keeps the coordinate math boring.
        FlippedDraw.into(ctx, height: outH) {
            NSGraphicsContext.current?.cgContext.saveGState()
            NSGraphicsContext.current?.cgContext
                .translateBy(x: captureOrigin.x, y: captureOrigin.y)
            drawAnnotations(annotations, scale: s,
                            imageSize: CGSize(width: baseW, height: baseH),
                            overDark: dark)
            NSGraphicsContext.current?.cgContext.restoreGState()

            if showLegend {
                drawLegend(rows, in: legendFrame, scale: s, dark: dark)
            }
        }

        guard let rendered = ctx.makeImage() else { return nil }
        return options.halveOutput ? halve(rendered) : rendered
    }

    // MARK: Boxes

    /// Draws boxes and badges in **image-pixel coordinates** into the current
    /// AppKit graphics context.
    ///
    /// Shared by the export and the editor canvas — the canvas scales the CTM
    /// and calls straight into this, so what the editor shows is what the PNG
    /// contains, by construction rather than by two implementations agreeing.
    static func drawAnnotations(_ annotations: [Annotation], scale: CGFloat,
                                imageSize: CGSize, overDark: Bool) {
        for (i, a) in annotations.enumerated() {
            drawBox(a, number: i + 1, scale: scale,
                    imageSize: imageSize, overDark: overDark)
        }
    }

    /// Single annotation at a given opacity and badge scale — the editor needs
    /// both to express state (a box dims while another is being written about;
    /// a badge pulses on commit). The export always calls this at 1.0, so the
    /// editor is a preview of the same drawing code, not a lookalike.
    static func drawAnnotation(_ a: Annotation, number: Int, scale: CGFloat,
                               imageSize: CGSize, overDark: Bool,
                               alpha: CGFloat = 1, badgeScale: CGFloat = 1) {
        let ctx = NSGraphicsContext.current?.cgContext
        if alpha < 1 { ctx?.saveGState(); ctx?.setAlpha(alpha) }
        drawBox(a, number: number, scale: scale, imageSize: imageSize,
                overDark: overDark, badgeScale: badgeScale)
        if alpha < 1 { ctx?.restoreGState() }
    }

    /// Where the badge lands, including the small-box and edge cases. Exposed
    /// so the editor can hit-test and animate it without duplicating the rules.
    static func badgeRect(for boxRect: CGRect, scale s: CGFloat,
                          imageSize: CGSize) -> (rect: CGRect, leader: Bool) {
        let b = s * M.badge
        let tooSmall = boxRect.width < b * 1.4 || boxRect.height < b * 1.4

        var origin = tooSmall
            ? CGPoint(x: boxRect.minX - b - s * 4, y: boxRect.minY - b - s * 4)
            : CGPoint(x: boxRect.minX - b / 2, y: boxRect.minY - b / 2)

        let margin = s * 2
        var leader = tooSmall

        if origin.x < margin { origin.x = boxRect.minX + margin; leader = false }
        if origin.y < margin { origin.y = boxRect.minY + margin; leader = false }
        if origin.x + b > imageSize.width  - margin { origin.x = imageSize.width  - b - margin }
        if origin.y + b > imageSize.height - margin { origin.y = imageSize.height - b - margin }

        return (CGRect(x: origin.x, y: origin.y, width: b, height: b), leader)
    }

    private static func drawBox(_ a: Annotation, number: Int, scale s: CGFloat,
                                imageSize: CGSize, overDark: Bool,
                                badgeScale: CGFloat = 1) {
        let color = Palette.color(a.wheelIndex)
        let rect = a.rect

        // A halo on both edges of the stroke is what lets one palette read over
        // a white Figma canvas and a dark app UI. It follows the capture: a
        // white halo on a dark screenshot reads as an unintended second border,
        // and the stroke needs no help there anyway.
        let haloColor = overDark
            ? NSColor(calibratedWhite: 0.05, alpha: 0.55)
            : NSColor(calibratedWhite: 1.00, alpha: 0.85)
        haloColor.setStroke()
        let outer = NSBezierPath(roundedRect: rect.insetBy(dx: -s * M.halo, dy: -s * M.halo),
                                xRadius: s * (M.boxRadius + M.halo),
                                yRadius: s * (M.boxRadius + M.halo))
        outer.lineWidth = s * M.halo
        outer.stroke()

        let inner = NSBezierPath(roundedRect: rect.insetBy(dx: s * M.stroke, dy: s * M.stroke),
                                 xRadius: s * M.boxRadius, yRadius: s * M.boxRadius)
        inner.lineWidth = s * M.halo
        inner.stroke()

        // A low-saturation stroke on a busy design is easy to lose. Tinting
        // the interior makes the marked region a region rather than an outline
        // — light enough that the design underneath is still being judged.
        color.withAlphaComponent(0.09).setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: s * M.stroke, dy: s * M.stroke),
                     xRadius: s * M.boxRadius, yRadius: s * M.boxRadius).fill()

        color.setStroke()
        let border = NSBezierPath(roundedRect: rect.insetBy(dx: s * M.stroke / 2,
                                                            dy: s * M.stroke / 2),
                                  xRadius: s * M.boxRadius, yRadius: s * M.boxRadius)
        border.lineWidth = s * M.stroke
        border.stroke()

        drawBadge(number: number, wheelIndex: a.wheelIndex, boxRect: rect,
                  scale: s, imageSize: imageSize, halo: haloColor,
                  badgeScale: badgeScale)
    }

    /// Badge geometry, including the two cases that actually show up: a box too
    /// small to hold the badge, and a box against the edge of the capture.
    private static func drawBadge(number: Int, wheelIndex: Int, boxRect: CGRect,
                                  scale s: CGFloat, imageSize: CGSize,
                                  halo haloColor: NSColor, badgeScale: CGFloat) {
        let placed = badgeRect(for: boxRect, scale: s, imageSize: imageSize)
        var badge = placed.rect
        if badgeScale != 1 {
            let grow = badge.width * (badgeScale - 1) / 2
            badge = badge.insetBy(dx: -grow, dy: -grow)
        }

        if placed.leader {
            Palette.color(wheelIndex).setStroke()
            let leader = NSBezierPath()
            leader.lineWidth = s * 2
            leader.move(to: CGPoint(x: badge.maxX - s * 2, y: badge.maxY - s * 2))
            leader.line(to: CGPoint(x: boxRect.minX, y: boxRect.minY))
            leader.stroke()
        }

        haloColor.setStroke()
        let halo = NSBezierPath(roundedRect: badge.insetBy(dx: -s * 1.5, dy: -s * 1.5),
                                xRadius: s * (M.badgeRadius + 1.5),
                                yRadius: s * (M.badgeRadius + 1.5))
        halo.lineWidth = s * 1.5
        halo.stroke()

        Palette.color(wheelIndex).setFill()
        NSBezierPath(roundedRect: badge, xRadius: s * M.badgeRadius,
                     yRadius: s * M.badgeRadius).fill()

        // Numeral contrast is decided per swatch — a Morandi palette spans
        // light sand and deep dusk, so neither black nor white works for all.
        let numeral = NSFont.monospacedDigitSystemFont(
            ofSize: s * M.badgeFont * badgeScale, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: numeral,
            .foregroundColor: onColorInk(Palette.color(wheelIndex))
        ]
        let text = "\(number)" as NSString
        let size = text.size(withAttributes: attrs)
        text.draw(at: CGPoint(x: badge.midX - size.width / 2,
                              y: badge.midY - size.height / 2),
                  withAttributes: attrs)
    }

    // MARK: Legend

    private struct LegendRow {
        let number: Int
        let wheelIndex: Int
        let note: String
    }

    private static func legendTextAttributes(_ row: LegendRow, scale s: CGFloat,
                                             dark: Bool) -> [NSAttributedString.Key: Any] {
        let para = NSMutableParagraphStyle()
        para.lineHeightMultiple = M.legendLead
        para.lineBreakMode = .byWordWrapping
        return [
            .font: NSFont.systemFont(ofSize: s * M.legendFont, weight: .medium),
            // The note itself carries the box color — that was the explicit
            // requirement — but contrast-corrected against the legend ground,
            // so amber and lime stay readable instead of technically compliant.
            .foregroundColor: readable(Palette.color(row.wheelIndex),
                                      on: legendBackground(dark: dark)),
            .paragraphStyle: para
        ]
    }

    private static func rowTextWidth(_ width: CGFloat, scale s: CGFloat) -> CGFloat {
        width - s * (M.legendPad * 2 + M.legendSwatch + M.legendSwatchGap)
    }

    private static func rowHeight(_ row: LegendRow, width: CGFloat, scale s: CGFloat,
                                  dark: Bool) -> CGFloat {
        let attrs = legendTextAttributes(row, scale: s, dark: dark)
        let bounding = (row.note as NSString).boundingRect(
            with: CGSize(width: rowTextWidth(width, scale: s), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs
        )
        return max(s * M.legendSwatch, bounding.height.rounded(.up))
    }

    private static func legendHeight(rows: [LegendRow], width: CGFloat,
                                     scale s: CGFloat, dark: Bool) -> CGFloat {
        let body = rows.reduce(CGFloat(0)) { $0 + rowHeight($1, width: width, scale: s, dark: dark) }
        let gaps = CGFloat(max(0, rows.count - 1)) * s * M.legendRowGap
        return body + gaps + s * M.legendPad * 2
    }

    private static func drawLegend(_ rows: [LegendRow], in frame: CGRect,
                                   scale s: CGFloat, dark: Bool) {
        let width = frame.width
        var y = frame.minY + s * M.legendPad
        let swatchX = frame.minX + s * M.legendPad
        let textX = swatchX + s * (M.legendSwatch + M.legendSwatchGap)
        let textW = rowTextWidth(width, scale: s)

        for row in rows {
            let h = rowHeight(row, width: width, scale: s, dark: dark)

            let swatch = CGRect(x: swatchX, y: y + s * 1.5,
                                width: s * M.legendSwatch, height: s * M.legendSwatch)
            Palette.color(row.wheelIndex).setFill()
            NSBezierPath(roundedRect: swatch, xRadius: s * 4, yRadius: s * 4).fill()

            let nAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: s * 10, weight: .bold),
                .foregroundColor: onColorInk(Palette.color(row.wheelIndex))
            ]
            let nText = "\(row.number)" as NSString
            let nSize = nText.size(withAttributes: nAttrs)
            nText.draw(at: CGPoint(x: swatch.midX - nSize.width / 2,
                                   y: swatch.midY - nSize.height / 2),
                       withAttributes: nAttrs)

            (row.note as NSString).draw(
                with: CGRect(x: textX, y: y, width: textW, height: h),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: legendTextAttributes(row, scale: s, dark: dark)
            )

            y += h + s * M.legendRowGap
        }
    }

    /// Halves the pixel dimensions of a finished export.
    private static func halve(_ image: CGImage) -> CGImage {
        let w = max(1, image.width / 2), h = max(1, image.height / 2)
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    // MARK: Color helpers

    /// A dark UI screenshot with a bright white legend welded to the bottom
    /// looks broken, so the strip follows the capture.
    static func isDark(_ image: CGImage) -> Bool {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let l = relativeLuminance(r: CGFloat(pixel[0]) / 255,
                                  g: CGFloat(pixel[1]) / 255,
                                  b: CGFloat(pixel[2]) / 255)
        return l < 0.38
    }

    /// The line between the two zones, and around the whole export.
    static func divider(dark: Bool) -> NSColor {
        dark ? NSColor(srgbRed: 0x3A/255, green: 0x40/255, blue: 0x52/255, alpha: 1)
             : NSColor(srgbRed: 0xC9/255, green: 0xCD/255, blue: 0xD9/255, alpha: 1)
    }

    private static func legendBackground(dark: Bool) -> NSColor {
        dark ? NSColor(srgbRed: 0x1B/255, green: 0x1E/255, blue: 0x29/255, alpha: 1)
             : NSColor(srgbRed: 0xF2/255, green: 0xF3/255, blue: 0xF8/255, alpha: 1)
    }

    private static func relativeLuminance(r: CGFloat, g: CGFloat, b: CGFloat) -> CGFloat {
        func lin(_ c: CGFloat) -> CGFloat {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    private static func luminance(_ color: NSColor) -> CGFloat {
        guard let c = color.usingColorSpace(.sRGB) else { return 0 }
        return relativeLuminance(r: c.redComponent, g: c.greenComponent, b: c.blueComponent)
    }

    private static func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Black or white numerals, whichever survives on this swatch.
    private static func onColorInk(_ swatch: NSColor) -> NSColor {
        let white = NSColor.white
        let black = NSColor(calibratedWhite: 0.08, alpha: 1)
        return contrast(swatch, white) >= contrast(swatch, black) ? white : black
    }

    /// Walks a palette color down (or up) in brightness until it clears 4.5:1,
    /// staying in HSB so the hue survives.
    ///
    /// The obvious implementation — blend toward black or white — destroys a
    /// Morandi palette: ten low-saturation hues all converge on the same grey
    /// and the legend stops being color-coded at all. Compressing brightness
    /// while nudging saturation *up* keeps each hue identifiable at 4.5:1.
    private static func readable(_ color: NSColor, on background: NSColor) -> NSColor {
        guard let c = color.usingColorSpace(.sRGB) else { return color }
        let onDark = luminance(background) <= 0.5

        let h = c.hueComponent
        var sat = c.saturationComponent
        var bri = c.brightnessComponent
        var result = c
        var guardRail = 0

        while contrast(result, background) < 4.5 && guardRail < 60 {
            guardRail += 1
            if onDark {
                bri = min(1, bri + 0.015)
                sat = max(0.10, sat - 0.004)   // a hair cleaner as it lightens
            } else {
                bri = max(0, bri - 0.015)
                sat = min(1, sat + 0.010)      // a hair richer as it darkens
            }
            result = Palette.srgb(hue: h, saturation: sat, brightness: bri)
        }
        return result
    }
}
