import Foundation
import CryptoKit
import os

/// Content-addressed store for images and files.
///
/// The path is derived from the hash, so deduplication happens for free:
/// the same screenshot copied twice takes up space once,
/// and the database record for it is a single row too.
public struct BlobStore: Sendable {
    private let location: StoreLocation
    private let logger = Logger(subsystem: "kz.mobilefirst.notchka", category: "blobs")

    public init(location: StoreLocation) {
        self.location = location
    }

    public static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Stores the data and returns the relative path.
    ///
    /// `hash` is accepted from outside because the caller has usually already
    /// computed it for the database row. SHA-256 of a megabyte-sized screenshot
    /// isn't free, and there's no reason to compute it twice for a single copy.
    /// If it wasn't passed, we compute it ourselves.
    @discardableResult
    public func store(_ data: Data, hash: String? = nil) throws -> String {
        let path = Self.relativePath(for: hash ?? Self.hash(data))
        let url = location.blobsDirectory.appending(path: path)
        // A file with this name is exactly these bytes: the content is the name.
        // No need to overwrite, and this saves a write on every repeat.
        guard !FileManager.default.fileExists(atPath: url.path) else { return path }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        return path
    }

    public func data(at path: String) throws -> Data {
        try Data(contentsOf: location.blobsDirectory.appending(path: path))
    }

    /// Removes a blob. A missing file is not an error: the goal of the call is achieved.
    ///
    /// This is deletion with a catch, not an existence check before it.
    /// Checking and deleting are two operations, and the file can disappear between
    /// them: size-based eviction from RetentionPolicy can easily coincide in time
    /// with manually removing the same blob. In that case the check passes,
    /// but the delete throws — exactly where the caller is entitled to expect
    /// a silent no-op.
    public func remove(at path: String) throws {
        let url = location.blobsDirectory.appending(path: path)
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
    }

    /// How much space is used by blobs.
    ///
    /// The volume budget in RetentionPolicy relies on this number, so a directory
    /// traversal error must leave a trace. Without a handler the enumerator
    /// silently skips an inaccessible subtree, and the method returns a
    /// plausible but understated number: eviction doesn't trigger in time,
    /// and there's nothing to diagnose the cause from. The handler doesn't
    /// abort the traversal — better to count the rest and report the issue
    /// than to count nothing at all.
    public func totalSize() throws -> Int {
        let fm = FileManager.default
        let enumerator = fm.enumerator(
            at: location.blobsDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [],
            errorHandler: { [logger] url, error in
                logger.error(
                    "failed to traverse \(url.lastPathComponent, privacy: .public) while counting blobs: \(error.localizedDescription, privacy: .public)"
                )
                return true
            }
        )
        // A missing blobs directory doesn't give nil, but an enumerator with zero
        // iterations, so the branch below doesn't actually trigger in practice. It's
        // needed because the API returns an Optional, not because it guards against
        // the directory being missing.
        guard let enumerator else { return 0 }

        var total = 0
        for case let url as URL in enumerator {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            total += size ?? 0
        }
        return total
    }

    /// The first two characters of the hash are the subdirectory: thousands of
    /// files in one folder slow down the file system and make the directory
    /// unreadable to the eye.
    private static func relativePath(for hash: String) -> String {
        "\(hash.prefix(2))/\(hash)"
    }
}
