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

    /// Сколько панель отъедает у содержимого: по ширине — поля с обеих
    /// сторон, по высоте — вырез чёлки сверху и поле снизу.
    ///
    /// Живёт здесь, а не литералами в месте применения, чтобы содержимое
    /// вкладок могло сверяться с реально доступным местом. Без такой сверки
    /// разъезд не обнаруживается ничем: SwiftUI на переполнении не даёт ни
    /// ошибки, ни предупреждения — он молча обрезает или накладывает.
    public static let contentInsets = CGSize(width: 26, height: 38)

    /// Место, остающееся содержимому вкладки в раскрытой панели.
    public static var contentSize: CGSize {
        CGSize(
            width: expandedSize.width - contentInsets.width,
            height: expandedSize.height - contentInsets.height
        )
    }

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
