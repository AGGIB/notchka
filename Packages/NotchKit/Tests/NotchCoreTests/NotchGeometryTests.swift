import Testing
import CoreGraphics
@testable import NotchCore

/// Metrics close to a MacBook Pro 14": width 1512, notch 252 pt with 630 on each side.
private let notchedScreen = ScreenMetrics(
    frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
    safeAreaTopInset: 32,
    auxiliaryTopLeftWidth: 630,
    auxiliaryTopRightWidth: 630
)

@Test("On a screen with a notch, the cutout is derived from the auxiliary areas")
func notchRectIsDerivedFromAuxiliaryAreas() throws {
    let geometry = try #require(NotchGeometryCalculator.geometry(for: notchedScreen))
    #expect(geometry.notchRect.origin.x == 630)
    #expect(geometry.notchRect.origin.y == 0)
    #expect(geometry.notchRect.width == 252)
    #expect(geometry.notchRect.height == 32)
}

@Test("The hot zone is wider than the notch by 6 pt on each side and 4 pt below")
func hotZoneIsInflatedNotch() throws {
    let geometry = try #require(NotchGeometryCalculator.geometry(for: notchedScreen))
    #expect(geometry.hotZone.origin.x == 624)
    #expect(geometry.hotZone.width == 264)
    #expect(geometry.hotZone.height == 36)
}

@Test("A screen without a notch has no geometry")
func screenWithoutNotchHasNoGeometry() {
    let external = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
        safeAreaTopInset: 0,
        auxiliaryTopLeftWidth: 0,
        auxiliaryTopRightWidth: 0
    )
    #expect(NotchGeometryCalculator.geometry(for: external) == nil)
}

@Test("Inconsistent auxiliary areas do not produce a negative notch")
func inconsistentAuxiliaryAreasAreRejected() {
    let broken = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1000, height: 700),
        safeAreaTopInset: 32,
        auxiliaryTopLeftWidth: 600,
        auxiliaryTopRightWidth: 600
    )
    #expect(NotchGeometryCalculator.geometry(for: broken) == nil)
}

@Test("Zero auxiliary areas with a claimed notch do not produce a full-screen cutout")
func zeroAuxiliaryAreasAreRejectedDespiteNotch() {
    // Reproduces what ScreenMetricsReader used to return when both sides were
    // nil: safeAreaTopInset > 0 (there is a notch), but the auxiliary areas
    // are zero. notchWidth would then honestly compute as frame.width — the
    // calculator must reject this itself, not rely on the caller never
    // passing such metrics.
    let degenerate = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        safeAreaTopInset: 32,
        auxiliaryTopLeftWidth: 0,
        auxiliaryTopRightWidth: 0
    )
    #expect(NotchGeometryCalculator.geometry(for: degenerate) == nil)
}

@Test("A single zero auxiliary area with a claimed notch is also rejected")
func singleZeroAuxiliaryAreaIsRejected() {
    // Asymmetric variant of the same degradation: only one nil from AppKit.
    let halfDegenerate = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        safeAreaTopInset: 32,
        auxiliaryTopLeftWidth: 0,
        auxiliaryTopRightWidth: 630
    )
    #expect(NotchGeometryCalculator.geometry(for: halfDegenerate) == nil)
}
