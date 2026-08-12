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
            var sawAnything = false

            for await line in await adapter.lines() {
                sawAnything = true
                continuation.yield(accumulator.apply(line, now: Date()))
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
