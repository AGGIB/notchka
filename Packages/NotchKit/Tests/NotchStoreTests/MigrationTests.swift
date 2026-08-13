import Testing
import Foundation
import GRDB
@testable import NotchStore

private func migratedDatabase() throws -> NotchDatabase {
    let database = try NotchDatabase(location: .temporary())
    try database.migrate()
    return database
}

@Test("после миграций существуют все четыре таблицы")
func allTablesExist() throws {
    let database = try migratedDatabase()
    try database.queue.read { db in
        // Чтение вынесено в let, а не `#expect(try ...)` сразу в аргументе:
        // компилятор Swift 6.3 не считает try внутри #expect обработанным,
        // если #expect вызван внутри замыкания — сборка падает с "errors
        // thrown from here are not handled" (баг swiftlang/swift#78395).
        // Это обход бага компилятора, а не требование стиля — тот же
        // приём повторён ниже везде, где встречается этот паттерн.
        let hasClipboardItems = try db.tableExists("clipboard_items")
        let hasNotes = try db.tableExists("notes")
        let hasSnippets = try db.tableExists("snippets")
        let hasSearchIndex = try db.tableExists("search_index")
        #expect(hasClipboardItems)
        #expect(hasNotes)
        #expect(hasSnippets)
        #expect(hasSearchIndex)
    }
}

// Имя нарочно не `migrationIsIdempotent`: такая функция уже есть в
// NotchDatabaseTests того же тест-таргета, и вторая с тем же именем —
// ошибка повторного объявления, а не два теста.
@Test("повторная миграция не теряет уже сохранённые строки")
func migrationPreservesExistingRows() throws {
    let location = StoreLocation.temporary()
    let first = try NotchDatabase(location: location)
    try first.migrate()
    try first.queue.write { db in
        try db.execute(sql: "INSERT INTO notes (body, created_at, updated_at) VALUES (?, ?, ?)",
                       arguments: ["сохранить меня", Date(), Date()])
    }

    let second = try NotchDatabase(location: location)
    try second.migrate()
    let count = try second.queue.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notes") ?? 0
    }
    #expect(count == 1)
}

@Test("порядок пинов хранится и уникален не требуется — дубли порядка допустимы")
func snippetOrderColumnExists() throws {
    let database = try migratedDatabase()
    try database.queue.write { db in
        for order in [1, 1, 2] {
            try db.execute(
                sql: "INSERT INTO snippets (label, value, sort_order, is_sensitive, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
                arguments: ["л", "з", order, false, Date(), Date()]
            )
        }
        let snippetCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM snippets")
        #expect(snippetCount == 3)
    }
}

/// Проверяет само решение, а не наличие таблицы: индекс не связан с
/// владельцами внешними ключами, поэтому удаление записи НЕ уносит с собой
/// её строку индекса. Чистка — обязанность репозитория, и именно на ней
/// держится то, что удалённая заметка перестаёт находиться поиском.
///
/// Прошлая версия этого теста проверяла только `tableExists` — ровно то же,
/// что и `allTablesExist` строкой выше, — и прошла бы при любой схеме, в том
/// числе с каскадным удалением, которого мы как раз не хотим.
///
/// Сама таблица индекса при этом обычная FTS5, НЕ contentless: план 3 выбрал
/// так намеренно, потому что из contentless нельзя удалять обычным
/// `DELETE ... WHERE`, а именно им её и чистят. Не «оптимизировать» обратно.
@Test("удаление владельца не уносит строку индекса — чистит репозиторий")
func searchIndexSurvivesOwnerDeletion() throws {
    let database = try migratedDatabase()
    try database.queue.write { db in
        try db.execute(
            sql: "INSERT INTO notes (body, created_at, updated_at) VALUES (?, ?, ?)",
            arguments: ["заметка", Date(), Date()]
        )
        let noteID = db.lastInsertedRowID
        try db.execute(
            sql: "INSERT INTO search_index (owner_kind, owner_id, title, body) VALUES (?, ?, ?, ?)",
            arguments: ["note", noteID, "", "заметка"]
        )
        try db.execute(sql: "DELETE FROM notes WHERE id = ?", arguments: [noteID])
    }

    let orphaned = try database.queue.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_index WHERE owner_kind = 'note'")
    }
    #expect(orphaned == 1)
}

