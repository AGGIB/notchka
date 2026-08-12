import Testing
import SwiftUI
@testable import NotchUI

private let canvas = CGRect(x: 0, y: 0, width: 600, height: 400)

@Test("высота фигуры равна заданной, ширина включает вогнутые уши")
func shapeRespectsExplicitSize() {
    let shape = NotchShape(width: 300, height: 150, bottomRadius: 22, concaveRadius: 10)
    let bounds = shape.path(in: canvas).boundingRect
    // width задаёт корпус; уши по 10 pt с каждой стороны выходят за него наружу.
    #expect(abs(bounds.width - 320) < 1)
    #expect(abs(bounds.height - 150) < 1)
}

@Test("фигура центрирована по горизонтали и прижата к верху")
func shapeIsCenteredAtTop() {
    let shape = NotchShape(width: 300, height: 150, bottomRadius: 22, concaveRadius: 10)
    let bounds = shape.path(in: canvas).boundingRect
    #expect(abs(bounds.midX - canvas.midX) < 1)
    #expect(abs(bounds.minY) < 1)
}

@Test("вогнутые уши расширяют фигуру ровно на два радиуса")
func topCornersFlareOutward() {
    let plain = NotchShape(width: 300, height: 150, bottomRadius: 22, concaveRadius: 0)
    let flared = NotchShape(width: 300, height: 150, bottomRadius: 22, concaveRadius: 12)
    #expect(abs(plain.path(in: canvas).boundingRect.width - 300) < 1)
    #expect(abs(flared.path(in: canvas).boundingRect.width - 324) < 1)
}

@Test("ниже вогнутого скругления корпус строго вертикален")
func bodyIsVerticalBelowEars() {
    let shape = NotchShape(width: 300, height: 150, bottomRadius: 22, concaveRadius: 12)
    let path = shape.path(in: canvas)
    let bodyLeft = canvas.midX - 150
    // y = 60 ниже уха (12 pt) и выше нижнего скругления (150 - 22 = 128).
    #expect(path.contains(CGPoint(x: bodyLeft + 4, y: 60)) == true)
    #expect(path.contains(CGPoint(x: bodyLeft - 4, y: 60)) == false)
}

@Test("анимируемые данные переносят размеры туда и обратно")
func animatableDataRoundTrips() {
    // concaveRadius задан разным на входе (4) и на выходе (10) — иначе
    // тест не отличил бы «поле включено в animatableData» от «поле в
    // AnimatablePair отсутствует, а значение просто не менялось».
    var shape = NotchShape(width: 100, height: 50, bottomRadius: 8, concaveRadius: 4)
    shape.animatableData = NotchShape(
        width: 300, height: 150, bottomRadius: 22, concaveRadius: 10
    ).animatableData
    #expect(shape.width == 300)
    #expect(shape.height == 150)
    #expect(shape.bottomRadius == 22)
    #expect(shape.concaveRadius == 10)
}
