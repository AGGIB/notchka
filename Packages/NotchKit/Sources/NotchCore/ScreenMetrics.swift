import CoreGraphics

/// A snapshot of screen measurements sufficient for computing the notch.
/// Deliberately decoupled from NSScreen: geometry must be computable for
/// synthetic configurations that aren't physically available.
public struct ScreenMetrics: Sendable, Equatable {
    public let frame: CGRect
    /// Notch height — zero means a screen with no notch.
    /// On macOS this comes from NSScreen.safeAreaInsets.top (leftmost screen).
    public let safeAreaTopInset: CGFloat
    /// Width of the menu bar strip to the left of the notch.
    /// macOS provides no direct API for the notch width, so we compute it
    /// by subtracting the side areas from the screen width.
    public let auxiliaryTopLeftWidth: CGFloat
    /// Width of the menu bar strip to the right of the notch.
    /// Together with auxiliaryTopLeftWidth this lets us derive the notch's
    /// position and width: notchX = auxiliaryTopLeftWidth, notchWidth = frame.width - left - right.
    public let auxiliaryTopRightWidth: CGFloat

    public init(
        frame: CGRect,
        safeAreaTopInset: CGFloat,
        auxiliaryTopLeftWidth: CGFloat,
        auxiliaryTopRightWidth: CGFloat
    ) {
        self.frame = frame
        self.safeAreaTopInset = safeAreaTopInset
        self.auxiliaryTopLeftWidth = auxiliaryTopLeftWidth
        self.auxiliaryTopRightWidth = auxiliaryTopRightWidth
    }
}
