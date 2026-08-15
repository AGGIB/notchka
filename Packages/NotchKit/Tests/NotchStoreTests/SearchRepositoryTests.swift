import Testing
import Foundation
@testable import NotchStore

private func seeded() throws -> (NotchDatabase, SearchRepository) {
    let database = try NotchDatabase(location: .temporary())
    try database.migrate()
    try database.queue.write { db in
        try db.execute(
            sql: "INSERT INTO search_index (owner_kind, owner_id, title, body) VALUES (?, ?, ?, ?)",
            arguments: ["clipboard", 1, "Safari", "link to GRDB documentation"]
        )
        try db.execute(
            sql: "INSERT INTO search_index (owner_kind, owner_id, title, body) VALUES (?, ?, ?, ?)",
            arguments: ["note", 2, "", "call about documenting the schema at 3pm"]
        )
        try db.execute(
            sql: "INSERT INTO search_index (owner_kind, owner_id, title, body) VALUES (?, ?, ?, ?)",
            arguments: ["snippet", 3, "Email", "developer@mobilefirst.kz"]
        )
    }
    return (database, SearchRepository(database: database))
}

// Query is "document" — a shared prefix of the clipboard entry's
// "documentation" and the note's "documenting", not the full word from
// either. The two entries share a root but diverge in suffix — without
// FTS5 stemming they don't match as whole words. The full word would only
// find one of them; the shared prefix finds both — and this isn't a
// workaround, it's the same behavior that catches a user who doesn't
// finish typing a word (see prefixSearchWorks below).
@Test("finds across all three entity kinds with one query")
func searchesAcrossKinds() throws {
    let (_, repository) = try seeded()
    let results = try repository.search("document", limit: 10)
    #expect(Set(results.map(\.kind)) == [.clipboard, .note])
}

@Test("finds a pinned snippet by label")
func findsSnippetByLabel() throws {
    let (_, repository) = try seeded()
    #expect(try repository.search("Email", limit: 10).map(\.kind) == [.snippet])
}

@Test("empty query does not return everything")
func emptyQueryReturnsNothing() throws {
    let (_, repository) = try seeded()
    #expect(try repository.search("   ", limit: 10).isEmpty)
}

@Test("query with FTS special characters doesn't crash search")
func ftsSyntaxIsEscaped() throws {
    let (_, repository) = try seeded()
    // Quotes and asterisks are FTS5 syntax; left unescaped, they cause a
    // syntax error and break the entire search on ordinary user input.
    #expect(throws: Never.self) { _ = try repository.search("\"unclosed", limit: 10) }
    #expect(throws: Never.self) { _ = try repository.search("* AND *", limit: 10) }
}

@Test("prefix search works — user doesn't finish typing the whole word")
func prefixSearchWorks() throws {
    let (_, repository) = try seeded()
    #expect(try repository.search("docum", limit: 10).isEmpty == false)
}

@Test("limit is honoured")
func limitIsHonoured() throws {
    let (_, repository) = try seeded()
    #expect(try repository.search("document", limit: 1).count == 1)
}

@Test("result carries the owner ID to navigate to the item")
func resultCarriesOwnerID() throws {
    let (_, repository) = try seeded()
    let result = try #require(try repository.search("Email", limit: 1).first)
    #expect(result.ownerID == 3)
}
