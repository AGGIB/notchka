import Foundation

/// Где лежат база и блобы.
///
/// Отдельный тип, потому что тестам нужно изолированное расположение:
/// прогон, который пишет в боевую базу пользователя, недопустим, а
/// подменять пути строками по месту — верный способ однажды промахнуться.
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

    /// Изолированное расположение для тестов.
    public static func temporary() -> StoreLocation {
        StoreLocation(root: URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "notchka-tests-\(UUID().uuidString)"))
    }

    public func createDirectories() throws {
        try FileManager.default.createDirectory(at: blobsDirectory, withIntermediateDirectories: true)
    }
}
