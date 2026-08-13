import SwiftUI
import NotchCore

/// Оболочка панели: чёрная фигура, морф между состояниями, колонка
/// переключения вкладок слева и место под содержимое справа.
///
/// Содержимое приходит замыканием, а не зашито внутрь: что именно рисует
/// каждая вкладка, оболочка не знает. Колонку вкладок оболочка, наоборот,
/// рисует сама — переключение (её единственная обязанность, не связанная с
/// конкретным содержимым) не должно зависеть от того, какие вкладки уже
/// подключены к данным, а какие ещё нет.
public struct NotchPanelView<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let state: NotchState
    private let notchSize: CGSize
    private let accent: Color
    private let onSelectTab: (NotchTab) -> Void
    private let content: (NotchTab) -> Content

    /// Промежуток между колонкой вкладок и содержимым.
    ///
    /// Вычисляемое, а не хранимое свойство: NotchPanelView — generic-тип
    /// (по Content), а хранимые static-свойства в generic-типах Swift не
    /// поддерживает (у каждой специализации была бы своя копия хранилища).
    private static var contentGap: CGFloat { 16 }

    public init(
        state: NotchState,
        notchSize: CGSize,
        accent: Color,
        onSelectTab: @escaping (NotchTab) -> Void,
        @ViewBuilder content: @escaping (NotchTab) -> Content
    ) {
        self.state = state
        self.notchSize = notchSize
        self.accent = accent
        self.onSelectTab = onSelectTab
        self.content = content
    }

    public var body: some View {
        let size = PanelMetrics.size(for: state, notch: notchSize)

        NotchShape(
            width: size.width,
            height: size.height,
            bottomRadius: PanelMetrics.bottomRadius(for: state),
            concaveRadius: PanelMetrics.concaveRadius
        )
        .fill(.black)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Свечение только у раскрытой панели: в покое и в peek она по размеру
        // близка к вырезу, и ореол вокруг чёрного на чёрном выдавал бы
        // границу панели там, где её быть не должно.
        .shadow(color: glowColor, radius: glowRadius, y: 6)
        .overlay(alignment: .top) { tabBody(in: size) }
        .animation(NotchMotion.animation(for: state, reduceMotion: reduceMotion), value: state)
        .animation(NotchMotion.accentFade, value: accent)
    }

    /// Цвет ореола. Прозрачный во всех состояниях, кроме раскрытого.
    private var glowColor: Color {
        if case .expanded = state { accent.opacity(0.28) } else { .clear }
    }

    /// Радиус ореола. Ноль вне раскрытого состояния, чтобы SwiftUI не тратил
    /// проход размытия там, где цвет всё равно прозрачный.
    private var glowRadius: CGFloat {
        if case .expanded = state { 12 } else { 0 }
    }

    @ViewBuilder
    private func tabBody(in size: CGSize) -> some View {
        if case .expanded(let tab) = state {
            HStack(spacing: Self.contentGap) {
                TabRailView(selected: tab, accent: accent, onSelect: onSelectTab)
                content(tab)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(width: size.width - 26, height: size.height - 38)
            .padding(.top, 24)
            // Морф формы и проявление содержимого — разные вещи. При
            // Reduce Motion форма меняется мгновенно, и переход целиком
            // отдаётся прозрачности: это вторая половина требования
            // спеки, ради которой в плане 1 написана usesMorph.
            .transition(
                NotchMotion.usesMorph(reduceMotion: reduceMotion)
                    ? AnyTransition(.blurReplace).combined(with: .opacity)
                    : .opacity
            )
        }
    }
}
