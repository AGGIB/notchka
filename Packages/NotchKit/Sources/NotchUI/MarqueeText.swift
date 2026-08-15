import SwiftUI

/// Marquee rules: whether the text needs to scroll and how long one pass
/// takes.
///
/// Separated from rendering by the same approach as TrackFormatting,
/// ClipboardCard.preview, ClipboardTabContent.resolve — the decision is
/// verified by a windowless test, not by eye on a live panel (see
/// MarqueeMetricsTests).
public enum MarqueeMetrics {
    /// Scrolling is needed only when the text is STRICTLY wider than the
    /// available space.
    ///
    /// Text that fits exactly (`textWidth == availableWidth`) does not
    /// scroll: it's already fully visible without movement, and shifting it
    /// would pass off as animation something that actually solves nothing
    /// and just looks like jitter for no reason.
    public static func shouldScroll(textWidth: CGFloat, availableWidth: CGFloat) -> Bool {
        textWidth > availableWidth
    }

    /// How long it takes text of the given width to travel past at the
    /// given speed.
    ///
    /// A non-positive width or speed yields zero, not division by zero or a
    /// negative duration — both degenerate cases are safe for the caller
    /// (see MarqueeText.offset(at:)), which would otherwise get NaN or an
    /// infinite zero-length cycle.
    public static func passDuration(width: CGFloat, speed: CGFloat) -> TimeInterval {
        guard width > 0, speed > 0 else { return 0 }
        return TimeInterval(width / speed)
    }
}

/// Marquee text: shows the text still while it fits, and scrolls it
/// left-to-right at a steady pace when it doesn't.
///
/// Measures itself via `onGeometryChange` (macOS 15+) — the only NotchUI
/// way available to learn the text's width and the space allotted to it:
/// the package doesn't import AppKit, so `NSAttributedString`/`NSFont` are
/// simply unavailable here (Global Constraints of the plan).
public struct MarqueeText: View {
    private let text: String
    private let font: Font

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Natural unconstrained width of the text — measured by an invisible
    /// probe (see `widthProbe`), not by the visible text itself: in the
    /// still branch the visible text must truncate to fit, not stretch the
    /// layout to its full length.
    @State private var textWidth: CGFloat = 0
    /// The width the parent actually allotted. Measured on the outer
    /// container, after `.frame(maxWidth: .infinity)` — i.e. this isn't the
    /// text's width, but exactly the space it needs to fit into.
    @State private var availableWidth: CGFloat = 0
    /// The start of the current scroll cycle — a reference point, not a
    /// frame counter: the offset at any moment is computed from it anew
    /// (see `offset(at:)`), not accumulated frame by frame.
    @State private var startDate = Date()

    public init(_ text: String, font: Font) {
        self.text = text
        self.font = font
    }

    /// Reduce Motion turns off scrolling entirely regardless of whether the
    /// text fits or not — requirement 4 of the spec, the same flag read the
    /// same way (`@Environment`) as in NotchPanelView.
    private var shouldScroll: Bool {
        !reduceMotion && MarqueeMetrics.shouldScroll(textWidth: textWidth, availableWidth: availableWidth)
    }

    public var body: some View {
        Group {
            if shouldScroll {
                scrolling
            } else {
                // The same still text with ellipsis truncation — for a
                // title that fits (requirement 1) and for Reduce Motion
                // (requirement 4) alike: it's one and the same required
                // state, not two similar-but-different ones.
                Text(text).font(font).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(widthProbe)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { availableWidth = $0 }
        .onChange(of: text) { _, _ in
            // A track change is a text change: reset the reference point,
            // so the new title starts with a pause at the beginning, not
            // from whatever pass phase the previous one stopped at
            // (requirement 5).
            startDate = Date()
        }
        // Scrolling draws the text as two copies in a row (see scrolling) —
        // without an explicit accessibility element, VoiceOver would read
        // it twice.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    /// An invisible probe made of the same text and font as the visible
    /// one. `fixedSize()` forces it to lay out at its true width instead of
    /// the one proposed by the parent, and `opacity(0)` hides it without
    /// removing it from the layout — unlike a conditional `if`, a view
    /// hidden this way keeps being measured.
    private var widthProbe: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .fixedSize()
            .opacity(0)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { textWidth = $0 }
    }

    /// Two instances of the text in a row, separated by
    /// `NotchMotion.marqueeGap`: when the first one travels the whole pass
    /// distance, the second one is right there taking its starting place,
    /// and at that moment `offset(at:)` resets back to zero — to the eye
    /// this reads as continuous seamless movement, not a jump.
    private var scrolling: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: false)) { context in
            HStack(spacing: NotchMotion.marqueeGap) {
                Text(text).font(font).lineLimit(1).fixedSize()
                Text(text).font(font).lineLimit(1).fixedSize()
            }
            .offset(x: offset(at: context.date))
        }
        // A fixed numeric width, not maxWidth: `.frame(width:)` always
        // reports exactly this number to the parent, no matter what's
        // inside. Without it, the two copies of the text (fixedSize,
        // together wider than the available space by construction) would
        // push their full width upward, and the player column would
        // stretch to fit them — exactly what requirement 7 forbids.
        .frame(width: availableWidth, alignment: .leading)
        // The frame above no longer grows, but the content inside it is
        // still wider and would otherwise draw past its bounds without
        // clipping — clipped() trims the drawing itself, not the size,
        // which is already fixed by the line above.
        .clipped()
        .mask(edgeFade)
    }

    /// The offset at moment `date`: zero during the pause, then a uniform
    /// leftward shift over the whole pass distance across `passDuration`,
    /// then the cycle starts over.
    ///
    /// A pure function of time, not stored offset state — so the pause and
    /// the repeat have nowhere to drift out of sync between TimelineView
    /// frames, and it's computed right here rather than via a separate
    /// spring or `.animation`, because strictly linear motion without
    /// easing is required (requirement 2), not a NotchMotion curve — those
    /// are for transitions between panel states, not for the marquee's
    /// steady pace.
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

    /// Edge fade — a mask, not an overlaid plate: `.mask` cuts the alpha of
    /// the text itself, so what's honestly behind it (the "Obsidian"
    /// panel's black background) shows through at the edges, rather than
    /// faking it with color over the text (requirement 3 and the
    /// "Obsidian" rule about plates). The fade width is converted to a
    /// fraction of `availableWidth`, because `LinearGradient` with
    /// `.leading`/`.trailing` is specified in unit coordinates (0...1), not
    /// points.
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
