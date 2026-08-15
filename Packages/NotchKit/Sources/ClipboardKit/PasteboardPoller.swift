import Foundation

/// Decides whether the pasteboard needs to be read.
///
/// macOS has no public notification for pasteboard changes — polling
/// the change count is what's left. The "read or not" logic is kept
/// separate from `NSPasteboard` so it can be tested without one: you
/// can't fake a live system's `changeCount` in a test.
public struct PasteboardPoller: Sendable {
    /// No point going faster: nobody copies five times a second.
    public static let interval: TimeInterval = 0.4
    /// An idle user isn't copying anything — no reason to wake the process.
    public static let idleThreshold: TimeInterval = 60

    private var lastSeenCount: Int?

    public init() {}

    public mutating func shouldRead(changeCount: Int, idleSeconds: TimeInterval) -> Bool {
        guard idleSeconds < Self.idleThreshold else { return false }
        // Don't remember the count while the user is idle: otherwise
        // anything copied during their absence would be lost forever.
        guard lastSeenCount != changeCount else { return false }
        lastSeenCount = changeCount
        return true
    }

    /// Marks a change as our own — no need to read it.
    ///
    /// The app writes to the pasteboard itself when the user pulls
    /// something out of history. Without this marker, polling a fraction
    /// of a second later would read back its own write and create a
    /// second entry for the same thing. For text this would be harmless:
    /// byte-for-byte it's the same, and hash-based dedup would just bump
    /// the existing entry. But an image comes back from the pasteboard in
    /// a different representation and a different size — the hash doesn't
    /// match, and a duplicate shows up in history, noticeably heavier than
    /// the original.
    public mutating func ignore(changeCount: Int) {
        lastSeenCount = changeCount
    }
}
