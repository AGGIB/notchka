import SwiftUI

/// Panel silhouette: a rectangle pressed against the top edge of the screen,
/// with rounded bottom corners and concave top corners.
///
/// The concave corners are the key detail: they make the seam with the chassis look molded,
/// as if the panel flows out of the notch rather than sitting on top of it.
public struct NotchShape: Shape {
    public var width: CGFloat
    public var height: CGFloat
    public var bottomRadius: CGFloat
    public var concaveRadius: CGFloat

    public init(width: CGFloat, height: CGFloat, bottomRadius: CGFloat, concaveRadius: CGFloat) {
        self.width = width
        self.height = height
        self.bottomRadius = bottomRadius
        self.concaveRadius = concaveRadius
    }

    /// concaveRadius is a constant at every call site today, so its
    /// absence here would be a silent, easy-to-miss gap; a future
    /// plan will reasonably assume a public var animates like the
    /// other three fields — so it's part of animatableData too.
    public var animatableData: AnimatablePair<AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat>, CGFloat> {
        get {
            AnimatablePair(AnimatablePair(AnimatablePair(width, height), bottomRadius), concaveRadius)
        }
        set {
            width = newValue.first.first.first
            height = newValue.first.first.second
            bottomRadius = newValue.first.second
            concaveRadius = newValue.second
        }
    }

    public func path(in rect: CGRect) -> Path {
        // Radii must not consume the whole shape at small sizes.
        let bottom = min(bottomRadius, height / 2, width / 2)
        let concave = min(concaveRadius, height / 2, width / 2)

        let left = rect.midX - width / 2
        let right = rect.midX + width / 2
        let top = rect.minY
        let bottomY = rect.minY + height

        var path = Path()
        path.move(to: CGPoint(x: left - concave, y: top))
        // Left concave corner: the arc curves inward into the panel.
        path.addQuadCurve(
            to: CGPoint(x: left, y: top + concave),
            control: CGPoint(x: left, y: top)
        )
        path.addLine(to: CGPoint(x: left, y: bottomY - bottom))
        path.addQuadCurve(
            to: CGPoint(x: left + bottom, y: bottomY),
            control: CGPoint(x: left, y: bottomY)
        )
        path.addLine(to: CGPoint(x: right - bottom, y: bottomY))
        path.addQuadCurve(
            to: CGPoint(x: right, y: bottomY - bottom),
            control: CGPoint(x: right, y: bottomY)
        )
        path.addLine(to: CGPoint(x: right, y: top + concave))
        // Right concave corner: mirrors the left — the seam with the menu bar should
        // look molded on both sides, not just the left.
        path.addQuadCurve(
            to: CGPoint(x: right + concave, y: top),
            control: CGPoint(x: right, y: top)
        )
        path.closeSubpath()
        return path
    }
}
