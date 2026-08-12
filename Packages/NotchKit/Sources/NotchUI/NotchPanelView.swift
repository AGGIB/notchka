import SwiftUI
import NotchCore

/// Оболочка панели: чёрная фигура, морф между состояниями и место под содержимое.
///
/// Содержимое приходит замыканием, а не зашито внутрь: вкладки добавляются
/// следующими планами, и оболочка не должна знать, что в них.
public struct NotchPanelView<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let state: NotchState
    private let notchSize: CGSize
    private let accent: Color
    private let content: (NotchTab) -> Content

    public init(
        state: NotchState,
        notchSize: CGSize,
        accent: Color,
        @ViewBuilder content: @escaping (NotchTab) -> Content
    ) {
        self.state = state
        self.notchSize = notchSize
        self.accent = accent
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
            content(tab)
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
