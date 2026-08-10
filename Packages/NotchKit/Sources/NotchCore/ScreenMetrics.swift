import CoreGraphics

/// Снимок измерений экрана, достаточный для вычисления чёлки.
/// Отделён от NSScreen намеренно: геометрия должна считаться на выдуманных
/// конфигурациях, которых нет под рукой.
public struct ScreenMetrics: Sendable, Equatable {
    public let frame: CGRect
    /// Высота выреза. На экранах без чёлки равна нулю.
    public let safeAreaTopInset: CGFloat
    /// Ширина полосы меню-бара слева от выреза.
    public let auxiliaryTopLeftWidth: CGFloat
    /// Ширина полосы меню-бара справа от выреза.
    public let auxiliaryTopRightWidth: CGFloat

    public init(
        frame: CGRect,
        safeAreaTopInset: CGFloat,
        auxiliaryTopLeftWidth: CGFloat,
        auxiliaryTopRightWidth: CGFloat
    ) {
        self.frame = frame
        self.safeAreaTopInset = safeAreaTopInset
        self.auxiliaryTopLeftWidth = auxiliaryTopLeftWidth
        self.auxiliaryTopRightWidth = auxiliaryTopRightWidth
    }
}
