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

@Test("сохранённый текст читается обратно")
func textRoundTrips() throws {
    let repository = try makeRepository()
    try repository.saveText("привет", source: ("com.apple.TextEdit", "TextEdit"), at: t0)
    let items = try repository.recent(limit: 10)
    #expect(items.count == 1)
    #expect(items[0].textBody == "привет")
    #expect(items[0].sourceAppName == "TextEdit")
}

@Test("повтор поднимает запись наверх, а не создаёт вторую")
func duplicateIsPromotedNotDuplicated() throws {
    let repository = try makeRepository()
    try repository.saveText("один", source: ("com.apple.TextEdit", "TextEdit"), at: t0)
    try repository.saveText("два", source: ("com.apple.TextEdit", "TextEdit"), at: t0.addingTimeInterval(1))
    try repository.saveText("один", source: ("com.apple.TextEdit", "TextEdit"), at: t0.addingTimeInterval(2))

    let items = try repository.recent(limit: 10)
    #expect(items.count == 2)
    #expect(items[0].textBody == "один")
}

@Test("лента отсортирована по последнему использованию")
func recentIsSortedByLastUsed() throws {
    let repository = try makeRepository()
    try repository.saveText("старое", source: nil, at: t0)
    try repository.saveText("новое", source: nil, at: t0.addingTimeInterval(60))
    #expect(try repository.recent(limit: 10).map(\.textBody) == ["новое", "старое"])
}

@Test("картинка сохраняется блобом, а не текстом")
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

@Test("вставленный из истории элемент поднимается наверх ленты")
func touchPromotesItem() throws {
    let repository = try makeRepository()
    try repository.saveText("старое", source: nil, at: t0)
    try repository.saveText("новое", source: nil, at: t0.addingTimeInterval(60))
    let old = try #require(try repository.recent(limit: 10).last)

    try repository.touch(id: try #require(old.id), at: t0.addingTimeInterval(120))
    #expect(try repository.recent(limit: 10).map(\.textBody) == ["старое", "новое"])
}

@Test("удалённая запись исчезает и из полнотекстового индекса")
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

    try repository.saveText("квитанция об оплате", source: nil, at: t0)
    let item = try #require(try repository.recent(limit: 1).first)
    #expect(try indexedRows() == 1)

    try repository.delete(id: try #require(item.id))
    // Индекс — вторая копия текста на диске. Пользователь, удаливший запись
    // из истории, вправе рассчитывать, что она исчезла отовсюду, а не
    // осталась лежать в поисковом индексе.
    #expect(try indexedRows() == 0)
}

@Test("закрепление сохраняется")
func pinningPersists() throws {
    let repository = try makeRepository()
    try repository.saveText("важное", source: nil, at: t0)
    let item = try #require(try repository.recent(limit: 1).first)
    try repository.setPinned(id: item.id!, true)
    #expect(try repository.recent(limit: 1).first?.isPinned == true)
}

@Test("удаление убирает и запись, и её блоб")
func deleteRemovesBlobToo() throws {
    let repository = try makeRepository()
    try repository.saveImage(Data(repeating: 9, count: 256), source: nil, at: t0)
    let item = try #require(try repository.recent(limit: 1).first)
    try repository.delete(id: item.id!)
    #expect(try repository.recent(limit: 10).isEmpty)
    #expect(try repository.blobBytes() == 0)
}
