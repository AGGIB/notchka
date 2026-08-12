# Notchka: Музыка — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Вкладка музыки в чёлке: живой трек из любого источника, включая браузеры, с обложкой, вытянутым из неё акцентным цветом и работающим управлением.

**Architecture:** Новая библиотека `MediaBridge` в пакете `NotchKit` разбирает поток адаптера и отдаёт снимки через протокол; долгоживущий perl-процесс живёт под супервизором с нарастающими паузами. Отладочная вьюха фундамента заменяется настоящей оболочкой панели с вкладками, в которую садится плеер.

**Tech Stack:** Swift 6.3, Foundation `Process`, SwiftUI, Swift Testing, mediaremote-adapter (уже вендорен).

Опирается на:
- Фундамент: [2026-08-10-notchka-foundation.md](2026-08-10-notchka-foundation.md) — слит в master
- Спека: [2026-08-10-notchka-design.md](../specs/2026-08-10-notchka-design.md) §4, §7, §8
- **Источник истины по адаптеру:** [2026-08-10-spike-mediaremote.md](../notes/2026-08-10-spike-mediaremote.md)

## Global Constraints

Действуют в каждой задаче, повторно не проговариваются.

- macOS 26.0+, Apple Silicon. Swift 6.3, Xcode 26.6.
- Строгая конкурентность Swift 6 (`SWIFT_STRICT_CONCURRENCY = complete`), язык версии 6.
- Тесты — **Swift Testing** (`import Testing`, `@Test`, `#expect`), не XCTest.
- `NotchCore` и `MediaBridge` не импортируют AppKit. Мост в AppKit живёт только в app-таргете.
- Логирование — `os.Logger`, не `NSLog` и не `print`.
- Пружина открытия и разворота: `.spring(response: 0.34, dampingFraction: 0.68)`.
  Закрытие: `.snappy(duration: 0.26)`. Смена акцентного цвета: 600 мс.
- Ноль сетевых запросов. Обложка приходит из адаптера, наружу ничего не уходит.
- Файлы 200–400 строк типично, 800 максимум. Функции до 50 строк.
- Комментарии на русском, объясняют «почему», а не «что».
- Формат коммитов: `<type>: <описание>`, типы `feat|fix|refactor|docs|test|chore|perf`.
- В простое приложение спит: при закрытой панели поток адаптера читается, но
  рендер и таймеры UI не работают.

## Проверенные факты об адаптере

Всё ниже установлено спайком на этой машине, не предположено. Не переоткрывать.

**Пути обязаны быть абсолютными** — с относительными бридж падает с
`Failed to load framework`:

```
ADAPTER_PL        = <repo>/vendor/mediaremote-adapter/bin/mediaremote-adapter.pl
ADAPTER_FRAMEWORK = <repo>/vendor/mediaremote-adapter/.build/MediaRemoteAdapter.framework
```

**Команды:** `/usr/bin/perl $ADAPTER_PL $ADAPTER_FRAMEWORK <get|stream|send N>`

**Коды `send`:** `0` — play (идемпотентна), `1` — pause (идемпотентна), `2` — toggle.

**Формат потока:** строки `{"type":"data","diff":<bool>,"payload":{…}}`.
Первая строка после подключения — служебная, `diff:false` с **пустым** payload.
Вторая — полный снимок, `diff:false` с заполненным. Дальше только диффы.

**Поля payload:** `title`, `artist`, `album`, `duration`, `elapsedTime`,
`timestamp` (строка ISO 8601), `playbackRate`, `playing`, `bundleIdentifier`,
`processIdentifier`, `artworkData` (base64), `artworkMimeType`,
`contentItemIdentifier`.

**Три ловушки, найденные спайком:**

1. `elapsedTime` и `timestamp` — снимок на момент события, а **не тикающее
   значение**. Живая позиция считается как
   `elapsedTime + (now - timestamp) * playbackRate`.
2. `contentItemIdentifier` меняется почти на каждое обновление — это токен
   снимка, **не идентификатор трека**. Не использовать как ключ.
3. `get` иногда возвращает текст `Reading now playing information timed out
   after 2000 milliseconds` вместо JSON. Это не отказ канала, а временная
   осечка, которую надо пережить, а не считать падением.

**MediaRemote отдаёт только одну активную сессию**, а не список источников.
Если пользователь слушает в двух приложениях, придёт то, что система считает
текущим now-playing.

**Завершение:** адаптер перехватывает `SIGINT` и выходит чисто, код 0, меньше
секунды. Убивать `SIGKILL` не нужно.

---

### Task 1: Модель снимка и разбор строки адаптера

**Files:**
- Create: `Packages/NotchKit/Sources/MediaBridge/NowPlayingSnapshot.swift`
- Create: `Packages/NotchKit/Sources/MediaBridge/AdapterLine.swift`
- Modify: `Packages/NotchKit/Package.swift` — объявить таргеты `MediaBridge` и `MediaBridgeTests`
- Test: `Packages/NotchKit/Tests/MediaBridgeTests/AdapterLineTests.swift`

**Interfaces:**
- Consumes: ничего
- Produces:
  - `NowPlayingSnapshot` с полями `title`, `artist`, `album`, `duration`,
    `elapsedTime`, `timestamp`, `playbackRate`, `isPlaying`, `sourceBundleID`,
    `artworkData`, `artworkMimeType`
  - `AdapterLine.parse(_ line: String) -> AdapterLine`
  - `enum AdapterLine { case snapshot(NowPlayingSnapshot?), diff(NowPlayingPayload), transientFailure(String), unrecognized(String) }`
  - `NowPlayingPayload` — все поля опциональны, метод `applied(to:) -> NowPlayingSnapshot?`

- [ ] **Step 1: Объявить таргеты и написать падающие тесты**

Добавь в массив `products` файла `Packages/NotchKit/Package.swift`:

```swift
        .library(name: "MediaBridge", targets: ["MediaBridge"]),
```

и в массив `targets`:

```swift
        .target(name: "MediaBridge"),
        .testTarget(name: "MediaBridgeTests", dependencies: ["MediaBridge"]),
```

Создай `Packages/NotchKit/Tests/MediaBridgeTests/AdapterLineTests.swift`:

```swift
import Testing
import Foundation
@testable import MediaBridge

/// Реальный payload из спайка, обложка обрезана.
private let fullPayloadLine = """
{"type":"data","diff":false,"payload":{"playbackRate":1,"album":"","elapsedTime":200.349576,\
"timestamp":"2026-08-10T11:35:25Z","bundleIdentifier":"com.google.Chrome",\
"processIdentifier":59148,"artworkData":"/9j/4AAQSkZJRg==","title":"Deep Work Music",\
"artworkMimeType":"image/jpeg","duration":7279.961,"artist":"Deep Idle Room",\
"contentItemIdentifier":"F06E3460-AF16-445A-AF1E-2600F5CA2D5E","playing":true}}
"""

@Test("полный снимок разбирается со всеми полями")
func fullSnapshotParses() throws {
    guard case .snapshot(let snapshot?) = AdapterLine.parse(fullPayloadLine) else {
        Issue.record("ожидался снимок")
        return
    }
    #expect(snapshot.title == "Deep Work Music")
    #expect(snapshot.artist == "Deep Idle Room")
    #expect(snapshot.sourceBundleID == "com.google.Chrome")
    #expect(snapshot.isPlaying == true)
    #expect(snapshot.playbackRate == 1)
    #expect(abs(snapshot.duration - 7279.961) < 0.001)
    #expect(abs(snapshot.elapsedTime - 200.349576) < 0.001)
    #expect(snapshot.artworkData != nil)
}

@Test("служебная первая строка потока значит «ничего не играет»")
func emptySnapshotMeansNoSession() {
    guard case .snapshot(let snapshot) = AdapterLine.parse(#"{"type":"data","diff":false,"payload":{}}"#) else {
        Issue.record("ожидался снимок")
        return
    }
    #expect(snapshot == nil)
}

@Test("дифф разбирается как частичный payload")
func diffParsesAsPartial() throws {
    guard case .diff(let payload) = AdapterLine.parse(#"{"type":"data","diff":true,"payload":{"playing":true}}"#) else {
        Issue.record("ожидался дифф")
        return
    }
    #expect(payload.playing == true)
    #expect(payload.title == nil)
}

@Test("дифф накладывается на снимок, не затирая незаданные поля")
func diffMergesWithoutClobbering() throws {
    guard case .snapshot(let base?) = AdapterLine.parse(fullPayloadLine),
          case .diff(let payload) = AdapterLine.parse(#"{"type":"data","diff":true,"payload":{"playing":false}}"#)
    else {
        Issue.record("подготовка не удалась")
        return
    }
    let merged = try #require(payload.applied(to: base))
    #expect(merged.isPlaying == false)
    #expect(merged.title == "Deep Work Music")
    #expect(merged.sourceBundleID == "com.google.Chrome")
}

@Test("текст таймаута опознаётся как временная осечка, а не как мусор")
func timeoutTextIsTransient() {
    let line = "Reading now playing information timed out after 2000 milliseconds"
    guard case .transientFailure(let text) = AdapterLine.parse(line) else {
        Issue.record("ожидалась временная осечка")
        return
    }
    #expect(text.contains("timed out"))
}

@Test("непонятная строка не роняет разбор")
func garbageIsUnrecognised() {
    guard case .unrecognized = AdapterLine.parse("{не json") else {
        Issue.record("ожидалась неопознанная строка")
        return
    }
}

@Test("пустая строка не считается событием")
func blankLineIsUnrecognised() {
    guard case .unrecognized = AdapterLine.parse("   ") else {
        Issue.record("ожидалась неопознанная строка")
        return
    }
}

@Test("дифф без предшествующего снимка не сочиняет состояние")
func diffBeforeSnapshotIsIgnored() {
    var payload = NowPlayingPayload()
    payload.playing = true
    // Иначе получился бы снимок «играет неизвестно что»: пустое название,
    // нулевая длительность, метка времени в начале эпохи.
    #expect(payload.applied(to: nil) == nil)
}

@Test("валидный JSON со словами про таймаут внутри данных не считается осечкой")
func jsonWithTimeoutInDataIsNotTransientFailure() {
    let line = #"{"type":"data","diff":false,"payload":{"title":"Why my build timed out","playing":true}}"#
    guard case .snapshot(let snapshot?) = AdapterLine.parse(line) else {
        Issue.record("ожидался снимок, а не осечка")
        return
    }
    #expect(snapshot.title == "Why my build timed out")
}
```

- [ ] **Step 2: Запустить тесты и убедиться, что они падают**

Run: `swift test --package-path Packages/NotchKit --filter AdapterLineTests`
Expected: FAIL — `no such module 'MediaBridge'`

- [ ] **Step 3: Написать модель снимка**

Создай `Packages/NotchKit/Sources/MediaBridge/NowPlayingSnapshot.swift`:

```swift
import Foundation

/// Состояние текущего воспроизведения на момент последнего события адаптера.
///
/// `elapsedTime` и `timestamp` намеренно хранятся парой: адаптер отдаёт их
/// как снимок и между событиями не обновляет, поэтому позиция без метки
/// времени бессмысленна. Живой расчёт — в `PlaybackPosition`.
public struct NowPlayingSnapshot: Sendable, Equatable {
    public var title: String
    public var artist: String
    public var album: String
    public var duration: TimeInterval
    public var elapsedTime: TimeInterval
    public var timestamp: Date
    public var playbackRate: Double
    public var isPlaying: Bool
    /// Bundle id приложения-источника: по нему UI показывает, откуда играет.
    public var sourceBundleID: String
    public var artworkData: Data?
    public var artworkMimeType: String?

    public init(
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval,
        elapsedTime: TimeInterval,
        timestamp: Date,
        playbackRate: Double,
        isPlaying: Bool,
        sourceBundleID: String,
        artworkData: Data?,
        artworkMimeType: String?
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.elapsedTime = elapsedTime
        self.timestamp = timestamp
        self.playbackRate = playbackRate
        self.isPlaying = isPlaying
        self.sourceBundleID = sourceBundleID
        self.artworkData = artworkData
        self.artworkMimeType = artworkMimeType
    }
}
```

- [ ] **Step 4: Написать разбор строки**

Создай `Packages/NotchKit/Sources/MediaBridge/AdapterLine.swift`:

```swift
import Foundation

/// Частичный payload: адаптер шлёт диффы, где заданы только изменившиеся поля,
/// поэтому все свойства опциональны и «отсутствует» не равно «сброшено в ноль».
public struct NowPlayingPayload: Sendable, Equatable, Decodable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var duration: TimeInterval?
    public var elapsedTime: TimeInterval?
    public var timestamp: Date?
    public var playbackRate: Double?
    public var playing: Bool?
    public var bundleIdentifier: String?
    public var artworkData: Data?
    public var artworkMimeType: String?

    public init() {}

    /// Пустой payload значит «сессии нет», а не «трек без названия».
    public var isEmpty: Bool {
        title == nil && artist == nil && album == nil && duration == nil
            && elapsedTime == nil && timestamp == nil && playbackRate == nil
            && playing == nil && bundleIdentifier == nil && artworkData == nil
            && artworkMimeType == nil
    }

    /// Накладывает дифф на имеющийся снимок. Возвращает nil, если снимка ещё
    /// не было: дифф сам по себе не описывает трек целиком.
    public func applied(to base: NowPlayingSnapshot?) -> NowPlayingSnapshot? {
        // Без базы возвращаем именно nil, а не сочинённый снимок: дифф вроде
        // {"playing":true} описал бы «играет неизвестно что» с пустым
        // названием и нулевой длительностью. На это опирается аккумулятор
        // из Task 5.
        guard var snapshot = base else { return nil }
        if let title { snapshot.title = title }
        if let artist { snapshot.artist = artist }
        if let album { snapshot.album = album }
        if let duration { snapshot.duration = duration }
        if let elapsedTime { snapshot.elapsedTime = elapsedTime }
        if let timestamp { snapshot.timestamp = timestamp }
        if let playbackRate { snapshot.playbackRate = playbackRate }
        if let playing { snapshot.isPlaying = playing }
        if let bundleIdentifier { snapshot.sourceBundleID = bundleIdentifier }
        if let artworkData { snapshot.artworkData = artworkData }
        if let artworkMimeType { snapshot.artworkMimeType = artworkMimeType }
        return snapshot
    }

    /// Полный снимок из payload. Недостающие поля заполняются нейтрально:
    /// адаптер опускает пустые строки и нулевые длительности.
    public func asSnapshot() -> NowPlayingSnapshot? {
        guard !isEmpty else { return nil }
        return NowPlayingSnapshot(
            title: title ?? "",
            artist: artist ?? "",
            album: album ?? "",
            duration: duration ?? 0,
            elapsedTime: elapsedTime ?? 0,
            timestamp: timestamp ?? Date(timeIntervalSince1970: 0),
            playbackRate: playbackRate ?? 0,
            isPlaying: playing ?? false,
            sourceBundleID: bundleIdentifier ?? "",
            artworkData: artworkData,
            artworkMimeType: artworkMimeType
        )
    }
}

/// Одна строка вывода адаптера.
public enum AdapterLine: Sendable, Equatable {
    /// Полное состояние. nil значит «сессии нет».
    case snapshot(NowPlayingSnapshot?)
    case diff(NowPlayingPayload)
    /// Адаптер жив, но конкретный ответ не получился — канал ронять не надо.
    case transientFailure(String)
    case unrecognized(String)

    private struct Envelope: Decodable {
        let type: String
        let diff: Bool
        let payload: NowPlayingPayload
    }

    /// Известный текст осечки адаптера. Сверяется только с тем, что не
    /// разобралось как JSON: подстрока «timed out» вполне может встретиться
    /// в названии трека, и такую строку нельзя терять как сбой канала.
    private static let adapterTimeoutMessage = "timed out"

    public static func parse(_ line: String) -> AdapterLine {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unrecognized(line) }
        guard let data = trimmed.data(using: .utf8) else { return .unrecognized(line) }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // Разбор JSON идёт первым: валидная строка потока — это данные,
        // что бы ни встретилось внутри её текстовых полей.
        if let envelope = try? decoder.decode(Envelope.self, from: data) {
            return envelope.diff ? .diff(envelope.payload) : .snapshot(envelope.payload.asSnapshot())
        }

        // Осечку адаптер печатает открытым текстом, не JSON-ом. Отличать её
        // от мусора важно: супервизор не должен считать это падением канала.
        if trimmed.contains(adapterTimeoutMessage) { return .transientFailure(trimmed) }

        return .unrecognized(line)
    }
}
```

Замечание про `artworkData`: адаптер отдаёт base64-строку, а `Data` в Swift
декодируется из base64 автоматически при `Decodable` — дополнительного шага
не требуется. Если тест на обложку упадёт, проверь это в первую очередь.

- [ ] **Step 5: Запустить тесты и убедиться, что они проходят**

Run: `swift test --package-path Packages/NotchKit --filter AdapterLineTests`
Expected: PASS, 9 тестов

- [ ] **Step 6: Прогнать полный пакет и закоммитить**

Run: `swift test --package-path Packages/NotchKit`
Expected: PASS, 43 теста (34 фундамента + 9 новых)

```bash
git add Packages/NotchKit
git commit -m "feat: модель снимка и разбор строк адаптера"
```

---

### Task 2: Живая позиция воспроизведения

Спайк показал: `elapsedTime` между событиями не растёт. Без этой задачи
прогресс-бар будет стоять на месте, пока не сменится трек.

**Files:**
- Create: `Packages/NotchKit/Sources/MediaBridge/PlaybackPosition.swift`
- Test: `Packages/NotchKit/Tests/MediaBridgeTests/PlaybackPositionTests.swift`

**Interfaces:**
- Consumes: `NowPlayingSnapshot` из Task 1
- Produces: `PlaybackPosition.current(in: NowPlayingSnapshot, at: Date) -> TimeInterval`

- [ ] **Step 1: Написать падающие тесты**

Создай `Packages/NotchKit/Tests/MediaBridgeTests/PlaybackPositionTests.swift`:

```swift
import Testing
import Foundation
@testable import MediaBridge

private let t0 = Date(timeIntervalSince1970: 1_000_000)

private func snapshot(
    elapsed: TimeInterval,
    rate: Double,
    playing: Bool,
    duration: TimeInterval = 300
) -> NowPlayingSnapshot {
    NowPlayingSnapshot(
        title: "t", artist: "a", album: "", duration: duration,
        elapsedTime: elapsed, timestamp: t0, playbackRate: rate,
        isPlaying: playing, sourceBundleID: "com.example",
        artworkData: nil, artworkMimeType: nil
    )
}

@Test("на паузе позиция не растёт со временем")
func pausedPositionIsFrozen() {
    let paused = snapshot(elapsed: 42, rate: 0, playing: false)
    #expect(PlaybackPosition.current(in: paused, at: t0.addingTimeInterval(30)) == 42)
}

@Test("при воспроизведении позиция растёт от метки времени")
func playingPositionAdvances() {
    let playing = snapshot(elapsed: 42, rate: 1, playing: true)
    let position = PlaybackPosition.current(in: playing, at: t0.addingTimeInterval(10))
    #expect(abs(position - 52) < 0.001)
}

@Test("ускоренное воспроизведение учитывает темп")
func rateIsApplied() {
    let fast = snapshot(elapsed: 100, rate: 1.5, playing: true)
    let position = PlaybackPosition.current(in: fast, at: t0.addingTimeInterval(10))
    #expect(abs(position - 115) < 0.001)
}

@Test("позиция не выходит за длительность трека")
func positionIsClampedToDuration() {
    let nearEnd = snapshot(elapsed: 295, rate: 1, playing: true, duration: 300)
    #expect(PlaybackPosition.current(in: nearEnd, at: t0.addingTimeInterval(60)) == 300)
}

@Test("отрицательное время не появляется при часах, отставших от метки")
func positionNeverGoesNegative() {
    let playing = snapshot(elapsed: 5, rate: 1, playing: true)
    #expect(PlaybackPosition.current(in: playing, at: t0.addingTimeInterval(-30)) == 0)
}

@Test("нулевая длительность не ограничивает позицию")
func zeroDurationDoesNotClamp() {
    let live = snapshot(elapsed: 10, rate: 1, playing: true, duration: 0)
    let position = PlaybackPosition.current(in: live, at: t0.addingTimeInterval(20))
    #expect(abs(position - 30) < 0.001)
}
```

- [ ] **Step 2: Запустить тесты и убедиться, что они падают**

Run: `swift test --package-path Packages/NotchKit --filter PlaybackPositionTests`
Expected: FAIL — `cannot find 'PlaybackPosition' in scope`

- [ ] **Step 3: Написать реализацию**

Создай `Packages/NotchKit/Sources/MediaBridge/PlaybackPosition.swift`:

```swift
import Foundation

/// Позиция воспроизведения на произвольный момент времени.
///
/// Существует потому, что адаптер отдаёт `elapsedTime` снимком и между
/// событиями его не обновляет: читать поле напрямую значит показывать
/// застывший прогресс-бар, пока не сменится трек.
public enum PlaybackPosition {
    public static func current(in snapshot: NowPlayingSnapshot, at now: Date) -> TimeInterval {
        // На паузе метка времени устаревает произвольно долго, поэтому
        // экстраполировать от неё нельзя — позиция просто замерла.
        guard snapshot.isPlaying else { return snapshot.elapsedTime }

        let drift = now.timeIntervalSince(snapshot.timestamp) * snapshot.playbackRate
        let raw = snapshot.elapsedTime + drift
        // Нулевая длительность значит «поток без конца» (радио, стрим),
        // ограничивать там нечем.
        let upperBound = snapshot.duration > 0 ? snapshot.duration : .greatestFiniteMagnitude
        return min(max(raw, 0), upperBound)
    }
}
```

- [ ] **Step 4: Запустить тесты и убедиться, что они проходят**

Run: `swift test --package-path Packages/NotchKit --filter PlaybackPositionTests`
Expected: PASS, 6 тестов

- [ ] **Step 5: Закоммитить**

```bash
git add Packages/NotchKit
git commit -m "feat: вычисление живой позиции воспроизведения"
```

---

### Task 3: Политика перезапуска адаптера

Отдельно от процесса, потому что здесь живёт решение «когда пробовать снова»,
и его надо проверять без запуска perl.

**Files:**
- Create: `Packages/NotchKit/Sources/MediaBridge/RestartPolicy.swift`
- Test: `Packages/NotchKit/Tests/MediaBridgeTests/RestartPolicyTests.swift`

**Interfaces:**
- Consumes: ничего
- Produces:
  - `RestartPolicy` с `mutating func nextDelay() -> TimeInterval` и `mutating func reset()`
  - Константы `RestartPolicy.initialDelay = 1`, `.maxDelay = 30`

- [ ] **Step 1: Написать падающие тесты**

Создай `Packages/NotchKit/Tests/MediaBridgeTests/RestartPolicyTests.swift`:

```swift
import Testing
@testable import MediaBridge

@Test("паузы удваиваются от одной секунды")
func delaysDouble() {
    var policy = RestartPolicy()
    #expect(policy.nextDelay() == 1)
    #expect(policy.nextDelay() == 2)
    #expect(policy.nextDelay() == 4)
    #expect(policy.nextDelay() == 8)
}

@Test("пауза упирается в потолок и дальше не растёт")
func delayIsCapped() {
    var policy = RestartPolicy()
    for _ in 0..<10 { _ = policy.nextDelay() }
    #expect(policy.nextDelay() == 30)
    #expect(policy.nextDelay() == 30)
}

@Test("успешное подключение сбрасывает паузу")
func successResetsDelay() {
    var policy = RestartPolicy()
    _ = policy.nextDelay()
    _ = policy.nextDelay()
    policy.reset()
    #expect(policy.nextDelay() == 1)
}
```

- [ ] **Step 2: Запустить тесты и убедиться, что они падают**

Run: `swift test --package-path Packages/NotchKit --filter RestartPolicyTests`
Expected: FAIL — `cannot find 'RestartPolicy' in scope`

- [ ] **Step 3: Написать реализацию**

Создай `Packages/NotchKit/Sources/MediaBridge/RestartPolicy.swift`:

```swift
import Foundation

/// Нарастающие паузы между попытками поднять адаптер.
///
/// Потолок в 30 секунд выбран так, чтобы упавший навсегда адаптер не жёг
/// батарею перезапусками, но и не заставлял ждать минутами после того, как
/// причина отказа ушла.
public struct RestartPolicy: Sendable {
    public static let initialDelay: TimeInterval = 1
    public static let maxDelay: TimeInterval = 30

    private var attempt = 0

    public init() {}

    public mutating func nextDelay() -> TimeInterval {
        let delay = min(Self.initialDelay * pow(2, Double(attempt)), Self.maxDelay)
        attempt += 1
        return delay
    }

    /// Вызывается, когда поток снова заработал: следующий отказ начнёт
    /// отсчёт заново, а не продолжит с накопленного потолка.
    public mutating func reset() {
        attempt = 0
    }
}
```

- [ ] **Step 4: Запустить тесты и убедиться, что они проходят**

Run: `swift test --package-path Packages/NotchKit --filter RestartPolicyTests`
Expected: PASS, 3 теста

- [ ] **Step 5: Закоммитить**

```bash
git add Packages/NotchKit
git commit -m "feat: политика перезапуска адаптера с нарастающими паузами"
```

---

### Task 4: Процесс адаптера

Первая задача плана, где появляется живой сторонний процесс. Юнит-тестами
не покрывается — проверяется интеграционно и вручную.

**Files:**
- Create: `Packages/NotchKit/Sources/MediaBridge/AdapterPaths.swift`
- Create: `Packages/NotchKit/Sources/MediaBridge/AdapterProcess.swift`
- Test: `Packages/NotchKit/Tests/MediaBridgeTests/AdapterProcessIntegrationTests.swift`

**Interfaces:**
- Consumes: `AdapterLine` из Task 1
- Produces:
  - `AdapterPaths(perl:script:framework:)`, статический `AdapterPaths.vendored(repoRoot:)`,
    свойство `existsOnDisk`
  - `actor AdapterProcess` с `func lines() -> AsyncStream<AdapterLine>`,
    `func send(code: Int32) async throws`, `func stop()`

- [ ] **Step 1: Написать пути**

Создай `Packages/NotchKit/Sources/MediaBridge/AdapterPaths.swift`:

```swift
import Foundation

/// Пути к вендоренному адаптеру.
///
/// Все обязаны быть абсолютными: спайк показал, что с относительным путём
/// бридж падает с `Failed to load framework` — он резолвит фреймворк изнутри
/// собственного процесса и ничего не знает о рабочем каталоге вызывающего.
public struct AdapterPaths: Sendable, Equatable {
    public let perl: URL
    public let script: URL
    public let framework: URL

    public init(perl: URL, script: URL, framework: URL) {
        self.perl = perl
        self.script = script
        self.framework = framework
    }

    /// Раскладка вендоренной копии в репозитории.
    public static func vendored(repoRoot: URL) -> AdapterPaths {
        AdapterPaths(
            perl: URL(fileURLWithPath: "/usr/bin/perl"),
            script: repoRoot.appending(path: "vendor/mediaremote-adapter/bin/mediaremote-adapter.pl"),
            framework: repoRoot.appending(path: "vendor/mediaremote-adapter/.build/MediaRemoteAdapter.framework")
        )
    }

    public var existsOnDisk: Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: perl.path)
            && fm.fileExists(atPath: script.path)
            && fm.fileExists(atPath: framework.path)
    }
}
```

- [ ] **Step 2: Написать процесс**

Создай `Packages/NotchKit/Sources/MediaBridge/AdapterProcess.swift`:

```swift
import Foundation
import os

/// Долгоживущий `stream`-процесс адаптера и разовые команды к нему.
///
/// Актор, а не класс: чтение stdout идёт в фоне, а `send` может прийти из UI,
/// и состояние процесса нельзя трогать с двух сторон одновременно.
public actor AdapterProcess {
    private let paths: AdapterPaths
    private let logger = Logger(subsystem: "kz.mobilefirst.notchka", category: "adapter")
    private var streamProcess: Process?

    public init(paths: AdapterPaths) {
        self.paths = paths
    }

    /// Поток разобранных строк. Завершается, когда процесс умирает —
    /// перезапуском занимается провайдер из Task 5, не этот тип.
    public func lines() -> AsyncStream<AdapterLine> {
        AsyncStream { continuation in
            let process = Process()
            process.executableURL = paths.perl
            process.arguments = [paths.script.path, paths.framework.path, "stream"]

            let pipe = Pipe()
            process.standardOutput = pipe
            // stderr адаптера нам не нужен, но и в консоль его лить незачем.
            process.standardError = FileHandle.nullDevice

            // Буфер нужен, потому что чтение приходит кусками, а не строками:
            // одна строка может прийти разорванной между двумя срабатываниями.
            let buffer = LineBuffer()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                for line in buffer.take(handle.availableData) {
                    continuation.yield(AdapterLine.parse(line))
                }
            }

            process.terminationHandler = { _ in
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.finish()
            }

            do {
                try process.run()
                streamProcess = process
            } catch {
                logger.error("не удалось запустить адаптер: \(error.localizedDescription, privacy: .public)")
                continuation.finish()
                return
            }

            continuation.onTermination = { _ in
                Task { await self.stop() }
            }
        }
    }

    /// Разовая команда управления. Отдельный короткоживущий процесс —
    /// у `stream` нет входного канала для команд.
    public func send(code: Int32) async throws {
        let process = Process()
        process.executableURL = paths.perl
        process.arguments = [paths.script.path, paths.framework.path, "send", String(code)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    /// Останавливает поток. SIGINT, а не SIGKILL: спайк подтвердил, что
    /// адаптер перехватывает его и выходит чисто меньше чем за секунду.
    public func stop() {
        guard let process = streamProcess, process.isRunning else { return }
        process.interrupt()
        streamProcess = nil
    }
}

/// Накопитель байтов, отдающий целые строки.
///
/// Отдельный тип, потому что обработчик `readabilityHandler` вызывается
/// с произвольного потока и не может владеть изменяемым состоянием актора.
private final class LineBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func take(_ chunk: Data) -> [String] {
        guard !chunk.isEmpty else { return [] }
        lock.lock()
        defer { lock.unlock() }

        data.append(chunk)
        var lines: [String] = []
        while let newline = data.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = data[data.startIndex..<newline]
            data.removeSubrange(data.startIndex...newline)
            if let line = String(data: lineData, encoding: .utf8) { lines.append(line) }
        }
        return lines
    }
}
```

- [ ] **Step 3: Написать интеграционный тест, пропускаемый без адаптера**

Создай `Packages/NotchKit/Tests/MediaBridgeTests/AdapterProcessIntegrationTests.swift`:

```swift
import Testing
import Foundation
@testable import MediaBridge

/// Корень репозитория относительно файла теста.
private var repoRoot: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // MediaBridgeTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // NotchKit
        .deletingLastPathComponent()  // Packages
}

@Test("пути к вендоренному адаптеру абсолютны")
func vendoredPathsAreAbsolute() {
    let paths = AdapterPaths.vendored(repoRoot: repoRoot)
    #expect(paths.script.path.hasPrefix("/"))
    #expect(paths.framework.path.hasPrefix("/"))
    #expect(paths.perl.path == "/usr/bin/perl")
}

/// Требует собранного фреймворка. Пропускается, если его нет: собирать
/// адаптер ради теста незачем, а на машине разработчика он уже есть.
@Test("поток адаптера отдаёт хотя бы одну разобранную строку")
func streamYieldsParsedLine() async throws {
    let paths = AdapterPaths.vendored(repoRoot: repoRoot)
    try #require(paths.existsOnDisk, "адаптер не собран, тест пропущен")

    let adapter = AdapterProcess(paths: paths)
    var received: AdapterLine?
    for await line in await adapter.lines() {
        received = line
        break
    }
    await adapter.stop()
    #expect(received != nil)
}
```

- [ ] **Step 4: Прогнать тесты**

Run: `swift test --package-path Packages/NotchKit --filter AdapterProcess`
Expected: PASS, 2 теста. Второй проходит, если фреймворк собран; если нет —
`#require` пропускает его с сообщением, а не роняет прогон.

Если фреймворк не собран, собери его по заметке спайка:

```bash
cd vendor/mediaremote-adapter && cmake -S . -B .build -DCMAKE_BUILD_TYPE=Release && cmake --build .build && cd -
```

- [ ] **Step 5: Ручная проверка команд**

Включи музыку в браузере и выполни из корня репозитория:

```bash
ADAPTER_PL="$PWD/vendor/mediaremote-adapter/bin/mediaremote-adapter.pl"
ADAPTER_FRAMEWORK="$PWD/vendor/mediaremote-adapter/.build/MediaRemoteAdapter.framework"
/usr/bin/perl "$ADAPTER_PL" "$ADAPTER_FRAMEWORK" get
```

Убедись, что `bundleIdentifier` соответствует источнику. Это проверка среды,
а не кода: если здесь пусто, дальше отлаживать нечего.

- [ ] **Step 6: Закоммитить**

```bash
git add Packages/NotchKit
git commit -m "feat: процесс адаптера и пути к вендоренной копии"
```

---

### Task 5: Провайдер и склейка снимков

**Files:**
- Create: `Packages/NotchKit/Sources/MediaBridge/MediaCommand.swift`
- Create: `Packages/NotchKit/Sources/MediaBridge/NowPlayingProvider.swift`
- Create: `Packages/NotchKit/Sources/MediaBridge/AdapterProvider.swift`
- Test: `Packages/NotchKit/Tests/MediaBridgeTests/AdapterProviderTests.swift`

**Interfaces:**
- Consumes: `AdapterProcess`, `AdapterLine`, `RestartPolicy`
- Produces:
  - `enum MediaCommand { case play, pause, toggle }` со свойством `adapterCode`
  - `protocol NowPlayingProvider: Sendable` с `var snapshots: AsyncStream<NowPlayingSnapshot?> { get async }`
    и `func send(_ command: MediaCommand) async throws`
  - `SnapshotAccumulator` — склейка снимков и диффов, чистая и тестируемая
  - `actor AdapterProvider: NowPlayingProvider`

- [ ] **Step 1: Написать падающие тесты**

Создай `Packages/NotchKit/Tests/MediaBridgeTests/AdapterProviderTests.swift`:

```swift
import Testing
import Foundation
@testable import MediaBridge

private let base = NowPlayingSnapshot(
    title: "Sweet Dreams", artist: "Eurythmics", album: "", duration: 216,
    elapsedTime: 10, timestamp: Date(timeIntervalSince1970: 1_000_000),
    playbackRate: 1, isPlaying: true, sourceBundleID: "com.google.Chrome",
    artworkData: nil, artworkMimeType: nil
)

@Test("коды команд совпадают с проверенными спайком")
func commandCodesMatchSpike() {
    #expect(MediaCommand.play.adapterCode == 0)
    #expect(MediaCommand.pause.adapterCode == 1)
    #expect(MediaCommand.toggle.adapterCode == 2)
}

@Test("снимок заменяет состояние целиком")
func snapshotReplacesState() {
    var accumulator = SnapshotAccumulator()
    #expect(accumulator.apply(.snapshot(base)) == base)
}

@Test("дифф правит только заданные поля")
func diffPatchesState() {
    var accumulator = SnapshotAccumulator()
    _ = accumulator.apply(.snapshot(base))
    var payload = NowPlayingPayload()
    payload.playing = false
    let updated = accumulator.apply(.diff(payload))
    #expect(updated?.isPlaying == false)
    #expect(updated?.title == "Sweet Dreams")
}

@Test("дифф до первого снимка не выдумывает состояние")
func diffBeforeSnapshotIsIgnored() {
    var accumulator = SnapshotAccumulator()
    var payload = NowPlayingPayload()
    payload.playing = true
    #expect(accumulator.apply(.diff(payload)) == nil)
}

@Test("пустой снимок означает конец сессии")
func emptySnapshotClearsState() {
    var accumulator = SnapshotAccumulator()
    _ = accumulator.apply(.snapshot(base))
    #expect(accumulator.apply(.snapshot(nil)) == nil)
    #expect(accumulator.current == nil)
}

@Test("временная осечка не стирает последний известный трек")
func transientFailureKeepsState() {
    var accumulator = SnapshotAccumulator()
    _ = accumulator.apply(.snapshot(base))
    #expect(accumulator.apply(.transientFailure("timed out")) == base)
    #expect(accumulator.current == base)
}

@Test("неопознанная строка не меняет состояние")
func unrecognisedLineKeepsState() {
    var accumulator = SnapshotAccumulator()
    _ = accumulator.apply(.snapshot(base))
    #expect(accumulator.apply(.unrecognized("шум")) == base)
}
```

- [ ] **Step 2: Запустить тесты и убедиться, что они падают**

Run: `swift test --package-path Packages/NotchKit --filter AdapterProviderTests`
Expected: FAIL — `cannot find 'MediaCommand' in scope`

- [ ] **Step 3: Написать команды**

Создай `Packages/NotchKit/Sources/MediaBridge/MediaCommand.swift`:

```swift
/// Команда управления воспроизведением.
///
/// Коды подтверждены спайком эмпирически, а не взяты из заголовка фреймворка:
/// `play` и `pause` идемпотентны, `toggle` инвертирует состояние на каждый вызов.
public enum MediaCommand: Sendable, Equatable {
    case play
    case pause
    case toggle

    public var adapterCode: Int32 {
        switch self {
        case .play: 0
        case .pause: 1
        case .toggle: 2
        }
    }
}
```

- [ ] **Step 4: Написать протокол и склейку**

Создай `Packages/NotchKit/Sources/MediaBridge/NowPlayingProvider.swift`:

```swift
import Foundation

/// Источник сведений о текущем воспроизведении.
///
/// Протокол существует ради риска, названного в спеке главным: MediaRemote
/// закрыт приватным entitlement, и если perl-обход перестанет работать,
/// вторая реализация напишется на браузерном расширении, а UI не изменится.
public protocol NowPlayingProvider: Sendable {
    /// nil в потоке значит «сейчас ничего не играет».
    var snapshots: AsyncStream<NowPlayingSnapshot?> { get async }
    func send(_ command: MediaCommand) async throws
}

/// Склейка потока адаптера в текущее состояние.
///
/// Отдельно от процесса, потому что здесь вся логика «что делать со строкой»,
/// и её надо проверять без запуска perl.
public struct SnapshotAccumulator: Sendable {
    public private(set) var current: NowPlayingSnapshot?

    public init() {}

    /// Возвращает состояние после применения строки.
    @discardableResult
    public mutating func apply(_ line: AdapterLine) -> NowPlayingSnapshot? {
        switch line {
        case .snapshot(let snapshot):
            current = snapshot
        case .diff(let payload):
            // Дифф до первого снимка описывает изменение неизвестно чего —
            // выдумывать по нему трек нельзя.
            current = payload.applied(to: current)
        case .transientFailure, .unrecognized:
            // Канал жив, конкретная строка бесполезна. Последний известный
            // трек остаётся на экране: гасить его было бы враньём наоборот.
            break
        }
        return current
    }
}
```

- [ ] **Step 5: Написать провайдер**

Создай `Packages/NotchKit/Sources/MediaBridge/AdapterProvider.swift`:

```swift
import Foundation
import os

/// Провайдер поверх perl-адаптера: держит поток живым и склеивает строки.
public actor AdapterProvider: NowPlayingProvider {
    private let paths: AdapterPaths
    private let logger = Logger(subsystem: "kz.mobilefirst.notchka", category: "media")
    private var process: AdapterProcess?

    public init(paths: AdapterPaths) {
        self.paths = paths
    }

    public var snapshots: AsyncStream<NowPlayingSnapshot?> {
        get async {
            AsyncStream { continuation in
                let task = Task { await self.pump(into: continuation) }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    public func send(_ command: MediaCommand) async throws {
        let adapter = process ?? AdapterProcess(paths: paths)
        process = adapter
        try await adapter.send(code: command.adapterCode)
    }

    /// Поднимает поток, склеивает строки и переподнимает его при обрыве.
    private func pump(into continuation: AsyncStream<NowPlayingSnapshot?>.Continuation) async {
        var policy = RestartPolicy()
        var accumulator = SnapshotAccumulator()

        while !Task.isCancelled {
            let adapter = AdapterProcess(paths: paths)
            process = adapter
            var sawAnything = false

            for await line in await adapter.lines() {
                sawAnything = true
                continuation.yield(accumulator.apply(line))
            }

            guard !Task.isCancelled else { break }

            // Поток, проживший достаточно, чтобы что-то отдать, считается
            // рабочим: следующий обрыв начнёт отсчёт пауз заново.
            if sawAnything { policy.reset() }
            let delay = policy.nextDelay()
            logger.notice("поток адаптера оборван, повтор через \(delay, privacy: .public) с")
            try? await Task.sleep(for: .seconds(delay))
        }

        await process?.stop()
        continuation.finish()
    }
}
```

- [ ] **Step 6: Запустить тесты и убедиться, что они проходят**

Run: `swift test --package-path Packages/NotchKit --filter AdapterProviderTests`
Expected: PASS, 7 тестов

- [ ] **Step 7: Прогнать полный пакет и закоммитить**

Run: `swift test --package-path Packages/NotchKit`
Expected: PASS, 61 тест

```bash
git add Packages/NotchKit
git commit -m "feat: провайдер поверх адаптера со склейкой снимков и перезапуском"
```

---

### Task 6: Акцентный цвет из обложки

**Files:**
- Create: `Packages/NotchKit/Sources/NotchUI/ArtworkAccent.swift`
- Test: `Packages/NotchKit/Tests/NotchUITests/ArtworkAccentTests.swift`

**Interfaces:**
- Consumes: ничего (принимает `CGImage`)
- Produces:
  - `ArtworkAccent.color(from: CGImage) -> Color?`
  - `ArtworkAccent.hsb(from: CGImage) -> (h: Double, s: Double, b: Double)?`
  - `ArtworkAccent.readable(_:) -> (h: Double, s: Double, b: Double)`
  - Константы `minBrightness = 0.55`, `minSaturation = 0.35`

- [ ] **Step 1: Написать падающие тесты**

Проверяем не точный RGB — он зависит от версии CoreGraphics, — а свойство,
ради которого всё делается: цвет обязан читаться на чёрном.

Создай `Packages/NotchKit/Tests/NotchUITests/ArtworkAccentTests.swift`:

```swift
import Testing
import CoreGraphics
@testable import NotchUI

/// Одноцветная картинка 8×8 заданного цвета.
private func solidImage(red: Double, green: Double, blue: Double) -> CGImage {
    let width = 8, height = 8
    let space = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

@Test("тусклый цвет поднимается до читаемого на чёрном")
func dimColourIsBrightened() {
    let corrected = ArtworkAccent.readable((h: 0.6, s: 0.5, b: 0.05))
    #expect(corrected.b >= ArtworkAccent.minBrightness)
}

@Test("блёклый цвет получает насыщенность, иначе сольётся с серым")
func washedColourGainsSaturation() {
    let corrected = ArtworkAccent.readable((h: 0.1, s: 0.02, b: 0.8))
    #expect(corrected.s >= ArtworkAccent.minSaturation)
}

@Test("уже читаемый цвет не искажается")
func readableColourIsLeftAlone() {
    let input = (h: 0.9, s: 0.7, b: 0.8)
    let corrected = ArtworkAccent.readable(input)
    #expect(abs(corrected.h - input.h) < 0.0001)
    #expect(abs(corrected.s - input.s) < 0.0001)
    #expect(abs(corrected.b - input.b) < 0.0001)
}

@Test("оттенок сохраняется при коррекции — цвет остаётся «тем же»")
func hueSurvivesCorrection() {
    let corrected = ArtworkAccent.readable((h: 0.33, s: 0.01, b: 0.02))
    #expect(abs(corrected.h - 0.33) < 0.0001)
}

@Test("из одноцветной обложки извлекается цвет")
func solidArtworkYieldsColour() {
    #expect(ArtworkAccent.color(from: solidImage(red: 0.9, green: 0.2, blue: 0.5)) != nil)
}

@Test("чёрная обложка тоже даёт читаемый цвет, а не чёрный на чёрном")
func blackArtworkStillReadable() throws {
    let colour = try #require(ArtworkAccent.hsb(from: solidImage(red: 0, green: 0, blue: 0)))
    let corrected = ArtworkAccent.readable(colour)
    #expect(corrected.b >= ArtworkAccent.minBrightness)
}
```

- [ ] **Step 2: Запустить тесты и убедиться, что они падают**

Run: `swift test --package-path Packages/NotchKit --filter ArtworkAccentTests`
Expected: FAIL — `cannot find 'ArtworkAccent' in scope`

- [ ] **Step 3: Написать реализацию**

Создай `Packages/NotchKit/Sources/NotchUI/ArtworkAccent.swift`:

```swift
import SwiftUI
import CoreGraphics

/// Акцентный цвет, вытянутый из обложки.
///
/// Панель чёрная, поэтому «средний цвет картинки» не годится: тёмная или
/// блёклая обложка дала бы акцент, неотличимый от фона. Оттенок берётся из
/// обложки, а яркость и насыщенность зажимаются в диапазон, где цвет
/// гарантированно виден на чёрном.
public enum ArtworkAccent {
    public static let minBrightness: Double = 0.55
    public static let minSaturation: Double = 0.35

    public static func color(from image: CGImage) -> Color? {
        guard let hsb = hsb(from: image) else { return nil }
        let corrected = readable(hsb)
        return Color(hue: corrected.h, saturation: corrected.s, brightness: corrected.b)
    }

    /// Средний цвет картинки в HSB. Усреднение отрисовкой в 1×1 — самый
    /// дешёвый способ; точности «на глаз» для акцента достаточно.
    public static func hsb(from image: CGImage) -> (h: Double, s: Double, b: Double)? {
        var pixel = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return rgbToHSB(
            r: Double(pixel[0]) / 255,
            g: Double(pixel[1]) / 255,
            b: Double(pixel[2]) / 255
        )
    }

    /// Поднимает яркость и насыщенность до порогов читаемости, не трогая оттенок.
    public static func readable(
        _ hsb: (h: Double, s: Double, b: Double)
    ) -> (h: Double, s: Double, b: Double) {
        (h: hsb.h, s: max(hsb.s, minSaturation), b: max(hsb.b, minBrightness))
    }

    private static func rgbToHSB(r: Double, g: Double, b: Double) -> (h: Double, s: Double, b: Double) {
        let maxValue = max(r, g, b)
        let minValue = min(r, g, b)
        let delta = maxValue - minValue

        var hue: Double = 0
        if delta > 0 {
            switch maxValue {
            case r: hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            case g: hue = (b - r) / delta + 2
            default: hue = (r - g) / delta + 4
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        let saturation = maxValue > 0 ? delta / maxValue : 0
        return (h: hue, s: saturation, b: maxValue)
    }
}
```

- [ ] **Step 4: Запустить тесты и убедиться, что они проходят**

Run: `swift test --package-path Packages/NotchKit --filter ArtworkAccentTests`
Expected: PASS, 6 тестов

- [ ] **Step 5: Закоммитить**

```bash
git add Packages/NotchKit
git commit -m "feat: акцентный цвет из обложки с гарантией читаемости на чёрном"
```

---

### Task 7: Оболочка панели с вкладками

Отладочная вьюха фундамента заменяется настоящей. Здесь же закрывается долг
про `usesMorph`, оставленный планом 1.

**Files:**
- Create: `Packages/NotchKit/Sources/NotchUI/PanelMetrics.swift`
- Create: `Packages/NotchKit/Sources/NotchUI/NotchPanelView.swift`
- Modify: `App/AppDelegate.swift` — убрать `DebugNotchView`, подключить `NotchPanelView`
- Test: `Packages/NotchKit/Tests/NotchUITests/PanelMetricsTests.swift`

**Interfaces:**
- Consumes: `NotchState`, `NotchTab`, `NotchShape`, `NotchMotion`
- Produces:
  - `PanelMetrics.size(for:notch:)`, `.bottomRadius(for:)`, `.windowSize`, `.concaveRadius`
  - `NotchPanelView(state:notchSize:accent:content:)`

- [ ] **Step 1: Написать падающие тесты размеров**

Размеры панели переезжают из магических литералов отладочной вьюхи в
именованное место — заодно становятся проверяемыми.

Создай `Packages/NotchKit/Tests/NotchUITests/PanelMetricsTests.swift`:

```swift
import Testing
import CoreGraphics
import NotchCore
@testable import NotchUI

private let notch = CGSize(width: 200, height: 32)

@Test("в покое панель ровно по вырезу")
func closedMatchesNotch() {
    #expect(PanelMetrics.size(for: .closed, notch: notch) == notch)
}

@Test("peek шире и выше выреза")
func peekIsLarger() {
    let size = PanelMetrics.size(for: .peek(.hover), notch: notch)
    #expect(size.width > notch.width)
    #expect(size.height > notch.height)
}

@Test("разворот больше peek")
func expandedIsLargerThanPeek() {
    let peek = PanelMetrics.size(for: .peek(.hover), notch: notch)
    let expanded = PanelMetrics.size(for: .expanded(.music), notch: notch)
    #expect(expanded.width > peek.width)
    #expect(expanded.height > peek.height)
}

@Test("разворот одинаков для всех вкладок — панель не прыгает при переключении")
func expandedSizeIsTabIndependent() {
    let sizes = NotchTab.allCases.map { PanelMetrics.size(for: .expanded($0), notch: notch) }
    #expect(Set(sizes.map(\.width)).count == 1)
    #expect(Set(sizes.map(\.height)).count == 1)
}

@Test("разворот помещается в окно с запасом на вогнутые уши")
func expandedFitsWindow() {
    let expanded = PanelMetrics.size(for: .expanded(.music), notch: notch)
    #expect(expanded.width + 2 * PanelMetrics.concaveRadius <= PanelMetrics.windowSize.width)
    #expect(expanded.height <= PanelMetrics.windowSize.height)
}
```

- [ ] **Step 2: Запустить тесты и убедиться, что они падают**

Run: `swift test --package-path Packages/NotchKit --filter PanelMetricsTests`
Expected: FAIL — `cannot find 'PanelMetrics' in scope`

- [ ] **Step 3: Написать метрики**

Создай `Packages/NotchKit/Sources/NotchUI/PanelMetrics.swift`:

```swift
import CoreGraphics
import NotchCore

/// Размеры панели по состояниям.
///
/// Собраны в одном месте, потому что от них зависят три вещи сразу: рисование
/// фигуры, размер окна и проверка попадания курсора в раскрытую панель.
/// Разъехавшись, они дали бы панель, закрывающуюся под курсором.
public enum PanelMetrics {
    /// Окно постоянного размера, в котором живёт всё остальное.
    public static let windowSize = CGSize(width: 680, height: 300)
    public static let concaveRadius: CGFloat = 8

    public static let peekPadding = CGSize(width: 120, height: 28)
    public static let expandedSize = CGSize(width: 620, height: 240)

    public static func size(for state: NotchState, notch: CGSize) -> CGSize {
        switch state {
        case .closed:
            notch
        case .peek:
            CGSize(
                width: notch.width + peekPadding.width,
                height: notch.height + peekPadding.height
            )
        case .expanded:
            expandedSize
        }
    }

    public static func bottomRadius(for state: NotchState) -> CGFloat {
        switch state {
        case .closed: 10
        case .peek: 16
        case .expanded: 22
        }
    }
}
```

- [ ] **Step 4: Написать оболочку панели**

Создай `Packages/NotchKit/Sources/NotchUI/NotchPanelView.swift`:

```swift
import SwiftUI
import NotchCore

/// Оболочка панели: чёрная фигура, морф между состояниями и место под содержимое.
///
/// Содержимое приходит замыканием, а не зашито внутрь: вкладки добавляются
/// следующими планами, и оболочка не должна знать, что в них.
public struct NotchPanelView<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let state: NotchState
    private let notchSize: CGSize
    private let accent: Color
    private let content: (NotchTab) -> Content

    public init(
        state: NotchState,
        notchSize: CGSize,
        accent: Color,
        @ViewBuilder content: @escaping (NotchTab) -> Content
    ) {
        self.state = state
        self.notchSize = notchSize
        self.accent = accent
        self.content = content
    }

    public var body: some View {
        let size = PanelMetrics.size(for: state, notch: notchSize)

        NotchShape(
            width: size.width,
            height: size.height,
            bottomRadius: PanelMetrics.bottomRadius(for: state),
            concaveRadius: PanelMetrics.concaveRadius
        )
        .fill(.black)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .shadow(color: accent.opacity(0.45), radius: 22, y: 10)
        .overlay(alignment: .top) { tabBody(in: size) }
        .animation(NotchMotion.animation(for: state, reduceMotion: reduceMotion), value: state)
        .animation(.easeInOut(duration: 0.6), value: accent)
    }

    @ViewBuilder
    private func tabBody(in size: CGSize) -> some View {
        if case .expanded(let tab) = state {
            content(tab)
                .frame(width: size.width - 26, height: size.height - 38)
                .padding(.top, 24)
                // Морф формы и проявление содержимого — разные вещи. При
                // Reduce Motion форма меняется мгновенно, и переход целиком
                // отдаётся прозрачности: это вторая половина требования
                // спеки, ради которой в плане 1 написана usesMorph.
                .transition(
                    NotchMotion.usesMorph(reduceMotion: reduceMotion)
                        ? .blurReplace.combined(with: .opacity)
                        : .opacity
                )
        }
    }
}
```

- [ ] **Step 5: Подключить оболочку вместо отладочной вьюхи**

В `App/AppDelegate.swift` удали `DebugNotchView` целиком и замени содержимое
хостинг-вьюхи на `NotchPanelView`, передав состояние контроллера, размер
выреза и акцентный цвет (пока константный — плеер подключается в Task 8).
Размер окна возьми из `PanelMetrics.windowSize`, убрав локальную константу.

Содержимое на этом шаге — заглушка с именем вкладки, чтобы было видно
переключение:

```swift
NotchPanelView(
    state: controller.state,
    notchSize: geometry.notchRect.size,
    accent: .white
) { tab in
    Text(String(describing: tab))
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white.opacity(0.7))
}
```

- [ ] **Step 6: Собрать и проверить вручную**

```bash
xcodegen generate
xcodebuild -project Notchka.xcodeproj -scheme Notchka -configuration Debug \
  -derivedDataPath build build
open build/Build/Products/Debug/Notchka.app
```

- [ ] Панель по-прежнему раскрывается по наведению и по `⌥Space`
- [ ] В развороте видно имя вкладки
- [ ] При включённом Reduce Motion форма меняется без пружины

- [ ] **Step 7: Прогнать тесты и закоммитить**

Run: `swift test --package-path Packages/NotchKit`
Expected: PASS, 72 теста (34 фундамента + 27 MediaBridge + 11 NotchUI)

```bash
pkill -x Notchka
git add Packages/NotchKit App
git commit -m "feat: оболочка панели с вкладками вместо отладочной вьюхи"
```

---

### Task 8: Вкладка музыки

**Files:**
- Create: `Packages/NotchKit/Sources/NotchUI/MusicTabView.swift`
- Create: `Packages/NotchKit/Sources/NotchUI/EqualizerView.swift`
- Create: `App/MusicViewModel.swift`
- Modify: `App/AppDelegate.swift`
- Test: `Packages/NotchKit/Tests/NotchUITests/MusicFormattingTests.swift`

**Interfaces:**
- Consumes: `NowPlayingSnapshot`, `PlaybackPosition`, `ArtworkAccent`, `MediaCommand`
- Produces:
  - `TrackFormatting.time(_:)`, `TrackFormatting.progress(position:duration:)`
  - `TrackDisplay`, `TrackControl`
  - `MusicTabView(track:position:artwork:accent:onControl:)`
  - `EqualizerView(isAnimating:accent:)`
  - `MusicViewModel` — `@Observable`, подписан на провайдер

- [ ] **Step 1: Написать падающие тесты форматирования**

Создай `Packages/NotchKit/Tests/NotchUITests/MusicFormattingTests.swift`:

```swift
import Testing
import Foundation
@testable import NotchUI

@Test("секунды форматируются как минуты и секунды")
func timeFormatsAsMinutesSeconds() {
    #expect(TrackFormatting.time(0) == "0:00")
    #expect(TrackFormatting.time(9) == "0:09")
    #expect(TrackFormatting.time(62) == "1:02")
    #expect(TrackFormatting.time(216) == "3:36")
}

@Test("час и больше показывается с часами")
func longTracksShowHours() {
    #expect(TrackFormatting.time(3600) == "1:00:00")
    #expect(TrackFormatting.time(7279) == "2:01:19")
}

@Test("вырожденное время не ломает форматирование")
func degenerateTimesAreSafe() {
    #expect(TrackFormatting.time(-5) == "0:00")
    #expect(TrackFormatting.time(.nan) == "0:00")
    #expect(TrackFormatting.time(.infinity) == "0:00")
}

@Test("доля прогресса не выходит за границы")
func progressIsClamped() {
    #expect(TrackFormatting.progress(position: 50, duration: 100) == 0.5)
    #expect(TrackFormatting.progress(position: 150, duration: 100) == 1)
    #expect(TrackFormatting.progress(position: -10, duration: 100) == 0)
}

@Test("поток без длительности даёт нулевой прогресс, а не деление на ноль")
func zeroDurationGivesZeroProgress() {
    #expect(TrackFormatting.progress(position: 42, duration: 0) == 0)
}
```

- [ ] **Step 2: Запустить тесты и убедиться, что они падают**

Run: `swift test --package-path Packages/NotchKit --filter MusicFormattingTests`
Expected: FAIL — `cannot find 'TrackFormatting' in scope`

- [ ] **Step 3: Написать форматирование и вьюху**

Создай `Packages/NotchKit/Sources/NotchUI/MusicTabView.swift`:

```swift
import SwiftUI

/// Форматирование времени и прогресса.
///
/// Вынесено из вьюхи, потому что вырожденные значения приходят из внешнего
/// источника: длительность нулевая у радиопотоков, а позиция может оказаться
/// нечисловой при рассинхроне часов.
public enum TrackFormatting {
    public static func time(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        let (hours, minutes, secs) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    public static func progress(position: TimeInterval, duration: TimeInterval) -> Double {
        guard duration > 0, position.isFinite else { return 0 }
        return min(max(position / duration, 0), 1)
    }
}

/// Что показывает вкладка музыки.
public struct TrackDisplay: Equatable, Sendable {
    public let title: String
    public let artist: String
    public let source: String
    public let duration: TimeInterval
    public let isPlaying: Bool

    public init(title: String, artist: String, source: String, duration: TimeInterval, isPlaying: Bool) {
        self.title = title
        self.artist = artist
        self.source = source
        self.duration = duration
        self.isPlaying = isPlaying
    }
}

public enum TrackControl: Sendable { case previous, playPause, next }

public struct MusicTabView: View {
    private let track: TrackDisplay?
    private let position: TimeInterval
    private let artwork: Image?
    private let accent: Color
    private let onControl: (TrackControl) -> Void

    public init(
        track: TrackDisplay?,
        position: TimeInterval,
        artwork: Image?,
        accent: Color,
        onControl: @escaping (TrackControl) -> Void
    ) {
        self.track = track
        self.position = position
        self.artwork = artwork
        self.accent = accent
        self.onControl = onControl
    }

    public var body: some View {
        if let track {
            playing(track)
        } else {
            // Честный пустой экран лучше замороженного последнего трека:
            // спека требует не врать, когда источник недоступен.
            Text("Ничего не играет")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.4))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func playing(_ track: TrackDisplay) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                artworkView
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                    Text(track.source)
                        .font(.system(size: 9))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay(Capsule().stroke(accent.opacity(0.5)))
                        .padding(.top, 3)
                }
                Spacer(minLength: 0)
                EqualizerView(isAnimating: track.isPlaying, accent: accent)
            }

            HStack(spacing: 16) {
                control("backward.fill", .previous)
                control(track.isPlaying ? "pause.fill" : "play.fill", .playPause)
                control("forward.fill", .next)
            }

            ProgressBar(
                progress: TrackFormatting.progress(position: position, duration: track.duration),
                accent: accent
            )

            HStack {
                Text(TrackFormatting.time(position))
                Spacer()
                Text(TrackFormatting.time(track.duration))
            }
            .font(.system(size: 9))
            .foregroundStyle(.white.opacity(0.45))
        }
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private var artworkView: some View {
        Group {
            if let artwork {
                artwork.resizable().aspectRatio(contentMode: .fill)
            } else {
                accent.opacity(0.35)
            }
        }
        .frame(width: 58, height: 58)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func control(_ symbol: String, _ command: TrackControl) -> some View {
        Button { onControl(command) } label: {
            Image(systemName: symbol).font(.system(size: 13))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.85))
    }
}

private struct ProgressBar: View {
    let progress: Double
    let accent: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.13))
                Capsule().fill(accent).frame(width: proxy.size.width * progress)
            }
        }
        .frame(height: 3)
    }
}
```

- [ ] **Step 4: Написать эквалайзер**

Создай `Packages/NotchKit/Sources/NotchUI/EqualizerView.swift`:

```swift
import SwiftUI

/// Декоративный эквалайзер.
///
/// Настоящий спектр чужого приложения без виртуального аудиодрайвера
/// недоступен — ограничение зафиксировано в спеке §7. Полоски реагируют на
/// факт воспроизведения, а не на звук, и это осознанно.
///
/// `paused: !isAnimating` в TimelineView обязателен: без него таймлайн
/// продолжает будить рендер на паузе, а спека требует ноль работы в простое.
public struct EqualizerView: View {
    private static let periods: [Double] = [0.9, 0.62, 1.15, 0.75, 0.95]

    let isAnimating: Bool
    let accent: Color

    public init(isAnimating: Bool, accent: Color) {
        self.isAnimating = isAnimating
        self.accent = accent
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isAnimating)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Self.periods.indices, id: \.self) { index in
                    Capsule()
                        .fill(accent)
                        .frame(width: 2.5, height: height(at: index, time: time))
                }
            }
        }
        .frame(height: 16)
    }

    private func height(at index: Int, time: Double) -> CGFloat {
        guard isAnimating else { return 3 }
        let phase = sin(time / Self.periods[index] * .pi * 2)
        return 3 + CGFloat((phase + 1) / 2) * 13
    }
}
```

- [ ] **Step 5: Написать модель вкладки в app-таргете**

Создай `App/MusicViewModel.swift`:

```swift
import AppKit
import Observation
import SwiftUI
import MediaBridge
import NotchUI

/// Держит текущий трек и переводит его в то, что показывает вкладка.
@MainActor
@Observable
final class MusicViewModel {
    private(set) var track: TrackDisplay?
    private(set) var artwork: Image?
    private(set) var accent: Color = .white
    private(set) var position: TimeInterval = 0

    @ObservationIgnored private let provider: any NowPlayingProvider
    @ObservationIgnored private var snapshot: NowPlayingSnapshot?
    @ObservationIgnored private var pump: Task<Void, Never>?

    init(provider: any NowPlayingProvider) {
        self.provider = provider
    }

    func start() {
        pump = Task { [weak self] in
            guard let self else { return }
            for await snapshot in await provider.snapshots {
                await MainActor.run { self.apply(snapshot) }
            }
        }
    }

    deinit {
        pump?.cancel()
    }

    /// Позиция пересчитывается по запросу вьюхи, а не хранится тикающей:
    /// адаптер отдаёт её снимком, и единственный честный способ — считать
    /// от метки времени.
    func refreshPosition(now: Date = Date()) {
        guard let snapshot else { return }
        position = PlaybackPosition.current(in: snapshot, at: now)
    }

    func handle(_ control: TrackControl) {
        let command: MediaCommand = switch control {
        case .playPause: .toggle
        // Переключение треков спайком не проверялось: у адаптера есть seek,
        // но кода «следующий трек» мы не подтверждали. До проверки обе
        // стрелки делают то же, что центральная кнопка — врать видом кнопки
        // хуже, чем временно её продублировать.
        case .previous, .next: .toggle
        }
        Task { try? await provider.send(command) }
    }

    private func apply(_ snapshot: NowPlayingSnapshot?) {
        self.snapshot = snapshot
        guard let snapshot else {
            track = nil
            artwork = nil
            accent = .white
            return
        }
        track = TrackDisplay(
            title: snapshot.title,
            artist: snapshot.artist,
            source: Self.sourceName(for: snapshot.sourceBundleID),
            duration: snapshot.duration,
            isPlaying: snapshot.isPlaying
        )
        updateArtwork(from: snapshot)
        refreshPosition()
    }

    private func updateArtwork(from snapshot: NowPlayingSnapshot) {
        guard let data = snapshot.artworkData,
              let image = NSImage(data: data),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            artwork = nil
            return
        }
        artwork = Image(nsImage: image)
        if let colour = ArtworkAccent.color(from: cgImage) { accent = colour }
    }

    /// Человеческое имя источника вместо bundle id.
    private static func sourceName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        return FileManager.default.displayName(atPath: url.path)
    }
}
```

- [ ] **Step 6: Подключить вкладку в AppDelegate**

Создай провайдер и модель при запуске, передай акцент и содержимое в
`NotchPanelView`.

Корень репозитория для `AdapterPaths.vendored` вынеси в **одну именованную
константу с комментарием**: сейчас приложение работает только из дерева
исходников, а в плане 4 адаптер переедет внутрь бандла.

Позицию обновляй только пока панель раскрыта — в покое приложение обязано
спать:

```swift
if case .expanded = controller.state { musicModel.refreshPosition() }
```

- [ ] **Step 7: Собрать и проверить вручную**

Включи музыку в браузере, собери и запусти. Проверь:

- [ ] Разворот показывает реальный трек, исполнителя и имя браузера
- [ ] Обложка видна, свечение панели окрашено в цвет обложки
- [ ] Кнопка паузы реально ставит на паузу и меняет вид
- [ ] Прогресс-бар едет, а не стоит
- [ ] Смена трека в браузере обновляет панель за секунду
- [ ] Останови музыку совсем — панель говорит «Ничего не играет», а не держит старый трек

- [ ] **Step 8: Прогнать тесты и закоммитить**

Run: `swift test --package-path Packages/NotchKit`
Expected: PASS, 77 тестов

```bash
pkill -x Notchka
git add Packages/NotchKit App
git commit -m "feat: вкладка музыки с обложкой, акцентным цветом и управлением"
```

---

### Task 9: Долги фундамента

Две вещи, записанные планом 1 как долги и требовавшие настоящих размеров
панели. Теперь они есть.

**Files:**
- Modify: `Packages/NotchKit/Sources/NotchCore/NotchGeometry.swift`
- Modify: `App/NotchController.swift`
- Modify: `App/AppDelegate.swift`
- Test: `Packages/NotchKit/Tests/NotchCoreTests/HotZoneRetentionTests.swift`

**Interfaces:**
- Consumes: `PanelMetrics` из Task 7, `NotchGeometry`, `NotchStateMachine`
- Produces: `NotchGeometry.retentionZone(for: CGSize) -> CGRect`

- [ ] **Step 1: Написать падающие тесты удержания**

Создай `Packages/NotchKit/Tests/NotchCoreTests/HotZoneRetentionTests.swift`:

```swift
import Testing
import CoreGraphics
@testable import NotchCore

private let metrics = ScreenMetrics(
    frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
    safeAreaTopInset: 32,
    auxiliaryTopLeftWidth: 630,
    auxiliaryTopRightWidth: 630
)

@Test("зона удержания охватывает раскрытую панель целиком")
func retentionZoneCoversPanel() throws {
    let geometry = try #require(NotchGeometryCalculator.geometry(for: metrics))
    let panel = CGSize(width: 620, height: 240)
    let zone = geometry.retentionZone(for: panel)
    #expect(zone.width >= panel.width)
    #expect(zone.height >= panel.height)
}

@Test("зона удержания центрирована по вырезу, а не по экрану")
func retentionZoneIsCentredOnNotch() throws {
    let geometry = try #require(NotchGeometryCalculator.geometry(for: metrics))
    let zone = geometry.retentionZone(for: CGSize(width: 620, height: 240))
    #expect(abs(zone.midX - geometry.notchRect.midX) < 0.001)
}

@Test("курсор на видимой панели остаётся внутри зоны удержания")
func cursorOnPanelStaysInside() throws {
    let geometry = try #require(NotchGeometryCalculator.geometry(for: metrics))
    let panel = CGSize(width: 620, height: 240)
    let zone = geometry.retentionZone(for: panel)
    // Точка у нижнего края панели — та самая, из-за которой панель
    // закрывалась под курсором при проверке по зоне входа.
    let nearBottomEdge = CGPoint(x: geometry.notchRect.midX, y: panel.height - 4)
    #expect(zone.contains(nearBottomEdge))
    #expect(geometry.hotZone.contains(nearBottomEdge) == false)
}
```

- [ ] **Step 2: Запустить тесты и убедиться, что они падают**

Run: `swift test --package-path Packages/NotchKit --filter HotZoneRetentionTests`
Expected: FAIL — `value of type 'NotchGeometry' has no member 'retentionZone'`

- [ ] **Step 3: Написать зону удержания**

Добавь в `Packages/NotchKit/Sources/NotchCore/NotchGeometry.swift`:

```swift
extension NotchGeometry {
    /// Прямоугольник, при выходе из которого раскрытая панель закрывается.
    ///
    /// Зона входа намеренно мала — вырез плюс несколько пунктов, — и проверять
    /// по ней открытую панель нельзя: подводя курсор к видимой панели,
    /// пользователь вышел бы из зоны и она закрылась бы под курсором.
    /// Поэтому удержание считается по текущим границам панели.
    public func retentionZone(for panel: CGSize) -> CGRect {
        CGRect(
            x: notchRect.midX - panel.width / 2,
            y: 0,
            width: panel.width,
            height: panel.height
        )
    }
}
```

- [ ] **Step 4: Подключить удержание в контроллере**

В `App/NotchController.swift`, в `cursorSampled`, выбирай прямоугольник по
состоянию: в `.closed` — `geometry.hotZone`, иначе —
`geometry.retentionZone(for: PanelMetrics.size(for: state, notch: geometry.notchRect.size))`.

- [ ] **Step 5: Подключить отправителя fullScreenChanged**

Долг фундамента: машина умеет обрабатывать это событие с плана 1, но посылать
его некому. Спека §5 требует отключать панель в фуллскрине.

Наблюдай `NSWorkspace.shared.notificationCenter` за
`activeSpaceDidChangeNotification` и проверяй, схлопнулся ли
`safeAreaInsets.top` встроенного экрана в ноль — это дешёвый признак
фуллскрина на чёлочном дисплее. Отправляй
`controller.handle(.fullScreenChanged(isFullScreen))`.

Наблюдателя снимай в `deinit`, как уже сделано для монитора курсора, хоткея
и смены конфигурации экранов.

- [ ] **Step 6: Собрать и проверить вручную**

- [ ] Разверни панель хоткеем и подведи курсор к её нижнему краю — не закрывается
- [ ] Уведи курсор далеко вниз — закрывается
- [ ] Разверни окно в фуллскрин — панель исчезает и на наведение не реагирует
- [ ] Выйди из фуллскрина — панель снова работает

- [ ] **Step 7: Прогнать тесты и закоммитить**

Run: `swift test --package-path Packages/NotchKit`
Expected: PASS, 80 тестов

```bash
pkill -x Notchka
git add Packages/NotchKit App
git commit -m "feat: удержание панели по её границам и отключение в фуллскрине"
```

---

### Task 10: Приёмка плана «Музыка»

**Files:**
- Create: `docs/superpowers/notes/2026-08-12-music-acceptance.md`

- [ ] **Step 1: Прогнать все тесты**

Run: `swift test --package-path Packages/NotchKit`
Expected: PASS, 80 тестов (34 фундамента + 27 MediaBridge + 16 NotchUI + 3 NotchCore)

- [ ] **Step 2: Собрать релизную конфигурацию**

```bash
xcodebuild -project Notchka.xcodeproj -scheme Notchka -configuration Release \
  -derivedDataPath build build 2>&1 | grep -E 'warning:|error:|BUILD'
```

Expected: `** BUILD SUCCEEDED **`, ноль предупреждений. Грепай полный лог,
а не хвост.

- [ ] **Step 3: Проверить расход в трёх режимах**

Замерь CPU процесса: панель закрыта и музыка играет; панель раскрыта и музыка
играет; музыка остановлена. Запиши реальные цифры, а не ожидаемые.

Закрытая панель при играющей музыке — главный режим, приложение висит так
часами. Если там заметный процент, виноват либо поток адаптера, либо
незаснувший `TimelineView` эквалайзера.

- [ ] **Step 4: Пройти сквозной сценарий**

- [ ] Трек в Chrome виден в панели с названием, исполнителем и «Google Chrome»
- [ ] Пауза с панели останавливает воспроизведение в браузере
- [ ] Смена трека обновляет обложку и акцентный цвет
- [ ] `pkill -f mediaremote-adapter` — панель переживает и восстанавливается
- [ ] Браузер закрыт совсем — панель говорит «Ничего не играет»

- [ ] **Step 5: Записать отчёт и закоммитить**

Создай `docs/superpowers/notes/2026-08-12-music-acceptance.md` с реальными
результатами, чек-листом с указанием, что проверил человек, а что агент,
и разделом «Осталось на потом».

```bash
git add docs/superpowers/notes
git commit -m "docs: приёмка плана «Музыка»"
```

---

## Что дальше

- **План 3 — хранилище и буфер обмена.** `NotchStore` на GRDB с FTS5,
  `ClipboardKit` с фильтрами приватности, горизонтальная лента, автовставка
  через CGEvent, клавиатура `⌘1`…`⌘4`, `⇥`, `Esc`, стрелки и `↩`.
- **План 4 — заметки, пины и поиск.** `StashKit`, сквозной поиск по трём
  сущностям, настройки, онбординг разрешения Accessibility.

Долги, оставленные этим планом:

- **Кнопки «предыдущий» и «следующий» шлют toggle.** У адаптера есть коды
  помимо 0/1/2, но переключение треков спайком не проверялось. Проверить
  эмпирически, как это было сделано для play/pause, и подключить.
- **Путь к вендоренному адаптеру берётся из константы.** Приложение работает
  только из дерева исходников. В плане 4 адаптер переезжает внутрь бандла.
- **`AppleScriptProvider` для Spotify и Music.app не написан.** Адаптер
  покрывает и их; отдельная реализация понадобится, только если обнаружится
  расхождение в точности позиции.
