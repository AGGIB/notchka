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

@Test("a note round-trips through save and read")
func noteRoundTrips() throws {
    let repository = try makeRepository()
    try repository.add("call at 3pm", at: t0)
    #expect(try repository.all().map(\.body) == ["call at 3pm"])
}

@Test("newest notes come first")
func newestFirst() throws {
    let repository = try makeRepository()
    try repository.add("first", at: t0)
    try repository.add("second", at: t0.addingTimeInterval(60))
    #expect(try repository.all().map(\.body) == ["second", "first"])
}

@Test("editing changes the text and update time, not the creation time")
func updateKeepsCreationTime() throws {
    let repository = try makeRepository()
    try repository.add("draft", at: t0)
    let note = try #require(try repository.all().first)
    try repository.update(id: note.id!, body: "done", at: t0.addingTimeInterval(600))

    let updated = try #require(try repository.all().first)
    #expect(updated.body == "done")
    #expect(updated.createdAt == t0)
    #expect(updated.updatedAt == t0.addingTimeInterval(600))
}

/// Throws instead of silently doing nothing: calling code needs to be able
/// to tell "saved" from "rejected" apart, so it doesn't, for example, clear
/// the input field after an empty ⌘↩.
@Test("an empty note is not saved — throws EmptyBodyError")
func emptyNoteIsRejected() throws {
    let repository = try makeRepository()
    #expect(throws: NotesRepository.EmptyBodyError.self) {
        try repository.add("   \n  ", at: t0)
    }
    #expect(try repository.all().isEmpty)
}

/// Same rejection, the same way, as on creation — throw, not a silent
/// fallback to the old content.
@Test("an empty edit is not applied — throws EmptyBodyError")
func emptyUpdateIsRejected() throws {
    let repository = try makeRepository()
    try repository.add("original text", at: t0)
    let note = try #require(try repository.all().first)

    #expect(throws: NotesRepository.EmptyBodyError.self) {
        try repository.update(id: try #require(note.id), body: "   ", at: t0.addingTimeInterval(60))
    }
    #expect(try repository.all().first?.body == "original text")
}

@Test("deleting removes the note")
func deleteRemovesNote() throws {
    let repository = try makeRepository()
    try repository.add("delete me", at: t0)
    let note = try #require(try repository.all().first)
    try repository.delete(id: note.id!)
    #expect(try repository.all().isEmpty)
}

@Test("a note lands in the search index and leaves it on delete")
func noteIsIndexed() throws {
    let database = try NotchDatabase(location: .temporary())
    try database.migrate()
    let repository = NotesRepository(database: database)
    try repository.add("uniqueword", at: t0)

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

/// An edit must reach the index, not just the note itself.
///
/// Without this, search would keep finding the note by its old text and
/// fail to find it by the new one — silently, because both the write path
/// and the search path work fine on their own. Test added after review:
/// the task brief only called for create/delete coverage, leaving updates
/// untested.
@Test("editing a note refreshes the search index too")
func updateRefreshesSearchIndex() throws {
    let database = try NotchDatabase(location: .temporary())
    try database.migrate()
    let repository = NotesRepository(database: database)
    try repository.add("originaltext", at: t0)
    let note = try #require(try repository.all().first)

    try repository.update(id: try #require(note.id), body: "correctedtext", at: t0.addingTimeInterval(60))

    let indexed = try database.queue.read { db in
        try String.fetchOne(
            db,
            sql: "SELECT body FROM search_index WHERE owner_kind = 'note' AND owner_id = ?",
            arguments: [note.id]
        )
    }
    #expect(indexed == "correctedtext")
}
