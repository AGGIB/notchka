import Testing
import Foundation
import NotchStore
@testable import StashKit

private let t0 = Date(timeIntervalSince1970: 1_000_000)

private func makeRepository() throws -> SnippetsRepository {
    let database = try NotchDatabase(location: .temporary())
    try database.migrate()
    return SnippetsRepository(database: database)
}

@Test("пин сохраняется со всеми полями")
func snippetRoundTrips() throws {
    let repository = try makeRepository()
    try repository.add(label: "Почта", value: "developer@mobilefirst.kz",
                       icon: "envelope", colorHex: "#FF2D95", isSensitive: false, at: t0)
    let pin = try #require(try repository.all().first)
    #expect(pin.label == "Почта")
    #expect(pin.value == "developer@mobilefirst.kz")
    #expect(pin.icon == "envelope")
    #expect(pin.isSensitive == false)
}

@Test("пины отдаются в заданном порядке")
func orderIsPreserved() throws {
    let repository = try makeRepository()
    try repository.add(label: "третий", value: "3", icon: nil, colorHex: nil, isSensitive: false, at: t0)
    try repository.add(label: "первый", value: "1", icon: nil, colorHex: nil, isSensitive: false, at: t0)
    let pins = try repository.all()
    try repository.move(id: pins[1].id!, to: 0)
    #expect(try repository.all().map(\.label) == ["первый", "третий"])
}

@Test("перемещение в конец работает")
func moveToEnd() throws {
    let repository = try makeRepository()
    for label in ["a", "b", "c"] {
        try repository.add(label: label, value: label, icon: nil, colorHex: nil, isSensitive: false, at: t0)
    }
    let first = try #require(try repository.all().first)
    try repository.move(id: first.id!, to: 2)
    #expect(try repository.all().map(\.label) == ["b", "c", "a"])
}

@Test("чувствительное значение маскируется точками")
func sensitiveValueIsMasked() {
    #expect(Snippet.masked("123456789012") == "••• ••• •••")
}

@Test("маскировка не зависит от длины — по ней нельзя угадать значение")
func maskDoesNotLeakLength() {
    #expect(Snippet.masked("12") == Snippet.masked("1234567890123456"))
}

@Test("пустая метка не сохраняется")
func emptyLabelIsRejected() throws {
    let repository = try makeRepository()
    try repository.add(label: "  ", value: "значение", icon: nil, colorHex: nil, isSensitive: false, at: t0)
    #expect(try repository.all().isEmpty)
}

@Test("метка попадает в индекс, а чувствительное значение — нет")
func sensitiveValueIsNotIndexed() throws {
    let database = try NotchDatabase(location: .temporary())
    try database.migrate()
    let repository = SnippetsRepository(database: database)
    try repository.add(label: "ИИН", value: "секретноезначение",
                       icon: nil, colorHex: nil, isSensitive: true, at: t0)

    let leaked = try database.queue.read { db in
        try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM search_index WHERE body LIKE '%секретноезначение%'"
        ) ?? 0
    }
    #expect(leaked == 0)
}

/// Правка обязана доезжать до индекса, а не только до самой записи пина.
///
/// Без этого поиск продолжал бы находить пин по старой метке и не находил
/// бы по новой — молча, потому что запись и поиск по отдельности работают.
/// Бриф задачи дал проверки индекса только на создание (через отсутствие
/// утечки чувствительного значения) — путь обновления остался без своей
/// проверки, как в прошлой задаче с заметками, где это вскрылось уже на
/// ревью. Тест добавлен сразу, а не после повторной находки.
@Test("правка пина обновляет метку в поисковом индексе")
func snippetUpdateRefreshesSearchIndex() throws {
    let database = try NotchDatabase(location: .temporary())
    try database.migrate()
    let repository = SnippetsRepository(database: database)
    try repository.add(label: "старая метка", value: "значение",
                       icon: nil, colorHex: nil, isSensitive: false, at: t0)
    let pin = try #require(try repository.all().first)

    var updated = pin
    updated.label = "новая метка"
    try repository.update(updated, at: t0.addingTimeInterval(60))

    let indexed = try database.queue.read { db in
        try String.fetchOne(
            db,
            sql: "SELECT body FROM search_index WHERE owner_kind = 'snippet' AND owner_id = ?",
            arguments: [pin.id]
        )
    }
    #expect(indexed == "новая метка")
}

/// Удаление обязано убирать и саму запись, и строку индекса — иначе поиск
/// находил бы уже удалённый пин. Заодно проверяет то, что имя брифового
/// теста `sensitiveValueIsNotIndexed` заявляет, но не проверяет само тело:
/// что метка действительно попадает в индекс при создании (а не только
/// что чувствительное значение туда не попадает).
@Test("удаление убирает пин и его строку индекса")
func deleteRemovesSnippetAndIndexRow() throws {
    let database = try NotchDatabase(location: .temporary())
    try database.migrate()
    let repository = SnippetsRepository(database: database)
    try repository.add(label: "удалить", value: "значение",
                       icon: nil, colorHex: nil, isSensitive: false, at: t0)
    let pin = try #require(try repository.all().first)

    let indexedBeforeDelete = try database.queue.read { db in
        try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM search_index WHERE owner_kind = 'snippet' AND body = ?",
            arguments: ["удалить"]
        ) ?? 0
    }
    #expect(indexedBeforeDelete == 1)

    let id = try #require(pin.id)
    try repository.delete(id: id)
    #expect(try repository.all().isEmpty)

    let indexedAfterDelete = try database.queue.read { db in
        try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM search_index WHERE owner_kind = 'snippet'"
        ) ?? 0
    }
    #expect(indexedAfterDelete == 0)
}

/// Значение не индексируется и для нечувствительных пинов — правило одно
/// для всех, без ветвления по isSensitive в месте записи индекса (см.
/// комментарий в SnippetsRepository.add). Без этого теста регрессия вида
/// «для нечувствительных давай проиндексируем value ради удобства поиска»
/// прошла бы незамеченной: единственная проверка из брифа покрывает
/// только isSensitive: true.
@Test("значение не индексируется и когда пин не чувствительный")
func nonSensitiveValueIsNotIndexedEither() throws {
    let database = try NotchDatabase(location: .temporary())
    try database.migrate()
    let repository = SnippetsRepository(database: database)
    try repository.add(label: "Телефон", value: "открытоезначение",
                       icon: nil, colorHex: nil, isSensitive: false, at: t0)

    let leaked = try database.queue.read { db in
        try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM search_index WHERE body LIKE ?",
            arguments: ["%открытоезначение%"]
        ) ?? 0
    }
    #expect(leaked == 0)
}

/// Пустая после отсечения пробелов метка отклоняется и при правке, тем же
/// правилом, что и при создании, — иначе пин можно обезличить до пина без
/// подписи правкой, а не только создать такой напрямую (брифовый тест
/// `emptyLabelIsRejected` проверяет только add).
@Test("пустая метка не сохраняется и при правке")
func emptyLabelIsRejectedOnUpdate() throws {
    let repository = try makeRepository()
    try repository.add(label: "исходная метка", value: "значение",
                       icon: nil, colorHex: nil, isSensitive: false, at: t0)
    let pin = try #require(try repository.all().first)

    var blanked = pin
    blanked.label = "   "
    try repository.update(blanked, at: t0.addingTimeInterval(60))

    #expect(try repository.all().map(\.label) == ["исходная метка"])
}
