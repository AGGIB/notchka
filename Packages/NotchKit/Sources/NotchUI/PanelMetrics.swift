import CoreGraphics
import NotchCore

/// Размеры панели по состояниям.
///
/// Собраны в одном месте, потому что от них зависят три вещи сразу: рисование
/// фигуры, размер окна и проверка попадания курсора в раскрытую панель.
/// Разъехавшись, они дали бы панель, закрывающуюся под курсором.
public enum PanelMetrics {
    /// Окно постоянного размера, в котором живёт всё остальное.
    public static let windowSize = CGSize(width: 680, height: 300)
    public static let concaveRadius: CGFloat = 8

    public static let peekPadding = CGSize(width: 120, height: 28)
    public static let expandedSize = CGSize(width: 620, height: 240)

    public static func size(for state: NotchState, notch: CGSize) -> CGSize {
        switch state {
        case .closed:
            notch
        case .peek:
            CGSize(
                width: notch.width + peekPadding.width,
                height: notch.height + peekPadding.height
            )
        case .expanded:
            expandedSize
        }
    }

    public static func bottomRadius(for state: NotchState) -> CGFloat {
        switch state {
        case .closed: 10
        case .peek: 16
        case .expanded: 22
        }
    }
}
