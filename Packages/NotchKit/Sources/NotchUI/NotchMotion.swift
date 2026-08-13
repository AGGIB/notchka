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

    /// Смена акцентного цвета (обложка трека) — плавная перекраска тени,
    /// не связанная с раскрытием панели, поэтому не участвует в переключении
    /// opening/closing/reduced и не подчиняется Reduce Motion: это тихая
    /// смена оттенка, а не движение, которое спека просит приглушать.
    public static let accentFade = Animation.easeInOut(duration: 0.6)

    // MARK: - Бегущая строка (MarqueeText)
    //
    // Не `Animation`, а голые числа: прокрутка — не переход между
    // состояниями панели (для такого здесь спринги и снэппи выше), а
    // равномерное движение, которое MarqueeText считает само как чистую
    // функцию времени. Числа собраны здесь по тому же принципу, что и
    // остальной файл — единое место для параметров движения проекта,
    // не в вьюхе.

    /// Скорость прокрутки, точек в секунду. Подобрана так, чтобы название
    /// успевало читаться на ходу, а не мелькало: заголовок обычной длины
    /// проезжает мимо за несколько секунд, а не пролетает почти мгновенно.
    public static let marqueeSpeed: CGFloat = 30

    /// Пауза у начала строки перед стартом прокрутки. Даёт время прочитать
    /// видимую часть текста до того, как она уедет влево, и повторяется в
    /// начале каждого следующего прохода — не только один раз при появлении.
    public static let marqueePause: TimeInterval = 1.2

    /// Промежуток между концом одного прохода и началом следующего. В
    /// MarqueeText это расстояние между двумя копиями текста, которое не
    /// даёт им читаться слитно, когда вторая копия въезжает на место первой.
    public static let marqueeGap: CGFloat = 24

    /// Ширина растворения по каждому краю бегущей строки, в точках.
    public static let marqueeEdgeFade: CGFloat = 16
}
