import AppKit
import CoreGraphics

/// Screen Recording is the first-run cliff, so this is deliberately explicit:
/// preflight silently, and only ever ask from a context where we can explain
/// why. Never ask cold.
enum Permissions {

    static var hasScreenCapture: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Triggers the system prompt. Returns immediately; the grant does not
    /// apply to the already-running process on some OS versions, which is why
    /// callers must handle "granted but still failing" by re-checking on focus.
    @discardableResult
    static func requestScreenCapture() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    /// Shown when the grant exists but no longer matches this build. Separate
    /// from the first-run alert because the fix is different: the entry has to
    /// be removed and re-added, not just switched on.
    static func presentStaleGrantAlert() {
        let alert = NSAlert()
        alert.messageText = "Fetcher needs Screen Recording access again"
        alert.informativeText =
            "macOS ties this permission to the app's code signature, so rebuilding "
          + "or re-installing Fetcher invalidates it.\n\n"
          + "In Privacy & Security -> Screen Recording, remove Fetcher with the "
          + "minus button, add it again, and relaunch."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            openScreenRecordingSettings()
        }
    }

    /// Shown instead of a capture when permission is missing.
    static func presentDeniedAlert() {
        let alert = NSAlert()
        alert.messageText = "Fetcher needs Screen Recording access"
        alert.informativeText =
            "macOS requires this permission for any app that captures the screen. "
          + "Fetcher uses it only when you press the capture shortcut, and the "
          + "image never leaves your machine.\n\n"
          + "Enable Fetcher under Privacy & Security -> Screen Recording, then "
          + "try again."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            openScreenRecordingSettings()
        }
    }
}
