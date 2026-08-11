# Notchka: Фундамент — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Живая пустая чёлка — открывается по наведению и хоткею, не крадёт фокус, не блокирует меню-бар — плюс доказанный канал чтения музыки из браузера.

**Architecture:** Тонкий app-таргет на AppKit держит окно и системные API; вся логика (геометрия, машина состояний, пороги курсора, форма) живёт в локальном SPM-пакете `NotchKit` и тестируется без запуска приложения. Панель это неактивирующаяся `NSPanel` постоянного размера — анимируется содержимое внутри, а не окно.

**Tech Stack:** Swift 6.3, SwiftUI + AppKit, Swift Testing, XcodeGen, Carbon HIToolbox (хоткей), mediaremote-adapter (вендорится).

Спека: [docs/superpowers/specs/2026-08-10-notchka-design.md](../specs/2026-08-10-notchka-design.md)

## Global Constraints

Требования проекта. Действуют в каждой задаче, повторно не проговариваются.

- Целевая платформа: macOS 26.0+, Apple Silicon. Тулчейн: Swift 6.3, Xcode 26.6.
- Bundle id: `kz.mobilefirst.notchka`. Имя приложения: `Notchka`.
- Приложение-агент: `LSUIElement = true`, без иконки в Dock, без главного окна.
- Без сэндбокса, без hardened runtime, локальная подпись (`CODE_SIGN_IDENTITY = "-"`).
- Строгая конкурентность Swift 6 (`SWIFT_STRICT_CONCURRENCY = complete`), язык версии 6.
- Тесты пишутся на **Swift Testing** (`import Testing`, `@Test`, `#expect`), не на XCTest.
- Ноль сетевых запросов. Приложение не обращается наружу ни при каких условиях.
- Пружина открытия и разворота: `.spring(response: 0.34, dampingFraction: 0.68)`.
  Закрытие: `.snappy(duration: 0.26)`.
- Пороги курсора: вход в горячую зону 120 мс, выход 250 мс.
- Горячая зона: прямоугольник чёлки, расширенный на 6 pt по горизонтали и 4 pt вниз.
- Анимируются только `transform`, `opacity`, `clip-path` и параметры фигуры.
- Файлы: 200–400 строк типично, 800 максимум. Функции до 50 строк.
- Комментарии на русском, объясняют «почему», а не «что».
- Формат коммитов: `<type>: <описание>`, типы `feat|fix|refactor|docs|test|chore|perf`.

---

### Task 1: Спайк — доказать чтение музыки из браузера

Первая задача плана, потому что от её исхода зависит план 2. Ни строчки UI до того,
как поток данных доказан на реальной машине.

**Files:**
- Create: `vendor/mediaremote-adapter/` (клон стороннего репозитория)
- Create: `docs/superpowers/notes/2026-08-10-spike-mediaremote.md`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: ничего
- Produces: файл `docs/superpowers/notes/2026-08-10-spike-mediaremote.md`, содержащий
  проверенные пути `ADAPTER_PL` и `ADAPTER_FRAMEWORK`, точную команду запуска потока
  и образец JSON. План 2 берёт эти значения оттуда.

- [ ] **Step 1: Клонировать адаптер в vendor/**

```bash
mkdir -p vendor
git clone --depth 1 https://github.com/ungive/mediaremote-adapter.git vendor/mediaremote-adapter
ls vendor/mediaremote-adapter
```

Ожидается: в каталоге есть `README.md`, скрипт `mediaremote-adapter.pl` (или похожий `.pl`)
и исходники фреймворка. Точное имя `.pl`-файла найди командой:

```bash
find vendor/mediaremote-adapter -name '*.pl'
```

- [ ] **Step 2: Собрать MediaRemoteAdapter.framework**

Репозиторий собирается через **CMake** — Xcode-проекта и `Package.swift` в нём нет.

```bash
cd vendor/mediaremote-adapter
cmake -S . -B .build -DCMAKE_BUILD_TYPE=Release
cmake --build .build
cd -
ls -d vendor/mediaremote-adapter/.build/MediaRemoteAdapter.framework
```

Ожидается: `vendor/mediaremote-adapter/.build/MediaRemoteAdapter.framework`, около 5 МБ.

- [ ] **Step 3: Проверить работоспособность адаптера**

Пути обязаны быть **абсолютными**: с относительными адаптер падает с
`Failed to load framework`. Это не придирка стиля, а требование самого бриджа.

```bash
ADAPTER_PL="$PWD/vendor/mediaremote-adapter/bin/mediaremote-adapter.pl"
ADAPTER_FRAMEWORK="$PWD/vendor/mediaremote-adapter/.build/MediaRemoteAdapter.framework"
/usr/bin/perl "$ADAPTER_PL" "$ADAPTER_FRAMEWORK" test; echo "exit=$?"
```

Ожидается: `exit=0`.

Если код не нулевой — спайк провален, переходи к Step 8.

- [ ] **Step 4: Прочитать трек из Chrome**

Вручную: открой Chrome, включи любой ролик на YouTube, оставь играть. Затем:

```bash
/usr/bin/perl "$ADAPTER_PL" "$ADAPTER_FRAMEWORK" get
```

Ожидается: JSON, где `"bundleIdentifier"` равен `com.google.Chrome`, а `"title"`
совпадает с названием ролика. Поля `"playing"`, `"duration"`, `"elapsedTime"` заполнены.

Это и есть главная проверка всего проекта: если тут пусто — вся стратегия чтения музыки
не работает.

- [ ] **Step 5: Проверить поток обновлений**

```bash
/usr/bin/perl "$ADAPTER_PL" "$ADAPTER_FRAMEWORK" stream
```

Вручную: поставь ролик на паузу и сними с паузы, переключи на другой.

Ожидается: строки вида `{"type":"data","diff":true,"payload":{...}}` появляются на каждое
действие. Оборви поток по `Ctrl+C` — процесс должен завершиться чисто.

- [ ] **Step 6: Проверить обратное управление**

```bash
/usr/bin/perl "$ADAPTER_PL" "$ADAPTER_FRAMEWORK" send 2
```

Ожидается: воспроизведение в Chrome переключилось (код `2` — toggle play/pause в наборе
MediaRemote 0…13). Если этот код дал другой эффект, перебери коды 0, 1, 2 и запиши в
заметку, какой из них play, pause и toggle.

- [ ] **Step 7: Записать результат спайка**

Создай `docs/superpowers/notes/2026-08-10-spike-mediaremote.md`:

```markdown
# Спайк: чтение now playing через mediaremote-adapter

Дата: 2026-08-10
Машина: macOS 26.3, Apple Silicon
Результат: УСПЕХ

## Проверенные пути

- ADAPTER_PL: <вставь реальный путь>
- ADAPTER_FRAMEWORK: <вставь реальный путь>

## Команды

Разовое чтение:
    /usr/bin/perl $ADAPTER_PL $ADAPTER_FRAMEWORK get

Поток:
    /usr/bin/perl $ADAPTER_PL $ADAPTER_FRAMEWORK stream

Управление:
    /usr/bin/perl $ADAPTER_PL $ADAPTER_FRAMEWORK send <код>

## Коды команд (проверено вручную)

- 0 — <что делает>
- 1 — <что делает>
- 2 — <что делает>

## Образец payload из Chrome

<вставь реальный JSON, обложку обрежь на первых 80 символах>

## Задержки

- От нажатия паузы до строки в потоке: <измерь на глаз, порядок величины>
```

Все угловые скобки должны быть заменены реальными значениями — файл читает план 2.

- [ ] **Step 8: Если спайк провален — зафиксировать и остановиться**

Если Step 3 или Step 4 не дали результата, запиши в ту же заметку `Результат: ПРОВАЛ`
с точным выводом команд и **останови выполнение плана**. Дальнейшие задачи имеют смысл,
но план 2 придётся переписать на провайдер через браузерное расширение. Это решение
принимает человек, а не исполнитель плана.

- [ ] **Step 9: Исключить артефакты сборки и закоммитить**

Добавь в `.gitignore`:

```gitignore
# Артефакты сборки вендоренного адаптера
vendor/mediaremote-adapter/.build/
```

```bash
git add .gitignore vendor/mediaremote-adapter docs/superpowers/notes/
git commit -m "chore: вендоринг mediaremote-adapter и спайк чтения музыки из браузера"
```

---

### Task 2: Скелет проекта

**Files:**
- Create: `project.yml`
- Create: `Packages/NotchKit/Package.swift`
- Create: `Packages/NotchKit/Sources/NotchCore/NotchCorePlaceholder.swift`
- Create: `Packages/NotchKit/Sources/NotchUI/NotchUIPlaceholder.swift`
- Create: `App/AppDelegate.swift`
- Create: `App/Info.plist`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: ничего
- Produces: собираемый app-таргет `Notchka` и библиотеки `NotchCore`, `NotchUI`;
  команды сборки, которыми пользуются все последующие задачи.

Задача строительная: в ней нет тестов, потому что нечего проверять, кроме
успешной сборки. Тест-таргеты объявляются там, где появляются настоящие тесты:
`NotchCoreTests` в Task 3, `NotchUITests` в Task 6. Пустой тест-таргет SPM
не соберёт, поэтому объявлять их заранее нельзя.

- [ ] **Step 1: Установить XcodeGen**

Проект описывается текстовым `project.yml`, а `.xcodeproj` генерируется. Это избавляет от
конфликтов в `.pbxproj` и делает структуру проекта читаемой в диффах.

```bash
which xcodegen || brew install xcodegen
xcodegen --version
```

- [ ] **Step 2: Создать локальный пакет NotchKit**

Создай `Packages/NotchKit/Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotchKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "NotchCore", targets: ["NotchCore"]),
        .library(name: "NotchUI", targets: ["NotchUI"]),
    ],
    targets: [
        .target(name: "NotchCore"),
        .target(name: "NotchUI", dependencies: ["NotchCore"]),
    ]
)
```

- [ ] **Step 3: Создать заглушки таргетов**

SPM не собирает таргет без единого исходника, а настоящих типов тут ещё нет.
Обе заглушки удаляются в задачах, которые приносят первый настоящий файл.

Создай `Packages/NotchKit/Sources/NotchCore/NotchCorePlaceholder.swift`:

```swift
/// Заглушка таргета. Удаляется в Task 3, когда появляется ScreenMetrics.
enum NotchCorePlaceholder {}
```

Создай `Packages/NotchKit/Sources/NotchUI/NotchUIPlaceholder.swift`:

```swift
/// Заглушка таргета. Удаляется в Task 6, когда появляется NotchShape.
enum NotchUIPlaceholder {}
```

- [ ] **Step 4: Убедиться, что пакет собирается**

Run: `swift build --package-path Packages/NotchKit`
Expected: `Build complete`, ноль предупреждений

Тестов в этой задаче нет и быть не может: проверять здесь нечего, кроме факта
сборки. Первый настоящий красно-зелёный цикл начинается в Task 3.

- [ ] **Step 5: Описать app-таргет**

Создай `project.yml`:

```yaml
name: Notchka
options:
  bundleIdPrefix: kz.mobilefirst
  deploymentTarget:
    macOS: "26.0"
  createIntermediateGroups: true

packages:
  NotchKit:
    path: Packages/NotchKit

targets:
  Notchka:
    type: application
    platform: macOS
    sources:
      - path: App
    dependencies:
      - package: NotchKit
        product: NotchCore
      - package: NotchKit
        product: NotchUI
    info:
      path: App/Info.plist
      properties:
        CFBundleName: Notchka
        LSUIElement: true
        LSMinimumSystemVersion: "26.0"
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: kz.mobilefirst.notchka
        MARKETING_VERSION: "0.1.0"
        CURRENT_PROJECT_VERSION: "1"
        SWIFT_VERSION: "6.0"
        SWIFT_STRICT_CONCURRENCY: complete
        CODE_SIGN_IDENTITY: "-"
        CODE_SIGNING_REQUIRED: NO
        ENABLE_HARDENED_RUNTIME: NO
        ENABLE_USER_SCRIPT_SANDBOXING: NO
```

- [ ] **Step 6: Написать точку входа**

Создай `App/AppDelegate.swift`:

```swift
import AppKit

/// Точка входа. Приложение-агент: без иконки в Dock и без главного окна,
/// вся видимая часть появится в Task 9.
@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("Notchka запущена")
    }
}
```

- [ ] **Step 7: Сгенерировать проект и собрать**

```bash
xcodegen generate
xcodebuild -project Notchka.xcodeproj -scheme Notchka -configuration Debug \
  -derivedDataPath build build
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 8: Проверить, что приложение запускается агентом**

```bash
open build/Build/Products/Debug/Notchka.app
sleep 1
pgrep -x Notchka && echo "процесс живой"
```

Expected: процесс найден, иконка в Dock **не появилась**.

```bash
pkill -x Notchka
```

- [ ] **Step 9: Закоммитить**

Добавь в `.gitignore`:

```gitignore
# XcodeGen генерирует проект из project.yml
Notchka.xcodeproj/
```

```bash
git add .gitignore project.yml Packages App
git commit -m "feat: скелет проекта — app-таргет Notchka и пакет NotchKit"
```

---

### Task 3: Геометрия чёлки

Чистая арифметика без AppKit — поэтому тестируется на выдуманных экранах, включая те,
которых нет под рукой.

**Files:**
- Create: `Packages/NotchKit/Sources/NotchCore/ScreenMetrics.swift`
- Create: `Packages/NotchKit/Sources/NotchCore/NotchGeometry.swift`
- Delete: `Packages/NotchKit/Sources/NotchCore/NotchCorePlaceholder.swift`
- Modify: `Packages/NotchKit/Package.swift` — объявить тест-таргет
- Test: `Packages/NotchKit/Tests/NotchCoreTests/NotchGeometryTests.swift`

**Interfaces:**
- Consumes: ничего
- Produces:
  - `ScreenMetrics(frame:safeAreaTopInset:auxiliaryTopLeftWidth:auxiliaryTopRightWidth:)`
  - `NotchGeometry` с полями `notchRect: CGRect` и `hotZone: CGRect`
  - `NotchGeometryCalculator.geometry(for: ScreenMetrics) -> NotchGeometry?`
  - Константы `NotchGeometryCalculator.hotZoneInsetX = 6`, `.hotZoneInsetBottom = 4`

- [ ] **Step 1: Объявить тест-таргет и написать падающие тесты**

Task 2 оставил `Package.swift` без тест-таргетов: пустой тест-таргет SPM не собирает.
Добавь в массив `targets`:

```swift
        .testTarget(name: "NotchCoreTests", dependencies: ["NotchCore"]),
```

Создай `Packages/NotchKit/Tests/NotchCoreTests/NotchGeometryTests.swift`:

```swift
import Testing
import CoreGraphics
@testable import NotchCore

/// Метрики, близкие к MacBook Pro 14": ширина 1512, чёлка 252 pt по 630 с каждой стороны.
private let notchedScreen = ScreenMetrics(
    frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
    safeAreaTopInset: 32,
    auxiliaryTopLeftWidth: 630,
    auxiliaryTopRightWidth: 630
)

@Test("на экране с чёлкой вырез считается из боковых областей")
func notchRectIsDerivedFromAuxiliaryAreas() throws {
    let geometry = try #require(NotchGeometryCalculator.geometry(for: notchedScreen))
    #expect(geometry.notchRect.origin.x == 630)
    #expect(geometry.notchRect.origin.y == 0)
    #expect(geometry.notchRect.width == 252)
    #expect(geometry.notchRect.height == 32)
}

@Test("горячая зона шире выреза на 6 pt с каждой стороны и на 4 pt ниже")
func hotZoneIsInflatedNotch() throws {
    let geometry = try #require(NotchGeometryCalculator.geometry(for: notchedScreen))
    #expect(geometry.hotZone.origin.x == 624)
    #expect(geometry.hotZone.width == 264)
    #expect(geometry.hotZone.height == 36)
}

@Test("на экране без чёлки геометрии нет")
func screenWithoutNotchHasNoGeometry() {
    let external = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
        safeAreaTopInset: 0,
        auxiliaryTopLeftWidth: 0,
        auxiliaryTopRightWidth: 0
    )
    #expect(NotchGeometryCalculator.geometry(for: external) == nil)
}

@Test("некорректные боковые области не дают отрицательной чёлки")
func inconsistentAuxiliaryAreasAreRejected() {
    let broken = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1000, height: 700),
        safeAreaTopInset: 32,
        auxiliaryTopLeftWidth: 600,
        auxiliaryTopRightWidth: 600
    )
    #expect(NotchGeometryCalculator.geometry(for: broken) == nil)
}
```

- [ ] **Step 2: Запустить тесты и убедиться, что они падают**

Run: `swift test --package-path Packages/NotchKit --filter NotchGeometryTests`
Expected: FAIL — `cannot find 'ScreenMetrics' in scope`

- [ ] **Step 3: Написать реализацию**

Удали заглушку `Packages/NotchKit/Sources/NotchCore/NotchCorePlaceholder.swift` —
в таргете появляются настоящие типы, держать её больше незачем.

Создай `Packages/NotchKit/Sources/NotchCore/ScreenMetrics.swift`:

```swift
import CoreGraphics

/// Снимок измерений экрана, достаточный для вычисления чёлки.
/// Отделён от NSScreen намеренно: геометрия должна считаться на выдуманных
/// конфигурациях, которых нет под рукой.
public struct ScreenMetrics: Sendable, Equatable {
    public let frame: CGRect
    /// Высота выреза. На экранах без чёлки равна нулю.
    public let safeAreaTopInset: CGFloat
    /// Ширина полосы меню-бара слева от выреза.
    public let auxiliaryTopLeftWidth: CGFloat
    /// Ширина полосы меню-бара справа от выреза.
    public let auxiliaryTopRightWidth: CGFloat

    public init(
        frame: CGRect,
        safeAreaTopInset: CGFloat,
        auxiliaryTopLeftWidth: CGFloat,
        auxiliaryTopRightWidth: CGFloat
    ) {
        self.frame = frame
        self.safeAreaTopInset = safeAreaTopInset
        self.auxiliaryTopLeftWidth = auxiliaryTopLeftWidth
        self.auxiliaryTopRightWidth = auxiliaryTopRightWidth
    }
}
```

Создай `Packages/NotchKit/Sources/NotchCore/NotchGeometry.swift`:

```swift
import CoreGraphics

/// Положение выреза и зоны его срабатывания.
/// Координаты экранные, начало отсчёта — верхний левый угол дисплея.
public struct NotchGeometry: Sendable, Equatable {
    public let notchRect: CGRect
    public let hotZone: CGRect

    public init(notchRect: CGRect, hotZone: CGRect) {
        self.notchRect = notchRect
        self.hotZone = hotZone
    }
}

public enum NotchGeometryCalculator {
    /// Запас по горизонтали: курсор не обязан попадать в вырез пиксель в пиксель.
    public static let hotZoneInsetX: CGFloat = 6
    /// Запас снизу: чёлка реагирует чуть раньше, чем курсор дойдёт до её края.
    public static let hotZoneInsetBottom: CGFloat = 4

    public static func geometry(for metrics: ScreenMetrics) -> NotchGeometry? {
        guard metrics.safeAreaTopInset > 0 else { return nil }

        let notchWidth = metrics.frame.width
            - metrics.auxiliaryTopLeftWidth
            - metrics.auxiliaryTopRightWidth
        guard notchWidth > 0 else { return nil }

        let notchRect = CGRect(
            x: metrics.auxiliaryTopLeftWidth,
            y: 0,
            width: notchWidth,
            height: metrics.safeAreaTopInset
        )
        let hotZone = CGRect(
            x: notchRect.minX - hotZoneInsetX,
            y: 0,
            width: notchRect.width + hotZoneInsetX * 2,
            height: notchRect.height + hotZoneInsetBottom
        )
        return NotchGeometry(notchRect: notchRect, hotZone: hotZone)
    }
}
```

- [ ] **Step 4: Запустить тесты и убедиться, что они проходят**

Run: `swift test --package-path Packages/NotchKit --filter NotchGeometryTests`
Expected: PASS, 4 теста

- [ ] **Step 5: Закоммитить**

```bash
git add Packages/NotchKit
git commit -m "feat: геометрия чёлки и горячей зоны из метрик экрана"
```

---

### Task 4: Машина состояний

Полная таблица переходов из спеки §8. Машина синхронная и не знает про время — пороги
живут отдельно, в Task 5. Это разделение и делает обе части тестируемыми.

**Files:**
- Create: `Packages/NotchKit/Sources/NotchCore/NotchState.swift`
- Create: `Packages/NotchKit/Sources/NotchCore/NotchStateMachine.swift`
- Test: `Packages/NotchKit/Tests/NotchCoreTests/NotchStateMachineTests.swift`

**Interfaces:**
- Consumes: ничего
- Produces:
  - `NotchTab` (`.music = 1`, `.clipboard`, `.notes`, `.pins`), свойство `next`
  - `PeekReason` (`.hover`, `.trackChanged`)
  - `NotchState` (`.closed`, `.peek(PeekReason)`, `.expanded(NotchTab)`)
  - `NotchEvent` — см. реализацию ниже
  - `NotchStateMachine` с `state`, `lastTab`, `isFullScreen`
    и `mutating func handle(_ event: NotchEvent) -> NotchState?`

- [ ] **Step 1: Написать падающие тесты**

Создай `Packages/NotchKit/Tests/NotchCoreTests/NotchStateMachineTests.swift`:

```swift
import Testing
@testable import NotchCore

@Test("курсор в горячей зоне открывает peek")
func cursorOpensPeek() {
    var machine = NotchStateMachine()
    #expect(machine.handle(.cursorEnteredHotZone) == .peek(.hover))
}

@Test("хоткей из закрытого состояния разворачивает последнюю вкладку")
func hotkeyOpensLastTab() {
    var machine = NotchStateMachine()
    machine.handle(.hotkey)
    machine.handle(.selectTab(.notes))
    machine.handle(.dismiss)
    #expect(machine.handle(.hotkey) == .expanded(.notes))
}

@Test("смена трека даёт автопик, который сам истекает")
func trackChangeAutoPeeks() {
    var machine = NotchStateMachine()
    #expect(machine.handle(.trackChanged) == .peek(.trackChanged))
    #expect(machine.handle(.peekTimedOut) == .closed)
}

@Test("наведение во время автопика превращает его в hover")
func hoverTakesOverAutoPeek() {
    var machine = NotchStateMachine()
    machine.handle(.trackChanged)
    #expect(machine.handle(.cursorEnteredHotZone) == .peek(.hover))
}

@Test("клик по peek разворачивает вкладку музыки")
func clickExpandsToMusic() {
    var machine = NotchStateMachine()
    machine.handle(.cursorEnteredHotZone)
    #expect(machine.handle(.click) == .expanded(.music))
}

@Test("уход курсора закрывает peek")
func cursorLeaveClosesPeek() {
    var machine = NotchStateMachine()
    machine.handle(.cursorEnteredHotZone)
    #expect(machine.handle(.cursorLeftHotZone) == .closed)
}

@Test("уход курсора НЕ закрывает развёрнутую панель")
func cursorLeaveKeepsExpandedOpen() {
    var machine = NotchStateMachine()
    machine.handle(.hotkey)
    #expect(machine.handle(.cursorLeftHotZone) == nil)
    #expect(machine.state == .expanded(.music))
}

@Test("Esc и клик вне панели закрывают разворот")
func dismissClosesExpanded() {
    var machine = NotchStateMachine()
    machine.handle(.hotkey)
    #expect(machine.handle(.dismiss) == .closed)
}

@Test("хоткей на развёрнутой панели её закрывает")
func hotkeyTogglesExpandedClosed() {
    var machine = NotchStateMachine()
    machine.handle(.hotkey)
    #expect(machine.handle(.hotkey) == .closed)
}

@Test("цикл вкладок идёт по кругу")
func cycleTabWrapsAround() {
    var machine = NotchStateMachine()
    machine.handle(.hotkey)
    #expect(machine.handle(.cycleTab) == .expanded(.clipboard))
    #expect(machine.handle(.cycleTab) == .expanded(.notes))
    #expect(machine.handle(.cycleTab) == .expanded(.pins))
    #expect(machine.handle(.cycleTab) == .expanded(.music))
}

@Test("фуллскрин закрывает панель и глушит события")
func fullScreenDisablesPanel() {
    var machine = NotchStateMachine()
    machine.handle(.hotkey)
    #expect(machine.handle(.fullScreenChanged(true)) == .closed)
    #expect(machine.handle(.hotkey) == nil)
    #expect(machine.handle(.cursorEnteredHotZone) == nil)
    #expect(machine.state == .closed)
}

@Test("выход из фуллскрина возвращает реакцию на события")
func leavingFullScreenReenablesPanel() {
    var machine = NotchStateMachine()
    machine.handle(.fullScreenChanged(true))
    machine.handle(.fullScreenChanged(false))
    #expect(machine.handle(.cursorEnteredHotZone) == .peek(.hover))
}

@Test("повторное событие без смены состояния не сообщается")
func idempotentEventsReturnNil() {
    var machine = NotchStateMachine()
    machine.handle(.cursorEnteredHotZone)
    #expect(machine.handle(.cursorEnteredHotZone) == nil)
}
```

- [ ] **Step 2: Запустить тесты и убедиться, что они падают**

Run: `swift test --package-path Packages/NotchKit --filter NotchStateMachineTests`
Expected: FAIL — `cannot find 'NotchStateMachine' in scope`

- [ ] **Step 3: Написать типы состояний**

Создай `Packages/NotchKit/Sources/NotchCore/NotchState.swift`:

```swift
/// Вкладки панели. Сырые значения совпадают с цифрами хоткеев ⌘1…⌘4.
public enum NotchTab: Int, Sendable, Equatable, CaseIterable {
    case music = 1
    case clipboard
    case notes
    case pins

    /// Следующая вкладка по кругу — для ⇥.
    public var next: NotchTab {
        NotchTab(rawValue: rawValue % NotchTab.allCases.count + 1) ?? .music
    }
}

/// Почему панель находится в промежуточном состоянии.
/// Различие важно: hover закрывается уходом курсора, автопик — по таймеру.
public enum PeekReason: Sendable, Equatable {
    case hover
    case trackChanged
}

public enum NotchState: Sendable, Equatable {
    case closed
    case peek(PeekReason)
    case expanded(NotchTab)
}

public enum NotchEvent: Sendable, Equatable {
    case cursorEnteredHotZone
    case cursorLeftHotZone
    case click
    case hotkey
    /// Esc или клик вне панели.
    case dismiss
    case selectTab(NotchTab)
    case cycleTab
    case trackChanged
    /// Истекли 2 секунды автопика по смене трека.
    case peekTimedOut
    case fullScreenChanged(Bool)
}
```

- [ ] **Step 4: Написать машину**

Создай `Packages/NotchKit/Sources/NotchCore/NotchStateMachine.swift`:

```swift
/// Единственный источник истины о состоянии панели.
/// Синхронная и не зависит от времени: пороги курсора и таймер автопика
/// живут снаружи и приходят сюда уже готовыми событиями.
public struct NotchStateMachine: Sendable {
    public private(set) var state: NotchState = .closed
    /// Вкладка, на которую вернёт хоткей.
    public private(set) var lastTab: NotchTab = .music
    public private(set) var isFullScreen = false

    public init() {}

    /// Возвращает новое состояние, если оно изменилось, иначе nil.
    @discardableResult
    public mutating func handle(_ event: NotchEvent) -> NotchState? {
        guard let next = resolve(event), next != state else { return nil }
        if case .expanded(let tab) = next { lastTab = tab }
        state = next
        return next
    }

    private mutating func resolve(_ event: NotchEvent) -> NotchState? {
        if case .fullScreenChanged(let isActive) = event {
            isFullScreen = isActive
            // В фуллскрине меню-бар скрыт, а область выреза чёрная — панели негде жить.
            return isActive ? .closed : nil
        }
        guard !isFullScreen else { return nil }

        switch (state, event) {
        case (.closed, .cursorEnteredHotZone):
            return .peek(.hover)
        case (.closed, .trackChanged):
            return .peek(.trackChanged)
        case (.closed, .hotkey):
            return .expanded(lastTab)

        case (.peek, .click):
            return .expanded(.music)
        case (.peek, .hotkey):
            return .expanded(lastTab)
        case (.peek(.hover), .cursorLeftHotZone):
            return .closed
        case (.peek(.trackChanged), .peekTimedOut):
            return .closed
        case (.peek(.trackChanged), .cursorEnteredHotZone):
            return .peek(.hover)

        case (.expanded, .dismiss), (.expanded, .hotkey):
            return .closed
        case (.expanded, .selectTab(let tab)):
            return .expanded(tab)
        case (.expanded(let tab), .cycleTab):
            return .expanded(tab.next)

        // Уход курсора из развёрнутой панели её не закрывает: работа с лентой
        // буфера подразумевает движение мыши куда угодно.
        default:
            return nil
        }
    }
}
```

- [ ] **Step 5: Запустить тесты и убедиться, что они проходят**

Run: `swift test --package-path Packages/NotchKit --filter NotchStateMachineTests`
Expected: PASS, 14 тестов

Четырнадцатый тест добавлен после ревью: строка таблицы «peek + хоткей →
expanded(последняя вкладка)» была реализована, но не покрыта. Он должен
уводить `lastTab` на вкладку, отличную от `.music`, иначе не отличит
правильное поведение от подстановки музыки по умолчанию.

- [ ] **Step 6: Закоммитить**

```bash
git add Packages/NotchKit
git commit -m "feat: машина состояний панели с полной таблицей переходов"
```

---

### Task 5: Пороги курсора

Отдельно от машины, потому что здесь живёт время. Вход считается состоявшимся через
120 мс, выход — через 250 мс. Без этого панель дёргается всякий раз, когда курсор
проезжает мимо чёлки к меню-бару.

**Files:**
- Create: `Packages/NotchKit/Sources/NotchCore/HoverDebouncer.swift`
- Test: `Packages/NotchKit/Tests/NotchCoreTests/HoverDebouncerTests.swift`

**Interfaces:**
- Consumes: `NotchEvent` из Task 4
- Produces:
  - `HoverDebouncer.enterDwell = 0.120`, `.exitGrace = 0.250`
  - `mutating func cursorMoved(isInsideHotZone: Bool, at: Date) -> NotchEvent?`
  - `mutating func tick(at: Date) -> NotchEvent?`
  - `var hasPendingTransition: Bool` — по нему Task 8 решает, нужен ли таймер

**Инвариант, на который опирается машина состояний.** События входа и выхода
всегда парны: `.cursorLeftHotZone` испускается только после того, как был
испущен `.cursorEnteredHotZone`. Машина из Task 4 обрабатывает выход курсора
лишь из `peek(.hover)`; если бы дебаунсер мог выдать одиночный выход во время
автопика по смене трека, событие молча провалилось бы в `default`. Поле
`reported` и есть носитель этого инварианта — оно хранит то, о чём уже
сообщили наружу, и переход обратно возможен только из сообщённого состояния.

- [ ] **Step 1: Написать падающие тесты**

Создай `Packages/NotchKit/Tests/NotchCoreTests/HoverDebouncerTests.swift`:

```swift
import Testing
import Foundation
@testable import NotchCore

private let t0 = Date(timeIntervalSince1970: 1_000_000)
private func at(_ offset: TimeInterval) -> Date { t0.addingTimeInterval(offset) }

@Test("проезд мимо чёлки за 100 мс не открывает панель")
func briefPassByDoesNotTrigger() {
    var debouncer = HoverDebouncer()
    #expect(debouncer.cursorMoved(isInsideHotZone: true, at: at(0)) == nil)
    #expect(debouncer.cursorMoved(isInsideHotZone: false, at: at(0.100)) == nil)
    #expect(debouncer.tick(at: at(0.500)) == nil)
}

@Test("задержка 120 мс в зоне открывает панель")
func dwellTriggersEnter() {
    var debouncer = HoverDebouncer()
    debouncer.cursorMoved(isInsideHotZone: true, at: at(0))
    #expect(debouncer.tick(at: at(0.119)) == nil)
    #expect(debouncer.tick(at: at(0.120)) == .cursorEnteredHotZone)
}

@Test("после входа краткий выход не закрывает панель")
func briefExitDoesNotClose() {
    var debouncer = HoverDebouncer()
    debouncer.cursorMoved(isInsideHotZone: true, at: at(0))
    debouncer.tick(at: at(0.120))
    debouncer.cursorMoved(isInsideHotZone: false, at: at(0.200))
    #expect(debouncer.cursorMoved(isInsideHotZone: true, at: at(0.400)) == nil)
    #expect(debouncer.tick(at: at(1.000)) == nil)
}

@Test("выход дольше 250 мс закрывает панель")
func sustainedExitTriggersLeave() {
    var debouncer = HoverDebouncer()
    debouncer.cursorMoved(isInsideHotZone: true, at: at(0))
    debouncer.tick(at: at(0.120))
    debouncer.cursorMoved(isInsideHotZone: false, at: at(0.200))
    #expect(debouncer.tick(at: at(0.449)) == nil)
    #expect(debouncer.tick(at: at(0.450)) == .cursorLeftHotZone)
}

@Test("событие сообщается один раз")
func eventIsReportedOnce() {
    var debouncer = HoverDebouncer()
    debouncer.cursorMoved(isInsideHotZone: true, at: at(0))
    #expect(debouncer.tick(at: at(0.120)) == .cursorEnteredHotZone)
    #expect(debouncer.tick(at: at(0.500)) == nil)
}

@Test("ожидание перехода видно снаружи — по нему включается таймер")
func pendingTransitionIsObservable() {
    var debouncer = HoverDebouncer()
    #expect(debouncer.hasPendingTransition == false)
    debouncer.cursorMoved(isInsideHotZone: true, at: at(0))
    #expect(debouncer.hasPendingTransition == true)
    debouncer.tick(at: at(0.120))
    #expect(debouncer.hasPendingTransition == false)
}
```

- [ ] **Step 2: Запустить тесты и убедиться, что они падают**

Run: `swift test --package-path Packages/NotchKit --filter HoverDebouncerTests`
Expected: FAIL — `cannot find 'HoverDebouncer' in scope`

- [ ] **Step 3: Написать реализацию**

Создай `Packages/NotchKit/Sources/NotchCore/HoverDebouncer.swift`:

```swift
import Foundation

/// Превращает сырое положение курсора в события входа и выхода,
/// выдерживая пороги. Время приходит снаружи параметром — поэтому
/// тесты не ждут ни миллисекунды.
public struct HoverDebouncer: Sendable {
    /// Сколько курсор должен продержаться в зоне, чтобы открыть панель.
    public static let enterDwell: TimeInterval = 0.120
    /// Сколько курсор должен пробыть снаружи, чтобы панель закрылась.
    public static let exitGrace: TimeInterval = 0.250

    /// Фактическое положение курсора.
    private var isInside = false
    /// Положение, о котором уже сообщили наружу.
    private var reported = false
    private var changedAt: Date?

    public init() {}

    /// Есть ли переход, ожидающий истечения порога.
    /// Пока значение ложно, таймер опроса не нужен — в простое приложение спит.
    public var hasPendingTransition: Bool { isInside != reported }

    @discardableResult
    public mutating func cursorMoved(isInsideHotZone: Bool, at now: Date) -> NotchEvent? {
        if isInsideHotZone != isInside {
            isInside = isInsideHotZone
            changedAt = now
        }
        return evaluate(at: now)
    }

    /// Вызывается по таймеру: пороги должны срабатывать и когда курсор замер.
    @discardableResult
    public mutating func tick(at now: Date) -> NotchEvent? {
        evaluate(at: now)
    }

    private mutating func evaluate(at now: Date) -> NotchEvent? {
        guard hasPendingTransition, let changedAt else { return nil }
        let threshold = isInside ? Self.enterDwell : Self.exitGrace
        guard now.timeIntervalSince(changedAt) >= threshold else { return nil }
        reported = isInside
        return isInside ? .cursorEnteredHotZone : .cursorLeftHotZone
    }
}
```

- [ ] **Step 4: Запустить тесты и убедиться, что они проходят**

Run: `swift test --package-path Packages/NotchKit --filter HoverDebouncerTests`
Expected: PASS, 6 тестов

- [ ] **Step 5: Закоммитить**

```bash
git add Packages/NotchKit
git commit -m "feat: пороги входа и выхода курсора из горячей зоны"
```

---

### Task 6: Форма чёлки

Одна `Shape` с анимируемыми размерами и вогнутыми верхними углами. Вогнутость —
не украшение: именно она создаёт впечатление, что панель вылита заодно с корпусом.

**Files:**
- Create: `Packages/NotchKit/Sources/NotchUI/NotchShape.swift`
- Delete: `Packages/NotchKit/Sources/NotchUI/NotchUIPlaceholder.swift`
- Modify: `Packages/NotchKit/Package.swift` — объявить тест-таргет
- Test: `Packages/NotchKit/Tests/NotchUITests/NotchShapeTests.swift`

Перед тестами добавь в массив `targets` файла `Package.swift`:

```swift
        .testTarget(name: "NotchUITests", dependencies: ["NotchUI"]),
```

**Interfaces:**
- Consumes: ничего
- Produces: `NotchShape(width:height:bottomRadius:concaveRadius:)`, соответствует
  протоколу `Shape`, реализует `animatableData`

- [ ] **Step 1: Написать падающие тесты**

Создай `Packages/NotchKit/Tests/NotchUITests/NotchShapeTests.swift`:

```swift
import Testing
import SwiftUI
@testable import NotchUI

private let canvas = CGRect(x: 0, y: 0, width: 600, height: 400)

@Test("высота фигуры равна заданной, ширина включает вогнутые уши")
func shapeRespectsExplicitSize() {
    let shape = NotchShape(width: 300, height: 150, bottomRadius: 22, concaveRadius: 10)
    let bounds = shape.path(in: canvas).boundingRect
    // width задаёт корпус; уши по 10 pt с каждой стороны выходят за него наружу.
    #expect(abs(bounds.width - 320) < 1)
    #expect(abs(bounds.height - 150) < 1)
}

@Test("фигура центрирована по горизонтали и прижата к верху")
func shapeIsCenteredAtTop() {
    let shape = NotchShape(width: 300, height: 150, bottomRadius: 22, concaveRadius: 10)
    let bounds = shape.path(in: canvas).boundingRect
    #expect(abs(bounds.midX - canvas.midX) < 1)
    #expect(abs(bounds.minY) < 1)
}

@Test("вогнутые уши расширяют фигуру ровно на два радиуса")
func topCornersFlareOutward() {
    let plain = NotchShape(width: 300, height: 150, bottomRadius: 22, concaveRadius: 0)
    let flared = NotchShape(width: 300, height: 150, bottomRadius: 22, concaveRadius: 12)
    #expect(abs(plain.path(in: canvas).boundingRect.width - 300) < 1)
    #expect(abs(flared.path(in: canvas).boundingRect.width - 324) < 1)
}

@Test("ниже вогнутого скругления корпус строго вертикален")
func bodyIsVerticalBelowEars() {
    let shape = NotchShape(width: 300, height: 150, bottomRadius: 22, concaveRadius: 12)
    let path = shape.path(in: canvas)
    let bodyLeft = canvas.midX - 150
    // y = 60 ниже уха (12 pt) и выше нижнего скругления (150 - 22 = 128).
    #expect(path.contains(CGPoint(x: bodyLeft + 4, y: 60)) == true)
    #expect(path.contains(CGPoint(x: bodyLeft - 4, y: 60)) == false)
}

@Test("анимируемые данные переносят размеры туда и обратно")
func animatableDataRoundTrips() {
    var shape = NotchShape(width: 100, height: 50, bottomRadius: 8, concaveRadius: 6)
    shape.animatableData = NotchShape(
        width: 300, height: 150, bottomRadius: 22, concaveRadius: 6
    ).animatableData
    #expect(shape.width == 300)
    #expect(shape.height == 150)
    #expect(shape.bottomRadius == 22)
}
```

- [ ] **Step 2: Запустить тесты и убедиться, что они падают**

Run: `swift test --package-path Packages/NotchKit --filter NotchShapeTests`
Expected: FAIL — `cannot find 'NotchShape' in scope`

- [ ] **Step 3: Написать реализацию**

Удали заглушку и создай `Packages/NotchKit/Sources/NotchUI/NotchShape.swift`:

```swift
import SwiftUI

/// Силуэт панели: прямоугольник, прижатый к верхней кромке экрана,
/// с округлыми нижними углами и вогнутыми верхними.
///
/// Вогнутые углы — главная деталь: они делают стык с корпусом литым,
/// как будто панель вытекает из выреза, а не лежит поверх него.
public struct NotchShape: Shape {
    public var width: CGFloat
    public var height: CGFloat
    public var bottomRadius: CGFloat
    public var concaveRadius: CGFloat

    public init(width: CGFloat, height: CGFloat, bottomRadius: CGFloat, concaveRadius: CGFloat) {
        self.width = width
        self.height = height
        self.bottomRadius = bottomRadius
        self.concaveRadius = concaveRadius
    }

    public var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(width, height), bottomRadius) }
        set {
            width = newValue.first.first
            height = newValue.first.second
            bottomRadius = newValue.second
        }
    }

    public func path(in rect: CGRect) -> Path {
        // Радиусы не должны съедать фигуру целиком на маленьких размерах.
        let bottom = min(bottomRadius, height / 2, width / 2)
        let concave = min(concaveRadius, height / 2, width / 2)

        let left = rect.midX - width / 2
        let right = rect.midX + width / 2
        let top = rect.minY
        let bottomY = rect.minY + height

        var path = Path()
        path.move(to: CGPoint(x: left - concave, y: top))
        // Левый вогнутый угол: дуга выгибается внутрь панели.
        path.addQuadCurve(
            to: CGPoint(x: left, y: top + concave),
            control: CGPoint(x: left, y: top)
        )
        path.addLine(to: CGPoint(x: left, y: bottomY - bottom))
        path.addQuadCurve(
            to: CGPoint(x: left + bottom, y: bottomY),
            control: CGPoint(x: left, y: bottomY)
        )
        path.addLine(to: CGPoint(x: right - bottom, y: bottomY))
        path.addQuadCurve(
            to: CGPoint(x: right, y: bottomY - bottom),
            control: CGPoint(x: right, y: bottomY)
        )
        path.addLine(to: CGPoint(x: right, y: top + concave))
        // Правый вогнутый угол.
        path.addQuadCurve(
            to: CGPoint(x: right + concave, y: top),
            control: CGPoint(x: right, y: top)
        )
        path.closeSubpath()
        return path
    }
}
```

- [ ] **Step 4: Запустить тесты и убедиться, что они проходят**

Run: `swift test --package-path Packages/NotchKit --filter NotchShapeTests`
Expected: PASS, 5 тестов

Если `topCornersFlareOutward` даёт ширину 300 вместо 324, значит контур начинается
в `left`, а не в `left - concave`: уши должны выходить наружу от корпуса, иначе стык
с меню-баром получится прямым углом.

- [ ] **Step 5: Закоммитить**

```bash
git add Packages/NotchKit
git commit -m "feat: форма панели с вогнутыми верхними углами"
```

---

### Task 7: Панель-окно

Самая капризная часть проекта. Юнит-тестами не покрывается — проверяется руками
по чек-листу, и этот чек-лист обязателен.

**Files:**
- Create: `App/NotchPanel.swift`
- Create: `App/ScreenMetricsReader.swift`
- Modify: `App/AppDelegate.swift`

**Interfaces:**
- Consumes: `NotchGeometryCalculator`, `ScreenMetrics` из Task 3; `NotchShape` из Task 6
- Produces:
  - `NotchPanel(contentRect:rootView:)`, свойство `acceptsKeyboard: Bool`
  - `ScreenMetricsReader.metrics(for: NSScreen) -> ScreenMetrics`
  - `ScreenMetricsReader.builtInScreen() -> NSScreen?`

- [ ] **Step 1: Написать мост от NSScreen к ScreenMetrics**

Создай `App/ScreenMetricsReader.swift`:

```swift
import AppKit
import NotchCore

/// Единственное место, где AppKit превращается в чистые метрики.
/// Всё остальное приложение работает уже со ScreenMetrics.
enum ScreenMetricsReader {
    static func metrics(for screen: NSScreen) -> ScreenMetrics {
        ScreenMetrics(
            frame: screen.frame,
            safeAreaTopInset: screen.safeAreaInsets.top,
            auxiliaryTopLeftWidth: screen.auxiliaryTopLeftArea?.width ?? 0,
            auxiliaryTopRightWidth: screen.auxiliaryTopRightArea?.width ?? 0
        )
    }

    /// Экран с чёлкой. Первая версия живёт только на встроенном дисплее.
    static func builtInScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
    }
}
```

- [ ] **Step 2: Написать панель**

Создай `App/NotchPanel.swift`:

```swift
import AppKit
import SwiftUI

/// Окно панели. Размер постоянен и равен максимальному развороту:
/// менять фрейм NSWindow во время пружины — значит получить рывки,
/// поэтому анимируется только содержимое внутри.
final class NotchPanel: NSPanel {
    /// Разрешает панели стать key-окном. Включается только на время
    /// разворота с полем поиска, иначе панель отобрала бы фокус
    /// у приложения, куда мы собираемся вставлять текст.
    var acceptsKeyboard = false

    override var canBecomeKey: Bool { acceptsKeyboard }
    override var canBecomeMain: Bool { false }

    init(contentRect: CGRect, rootView: some View) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        // Выше меню-бара: панель должна перекрывать его, а не прятаться под ним.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenNone, .ignoresCycle]

        isOpaque = false
        backgroundColor = .clear
        // Тень рисуем сами — системная не умеет вогнутые углы.
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        // По умолчанию окно прозрачно для мыши, иначе оно перехватит
        // клики по меню-бару. Включается в Task 8, когда курсор входит в зону.
        ignoresMouseEvents = true

        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = CGRect(origin: .zero, size: contentRect.size)
        contentView = hosting
    }
}
```

- [ ] **Step 3: Показать панель с временным содержимым**

Замени `App/AppDelegate.swift`:

```swift
import AppKit
import SwiftUI
import NotchCore
import NotchUI

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NotchPanel?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = ScreenMetricsReader.builtInScreen(),
              let geometry = NotchGeometryCalculator.geometry(
                  for: ScreenMetricsReader.metrics(for: screen)
              )
        else {
            NSLog("Notchka: дисплей с чёлкой не найден, панель не создана")
            return
        }

        // Окно фиксировано по максимальному развороту и центрировано над вырезом.
        let panelSize = CGSize(width: 640, height: 260)
        let origin = CGPoint(
            x: screen.frame.midX - panelSize.width / 2,
            y: screen.frame.maxY - panelSize.height
        )
        let frame = CGRect(origin: origin, size: panelSize)

        let panel = NotchPanel(
            contentRect: frame,
            rootView: DebugNotchView(
                notchWidth: geometry.notchRect.width,
                notchHeight: geometry.notchRect.height
            )
        )
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        self.panel = panel
    }
}

/// Временная вьюха: рисует силуэт в размер настоящего выреза,
/// чтобы проверить попадание панели в чёлку. Уходит в Task 9.
private struct DebugNotchView: View {
    let notchWidth: CGFloat
    let notchHeight: CGFloat

    var body: some View {
        NotchShape(
            width: notchWidth,
            height: notchHeight,
            bottomRadius: 10,
            concaveRadius: 8
        )
        .fill(.red.opacity(0.6))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
```

- [ ] **Step 4: Собрать и запустить**

```bash
xcodegen generate
xcodebuild -project Notchka.xcodeproj -scheme Notchka -configuration Debug \
  -derivedDataPath build build
open build/Build/Products/Debug/Notchka.app
```

Expected: красный силуэт **точно накрывает физическую чёлку** — не шире, не уже,
не смещён. Если не совпал, проверь `auxiliaryTopLeftArea` в Step 1: на некоторых
конфигурациях он приходит `nil`, и ширина считается неверно.

- [ ] **Step 5: Пройти чек-лист поведения окна**

Проверь руками, отмечая каждый пункт:

- [ ] Панель видна поверх меню-бара
- [ ] Клик по меню «Файл» активного приложения проходит насквозь и открывает меню
- [ ] Открыт TextEdit, набор текста продолжает попадать в него — панель не крадёт фокус
- [ ] Переключение на другой Space: панель на месте
- [ ] Переход приложения в фуллскрин: панель не мешает и не мигает поверх
- [ ] В `Мониторинге системы` процесс Notchka в покое даёт около нуля процентов CPU

Любой невыполненный пункт чинится здесь и сейчас — дальше по плану он станет дороже.

- [ ] **Step 6: Закоммитить**

```bash
pkill -x Notchka
git add App
git commit -m "feat: панель-окно над меню-баром без перехвата фокуса"
```

---

### Task 8: Курсор, хоткей и подключение машины

**Files:**
- Create: `App/CursorMonitor.swift`
- Create: `App/HotkeyCenter.swift`
- Create: `App/NotchController.swift`
- Modify: `App/AppDelegate.swift`

**Interfaces:**
- Consumes: `NotchStateMachine`, `HoverDebouncer`, `NotchGeometry` из Tasks 3–5;
  `NotchPanel` из Task 7
- Produces: `NotchController`, публикующий `state: NotchState` через `@Observable`;
  метод `handle(_ event: NotchEvent)`

- [ ] **Step 1: Написать монитор курсора**

Создай `App/CursorMonitor.swift`:

```swift
import AppKit

/// Следит за положением курсора. Глобальный монитор мыши разрешений
/// не требует — в отличие от монитора клавиатуры.
///
/// Таймер запускается только когда есть ожидающий порог: в покое
/// приложение не должно просыпаться 20 раз в секунду.
@MainActor
final class CursorMonitor {
    private var monitor: Any?
    private var timer: Timer?
    private var onSample: ((CGPoint, Date) -> Void)?

    /// Шаг опроса, пока ждём истечения порога. 50 мс достаточно:
    /// самый короткий порог — 120 мс.
    private static let tickInterval: TimeInterval = 0.05

    func start(onSample: @escaping (CGPoint, Date) -> Void) {
        self.onSample = onSample
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.emit()
            }
        }
    }

    /// Включается контроллером, когда у порога есть незавершённый переход.
    func setTicking(_ isTicking: Bool) {
        guard isTicking != (timer != nil) else { return }
        if isTicking {
            timer = Timer.scheduledTimer(
                withTimeInterval: Self.tickInterval, repeats: true
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.emit() }
            }
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        setTicking(false)
    }

    deinit {
        // Тот же приём и то же обоснование, что в HotkeyCenter.deinit.
        MainActor.assumeIsolated { stop() }
    }

    private func emit() {
        onSample?(NSEvent.mouseLocation, Date())
    }
}
```

- [ ] **Step 2: Написать глобальный хоткей**

Создай `App/HotkeyCenter.swift`:

```swift
import AppKit
import Carbon.HIToolbox

/// Глобальный хоткей через Carbon. Выбран сознательно:
/// NSEvent.addGlobalMonitorForEvents(matching: .keyDown) потребовал бы
/// разрешения Accessibility ещё до того, как оно понадобится для вставки.
///
/// Переназначение хоткея из настроек появится в плане 4 — тогда сюда
/// заедет KeyboardShortcuts, которая является обёрткой над этим же API.
@MainActor
final class HotkeyCenter {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var onFire: (() -> Void)?

    private static let signature = OSType(0x4E4F5443)  // 'NOTC'
    private static let hotKeyID: UInt32 = 1

    /// По умолчанию ⌥Space: ⌘Space занят Spotlight.
    func register(
        keyCode: UInt32 = UInt32(kVK_Space),
        modifiers: UInt32 = UInt32(optionKey),
        onFire: @escaping () -> Void
    ) {
        unregister()
        self.onFire = onFire

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData, let event else { return noErr }
                var firedID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &firedID
                )
                guard firedID.signature == HotkeyCenter.signature,
                      firedID.id == HotkeyCenter.hotKeyID
                else { return noErr }

                let center = Unmanaged<HotkeyCenter>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                // Carbon-обработчик вызывается на главном цикле выполнения.
                MainActor.assumeIsolated { center.onFire?() }
                return noErr
            },
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )

        let id = EventHotKeyID(signature: Self.signature, id: Self.hotKeyID)
        let status = RegisterEventHotKey(
            keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef
        )
        guard status == noErr else {
            // Без этого лога отказ регистрации неотличим от хоткея, который
            // просто никто не нажимает — единственный способ узнать причину
            // у пользователя ежедневного инструмента это системный лог.
            NSLog(
                "Notchka: регистрация хоткея не удалась (keyCode=\(keyCode), modifiers=\(modifiers)), OSStatus=\(status). Вероятная причина: сочетание уже занято другим приложением или системой."
            )
            return
        }
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
```

- [ ] **Step 3: Связать всё в контроллере**

Создай `App/NotchController.swift`:

```swift
import AppKit
import Observation
import NotchCore

/// Сводит воедино источники событий и машину состояний.
/// Здесь же живёт правило: окно ловит мышь только когда панель раскрыта
/// или курсор в горячей зоне — иначе меню-бар был бы недоступен.
@MainActor
@Observable
final class NotchController {
    private(set) var state: NotchState = .closed

    @ObservationIgnored private var machine = NotchStateMachine()
    @ObservationIgnored private var debouncer = HoverDebouncer()
    @ObservationIgnored private let cursor = CursorMonitor()
    @ObservationIgnored private let hotkey = HotkeyCenter()
    @ObservationIgnored private let geometry: NotchGeometry
    @ObservationIgnored private let screenFrame: CGRect
    @ObservationIgnored private weak var panel: NotchPanel?

    init(geometry: NotchGeometry, screenFrame: CGRect, panel: NotchPanel) {
        self.geometry = geometry
        self.screenFrame = screenFrame
        self.panel = panel
    }

    func start() {
        cursor.start { [weak self] location, now in
            self?.cursorSampled(at: location, now: now)
        }
        hotkey.register { [weak self] in
            self?.handle(.hotkey)
        }
    }

    deinit {
        // Тот же приём и то же обоснование, что в HotkeyCenter.deinit.
        MainActor.assumeIsolated {
            cursor.stop()
            hotkey.unregister()
        }
    }

    func handle(_ event: NotchEvent) {
        guard machine.handle(event) != nil else { return }
        state = machine.state
        syncMouseHandling()
    }

    private func cursorSampled(at location: CGPoint, now: Date) {
        // NSEvent.mouseLocation задан в глобальных координатах AppKit: начало
        // отсчёта — левый нижний угол всей раскладки мониторов, Y растёт вверх;
        // это начало не обязано совпадать с левым нижним углом именно этого
        // экрана (при нескольких дисплеях у screenFrame бывает ненулевой origin).
        // NotchGeometry.hotZone, наоборот, всегда задана относительно своего
        // экрана с началом в левом верхнем углу. Поэтому X переводится сдвигом
        // на screenFrame.origin.x — переворота нет, в обеих системах X растёт
        // вправо, — а Y вычитанием из screenFrame.maxY: здесь сдвиг и переворот
        // совпадают в одном действии, потому что maxY уже равен origin.y + height.
        let screenRelative = CGPoint(
            x: location.x - screenFrame.origin.x,
            y: screenFrame.maxY - location.y
        )
        let isInside = geometry.hotZone.contains(screenRelative)

        if let event = debouncer.cursorMoved(isInsideHotZone: isInside, at: now) {
            handle(event)
        }
        cursor.setTicking(debouncer.hasPendingTransition)
    }

    /// Прозрачность окна для мыши. Закрытая панель не должна мешать меню-бару.
    private func syncMouseHandling() {
        guard let panel else { return }
        switch state {
        case .closed:
            panel.ignoresMouseEvents = true
            panel.acceptsKeyboard = false
        case .peek:
            panel.ignoresMouseEvents = false
            panel.acceptsKeyboard = false
        case .expanded:
            panel.ignoresMouseEvents = false
            panel.acceptsKeyboard = true
        }
    }
}
```

- [ ] **Step 4: Подключить контроллер и показать состояние**

В `App/AppDelegate.swift` замени `DebugNotchView` на версию, читающую состояние,
и создай контроллер после панели:

```swift
private struct DebugNotchView: View {
    let controller: NotchController
    let notchWidth: CGFloat
    let notchHeight: CGFloat

    var body: some View {
        NotchShape(
            width: currentWidth,
            height: currentHeight,
            bottomRadius: currentHeight > 60 ? 22 : 10,
            concaveRadius: 8
        )
        .fill(.black)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(animation, value: controller.state)
    }

    private var currentWidth: CGFloat {
        switch controller.state {
        case .closed: notchWidth
        case .peek: notchWidth + 120
        case .expanded: 620
        }
    }

    private var currentHeight: CGFloat {
        switch controller.state {
        case .closed: notchHeight
        case .peek: notchHeight + 28
        case .expanded: 200
        }
    }

    private var animation: Animation {
        if case .closed = controller.state {
            return .snappy(duration: 0.26)
        }
        return .spring(response: 0.34, dampingFraction: 0.68)
    }
}
```

В `applicationDidFinishLaunching` после создания панели:

```swift
        let controller = NotchController(
            geometry: geometry,
            screenFrame: screen.frame,
            panel: panel
        )
        panel.contentView = NSHostingView(
            rootView: DebugNotchView(
                controller: controller,
                notchWidth: geometry.notchRect.width,
                notchHeight: geometry.notchRect.height
            )
        )
        controller.start()
        self.controller = controller
```

Добавь свойство `private var controller: NotchController?` рядом с `panel`.

- [ ] **Step 5: Собрать и проверить живое поведение**

```bash
xcodegen generate
xcodebuild -project Notchka.xcodeproj -scheme Notchka -configuration Debug \
  -derivedDataPath build build
open build/Build/Products/Debug/Notchka.app
```

Проверь руками:

- [ ] Наведение на чёлку раскрывает её в peek с пружиной, без рывка
- [ ] Быстрый проезд курсором мимо чёлки её **не** раскрывает
- [ ] `⌥Space` разворачивает панель на полную, повторное нажатие сворачивает
- [ ] В развёрнутом состоянии увод курсора вниз панель не закрывает
- [ ] Когда панель закрыта, меню-бар кликается как обычно
- [ ] В `Мониторинге системы` в покое CPU около нуля, при наведении кратковременно растёт

- [ ] **Step 6: Закоммитить**

```bash
pkill -x Notchka
git add App
git commit -m "feat: курсор, глобальный хоткей и подключение машины состояний"
```

---

### Task 9: Реакция на Reduce Motion

Требование спеки: при включённом системном Reduce Motion морф заменяется кросс-фейдом.
Логика выбора анимации чистая, поэтому тестируется.

**Files:**
- Create: `Packages/NotchKit/Sources/NotchUI/NotchMotion.swift`
- Modify: `App/AppDelegate.swift`
- Test: `Packages/NotchKit/Tests/NotchUITests/NotchMotionTests.swift`

**Interfaces:**
- Consumes: `NotchState` из Task 4
- Produces: `NotchMotion.animation(for: NotchState, reduceMotion: Bool) -> Animation`
  и `NotchMotion.usesMorph(reduceMotion: Bool) -> Bool`

- [ ] **Step 1: Написать падающие тесты**

Создай `Packages/NotchKit/Tests/NotchUITests/NotchMotionTests.swift`:

```swift
import Testing
import SwiftUI
import NotchCore
@testable import NotchUI

@Test("открытие и разворот идут упругой пружиной")
func openingUsesSpring() {
    let opening = NotchMotion.animation(for: .peek(.hover), reduceMotion: false)
    #expect(opening == .spring(response: 0.34, dampingFraction: 0.68))

    let expanding = NotchMotion.animation(for: .expanded(.music), reduceMotion: false)
    #expect(expanding == .spring(response: 0.34, dampingFraction: 0.68))
}

@Test("закрытие быстрее открытия")
func closingIsSnappy() {
    #expect(NotchMotion.animation(for: .closed, reduceMotion: false)
            == .snappy(duration: 0.26))
}

@Test("при Reduce Motion пружина заменяется линейным затуханием")
func reduceMotionReplacesSpring() {
    let reduced = NotchMotion.animation(for: .expanded(.music), reduceMotion: true)
    #expect(reduced == .easeInOut(duration: 0.18))
    #expect(NotchMotion.usesMorph(reduceMotion: true) == false)
    #expect(NotchMotion.usesMorph(reduceMotion: false) == true)
}
```

- [ ] **Step 2: Запустить тесты и убедиться, что они падают**

Run: `swift test --package-path Packages/NotchKit --filter NotchMotionTests`
Expected: FAIL — `cannot find 'NotchMotion' in scope`

- [ ] **Step 3: Написать реализацию**

Создай `Packages/NotchKit/Sources/NotchUI/NotchMotion.swift`:

```swift
import SwiftUI
import NotchCore

/// Все параметры движения собраны в одном месте, чтобы физика панели
/// не расползлась по вьюхам и её можно было проверить тестами.
public enum NotchMotion {
    public static let opening = Animation.spring(response: 0.34, dampingFraction: 0.68)
    public static let closing = Animation.snappy(duration: 0.26)
    /// При Reduce Motion пружина неуместна: пользователь просил её не показывать.
    public static let reduced = Animation.easeInOut(duration: 0.18)

    public static func animation(for state: NotchState, reduceMotion: Bool) -> Animation {
        guard !reduceMotion else { return reduced }
        return state == .closed ? closing : opening
    }

    /// Нужно ли морфить форму. При Reduce Motion форма меняется мгновенно,
    /// а переход отдаётся прозрачности.
    public static func usesMorph(reduceMotion: Bool) -> Bool { !reduceMotion }
}
```

- [ ] **Step 4: Запустить тесты и убедиться, что они проходят**

Run: `swift test --package-path Packages/NotchKit --filter NotchMotionTests`
Expected: PASS, 3 теста

- [ ] **Step 5: Подключить к вьюхе**

В `DebugNotchView` внутри `App/AppDelegate.swift` замени приватное свойство `animation`
на чтение системной настройки:

```swift
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var animation: Animation {
        NotchMotion.animation(for: controller.state, reduceMotion: reduceMotion)
    }
```

- [ ] **Step 6: Проверить вручную**

Включи `Системные настройки → Универсальный доступ → Монитор → Уменьшение движения`,
перезапусти приложение.

Expected: панель раскрывается затуханием без пружинного перелёта.

Верни настройку обратно.

- [ ] **Step 7: Закоммитить**

```bash
git add Packages/NotchKit App
git commit -m "feat: единые параметры движения и поддержка Reduce Motion"
```

---

### Task 10: Приёмка фундамента

Проверка, что фундамент действительно готов принять план 2, и фиксация оставшихся
шероховатостей.

**Files:**
- Create: `docs/superpowers/notes/2026-08-10-foundation-acceptance.md`

**Interfaces:**
- Consumes: всё выше
- Produces: отчёт о приёмке

- [ ] **Step 1: Прогнать все тесты**

```bash
swift test --package-path Packages/NotchKit
```

Expected: PASS, 32 теста (4 геометрия + 14 машина + 6 пороги + 5 форма + 3 движение)

- [ ] **Step 2: Собрать релизную конфигурацию**

```bash
xcodebuild -project Notchka.xcodeproj -scheme Notchka -configuration Release \
  -derivedDataPath build build
```

Expected: `** BUILD SUCCEEDED **`, ноль предупреждений компилятора.
Предупреждения строгой конкурентности чинятся здесь — в плане 2 их станет труднее ловить.

- [ ] **Step 3: Проверить расход в покое**

Запусти приложение, не трогай мышь минуту, посмотри `Мониторинг системы`.

Expected: CPU процесса Notchka около нуля, таймер в покое не крутится.

Если процент заметный — проверь, что `CursorMonitor.setTicking(false)` действительно
вызывается после срабатывания порога.

- [ ] **Step 4: Записать отчёт**

Создай `docs/superpowers/notes/2026-08-10-foundation-acceptance.md` с реальными
результатами шагов 1–3, списком пунктов ручных чек-листов из Task 7 и Task 8
с отметками, и разделом «Осталось на потом» — всё, что заметил, но не чинил.

- [ ] **Step 5: Закоммитить**

```bash
git add docs/superpowers/notes
git commit -m "docs: приёмка фундамента Notchka"
```

---

## Что дальше

Планы 2–4 пишутся отдельно и опираются на этот:

- **План 2 — Музыка.** `MediaBridge` поверх путей и команд из спайка Task 1,
  вкладка плеера, извлечение акцентного цвета из обложки.
- **План 3 — Хранилище и буфер.** `NotchStore` на GRDB с FTS5, `ClipboardKit`
  с фильтрами приватности, горизонтальная лента, автовставка через CGEvent.
  Там же клавиатура из спеки §9: `⌘1`…`⌘4`, `⇥`, `Esc`, стрелки и `↩` подключаются
  к событиям `selectTab`, `cycleTab` и `dismiss`, которые машина уже умеет
  обрабатывать с Task 4, но которые пока никто не отправляет.
- **План 4 — Заметки, пины, поиск.** `StashKit`, сквозной поиск, настройки,
  онбординг разрешения Accessibility.
