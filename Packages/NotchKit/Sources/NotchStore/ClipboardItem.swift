import Foundation
import GRDB

public enum ClipboardKind: String, Codable, Sendable {
    case text, image, file
}

/// Clipboard history entry.
///
/// Text lives directly in the row, while images and files are stored as a blob on disk:
/// putting megabyte-sized screenshots into SQLite would bloat the database and slow down
/// every query against the feed.
public struct ClipboardItem: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "clipboard_items"

    public var id: Int64?
    public var kind: ClipboardKind
    public var contentHash: String
    public var textBody: String?
    public var blobPath: String?
    public var byteSize: Int
    public var sourceBundleId: String?
    public var sourceAppName: String?
    public var createdAt: Date
    public var lastUsedAt: Date
    public var isPinned: Bool

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    enum CodingKeys: String, CodingKey {
        case id, kind
        case contentHash = "content_hash"
        case textBody = "text_body"
        case blobPath = "blob_path"
        case byteSize = "byte_size"
        case sourceBundleId = "source_bundle_id"
        case sourceAppName = "source_app_name"
        case createdAt = "created_at"
        case lastUsedAt = "last_used_at"
        case isPinned = "is_pinned"
    }
}
