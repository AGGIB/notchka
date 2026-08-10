import Testing
import CoreGraphics
@testable import NotchCore

/// Метрики, близкие к MacBook Pro 14": ширина 1512, чёлка 252 pt по 630 с каждой стороны.
private let notchedScreen = ScreenMetrics(
    frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
    safeAreaTopInset: 32,
    auxiliaryTopLeftWidth: 630,
    auxiliaryTopRightWidth: 630
)

@Test("на экране с чёлкой вырез считается из боковых областей")
func notchRectIsDerivedFromAuxiliaryAreas() throws {
    let geometry = try #require(NotchGeometryCalculator.geometry(for: notchedScreen))
    #expect(geometry.notchRect.origin.x == 630)
    #expect(geometry.notchRect.origin.y == 0)
    #expect(geometry.notchRect.width == 252)
    #expect(geometry.notchRect.height == 32)
}

@Test("горячая зона шире выреза на 6 pt с каждой стороны и на 4 pt ниже")
func hotZoneIsInflatedNotch() throws {
    let geometry = try #require(NotchGeometryCalculator.geometry(for: notchedScreen))
    #expect(geometry.hotZone.origin.x == 624)
    #expect(geometry.hotZone.width == 264)
    #expect(geometry.hotZone.height == 36)
}

@Test("на экране без чёлки геометрии нет")
func screenWithoutNotchHasNoGeometry() {
    let external = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
        safeAreaTopInset: 0,
        auxiliaryTopLeftWidth: 0,
        auxiliaryTopRightWidth: 0
    )
    #expect(NotchGeometryCalculator.geometry(for: external) == nil)
}

@Test("некорректные боковые области не дают отрицательной чёлки")
func inconsistentAuxiliaryAreasAreRejected() {
    let broken = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1000, height: 700),
        safeAreaTopInset: 32,
        auxiliaryTopLeftWidth: 600,
        auxiliaryTopRightWidth: 600
    )
    #expect(NotchGeometryCalculator.geometry(for: broken) == nil)
}
