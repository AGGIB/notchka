# Notchka: Хранилище и буфер обмена — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** История буфера обмена в чёлке: текст, картинки и файлы с указанием источника, горизонтальной лентой, вставкой одним кликом и тремя слоями защиты от паролей.

**Architecture:** `NotchStore` — SQLite через GRDB с миграциями и контент-адресуемым хранилищем блобов; `ClipboardKit` — опрос пастборда, фильтры и вытеснение. Вставка живёт в app-таргете: она требует Accessibility и возврата фокуса, то есть AppKit.

**Tech Stack:** Swift 6.3, GRDB.swift (первая внешняя зависимость проекта), CryptoKit, SwiftUI, Swift Testing.

Опирается на:
- [2026-08-10-notchka-foundation.md](2026-08-10-notchka-foundation.md) — слит в master
- [2026-08-12-notchka-music.md](2026-08-12-notchka-music.md) — оболочка панели с вкладками
- Спека: [2026-08-10-notchka-design.md](../specs/2026-08-10-notchka-design.md) §6, §7, §9, §10

## Global Constraints

- macOS 26.0+, Apple Silicon. Swift 6.3, Xcode 26.6.
- Строгая конкурентность Swift 6, язык версии 6.
- Тесты — **Swift Testing**, не XCTest.
- `NotchStore` и `ClipboardKit` не импортируют AppKit. Всё, что требует
  AppKit — чтение пастборда, вставка, разрешения — живёт в app-таргете.
- Логирование — `os.Logger`.
- Хранилище: `~/Library/Application Support/kz.mobilefirst.notchka/`,
  файл `notch.sqlite` и каталог `blobs/`.
- Лимиты буфера: **500 записей, 30 дней, 2 ГБ блобов** — срабатывает первый
  достигнутый. Закреплённые элементы из ротации исключены.
- Опрос пастборда — раз в **0.4 с** на низкоприоритетной очереди, с паузой
  при неактивности пользователя дольше **60 с**.
- Клик вставляет, `⌥`клик копирует. Оригинал пастборда не восстанавливается.
- Файлы 200–400 строк типично, 800 максимум. Функции до 50 строк.
- Комментарии на русском, объясняют «почему», а не «что».
- Формат коммитов: `<type>: <описание>`.

## Про приватность — прочитать до начала

Это первый план, где приложение постоянно читает чужие данные. Всё, что
пользователь копирует, включая пароли, банковские реквизиты и одноразовые
коды, проходит через этот код.

Спека задаёт три слоя защиты, и **порядок задач в плане подчинён этому**:
фильтры пишутся и тестируются раньше, чем появляется хоть одна строка,
пишущая в базу. Обратный порядок означал бы окно, в котором пароли
сохраняются в открытом виде, и никакая последующая правка их оттуда
не уберёт.

База не шифруется — это осознанный компромисс спеки §11 для личной машины.
Тем важнее, чтобы в неё не попадало то, чему там не место.

---

### Task 1: Зависимость GRDB и открытие базы

**Files:**
- Modify: `Packages/NotchKit/Package.swift`
- Create: `Packages/NotchKit/Sources/NotchStore/StoreLocation.swift`
- Create: `Packages/NotchKit/Sources/NotchStore/NotchDatabase.swift`
- Test: `Packages/NotchKit/Tests/NotchStoreTests/StoreLocationTests.swift`

**Interfaces:**
- Produces:
  - `StoreLocation.applicationSupport(bundleID:) -> URL`, `.databaseURL`, `.blobsDirectory`
  - `NotchDatabase(location:)` с `func migrate() throws`, `var queue: DatabaseQueue`

- [ ] **Step 1: Добавить зависимость и выяснить её версию**

Это первая внешняя зависимость проекта. `Package.resolved` уже выведен
из-под `.gitignore` планом 1 — после резолва он должен попасть в коммит.

Добавь в `Packages/NotchKit/Package.swift`:

```swift
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
```

и таргеты:

```swift
        .target(name: "NotchStore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "NotchStoreTests", dependencies: ["NotchStore"]),
```

плюс продукт `.library(name: "NotchStore", targets: ["NotchStore"])`.

```bash
swift package resolve --package-path Packages/NotchKit
grep -A2 'GRDB' Packages/NotchKit/Package.resolved
```

**Запиши в отчёт, какая мажорная версия зарезолвилась.** Код в этом плане
использует `DatabaseQueue`, `DatabaseMigrator` и `create(virtualTable:using:)` —
API, стабильный в GRDB много лет. Если резолвер даст версию, где что-то из
этого называется иначе, **остановись и доложи**, а не подгоняй код наугад:
миграции и FTS — не то место, где стоит угадывать.

- [ ] **Step 2: Написать падающие тесты расположения**

Создай `Packages/NotchKit/Tests/NotchStoreTests/StoreLocationTests.swift`:

```swift
import Testing
import Foundation
@testable import NotchStore

@Test("база и блобы лежат внутри каталога приложения")
func pathsAreInsideApplicationSupport() {
    let location = StoreLocation(bundleID: "kz.mobilefirst.notchka")
    #expect(location.databaseURL.path.contains("Application Support/kz.mobilefirst.notchka"))
    #expect(location.blobsDirectory.path.contains("Application Support/kz.mobilefirst.notchka"))
    #expect(location.databaseURL.lastPathComponent == "notch.sqlite")
}

@Test("временное расположение изолировано и не трогает боевое")
func temporaryLocationIsIsolated() {
    let a = StoreLocation.temporary()
    let b = StoreLocation.temporary()
    #expect(a.databaseURL != b.databaseURL)
    #expect(a.databaseURL.path.contains("Application Support") == false)
}

@Test("каталоги создаются по требованию")
func directoriesAreCreated() throws {
    let location = StoreLocation.temporary()
    try location.createDirectories()
    #expect(FileManager.default.fileExists(atPath: location.blobsDirectory.path))
}
```

- [ ] **Step 3: Запустить тесты и убедиться, что они падают**

Run: `swift test --package-path Packages/NotchKit --filter StoreLocationTests`
Expected: FAIL — `no such module 'NotchStore'`

- [ ] **Step 4: Написать расположение**

Создай `Packages/NotchKit/Sources/NotchStore/StoreLocation.swift`:

```swift
import Foundation

/// Где лежат база и блобы.
///
/// Отдельный тип, потому что тестам нужно изолированное расположение:
/// прогон, который пишет в боевую базу пользователя, недопустим, а
/// подменять пути строками по месту — верный способ однажды промахнуться.
public struct StoreLocation: Sendable, Equatable {
    public let root: URL

    public var databaseURL: URL { root.appending(path: "notch.sqlite") }
    public var blobsDirectory: URL { root.appending(path: "blobs") }

    public init(root: URL) {
        self.root = root
    }

    public init(bundleID: String) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.init(root: base.appending(path: bundleID))
    }

    /// Изолированное расположение для тестов.
    public static func temporary() -> StoreLocation {
        StoreLocation(root: URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "notchka-tests-\(UUID().uuidString)"))
    }

    public func createDirectories() throws {
        try FileManager.default.createDirectory(at: blobsDirectory, withIntermediateDirectories: true)
    }
}
```

- [ ] **Step 5: Написать базу и миграции**

Создай `Packages/NotchKit/Sources/NotchStore/NotchDatabase.swift`:

```swift
import Foundation
import GRDB

/// Соединение с базой и её схема.
///
/// Миграции нумерованы и неизменны после выпуска: план 4 добавит свои
/// следующим шагом, а не правкой этого. Иначе база пользователя, созданная
/// сегодня, разойдётся со схемой, которую ожидает код завтра.
public final class NotchDatabase: Sendable {
    public let queue: DatabaseQueue
    private let location: StoreLocation

    public init(location: StoreLocation) throws {
        self.location = location
        try location.createDirectories()
        self.queue = try DatabaseQueue(path: location.databaseURL.path)
    }

    public func migrate() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1-clipboard") { db in
            try db.create(table: "clipboard_items") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull()
                // Хеш содержимого уникален: повторное копирование того же
                // текста поднимает существующую запись, а не плодит копии.
                t.column("content_hash", .text).notNull().unique()
                t.column("text_body", .text)
                t.column("blob_path", .text)
                t.column("byte_size", .integer).notNull()
                t.column("source_bundle_id", .text)
                t.column("source_app_name", .text)
                t.column("created_at", .datetime).notNull()
                t.column("last_used_at", .datetime).notNull()
                t.column("is_pinned", .boolean).notNull().defaults(to: false)
            }
            // Лента всегда сортируется по последнему использованию —
            // без индекса это полный скан на каждое открытие панели.
            try db.create(index: "idx_clipboard_last_used", on: "clipboard_items", columns: ["last_used_at"])
        }

        migrator.registerMigration("v2-search") { db in
            // Contentless FTS: тексты уже лежат в своих таблицах, дублировать
            // их внутрь индекса незачем. Строки индекса ведут на владельца
            // парой (owner_kind, owner_id).
            try db.create(virtualTable: "search_index", using: FTS5()) { t in
                t.column("owner_kind").notIndexed()
                t.column("owner_id").notIndexed()
                t.column("title")
                t.column("body")
            }
        }

        try migrator.migrate(queue)
    }
}
```

- [ ] **Step 6: Запустить тесты и убедиться, что они проходят**

Run: `swift test --package-path Packages/NotchKit --filter StoreLocationTests`
Expected: PASS, 3 теста

- [ ] **Step 7: Закоммитить вместе с Package.resolved**

```bash
git add Packages/NotchKit
git status --short   # Package.resolved обязан быть в списке
git commit -m "feat: база на GRDB со схемой буфера и полнотекстовым индексом"
```

---

### Task 2: Контент-адресуемое хранилище блобов

**Files:**
- Create: `Packages/NotchKit/Sources/NotchStore/BlobStore.swift`
- Test: `Packages/NotchKit/Tests/NotchStoreTests/BlobStoreTests.swift`

**Interfaces:**
- Consumes: `StoreLocation`
- Produces:
  - `BlobStore(location:)` с `func store(_ data: Data) throws -> String`,
    `func data(at path: String) throws -> Data`, `func remove(at path: String) throws`,
    `func totalSize() throws -> Int`
  - `BlobStore.hash(_ data: Data) -> String`

- [ ] **Step 1: Написать падающие тесты**

Создай `Packages/NotchKit/Tests/NotchStoreTests/BlobStoreTests.swift`:

```swift
import Testing
import Foundation
@testable import NotchStore

private func makeStore() throws -> BlobStore {
    let location = StoreLocation.temporary()
    try location.createDirectories()
    return BlobStore(location: location)
}

@Test("одинаковые данные дают одинаковый путь")
func identicalDataSharesPath() throws {
    let store = try makeStore()
    let data = Data("одно и то же".utf8)
    #expect(try store.store(data) == store.store(data))
}

@Test("разные данные дают разные пути")
func differentDataDiffers() throws {
    let store = try makeStore()
    #expect(try store.store(Data("a".utf8)) != store.store(Data("b".utf8)))
}

@Test("сохранённые данные читаются обратно без изменений")
func roundTripPreservesBytes() throws {
    let store = try makeStore()
    let original = Data((0..<1024).map { UInt8($0 % 256) })
    let path = try store.store(original)
    #expect(try store.data(at: path) == original)
}

@Test("повторное сохранение не удваивает место на диске")
func duplicateStoreDoesNotGrow() throws {
    let store = try makeStore()
    let data = Data(repeating: 7, count: 4096)
    _ = try store.store(data)
    let afterFirst = try store.totalSize()
    _ = try store.store(data)
    #expect(try store.totalSize() == afterFirst)
}

@Test("путь разложен по подкаталогам, чтобы не собирать тысячи файлов в одном")
func pathIsSharded() throws {
    let store = try makeStore()
    let path = try store.store(Data("x".utf8))
    #expect(path.contains("/"))
    #expect(path.split(separator: "/").first?.count == 2)
}

@Test("удаление убирает файл и освобождает место")
func removeFreesSpace() throws {
    let store = try makeStore()
    let path = try store.store(Data(repeating: 1, count: 2048))
    try store.remove(at: path)
    #expect(try store.totalSize() == 0)
}

@Test("чтение отсутствующего блоба бросает, а не отдаёт пустые данные")
func missingBlobThrows() throws {
    let store = try makeStore()
    #expect(throws: (any Error).self) { try store.data(at: "aa/несуществующий") }
}
```

- [ ] **Step 2: Запустить тесты и убедиться, что они падают**

Run: `swift test --package-path Packages/NotchKit --filter BlobStoreTests`
Expected: FAIL — `cannot find 'BlobStore' in scope`

- [ ] **Step 3: Написать реализацию**

Создай `Packages/NotchKit/Sources/NotchStore/BlobStore.swift`:

```swift
import Foundation
import CryptoKit

/// Хранилище картинок и файлов, адресуемое содержимым.
///
/// Путь выводится из хеша, поэтому дедупликация получается сама собой:
/// один и тот же скриншот, скопированный дважды, занимает место один раз,
/// и запись в базе о нём тоже одна.
public struct BlobStore: Sendable {
    private let location: StoreLocation

    public init(location: StoreLocation) {
        self.location = location
    }

    public static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Сохраняет данные и возвращает относительный путь.
    @discardableResult
    public func store(_ data: Data) throws -> String {
        let path = Self.relativePath(for: Self.hash(data))
        let url = location.blobsDirectory.appending(path: path)
        // Файл с таким именем — это ровно эти байты: содержимое и есть имя.
        // Перезаписывать незачем, и это экономит запись на каждый повтор.
        guard !FileManager.default.fileExists(atPath: url.path) else { return path }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        return path
    }

    public func data(at path: String) throws -> Data {
        try Data(contentsOf: location.blobsDirectory.appending(path: path))
    }

    public func remove(at path: String) throws {
        let url = location.blobsDirectory.appending(path: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public func totalSize() throws -> Int {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: location.blobsDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }

        var total = 0
        for case let url as URL in enumerator {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            total += size ?? 0
        }
        return total
    }

    /// Первые два символа хеша — подкаталог: тысячи файлов в одной папке
    /// замедляют файловую систему и делают каталог нечитаемым глазами.
    private static func relativePath(for hash: String) -> String {
        "\(hash.prefix(2))/\(hash)"
    }
}
```

- [ ] **Step 4: Запустить тесты и убедиться, что они проходят**

Run: `swift test --package-path Packages/NotchKit --filter BlobStoreTests`
Expected: PASS, 7 тестов

- [ ] **Step 5: Закоммитить**

```bash
git add Packages/NotchKit
git commit -m "feat: контент-адресуемое хранилище блобов с дедупликацией"
```

---

### Task 3: Фильтры приватности

**Пишется до записи в базу намеренно.** Обратный порядок оставил бы окно,
в котором пароли сохраняются в открытом виде.

**Files:**
- Create: `Packages/NotchKit/Sources/ClipboardKit/PasteboardSnapshot.swift`
- Create: `Packages/NotchKit/Sources/ClipboardKit/PrivacyFilter.swift`
- Modify: `Packages/NotchKit/Package.swift` — таргеты `ClipboardKit`, `ClipboardKitTests`
- Test: `Packages/NotchKit/Tests/ClipboardKitTests/PrivacyFilterTests.swift`

**Interfaces:**
- Produces:
  - `PasteboardSnapshot(types:sourceBundleID:)` — то, что прочитано из пастборда,
    без AppKit
  - `PrivacyFilter(blockedBundleIDs:)` с `func shouldCapture(_ snapshot: PasteboardSnapshot) -> Bool`
  - `PrivacyFilter.defaultBlockedBundleIDs`
  - Константы типов: `.concealed`, `.transient`, `.autoGenerated`

- [ ] **Step 1: Написать падающие тесты**

Создай `Packages/NotchKit/Tests/ClipboardKitTests/PrivacyFilterTests.swift`:

```swift
import Testing
@testable import ClipboardKit

private func snapshot(types: [String], from bundleID: String? = "com.apple.TextEdit") -> PasteboardSnapshot {
    PasteboardSnapshot(types: types, sourceBundleID: bundleID)
}

@Test("обычный текст из обычного приложения попадает в историю")
func plainTextIsCaptured() {
    let filter = PrivacyFilter()
    #expect(filter.shouldCapture(snapshot(types: ["public.utf8-plain-text"])))
}

@Test("флаг ConcealedType отменяет захват — его ставят менеджеры паролей")
func concealedTypeIsRejected() {
    let filter = PrivacyFilter()
    #expect(filter.shouldCapture(snapshot(types: [
        "public.utf8-plain-text", PasteboardType.concealed
    ])) == false)
}

@Test("временное содержимое не сохраняется")
func transientTypeIsRejected() {
    let filter = PrivacyFilter()
    #expect(filter.shouldCapture(snapshot(types: [
        "public.utf8-plain-text", PasteboardType.transient
    ])) == false)
}

@Test("автосгенерированное содержимое не сохраняется")
func autoGeneratedTypeIsRejected() {
    let filter = PrivacyFilter()
    #expect(filter.shouldCapture(snapshot(types: [
        "public.utf8-plain-text", PasteboardType.autoGenerated
    ])) == false)
}

@Test("копирование из менеджера паролей отсекается по приложению-источнику")
func blockedAppIsRejected() {
    let filter = PrivacyFilter()
    for blocked in PrivacyFilter.defaultBlockedBundleIDs {
        #expect(filter.shouldCapture(snapshot(types: ["public.utf8-plain-text"], from: blocked)) == false)
    }
}

@Test("чёрный список настраивается")
func customBlockListIsHonoured() {
    let filter = PrivacyFilter(blockedBundleIDs: ["com.example.secrets"])
    #expect(filter.shouldCapture(snapshot(types: ["public.utf8-plain-text"], from: "com.example.secrets")) == false)
    // Свой список заменяет умолчания целиком, а не дополняет: иначе
    // отключить встроенную запись было бы нечем.
    #expect(filter.shouldCapture(snapshot(types: ["public.utf8-plain-text"], from: "com.1password.1password")))
}

@Test("неизвестный источник не повод отказывать")
func unknownSourceIsAllowed() {
    let filter = PrivacyFilter()
    #expect(filter.shouldCapture(snapshot(types: ["public.utf8-plain-text"], from: nil)))
}

@Test("пустой пастборд не событие")
func emptyTypesAreRejected() {
    let filter = PrivacyFilter()
    #expect(filter.shouldCapture(snapshot(types: [])) == false)
}
```

- [ ] **Step 2: Запустить тесты и убедиться, что они падают**

Run: `swift test --package-path Packages/NotchKit --filter PrivacyFilterTests`
Expected: FAIL — `no such module 'ClipboardKit'`

- [ ] **Step 3: Написать снимок пастборда**

Создай `Packages/NotchKit/Sources/ClipboardKit/PasteboardSnapshot.swift`:

```swift
import Foundation

/// Идентификаторы типов пастборда, важные для приватности.
///
/// Это не UTI Apple, а конвенция, которой следуют менеджеры паролей:
/// приложение помечает содержимое, чтобы менеджеры буфера его не сохраняли.
/// Соблюдать её — вопрос не совместимости, а порядочности.
public enum PasteboardType {
    public static let concealed = "org.nspasteboard.ConcealedType"
    public static let transient = "org.nspasteboard.TransientType"
    public static let autoGenerated = "org.nspasteboard.AutoGeneratedType"
}

/// То, что прочитано из пастборда, без AppKit.
///
/// Отделено от `NSPasteboard` намеренно: фильтры и разбор должны
/// проверяться на выдуманных сочетаниях типов, а не на живом пастборде
/// машины, где нельзя воспроизвести флаг менеджера паролей.
public struct PasteboardSnapshot: Sendable, Equatable {
    public let types: [String]
    public let sourceBundleID: String?

    public init(types: [String], sourceBundleID: String?) {
        self.types = types
        self.sourceBundleID = sourceBundleID
    }
}
```

- [ ] **Step 4: Написать фильтр**

Создай `Packages/NotchKit/Sources/ClipboardKit/PrivacyFilter.swift`:

```swift
import Foundation

/// Решает, попадает ли скопированное в историю.
///
/// Три слоя, потому что ни один не полон: флаг ставят не все менеджеры
/// паролей, чёрный список не знает про приложения, о которых мы не подумали,
/// а временные типы ловят автоматику вроде переводчиков и сокращателей
/// ссылок. Вместе они дают приемлемый уровень, порознь — нет.
public struct PrivacyFilter: Sendable {
    /// Приложения, копирование из которых не сохраняется никогда.
    public static let defaultBlockedBundleIDs: Set<String> = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "com.apple.keychainaccess",
    ]

    private static let rejectedTypes: Set<String> = [
        PasteboardType.concealed,
        PasteboardType.transient,
        PasteboardType.autoGenerated,
    ]

    private let blockedBundleIDs: Set<String>

    public init(blockedBundleIDs: Set<String> = PrivacyFilter.defaultBlockedBundleIDs) {
        self.blockedBundleIDs = blockedBundleIDs
    }

    public func shouldCapture(_ snapshot: PasteboardSnapshot) -> Bool {
        guard !snapshot.types.isEmpty else { return false }
        guard snapshot.types.allSatisfy({ !Self.rejectedTypes.contains($0) }) else { return false }
        // Неизвестный источник не повод отказывать: bundle id пропадает,
        // например, при копировании из системных диалогов, и терять из-за
        // этого обычный текст было бы хуже, чем сохранить его.
        guard let source = snapshot.sourceBundleID else { return true }
        return !blockedBundleIDs.contains(source)
    }
}
```

- [ ] **Step 5: Запустить тесты и убедиться, что они проходят**

Run: `swift test --package-path Packages/NotchKit --filter PrivacyFilterTests`
Expected: PASS, 8 тестов

- [ ] **Step 6: Закоммитить**

```bash
git add Packages/NotchKit
git commit -m "feat: три слоя защиты от попадания паролей в историю буфера"
```

---

### Task 4: Модель элемента и запись в базу

**Files:**
- Create: `Packages/NotchKit/Sources/NotchStore/ClipboardItem.swift`
- Create: `Packages/NotchKit/Sources/NotchStore/ClipboardRepository.swift`
- Test: `Packages/NotchKit/Tests/NotchStoreTests/ClipboardRepositoryTests.swift`

**Interfaces:**
- Consumes: `NotchDatabase`, `BlobStore`
- Produces:
  - `ClipboardItem` (GRDB-запись) и `ClipboardKind { text, image, file }`
  - `ClipboardRepository(database:blobs:)` с `save(_:)`, `recent(limit:)`,
    `touch(id:at:)`, `setPinned(id:_:)`, `delete(id:)`

- [ ] **Step 1: Написать падающие тесты**

Создай `Packages/NotchKit/Tests/NotchStoreTests/ClipboardRepositoryTests.swift`:

```swift
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
```

- [ ] **Step 2: Запустить тесты и убедиться, что они падают**

Run: `swift test --package-path Packages/NotchKit --filter ClipboardRepositoryTests`
Expected: FAIL — `cannot find 'ClipboardRepository' in scope`

- [ ] **Step 3: Написать модель**

Создай `Packages/NotchKit/Sources/NotchStore/ClipboardItem.swift`:

```swift
import Foundation
import GRDB

public enum ClipboardKind: String, Codable, Sendable {
    case text, image, file
}

/// Запись истории буфера.
///
/// Текст лежит прямо в строке, а картинки и файлы — блобом на диске:
/// класть мегабайтные скриншоты в SQLite значит раздувать базу и замедлять
/// любой запрос к ленте.
public struct ClipboardItem: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "clipboard_items"

    public var id: Int64?
    public var kind: ClipboardKind
    public var contentHash: String
    public var textBody: String?
    public var blobPath: String?
    public var byteSize: Int
    public var sourceBundleId: String?
    public var sourceAppName: String?
    public var createdAt: Date
    public var lastUsedAt: Date
    public var isPinned: Bool

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    enum CodingKeys: String, CodingKey {
        case id, kind
        case contentHash = "content_hash"
        case textBody = "text_body"
        case blobPath = "blob_path"
        case byteSize = "byte_size"
        case sourceBundleId = "source_bundle_id"
        case sourceAppName = "source_app_name"
        case createdAt = "created_at"
        case lastUsedAt = "last_used_at"
        case isPinned = "is_pinned"
    }
}
```

- [ ] **Step 4: Написать репозиторий**

Создай `Packages/NotchKit/Sources/NotchStore/ClipboardRepository.swift`:

```swift
import Foundation
import GRDB

/// Доступ к истории буфера.
public struct ClipboardRepository: Sendable {
    private let database: NotchDatabase
    private let blobs: BlobStore

    public init(database: NotchDatabase, blobs: BlobStore) {
        self.database = database
        self.blobs = blobs
    }

    public func saveText(
        _ text: String,
        source: (bundleID: String, appName: String)?,
        at now: Date = Date()
    ) throws {
        let data = Data(text.utf8)
        try save(
            kind: .text, hash: BlobStore.hash(data), text: text, blobPath: nil,
            byteSize: data.count, source: source, at: now
        )
    }

    public func saveImage(
        _ data: Data,
        source: (bundleID: String, appName: String)?,
        at now: Date = Date()
    ) throws {
        let path = try blobs.store(data)
        try save(
            kind: .image, hash: BlobStore.hash(data), text: nil, blobPath: path,
            byteSize: data.count, source: source, at: now
        )
    }

    public func saveFile(
        _ data: Data,
        fileName: String,
        source: (bundleID: String, appName: String)?,
        at now: Date = Date()
    ) throws {
        let path = try blobs.store(data)
        try save(
            kind: .file, hash: BlobStore.hash(data), text: fileName, blobPath: path,
            byteSize: data.count, source: source, at: now
        )
    }

    /// Повтор не создаёт вторую запись: уникальность хеша ловит его на уровне
    /// базы, а мы поднимаем существующую строку наверх ленты.
    private func save(
        kind: ClipboardKind, hash: String, text: String?, blobPath: String?,
        byteSize: Int, source: (bundleID: String, appName: String)?, at now: Date
    ) throws {
        try database.queue.write { db in
            if let existing = try ClipboardItem
                .filter(Column("content_hash") == hash)
                .fetchOne(db)
            {
                var updated = existing
                updated.lastUsedAt = now
                try updated.update(db)
                return
            }

            var item = ClipboardItem(
                id: nil, kind: kind, contentHash: hash, textBody: text,
                blobPath: blobPath, byteSize: byteSize,
                sourceBundleId: source?.bundleID, sourceAppName: source?.appName,
                createdAt: now, lastUsedAt: now, isPinned: false
            )
            try item.insert(db)

            if let text, !text.isEmpty, let id = item.id {
                try db.execute(
                    sql: "INSERT INTO search_index (owner_kind, owner_id, title, body) VALUES (?, ?, ?, ?)",
                    arguments: ["clipboard", id, source?.appName ?? "", text]
                )
            }
        }
    }

    public func recent(limit: Int) throws -> [ClipboardItem] {
        try database.queue.read { db in
            try ClipboardItem
                .order(Column("last_used_at").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    public func setPinned(id: Int64, _ isPinned: Bool) throws {
        try database.queue.write { db in
            try db.execute(
                sql: "UPDATE clipboard_items SET is_pinned = ? WHERE id = ?",
                arguments: [isPinned, id]
            )
        }
    }

    public func delete(id: Int64) throws {
        try database.queue.write { db in
            let item = try ClipboardItem.filter(Column("id") == id).fetchOne(db)
            // Блоб удаляется вместе с записью: осиротевший файл не найдёт
            // никто, а место он занимать продолжит.
            if let path = item?.blobPath { try? blobs.remove(at: path) }
            try db.execute(sql: "DELETE FROM clipboard_items WHERE id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM search_index WHERE owner_kind = 'clipboard' AND owner_id = ?", arguments: [id])
        }
    }

    public func data(for item: ClipboardItem) throws -> Data? {
        guard let path = item.blobPath else { return nil }
        return try blobs.data(at: path)
    }

    public func blobBytes() throws -> Int {
        try blobs.totalSize()
    }
}
```

- [ ] **Step 5: Запустить тесты и убедиться, что они проходят**

Run: `swift test --package-path Packages/NotchKit --filter ClipboardRepositoryTests`
Expected: PASS, 6 тестов

- [ ] **Step 6: Закоммитить**

```bash
git add Packages/NotchKit
git commit -m "feat: репозиторий истории буфера с дедупликацией по содержимому"
```

---

### Task 5: Лимиты и вытеснение

**Files:**
- Create: `Packages/NotchKit/Sources/NotchStore/RetentionPolicy.swift`
- Modify: `Packages/NotchKit/Sources/NotchStore/ClipboardRepository.swift` — метод `prune(policy:now:)`
- Test: `Packages/NotchKit/Tests/NotchStoreTests/RetentionPolicyTests.swift`

**Interfaces:**
- Produces:
  - `RetentionPolicy(maxItems:maxAge:maxBlobBytes:)`, `.default`
  - `ClipboardRepository.prune(policy:now:) throws -> Int`

- [ ] **Step 1: Написать падающие тесты**

Создай `Packages/NotchKit/Tests/NotchStoreTests/RetentionPolicyTests.swift`:

```swift
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
```

- [ ] **Step 2: Запустить тесты и убедиться, что они падают**

Run: `swift test --package-path Packages/NotchKit --filter RetentionPolicyTests`
Expected: FAIL — `cannot find 'RetentionPolicy' in scope`

- [ ] **Step 3: Написать политику**

Создай `Packages/NotchKit/Sources/NotchStore/RetentionPolicy.swift`:

```swift
import Foundation

/// Сколько истории хранить.
///
/// Три независимых предела, а не один: количество бережёт скорость ленты,
/// возраст — приватность (скопированное полгода назад пользователь давно
/// забыл), объём — диск, потому что один скриншот весит как тысяча строк
/// текста. Срабатывает тот, до которого дошли первым.
public struct RetentionPolicy: Sendable, Equatable {
    public let maxItems: Int
    public let maxAge: TimeInterval
    public let maxBlobBytes: Int

    public init(maxItems: Int, maxAge: TimeInterval, maxBlobBytes: Int) {
        self.maxItems = maxItems
        self.maxAge = maxAge
        self.maxBlobBytes = maxBlobBytes
    }

    public static let `default` = RetentionPolicy(
        maxItems: 500,
        maxAge: 30 * 24 * 3600,
        maxBlobBytes: 2 * 1024 * 1024 * 1024
    )
}
```

- [ ] **Step 4: Написать чистку**

Добавь в `ClipboardRepository`:

```swift
    /// Приводит историю к пределам политики. Возвращает число удалённых.
    ///
    /// Закреплённое не трогается никогда: пользователь закрепил его именно
    /// затем, чтобы оно пережило ротацию.
    @discardableResult
    public func prune(policy: RetentionPolicy, now: Date = Date()) throws -> Int {
        let candidates = try database.queue.read { db in
            try ClipboardItem
                .filter(Column("is_pinned") == false)
                .order(Column("last_used_at").desc)
                .fetchAll(db)
        }

        var doomed: [ClipboardItem] = []
        var keptBlobBytes = 0

        for (index, item) in candidates.enumerated() {
            let tooMany = index >= policy.maxItems
            let tooOld = now.timeIntervalSince(item.lastUsedAt) > policy.maxAge
            let hasBlob = item.blobPath != nil
            let overBudget = hasBlob && keptBlobBytes + item.byteSize > policy.maxBlobBytes

            if tooMany || tooOld || overBudget {
                doomed.append(item)
            } else if hasBlob {
                keptBlobBytes += item.byteSize
            }
        }

        for item in doomed {
            if let id = item.id { try delete(id: id) }
        }
        return doomed.count
    }
```

- [ ] **Step 5: Запустить тесты и убедиться, что они проходят**

Run: `swift test --package-path Packages/NotchKit --filter RetentionPolicyTests`
Expected: PASS, 6 тестов

- [ ] **Step 6: Закоммитить**

```bash
git add Packages/NotchKit
git commit -m "feat: вытеснение истории по количеству, возрасту и объёму"
```

---

### Task 6: Монитор пастборда

**Files:**
- Create: `Packages/NotchKit/Sources/ClipboardKit/PasteboardPoller.swift`
- Create: `App/PasteboardReader.swift`
- Test: `Packages/NotchKit/Tests/ClipboardKitTests/PasteboardPollerTests.swift`

**Interfaces:**
- Produces:
  - `PasteboardPoller` с `mutating func shouldRead(changeCount:idleSeconds:) -> Bool`
  - Константы `.interval = 0.4`, `.idleThreshold = 60`
  - `PasteboardReader` в app-таргете — мост к `NSPasteboard`

- [ ] **Step 1: Написать падающие тесты**

Логика «читать или нет» отделена от `NSPasteboard`, чтобы проверяться без него.

Создай `Packages/NotchKit/Tests/ClipboardKitTests/PasteboardPollerTests.swift`:

```swift
import Testing
@testable import ClipboardKit

@Test("первое изменение счётчика читается")
func firstChangeIsRead() {
    var poller = PasteboardPoller()
    #expect(poller.shouldRead(changeCount: 7, idleSeconds: 0))
}

@Test("тот же счётчик второй раз не читается")
func sameCountIsSkipped() {
    var poller = PasteboardPoller()
    _ = poller.shouldRead(changeCount: 7, idleSeconds: 0)
    #expect(poller.shouldRead(changeCount: 7, idleSeconds: 0) == false)
}

@Test("новое изменение читается")
func newChangeIsRead() {
    var poller = PasteboardPoller()
    _ = poller.shouldRead(changeCount: 7, idleSeconds: 0)
    #expect(poller.shouldRead(changeCount: 8, idleSeconds: 0))
}

@Test("при долгой неактивности не читаем — копировать некому")
func idleUserIsNotPolled() {
    var poller = PasteboardPoller()
    #expect(poller.shouldRead(changeCount: 9, idleSeconds: 120) == false)
}

@Test("вернувшийся пользователь снова читается, и пропущенное подхватывается")
func returningUserIsReadAgain() {
    var poller = PasteboardPoller()
    _ = poller.shouldRead(changeCount: 9, idleSeconds: 120)
    #expect(poller.shouldRead(changeCount: 9, idleSeconds: 1))
}

@Test("интервал и порог неактивности совпадают со спекой")
func constantsMatchSpec() {
    #expect(PasteboardPoller.interval == 0.4)
    #expect(PasteboardPoller.idleThreshold == 60)
}
```

- [ ] **Step 2: Запустить тесты и убедиться, что они падают**

Run: `swift test --package-path Packages/NotchKit --filter PasteboardPollerTests`
Expected: FAIL — `cannot find 'PasteboardPoller' in scope`

- [ ] **Step 3: Написать опрос**

Создай `Packages/NotchKit/Sources/ClipboardKit/PasteboardPoller.swift`:

```swift
import Foundation

/// Решает, надо ли читать пастборд.
///
/// Публичного уведомления об изменении пастборда в macOS нет — остаётся
/// опрос счётчика. Логика «читать или нет» отделена от `NSPasteboard`,
/// чтобы проверяться без него: подделать `changeCount` живой системы
/// в тесте нельзя.
public struct PasteboardPoller: Sendable {
    /// Чаще нет смысла: человек не копирует по пять раз в секунду.
    public static let interval: TimeInterval = 0.4
    /// Неактивный пользователь ничего не копирует — незачем будить процесс.
    public static let idleThreshold: TimeInterval = 60

    private var lastSeenCount: Int?

    public init() {}

    public mutating func shouldRead(changeCount: Int, idleSeconds: TimeInterval) -> Bool {
        guard idleSeconds < Self.idleThreshold else { return false }
        // Счётчик не запоминаем, пока пользователь неактивен: иначе
        // скопированное во время его отсутствия потерялось бы навсегда.
        guard lastSeenCount != changeCount else { return false }
        lastSeenCount = changeCount
        return true
    }
}
```

- [ ] **Step 4: Написать мост к NSPasteboard**

Создай `App/PasteboardReader.swift` — единственное место, где приложение
трогает `NSPasteboard` на чтение:

```swift
import AppKit
import ClipboardKit

/// Мост от NSPasteboard к чистым типам.
enum PasteboardReader {
    struct Content {
        let snapshot: PasteboardSnapshot
        let text: String?
        let image: Data?
        let fileName: String?
        let fileData: Data?
    }

    static func read() -> Content? {
        let pasteboard = NSPasteboard.general
        let types = (pasteboard.types ?? []).map(\.rawValue)
        let frontmost = NSWorkspace.shared.frontmostApplication

        let snapshot = PasteboardSnapshot(
            types: types,
            sourceBundleID: frontmost?.bundleIdentifier
        )

        // Порядок важен: файл может нести и текстовое представление,
        // и картинку-превью, а показать его надо файлом.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           let url = urls.first, url.isFileURL,
           let data = try? Data(contentsOf: url)
        {
            return Content(snapshot: snapshot, text: nil, image: nil,
                           fileName: url.lastPathComponent, fileData: data)
        }
        if let image = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            return Content(snapshot: snapshot, text: nil, image: image, fileName: nil, fileData: nil)
        }
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            return Content(snapshot: snapshot, text: text, image: nil, fileName: nil, fileData: nil)
        }
        return nil
    }

    static func appName(for bundleID: String?) -> String? {
        guard let bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        return FileManager.default.displayName(atPath: url.path)
    }
}
```

- [ ] **Step 5: Подключить опрос в app-таргете**

Создай в app-таргете службу, которая раз в `PasteboardPoller.interval`
на низкоприоритетной очереди спрашивает поллер, читает пастборд через
`PasteboardReader`, прогоняет через `PrivacyFilter` и пишет в репозиторий.
Неактивность бери из `CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .null)`.

Чистку `prune` вызывай не на каждую запись, а раз в сутки и при запуске:
проход по всей истории на каждое копирование — лишняя работа.

- [ ] **Step 6: Собрать и проверить вручную**

- [ ] Скопируй текст — он появляется в базе (проверь `sqlite3` или логом)
- [ ] Скопируй скриншот — появляется блоб, размер сходится
- [ ] Скопируй пароль из менеджера — **не появляется**
- [ ] Оставь машину на две минуты — опрос затихает (нулевой CPU)

- [ ] **Step 7: Прогнать тесты и закоммитить**

```bash
git add Packages/NotchKit App
git commit -m "feat: опрос пастборда с паузой при неактивности и фильтрами"
```

---

### Task 7: Вставка в активное приложение

**Files:**
- Create: `App/PasteService.swift`
- Create: `App/AccessibilityPermission.swift`
- Modify: `App/NotchController.swift` — запоминать фронтовое приложение

**Interfaces:**
- Produces:
  - `AccessibilityPermission.isTrusted`, `.requestIfNeeded()`, `.openSettings()`
  - `PasteService.paste(_ text:into:)`, `.copyOnly(_ text:)`

- [ ] **Step 1: Написать проверку разрешения**

Создай `App/AccessibilityPermission.swift`:

```swift
import AppKit
import ApplicationServices

/// Разрешение Accessibility — единственное, которое нужно приложению,
/// и только ради посылки `⌘V` в чужое приложение.
enum AccessibilityPermission {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Показывает системный запрос. Возвращает состояние на момент вызова:
    /// разрешение выдаётся асинхронно, пользователь уходит в настройки.
    @discardableResult
    static func requestIfNeeded() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
```

- [ ] **Step 2: Написать вставку**

Создай `App/PasteService.swift`:

```swift
import AppKit
import CoreGraphics
import os

/// Кладёт текст в пастборд и вставляет его в активное приложение.
///
/// Оригинал пастборда сознательно не восстанавливается: восстановление
/// через задержку ломает приложения, читающие буфер асинхронно, и даёт
/// гонки, которые пользователь увидит как «вставилось не то».
@MainActor
enum PasteService {
    private static let logger = Logger(subsystem: "kz.mobilefirst.notchka", category: "paste")

    static func copyOnly(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Возвращает false, если нет разрешения: вызывающий показывает подсказку.
    @discardableResult
    static func paste(_ text: String, into application: NSRunningApplication?) -> Bool {
        copyOnly(text)

        guard AccessibilityPermission.isTrusted else {
            logger.notice("вставка невозможна: нет разрешения Accessibility, текст только скопирован")
            return false
        }

        // Фокус возвращается тому приложению, у которого его забрала
        // раскрытая панель, иначе ⌘V уйдёт в пустоту.
        application?.activate()
        postCommandV()
        return true
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKeyCode: CGKeyCode = 0x09  // kVK_ANSI_V

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        else {
            logger.error("не удалось создать событие ⌘V")
            return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
```

- [ ] **Step 3: Запоминать фронтовое приложение при разворачивании**

В `App/NotchController.swift` при переходе в `.expanded` сохраняй
`NSWorkspace.shared.frontmostApplication` — до того, как панель станет
key-окном. После этого момента фронтовым будет уже Notchka.

- [ ] **Step 4: Проверить вручную**

- [ ] Открой TextEdit, разверни панель хоткеем, вставь элемент — текст появляется в TextEdit
- [ ] `⌥`клик — текст в буфере, но не вставлен
- [ ] Отзови разрешение Accessibility — клик копирует и показывает подсказку, приложение не падает

- [ ] **Step 5: Закоммитить**

```bash
git add App
git commit -m "feat: вставка в активное приложение через CGEvent"
```

---

### Task 8: Клавиатура

Закрывает долг фундамента: `⌘1`…`⌘4`, `⇥`, `Esc`, стрелки и `↩` машина
умеет с плана 1, но отправлять их некому.

**Files:**
- Create: `App/PanelKeyHandler.swift`
- Modify: `App/NotchPanel.swift`, `App/NotchController.swift`
- Test: `Packages/NotchKit/Tests/NotchCoreTests/KeyBindingTests.swift`

**Interfaces:**
- Produces: `KeyBinding.event(forKeyCode:modifiers:) -> NotchEvent?`

- [ ] **Step 1: Написать падающие тесты раскладки**

Соответствие клавиш событиям — чистая логика, её можно проверить без окна.

Создай `Packages/NotchKit/Tests/NotchCoreTests/KeyBindingTests.swift`:

```swift
import Testing
@testable import NotchCore

@Test("цифры с командой выбирают вкладки по порядку")
func digitsSelectTabs() {
    #expect(KeyBinding.event(forKeyCode: .digit1, modifiers: [.command]) == .selectTab(.music))
    #expect(KeyBinding.event(forKeyCode: .digit2, modifiers: [.command]) == .selectTab(.clipboard))
    #expect(KeyBinding.event(forKeyCode: .digit3, modifiers: [.command]) == .selectTab(.notes))
    #expect(KeyBinding.event(forKeyCode: .digit4, modifiers: [.command]) == .selectTab(.pins))
}

@Test("цифры без команды вкладки не переключают — это ввод в поиск")
func digitsWithoutCommandAreNotBindings() {
    #expect(KeyBinding.event(forKeyCode: .digit1, modifiers: []) == nil)
}

@Test("таб листает вкладки по кругу")
func tabCycles() {
    #expect(KeyBinding.event(forKeyCode: .tab, modifiers: []) == .cycleTab)
}

@Test("escape закрывает панель")
func escapeDismisses() {
    #expect(KeyBinding.event(forKeyCode: .escape, modifiers: []) == .dismiss)
}

@Test("неизвестная клавиша не даёт события")
func unknownKeyIsIgnored() {
    #expect(KeyBinding.event(forKeyCode: .other(99), modifiers: []) == nil)
}
```

- [ ] **Step 2: Запустить тесты и убедиться, что они падают**

Run: `swift test --package-path Packages/NotchKit --filter KeyBindingTests`
Expected: FAIL — `cannot find 'KeyBinding' in scope`

- [ ] **Step 3: Написать раскладку**

Создай `Packages/NotchKit/Sources/NotchCore/KeyBinding.swift`:

```swift
/// Клавиша в терминах, независимых от AppKit.
public enum PanelKey: Sendable, Equatable {
    case digit1, digit2, digit3, digit4
    case tab, escape
    case other(UInt16)
}

public struct PanelModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = PanelModifiers(rawValue: 1 << 0)
    public static let option = PanelModifiers(rawValue: 1 << 1)
    public static let shift = PanelModifiers(rawValue: 1 << 2)
}

/// Что делает клавиша в раскрытой панели.
///
/// Отдельно от AppKit, потому что раскладка — это правило, а не механика:
/// проверять «⌘2 открывает буфер» надо без окна и без нажатий.
public enum KeyBinding {
    public static func event(forKeyCode key: PanelKey, modifiers: PanelModifiers) -> NotchEvent? {
        switch key {
        // Цифры работают только с командой: без неё это обычный ввод,
        // который должен попасть в поле поиска.
        case .digit1 where modifiers.contains(.command): .selectTab(.music)
        case .digit2 where modifiers.contains(.command): .selectTab(.clipboard)
        case .digit3 where modifiers.contains(.command): .selectTab(.notes)
        case .digit4 where modifiers.contains(.command): .selectTab(.pins)
        case .tab: .cycleTab
        case .escape: .dismiss
        default: nil
        }
    }
}
```

- [ ] **Step 4: Подключить в панели**

Создай `App/PanelKeyHandler.swift` — перевод `NSEvent` в `PanelKey` и
`PanelModifiers`, и в `NotchPanel` переопредели `keyDown(with:)`, чтобы
раскрытая панель отдавала события контроллеру. Панель становится key-окном
только в `.expanded`, поэтому обработчик срабатывает лишь тогда, когда должен.

- [ ] **Step 5: Проверить вручную**

- [ ] `⌥Space`, затем `⌘2` — открывается буфер
- [ ] `⇥` листает вкладки по кругу
- [ ] `Esc` закрывает панель
- [ ] Ввод цифры в поле поиска не переключает вкладку

- [ ] **Step 6: Закоммитить**

```bash
git add Packages/NotchKit App
git commit -m "feat: клавиатурное управление вкладками панели"
```

---

### Task 9: Вкладка буфера — горизонтальная лента

**Files:**
- Create: `Packages/NotchKit/Sources/NotchUI/ClipboardTabView.swift`
- Create: `App/ClipboardViewModel.swift`
- Modify: `App/AppDelegate.swift`
- Test: `Packages/NotchKit/Tests/NotchUITests/ClipboardCardTests.swift`

**Interfaces:**
- Produces:
  - `ClipboardCard` — модель карточки (`kind`, `preview`, `source`, `isPinned`)
  - `ClipboardTabView(cards:selected:onActivate:onCopyOnly:)`
  - `ClipboardCard.preview(for:maxLength:)`

- [ ] **Step 1: Написать падающие тесты превью**

Создай `Packages/NotchKit/Tests/NotchUITests/ClipboardCardTests.swift`:

```swift
import Testing
@testable import NotchUI

@Test("длинный текст обрезается с многоточием")
func longTextIsTruncated() {
    let preview = ClipboardCard.preview(for: String(repeating: "а", count: 200), maxLength: 40)
    #expect(preview.count <= 41)
    #expect(preview.hasSuffix("…"))
}

@Test("короткий текст не трогается")
func shortTextIsUnchanged() {
    #expect(ClipboardCard.preview(for: "коротко", maxLength: 40) == "коротко")
}

@Test("переводы строк схлопываются — карточка в одну-две строки высотой")
func newlinesAreCollapsed() {
    #expect(ClipboardCard.preview(for: "первая\nвторая\n\nтретья", maxLength: 40) == "первая вторая третья")
}

@Test("ведущие и хвостовые пробелы убираются")
func whitespaceIsTrimmed() {
    #expect(ClipboardCard.preview(for: "   текст   ", maxLength: 40) == "текст")
}

@Test("пустой текст даёт пустое превью, а не многоточие")
func emptyStaysEmpty() {
    #expect(ClipboardCard.preview(for: "   ", maxLength: 40) == "")
}
```

- [ ] **Step 2: Запустить тесты и убедиться, что они падают**

Run: `swift test --package-path Packages/NotchKit --filter ClipboardCardTests`
Expected: FAIL — `cannot find 'ClipboardCard' in scope`

- [ ] **Step 3: Написать карточку и ленту**

Создай `Packages/NotchKit/Sources/NotchUI/ClipboardTabView.swift` с моделью
карточки, превью и горизонтальной лентой. Раскладка выбрана человеком на
этапе дизайна: лента, а не список, потому что панель остаётся низкой,
а картинки видно картинками.

```swift
import SwiftUI

public struct ClipboardCard: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable { case text, image, file }

    public let id: Int64
    public let kind: Kind
    public let preview: String
    public let source: String
    public let isPinned: Bool

    public init(id: Int64, kind: Kind, preview: String, source: String, isPinned: Bool) {
        self.id = id
        self.kind = kind
        self.preview = preview
        self.source = source
        self.isPinned = isPinned
    }

    /// Превью для карточки.
    ///
    /// Переводы строк схлопываются, потому что карточка фиксированной
    /// высоты: многострочный текст иначе обрежется на первой строке и
    /// станет неузнаваемым.
    public static func preview(for text: String, maxLength: Int) -> String {
        let flattened = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard flattened.count > maxLength else { return flattened }
        return flattened.prefix(maxLength) + "…"
    }
}
```

Дальше в том же файле — `ClipboardTabView` с `ScrollView(.horizontal)`,
карточками ~76 pt шириной, подписью типа, превью и именем источника.
Выделенная карточка обводится акцентным цветом. Клик вызывает `onActivate`,
`⌥`клик — `onCopyOnly`.

- [ ] **Step 4: Написать модель в app-таргете**

Создай `App/ClipboardViewModel.swift`: `@Observable`, читает `recent(limit:)`
при открытии панели, отдаёт карточки, обрабатывает активацию через
`PasteService`.

Не держи подписку на базу постоянно: лента нужна только при раскрытой
панели, а в покое приложение обязано спать.

- [ ] **Step 5: Подключить вкладку**

В `AppDelegate` передай `ClipboardTabView` в `NotchPanelView` для вкладки
`.clipboard`.

- [ ] **Step 6: Проверить вручную**

- [ ] Скопируй несколько разных вещей, открой буфер — все видны, новое слева
- [ ] Клик по текстовой карточке вставляет текст в активное приложение
- [ ] `⌥`клик только копирует
- [ ] Карточка со скриншотом показывает картинку, а не «Снимок экрана»
- [ ] Источник подписан именем приложения, а не bundle id

- [ ] **Step 7: Прогнать тесты и закоммитить**

```bash
pkill -x Notchka
git add Packages/NotchKit App
git commit -m "feat: вкладка буфера обмена горизонтальной лентой"
```

---

### Task 10: Онбординг разрешения

**Files:**
- Create: `Packages/NotchKit/Sources/NotchUI/PermissionPromptView.swift`
- Modify: `App/AppDelegate.swift`

- [ ] **Step 1: Написать вьюху запроса**

Панель показывает шаг с объяснением и кнопкой в нужный раздел системных
настроек. Текст должен говорить, **зачем** разрешение, а не просто просить:
пользователь, которому не объяснили, справедливо откажет.

- [ ] **Step 2: Подхватывать выдачу без перезапуска**

Проверяй `AccessibilityPermission.isTrusted` при каждом разворачивании
панели: пользователь уходит в настройки и возвращается, и требовать
перезапуска приложения после этого — плохие манеры.

- [ ] **Step 3: Проверить вручную**

- [ ] Отзови разрешение в системных настройках, запусти приложение — панель объясняет, зачем оно
- [ ] Кнопка открывает нужный раздел настроек
- [ ] Выдай разрешение и вернись — панель работает без перезапуска

- [ ] **Step 4: Закоммитить**

```bash
git add Packages/NotchKit App
git commit -m "feat: онбординг разрешения Accessibility"
```

---

### Task 11: Приёмка плана «Буфер»

- [ ] **Step 1: Прогнать все тесты**

Run: `swift test --package-path Packages/NotchKit`
Expected: PASS. Ожидаемое число выведи сложением: 78 после плана 2 плюс
3 + 7 + 8 + 6 + 6 + 6 + 5 + 5 = 46 новых, итого **124**.

- [ ] **Step 2: Релизная сборка без предупреждений**

Грепай полный лог на `warning:` и `error:`, а не хвост.

- [ ] **Step 3: Проверить приватность отдельно и придирчиво**

Это главная проверка плана. Пройди её вручную и запиши результат:

- [ ] Копирование из 1Password не попадает в историю
- [ ] Копирование из Связки ключей не попадает
- [ ] Обычный текст из того же приложения после этого попадает — фильтр не залипает
- [ ] База не содержит ничего похожего на пароль: открой `notch.sqlite` и посмотри глазами

- [ ] **Step 4: Замерить расход**

CPU в покое при неактивном пользователе, при активной работе с копированием,
и объём базы после сотни элементов.

- [ ] **Step 5: Записать отчёт и закоммитить**

Создай `docs/superpowers/notes/2026-08-12-clipboard-acceptance.md`.

---

## Что дальше

- **План 4 — заметки, пины и поиск.** `StashKit` поверх той же базы,
  сквозной поиск по трём сущностям через уже созданный FTS-индекс,
  настройки, переезд адаптера внутрь бандла.

Долги, оставленные этим планом:

- Поиск по буферу написан в базу, но интерфейса у него нет — он появится
  в плане 4 вместе с общим полем поиска.
- Файлы сохраняются копией содержимого. Для больших файлов это расточительно;
  альтернатива — хранить ссылку и терять данные при перемещении оригинала.
  Решение отложено до появления реального неудобства.
- `prune` вызывается по расписанию, а не при превышении. Если пользователь
  за день скопирует тысячу скриншотов, лимит объёма будет нарушен до
  следующей чистки.
