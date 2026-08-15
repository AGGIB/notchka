import Testing
import Foundation
import GRDB
@testable import NotchStore

private func migratedDatabase() throws -> NotchDatabase {
    let database = try NotchDatabase(location: .temporary())
    try database.migrate()
    return database
}

@Test("all four tables exist after migrations")
func allTablesExist() throws {
    let database = try migratedDatabase()
    try database.queue.read { db in
        // The read is pulled out into a let instead of `#expect(try ...)`
        // directly in the argument: the Swift 6.3 compiler doesn't consider
        // try inside #expect handled when #expect is called inside a
        // closure — the build fails with "errors thrown from here are not
        // handled" (compiler bug swiftlang/swift#78395). This is a
        // workaround for the compiler bug, not a style requirement — the
        // same trick is repeated below everywhere this pattern occurs.
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

// Deliberately not named `migrationIsIdempotent`: a function with that
// name already exists in NotchDatabaseTests in the same test target, and
// a second one with the same name would be a redeclaration error, not two
// tests.
@Test("re-running migration doesn't lose already saved rows")
func migrationPreservesExistingRows() throws {
    let location = StoreLocation.temporary()
    let first = try NotchDatabase(location: location)
    try first.migrate()
    try first.queue.write { db in
        try db.execute(sql: "INSERT INTO notes (body, created_at, updated_at) VALUES (?, ?, ?)",
                       arguments: ["save me", Date(), Date()])
    }

    let second = try NotchDatabase(location: location)
    try second.migrate()
    let count = try second.queue.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notes") ?? 0
    }
    #expect(count == 1)
}

@Test("pin order is stored and uniqueness isn't required — duplicate order values are allowed")
func snippetOrderColumnExists() throws {
    let database = try migratedDatabase()
    try database.queue.write { db in
        for order in [1, 1, 2] {
            try db.execute(
                sql: "INSERT INTO snippets (label, value, sort_order, is_sensitive, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
                arguments: ["label", "value", order, false, Date(), Date()]
            )
        }
        let snippetCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM snippets")
        #expect(snippetCount == 3)
    }
}

/// Tests the actual design decision, not just table existence: the index
/// isn't linked to owners via foreign keys, so deleting a record does NOT
/// take its index row down with it. Cleanup is the repository's
/// responsibility, and that's exactly what makes a deleted note stop
/// showing up in search.
///
/// The previous version of this test only checked `tableExists` — exactly
/// the same thing `allTablesExist` checks above — and would have passed
/// under any schema, including one with cascading deletes, which is
/// precisely what we don't want.
///
/// The index table itself is a plain FTS5 table, NOT contentless: plan 3
/// chose this deliberately, because you can't delete from a contentless
/// table with a plain `DELETE ... WHERE`, which is exactly how it gets
/// cleaned up. Do not "optimize" this back.
@Test("deleting the owner doesn't take the index row with it — the repository cleans it up")
func searchIndexSurvivesOwnerDeletion() throws {
    let database = try migratedDatabase()
    try database.queue.write { db in
        try db.execute(
            sql: "INSERT INTO notes (body, created_at, updated_at) VALUES (?, ?, ?)",
            arguments: ["note", Date(), Date()]
        )
        let noteID = db.lastInsertedRowID
        try db.execute(
            sql: "INSERT INTO search_index (owner_kind, owner_id, title, body) VALUES (?, ?, ?, ?)",
            arguments: ["note", noteID, "", "note"]
        )
        try db.execute(sql: "DELETE FROM notes WHERE id = ?", arguments: [noteID])
    }

    let orphaned = try database.queue.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_index WHERE owner_kind = 'note'")
    }
    #expect(orphaned == 1)
}

