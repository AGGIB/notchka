import CoreGraphics
import NotchCore

/// Panel sizes by state.
///
/// Gathered in one place because three things depend on them at once: drawing
/// the shape, the window size, and hit-testing the cursor against the expanded
/// panel. If they drifted apart, they'd produce a panel that closes under the cursor.
public enum PanelMetrics {
    /// Fixed-size window that everything else lives inside.
    public static let windowSize = CGSize(width: 680, height: 300)
    public static let concaveRadius: CGFloat = 8

    public static let peekPadding = CGSize(width: 120, height: 28)
    public static let expandedSize = CGSize(width: 620, height: 264)

    /// Side insets, combined.
    public static let horizontalInset: CGFloat = 26
    /// Gap between the bottom edge of the physical notch and the content.
    public static let notchGap: CGFloat = 6
    /// Bottom inset.
    public static let bottomInset: CGFloat = 14

    /// Notch height for tests and estimates. At runtime the real value is
    /// used, measured from the screen's `safeAreaInsets.top`: on current
    /// MacBooks that's 32 pt, but it can't be hardcoded — the panel must be
    /// computed from whatever notch actually exists.
    public static let referenceNotchHeight: CGFloat = 32

    /// How much the panel eats into the content for a notch of height `notchHeight`.
    ///
    /// The top inset is derived from the real notch height, not from a
    /// constant: it used to be hardcoded as 24 for a 32 pt notch, and the
    /// notch covered the top of the artwork and the track title. Computing
    /// content from the physical notch is the only way to avoid repeating that.
    public static func contentInsets(notchHeight: CGFloat) -> CGSize {
        CGSize(width: horizontalInset, height: notchHeight + notchGap + bottomInset)
    }

    /// Space left for tab content in the expanded panel.
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
