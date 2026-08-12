import SwiftUI
import NotchCore

/// Все параметры движения собраны в одном месте, чтобы физика панели
/// не расползлась по вьюхам и её можно было проверить тестами.
public enum NotchMotion {
    public static let opening = Animation.spring(response: 0.34, dampingFraction: 0.68)
    public static let closing = Animation.snappy(duration: 0.26)
    /// При Reduce Motion пружина неуместна: пользователь просил её не показывать.
    public static let reduced = Animation.easeInOut(duration: 0.18)

    public static func animation(for state: NotchState, reduceMotion: Bool) -> Animation {
        guard !reduceMotion else { return reduced }
        return state == .closed ? closing : opening
    }

    /// Нужно ли морфить форму. При Reduce Motion форма меняется мгновенно,
    /// а переход отдаётся прозрачности.
    public static func usesMorph(reduceMotion: Bool) -> Bool { !reduceMotion }
}
