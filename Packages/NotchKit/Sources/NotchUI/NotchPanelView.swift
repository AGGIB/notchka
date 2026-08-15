import SwiftUI
import NotchCore

/// Panel shell: the black shape, the morph between states, a tab-switching
/// column on the left, and a slot for content on the right.
///
/// Content arrives as a closure rather than being baked in: the shell
/// doesn't know what each tab actually draws. The tab column, by contrast,
/// the shell draws itself — switching (its one responsibility, unrelated to
/// any specific content) shouldn't depend on which tabs are already wired
/// to data and which aren't yet.
public struct NotchPanelView<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let state: NotchState
    private let notchSize: CGSize
    private let accent: Color
    private let onSelectTab: (NotchTab) -> Void
    private let content: (NotchTab) -> Content

    /// Gap between the tab column and the content.
    ///
    /// Computed, not stored: NotchPanelView is a generic type
    /// (over Content), and Swift doesn't support stored static properties
    /// in generic types (each specialization would get its own copy of storage).
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
        // Glow only for the expanded panel: at rest and in peek it's close
        // in size to the notch, and a halo around black-on-black would give
        // away the panel edge where it shouldn't be visible.
        .shadow(color: glowColor, radius: glowRadius, y: 6)
        .overlay(alignment: .top) { tabBody(in: size) }
        .animation(NotchMotion.animation(for: state, reduceMotion: reduceMotion), value: state)
        .animation(NotchMotion.accentFade, value: accent)
    }

    /// Glow color. Transparent in every state except expanded.
    private var glowColor: Color {
        if case .expanded = state { accent.opacity(0.28) } else { .clear }
    }

    /// Glow radius. Zero outside the expanded state, so SwiftUI doesn't spend
    /// a blur pass where the color is transparent anyway.
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
            .frame(
                width: size.width - PanelMetrics.contentInsets(notchHeight: notchSize.height).width,
                height: size.height - PanelMetrics.contentInsets(notchHeight: notchSize.height).height
            )
            // Top padding equals the notch's actual height plus a gap, not
            // a constant: the notch on this machine is 32 pt, and the padding
            // was 24 — the notch covered the top of the artwork and track title.
            .padding(.top, notchSize.height + PanelMetrics.notchGap)
            // Shape morph and content reveal are different things. Under
            // Reduce Motion the shape changes instantly, and the transition
            // is handed entirely to opacity: this is the second half of the
            // spec requirement that usesMorph in plan 1 was written for.
            .transition(
                NotchMotion.usesMorph(reduceMotion: reduceMotion)
                    ? AnyTransition(.blurReplace).combined(with: .opacity)
                    : .opacity
            )
        }
    }
}
