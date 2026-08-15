import Foundation

/// Turns raw cursor position into enter/exit events with threshold filtering.
/// Time is passed as a parameter (not read from the clock) — so tests don't wait a single millisecond.
public struct HoverDebouncer: Sendable {
    /// Minimum time the cursor must stay inside the zone to open the panel.
    public static let enterDwell: TimeInterval = 0.120
    /// Minimum time the cursor must stay outside the zone to close the panel.
    public static let exitGrace: TimeInterval = 0.250

    /// Current cursor position; a mismatch with `reported` is a pending transition.
    private var isInside = false
    /// The position already reported externally.
    /// Invariant: exit is only emitted if entry was already reported.
    private var reported = false
    /// Threshold timer start; not updated on movement in the same direction.
    private var changedAt: Date?

    public init() {}

    /// Whether a transition is pending that should fire once the threshold elapses.
    /// While false, the timer doesn't need to run — the app is idle.
    public var hasPendingTransition: Bool { isInside != reported }

    @discardableResult
    public mutating func cursorMoved(isInsideHotZone: Bool, at now: Date) -> NotchEvent? {
        if isInsideHotZone != isInside {
            isInside = isInsideHotZone
            changedAt = now
        }
        return evaluate(at: now)
    }

    /// Checks threshold conditions on a timer tick.
    /// Needed so thresholds still fire even when the cursor is frozen.
    @discardableResult
    public mutating func tick(at now: Date) -> NotchEvent? {
        evaluate(at: now)
    }

    private mutating func evaluate(at now: Date) -> NotchEvent? {
        guard hasPendingTransition, let changedAt else { return nil }
        let threshold = isInside ? Self.enterDwell : Self.exitGrace
        guard now.timeIntervalSince(changedAt) >= threshold else { return nil }
        reported = isInside
        return isInside ? .cursorEnteredHotZone : .cursorLeftHotZone
    }
}
