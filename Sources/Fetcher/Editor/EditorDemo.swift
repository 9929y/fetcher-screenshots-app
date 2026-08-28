import AppKit

/// Renders the editor to PNG without any mouse input.
///
/// The interactive states are the part of this app most likely to regress
/// invisibly, and they are exactly the part a headless test cannot click. So
/// the editor is driven programmatically into each state and its content view
/// is cached to disk — reviewable by eye, diffable in a pull request, and
/// runnable on a machine with no one sitting at it.
enum EditorDemo {

    static func run() {
        Task { @MainActor in
            guard let base = SyntheticScreen.make(size: CGSize(width: 900, height: 560),
                                                  scale: 2, dark: false) else {
                print("[fetcher] fixture failed"); NSApp.terminate(nil); return
            }

            let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("dist", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            let controller = EditorWindowController(
                image: base, scale: 2,
                regionOnScreen: CGRect(x: 200, y: 300, width: 900, height: 560)
            )
            controller.show()

            let canvas = controller.canvasForTesting

            // State 0 — nothing marked yet. The hint has to be legible over
            // whatever was captured, which is the case it failed at first.
            await settle(0.6)
            snapshot(controller, to: dir.appendingPathComponent("editor-empty.png"))

            let s: CGFloat = 2
            let a = canvas.document.add(rect: CGRect(x: 48 * s, y: 64 * s,
                                                     width: 400 * s, height: 34 * s))
            canvas.document.setNote("Heading — drop to 28/34, weight 600.", for: a.id)
            let b = canvas.document.add(rect: CGRect(x: 318 * s, y: 210 * s,
                                                     width: 264 * s, height: 190 * s))
            canvas.document.setNote("Middle card — add the accent border and an accent pill.", for: b.id)
            let c = canvas.document.add(rect: CGRect(x: 48 * s, y: 452 * s,
                                                     width: 170 * s, height: 40 * s))

            // State 1 — a box selected: handles, ringed swatch, live key hints.
            canvas.debugSetMode(.selected(c.id))
            controller.refreshToolbar()
            await settle()
            snapshot(controller, to: dir.appendingPathComponent("editor-selected.png"))

            // State 2 — writing a note: the field is bound to its box by color,
            // and every other box steps back so the binding is unambiguous.
            canvas.beginEditing(b.id)
            controller.refreshToolbar()
            await settle(0.5)
            snapshot(controller, to: dir.appendingPathComponent("editor-editing.png"))

            // State 3 — the shelf, holding a finished capture.
            canvas.commitNote(advance: false)
            var opts = Compositor.Options()
            opts.scale = 2
            if let composited = Compositor.render(base: base,
                                                  annotations: canvas.document.annotations,
                                                  options: opts),
               let url = try? Output.write(composited) {
                let shelf = ShelfController()
                shelf.present(image: composited, fileURL: url)
                await settle(0.6)
                let shelfURL = dir.appendingPathComponent("shelf.png")
                snapshot(view: shelf.viewForTesting, to: shelfURL)

                // The composited image carries its legend strip along the
                // bottom, and the legend ground is the only blue-biased thing
                // in it. If the thumbnail is inverted, the bias shows up at the
                // top instead — which is exactly how this drew at first.
                if let cg = NSImage(contentsOf: shelfURL)?
                    .cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    let rep = NSBitmapImageRep(cgImage: cg)
                    func bias(_ y: Int) -> CGFloat {
                        guard let c = rep.colorAt(x: cg.width / 2, y: y)?
                            .usingColorSpace(.sRGB) else { return 0 }
                        return c.blueComponent - c.redComponent
                    }
                    let thumbBottom = Int(Double(cg.height) * 0.78)
                    let ok = bias(thumbBottom) > bias(6)
                    print("[fetcher] shelf thumbnail upright: \(ok) "
                          + "(top bias \(String(format: "%.3f", bias(6))), "
                          + "legend bias \(String(format: "%.3f", bias(thumbBottom))))")
                }
            }

            // State 4 — the settings form. SwiftUI layout goes wrong silently
            // too, and this is the one window nobody looks at until they need it.
            let settings = SettingsWindowController(onHotkeysChanged: {})
            settings.window?.setContentSize(NSSize(width: 560, height: 1240))
            settings.showWindow(nil)
            await settle(1.0)
            if let content = settings.window?.contentView {
                snapshot(view: content, to: dir.appendingPathComponent("settings.png"))
            }
            settings.close()

            print("[fetcher] wrote editor-selected.png, editor-editing.png, "
                  + "shelf.png, settings.png")
            NSApp.terminate(nil)
        }
    }

    private static func settle(_ seconds: Double = 0.7) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static func snapshot(_ controller: EditorWindowController, to url: URL) {
        guard let view = controller.contentViewForTesting else { return }
        snapshot(view: view, to: url)
    }

    private static func snapshot(view: NSView, to url: URL) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
