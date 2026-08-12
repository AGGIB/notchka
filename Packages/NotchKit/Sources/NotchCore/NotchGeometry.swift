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
        // Нулевой inset значит «у этого экрана нет чёлки» (например, внешний
        // монитор) — для него геометрии не существует, а не вырожденный
        // прямоугольник нулевой высоты.
        guard metrics.safeAreaTopInset > 0 else { return nil }

        // Обе боковые области обязаны быть измерены и положительны: вырез по
        // конструкции экрана всегда отделён от каждого края полосой меню-бара,
        // нулевая ширина с любой стороны на экране с чёлкой не бывает настоящей.
        // Это тот же случай, что ловит ScreenMetricsReader на границе с AppKit
        // (nil-боковая область), но калькулятор не обязан доверять вызывающей
        // стороне — он публичный API и может получить такие метрики и напрямую.
        guard metrics.auxiliaryTopLeftWidth > 0, metrics.auxiliaryTopRightWidth > 0 else {
            return nil
        }

        let notchWidth = metrics.frame.width
            - metrics.auxiliaryTopLeftWidth
            - metrics.auxiliaryTopRightWidth
        // Рассинхрон боковых областей (шире самого экрана) даёт нулевую или
        // отрицательную ширину — это невозможная геометрия, которую нельзя
        // отдавать вызывающему как есть.
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
