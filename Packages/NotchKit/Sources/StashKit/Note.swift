import Foundation
import GRDB

public struct Note: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "notes"

    public var id: Int64?
    public var body: String
    public var createdAt: Date
    public var updatedAt: Date

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    enum CodingKeys: String, CodingKey {
        case id, body
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
