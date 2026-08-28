import AppKit

/// Persisted preferences.
///
/// Deliberately a small, flat store with defaults that are good enough that
/// most people never open the window. Anything here that has to be right for
/// the tool to work at all — the assignment order, the badge rules — is not
/// here; it is in the code, where it cannot be broken by a stray click.
final class Settings: ObservableObject {

    static let shared = Settings()

    private let defaults = UserDefaults.standard

    // MARK: Stored

    @Published var paletteHex: [String] {
        didSet { defaults.set(paletteHex, forKey: Key.palette) }
    }
    @Published var legendEnabled: Bool {
        didSet { defaults.set(legendEnabled, forKey: Key.legendEnabled) }
    }
    @Published var legendPlacement: LegendPlacement {
        didSet { defaults.set(legendPlacement.rawValue, forKey: Key.legendPlacement) }
    }
    @Published var promptTemplate: String {
        didSet { defaults.set(promptTemplate, forKey: Key.promptTemplate) }
    }
    @Published var saveDirectoryPath: String {
        didSet { defaults.set(saveDirectoryPath, forKey: Key.saveDirectory) }
    }
    @Published var exportAtOneX: Bool {
        didSet { defaults.set(exportAtOneX, forKey: Key.exportAtOneX) }
    }
    /// Inset the capture on a ground with a shadow under it, rather than
    /// running it to the edges of the file.
    @Published var marginedExport: Bool {
        didSet { defaults.set(marginedExport, forKey: Key.margined) }
    }
    @Published var frameSnapEnabled: Bool {
        didSet { defaults.set(frameSnapEnabled, forKey: Key.frameSnap) }
    }
    /// Seconds an untouched, unmarked capture waits before it finishes itself.
    /// Zero turns it off.
    @Published var autoFinishSeconds: Double {
        didSet { defaults.set(autoFinishSeconds, forKey: Key.autoFinish) }
    }
    /// Seconds the corner card stays before it puts itself away. Zero keeps it
    /// until dismissed. The file on disk is unaffected either way.
    @Published var shelfSeconds: Double {
        didSet { defaults.set(shelfSeconds, forKey: Key.shelfSeconds) }
    }
    @Published var captureHotkey: HotkeyCombo {
        didSet { save(captureHotkey, Key.captureHotkey) }
    }
    @Published var recaptureHotkey: HotkeyCombo {
        didSet { save(recaptureHotkey, Key.recaptureHotkey) }
    }

    private enum Key {
        static let palette = "palette"
        static let legendEnabled = "legendEnabled"
        static let legendPlacement = "legendPlacement"
        static let promptTemplate = "promptTemplate"
        static let saveDirectory = "saveDirectory"
        static let exportAtOneX = "exportAtOneX"
        static let margined = "marginedExport"
        static let frameSnap = "frameSnap"
        static let autoFinish = "autoFinishSeconds"
        static let shelfSeconds = "shelfSeconds"
        static let captureHotkey = "captureHotkey"
        static let recaptureHotkey = "recaptureHotkey"
    }

    private init() {
        let stored = defaults.stringArray(forKey: Key.palette)
        paletteHex = (stored?.count == Palette.count ? stored! : Palette.defaultHex)
        legendEnabled = defaults.object(forKey: Key.legendEnabled) as? Bool ?? true
        legendPlacement = LegendPlacement(
            rawValue: defaults.string(forKey: Key.legendPlacement) ?? "") ?? .automatic
        promptTemplate = defaults.string(forKey: Key.promptTemplate)
            ?? PromptGenerator.defaultTemplate
        saveDirectoryPath = defaults.string(forKey: Key.saveDirectory)
            ?? Output.defaultSaveDirectory.path
        exportAtOneX = defaults.bool(forKey: Key.exportAtOneX)
        marginedExport = defaults.object(forKey: Key.margined) as? Bool ?? true
        frameSnapEnabled = defaults.object(forKey: Key.frameSnap) as? Bool ?? true
        autoFinishSeconds = defaults.object(forKey: Key.autoFinish) as? Double ?? 3
        shelfSeconds = defaults.object(forKey: Key.shelfSeconds) as? Double ?? 10
        captureHotkey = Settings.load(Key.captureHotkey, defaults) ?? .defaultCapture
        recaptureHotkey = Settings.load(Key.recaptureHotkey, defaults) ?? .defaultRecapture
    }

    // MARK: Derived

    var saveDirectory: URL { URL(fileURLWithPath: saveDirectoryPath, isDirectory: true) }

    var palette: [Palette.Swatch] {
        zip(paletteHex, Palette.defaultWheel).map { hex, fallback in
            Palette.Swatch(name: fallback.name, hex: Palette.parse(hex) ?? fallback.hex)
        }
    }

    func resetPalette() { paletteHex = Palette.defaultHex }
    func resetPromptTemplate() { promptTemplate = PromptGenerator.defaultTemplate }

    // MARK: Codable helpers

    private func save<T: Encodable>(_ value: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func load<T: Decodable>(_ key: String, _ defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

enum LegendPlacement: String, CaseIterable, Identifiable {
    case automatic, below, right

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .below:     return "Below the capture"
        case .right:     return "Beside the capture"
        }
    }

    /// A tall, narrow capture — a mobile frame, a sidebar — gets a legend that
    /// would otherwise be wider than the image is. Beside it keeps the pasted
    /// result closer to square, which reads better in a chat.
    func resolved(forImageSize size: CGSize) -> LegendPlacement {
        guard self == .automatic else { return self }
        return size.height / max(1, size.width) > 1.15 ? .right : .below
    }
}
