import Testing
import CoreGraphics
@testable import NotchCore

private let metrics = ScreenMetrics(
    frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
    safeAreaTopInset: 32,
    auxiliaryTopLeftWidth: 630,
    auxiliaryTopRightWidth: 630
)

@Test("retention zone covers the expanded panel entirely")
func retentionZoneCoversPanel() throws {
    let geometry = try #require(NotchGeometryCalculator.geometry(for: metrics))
    let panel = CGSize(width: 620, height: 240)
    let zone = geometry.retentionZone(for: panel)
    #expect(zone.width >= panel.width)
    #expect(zone.height >= panel.height)
}

@Test("retention zone is centered on the notch, not the screen")
func retentionZoneIsCentredOnNotch() throws {
    let geometry = try #require(NotchGeometryCalculator.geometry(for: metrics))
    let zone = geometry.retentionZone(for: CGSize(width: 620, height: 240))
    #expect(abs(zone.midX - geometry.notchRect.midX) < 0.001)
}

@Test("cursor on the visible panel stays inside the retention zone")
func cursorOnPanelStaysInside() throws {
    let geometry = try #require(NotchGeometryCalculator.geometry(for: metrics))
    let panel = CGSize(width: 620, height: 240)
    let zone = geometry.retentionZone(for: panel)
    // Point near the panel's bottom edge — the one that used to make the panel
    // close under the cursor when checked against the entry zone.
    let nearBottomEdge = CGPoint(x: geometry.notchRect.midX, y: panel.height - 4)
    #expect(zone.contains(nearBottomEdge))
    #expect(geometry.hotZone.contains(nearBottomEdge) == false)
}
