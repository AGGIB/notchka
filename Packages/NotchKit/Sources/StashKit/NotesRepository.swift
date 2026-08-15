import Foundation
import GRDB
import NotchStore

/// Access to the quick notes repository.
public struct NotesRepository: Sendable {
    private let database: NotchDatabase

    // Owner kind in the shared search_index. A constant, not a literal in three
    // places: a typo in one of them silently breaks search, and the compiler
    // won't catch it — only a runtime string mismatch.
    private static let ownerKind = "note"

    public init(database: NotchDatabase) {
        self.database = database
    }

    /// The note wasn't saved because nothing was left of it after trimming
    /// whitespace and newlines.
    public struct EmptyBodyError: Error, Sendable {}

    /// Saves a note. After trimming whitespace and newlines, an empty
    /// note is not saved but throws instead — otherwise a stray ⌘↩ with no
    /// text would silently do nothing, and the caller couldn't tell
    /// "saved" from "rejected" to, say, avoid clearing the input field.
    ///
    /// The search index row is written in the same transaction as the
    /// note itself: without this, a failure between the two inserts could
    /// leave a saved note without an index entry, and search wouldn't find it.
    public func add(_ body: String, at now: Date = Date()) throws {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EmptyBodyError() }

        try database.queue.write { db in
            var note = Note(id: nil, body: trimmed, createdAt: now, updatedAt: now)
            try note.insert(db)
            guard let id = note.id else {
                // GRDB always sets id in didInsert after a successful
                // auto-increment insert — this is unreachable in practice.
                // But throw here, not return: return would mean COMMITting
                // the note without an index row, and the diverged state
                // would remain in the database forever, not just for the call's duration.
                struct MissingInsertedID: Error, Sendable {}
                throw MissingInsertedID()
            }
            try db.execute(
                sql: "INSERT INTO search_index (owner_kind, owner_id, title, body) VALUES (?, ?, ?, ?)",
                arguments: [Self.ownerKind, id, "", trimmed]
            )
        }
    }

    /// All notes, newest first. Sorted by creation time,
    /// not modification time: editing shouldn't move a note in the feed.
    public func all() throws -> [Note] {
        try database.queue.read { db in
            try Note.order(Column("created_at").desc).fetchAll(db)
        }
    }

    /// Updates the text and the modification time. The creation time is not
    /// touched: otherwise fixing a typo would move the note to the top of
    /// the feed, and the user expects it to stay where it was.
    ///
    /// An edit that's empty after trimming whitespace is rejected by the
    /// same rule and the same way as an empty creation — throw, not a
    /// silent return, otherwise a user who erased all the text would have
    /// no way to know the edit didn't apply, and the old content would
    /// just silently stay in place.
    ///
    /// The index row is updated in the same transaction as the note —
    /// same as on creation and deletion, so search doesn't fall behind
    /// the note's text if there's a failure between the two operations.
    public func update(id: Int64, body: String, at now: Date = Date()) throws {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EmptyBodyError() }

        try database.queue.write { db in
            try db.execute(
                sql: "UPDATE notes SET body = ?, updated_at = ? WHERE id = ?",
                arguments: [trimmed, now, id]
            )
            try db.execute(
                sql: "UPDATE search_index SET body = ? WHERE owner_kind = ? AND owner_id = ?",
                arguments: [trimmed, Self.ownerKind, id]
            )
        }
    }

    /// Deletes a note together with its index row in a single transaction —
    /// otherwise, after a failure between operations, search could find an
    /// already-deleted note.
    public func delete(id: Int64) throws {
        try database.queue.write { db in
            try db.execute(sql: "DELETE FROM notes WHERE id = ?", arguments: [id])
            try db.execute(
                sql: "DELETE FROM search_index WHERE owner_kind = ? AND owner_id = ?",
                arguments: [Self.ownerKind, id]
            )
        }
    }
}
