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

@Test("умолчания совпадают со спекой")
func defaultsMatchSpec() {
    #expect(RetentionPolicy.default.maxItems == 500)
    #expect(RetentionPolicy.default.maxAge == 30 * 24 * 3600)
    #expect(RetentionPolicy.default.maxBlobBytes == 2 * 1024 * 1024 * 1024)
}

@Test("лишние по количеству удаляются, начиная с самых старых")
func excessItemsAreDropped() throws {
    let repository = try makeRepository()
    for index in 0..<10 {
        try repository.saveText("\(index)", source: nil, at: t0.addingTimeInterval(Double(index)))
    }
    let removed = try repository.prune(
        policy: RetentionPolicy(maxItems: 4, maxAge: .infinity, maxBlobBytes: .max),
        now: t0.addingTimeInterval(100)
    )
    #expect(removed == 6)
    #expect(try repository.recent(limit: 100).map(\.textBody) == ["9", "8", "7", "6"])
}

@Test("устаревшие по времени удаляются")
func staleItemsAreDropped() throws {
    let repository = try makeRepository()
    try repository.saveText("древнее", source: nil, at: t0)
    try repository.saveText("свежее", source: nil, at: t0.addingTimeInterval(86_400))
    let removed = try repository.prune(
        policy: RetentionPolicy(maxItems: .max, maxAge: 3600, maxBlobBytes: .max),
        now: t0.addingTimeInterval(86_400 + 60)
    )
    #expect(removed == 1)
    #expect(try repository.recent(limit: 10).map(\.textBody) == ["свежее"])
}

@Test("закреплённое не вытесняется ни по количеству, ни по возрасту")
func pinnedSurvivesEverything() throws {
    let repository = try makeRepository()
    try repository.saveText("закреплённое", source: nil, at: t0)
    let pinned = try #require(try repository.recent(limit: 1).first)
    try repository.setPinned(id: pinned.id!, true)
    for index in 0..<20 {
        try repository.saveText("шум \(index)", source: nil, at: t0.addingTimeInterval(Double(index + 1)))
    }

    _ = try repository.prune(
        policy: RetentionPolicy(maxItems: 3, maxAge: 1, maxBlobBytes: .max),
        now: t0.addingTimeInterval(10_000)
    )
    let survivors = try repository.recent(limit: 100).map(\.textBody)
    #expect(survivors.contains("закреплённое"))
    // Без этой строки тест проходит и при полностью нерабочем вытеснении:
    // закреплённое, разумеется, останется, если не удалено вообще ничего.
    // Проверяется не «эта запись цела», а «она цела при работающей чистке».
    #expect(survivors.contains("шум 0") == false)
}

/// Закреплённое исключено из бюджета объёма целиком — не только защищено от
/// удаления, но и не считается занимающим место. Решение сознательное:
/// закрепление это явное «храни», а бюджет ограничивает то, что копится
/// само. Тест закрепляет решение, чтобы оно не отменилось по недосмотру.
@Test("блобы закреплённых записей не входят в бюджет объёма")
func pinnedBlobsAreOutsideTheBudget() throws {
    let repository = try makeRepository()
    try repository.saveImage(Data(repeating: 1, count: 4096), source: nil, at: t0)
    let pinned = try #require(try repository.recent(limit: 1).first)
    try repository.setPinned(id: pinned.id!, true)

    let removed = try repository.prune(
        policy: RetentionPolicy(maxItems: .max, maxAge: .infinity, maxBlobBytes: 1024),
        now: t0.addingTimeInterval(100)
    )
    #expect(removed == 0)
    #expect(try repository.blobBytes() == 4096)
}

/// Вытеснение выбирает кандидатов одним запросом, а удаляет их по одному
/// отдельными транзакциями — иначе GRDB упал бы на вложенной транзакции.
/// Между выбором и удалением конкретной записи её успевают закрепить, и
/// проверка внутри транзакции удаления — единственное, что стоит между
/// такой записью и её потерей. Саму гонку в тесте не воспроизвести,
/// поэтому проверяется защита напрямую.
@Test("защищённое удаление щадит закреплённое, прямое — нет")
func guardedDeleteSparesPinnedButDirectDoesNot() throws {
    let repository = try makeRepository()
    try repository.saveText("закреплено позже", source: nil, at: t0)
    let item = try #require(try repository.recent(limit: 1).first)
    let id = try #require(item.id)
    try repository.setPinned(id: id, true)

    _ = try repository.performDelete(id: id, sparingPinned: true)
    #expect(try repository.recent(limit: 10).count == 1)

    // Прямое распоряжение пользователя закрепление не останавливает:
    // закрепил — не значит «удалить нельзя», значит «само не удалится».
    try repository.delete(id: id)
    #expect(try repository.recent(limit: 10).isEmpty)
}

@Test("превышение объёма блобов вытесняет самые старые с блобами")
func blobBudgetIsEnforced() throws {
    let repository = try makeRepository()
    for index in 0..<5 {
        try repository.saveImage(
            Data(repeating: UInt8(index), count: 1024),
            source: nil, at: t0.addingTimeInterval(Double(index))
        )
    }
    _ = try repository.prune(
        policy: RetentionPolicy(maxItems: .max, maxAge: .infinity, maxBlobBytes: 2048),
        now: t0.addingTimeInterval(100)
    )
    #expect(try repository.blobBytes() <= 2048)
}

@Test("чистка на пустой базе безопасна")
func pruningEmptyIsSafe() throws {
    let repository = try makeRepository()
    #expect(try repository.prune(policy: .default, now: t0) == 0)
}
