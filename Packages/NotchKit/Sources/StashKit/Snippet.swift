import Foundation
import GRDB

/// A pinned snippet: email, card number, national ID and the like — things
/// the user keeps at hand in the panel instead of having to search and
/// copy them again every time.
public struct Snippet: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "snippets"

    public var id: Int64?
    public var label: String
    public var value: String
    public var icon: String?
    public var colorHex: String?
    public var sortOrder: Int
    public var isSensitive: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    enum CodingKeys: String, CodingKey {
        case id, label, value, icon
        case colorHex = "color_hex"
        case sortOrder = "sort_order"
        case isSensitive = "is_sensitive"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

extension Snippet {
    /// Fixed-length mask.
    ///
    /// The length of the real value is itself a hint: dot count alone
    /// tells a national ID apart from a card number. That's why the mask
    /// doesn't depend on the value.
    public static func masked(_ value: String) -> String {
        "••• ••• •••"
    }
}
