import AppKit

// Menu-bar-only: no Dock icon, no main window. A capture tool that steals
// focus or shows up in the Dock is a capture tool you stop reaching for.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
