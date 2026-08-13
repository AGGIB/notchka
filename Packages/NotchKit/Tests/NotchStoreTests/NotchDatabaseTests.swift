import Testing
import Foundation
import GRDB
@testable import NotchStore

/// Проверки самой схемы, а не работающего поверх неё репозитория.
///
/// Существуют потому, что два свойства схемы держатся на решениях, которые
/// легко откатить по невнимательности, и откат не даст ни ошибки сборки, ни
/// исключения во время работы. Испорченная миграция обходится дороже обычной
/// ошибки: у пользователя уже созданная база не переедет.

private func makeDatabase() throws -> NotchDatabase {
    let database = try NotchDatabase(location: .temporary())
    try database.migrate()
    return database
}

@Test("повторная миграция не ломает уже мигрированную базу")
func migrationIsIdempotent() throws {
    let database = try makeDatabase()
    try database.migrate()

    let tableCount = try database.queue.read { db in
        try Int.fetchOne(
            db,
            sql: "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'clipboard_items'"
        )
    }
    #expect(tableCount == 1)
}

/// Главная защита этого файла.
///
/// Полнотекстовая таблица создана обычной, а не contentless — намеренно.
/// Contentless выглядит экономнее и её легко «оптимизировать» обратно, но
/// она не хранит значений колонок: чтение вернуло бы пустые строки, а
/// удаление по владельцу перестало бы находить хоть что-нибудь. Причём
/// молча — DELETE на contentless не падает, он просто ничего не удаляет,
/// и тексты, удалённые пользователем из истории, продолжали бы лежать
/// в индексе.
@Test("значения колонок индекса читаются обратно — таблица не contentless")
func searchIndexStoresItsColumns() throws {
    let database = try makeDatabase()
    try database.queue.write { db in
        try db.execute(
            sql: "INSERT INTO search_index (owner_kind, owner_id, title, body) VALUES (?, ?, ?, ?)",
            arguments: ["clipboard", 1, "TextEdit", "привет мир"]
        )
    }

    let owner = try database.queue.read { db in
        try String.fetchOne(db, sql: "SELECT owner_kind FROM search_index")
    }
    #expect(owner == "clipboard")
}

@Test("удаление по владельцу убирает ровно свою строку индекса")
func searchIndexRowsAreDeletableByOwner() throws {
    let database = try makeDatabase()
    try database.queue.write { db in
        for id in 1...2 {
            try db.execute(
                sql: "INSERT INTO search_index (owner_kind, owner_id, title, body) VALUES (?, ?, ?, ?)",
                arguments: ["clipboard", id, "источник", "тело \(id)"]
            )
        }
        try db.execute(
            sql: "DELETE FROM search_index WHERE owner_kind = ? AND owner_id = ?",
            arguments: ["clipboard", 1]
        )
    }

    let survivors = try database.queue.read { db in
        try Int.fetchAll(db, sql: "SELECT owner_id FROM search_index")
    }
    #expect(survivors == [2])
}

@Test("текст остаётся находимым через полнотекстовый поиск")
func searchIndexIsQueryable() throws {
    let database = try makeDatabase()
    try database.queue.write { db in
        try db.execute(
            sql: "INSERT INTO search_index (owner_kind, owner_id, title, body) VALUES (?, ?, ?, ?)",
            arguments: ["clipboard", 7, "TextEdit", "квитанция об оплате"]
        )
    }

    let found = try database.queue.read { db in
        try Int.fetchOne(db, sql: "SELECT owner_id FROM search_index WHERE search_index MATCH 'квитанция'")
    }
    #expect(found == 7)
}

/// На этой уникальности держится дедупликация: повторно скопированный текст
/// обязан поднять существующую запись, а не завести вторую.
@Test("повторный content_hash отвергается самой базой")
func contentHashIsUnique() throws {
    let database = try makeDatabase()
    let insert = """
        INSERT INTO clipboard_items
            (kind, content_hash, text_body, byte_size, created_at, last_used_at, is_pinned)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """
    let now = Date(timeIntervalSince1970: 1_000_000)

    try database.queue.write { db in
        try db.execute(sql: insert, arguments: ["text", "одинаковый", "первый", 6, now, now, false])
    }

    #expect(throws: (any Error).self) {
        try database.queue.write { db in
            try db.execute(sql: insert, arguments: ["text", "одинаковый", "второй", 6, now, now, false])
        }
    }
}
