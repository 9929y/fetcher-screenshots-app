import AppKit

/// Motion vocabulary.
///
/// The target is the Apple feel: short, ease-out, no bounce except where a
/// bounce carries meaning — a badge confirming that a note just bound to it.
/// Custom drawing means these are *values* being animated rather than layer
/// properties, so the canvas ticks them and redraws.
enum Motion {

    /// Honour the system setting. Every animation collapses to an instant
    /// state change when this is on.
    static var reduced: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    enum Duration {
        /// State flips the user did on purpose: hover, selection, color change.
        static let quick: CFTimeInterval = YYStudioTokens.quick
        /// Things appearing or leaving: handles, the note field, dimming.
        static let standard: CFTimeInterval = YYStudioTokens.fast
        /// Window entrance and exit.
        static let entrance: CFTimeInterval = YYStudioTokens.medium
        /// The commit confirmation.
        static let pulse: CFTimeInterval = YYStudioTokens.slow
    }

    enum Curve {
        case easeOut, spring, linear

        func value(_ t: CGFloat) -> CGFloat {
            switch self {
            case .linear:  return t
            case .easeOut: return 1 - pow(1 - t, 3)
            case .spring:
                // One soft overshoot, settled by the end. Enough to read as
                // physical, not enough to read as a toy.
                let s: CGFloat = 1.70158
                let p = t - 1
                return p * p * ((s + 1) * p + s) + 1
            }
        }
    }

    static let timing = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)

    /// Wraps an AppKit animation with the reduce-motion escape hatch.
    static func animate(_ duration: CFTimeInterval,
                        _ body: @escaping (NSAnimationContext) -> Void,
                        completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = reduced ? 0 : duration
            ctx.timingFunction = timing
            ctx.allowsImplicitAnimation = true
            body(ctx)
        }, completionHandler: completion)
    }
}

/// A scalar that eases toward a target. Cheap enough to keep several per
/// annotation, which is what makes per-element state animation practical in a
/// hand-drawn canvas.
struct Tween {
    private var from: CGFloat
    private var to: CGFloat
    private var startedAt: CFTimeInterval
    private var duration: CFTimeInterval
    private var curve: Motion.Curve

    init(_ value: CGFloat = 0) {
        from = value; to = value
        startedAt = 0; duration = 0
        curve = .easeOut
    }

    var target: CGFloat { to }

    mutating func set(_ value: CGFloat,
                      duration d: CFTimeInterval = Motion.Duration.quick,
                      curve c: Motion.Curve = .easeOut,
                      now: CFTimeInterval) {
        guard value != to else { return }
        from = self.value(at: now)
        to = value
        duration = Motion.reduced ? 0 : d
        curve = c
        startedAt = now
    }

    /// Jump with no animation — used when rebuilding state, so a redraw does
    /// not read as a transition the user did not cause.
    mutating func snap(_ value: CGFloat) {
        from = value; to = value; duration = 0; startedAt = 0
    }

    func value(at now: CFTimeInterval) -> CGFloat {
        guard duration > 0 else { return to }
        let t = min(1, max(0, CGFloat((now - startedAt) / duration)))
        return from + (to - from) * curve.value(t)
    }

    func isAnimating(at now: CFTimeInterval) -> Bool {
        duration > 0 && now - startedAt < duration
    }
}

/// Per-annotation animated state. One exists for every box on the canvas; the
/// canvas ticks them together and stops the timer once they all settle.
struct AnnotationMotion {
    var hover = Tween(0)       // 0 idle, 1 pointer over the box
    var select = Tween(0)      // 0 unselected, 1 handles shown
    var dim = Tween(1)         // 1 full strength, lower while another box is being written about
    var badgePulse = Tween(1)  // badge scale, spikes on commit
    var alive = Tween(1)       // 1 present, 0 mid-delete

    func isAnimating(at now: CFTimeInterval) -> Bool {
        hover.isAnimating(at: now) || select.isAnimating(at: now)
            || dim.isAnimating(at: now) || badgePulse.isAnimating(at: now)
            || alive.isAnimating(at: now)
    }
}
