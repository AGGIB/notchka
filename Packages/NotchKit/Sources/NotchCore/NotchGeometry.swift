import CoreGraphics

/// Position of the notch and its trigger zone.
/// Coordinates are in screen space, origin is the top-left corner of the display.
public struct NotchGeometry: Sendable, Equatable {
    public let notchRect: CGRect
    public let hotZone: CGRect

    public init(notchRect: CGRect, hotZone: CGRect) {
        self.notchRect = notchRect
        self.hotZone = hotZone
    }
}

public enum NotchGeometryCalculator {
    /// Horizontal margin: the cursor doesn't have to land inside the notch pixel-perfect.
    public static let hotZoneInsetX: CGFloat = 6
    /// Bottom margin: the notch reacts slightly before the cursor reaches its edge.
    public static let hotZoneInsetBottom: CGFloat = 4

    public static func geometry(for metrics: ScreenMetrics) -> NotchGeometry? {
        // A zero inset means "this screen has no notch" (e.g. an external
        // monitor) — for it, no geometry exists, rather than a degenerate
        // rectangle of zero height.
        guard metrics.safeAreaTopInset > 0 else { return nil }

        // Both side areas must be measured and positive: by screen construction
        // the notch is always separated from each edge by a menu bar strip,
        // zero width on either side never happens on a screen with a notch.
        // This is the same case ScreenMetricsReader catches at the AppKit boundary
        // (a nil side area), but the calculator doesn't have to trust the caller —
        // it's a public API and could receive such metrics directly.
        guard metrics.auxiliaryTopLeftWidth > 0, metrics.auxiliaryTopRightWidth > 0 else {
            return nil
        }

        let notchWidth = metrics.frame.width
            - metrics.auxiliaryTopLeftWidth
            - metrics.auxiliaryTopRightWidth
        // A mismatch between the side areas (wider than the screen itself) gives
        // a zero or negative width — this is an impossible geometry that must not
        // be handed back to the caller as-is.
        guard notchWidth > 0 else { return nil }

        let notchRect = CGRect(
            x: metrics.auxiliaryTopLeftWidth,
            y: 0,
            width: notchWidth,
            height: metrics.safeAreaTopInset
        )
        let hotZone = CGRect(
            x: notchRect.minX - hotZoneInsetX,
            y: 0,
            width: notchRect.width + hotZoneInsetX * 2,
            height: notchRect.height + hotZoneInsetBottom
        )
        return NotchGeometry(notchRect: notchRect, hotZone: hotZone)
    }
}

extension NotchGeometry {
    /// Rectangle whose exit closes the expanded panel.
    ///
    /// The entry zone (`hotZone`) is intentionally small — the notch plus a
    /// few points — and the open panel can't be checked against it: moving
    /// the cursor toward the visible panel, the user would exit the zone and
    /// it would close right under the cursor. That's why retention is checked
    /// against the panel's current visible bounds: horizontally — the center
    /// matches the notch center (the panel is drawn horizontally centered
    /// above it, see NotchPanelView), vertically — from the top edge of the
    /// screen (`y: 0`) downward, because the panel is pinned to that edge in
    /// every state.
    public func retentionZone(for panel: CGSize) -> CGRect {
        CGRect(
            x: notchRect.midX - panel.width / 2,
            y: 0,
            width: panel.width,
            height: panel.height
        )
    }
}
