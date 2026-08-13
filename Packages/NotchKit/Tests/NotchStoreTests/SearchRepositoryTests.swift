import Testing
import Foundation
@testable import NotchStore

private func seeded() throws -> (NotchDatabase, SearchRepository) {
    let database = try NotchDatabase(location: .temporary())
    try database.migrate()
    try database.queue.write { db in
        try db.execute(
            sql: "INSERT INTO search_index (owner_kind, owner_id, title, body) VALUES (?, ?, ?, ?)",
            arguments: ["clipboard", 1, "Safari", "ссылка на документацию GRDB"]
        )
        try db.execute(
            sql: "INSERT INTO search_index (owner_kind, owner_id, title, body) VALUES (?, ?, ?, ?)",
            arguments: ["note", 2, "", "созвон по документации в 15:00"]
        )
        try db.execute(
            sql: "INSERT INTO search_index (owner_kind, owner_id, title, body) VALUES (?, ?, ?, ?)",
            arguments: ["snippet", 3, "Почта", "developer@mobilefirst.kz"]
        )
    }
    return (database, SearchRepository(database: database))
}

// Запрос — "документаци", без последней буквы, а не полное слово из текста
// заметки ("документации"). У заметки и записи буфера общий корень, но
// разные падежи ("документации" / "документацию") — без стемминга FTS5 они
// не совпадают как целые слова, а расходятся ровно в последней букве.
// Полное слово нашло бы только заметку; общий префикс находит оба — и это
// не обход, а то же самое поведение, что ловит пользователя, печатающего
// слово не до конца (см. prefixSearchWorks ниже).
@Test("находит по всем трём сущностям одним запросом")
func searchesAcrossKinds() throws {
    let (_, repository) = try seeded()
    let results = try repository.search("документаци", limit: 10)
    #expect(Set(results.map(\.kind)) == [.clipboard, .note])
}

@Test("находит пин по метке")
func findsSnippetByLabel() throws {
    let (_, repository) = try seeded()
    #expect(try repository.search("Почта", limit: 10).map(\.kind) == [.snippet])
}

@Test("пустой запрос не возвращает всё подряд")
func emptyQueryReturnsNothing() throws {
    let (_, repository) = try seeded()
    #expect(try repository.search("   ", limit: 10).isEmpty)
}

@Test("запрос со спецсимволами FTS не роняет поиск")
func ftsSyntaxIsEscaped() throws {
    let (_, repository) = try seeded()
    // Кавычки и звёздочки — синтаксис FTS5; необработанные, они дают
    // syntax error и роняют весь поиск на обычном пользовательском вводе.
    #expect(throws: Never.self) { _ = try repository.search("\"незакрытая", limit: 10) }
    #expect(throws: Never.self) { _ = try repository.search("* AND *", limit: 10) }
}

@Test("поиск по префиксу работает — пользователь не дописывает слово целиком")
func prefixSearchWorks() throws {
    let (_, repository) = try seeded()
    #expect(try repository.search("докум", limit: 10).isEmpty == false)
}

@Test("лимит соблюдается")
func limitIsHonoured() throws {
    let (_, repository) = try seeded()
    #expect(try repository.search("документаци", limit: 1).count == 1)
}

@Test("результат несёт идентификатор владельца для перехода к элементу")
func resultCarriesOwnerID() throws {
    let (_, repository) = try seeded()
    let result = try #require(try repository.search("Почта", limit: 1).first)
    #expect(result.ownerID == 3)
}
