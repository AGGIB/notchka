import CoreGraphics

/// Положение выреза и зоны его срабатывания.
/// Координаты экранные, начало отсчёта — верхний левый угол дисплея.
public struct NotchGeometry: Sendable, Equatable {
    public let notchRect: CGRect
    public let hotZone: CGRect

    public init(notchRect: CGRect, hotZone: CGRect) {
        self.notchRect = notchRect
        self.hotZone = hotZone
    }
}

public enum NotchGeometryCalculator {
    /// Запас по горизонтали: курсор не обязан попадать в вырез пиксель в пиксель.
    public static let hotZoneInsetX: CGFloat = 6
    /// Запас снизу: чёлка реагирует чуть раньше, чем курсор дойдёт до её края.
    public static let hotZoneInsetBottom: CGFloat = 4

    public static func geometry(for metrics: ScreenMetrics) -> NotchGeometry? {
        guard metrics.safeAreaTopInset > 0 else { return nil }

        let notchWidth = metrics.frame.width
            - metrics.auxiliaryTopLeftWidth
            - metrics.auxiliaryTopRightWidth
        guard notchWidth > 0 else { return nil }

        let notchRect = CGRect(
            x: metrics.auxiliaryTopLeftWidth,
            y: 0,
            width: notchWidth,
            height: metrics.safeAreaTopInset
        )
        let hotZone = CGRect(
            x: notchRect.minX - hotZoneInsetX,
            y: 0,
            width: notchRect.width + hotZoneInsetX * 2,
            height: notchRect.height + hotZoneInsetBottom
        )
        return NotchGeometry(notchRect: notchRect, hotZone: hotZone)
    }
}
