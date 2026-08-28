import AppKit

/// Finds the rectangle under the cursor by looking at pixels.
///
/// The obvious approach — snap to window bounds via the accessibility API — is
/// useless for the actual job. A Figma frame is not an OS window; asking the
/// system for window bounds returns the whole Figma window, which is never what
/// you wanted to capture. The boundary that matters is drawn in pixels, so that
/// is where it has to be found.
///
/// This is also why capture freezes the screen *before* the overlay appears:
/// the detector needs a bitmap to work on, and it must not contain the overlay.
private let MAX_CELL: CGFloat = 2

struct EdgeMap {

    let width: Int
    let height: Int
    /// Source pixels per cell. The map is downsampled — frame borders are many
    /// pixels long, so full resolution buys nothing and costs a lot.
    let cell: CGFloat

    /// Strong vertical gradient: a candidate left or right border.
    fileprivate let vEdge: [Bool]
    /// Strong horizontal gradient: a candidate top or bottom border.
    fileprivate let hEdge: [Bool]
    fileprivate let lum: [Float]

    // MARK: Build

    static func build(from image: CGImage, targetWidth: Int = 900) -> EdgeMap? {
        // The cell is capped, not just derived from a target width.
        //
        // A frame border is one or two pixels wide. Downsampling averages it
        // with its neighbours, so the coarser the cell the weaker the edge —
        // and the failure is silent and scale-dependent: detection works on a
        // laptop screen and quietly stops on a 5K one, worst on dark interfaces
        // where the border contrast was low to begin with. Two source pixels
        // per cell keeps a thin line detectable at any display size.
        let cell = min(max(1, CGFloat(image.width) / CGFloat(targetWidth)),
                       MAX_CELL)
        let w = max(8, Int(CGFloat(image.width) / cell))
        let h = max(8, Int(CGFloat(image.height) / cell))

        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = pixels.withUnsafeMutableBytes({ raw -> CGContext? in
            CGContext(data: raw.baseAddress, width: w, height: h,
                      bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        // A bitmap context's buffer is already stored top-down: byte 0 is the
        // top-left pixel, even though the drawing coordinate system has its
        // origin at the bottom left. Flipping here on the strength of the
        // coordinate system turns the whole map upside down — the detector then
        // finds real edges at mirrored rows and quietly never matches anything.
        var lum = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let src = y * w * 4
            for x in 0..<w {
                let i = src + x * 4
                lum[y * w + x] = 0.2126 * Float(pixels[i]) / 255
                                + 0.7152 * Float(pixels[i + 1]) / 255
                                + 0.0722 * Float(pixels[i + 2]) / 255
            }
        }

        // A low threshold on purpose: the boundary between a Figma frame and
        // the canvas behind it is often a very light grey on white.
        //
        // Adjacent differences, not a two-cell span. A frame border is a thin
        // line, and a symmetric gradient steps straight over it — comparing the
        // canvas on one side to the fill on the other and finding almost no
        // difference, while the line between them is plainly visible.
        let threshold: Float = 0.035
        var vEdge = [Bool](repeating: false, count: w * h)
        var hEdge = [Bool](repeating: false, count: w * h)
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                vEdge[i] = max(abs(lum[i + 1] - lum[i]),
                               abs(lum[i] - lum[i - 1])) > threshold
                hEdge[i] = max(abs(lum[i + w] - lum[i]),
                               abs(lum[i] - lum[i - w])) > threshold
            }
        }
        return EdgeMap(width: w, height: h, cell: cell, vEdge: vEdge, hEdge: hEdge, lum: lum)
    }

    // MARK: Query

    private func hEdgeAt(_ x: Int, _ y: Int) -> Bool {
        guard x >= 0, x < width, y >= 0, y < height else { return false }
        return hEdge[y * width + x]
    }

    private func vEdgeAt(_ x: Int, _ y: Int) -> Bool {
        guard x >= 0, x < width, y >= 0, y < height else { return false }
        return vEdge[y * width + x]
    }

    /// The horizontal run of edge pixels through `x` on row `y`, allowing small
    /// gaps — a real border is broken by antialiasing and rounded corners.
    fileprivate func horizontalRun(row y: Int, through x: Int) -> ClosedRange<Int>? {
        guard hEdgeAt(x, y) || hEdgeAt(x, y - 1) || hEdgeAt(x, y + 1) else { return nil }
        let gap = 3
        var left = x, right = x
        var miss = 0
        var i = x
        while i > 0 {
            i -= 1
            if hEdgeAt(i, y) || hEdgeAt(i, y - 1) || hEdgeAt(i, y + 1) { left = i; miss = 0 }
            else { miss += 1; if miss > gap { break } }
        }
        miss = 0
        i = x
        while i < width - 1 {
            i += 1
            if hEdgeAt(i, y) || hEdgeAt(i, y - 1) || hEdgeAt(i, y + 1) { right = i; miss = 0 }
            else { miss += 1; if miss > gap { break } }
        }
        return left <= right ? left...right : nil
    }

    private func verticalCoverage(column x: Int, from y0: Int, to y1: Int) -> CGFloat {
        guard y1 > y0 else { return 0 }
        var hits = 0
        for y in y0...y1 where vEdgeAt(x, y) || vEdgeAt(x - 1, y) || vEdgeAt(x + 1, y) {
            hits += 1
        }
        return CGFloat(hits) / CGFloat(y1 - y0 + 1)
    }

    /// The enclosing rectangle around a point, in source-image pixels, or nil
    /// when the pixels do not actually describe one.
    ///
    /// "Enclosing" means *the smallest rectangle whose four sides all exist*.
    /// Stopping at the first horizontal line above and below the cursor finds
    /// the gap between two rows of content inside a card, not the card — so
    /// candidate borders are collected going outward and paired innermost-first
    /// until a pair turns up that has real vertical sides too.
    ///
    /// Returning nil readily is the point: a snap that fires on nothing is
    /// worse than no snap, because it moves the selection out from under you.
    func candidate(atPixel p: CGPoint, imageSize: CGSize,
                   trace: ((String) -> Void)? = nil) -> CGRect? {
        let mx = Int(p.x / cell), my = Int(p.y / cell)
        guard mx > 1, my > 1, mx < width - 2, my < height - 2 else {
            trace?("out of bounds"); return nil
        }

        let minRun = max(12, width / 45)
        let maxCandidates = 12

        var above: [(row: Int, span: ClosedRange<Int>)] = []
        var y = my
        while y > 1 && above.count < maxCandidates {
            y -= 1
            if let run = horizontalRun(row: y, through: mx), run.count >= minRun {
                above.append((y, run))
                y -= 2                     // skip the other side of the same line
            }
        }
        var below: [(row: Int, span: ClosedRange<Int>)] = []
        y = my
        while y < height - 2 && below.count < maxCandidates {
            y += 1
            if let run = horizontalRun(row: y, through: mx), run.count >= minRun {
                below.append((y, run))
                y += 2
            }
        }
        trace?("candidates above=\(above.map(\.row)) below=\(below.map(\.row))")

        // Innermost first: the tightest box that validates is the one the user
        // was pointing at.
        var pairs: [(t: Int, b: Int, cost: Int)] = []
        for (i, t) in above.enumerated() {
            for (j, b) in below.enumerated() where b.row - t.row >= 6 {
                pairs.append((i, j, i + j))
            }
        }
        pairs.sort { $0.cost < $1.cost }

        for pair in pairs {
            let t = above[pair.t], b = below[pair.b]
            let left = max(t.span.lowerBound, b.span.lowerBound)
            let right = min(t.span.upperBound, b.span.upperBound)
            guard right - left >= minRun else { continue }

            // Both sides have to exist. Without this, two unrelated horizontal
            // lines — a heading and a rule below it — read as a rectangle.
            let coverage = min(verticalCoverage(column: left, from: t.row, to: b.row),
                               verticalCoverage(column: right, from: t.row, to: b.row))
            guard coverage >= 0.55 else { continue }

            let rect = CGRect(x: CGFloat(left) * cell, y: CGFloat(t.row) * cell,
                              width: CGFloat(right - left) * cell,
                              height: CGFloat(b.row - t.row) * cell)

            // Reject the degenerate answers: too small to have been aimed at,
            // and "the whole screen", which is not a snap.
            guard rect.width >= 24, rect.height >= 24,
                  rect.width <= imageSize.width * 0.97,
                  rect.height <= imageSize.height * 0.97 else { continue }

            trace?("matched rows \(t.row)..\(b.row) coverage \(String(format: "%.2f", coverage))")
            return rect.integral
        }

        trace?("no pair had four real sides")
        return nil
    }
}

// MARK: - Diagnostics

extension EdgeMap {
    /// Mean luminance of a row — used to confirm the map's orientation, which
    /// is the kind of thing that is much cheaper to measure than to reason
    /// about.
    func meanLuminance(row y: Int) -> Float {
        guard y >= 0, y < height else { return -1 }
        var sum: Float = 0
        for x in 0..<width { sum += lum[y * width + x] }
        return sum / Float(width)
    }

    /// Rows carrying a long horizontal edge run through `x`.
    func edgeRows(throughColumn x: Int, minRun: Int) -> [Int] {
        (1..<(height - 1)).filter { y in
            (horizontalRun(row: y, through: x)?.count ?? 0) >= minRun
        }
    }
}
