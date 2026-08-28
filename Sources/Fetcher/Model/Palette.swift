import AppKit

/// The ten annotation colors.
///
/// Two orders matter and they are deliberately different:
///
/// - `wheel` is display order — the hue wheel, which is how the palette reads
///   in settings and how the number keys 1–0 map onto it.
/// - `assignment` is the order colors are handed out to new annotations. It
///   hops across the wheel so that consecutive boxes are never adjacent hues;
///   every consecutive pair is at least 127° apart.
///
/// Since the common case is 3–4 boxes, the first four assigned colors are the
/// four most widely separated hues in the set.
enum Palette {

    struct Swatch {
        let name: String
        let hex: UInt32
    }

    /// Display order: around the hue wheel. Index here is what `1`–`0` selects.
    ///
    /// Morandi: saturation held around 25–40% with a high grey component, so
    /// the boxes sit *on* a design instead of shouting over it.
    ///
    /// Low saturation costs identifiability twice — box against screenshot, and
    /// box against box — so three things compensate: hue spacing is kept as
    /// wide as the wheel allows, the stroke is heavier than a saturated palette
    /// would need, and the numbered badge carries the identity that color alone
    /// no longer can. The names are the ones you would say out loud, because
    /// they end up in the prompt text.
    static let defaultWheel: [Swatch] = [
        Swatch(name: "Rose",       hex: 0xB4746E),   //   5 deg
        Swatch(name: "Clay",       hex: 0xBE8A65),   //  25
        Swatch(name: "Sand",       hex: 0xC3A878),   //  38
        Swatch(name: "Olive",      hex: 0x9AA87B),   //  79
        Swatch(name: "Sage",       hex: 0x7E9B84),   // 132
        Swatch(name: "Eucalyptus", hex: 0x6E9B98),   // 176
        Swatch(name: "Mist",       hex: 0x7D9BB5),   // 208
        Swatch(name: "Dusk",       hex: 0x8189AE),   // 229
        Swatch(name: "Lilac",      hex: 0x9C87A8),   // 278
        Swatch(name: "Mauve",      hex: 0xB2839A)    // 331
    ]

    static let count = 10

    static var defaultHex: [String] {
        defaultWheel.map { String(format: "#%06X", $0.hex) }
    }

    /// The palette in use. Customizable; the Morandi set is the fallback for
    /// any entry that fails to parse, so a bad value can never leave the app
    /// with fewer than ten usable colors.
    static var wheel: [Swatch] { Settings.shared.palette }

    static func parse(_ hex: String) -> UInt32? {
        var text = hex.trimmingCharacters(in: .whitespaces).uppercased()
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        return value
    }

    /// Assignment order, as indices into `wheel`.
    /// Rose, Eucalyptus, Sand, Dusk, Olive, Lilac, Sage, Mauve, Mist, Clay —
    /// every consecutive pair at least 122 deg apart, and the first four (the
    /// common case) at least 137 deg apart.
    static let assignment: [Int] = [0, 5, 2, 7, 3, 8, 4, 9, 6, 1]

    /// The wheel index for the nth annotation (0-based). Cycles past ten;
    /// the badge number keeps counting, which is what keeps them apart.
    static func wheelIndex(forAnnotation n: Int) -> Int {
        assignment[n % assignment.count]
    }

    static func swatch(_ wheelIndex: Int) -> Swatch {
        wheel[wheelIndex % wheel.count]
    }

    static func color(_ wheelIndex: Int) -> NSColor {
        let hex = swatch(wheelIndex).hex
        return NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green:   CGFloat((hex >> 8)  & 0xFF) / 255,
            blue:    CGFloat( hex        & 0xFF) / 255,
            alpha: 1
        )
    }

    /// Where this color sits in the hand-out order, 1-based. Shown in settings
    /// so "a fixed order" is something you can see rather than take on trust.
    static func assignmentPosition(_ wheelIndex: Int) -> Int {
        (assignment.firstIndex(of: wheelIndex) ?? 0) + 1
    }

    /// The name shown in the UI. Designed, and stable across recoloring.
    static func displayName(_ wheelIndex: Int) -> String {
        defaultWheel[wheelIndex % defaultWheel.count].name
    }

    /// The name written into the prompt, derived from the color itself.
    ///
    /// These have to be two different things. "Eucalyptus" is a good name in a
    /// settings window and a bad one in an instruction to a model — and once
    /// the palette is customizable, a stored name is worse than useless: change
    /// slot one to blue and every prompt still calls it rose, which is not
    /// ambiguous, it is wrong. Deriving from the hue cannot drift.
    static func name(_ wheelIndex: Int) -> String {
        guard let c = color(wheelIndex).usingColorSpace(.sRGB) else { return "colored" }
        if c.saturationComponent < 0.10 { return c.brightnessComponent < 0.5 ? "grey" : "light grey" }

        let hue = c.hueComponent * 360
        switch hue {
        case ..<15, 345...: return "red"
        case ..<30:  return "orange"
        case ..<50:  return "amber"
        case ..<70:  return "yellow"
        case ..<100: return "olive"
        case ..<150: return "green"
        case ..<190: return "teal"
        case ..<215: return "blue"
        case ..<255: return "indigo"
        case ..<300: return "violet"
        default:     return "pink"
        }
    }

    /// HSB -> sRGB, used by the contrast correction. Reducing brightness while
    /// nudging saturation keeps a Morandi hue recognizable; blending toward
    /// black would flatten the whole palette into grey.
    static func srgb(hue h: CGFloat, saturation s: CGFloat,
                     brightness v: CGFloat) -> NSColor {
        let i = floor(h * 6)
        let f = h * 6 - i
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        let (r, g, b): (CGFloat, CGFloat, CGFloat)
        switch Int(i) % 6 {
        case 0:  (r, g, b) = (v, t, p)
        case 1:  (r, g, b) = (q, v, p)
        case 2:  (r, g, b) = (p, v, t)
        case 3:  (r, g, b) = (p, q, v)
        case 4:  (r, g, b) = (t, p, v)
        default: (r, g, b) = (v, p, q)
        }
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
