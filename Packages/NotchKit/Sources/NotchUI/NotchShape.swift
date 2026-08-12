import SwiftUI

/// Силуэт панели: прямоугольник, прижатый к верхней кромке экрана,
/// с округлыми нижними углами и вогнутыми верхними.
///
/// Вогнутые углы — главная деталь: они делают стык с корпусом литым,
/// как будто панель вытекает из выреза, а не лежит поверх него.
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

    /// concaveRadius сегодня константа во всех вызывающих местах, поэтому
    /// его отсутствие здесь было незаметно молчаливым скачком; следующий
    /// план обоснованно предположит, что публичный var анимируется, как
    /// остальные три поля, — поэтому он тоже часть animatableData.
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
        // Радиусы не должны съедать фигуру целиком на маленьких размерах.
        let bottom = min(bottomRadius, height / 2, width / 2)
        let concave = min(concaveRadius, height / 2, width / 2)

        let left = rect.midX - width / 2
        let right = rect.midX + width / 2
        let top = rect.minY
        let bottomY = rect.minY + height

        var path = Path()
        path.move(to: CGPoint(x: left - concave, y: top))
        // Левый вогнутый угол: дуга выгибается внутрь панели.
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
        // Правый вогнутый угол: зеркало левого — стык с меню-баром должен
        // выглядеть литым с обеих сторон, а не только слева.
        path.addQuadCurve(
            to: CGPoint(x: right + concave, y: top),
            control: CGPoint(x: right, y: top)
        )
        path.closeSubpath()
        return path
    }
}
