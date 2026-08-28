import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    private var statusItem: NSStatusItem!
    private var overlay: SelectionOverlay?
    private var editor: EditorWindowController?
    private let shelf = ShelfController()
    private var settingsWindow: SettingsWindowController?
    fileprivate var settingsWindowForDelegate: NSWindow? { settingsWindow?.window }

    /// What `recaptureLast` re-uses. Stored per display, because a rect is only
    /// meaningful relative to the display it came from.
    private var lastRegion: (displayID: CGDirectDisplayID, rect: CGRect)?

    /// Everything needed to put the editor back exactly as it was, for the
    /// corner card's undo. Kept because a capture that finished itself made a
    /// decision on the user's behalf, and that has to be reversible.
    private var lastSession: (image: CGImage, scale: CGFloat,
                              region: CGRect, annotations: [Annotation])?
    private var lastSavedURL: URL?

    private var captureInFlight = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildStatusItem()

        // The corner card's undo: back into the editor with the markup intact.
        shelf.onReopen = { [weak self] in
            guard let self, let session = self.lastSession else { return }
            self.openEditor(image: session.image, scale: session.scale,
                            region: session.region, restoring: session.annotations)
        }

        rebindHotkeys()

        if CommandLine.arguments.contains("--selftest") {
            SelfTest.run()
            return
        }

        if CommandLine.arguments.contains("--e2e") {
            E2ETest.run()
            return
        }

        if CommandLine.arguments.contains("--editor-demo") {
            EditorDemo.run()
            return
        }

        if CommandLine.arguments.contains("--capture-now") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.beginCapture(reuseLastRegion: false)
            }
        }

        log("ready — \(Settings.shared.captureHotkey.display) to capture, "
            + "\(Settings.shared.recaptureHotkey.display) to re-capture")
    }

    /// Called at launch and whenever the settings window changes a binding.
    func rebindHotkeys() {
        let settings = Settings.shared
        HotkeyManager.shared.bind(.capture, to: settings.captureHotkey) { [weak self] in
            self?.beginCapture(reuseLastRegion: false)
        }
        HotkeyManager.shared.bind(.recapture, to: settings.recaptureHotkey) { [weak self] in
            self?.beginCapture(reuseLastRegion: true)
        }
    }

    // MARK: Status item

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "rectangle.dashed",
                                   accessibilityDescription: "Fetcher")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "Capture Region", action: #selector(menuCapture), keyEquivalent: "")
            .target = self
        let re = menu.addItem(withTitle: "Re-capture Last Region",
                              action: #selector(menuRecapture), keyEquivalent: "")
        re.target = self
        menu.addItem(.separator())
        let path = menu.addItem(withTitle: "Copy Last File Path",
                                action: #selector(menuCopyPath), keyEquivalent: "")
        path.target = self
        let reveal = menu.addItem(withTitle: "Reveal Captures Folder",
                                  action: #selector(menuReveal), keyEquivalent: "")
        reveal.target = self
        menu.addItem(.separator())
        let prefs = menu.addItem(withTitle: "Settings…",
                                 action: #selector(menuSettings), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Fetcher", action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc private func menuCapture()   { beginCapture(reuseLastRegion: false) }
    @objc private func menuRecapture() { beginCapture(reuseLastRegion: true) }

    @objc private func menuCopyPath() {
        guard let url = lastSavedURL else { flash("no capture yet"); return }
        Output.copyPath(url)
        flash("path copied")
    }

    @objc private func menuSettings() {
        let controller = settingsWindow ?? SettingsWindowController { [weak self] in
            self?.rebindHotkeys()
        }
        settingsWindow = controller
        controller.window?.delegate = self
        controller.present()
    }

    @objc private func menuReveal() {
        let dir = Output.saveDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    // MARK: Capture flow

    private func beginCapture(reuseLastRegion: Bool) {
        guard !captureInFlight else { return }

        guard Permissions.hasScreenCapture else {
            Permissions.requestScreenCapture()
            Permissions.presentDeniedAlert()
            return
        }

        captureInFlight = true
        Task { @MainActor in
            defer { captureInFlight = false }
            do {
                // Freeze first, always. The overlay draws these pixels, so it
                // cannot contaminate its own capture.
                let displays = try await ScreenFreeze.freezeAll()

                if reuseLastRegion, let last = lastRegion,
                   let display = displays.first(where: { $0.displayID == last.displayID }) {
                    finishCapture(display: display, rect: last.rect)
                    return
                }
                if reuseLastRegion {
                    log("no valid last region — falling back to the crosshair")
                }

                let ov = SelectionOverlay()
                overlay = ov
                ov.present(displays) { [weak self] result in
                    self?.overlay = nil
                    guard let self, let (display, rect) = result else {
                        self?.log("cancelled")
                        return
                    }
                    self.finishCapture(display: display, rect: rect)
                }
            } catch ScreenFreeze.FreezeError.permissionStale {
                log("screen recording grant is stale for this build")
                Permissions.requestScreenCapture()
                Permissions.presentStaleGrantAlert()
            } catch {
                log("capture failed — \(error.localizedDescription)")
                presentError(error)
            }
        }
    }

    private func finishCapture(display: FrozenDisplay, rect: CGRect) {
        lastRegion = (display.displayID, rect)

        let viewHeight = display.screen.frame.height
        let pixels = display.pixelRect(fromViewRect: rect, viewHeight: viewHeight)

        guard let cropped = display.image.cropping(to: pixels) else {
            log("crop failed for \(pixels)")
            return
        }

        // The editor opens over the exact pixels that were captured, so the
        // transition from "selecting" to "annotating" moves nothing on screen.
        let onScreen = CGRect(x: display.screen.frame.minX + rect.minX,
                              y: display.screen.frame.minY + rect.minY,
                              width: rect.width, height: rect.height)

        openEditor(image: cropped, scale: display.scale, region: onScreen, restoring: [])
    }

    /// One path for a fresh capture and for reopening a finished one.
    private func openEditor(image: CGImage, scale: CGFloat, region: CGRect,
                            restoring annotations: [Annotation]) {
        let controller = EditorWindowController(image: image, scale: scale,
                                                regionOnScreen: region)
        controller.onFinished = { [weak self] composited, url, marks in
            guard let self else { return }
            self.lastSavedURL = url
            self.lastSession = (image, scale, region, marks)
            self.editor = nil
            let where_ = url.map { " — file at \($0.path)" } ?? ""
            self.log("done \(composited.width)x\(composited.height)\(where_)")
            self.flash("copied")
            self.shelf.present(image: composited, fileURL: url)
        }
        controller.onCancelled = { [weak self] in
            self?.editor = nil
            self?.log("editor cancelled")
        }
        editor = controller
        controller.show()
        if !annotations.isEmpty { controller.restore(annotations) }
    }

    // MARK: Feedback

    private func flash(_ text: String) {
        guard let button = statusItem.button else { return }
        button.title = " \(text)"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            button.title = ""
        }
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Capture failed"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func log(_ message: String) {
        print("[fetcher] \(message)")
        fflush(stdout)
    }
}

// MARK: - Settings window lifecycle

extension AppDelegate {
    /// Back to menu-bar-only once settings closes. The app becomes a regular
    /// app just long enough to own a window, because an accessory app's window
    /// opens behind everything and never takes the keyboard.
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === settingsWindowForDelegate else { return }
        NSApp.setActivationPolicy(.accessory)
    }
}
