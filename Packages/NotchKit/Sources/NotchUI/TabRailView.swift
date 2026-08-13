import SwiftUI
import NotchCore

/// Иконка и подпись вкладки для колонки переключения и для заглушки.
///
/// Живёт в NotchUI, а не в NotchCore: какой символ представляет вкладку —
/// вопрос представления, а не доменной логики, а NotchCore сознательно не
/// импортирует ничего, что рисует UI. Подписи на русском — так же, как и
/// остальной пользовательский текст панели (см. «Ничего не играет» в
/// MusicTabView).
extension NotchTab {
    /// SF Symbol колонки переключения. `TabRailView` перечисляет
    /// `NotchTab.allCases`, поэтому у нового case вкладки нет способа
    /// остаться без иконки незамеченным — компилятор потребует ветку в этом
    /// switch (см. также TabRailViewTests.everyTabHasIconAndLabel).
    var symbolName: String {
        switch self {
        case .music: "music.note"
        case .clipboard: "doc.on.clipboard"
        case .notes: "note.text"
        case .pins: "pin.fill"
        }
    }

    /// Человекочитаемое имя — для accessibilityLabel, подсказки при
    /// наведении и подписи заглушки вкладки.
    var title: String {
        switch self {
        case .music: "Музыка"
        case .clipboard: "Буфер обмена"
        case .notes: "Заметки"
        case .pins: "Пины"
        }
    }
}

/// Колонка переключения вкладок слева от содержимого панели.
///
/// Постоянная ширина и полная высота области содержимого — задача просила
/// именно такую раскладку взамен единственного клавиатурного пути (`⌘1`…`⌘4`,
/// `⇥`), которым раньше и ограничивалось переключение: три из четырёх вкладок
/// нечем было обнаружить на экране.
public struct TabRailView: View {
    private let selected: NotchTab
    private let accent: Color
    private let onSelect: (NotchTab) -> Void

    /// Общий для всех пунктов namespace: matchedGeometryEffect интерполирует
    /// подложку активного пункта между её старым и новым положением только
    /// когда оба используют один и тот же namespace и id (см. TabRailItemStyle).
    @Namespace private var activeTabNamespace

    private static let width: CGFloat = 64
    private static let itemSpacing: CGFloat = 16

    public init(selected: NotchTab, accent: Color, onSelect: @escaping (NotchTab) -> Void) {
        self.selected = selected
        self.accent = accent
        self.onSelect = onSelect
    }

    public var body: some View {
        VStack(spacing: Self.itemSpacing) {
            Spacer(minLength: 0)
            ForEach(NotchTab.allCases, id: \.self) { tab in
                TabRailItem(
                    tab: tab,
                    isSelected: tab == selected,
                    accent: accent,
                    namespace: activeTabNamespace,
                    onSelect: { onSelect(tab) }
                )
            }
            Spacer(minLength: 0)
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        // Тонкий шов между колонкой и содержимым — единственная линия на
        // панели, дающая глазу границу без второго цвета: та же белая
        // шкала прозрачности, что и остальной хром «Обсидиана».
        .overlay(alignment: .trailing) {
            Rectangle().fill(.white.opacity(0.08)).frame(width: 1)
        }
    }
}

/// Один пункт колонки: кнопка с иконкой, наведение и клик передаются наружу
/// через onSelect — сама панель ничего не знает про то, как событие дойдёт
/// до машины состояний (см. NotchPanelView.onSelectTab).
private struct TabRailItem: View {
    let tab: NotchTab
    let isSelected: Bool
    let accent: Color
    let namespace: Namespace.ID
    let onSelect: () -> Void

    @State private var isHovering = false

    private static let size: CGFloat = 36

    var body: some View {
        Button(action: onSelect) {
            Image(systemName: tab.symbolName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: Self.size, height: Self.size)
                .contentShape(Rectangle())
        }
        .buttonStyle(TabRailItemStyle(isSelected: isSelected, isHovering: isHovering, accent: accent, namespace: namespace))
        .onHover { isHovering = $0 }
        .help(tab.title)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Активная вкладка — белая на полной непрозрачности: акцентная подложка
    /// уже сообщает «это выбрано» (см. TabRailItemStyle.backdrop), а сама
    /// иконка обязана оставаться самым читаемым элементом что на чёрном
    /// фоне, что на мягкой акцентной плашке. Неактивные — белый низкой
    /// прозрачности по требованию задачи, наведение поднимает её заметно,
    /// но не до уровня активной.
    private var iconColor: Color {
        if isSelected { return .white }
        return .white.opacity(isHovering ? 0.7 : 0.4)
    }
}

/// Подложка активного пункта, наведение и нажатие — три разных состояния со
/// своим визуальным сигналом у каждого, чтобы «под курсором» не читалось как
/// «выбрано», а «выбрано» не терялось на «под курсором» соседней вкладки.
private struct TabRailItemStyle: ButtonStyle {
    let isSelected: Bool
    let isHovering: Bool
    let accent: Color
    let namespace: Namespace.ID

    private static let cornerRadius: CGFloat = 10

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(backdrop)
            // Нажатие отзывается мгновенно, без сглаживания: своей анимации
            // здесь нет намеренно. В NotchMotion нет константы подходящего
            // порядка — opening/closing привязаны к состояниям панели, а
            // accentFade в 0.6 с на порядок медленнее, чем нужно нажатию, —
            // а заводить собственную запрещено правилом проекта. Подложка
            // выбранной вкладки, в отличие от этого, анимируется: она
            // наследует пружину NotchMotion через .animation(value: state)
            // в NotchPanelView.body.
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
    }

    @ViewBuilder
    private var backdrop: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(accent.opacity(0.24))
                .matchedGeometryEffect(id: "activeTabBackdrop", in: namespace)
        } else if isHovering {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(.white.opacity(0.08))
        }
    }
}
