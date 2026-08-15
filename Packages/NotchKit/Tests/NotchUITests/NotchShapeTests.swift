import Testing
import SwiftUI
@testable import NotchUI

private let canvas = CGRect(x: 0, y: 0, width: 600, height: 400)

@Test("shape height matches the given value, width includes the concave ears")
func shapeRespectsExplicitSize() {
    let shape = NotchShape(width: 300, height: 150, bottomRadius: 22, concaveRadius: 10)
    let bounds = shape.path(in: canvas).boundingRect
    // width sets the body; the 10 pt ears on each side flare out beyond it.
    #expect(abs(bounds.width - 320) < 1)
    #expect(abs(bounds.height - 150) < 1)
}

@Test("shape is centered horizontally and flush with the top")
func shapeIsCenteredAtTop() {
    let shape = NotchShape(width: 300, height: 150, bottomRadius: 22, concaveRadius: 10)
    let bounds = shape.path(in: canvas).boundingRect
    #expect(abs(bounds.midX - canvas.midX) < 1)
    #expect(abs(bounds.minY) < 1)
}

@Test("concave ears widen the shape by exactly two radii")
func topCornersFlareOutward() {
    let plain = NotchShape(width: 300, height: 150, bottomRadius: 22, concaveRadius: 0)
    let flared = NotchShape(width: 300, height: 150, bottomRadius: 22, concaveRadius: 12)
    #expect(abs(plain.path(in: canvas).boundingRect.width - 300) < 1)
    #expect(abs(flared.path(in: canvas).boundingRect.width - 324) < 1)
}

@Test("body is strictly vertical below the concave curve")
func bodyIsVerticalBelowEars() {
    let shape = NotchShape(width: 300, height: 150, bottomRadius: 22, concaveRadius: 12)
    let path = shape.path(in: canvas)
    let bodyLeft = canvas.midX - 150
    // y = 60 is below the ear (12 pt) and above the bottom corner radius (150 - 22 = 128).
    #expect(path.contains(CGPoint(x: bodyLeft + 4, y: 60)) == true)
    #expect(path.contains(CGPoint(x: bodyLeft - 4, y: 60)) == false)
}

@Test("animatable data round-trips the dimensions")
func animatableDataRoundTrips() {
    // concaveRadius is set to different values on input (4) and output (10) — otherwise
    // the test couldn't distinguish "field is included in animatableData" from "field is
    // missing from AnimatablePair and the value just didn't change."
    var shape = NotchShape(width: 100, height: 50, bottomRadius: 8, concaveRadius: 4)
    shape.animatableData = NotchShape(
        width: 300, height: 150, bottomRadius: 22, concaveRadius: 10
    ).animatableData
    #expect(shape.width == 300)
    #expect(shape.height == 150)
    #expect(shape.bottomRadius == 22)
    #expect(shape.concaveRadius == 10)
}
