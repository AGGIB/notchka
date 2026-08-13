import SwiftUI

/// Правила бегущей строки: нужно ли прокручивать текст и сколько длится один
/// проход.
///
/// Отделены от отрисовки тем же приёмом, что и TrackFormatting,
/// ClipboardCard.preview, ClipboardTabContent.resolve — решение проверяется
/// тестом без окна, а не глазом на живой панели (см. MarqueeMetricsTests).
public enum MarqueeMetrics {
    /// Прокрутка нужна, только когда текст СТРОГО шире отведённого места.
    ///
    /// Текст, который влезает ровно впритык (`textWidth == availableWidth`),
    /// не прокручивается: весь целиком, он уже виден без движения, а
    /// сдвигать его — значит выдавать за анимацию то, что на самом деле
    /// ничего не решает и выглядит дёрганьем на ровном месте.
    public static func shouldScroll(textWidth: CGFloat, availableWidth: CGFloat) -> Bool {
        textWidth > availableWidth
    }

    /// Сколько времени текст указанной ширины едет мимо на данной скорости.
    ///
    /// Неположительные ширина или скорость дают ноль, а не деление на ноль
    /// или отрицательную длительность — оба вырожденных случая безопасны для
    /// вызывающей стороны (см. MarqueeText.offset(at:)), которая иначе
    /// получила бы NaN или бесконечный цикл нулевой длины.
    public static func passDuration(width: CGFloat, speed: CGFloat) -> TimeInterval {
        guard width > 0, speed > 0 else { return 0 }
        return TimeInterval(width / speed)
    }
}

/// Бегущая строка: показывает текст неподвижным, пока он влезает, и
/// прокручивает его слева направо ровным ходом, если нет.
///
/// Измеряет саму себя через `onGeometryChange` (macOS 15+) — единственный
/// доступный NotchUI способ узнать ширину текста и отведённого ему места:
/// пакет не импортирует AppKit, поэтому `NSAttributedString`/`NSFont` здесь
/// недоступны в принципе (Global Constraints плана).
public struct MarqueeText: View {
    private let text: String
    private let font: Font

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Естественная ширина текста без ограничений — измеряется невидимым
    /// зондом (см. `widthProbe`), а не самим видимым текстом: видимый текст
    /// в неподвижной ветке обязан обрезаться по месту, а не растягивать
    /// раскладку до своей полной длины.
    @State private var textWidth: CGFloat = 0
    /// Ширина, которую реально выделил родитель. Меряется на внешнем
    /// контейнере уже после `.frame(maxWidth: .infinity)` — то есть это не
    /// ширина текста, а именно то место, в которое ему нужно поместиться.
    @State private var availableWidth: CGFloat = 0
    /// Момент начала текущего цикла прокрутки — точка отсчёта, а не счётчик
    /// кадров: смещение в любой момент считается от неё заново (см.
    /// `offset(at:)`), а не накапливается кадр за кадром.
    @State private var startDate = Date()

    public init(_ text: String, font: Font) {
        self.text = text
        self.font = font
    }

    /// Reduce Motion выключает прокрутку целиком независимо от того, влезает
    /// текст или нет — требование 4 постановки, тот же флаг и то же место
    /// чтения (`@Environment`), что и в NotchPanelView.
    private var shouldScroll: Bool {
        !reduceMotion && MarqueeMetrics.shouldScroll(textWidth: textWidth, availableWidth: availableWidth)
    }

    public var body: some View {
        Group {
            if shouldScroll {
                scrolling
            } else {
                // Один и тот же неподвижный текст с усечением многоточием —
                // и для влезающего заголовка (требование 1), и для Reduce
                // Motion (требование 4): это одно и то же требуемое
                // состояние, а не два похожих, но разных.
                Text(text).font(font).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(widthProbe)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { availableWidth = $0 }
        .onChange(of: text) { _, _ in
            // Смена трека — это смена текста: сбрасываем точку отсчёта, и
            // новое название стартует с паузы у начала, а не с той фазы
            // прохода, на которой остановилось предыдущее (требование 5).
            startDate = Date()
        }
        // Прокрутка рисует текст двумя копиями подряд (см. scrolling) — без
        // явного accessibility-элемента VoiceOver прочитал бы его дважды.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    /// Невидимый зонд из того же текста и шрифта, что и видимый.
    /// `fixedSize()` заставляет его лечь на свою настоящую ширину вместо
    /// предложенной родителем, а `opacity(0)` прячет его, не убирая из
    /// раскладки — в отличие от условного `if`, спрятанная так вьюха
    /// продолжает измеряться.
    private var widthProbe: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .fixedSize()
            .opacity(0)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { textWidth = $0 }
    }

    /// Два экземпляра текста подряд через `NotchMotion.marqueeGap`: когда
    /// первый проезжает всю дистанцию прохода, второй как раз занимает его
    /// стартовое место, и в этот момент `offset(at:)` заново обнуляется —
    /// глазу это читается как непрерывное движение без шва, а не прыжок.
    private var scrolling: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: false)) { context in
            HStack(spacing: NotchMotion.marqueeGap) {
                Text(text).font(font).lineLimit(1).fixedSize()
                Text(text).font(font).lineLimit(1).fixedSize()
            }
            .offset(x: offset(at: context.date))
        }
        // Числовая ширина, а не maxWidth: `.frame(width:)` всегда сообщает
        // родителю ровно эту цифру, что бы ни лежало внутри. Без неё две
        // копии текста (fixedSize, вместе шире отведённого места по
        // построению) продавили бы наверх свою полную ширину, и колонка
        // плеера растянулась бы под них — ровно то, что запрещает
        // требование 7.
        .frame(width: availableWidth, alignment: .leading)
        // Рамка выше уже не растёт, но содержимое внутри неё по-прежнему
        // шире и без клипа рисовалось бы, вылезая за её границы — clipped()
        // обрезает именно рисование, а не размер, который зафиксирован строкой выше.
        .clipped()
        .mask(edgeFade)
    }

    /// Смещение в момент `date`: ноль на время паузы, затем равномерный
    /// сдвиг влево на всю дистанцию прохода за `passDuration`, затем цикл
    /// начинается заново.
    ///
    /// Чистая функция времени, а не хранимое состояние смещения — поэтому
    /// паузе и повтору неоткуда рассинхронизироваться между кадрами
    /// TimelineView, и здесь же, а не в отдельной пружине или `.animation`,
    /// потому что нужно строго линейное движение без ускорений (требование
    /// 2), а не кривая NotchMotion — они для переходов между состояниями
    /// панели, а не для равномерного хода бегущей строки.
    private func offset(at date: Date) -> CGFloat {
        let distance = textWidth + NotchMotion.marqueeGap
        let duration = MarqueeMetrics.passDuration(width: distance, speed: NotchMotion.marqueeSpeed)
        guard duration > 0 else { return 0 }
        let cycle = NotchMotion.marqueePause + duration
        let phase = date.timeIntervalSince(startDate).truncatingRemainder(dividingBy: cycle)
        guard phase > NotchMotion.marqueePause else { return 0 }
        let progress = (phase - NotchMotion.marqueePause) / duration
        return -CGFloat(progress) * distance
    }

    /// Растворение по краям — маска, а не подложенная плашка: `.mask` режет
    /// альфу самого текста, поэтому под краями честно проступает то, что на
    /// самом деле позади (чёрный фон панели «Обсидиана»), а не имитация
    /// цветом поверх текста (требование 3 и правило «Обсидиана» про плашки).
    /// Ширина растворения переводится в долю от `availableWidth`, потому что
    /// `LinearGradient` со `.leading`/`.trailing` задаётся в единичных
    /// координатах (0...1), а не в точках.
    private var edgeFade: some View {
        let fraction = availableWidth > 0 ? min(NotchMotion.marqueeEdgeFade / availableWidth, 0.5) : 0
        return LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: fraction),
                .init(color: .black, location: 1 - fraction),
                .init(color: .clear, location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}
