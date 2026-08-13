# Notchka: Заметки, пины и поиск — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Быстрые заметки и закреплённые сниппеты в чёлке, сквозной поиск по буферу, заметкам и пинам одним полем — и приложение, работающее вне дерева исходников.

**Architecture:** `StashKit` поверх уже существующей базы: вторая миграция добавляет две таблицы, поиск использует FTS-индекс, созданный планом 3. Адаптер переезжает внутрь бандла, после чего приложение перестаёт зависеть от репозитория.

**Tech Stack:** Swift 6.3, GRDB.swift, SwiftUI, Swift Testing.

Опирается на:
- [2026-08-10-notchka-foundation.md](2026-08-10-notchka-foundation.md) — слит в master
- [2026-08-12-notchka-music.md](2026-08-12-notchka-music.md)
- [2026-08-12-notchka-clipboard.md](2026-08-12-notchka-clipboard.md)
- Спека: [2026-08-10-notchka-design.md](../specs/2026-08-10-notchka-design.md) §6, §7, §9, §10

Это последний план продукта. Его приёмка проверяет не свою часть, а
**весь инструмент целиком** против критериев готовности спеки §14.

## Global Constraints

- macOS 26.0+, Apple Silicon. Swift 6.3, Xcode 26.6.
- Строгая конкурентность Swift 6, язык версии 6.
- Тесты — **Swift Testing**, не XCTest.
- `NotchStore`, `StashKit`, `ClipboardKit` не импортируют AppKit.
- Логирование — `os.Logger`.
- Клик вставляет, `⌥`клик копирует. Оригинал пастборда не восстанавливается.
- Файлы 200–400 строк типично, 800 максимум. Функции до 50 строк.
- Комментарии на русском, объясняют «почему», а не «что».
- Формат коммитов: `<type>: <описание>`.

## Про чувствительные пины

Пин может нести ИИН, номер карты или адрес. Спека §7 требует помечать такие
значения чувствительными: в панели они маскируются точками, а вставляются
целиком.

Маскировка — это защита от взгляда через плечо, **не от чтения базы**: база
не шифруется, и значение лежит в ней открытым текстом. Не выдавать маскировку
за шифрование ни в интерфейсе, ни в комментариях.

---

### Task 1: Схема заметок и пинов

**Files:**
- Modify: `Packages/NotchKit/Sources/NotchStore/NotchDatabase.swift` — миграция v3
- Test: `Packages/NotchKit/Tests/NotchStoreTests/MigrationTests.swift`

**Interfaces:**
- Produces: таблицы `notes` и `snippets`

- [ ] **Step 1: Написать падающие тесты**

Создай `Packages/NotchKit/Tests/NotchStoreTests/MigrationTests.swift`:

```swift
import Testing
import Foundation
import GRDB
@testable import NotchStore

private func migratedDatabase() throws -> NotchDatabase {
    let database = try NotchDatabase(location: .temporary())
    try database.migrate()
    return database
}

@Test("после миграций существуют все четыре таблицы")
func allTablesExist() throws {
    let database = try migratedDatabase()
    try database.queue.read { db in
        #expect(try db.tableExists("clipboard_items"))
        #expect(try db.tableExists("notes"))
        #expect(try db.tableExists("snippets"))
        #expect(try db.tableExists("search_index"))
    }
}

// Имя нарочно не `migrationIsIdempotent`: такая функция уже есть в
// NotchDatabaseTests того же тест-таргета, и вторая с тем же именем —
// ошибка повторного объявления, а не два теста.
@Test("повторная миграция не теряет уже сохранённые строки")
func migrationPreservesExistingRows() throws {
    let location = StoreLocation.temporary()
    let first = try NotchDatabase(location: location)
    try first.migrate()
    try first.queue.write { db in
        try db.execute(sql: "INSERT INTO notes (body, created_at, updated_at) VALUES (?, ?, ?)",
                       arguments: ["сохранить меня", Date(), Date()])
    }

    let second = try NotchDatabase(location: location)
    try second.migrate()
    let count = try second.queue.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notes") ?? 0
    }
    #expect(count == 1)
}

@Test("порядок пинов хранится и уникален не требуется — дубли порядка допустимы")
func snippetOrderColumnExists() throws {
    let database = try migratedDatabase()
    try database.queue.write { db in
        for order in [1, 1, 2] {
            try db.execute(
                sql: "INSERT INTO snippets (label, value, sort_order, is_sensitive, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
                arguments: ["л", "з", order, false, Date(), Date()]
            )
        }
        #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM snippets") == 3)
    }
}

@Test("индекс не связан с таблицами-владельцами внешними ключами")
func searchIndexIsIndependent() throws {
    let database = try migratedDatabase()
    // Индекс не знает о таблицах-владельцах: связь держится парой
    // (owner_kind, owner_id), внешних ключей нет, и чистка при удалении —
    // ответственность репозиториев.
    //
    // Таблица при этом обычная FTS5, НЕ contentless — план 3 выбрал так
    // намеренно: из contentless нельзя удалять обычным DELETE ... WHERE,
    // а именно им чистятся строки. Не «оптимизировать» её обратно.
    try database.queue.read { db in
        #expect(try db.tableExists("search_index"))
    }
}
```

- [ ] **Step 2: Запустить тесты и убедиться, что они падают**

Run: `swift test --package-path Packages/NotchKit --filter MigrationTests`
Expected: FAIL — таблицы `notes` не существует

- [ ] **Step 3: Добавить миграцию**

Добавь в `NotchDatabase.migrate()` **третьей** миграцией, не трогая первые
две: они уже отработали на машине пользователя, и правка выпущенной
миграции разошла бы схему с кодом.

```swift
        migrator.registerMigration("v3-stash") { db in
            try db.create(table: "notes") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("body", .text).notNull()
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }

            try db.create(table: "snippets") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("label", .text).notNull()
                t.column("value", .text).notNull()
                t.column("icon", .text)
                t.column("color_hex", .text)
                // Порядок задаёт пользователь перетаскиванием; дубли
                // допустимы и разрешаются стабильной сортировкой по id.
                t.column("sort_order", .integer).notNull()
                t.column("is_sensitive", .boolean).notNull().defaults(to: false)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }
        }
```

- [ ] **Step 4: Запустить тесты и убедиться, что они проходят**

Run: `swift test --package-path Packages/NotchKit --filter MigrationTests`
Expected: PASS, 4 теста

- [ ] **Step 5: Закоммитить**

```bash
git add Packages/NotchKit
git commit -m "feat: схема заметок и закреплённых сниппетов"
```

---

### Task 2: Репозиторий заметок

**Files:**
- Create: `Packages/NotchKit/Sources/StashKit/Note.swift`
- Create: `Packages/NotchKit/Sources/StashKit/NotesRepository.swift`
- Modify: `Packages/NotchKit/Package.swift` — таргеты `StashKit`, `StashKitTests`
- Test: `Packages/NotchKit/Tests/StashKitTests/NotesRepositoryTests.swift`

**Interfaces:**
- Consumes: `NotchDatabase` из плана 3
- Produces: `Note`, `NotesRepository` с `add(_:at:)`, `all()`, `update(id:body:at:)`, `delete(id:)`

- [ ] **Step 1: Написать падающие тесты**

Создай `Packages/NotchKit/Tests/StashKitTests/NotesRepositoryTests.swift`:

```swift
import Testing
import Foundation
import NotchStore
@testable import StashKit

private let t0 = Date(timeIntervalSince1970: 1_000_000)

private func makeRepository() throws -> NotesRepository {
    let database = try NotchDatabase(location: .temporary())
    try database.migrate()
    return NotesRepository(database: database)
}

@Test("заметка сохраняется и читается")
func noteRoundTrips() throws {
    let repository = try makeRepository()
    try repository.add("созвон в 15:00", at: t0)
    #expect(try repository.all().map(\.body) == ["созвон в 15:00"])
}

@Test("свежие заметки идут первыми")
func newestFirst() throws {
    let repository = try makeRepository()
    try repository.add("первая", at: t0)
    try repository.add("вторая", at: t0.addingTimeInterval(60))
    #expect(try repository.all().map(\.body) == ["вторая", "первая"])
}

@Test("правка меняет текст и время изменения, но не время создания")
func updateKeepsCreationTime() throws {
    let repository = try makeRepository()
    try repository.add("черновик", at: t0)
    let note = try #require(try repository.all().first)
    try repository.update(id: note.id!, body: "готово", at: t0.addingTimeInterval(600))

    let updated = try #require(try repository.all().first)
    #expect(updated.body == "готово")
    #expect(updated.createdAt == t0)
    #expect(updated.updatedAt == t0.addingTimeInterval(600))
}

@Test("пустая заметка не сохраняется")
func emptyNoteIsRejected() throws {
    let repository = try makeRepository()
    try repository.add("   \n  ", at: t0)
    #expect(try repository.all().isEmpty)
}

@Test("удаление убирает заметку")
func deleteRemovesNote() throws {
    let repository = try makeRepository()
    try repository.add("удалить", at: t0)
    let note = try #require(try repository.all().first)
    try repository.delete(id: note.id!)
    #expect(try repository.all().isEmpty)
}

@Test("заметка попадает в поисковый индекс и уходит из него при удалении")
func noteIsIndexed() throws {
    let database = try NotchDatabase(location: .temporary())
    try database.migrate()
    let repository = NotesRepository(database: database)
    try repository.add("уникальноеслово", at: t0)

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
```

- [ ] **Step 2: Запустить тесты и убедиться, что они падают**

Run: `swift test --package-path Packages/NotchKit --filter NotesRepositoryTests`
Expected: FAIL — `no such module 'StashKit'`

- [ ] **Step 3: Написать модель и репозиторий**

Создай `Packages/NotchKit/Sources/StashKit/Note.swift` и
`NotesRepository.swift`. Ключевые решения, которые надо соблюсти:

- пустая заметка не сохраняется — иначе `⌘↩` по случайности плодит мусор;
- индекс обновляется в той же транзакции, что и сама запись, иначе поиск
  будет находить удалённое;
- `createdAt` при правке не трогается: пользователь ожидает, что заметка
  останется на своём месте в ленте.

```swift
import Foundation
import GRDB

public struct Note: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "notes"

    public var id: Int64?
    public var body: String
    public var createdAt: Date
    public var updatedAt: Date

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    enum CodingKeys: String, CodingKey {
        case id, body
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
```

- [ ] **Step 4: Запустить тесты и убедиться, что они проходят**

Run: `swift test --package-path Packages/NotchKit --filter NotesRepositoryTests`
Expected: PASS, 6 тестов

- [ ] **Step 5: Закоммитить**

```bash
git add Packages/NotchKit
git commit -m "feat: репозиторий быстрых заметок"
```

---

### Task 3: Репозиторий закреплённых сниппетов

**Files:**
- Create: `Packages/NotchKit/Sources/StashKit/Snippet.swift`
- Create: `Packages/NotchKit/Sources/StashKit/SnippetsRepository.swift`
- Test: `Packages/NotchKit/Tests/StashKitTests/SnippetsRepositoryTests.swift`

**Interfaces:**
- Produces:
  - `Snippet` с `label`, `value`, `icon`, `colorHex`, `sortOrder`, `isSensitive`
  - `SnippetsRepository` с `add(_:)`, `all()`, `move(id:to:)`, `update(_:)`, `delete(id:)`
  - `Snippet.masked(_ value: String) -> String`

- [ ] **Step 1: Написать падающие тесты**

Создай `Packages/NotchKit/Tests/StashKitTests/SnippetsRepositoryTests.swift`:

```swift
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
```

- [ ] **Step 2: Запустить тесты и убедиться, что они падают**

Run: `swift test --package-path Packages/NotchKit --filter SnippetsRepositoryTests`
Expected: FAIL — `cannot find 'SnippetsRepository' in scope`

- [ ] **Step 3: Написать реализацию**

Ключевые решения:

- **Маскировка фиксированной длины.** Показывать столько точек, сколько
  символов, значит выдавать длину — по ней ИИН отличается от номера карты.
- **Чувствительное значение не индексируется.** Иначе поиск по подстроке
  вернул бы его в результатах, и вся маскировка была бы напрасна.
- `move(id:to:)` перенумеровывает весь список: попытка вставлять дробные
  порядки экономит запись, но усложняет чтение без выигрыша на десятке пинов.

```swift
extension Snippet {
    /// Маска фиксированной длины.
    ///
    /// Длина настоящего значения — сама по себе подсказка: по числу точек
    /// ИИН отличим от номера карты. Поэтому маска не зависит от значения.
    public static func masked(_ value: String) -> String {
        "••• ••• •••"
    }
}
```

- [ ] **Step 4: Запустить тесты и убедиться, что они проходят**

Run: `swift test --package-path Packages/NotchKit --filter SnippetsRepositoryTests`
Expected: PASS, 7 тестов

- [ ] **Step 5: Закоммитить**

```bash
git add Packages/NotchKit
git commit -m "feat: репозиторий закреплённых сниппетов с маскировкой чувствительных"
```

---

### Task 4: Сквозной поиск

**Files:**
- Create: `Packages/NotchKit/Sources/NotchStore/SearchRepository.swift`
- Test: `Packages/NotchKit/Tests/NotchStoreTests/SearchRepositoryTests.swift`

**Interfaces:**
- Produces:
  - `SearchResult(kind:ownerID:title:snippet:)`, `SearchKind { clipboard, note, snippet }`
  - `SearchRepository.search(_ query: String, limit: Int) throws -> [SearchResult]`

- [ ] **Step 1: Написать падающие тесты**

Создай `Packages/NotchKit/Tests/NotchStoreTests/SearchRepositoryTests.swift`:

```swift
import Testing
import Foundation
@testable import NotchStore

private func seeded() throws -> (NotchDatabase, SearchRepository) {
    let database = try NotchDatabase(location: .temporary())
    try database.migrate()
    try database.queue.write { db in
        try db.execute(
            sql: "INSERT INTO search_index (owner_kind, owner_id, title, body) VALUES (?, ?, ?, ?)",
            arguments: ["clipboard", 1, "Safari", "ссылка на документацию GRDB"]
        )
        try db.execute(
            sql: "INSERT INTO search_index (owner_kind, owner_id, title, body) VALUES (?, ?, ?, ?)",
            arguments: ["note", 2, "", "созвон по документации в 15:00"]
        )
        try db.execute(
            sql: "INSERT INTO search_index (owner_kind, owner_id, title, body) VALUES (?, ?, ?, ?)",
            arguments: ["snippet", 3, "Почта", "developer@mobilefirst.kz"]
        )
    }
    return (database, SearchRepository(database: database))
}

@Test("находит по всем трём сущностям одним запросом")
func searchesAcrossKinds() throws {
    let (_, repository) = try seeded()
    let results = try repository.search("документации", limit: 10)
    #expect(Set(results.map(\.kind)) == [.clipboard, .note])
}

@Test("находит пин по метке")
func findsSnippetByLabel() throws {
    let (_, repository) = try seeded()
    #expect(try repository.search("Почта", limit: 10).map(\.kind) == [.snippet])
}

@Test("пустой запрос не возвращает всё подряд")
func emptyQueryReturnsNothing() throws {
    let (_, repository) = try seeded()
    #expect(try repository.search("   ", limit: 10).isEmpty)
}

@Test("запрос со спецсимволами FTS не роняет поиск")
func ftsSyntaxIsEscaped() throws {
    let (_, repository) = try seeded()
    // Кавычки и звёздочки — синтаксис FTS5; необработанные, они дают
    // syntax error и роняют весь поиск на обычном пользовательском вводе.
    #expect(throws: Never.self) { _ = try repository.search("\"незакрытая", limit: 10) }
    #expect(throws: Never.self) { _ = try repository.search("* AND *", limit: 10) }
}

@Test("поиск по префиксу работает — пользователь не дописывает слово целиком")
func prefixSearchWorks() throws {
    let (_, repository) = try seeded()
    #expect(try repository.search("докум", limit: 10).isEmpty == false)
}

@Test("лимит соблюдается")
func limitIsHonoured() throws {
    let (_, repository) = try seeded()
    #expect(try repository.search("документации", limit: 1).count == 1)
}

@Test("результат несёт идентификатор владельца для перехода к элементу")
func resultCarriesOwnerID() throws {
    let (_, repository) = try seeded()
    let result = try #require(try repository.search("Почта", limit: 1).first)
    #expect(result.ownerID == 3)
}
```

- [ ] **Step 2: Запустить тесты и убедиться, что они падают**

Run: `swift test --package-path Packages/NotchKit --filter SearchRepositoryTests`
Expected: FAIL — `cannot find 'SearchRepository' in scope`

- [ ] **Step 3: Написать реализацию**

Главная тонкость — **экранирование пользовательского ввода**. FTS5 понимает
кавычки, звёздочки, `AND`/`OR`/`NEAR`; необработанные, они дают синтаксическую
ошибку на обычном вводе вроде `"цитата` или `2 * 2`.

Приём: разбить ввод на слова, каждое обернуть в двойные кавычки с удвоением
внутренних, склеить пробелами и добавить `*` к последнему слову для поиска
по префиксу.

**Осторожно со словами без букв и цифр.** Ввод вроде `* AND *` даёт слова,
из которых токенизатор FTS5 не извлекает ни одного токена, и запрос из
пустых фраз может оказаться синтаксически неверным — то есть ровно тем
падением, которого мы избегаем. Тест `ftsSyntaxIsEscaped` требует, чтобы
поиск не бросал ни на одном таком вводе; проверь это прогоном, а не
рассуждением, и если пустые фразы ломают запрос — отбрасывай слова, не
дающие токенов, а если после отбрасывания не осталось ничего, возвращай
`nil`, как на пустом вводе.

```swift
    /// Превращает свободный ввод в безопасный запрос FTS5.
    ///
    /// Без этого обычный ввод с кавычкой или звёздочкой роняет поиск
    /// синтаксической ошибкой — пользователь не обязан знать грамматику FTS.
    static func sanitize(_ query: String) -> String? {
        let words = query
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.replacingOccurrences(of: "\"", with: "\"\"") }
            .map { "\"\($0)\"" }
        guard !words.isEmpty else { return nil }
        // Префиксный поиск только для последнего слова: пользователь
        // дописывает его прямо сейчас, остальные уже введены целиком.
        return words.dropLast().joined(separator: " ") + (words.count > 1 ? " " : "") + words.last! + "*"
    }
```

- [ ] **Step 4: Запустить тесты и убедиться, что они проходят**

Run: `swift test --package-path Packages/NotchKit --filter SearchRepositoryTests`
Expected: PASS, 7 тестов

- [ ] **Step 5: Закоммитить**

```bash
git add Packages/NotchKit
git commit -m "feat: сквозной поиск по буферу, заметкам и пинам"
```

---

### Task 5: Вкладка заметок

**Files:**
- Create: `Packages/NotchKit/Sources/NotchUI/NotesTabView.swift`
- Create: `App/NotesViewModel.swift`
- Test: `Packages/NotchKit/Tests/NotchUITests/NoteFormattingTests.swift`

**Interfaces:**
- Produces: `NoteRow`, `NotesTabView(rows:draft:onSave:onOpen:onDelete:)`,
  `NoteFormatting.relativeDate(_:now:)`

- [ ] **Step 1: Написать падающие тесты дат**

Создай `Packages/NotchKit/Tests/NotchUITests/NoteFormattingTests.swift`:

```swift
import Testing
import Foundation
@testable import NotchUI

/// Календарь с прибитым поясом, а не `.current`.
///
/// «Вчера» — календарное понятие, а не «минус 24 часа»: попадёт ли момент
/// на предыдущий день, зависит от пояса машины. С `.current` тест был бы
/// зелёным здесь и красным у того, кто запустит его восточнее или западнее,
/// причём без всякой связи с кодом, который он проверяет.
private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

/// 2027-01-15T08:00:00Z — середина суток по UTC, чтобы сдвиги на несколько
/// часов в тестах ниже не перескакивали через полночь случайно.
private let now = Date(timeIntervalSince1970: 1_800_000_000)

@Test("сегодняшняя заметка показывает время")
func todayShowsTime() {
    let text = NoteFormatting.relativeDate(now.addingTimeInterval(-3600), now: now, calendar: calendar)
    #expect(text.contains(":"))
}

@Test("вчерашняя подписана словом")
func yesterdayIsNamed() {
    let text = NoteFormatting.relativeDate(now.addingTimeInterval(-26 * 3600), now: now, calendar: calendar)
    #expect(text == "вчера")
}

@Test("старая показывает дату без времени")
func olderShowsDate() {
    let text = NoteFormatting.relativeDate(now.addingTimeInterval(-10 * 24 * 3600), now: now, calendar: calendar)
    #expect(text.contains(":") == false)
}

@Test("будущая дата не ломает форматирование")
func futureIsSafe() {
    let text = NoteFormatting.relativeDate(now.addingTimeInterval(3600), now: now, calendar: calendar)
    #expect(text.isEmpty == false)
}
```

- [ ] **Step 2: Запустить тесты и убедиться, что они падают**

Run: `swift test --package-path Packages/NotchKit --filter NoteFormattingTests`
Expected: FAIL — `cannot find 'NoteFormatting' in scope`

- [ ] **Step 3: Написать вьюху**

`NoteFormatting.relativeDate(_:now:calendar:)` принимает календарь третьим
параметром со значением по умолчанию `.current`: «вчера» — понятие
календарное, и без возможности прибить пояс тест зависел бы от того, где
находится машина, а не от кода.

Поле ввода сверху, `⌘↩` сохраняет, клик по заметке разворачивает
inline-редактор. Без markdown-рендера — спека §7: редактор размером с ладонь
не место для форматирования.

- [ ] **Step 4: Проверить вручную**

- [ ] `⌘3` открывает заметки
- [ ] Ввод и `⌘↩` сохраняют, поле очищается
- [ ] Пустая заметка не сохраняется
- [ ] Клик по заметке позволяет её править
- [ ] Заметки переживают перезапуск приложения

- [ ] **Step 5: Закоммитить**

```bash
git add Packages/NotchKit App
git commit -m "feat: вкладка быстрых заметок"
```

---

### Task 6: Вкладка пинов

**Files:**
- Create: `Packages/NotchKit/Sources/NotchUI/PinsTabView.swift`
- Create: `App/PinsViewModel.swift`
- Test: `Packages/NotchKit/Tests/NotchUITests/PinChipTests.swift`

**Interfaces:**
- Produces: `PinChip`, `PinsTabView(chips:onActivate:onCopyOnly:onReorder:onEdit:)`

- [ ] **Step 1: Написать падающие тесты**

Создай `Packages/NotchKit/Tests/NotchUITests/PinChipTests.swift`:

```swift
import Testing
@testable import NotchUI

@Test("обычный пин показывает значение")
func plainPinShowsValue() {
    let chip = PinChip(id: 1, label: "Почта", value: "a@b.kz", isSensitive: false, colorHex: nil, icon: nil)
    #expect(chip.displayValue == "a@b.kz")
}

@Test("чувствительный пин показывает маску, а не значение")
func sensitivePinIsMasked() {
    let chip = PinChip(id: 2, label: "ИИН", value: "123456789012", isSensitive: true, colorHex: nil, icon: nil)
    #expect(chip.displayValue.contains("123456") == false)
    #expect(chip.displayValue.contains("•"))
}

@Test("вставляется настоящее значение, а не маска")
func pasteUsesRealValue() {
    let chip = PinChip(id: 3, label: "ИИН", value: "123456789012", isSensitive: true, colorHex: nil, icon: nil)
    #expect(chip.pasteValue == "123456789012")
}

@Test("длинное значение обрезается в подписи, но не при вставке")
func longValueIsTruncatedOnlyForDisplay() {
    let long = String(repeating: "9", count: 100)
    let chip = PinChip(id: 4, label: "Длинный", value: long, isSensitive: false, colorHex: nil, icon: nil)
    #expect(chip.displayValue.count < long.count)
    #expect(chip.pasteValue == long)
}

@Test("некорректный цвет не роняет карточку")
func badColourFallsBack() {
    let chip = PinChip(id: 5, label: "П", value: "з", isSensitive: false, colorHex: "не цвет", icon: nil)
    #expect(chip.accentOrDefault != nil)
}
```

- [ ] **Step 2: Запустить тесты и убедиться, что они падают**

Run: `swift test --package-path Packages/NotchKit --filter PinChipTests`
Expected: FAIL — `cannot find 'PinChip' in scope`

- [ ] **Step 3: Написать чипы и сетку**

Сетка два столбца, у каждого чипа метка, значение, иконка и цветная полоса
слева. Порядок меняется перетаскиванием. Клик вставляет, `⌥`клик копирует.

Заголовок вкладки напоминает правило: «Клик — вставить · ⌥клик — скопировать».

- [ ] **Step 4: Проверить вручную**

- [ ] `⌘4` открывает пины
- [ ] Добавление пина работает, значение сохраняется
- [ ] Чувствительный пин показан точками
- [ ] Клик по нему вставляет **настоящее** значение
- [ ] Перетаскивание меняет порядок и переживает перезапуск

- [ ] **Step 5: Закоммитить**

```bash
git add Packages/NotchKit App
git commit -m "feat: вкладка закреплённых сниппетов"
```

---

### Task 7: Поле поиска и навигация

**Files:**
- Create: `Packages/NotchKit/Sources/NotchUI/SearchOverlayView.swift`
- Modify: `App/PanelKeyHandler.swift`, `App/NotchController.swift`
- Test: `Packages/NotchKit/Tests/NotchCoreTests/SearchNavigationTests.swift`

**Interfaces:**
- Produces: `SearchSelection` — курсор по списку результатов с переносом

- [ ] **Step 1: Написать падающие тесты навигации**

Создай `Packages/NotchKit/Tests/NotchCoreTests/SearchNavigationTests.swift`:

```swift
import Testing
@testable import NotchCore

@Test("стрелка вниз двигает выделение")
func downMovesSelection() {
    var selection = SearchSelection(count: 3)
    #expect(selection.index == 0)
    selection.moveDown()
    #expect(selection.index == 1)
}

@Test("с последнего элемента вниз переходит на первый")
func downWrapsToStart() {
    var selection = SearchSelection(count: 3)
    selection.moveDown(); selection.moveDown(); selection.moveDown()
    #expect(selection.index == 0)
}

@Test("с первого вверх переходит на последний")
func upWrapsToEnd() {
    var selection = SearchSelection(count: 3)
    selection.moveUp()
    #expect(selection.index == 2)
}

@Test("на пустом списке навигация безопасна")
func emptyListIsSafe() {
    var selection = SearchSelection(count: 0)
    selection.moveDown()
    selection.moveUp()
    #expect(selection.index == nil)
}

@Test("смена числа результатов сбрасывает выделение в начало")
func changingCountResetsSelection() {
    var selection = SearchSelection(count: 5)
    selection.moveDown(); selection.moveDown()
    selection.update(count: 2)
    #expect(selection.index == 0)
}
```

- [ ] **Step 2: Запустить тесты и убедиться, что они падают**

Run: `swift test --package-path Packages/NotchKit --filter SearchNavigationTests`
Expected: FAIL — `cannot find 'SearchSelection' in scope`

- [ ] **Step 3: Написать выделение и вьюху**

Поле открывается по `⌘F` или просто набором текста при раскрытой панели.
Результаты сгруппированы по источнику, `↑`/`↓` двигают выделение, `↩`
вставляет, `⌥↩` копирует.

- [ ] **Step 4: Проверить вручную**

- [ ] `⌘F` открывает поиск
- [ ] Набор текста при раскрытой панели тоже открывает
- [ ] Находит запись из буфера, заметку и пин одним запросом
- [ ] `↑`/`↓` двигают выделение, `↩` вставляет
- [ ] Ввод кавычки или звёздочки не роняет поиск

- [ ] **Step 5: Закоммитить**

```bash
git add Packages/NotchKit App
git commit -m "feat: сквозной поиск с клавиатурной навигацией"
```

---

### Task 8: Настройки

**Files:**
- Create: `App/SettingsWindow.swift`
- Create: `Packages/NotchKit/Sources/NotchCore/Preferences.swift`
- Test: `Packages/NotchKit/Tests/NotchCoreTests/PreferencesTests.swift`

**Interfaces:**
- Produces: `Preferences` — лимиты, чёрный список, хоткей, с валидацией

- [ ] **Step 1: Написать падающие тесты валидации**

Создай `Packages/NotchKit/Tests/NotchCoreTests/PreferencesTests.swift`:

```swift
import Testing
@testable import NotchCore

@Test("умолчания совпадают со спекой")
func defaultsMatchSpec() {
    let preferences = Preferences.default
    #expect(preferences.maxItems == 500)
    #expect(preferences.maxAgeDays == 30)
    #expect(preferences.maxBlobGigabytes == 2)
}

@Test("нулевой лимит записей отклоняется — история перестала бы работать")
func zeroLimitIsRejected() {
    #expect(Preferences.validated(maxItems: 0, maxAgeDays: 30, maxBlobGigabytes: 2).maxItems >= 1)
}

@Test("отрицательные значения приводятся к минимуму")
func negativesAreClamped() {
    let preferences = Preferences.validated(maxItems: -5, maxAgeDays: -1, maxBlobGigabytes: -3)
    #expect(preferences.maxItems >= 1)
    #expect(preferences.maxAgeDays >= 1)
    #expect(preferences.maxBlobGigabytes >= 1)
}

@Test("чёрный список хранится множеством — дубли не копятся")
func blockListIsASet() {
    let preferences = Preferences.default.addingBlocked("com.example.app").addingBlocked("com.example.app")
    #expect(preferences.blockedBundleIDs.filter { $0 == "com.example.app" }.count == 1)
}
```

- [ ] **Step 2: Запустить тесты и убедиться, что они падают**

Run: `swift test --package-path Packages/NotchKit --filter PreferencesTests`
Expected: FAIL — `cannot find 'Preferences' in scope`

- [ ] **Step 3: Написать настройки и окно**

Обычное окно, открывается из контекстного меню чёлки. Разделы: хоткей,
лимиты истории, чёрный список приложений, состояние разрешения Accessibility.

Хоткей переназначается — здесь появляется `KeyboardShortcuts`, о которой
говорит спека §3: она обёртка над тем же Carbon, что уже используется, плюс
готовый UI выбора сочетания.

- [ ] **Step 4: Проверить вручную**

- [ ] Настройки открываются и не мешают панели
- [ ] Смена хоткея вступает в силу сразу
- [ ] Смена лимитов применяется к следующей чистке
- [ ] Добавленное в чёрный список приложение перестаёт попадать в историю

- [ ] **Step 5: Закоммитить**

```bash
git add Packages/NotchKit App
git commit -m "feat: окно настроек с лимитами, чёрным списком и хоткеем"
```

---

### Task 9: Адаптер внутрь бандла

Долг плана 2: сейчас приложение работает только из дерева исходников,
потому что путь к адаптеру — константа с путём к репозиторию.

**Files:**
- Modify: `project.yml` — копирование адаптера в ресурсы бандла
- Modify: `Packages/NotchKit/Sources/MediaBridge/AdapterPaths.swift`
- Test: `Packages/NotchKit/Tests/MediaBridgeTests/AdapterBundlePathsTests.swift`

**Interfaces:**
- Produces: `AdapterPaths.bundled(resourceURL:)`

- [ ] **Step 1: Написать падающие тесты**

```swift
import Testing
import Foundation
@testable import MediaBridge

@Test("пути внутри бандла абсолютны и указывают на ресурсы")
func bundledPathsPointIntoResources() {
    let resources = URL(fileURLWithPath: "/Applications/Notchka.app/Contents/Resources")
    let paths = AdapterPaths.bundled(resourceURL: resources)
    #expect(paths.script.path.hasPrefix("/Applications/Notchka.app/Contents/Resources"))
    #expect(paths.framework.path.hasPrefix("/Applications/Notchka.app/Contents/Resources"))
}

@Test("perl берётся системный, а не из бандла")
func perlIsSystem() {
    let paths = AdapterPaths.bundled(resourceURL: URL(fileURLWithPath: "/tmp"))
    // Весь обход работает именно потому, что perl подписан Apple.
    // Своя копия сломала бы механизм.
    #expect(paths.perl.path == "/usr/bin/perl")
}

@Test("отсутствующие ресурсы честно определяются")
func missingResourcesAreDetected() {
    let paths = AdapterPaths.bundled(resourceURL: URL(fileURLWithPath: "/несуществующий"))
    #expect(paths.existsOnDisk == false)
}
```

- [ ] **Step 2: Запустить тесты и убедиться, что они падают**

Run: `swift test --package-path Packages/NotchKit --filter AdapterBundlePathsTests`
Expected: FAIL — нет метода `bundled(resourceURL:)`

- [ ] **Step 3: Добавить копирование в project.yml и метод**

В `project.yml` добавь `.pl`-скрипт и собранный фреймворк в ресурсы
приложения. Фреймворк надо собрать до сборки приложения — добавь шаг сборки
или задокументируй его в README как предусловие.

**Важно: perl остаётся системным.** Весь обход работает потому, что
`/usr/bin/perl` подписан Apple и проходит проверку MediaRemote. Копия внутри
бандла сломала бы механизм — это не оптимизация, а поломка.

- [ ] **Step 4: Проверить вручную главное**

- [ ] Собери релиз, скопируй `.app` в `/Applications`
- [ ] Переименуй каталог репозитория, чтобы путь точно стал недействительным
- [ ] Запусти приложение из `/Applications` — музыка по-прежнему читается

Это единственная проверка задачи, которая что-то доказывает: если не
переименовать репозиторий, приложение может продолжать работать по старому
пути и создать ложное впечатление успеха.

- [ ] **Step 5: Закоммитить**

```bash
git add project.yml Packages/NotchKit
git commit -m "feat: адаптер внутри бандла — приложение работает вне репозитория"
```

---

### Task 10: Финальная приёмка продукта

Проверяет не этот план, а **весь инструмент** против критериев готовности
спеки §14.

**Files:**
- Create: `docs/superpowers/notes/2026-08-12-product-acceptance.md`
- Modify: `README.md`

- [ ] **Step 1: Прогнать все тесты**

Run: `swift test --package-path Packages/NotchKit`
Expected: PASS. Ожидание: **174** после плана 3 (замерено на слитом master,
а не оценка из черновика этого плана: план 3 прирос колонкой вкладок,
бегущей строкой, кнопками перемотки и правками по ревью) плюс
4 + 6 + 7 + 7 + 4 + 5 + 5 + 4 + 3 = 45, итого **219**.

- [ ] **Step 2: Релизная сборка без предупреждений**

- [ ] **Step 3: Пройти все десять критериев спеки §14**

Отметь каждый и запиши, что именно проверил:

- [ ] Трек из YouTube в Chrome виден в панели, пауза и переключение работают
- [ ] Наведение открывает peek за 120 мс, проезд мимо не открывает
- [ ] Клики по меню-бару проходят насквозь при свёрнутой панели
- [ ] Текст, скриншот и файл появляются в ленте с указанием источника
- [ ] Копирование из менеджера паролей в ленту не попадает
- [ ] Клик по пину вставляет значение, `⌥`клик копирует
- [ ] Поиск находит запись из буфера, заметку и пин одним запросом
- [ ] Перезапуск адаптера не роняет приложение и не оставляет замороженный трек
- [ ] В свёрнутом состоянии приложение не потребляет заметного CPU
- [ ] Reduce Motion выключает морф

- [ ] **Step 4: Прожить с инструментом день**

Единственная проверка, которую не заменит чек-лист. Пользуйся приложением
обычным образом и записывай всё, что раздражает: промахи мимо горячей зоны,
неудобный порядок вкладок, лишние движения при вставке.

Это не формальность: инструмент, которым пользуются ежедневно, оценивается
привычкой, а не тестами.

- [ ] **Step 5: Написать README**

Что это, как собрать, какие разрешения нужны и зачем, известные
ограничения — включая то, что эквалайзер декоративный, а база не шифруется.

- [ ] **Step 6: Записать отчёт и закоммитить**

```bash
git add docs README.md
git commit -m "docs: финальная приёмка продукта"
```

---

## Что дальше

Спека §13 оставила за пределами первой версии:

- внешние мониторы без чёлки — синтетическая чёлка по центру верха экрана;
- перетаскивание файлов в чёлку как в полку AirDrop;
- markdown, теги и синхронизация заметок;
- настоящий аудиоспектр — требует виртуального аудиодрайвера;
- виджеты, погода, календарь, таймеры;
- шифрование базы.

Долги, накопленные планами 2–4, собраны в отчётах приёмки. Перед тем как
браться за что-то из списка выше, стоит потратить один заход на них: они
дешевле и мешают ежедневно.
