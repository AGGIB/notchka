import AppKit
import ClipboardKit
import NotchStore
import CoreGraphics
import os

/// Служба слежения за буфером обмена.
///
/// Раз в `PasteboardPoller.interval` сверяет `changeCount` и простой
/// пользователя на главном потоке — это дешёвое сравнение целого числа и
/// один системный вызов, так что таймер живёт рядом с остальными на главном
/// потоке, а не заводит себе отдельную очередь. Если поллер решил, что пора
/// читать, само чтение `NSPasteboard` тоже происходит здесь же, на главном
/// потоке (см. `PasteboardReader`) — а вот дальше, начиная с фильтра
/// приватности и заканчивая чтением файла, хешированием, записью блоба и
/// вставкой в базу, работа уходит с главного потока: скопированный
/// мегабайтный скриншот не должен подвешивать панель.
///
/// Уводит её именно `await` на `nonisolated async`-функции, а не сам по себе
/// `Task(priority: .utility)`: задача, созданная внутри метода этого класса,
/// наследует его MainActor, и приоритет на исполнителя не влияет. Тонкость
/// неочевидная — на ней в этой ветке спотыкались трижды.
@MainActor
final class ClipboardService {
    private let repository: ClipboardRepository
    private let privacyFilter: PrivacyFilter
    private var poller = PasteboardPoller()

    private var pollTimer: Timer?
    private var pruneTimer: Timer?

    // nonisolated: без этого статический logger унаследовал бы MainActor-
    // изоляцию класса и был бы недоступен из store()/prune()/readFile() —
    // все три исполняются вне главного потока (см. их doc-комментарии).
    // Logger — Sendable, значение неизменно, гонки исключены.
    nonisolated private static let logger = Logger(subsystem: "kz.mobilefirst.notchka", category: "ClipboardService")

    /// Как часто чистить историю, пока приложение работает. Не на каждую
    /// запись: проход по всей истории на каждое ⌘C — лишняя работа. Чистка
    /// при запуске идёт отдельно, один раз, в start().
    private static let pruneInterval: TimeInterval = 24 * 3600

    init(repository: ClipboardRepository, privacyFilter: PrivacyFilter = PrivacyFilter()) {
        self.repository = repository
        self.privacyFilter = privacyFilter
    }

    /// Поднимает опрос и чистку. Вызывать один раз за жизнь службы — тот же
    /// приём идемпотентности, что у `MusicViewModel.start()`.
    func start() {
        guard pollTimer == nil else { return }
        pruneHistory()

        // Timer создаётся вручную и добавляется в .common, а не через
        // scheduledTimer, — тот же приём и то же обоснование, что в
        // CursorMonitor.setTicking: в режиме .default таймер не тикает во
        // время отслеживания открытого меню (RunLoop.Mode.eventTracking), и
        // скопированное в этот момент терялось бы до следующего клика.
        let pollTimer = Timer(timeInterval: PasteboardPoller.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.current.add(pollTimer, forMode: .common)
        self.pollTimer = pollTimer

        let pruneTimer = Timer(timeInterval: Self.pruneInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pruneHistory() }
        }
        RunLoop.current.add(pruneTimer, forMode: .common)
        self.pruneTimer = pruneTimer
    }

    /// Останавливает оба таймера. Вызывается явно при выходе из приложения —
    /// тот же уклад, что у `MusicViewModel.stopAdapter()`: процесс уходит
    /// через exit() в обход раскрутки стека Swift (см. AppDelegate.shutDown),
    /// так что полагаться на deinit нельзя.
    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        pruneTimer?.invalidate()
        pruneTimer = nil
    }

    deinit {
        // Тот же приём и то же обоснование, что в CursorMonitor.deinit и
        // HotkeyCenter.deinit.
        MainActor.assumeIsolated { stop() }
    }

    /// Помечает текущее содержимое пастборда как своё.
    ///
    /// Зовётся после того, как приложение само что-то туда положило — когда
    /// пользователь достаёт запись из истории. Иначе опрос через доли секунды
    /// прочитает собственную запись обратно (см. `PasteboardPoller.ignore`).
    func ignoreOwnPasteboardWrite() {
        poller.ignore(changeCount: NSPasteboard.general.changeCount)
    }

    /// Один тик опроса. На главном потоке остаётся ровно то, что обязано:
    /// чтение пастборда и разрешение имени приложения-источника — и то и
    /// другое AppKit. Всё остальное уходит в `store`.
    private func tick() {
        let changeCount = NSPasteboard.general.changeCount
        guard poller.shouldRead(changeCount: changeCount, idleSeconds: Self.idleSeconds()) else { return }
        guard let content = PasteboardReader.read() else { return }

        // Имя приложения разрешается здесь, а не в store: NSWorkspace и
        // FileManager.displayName — тоже AppKit, и звать их с чужого потока
        // значило бы обменять один дефект на другой.
        let source = content.snapshot.sourceBundleID.map { bundleID in
            (bundleID: bundleID, appName: PasteboardReader.appName(for: bundleID) ?? bundleID)
        }

        let repository = repository
        let privacyFilter = privacyFilter
        Task(priority: .utility) {
            await Self.store(
                content: content, source: source,
                repository: repository, privacyFilter: privacyFilter
            )
        }
    }

    /// Фильтр приватности, чтение файла, хеширование, запись блоба и вставка
    /// в базу — вне главного потока.
    ///
    /// `nonisolated` **и** `async` — обязательно оба. Одного `nonisolated`
    /// мало: `Task {}`, созданный внутри метода @MainActor-класса, наследует
    /// его изоляцию, и синхронный вызов из него так и остаётся на главном
    /// потоке. Уводит с актора именно `await` на функции, не привязанной к
    /// нему. Ровно на этом уже споткнулись дважды в этой же ветке — в
    /// PasteboardReader и в ClipboardViewModel.writeTemporaryFile.
    ///
    /// Порядок обязателен: `shouldCapture` проверяется первым, и только при
    /// положительном ответе что-либо попадает в репозиторий — ни одна ветка
    /// ниже не пишет в базу раньше фильтра.
    nonisolated private static func store(
        content: PasteboardReader.Content,
        source: (bundleID: String, appName: String)?,
        repository: ClipboardRepository,
        privacyFilter: PrivacyFilter
    ) async {
        guard privacyFilter.shouldCapture(content.snapshot) else { return }

        do {
            // Порядок ветвей — как в PasteboardReader.read(): файл раньше
            // картинки, картинка раньше текста, по той же причине (файл
            // может нести текстовое или графическое представление, но
            // показать его в истории надо файлом).
            if let fileName = content.fileName, let fileURL = content.fileURL {
                // Байты файла читаются здесь, а не в PasteboardReader.read():
                // там главный поток, и обычное «скопировать файл» с сетевого
                // диска остановило бы весь цикл событий вместе с отрисовкой
                // панели. Здесь же это после фильтра — на отвергнутое
                // содержимое ввод-вывод не тратится вовсе.
                guard let fileData = try? await Self.readFile(at: fileURL) else {
                    // Между опросом и этим моментом файл могли переместить или
                    // удалить. Не повод для тревоги, но и не повод молчать:
                    // иначе пропажа записи в истории ничем не объяснима.
                    logger.notice(
                        "файл \(fileName, privacy: .public) не прочитан, в историю не попал"
                    )
                    return
                }
                try repository.saveFile(fileData, fileName: fileName, source: source)
            } else if let image = content.image {
                try repository.saveImage(image, source: source)
            } else if let text = content.text {
                try repository.saveText(text, source: source)
            }
        } catch {
            logger.error("не удалось сохранить содержимое буфера: \(error, privacy: .public)")
        }
    }

    /// Чтение файла отдельной `async`-функцией, а не выражением по месту:
    /// внутри уже асинхронной `store` обычный вызов вернулся бы на её
    /// исполнителя, а нужен именно уход с актора вызывающего.
    nonisolated private static func readFile(at url: URL) async throws -> Data {
        try Data(contentsOf: url)
    }

    /// Приводит историю к пределам `RetentionPolicy.default`. Тоже вне
    /// главного потока: `prune` читает всю таблицу и, при срабатывании
    /// предела, удаляет записи по одной отдельными транзакциями, а вместе с
    /// ними файлы блобов с диска — не тот объём работы, который стоит делать
    /// на потоке, рисующем панель.
    private func pruneHistory() {
        let repository = repository
        Task(priority: .utility) {
            await Self.prune(repository: repository)
        }
    }

    /// `async` по той же причине, что и `store`: без него чистка выполнилась
    /// бы на главном потоке, потому что породивший её Task унаследовал его.
    nonisolated private static func prune(repository: ClipboardRepository) async {
        do {
            try repository.prune(policy: .default)
        } catch {
            logger.error("чистка истории буфера не удалась: \(error, privacy: .public)")
        }
    }

    /// Простой пользователя в секундах.
    ///
    /// Не `.null` — это нулевое событие, а не «любое», и не отражает
    /// реальный ввод. `kCGAnyInputEventType` не имеет именованного случая в
    /// `CGEventType`, отсюда сырое значение. Проверено эмпирически (см.
    /// отчёт Task 6): при активной машине держится долями секунды и не
    /// растёт, пока идёт ввод.
    private static func idleSeconds() -> TimeInterval {
        let anyInput = CGEventType(rawValue: ~0)!
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }
}
