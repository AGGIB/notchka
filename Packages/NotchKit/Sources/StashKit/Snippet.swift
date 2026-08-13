import Foundation
import GRDB

/// Закреплённый сниппет: почта, номер карты, ИИН и подобное — то, что
/// пользователь держит под рукой в панели вместо того, чтобы каждый раз
/// искать и копировать заново.
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
    /// Маска фиксированной длины.
    ///
    /// Длина настоящего значения — сама по себе подсказка: по числу точек
    /// ИИН отличим от номера карты. Поэтому маска не зависит от значения.
    public static func masked(_ value: String) -> String {
        "••• ••• •••"
    }
}
