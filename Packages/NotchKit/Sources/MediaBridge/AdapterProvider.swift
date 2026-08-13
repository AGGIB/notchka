import Foundation
import os

/// Провайдер поверх perl-адаптера: держит поток живым и склеивает строки.
///
/// Насос на актор — не больше одного одновременно: `snapshots` кеширует
/// уже поднятый поток и задачу в `activePump` и на повторное обращение
/// отдаёт их же, а не поднимает второй процесс адаптера поверх первого
/// (подробности — на самом `snapshots`).
public actor AdapterProvider: NowPlayingProvider {
    private let paths: AdapterPaths
    private let logger = Logger(subsystem: "kz.mobilefirst.notchka", category: "media")
    private var process: AdapterProcess?

    /// Текущий поднятый насос: поток для потребителей и задача, которая его
    /// наполняет. Одно поле — гарантия того, что насосов не бывает больше
    /// одного одновременно; пишет его только `startPump()`.
    private var activePump: (stream: AsyncStream<NowPlayingSnapshot?>, task: Task<Void, Never>)?

    /// Сколько раз актор поднимал новый насос за свою жизнь.
    ///
    /// Существует только ради тестов. У `AsyncStream` и `Task` нет
    /// публичного способа сравнить два значения на идентичность, поэтому
    /// свойство «повторное обращение к `snapshots` не подняло второй насос»
    /// нельзя проверить равенством возвращаемых значений — счётчик такую
    /// проверку заменяет, не запуская perl.
    private(set) var pumpsStarted = 0

    /// Сколько поток обязан прожить, чтобы адаптер считался рабочим, а не
    /// умирающим сразу после подключения.
    ///
    /// Спайк намерил: первая строка после подключения — всегда служебная
    /// `{"diff":false,"payload":{}}`, а на команду до появления diff-строк в
    /// потоке уходят «сотни миллисекунд», не единицы секунд. 5 секунд —
    /// с большим запасом выше этого шума (старт процесса, первая строка,
    /// пара обменов), но заметно меньше первой по-настоящему чувствительной
    /// паузы эскалации, так что честно живой, но медленный адаптер не
    /// штрафуется наравне с тем, что падает сразу за служебной строкой.
    static let restartLivenessThreshold: TimeInterval = 5

    /// Чистая проверка «прожил достаточно», вынесенная из `pump(into:)`
    /// отдельной функцией специально ради юнит-теста: сам `pump` гоняет
    /// настоящий процесс адаптера и подъёмом изолированного потока не
    /// проверяется без perl, а эта проверка — обычное сравнение дат.
    static func survivedLongEnoughToResetBackoff(openedAt: Date, closedAt: Date) -> Bool {
        closedAt.timeIntervalSince(openedAt) >= Self.restartLivenessThreshold
    }

    public init(paths: AdapterPaths) {
        self.paths = paths
    }

    /// Поток снимков.
    ///
    /// Контракт: НЕ мультикаст. `AsyncStream` не размножает элементы между
    /// потребителями — если к уже поднятому потоку подключатся двое через
    /// `for await`, каждый снимок достанется ровно одному из них, а не
    /// продублируется обоим. Рассчитан на одного потребителя одновременно,
    /// как во всём плане сейчас; настоящую рассылку этот тип не реализует и
    /// не обязан.
    ///
    /// Повторное обращение, пока насос жив, отдаёт уже поднятый поток, а не
    /// поднимает второй. Насос перестаёт считаться живым сразу, как только
    /// его задачу отменили (единственный способ ей завершиться, см. `pump`)
    /// — тогда обращение поднимает новый, рабочий, а не отдаёт мёртвый.
    public var snapshots: AsyncStream<NowPlayingSnapshot?> {
        get async {
            if let activePump, !activePump.task.isCancelled {
                return activePump.stream
            }
            return startPump()
        }
    }

    public func send(_ command: MediaCommand) async throws {
        let adapter = process ?? AdapterProcess(paths: paths)
        process = adapter
        try await adapter.send(code: command.adapterCode)
    }

    /// Разовая пересинхронизация через `get` — см. doc протокола для
    /// причины, по которой она вообще нужна.
    ///
    /// Тот же `process`, что и у `send(_:)` выше, а не отдельное поле:
    /// `AdapterProcess` из этого поля — просто удобный держатель короткоживущих
    /// команд (`send`/`get` сами по себе не трогают `streamProcess`, тот
    /// принадлежит насосу в `pump(into:)`), заводить второй экземпляр под
    /// то же самое незачем.
    ///
    /// Накопитель `pump(into:)` (`SnapshotAccumulator`) сюда не привлекается
    /// и не обновляется: он локален для тела `pump(into:)` и существует
    /// ради того, чтобы мержить диффы поверх последнего снимка потока — а
    /// `get` уже отдаёт полное состояние, мержить не с чем. Это асимметрично
    /// по отношению к потоку (следующий дифф из потока, если он вообще
    /// придёт, ляжет поверх старой базы накопителя, а не поверх того, что
    /// вернул этот refresh), но чинить это не входит в задачу: сам дефект
    /// в том, что для интерцепции продолжения диффов и не бывает.
    public func refresh() async -> NowPlayingSnapshot? {
        let adapter = process ?? AdapterProcess(paths: paths)
        process = adapter
        do {
            return try await adapter.get()
        } catch {
            logger.error("не удалось выполнить пересинхронизацию get: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Немедленно и гарантированно останавливает насос: не просто просит
    /// отмены, а дожидается, пока pump(into:) реально дойдёт до конца
    /// (его собственный хвост уже шлёт SIGINT адаптеру через process?.stop()
    /// и закрывает continuation — см. pump(into:) ниже). Ленивого
    /// распространения отмены через AsyncStream (как это происходит при
    /// обычном отключении последнего потребителя) здесь недостаточно: тот
    /// путь ничего не гарантирует ВЫЗЫВАЮЩЕЙ стороне о том, что процесс уже
    /// остановлен к моменту возврата, а именно эта гарантия нужна перед
    /// выходом из приложения.
    public func shutdown() async {
        guard let activePump else { return }
        activePump.task.cancel()
        await activePump.task.value
    }

    /// Поднимает новый насос и запоминает его в `activePump`.
    ///
    /// `AsyncStream.makeStream`, а не `AsyncStream.init(_:)` с замыканием:
    /// в `activePump` нужно сохранить саму `Task`, а не только поток, а
    /// `Task` создаётся уже после того, как получена `continuation`.
    /// `makeStream` отдаёт `continuation` обычным значением синхронно, без
    /// замыкания, — весь код ниже линейный и не поднимает вопрос о том, что
    /// можно писать из тела `AsyncStream.init`, а что нет (ср. комментарий
    /// про `@Sendable`-замыкание в `AdapterProcess.lines()`).
    private func startPump() -> AsyncStream<NowPlayingSnapshot?> {
        let (stream, continuation) = AsyncStream.makeStream(of: NowPlayingSnapshot?.self)
        let task = Task { await self.pump(into: continuation) }
        continuation.onTermination = { _ in task.cancel() }
        activePump = (stream, task)
        pumpsStarted += 1
        return stream
    }

    /// Поднимает поток, склеивает строки и переподнимает его при обрыве.
    ///
    /// Новый `AdapterProcess` создаётся на каждую попытку, а не переиспользуется:
    /// у актора одно поле под текущий процесс без токена поколения, и его
    /// уборка при обрыве потока идёт отдельным detached `Task` (см.
    /// `AdapterProcess.lines()`). Повторный вызов `lines()` на одном и том же
    /// экземпляре рисковал бы тем, что запоздавшая уборка от предыдущего
    /// потока прервёт только что поднятый.
    private func pump(into continuation: AsyncStream<NowPlayingSnapshot?>.Continuation) async {
        var policy = RestartPolicy()
        var accumulator = SnapshotAccumulator()

        while !Task.isCancelled {
            let adapter = AdapterProcess(paths: paths)
            process = adapter
            let openedAt = Date()

            for await line in await adapter.lines() {
                continuation.yield(accumulator.apply(line, now: Date()))
            }

            guard !Task.isCancelled else { break }

            // Живучесть меряется временем жизни потока, а не фактом «пришла
            // ли хоть одна строка»: спайк установил, что первая строка после
            // подключения — всегда служебная {"diff":false,"payload":{}},
            // даже если адаптер падает сразу вслед за ней. Судить по факту
            // любой строки означало бы сбрасывать паузу на каждой попытке
            // для адаптера, который умер навсегда, — ровно тот случай, ради
            // которого нарастающий backoff и существует; он бы держался на
            // нижней ступени бесконечно вместо того, чтобы вырасти до потолка.
            if Self.survivedLongEnoughToResetBackoff(openedAt: openedAt, closedAt: Date()) {
                policy.reset()
            }
            let delay = policy.nextDelay()
            logger.notice("поток адаптера оборван, повтор через \(delay, privacy: .public) с")
            try? await Task.sleep(for: .seconds(delay))
        }

        await process?.stop()
        continuation.finish()
    }
}
