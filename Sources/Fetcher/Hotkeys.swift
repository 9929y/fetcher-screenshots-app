import AppKit
import Carbon.HIToolbox

/// A key plus modifiers, in Carbon's vocabulary because that is what
/// `RegisterEventHotKey` speaks.
struct HotkeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    /// A global hotkey outranks every app's own menu shortcut, so the default
    /// has to be a combination no application reasonably wants.
    ///
    /// Letters are where every app puts its commands, which rules out most of
    /// them: ⌘C and ⌘X are untouchable, ⇧⌘C is Copy as PNG in Figma and the
    /// element picker in DevTools, ⌥⌘C is Copy Properties in Figma. The control
    /// variants are the exception — nothing standard claims ⌃⌘C or ⌃⌘X, and
    /// they sit next to each other for one-handed use.
    static let defaultCapture = HotkeyCombo(keyCode: UInt32(kVK_ANSI_C),
                                            modifiers: UInt32(controlKey | cmdKey))
    /// Adjacent to capture, so the pair works without the hand moving.
    static let defaultRecapture = HotkeyCombo(keyCode: UInt32(kVK_ANSI_X),
                                              modifiers: UInt32(controlKey | cmdKey))

    var isValid: Bool {
        // A bare key is not a global shortcut; it would swallow typing
        // everywhere. Require at least one of the three real modifiers.
        modifiers & UInt32(cmdKey | optionKey | controlKey) != 0
    }

    /// How it reads in the UI, in the order macOS writes modifiers.
    var display: String {
        var out = ""
        if modifiers & UInt32(controlKey) != 0 { out += "⌃" }
        if modifiers & UInt32(optionKey)  != 0 { out += "⌥" }
        if modifiers & UInt32(shiftKey)   != 0 { out += "⇧" }
        if modifiers & UInt32(cmdKey)     != 0 { out += "⌘" }
        return out + HotkeyCombo.keyLabel(keyCode)
    }

    /// Built from an AppKit key event, for the recorder.
    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(event: NSEvent) {
        keyCode = UInt32(event.keyCode)
        var carbon: UInt32 = 0
        let flags = event.modifierFlags
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option)  { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift)   { carbon |= UInt32(shiftKey) }
        modifiers = carbon
    }

    private static let labels: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
        kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
        kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
        kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
        kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "esc",
        kVK_Delete: "⌫", kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=",
        kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",",
        kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\",
        kVK_ANSI_Grave: "`",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12"
    ]

    static func keyLabel(_ code: UInt32) -> String {
        labels[Int(code)] ?? "Key \(code)"
    }
}

/// Global hotkeys via Carbon's `RegisterEventHotKey`.
///
/// Dependency-free on purpose: this is the one Carbon API with no modern
/// replacement, it needs no entitlement and no Accessibility grant, and it works
/// for an accessory app. Registrations are addressed by slot so that rebinding
/// from the settings window can replace one without disturbing the other.
final class HotkeyManager {

    static let shared = HotkeyManager()

    enum Slot: UInt32, CaseIterable {
        case capture = 1
        case recapture = 2
    }

    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var installed = false

    private init() {}

    /// Replaces whatever was bound to this slot. Returns false when the system
    /// or another app already owns the combination, which the recorder surfaces
    /// rather than failing silently.
    @discardableResult
    func bind(_ slot: Slot, to combo: HotkeyCombo, action: @escaping () -> Void) -> Bool {
        guard combo.isValid else { return false }
        installHandlerIfNeeded()
        unbind(slot)

        let hotKeyID = EventHotKeyID(signature: OSType(0x46544348), id: slot.rawValue) // 'FTCH'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            FileHandle.standardError.write(
                "Fetcher: \(combo.display) is already taken (OSStatus \(status))\n"
                    .data(using: .utf8)!)
            return false
        }
        refs[slot.rawValue] = ref
        actions[slot.rawValue] = action
        return true
    }

    func unbind(_ slot: Slot) {
        if let ref = refs.removeValue(forKey: slot.rawValue) {
            UnregisterEventHotKey(ref)
        }
        actions[slot.rawValue] = nil
    }

    fileprivate func fire(_ id: UInt32) { actions[id]?() }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return noErr }
                var hkID = EventHotKeyID()
                let err = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &hkID)
                guard err == noErr else { return err }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData)
                    .takeUnretainedValue()
                DispatchQueue.main.async { manager.fire(hkID.id) }
                return noErr
            },
            1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
    }
}
