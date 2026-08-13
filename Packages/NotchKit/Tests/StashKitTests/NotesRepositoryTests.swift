import Testing
import Foundation
import GRDB
import NotchStore
@testable import StashKit

private let t0 = Date(timeIntervalSince1970: 1_000_000)

private func makeRepository() throws -> NotesRepository {
    let database = try NotchDatabase(location: .temporary())
    try database.migrate()
    return NotesRepository(database: database)
}

@Test("заметка сохраняется и читается")
func noteRoundTrips() throws {
    let repository = try makeRepository()
    try repository.add("созвон в 15:00", at: t0)
    #expect(try repository.all().map(\.body) == ["созвон в 15:00"])
}

@Test("свежие заметки идут первыми")
func newestFirst() throws {
    let repository = try makeRepository()
    try repository.add("первая", at: t0)
    try repository.add("вторая", at: t0.addingTimeInterval(60))
    #expect(try repository.all().map(\.body) == ["вторая", "первая"])
}

@Test("правка меняет текст и время изменения, но не время создания")
func updateKeepsCreationTime() throws {
    let repository = try makeRepository()
    try repository.add("черновик", at: t0)
    let note = try #require(try repository.all().first)
    try repository.update(id: note.id!, body: "готово", at: t0.addingTimeInterval(600))

    let updated = try #require(try repository.all().first)
    #expect(updated.body == "готово")
    #expect(updated.createdAt == t0)
    #expect(updated.updatedAt == t0.addingTimeInterval(600))
}

@Test("пустая заметка не сохраняется")
func emptyNoteIsRejected() throws {
    let repository = try makeRepository()
    try repository.add("   \n  ", at: t0)
    #expect(try repository.all().isEmpty)
}

@Test("удаление убирает заметку")
func deleteRemovesNote() throws {
    let repository = try makeRepository()
    try repository.add("удалить", at: t0)
    let note = try #require(try repository.all().first)
    try repository.delete(id: note.id!)
    #expect(try repository.all().isEmpty)
}

@Test("заметка попадает в поисковый индекс и уходит из него при удалении")
func noteIsIndexed() throws {
    let database = try NotchDatabase(location: .temporary())
    try database.migrate()
    let repository = NotesRepository(database: database)
    try repository.add("уникальноеслово", at: t0)

    let indexed = try database.queue.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_index WHERE owner_kind = 'note'") ?? 0
    }
    #expect(indexed == 1)

    let note = try #require(try repository.all().first)
    try repository.delete(id: note.id!)
    let afterDelete = try database.queue.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_index WHERE owner_kind = 'note'") ?? 0
    }
    #expect(afterDelete == 0)
}

/// Правка обязана доезжать до индекса, а не только до самой заметки.
///
/// Без этого поиск продолжал бы находить заметку по старому тексту и не
/// находил бы по новому — молча, потому что и запись, и поиск по
/// отдельности работают. Тест дописан после ревью: бриф задачи давал
/// проверки только на создание и удаление, а обновление осталось без неё.
@Test("правка заметки обновляет и поисковый индекс")
func updateRefreshesSearchIndex() throws {
    let database = try NotchDatabase(location: .temporary())
    try database.migrate()
    let repository = NotesRepository(database: database)
    try repository.add("первоначальныйтекст", at: t0)
    let note = try #require(try repository.all().first)

    try repository.update(id: try #require(note.id), body: "исправленныйтекст", at: t0.addingTimeInterval(60))

    let indexed = try database.queue.read { db in
        try String.fetchOne(
            db,
            sql: "SELECT body FROM search_index WHERE owner_kind = 'note' AND owner_id = ?",
            arguments: [note.id]
        )
    }
    #expect(indexed == "исправленныйтекст")
}
