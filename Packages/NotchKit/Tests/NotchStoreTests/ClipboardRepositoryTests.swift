import Testing
import Foundation
import GRDB
@testable import NotchStore

private func makeRepository() throws -> ClipboardRepository {
    let location = StoreLocation.temporary()
    let database = try NotchDatabase(location: location)
    try database.migrate()
    return ClipboardRepository(database: database, blobs: BlobStore(location: location))
}

private let t0 = Date(timeIntervalSince1970: 1_000_000)

@Test("saved text reads back")
func textRoundTrips() throws {
    let repository = try makeRepository()
    try repository.saveText("hello", source: ("com.apple.TextEdit", "TextEdit"), at: t0)
    let items = try repository.recent(limit: 10)
    #expect(items.count == 1)
    #expect(items[0].textBody == "hello")
    #expect(items[0].sourceAppName == "TextEdit")
}

@Test("a repeat promotes the entry to the top instead of creating a duplicate")
func duplicateIsPromotedNotDuplicated() throws {
    let repository = try makeRepository()
    try repository.saveText("one", source: ("com.apple.TextEdit", "TextEdit"), at: t0)
    try repository.saveText("two", source: ("com.apple.TextEdit", "TextEdit"), at: t0.addingTimeInterval(1))
    try repository.saveText("one", source: ("com.apple.TextEdit", "TextEdit"), at: t0.addingTimeInterval(2))

    let items = try repository.recent(limit: 10)
    #expect(items.count == 2)
    #expect(items[0].textBody == "one")
}

@Test("the feed is sorted by last used")
func recentIsSortedByLastUsed() throws {
    let repository = try makeRepository()
    try repository.saveText("old", source: nil, at: t0)
    try repository.saveText("new", source: nil, at: t0.addingTimeInterval(60))
    #expect(try repository.recent(limit: 10).map(\.textBody) == ["new", "old"])
}

@Test("an image is stored as a blob, not as text")
func imageIsStoredAsBlob() throws {
    let repository = try makeRepository()
    let bytes = Data(repeating: 3, count: 512)
    try repository.saveImage(bytes, source: nil, at: t0)
    let item = try #require(try repository.recent(limit: 1).first)
    #expect(item.kind == .image)
    #expect(item.blobPath != nil)
    #expect(item.byteSize == 512)
    #expect(try repository.data(for: item) == bytes)
}

@Test("an item pasted from history moves to the top of the feed")
func touchPromotesItem() throws {
    let repository = try makeRepository()
    try repository.saveText("old", source: nil, at: t0)
    try repository.saveText("new", source: nil, at: t0.addingTimeInterval(60))
    let old = try #require(try repository.recent(limit: 10).last)

    try repository.touch(id: try #require(old.id), at: t0.addingTimeInterval(120))
    #expect(try repository.recent(limit: 10).map(\.textBody) == ["old", "new"])
}

@Test("a deleted entry disappears from the full-text index too")
func deleteClearsSearchIndex() throws {
    let location = StoreLocation.temporary()
    let database = try NotchDatabase(location: location)
    try database.migrate()
    let repository = ClipboardRepository(database: database, blobs: BlobStore(location: location))

    func indexedRows() throws -> Int? {
        try database.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM search_index")
        }
    }

    try repository.saveText("payment receipt", source: nil, at: t0)
    let item = try #require(try repository.recent(limit: 1).first)
    #expect(try indexedRows() == 1)

    try repository.delete(id: try #require(item.id))
    // The index is a second copy of the text on disk. A user who deletes an entry
    // from history is entitled to expect it disappeared everywhere, not
    // left sitting in the search index.
    #expect(try indexedRows() == 0)
}

@Test("pinning persists")
func pinningPersists() throws {
    let repository = try makeRepository()
    try repository.saveText("important", source: nil, at: t0)
    let item = try #require(try repository.recent(limit: 1).first)
    try repository.setPinned(id: item.id!, true)
    #expect(try repository.recent(limit: 1).first?.isPinned == true)
}

@Test("deletion removes both the entry and its blob")
func deleteRemovesBlobToo() throws {
    let repository = try makeRepository()
    try repository.saveImage(Data(repeating: 9, count: 256), source: nil, at: t0)
    let item = try #require(try repository.recent(limit: 1).first)
    try repository.delete(id: item.id!)
    #expect(try repository.recent(limit: 10).isEmpty)
    #expect(try repository.blobBytes() == 0)
}
