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
