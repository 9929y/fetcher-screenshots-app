import AppKit
import ServiceManagement

/// Login-item registration.
///
/// `SMAppService` registers a *bundle*, so this is meaningful only when running
/// from `Fetcher.app`. Running the bare executable during development, it
/// reports unavailable rather than throwing — the settings row disables itself
/// instead of offering a switch that cannot work.
enum LaunchAtLogin {

    static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    static var isEnabled: Bool {
        guard isAvailable else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    /// Returns the resulting state, which may differ from what was asked for:
    /// the user can have the item disabled in System Settings, and the app
    /// should show what is true rather than what it requested.
    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        guard isAvailable else { return false }
        do {
            if enabled { try SMAppService.mainApp.register() }
            else       { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Fetcher: could not \(enabled ? "enable" : "disable") launch at login — \(error.localizedDescription)")
        }
        return isEnabled
    }
}
