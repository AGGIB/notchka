import CoreGraphics

/// Снимок измерений экрана, достаточный для вычисления чёлки.
/// Отделён от NSScreen намеренно: геометрия должна считаться на выдуманных
/// конфигурациях, которых нет под рукой.
public struct ScreenMetrics: Sendable, Equatable {
    public let frame: CGRect
    /// Высота выреза — нулевое значение означает экран без чёлки.
    /// В macOS это получается из NSScreen.safeAreaInsets.top (крайний слева).
    public let safeAreaTopInset: CGFloat
    /// Ширина полосы меню-бара слева от выреза.
    /// macOS не предоставляет прямого API ширины выреза, поэтому мы вычисляем
    /// ширину вычитанием боковых областей из ширины экрана.
    public let auxiliaryTopLeftWidth: CGFloat
    /// Ширина полосы меню-бара справа от выреза.
    /// Вместе с auxiliaryTopLeftWidth позволяет вычислить положение и ширину выреза:
    /// notchX = auxiliaryTopLeftWidth, notchWidth = frame.width - left - right.
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
