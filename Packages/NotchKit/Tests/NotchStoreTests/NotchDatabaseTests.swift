import Testing
import Foundation
import GRDB
@testable import NotchStore

/// Checks of the schema itself, not the repository built on top of it.
///
/// They exist because two properties of the schema rest on decisions that
/// are easy to revert by accident, and reverting them won't produce a build
/// error or a runtime exception. A broken migration costs more than an
/// ordinary bug: a user's already-created database won't carry over.

private func makeDatabase() throws -> NotchDatabase {
    let database = try NotchDatabase(location: .temporary())
    try database.migrate()
    return database
}

@Test("re-running the migration does not break an already-migrated database")
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

/// The main protection this file provides.
///
/// The full-text table is created as a regular table, not contentless —
/// intentionally. Contentless looks cheaper and is easy to "optimize" back
/// to, but it doesn't store column values: reads would come back as empty
/// strings, and deleting by owner would stop finding anything at all. And
/// silently — DELETE on a contentless table doesn't fail, it just deletes
/// nothing, and text the user deleted from history would keep sitting
/// in the index.
@Test("index column values read back correctly — table is not contentless")
func searchIndexStoresItsColumns() throws {
    let database = try makeDatabase()
    try database.queue.write { db in
        try db.execute(
            sql: "INSERT INTO search_index (owner_kind, owner_id, title, body) VALUES (?, ?, ?, ?)",
            arguments: ["clipboard", 1, "TextEdit", "hello world"]
        )
    }

    let owner = try database.queue.read { db in
        try String.fetchOne(db, sql: "SELECT owner_kind FROM search_index")
    }
    #expect(owner == "clipboard")
}

@Test("deleting by owner removes exactly its own index row")
func searchIndexRowsAreDeletableByOwner() throws {
    let database = try makeDatabase()
    try database.queue.write { db in
        for id in 1...2 {
            try db.execute(
                sql: "INSERT INTO search_index (owner_kind, owner_id, title, body) VALUES (?, ?, ?, ?)",
                arguments: ["clipboard", id, "source", "body \(id)"]
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

@Test("text remains findable via full-text search")
func searchIndexIsQueryable() throws {
    let database = try makeDatabase()
    try database.queue.write { db in
        try db.execute(
            sql: "INSERT INTO search_index (owner_kind, owner_id, title, body) VALUES (?, ?, ?, ?)",
            arguments: ["clipboard", 7, "TextEdit", "payment receipt"]
        )
    }

    let found = try database.queue.read { db in
        try Int.fetchOne(db, sql: "SELECT owner_id FROM search_index WHERE search_index MATCH 'receipt'")
    }
    #expect(found == 7)
}

/// Deduplication depends on this uniqueness: a re-copied text is supposed
/// to bump the existing record, not create a second one.
@Test("a duplicate content_hash is rejected by the database itself")
func contentHashIsUnique() throws {
    let database = try makeDatabase()
    let insert = """
        INSERT INTO clipboard_items
            (kind, content_hash, text_body, byte_size, created_at, last_used_at, is_pinned)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """
    let now = Date(timeIntervalSince1970: 1_000_000)

    try database.queue.write { db in
        try db.execute(sql: insert, arguments: ["text", "identical", "first", 6, now, now, false])
    }

    #expect(throws: (any Error).self) {
        try database.queue.write { db in
            try db.execute(sql: insert, arguments: ["text", "identical", "second", 6, now, now, false])
        }
    }
}
