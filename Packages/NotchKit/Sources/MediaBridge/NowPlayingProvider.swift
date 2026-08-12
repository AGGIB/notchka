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
