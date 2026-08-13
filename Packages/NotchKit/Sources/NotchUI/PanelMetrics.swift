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
    public static let expandedSize = CGSize(width: 620, height: 264)

    /// Поля по бокам, суммарно.
    public static let horizontalInset: CGFloat = 26
    /// Просвет между нижним краем физического выреза и содержимым.
    public static let notchGap: CGFloat = 6
    /// Поле снизу.
    public static let bottomInset: CGFloat = 14

    /// Высота выреза для тестов и прикидок. В рантайме берётся настоящая,
    /// измеренная по `safeAreaInsets.top` экрана: у нынешних MacBook это
    /// 32 pt, но зашивать это числом нельзя — панель обязана считаться от
    /// того выреза, который на самом деле есть.
    public static let referenceNotchHeight: CGFloat = 32

    /// Сколько панель отъедает у содержимого при вырезе высотой `notchHeight`.
    ///
    /// Верхний отступ выводится из настоящей высоты выреза, а не из
    /// константы: раньше он был зашит числом 24 при вырезе в 32 pt, и чёлка
    /// накрывала верх обложки и название трека. Считать содержимое от
    /// физического выреза — единственный способ не наступить на это снова.
    public static func contentInsets(notchHeight: CGFloat) -> CGSize {
        CGSize(width: horizontalInset, height: notchHeight + notchGap + bottomInset)
    }

    /// Место, остающееся содержимому вкладки в раскрытой панели.
    public static func contentSize(notchHeight: CGFloat) -> CGSize {
        let insets = contentInsets(notchHeight: notchHeight)
        return CGSize(
            width: expandedSize.width - insets.width,
            height: expandedSize.height - insets.height
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
