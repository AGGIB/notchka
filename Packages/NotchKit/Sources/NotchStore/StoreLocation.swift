import Foundation

/// Where the database and blobs live.
///
/// A separate type because tests need an isolated location: a run that
/// writes to the user's production database is unacceptable, and
/// swapping paths with inline strings is a sure way to slip up eventually.
public struct StoreLocation: Sendable, Equatable {
    public let root: URL

    public var databaseURL: URL { root.appending(path: "notch.sqlite") }
    public var blobsDirectory: URL { root.appending(path: "blobs") }

    public init(root: URL) {
        self.root = root
    }

    public init(bundleID: String) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.init(root: base.appending(path: bundleID))
    }

    /// Isolated location for tests.
    public static func temporary() -> StoreLocation {
        StoreLocation(root: URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "notchka-tests-\(UUID().uuidString)"))
    }

    public func createDirectories() throws {
        try FileManager.default.createDirectory(at: blobsDirectory, withIntermediateDirectories: true)
    }
}
