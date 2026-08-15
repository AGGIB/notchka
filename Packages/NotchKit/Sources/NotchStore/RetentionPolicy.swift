import Foundation

/// How much history to keep.
///
/// Three independent limits, not one: count protects feed speed,
/// age protects privacy (something copied six months ago the user has
/// long forgotten), and size protects disk space, since one screenshot
/// weighs as much as a thousand lines of text. Whichever limit is hit
/// first wins.
public struct RetentionPolicy: Sendable, Equatable {
    public let maxItems: Int
    public let maxAge: TimeInterval
    public let maxBlobBytes: Int

    public init(maxItems: Int, maxAge: TimeInterval, maxBlobBytes: Int) {
        self.maxItems = maxItems
        self.maxAge = maxAge
        self.maxBlobBytes = maxBlobBytes
    }

    public static let `default` = RetentionPolicy(
        maxItems: 500,
        maxAge: 30 * 24 * 3600,
        maxBlobBytes: 2 * 1024 * 1024 * 1024
    )
}
