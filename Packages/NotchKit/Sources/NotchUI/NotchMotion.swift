import SwiftUI
import NotchCore

/// All motion parameters are gathered in one place so the panel's physics
/// don't get scattered across views and can be verified with tests.
public enum NotchMotion {
    public static let opening = Animation.spring(response: 0.34, dampingFraction: 0.68)
    public static let closing = Animation.snappy(duration: 0.26)
    /// A spring is out of place under Reduce Motion: the user asked not to see it.
    public static let reduced = Animation.easeInOut(duration: 0.18)

    public static func animation(for state: NotchState, reduceMotion: Bool) -> Animation {
        guard !reduceMotion else { return reduced }
        return state == .closed ? closing : opening
    }

    /// Whether the shape should morph. Under Reduce Motion the shape changes
    /// instantly, and the transition is handed off to opacity instead.
    public static func usesMorph(reduceMotion: Bool) -> Bool { !reduceMotion }

    /// Accent color change (track artwork) — a smooth shadow recolor that's
    /// unrelated to the panel opening, so it doesn't participate in the
    /// opening/closing/reduced switching and isn't subject to Reduce Motion:
    /// it's a quiet tint change, not the kind of motion the spec asks to tone down.
    public static let accentFade = Animation.easeInOut(duration: 0.6)

    // MARK: - Marquee text (MarqueeText)
    //
    // Not an `Animation`, but plain numbers: scrolling isn't a transition
    // between panel states (that's what the springs and snappy above are
    // for), but uniform motion that MarqueeText computes itself as a pure
    // function of time. The numbers are gathered here on the same principle
    // as the rest of the file — a single place for the project's motion
    // parameters, not inside the view.

    /// Scroll speed, in points per second. Tuned so the title stays readable
    /// while moving rather than blurring past: a title of ordinary length
    /// takes several seconds to scroll by rather than flying past almost instantly.
    public static let marqueeSpeed: CGFloat = 30

    /// Pause at the start of the line before scrolling begins. Gives time to
    /// read the visible part of the text before it slides left, and repeats
    /// at the start of every following pass — not just once when it appears.
    public static let marqueePause: TimeInterval = 1.2

    /// Gap between the end of one pass and the start of the next. In
    /// MarqueeText this is the distance between the two copies of the text
    /// that keeps them from reading as one continuous string when the second
    /// copy slides into place behind the first.
    public static let marqueeGap: CGFloat = 24

    /// Width of the fade-out at each edge of the marquee, in points.
    public static let marqueeEdgeFade: CGFloat = 16
}
