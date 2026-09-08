import AppKit
import SwiftUI

/// Click, then press the combination you want.
///
/// Recording uses a local event monitor rather than first-responder plumbing:
/// the monitor swallows the keystroke outright, so recording ⌘W does not also
/// close the window on the way through.
final class HotkeyRecorderView: NSView {

    var combo: HotkeyCombo { didSet { needsDisplay = true } }
    var onChange: ((HotkeyCombo) -> Void)?

    private var isRecording = false { didSet { needsDisplay = true } }
    private var isHovered = false { didSet { needsDisplay = true } }
    private var monitor: Any?
    private var rejection: String? { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    init(combo: HotkeyCombo) {
        self.combo = combo
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 132, height: 24) }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: 6, yRadius: 6)
        (isRecording ? Theme.accent.withAlphaComponent(0.12)
                     : (isHovered ? NSColor.controlColor.blended(withFraction: 0.4, of: .white)!
                                  : NSColor.controlColor)).setFill()
        path.fill()
        (isRecording ? Theme.accent : NSColor.separatorColor).setStroke()
        path.lineWidth = isRecording ? 1.5 : 1
        path.stroke()

        let label = rejection ?? (isRecording ? "Press a shortcut…" : combo.display)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: isRecording ? .regular : .medium),
            .foregroundColor: rejection != nil ? NSColor.systemRed
                : (isRecording ? Theme.accent : NSColor.labelColor)
        ]
        let text = label as NSString
        let size = text.size(withAttributes: attrs)
        text.draw(at: CGPoint(x: bounds.midX - size.width / 2,
                              y: bounds.midY - size.height / 2), withAttributes: attrs)
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        isRecording = true
        rejection = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { self.stopRecording(); return nil }   // esc

            let candidate = HotkeyCombo(event: event)
            guard candidate.isValid else {
                self.reject("Needs ⌘, ⌥ or ⌃")
                return nil
            }
            self.combo = candidate
            self.onChange?(candidate)
            self.stopRecording()
            return nil
        }
    }

    private func reject(_ message: String) {
        rejection = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            self?.rejection = nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopRecording() }
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }
}

struct HotkeyRecorder: NSViewRepresentable {
    @Binding var combo: HotkeyCombo

    func makeNSView(context: Context) -> HotkeyRecorderView {
        let view = HotkeyRecorderView(combo: combo)
        view.onChange = { combo = $0 }
        return view
    }

    func updateNSView(_ view: HotkeyRecorderView, context: Context) {
        if view.combo != combo { view.combo = combo }
    }
}
