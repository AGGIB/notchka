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
/// приватности и заканчивая хешированием, записью блоба и вставкой в базу,
/// работа уходит в фоновую задачу с приоритетом `.utility`: скопированный
/// мегабайтный скриншот не должен подвешивать панель.
@MainActor
final class ClipboardService {
    private let repository: ClipboardRepository
    private let privacyFilter: PrivacyFilter
    private var poller = PasteboardPoller()

    private var pollTimer: Timer?
    private var pruneTimer: Timer?

    // nonisolated: без этого статический logger унаследовал бы MainActor-
    // изоляцию класса и был бы недоступен из store()/pruneHistory() — обе
    // сознательно уводят работу с главного потока (см. их doc-комментарии).
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

    /// Один тик опроса. Целиком на главном потоке до момента передачи уже
    /// прочитанного содержимого в фоновую задачу — дальше в `store` этот
    /// поток не заходит.
    private func tick() {
        let changeCount = NSPasteboard.general.changeCount
        guard poller.shouldRead(changeCount: changeCount, idleSeconds: Self.idleSeconds()) else { return }
        guard let content = PasteboardReader.read() else { return }

        // Захват в локальные let, а не через self: замыкание ниже не должно
        // унаследовать MainActor-изоляцию через self, иначе Task(priority:)
        // выполнился бы на главном потоке — ровно там, где тяжёлой работе не
        // место.
        let repository = repository
        let privacyFilter = privacyFilter
        Task(priority: .utility) {
            Self.store(content: content, repository: repository, privacyFilter: privacyFilter)
        }
    }

    /// Фильтр приватности, хеширование, запись блоба и вставка в базу — вне
    /// главного потока.
    ///
    /// `nonisolated`: без этого статический метод @MainActor-класса унаследовал
    /// бы его изоляцию, и Task(priority: .utility) в tick() выше не увёл бы
    /// работу с главного потока.
    ///
    /// Порядок обязателен: `shouldCapture` проверяется первым, и только при
    /// положительном ответе что-либо попадает в репозиторий — ни одна ветка
    /// ниже не пишет в базу раньше фильтра.
    nonisolated private static func store(
        content: PasteboardReader.Content,
        repository: ClipboardRepository,
        privacyFilter: PrivacyFilter
    ) {
        guard privacyFilter.shouldCapture(content.snapshot) else { return }

        let source = content.snapshot.sourceBundleID.map { bundleID in
            (bundleID: bundleID, appName: PasteboardReader.appName(for: bundleID) ?? bundleID)
        }

        do {
            // Порядок ветвей — как в PasteboardReader.read(): файл раньше
            // картинки, картинка раньше текста, по той же причине (файл
            // может нести текстовое или графическое представление, но
            // показать его в истории надо файлом).
            if let fileName = content.fileName, let fileData = content.fileData {
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

    /// Приводит историю к пределам `RetentionPolicy.default`. Тоже вне
    /// главного потока: `prune` читает и, при срабатывании предела, удаляет
    /// записи по всей таблице — не тот объём работы, который стоит делать на
    /// потоке, рисующем панель.
    private func pruneHistory() {
        let repository = repository
        Task(priority: .utility) {
            do {
                try repository.prune(policy: .default)
            } catch {
                Self.logger.error("чистка истории буфера не удалась: \(error, privacy: .public)")
            }
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
