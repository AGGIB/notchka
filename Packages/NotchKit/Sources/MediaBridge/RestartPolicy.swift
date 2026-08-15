import Foundation

/// Growing pauses between attempts to bring the adapter back up.
///
/// The 30-second cap is chosen so that a permanently failed adapter doesn't
/// drain the battery with restarts, but also doesn't force waiting minutes
/// after the cause of the failure is gone.
public struct RestartPolicy: Sendable {
    public static let initialDelay: TimeInterval = 1
    public static let maxDelay: TimeInterval = 30

    private var attempt = 0

    public init() {}

    public mutating func nextDelay() -> TimeInterval {
        let delay = min(Self.initialDelay * pow(2, Double(attempt)), Self.maxDelay)
        attempt += 1
        return delay
    }

    /// Called when the stream starts working again: the next failure will
    /// restart the count from zero instead of continuing from the accumulated cap.
    public mutating func reset() {
        attempt = 0
    }
}
