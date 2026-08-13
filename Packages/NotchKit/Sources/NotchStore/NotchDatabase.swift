import Foundation
import GRDB

/// Соединение с базой и её схема.
///
/// Миграции нумерованы и неизменны после выпуска: план 4 добавит свои
/// следующим шагом, а не правкой этого. Иначе база пользователя, созданная
/// сегодня, разойдётся со схемой, которую ожидает код завтра.
public final class NotchDatabase: Sendable {
    public let queue: DatabaseQueue

    public init(location: StoreLocation) throws {
        try location.createDirectories()
        self.queue = try DatabaseQueue(path: location.databaseURL.path)
    }

    public func migrate() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1-clipboard") { db in
            try db.create(table: "clipboard_items") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull()
                // Хеш содержимого уникален: повторное копирование того же
                // текста поднимает существующую запись, а не плодит копии.
                t.column("content_hash", .text).notNull().unique()
                t.column("text_body", .text)
                t.column("blob_path", .text)
                t.column("byte_size", .integer).notNull()
                t.column("source_bundle_id", .text)
                t.column("source_app_name", .text)
                t.column("created_at", .datetime).notNull()
                t.column("last_used_at", .datetime).notNull()
                t.column("is_pinned", .boolean).notNull().defaults(to: false)
            }
            // Лента всегда сортируется по последнему использованию —
            // без индекса это полный скан на каждое открытие панели.
            try db.create(index: "idx_clipboard_last_used", on: "clipboard_items", columns: ["last_used_at"])
        }

        migrator.registerMigration("v2-search") { db in
            // Обычная таблица FTS5, а не contentless: индекс хранит копию
            // текста. Это сознательный размен. Contentless (content='')
            // сэкономил бы место, но удалять из него можно только особой
            // командой по rowid, а строки индекса ведут на владельца парой
            // (owner_kind, owner_id) — по ней и удаляем в Task 4, обычным
            // DELETE ... WHERE. Стоимость размена невелика: в индекс
            // попадает только текст, картинки и файлы туда не идут.
            try db.create(virtualTable: "search_index", using: FTS5()) { t in
                t.column("owner_kind").notIndexed()
                t.column("owner_id").notIndexed()
                t.column("title")
                t.column("body")
            }
        }

        try migrator.migrate(queue)
    }
}
