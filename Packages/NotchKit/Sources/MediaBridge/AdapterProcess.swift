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
    ///
    /// `Process` и `Pipe` собираются здесь, ДО построения `AsyncStream`, а не
    /// внутри его замыкания. Замыкание, которое принимает `AsyncStream.init`,
    /// типизировано как `@Sendable` — компилятор проверяет его по объявленному
    /// типу, а не по факту, что конкретно эта реализация вызывает его
    /// синхронно тут же, — поэтому запись в изменяемое состояние актора
    /// (`streamProcess`) изнутри него не проходит проверку строгой
    /// конкурентности Swift 6. Присваивание вынесено отдельной строкой после
    /// того, как поток уже построен: это обычный изолированный к актору код,
    /// а не тело замыкания.
    public func lines() -> AsyncStream<AdapterLine> {
        let process = Process()
        process.executableURL = paths.perl
        process.arguments = [paths.script.path, paths.framework.path, "stream"]

        let pipe = Pipe()
        process.standardOutput = pipe
        // stderr адаптера нам не нужен, но и в консоль его лить незачем.
        process.standardError = FileHandle.nullDevice

        let stream = AsyncStream<AdapterLine> { continuation in
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
            } catch {
                self.logger.error("не удалось запустить адаптер: \(error.localizedDescription, privacy: .public)")
                continuation.finish()
                return
            }

            continuation.onTermination = { _ in
                Task { await self.stop() }
            }
        }

        // Если process.run() выше не удался, процесс так и останется
        // незапущенным здесь — stop() ничего не сломает: process.isRunning
        // для него false, и guard там просто выйдет без действия.
        streamProcess = process
        return stream
    }

    /// Разовая команда управления. Отдельный короткоживущий процесс —
    /// у `stream` нет входного канала для команд.
    ///
    /// Ждём завершения через `terminationHandler`, а не `process.waitUntilExit()`:
    /// последний блокирует поток целиком, а это поток исполнителя актора —
    /// пока `send` не завершится, актор не сможет обслужить ничего другого,
    /// включая `stop()`. Если в этот момент супервизор из Task 5 гасит поток
    /// (выход из приложения, перезапуск), `stop()` встанет в очередь актора
    /// за уже идущим `send` и потеряет тот самый суб-секундный бюджет на
    /// SIGINT, ради которого адаптер вообще его перехватывает. `await` на
    /// continuation — точка приостановки, а не блокировки: актор в это время
    /// свободен обслуживать другие вызовы.
    public func send(code: Int32) async throws {
        let process = Process()
        process.executableURL = paths.perl
        process.arguments = [paths.script.path, paths.framework.path, "send", String(code)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // Резолвится ровно один раз: либо отсюда после завершения
            // процесса, либо из catch ниже, если он не смог даже
            // запуститься — тогда terminationHandler системой не вызывается,
            // двойного resume не будет.
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Останавливает поток. SIGINT, а не SIGKILL: спайк подтвердил, что
    /// адаптер перехватывает его и выходит чисто меньше чем за секунду.
    public func stop() {
        guard let process = streamProcess, process.isRunning else { return }
        process.interrupt()
        streamProcess = nil
    }

    /// Разовая пересинхронизация: `get` печатает текущее состояние ровно
    /// один раз и завершается сам — в отличие от `stream`, отдельного
    /// входного канала для команд ему тоже не нужно. Существует ради
    /// случая, который по потоку не увидеть в принципе: система иногда не
    /// присылает событие о возврате к прежнему источнику после короткой
    /// интерцепции (уведомление со звуком поверх настоящей музыки) — поток
    /// жив, но навсегда застревает на данных интерцепции, потому что
    /// событию просто неоткуда взяться. `get` в этот момент, в отличие от
    /// потока, отдаёт то, что система знает прямо сейчас (подтверждено
    /// вручную на живой машине во время диагностики этого дефекта).
    ///
    /// В отличие от `send(code:)`, нужен не код возврата, а содержимое
    /// stdout: `get` печатает туда голый JSON-объект — `NowPlayingPayload`
    /// без конверта `{"type":..,"diff":..,"payload":..}`, которым обёрнуты
    /// строки `stream` (см. `AdapterLine.parseSnapshot`, отдельный от
    /// `AdapterLine.parse` путь разбора именно по этой причине).
    ///
    /// stdout вычитывается `readabilityHandler`'ом по мере поступления, а
    /// не разом через `readDataToEndOfFile()` после того, как процесс уже
    /// завершился: `get` может вернуть артворк — на живой машине во время
    /// проверки этого метода пришло 256062 байта уже раскодированных данных,
    /// то есть больше 300 КиБ base64 в самом JSON, — это легко переполняет
    /// буфер трубы по умолчанию (64 КиБ). Не вычитывая трубу по мере
    /// поступления, можно получить дедлок: дочерний процесс блокируется на
    /// записи в заполненную трубу, а разбудить его некому — она не
    /// читается, пока сам процесс не завершится, а он не завершится, пока
    /// не допишет то, что как раз и не читается.
    ///
    /// Завершением чтения здесь служит EOF трубы (пустой `availableData`),
    /// а не `terminationHandler`, как у `send(code:)` выше: `send` не
    /// смотрит на stdout вовсе, и порядок между двумя независимыми
    /// колбэками GCD (закрытие процесса и опустошение трубы) нигде не
    /// задокументирован, тогда как EOF трубы гарантированно приходит только
    /// после того, как все написанные в неё байты уже вычитаны.
    public func get() async throws -> NowPlayingSnapshot? {
        let process = Process()
        process.executableURL = paths.perl
        process.arguments = [paths.script.path, paths.framework.path, "get"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        let buffer = OutputBuffer()
        let output: Data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else {
                    // Пустой availableData — это EOF: труба закрыта, писать
                    // в неё больше некому. Резолвим ровно здесь, а не ждём
                    // отдельного сигнала о завершении процесса (см. doc
                    // метода выше).
                    pipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(returning: buffer.snapshot())
                    return
                }
                buffer.append(chunk)
            }
            do {
                try process.run()
            } catch {
                // Тот же приём, что и в send(code:): run() не удался — сама
                // труба ещё пуста, readabilityHandler ни разу не сработал,
                // двойного resume не будет.
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }

        guard let text = String(data: output, encoding: .utf8) else { return nil }
        return AdapterLine.parseSnapshot(text)
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

/// Накопитель байтов для разового `get`.
///
/// Не переиспользует `LineBuffer` выше: тому нужен `\n`, чтобы отдать
/// строку, а `get` печатает один JSON-объект и не обязан завершать его
/// переводом строки — если бы его не было, LineBuffer промолчал бы навсегда,
/// так и не отдав ни одной «строки». Здесь копится всё до EOF целиком, без
/// понятия о строках вовсе; то же обоснование `@unchecked Sendable` и
/// блокировки, что и у LineBuffer — доступ идёт из readabilityHandler,
/// вызываемого с произвольного потока GCD, а не с потока исполнителя актора.
private final class OutputBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
