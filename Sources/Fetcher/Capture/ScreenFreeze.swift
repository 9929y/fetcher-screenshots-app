import AppKit
import ScreenCaptureKit

/// One display's frozen pixels, plus everything needed to map between the
/// overlay's point coordinates and the bitmap's pixel coordinates.
struct FrozenDisplay {
    let screen: NSScreen
    let displayID: CGDirectDisplayID
    let image: CGImage
    /// Backing scale of this display (1 or 2). The bitmap is at this scale.
    let scale: CGFloat
    /// Built at freeze time so hovering is instant. A Figma frame is not an OS
    /// window, so its bounds can only be found in the pixels.
    let edges: EdgeMap?

    /// Convert a rect in the overlay view's coordinate space (points,
    /// bottom-left origin) into the bitmap's coordinate space (pixels,
    /// top-left origin).
    func pixelRect(fromViewRect r: CGRect, viewHeight: CGFloat) -> CGRect {
        CGRect(
            x: (r.minX * scale).rounded(.down),
            y: ((viewHeight - r.maxY) * scale).rounded(.down),
            width:  max(1, (r.width  * scale).rounded()),
            height: max(1, (r.height * scale).rounded())
        )
    }
}

/// Capture happens *before* the selection overlay appears, not after.
///
/// Freezing first buys three things at once: the overlay can't contaminate its
/// own capture, frame-snap detection has real pixels to analyze, and the loupe
/// can read exact colors. Every serious capture tool works this way.
enum ScreenFreeze {

    enum FreezeError: LocalizedError {
        /// The permission was granted to an earlier build of this binary.
        ///
        /// This is the single most common failure in the whole app and it is
        /// easy to misdiagnose: `CGPreflightScreenCaptureAccess` still answers
        /// yes, while ScreenCaptureKit quietly returns an empty display list.
        /// Reporting it as "no displays" would send the user looking at their
        /// monitors instead of at Settings.
        case permissionStale
        case noDisplays
        case captureFailed(String)

        var errorDescription: String? {
            switch self {
            case .permissionStale:
                return "Screen Recording access is no longer valid for this build "
                     + "of Fetcher. macOS ties the permission to the app's code "
                     + "signature, so rebuilding or re-installing invalidates it. "
                     + "Remove Fetcher from Privacy & Security -> Screen Recording, "
                     + "add it again, and relaunch."
            case .noDisplays:
                return "No displays available to capture."
            case .captureFailed(let why):
                return "Screen capture failed: \(why)"
            }
        }
    }

    static func freezeAll() async throws -> [FrozenDisplay] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        // An empty display list while AppKit can see screens means the grant is
        // stale, not that the machine has no monitors.
        guard !content.displays.isEmpty else {
            throw NSScreen.screens.isEmpty ? FreezeError.noDisplays
                                           : FreezeError.permissionStale
        }

        var out: [FrozenDisplay] = []
        for display in content.displays {
            guard let screen = nsScreen(for: display.displayID) else { continue }
            let scale = screen.backingScaleFactor

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let cfg = SCStreamConfiguration()
            cfg.width  = Int(CGFloat(display.width)  * scale)
            cfg.height = Int(CGFloat(display.height) * scale)
            cfg.captureResolution = .best
            cfg.showsCursor = false
            cfg.scalesToFit = false

            do {
                let img = try await SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: cfg
                )
                out.append(FrozenDisplay(
                    screen: screen, displayID: display.displayID,
                    image: img, scale: scale, edges: EdgeMap.build(from: img)
                ))
            } catch {
                throw FreezeError.captureFailed(error.localizedDescription)
            }
        }
        // Same reasoning: displays came back but none matched a real screen.
        guard !out.isEmpty else {
            throw NSScreen.screens.isEmpty ? FreezeError.noDisplays
                                           : FreezeError.permissionStale
        }
        return out
    }

    private static func nsScreen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            return (screen.deviceDescription[key] as? NSNumber)?.uint32Value == id
        }
    }
}
