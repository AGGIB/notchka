import Foundation

/// Источник сведений о текущем воспроизведении.
///
/// Протокол существует ради риска, названного в спеке главным: MediaRemote
/// закрыт приватным entitlement, и если perl-обход перестанет работать,
/// вторая реализация напишется на браузерном расширении, а UI не изменится.
public protocol NowPlayingProvider: Sendable {
    /// nil в потоке значит «сейчас ничего не играет».
    ///
    /// Сколько потребителей одновременно поток обслуживает честно и не
    /// теряя события — решает реализация; сверяйтесь с её документацией
    /// (`AdapterProvider` рассчитан ровно на одного).
    var snapshots: AsyncStream<NowPlayingSnapshot?> { get async }
    func send(_ command: MediaCommand) async throws

    /// Останавливает пайплайн и гарантированно дожидается завершения —
    /// вызывающая сторона (см. AppDelegate) полагается на то, что после
    /// возврата отсюда никакой сторонний процесс уже не работает. Нужен
    /// отдельно от простого «отменить и забыть»: при завершении приложения
    /// полагаться на deinit нельзя — AppKit заканчивает процесс через
    /// exit(), в обход раскрутки стека Swift и деинициализаторов.
    func shutdown() async
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
