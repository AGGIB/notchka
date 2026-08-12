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
