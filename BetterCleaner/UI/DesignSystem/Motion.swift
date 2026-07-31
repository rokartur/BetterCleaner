import AppKit

/// The app's only animation entry point.
///
/// BetterCleaner animates almost nothing on purpose: navigation, selection and
/// keyboard actions must land instantly, and a cleaner that bounces while it
/// reports what it will delete reads as a toy. Motion is reserved for the few
/// places where it *explains a state change* — a progress bar filling, a status
/// pill being replaced.
///
/// Routing those through one helper means the Reduce Motion check can't be
/// forgotten: with the setting on, `animate` applies the change instantly rather
/// than skipping it, so the end state is always reached and no feedback depends
/// on movement alone.
@MainActor
enum Motion {
    /// Short enough to feel immediate, long enough to be followed. Anything past
    /// ~220ms starts to feel like waiting on the UI.
    static let duration: TimeInterval = 0.18

    /// Whether the user asked the system to cut animation.
    static var isReduced: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Run `changes` animated, or apply it instantly under Reduce Motion.
    ///
    /// - Parameter changes: must be written against the `animator()` proxy where
    ///   animation is wanted; it is invoked either way, so the final state is
    ///   identical in both modes.
    static func animate(duration: TimeInterval = Motion.duration,
                        _ changes: @escaping () -> Void) {
        guard !isReduced else {
            // No implicit animation context: apply and be done.
            changes()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.allowsImplicitAnimation = true
            // Interruptible: a second change mid-flight retargets instead of
            // queueing behind the first.
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            changes()
        }
    }

    /// Run `changes` with animation explicitly suppressed — for frequent,
    /// keyboard-driven updates (outline expand/collapse, list reloads) that must
    /// never appear to lag behind the key press.
    static func withoutAnimation(_ changes: () -> Void) {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        changes()
        NSAnimationContext.endGrouping()
    }
}
