import Testing
import Foundation
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
