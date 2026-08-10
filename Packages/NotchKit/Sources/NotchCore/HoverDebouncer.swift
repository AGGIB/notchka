import Foundation

/// Сырое положение курсора превращает в события входа и выхода с пороговой фильтрацией.
/// Время приходит параметром (не читается из часов) — поэтому тесты не дожидаются ни миллисекунды.
public struct HoverDebouncer: Sendable {
    /// Минимальное время пребывания курсора в зоне для открытия панели.
    public static let enterDwell: TimeInterval = 0.120
    /// Минимальное время пребывания курсора вне зоны для закрытия панели.
    public static let exitGrace: TimeInterval = 0.250

    /// Текущее положение курсора.
    private var isInside = false
    /// Положение, о котором уже сообщили наружу.
    /// Инвариант: выход испускается только если было сообщено о входе.
    private var reported = false
    /// Момент последней смены положения.
    private var changedAt: Date?

    public init() {}

    /// Ожидается ли переход, который должен сработать по истечении порога.
    /// Пока ложь, таймер можно не запускать — приложение находится в простое.
    public var hasPendingTransition: Bool { isInside != reported }

    @discardableResult
    public mutating func cursorMoved(isInsideHotZone: Bool, at now: Date) -> NotchEvent? {
        if isInsideHotZone != isInside {
            isInside = isInsideHotZone
            changedAt = now
        }
        return evaluate(at: now)
    }

    /// Проверка пороговых условий по таймеру.
    /// Нужна, чтобы пороги срабатывали и при замерзшем курсоре.
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
