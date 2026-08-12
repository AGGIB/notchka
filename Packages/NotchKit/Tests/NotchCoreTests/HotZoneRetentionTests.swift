import Testing
import CoreGraphics
@testable import NotchCore

private let metrics = ScreenMetrics(
    frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
    safeAreaTopInset: 32,
    auxiliaryTopLeftWidth: 630,
    auxiliaryTopRightWidth: 630
)

@Test("зона удержания охватывает раскрытую панель целиком")
func retentionZoneCoversPanel() throws {
    let geometry = try #require(NotchGeometryCalculator.geometry(for: metrics))
    let panel = CGSize(width: 620, height: 240)
    let zone = geometry.retentionZone(for: panel)
    #expect(zone.width >= panel.width)
    #expect(zone.height >= panel.height)
}

@Test("зона удержания центрирована по вырезу, а не по экрану")
func retentionZoneIsCentredOnNotch() throws {
    let geometry = try #require(NotchGeometryCalculator.geometry(for: metrics))
    let zone = geometry.retentionZone(for: CGSize(width: 620, height: 240))
    #expect(abs(zone.midX - geometry.notchRect.midX) < 0.001)
}

@Test("курсор на видимой панели остаётся внутри зоны удержания")
func cursorOnPanelStaysInside() throws {
    let geometry = try #require(NotchGeometryCalculator.geometry(for: metrics))
    let panel = CGSize(width: 620, height: 240)
    let zone = geometry.retentionZone(for: panel)
    // Точка у нижнего края панели — та самая, из-за которой панель
    // закрывалась под курсором при проверке по зоне входа.
    let nearBottomEdge = CGPoint(x: geometry.notchRect.midX, y: panel.height - 4)
    #expect(zone.contains(nearBottomEdge))
    #expect(geometry.hotZone.contains(nearBottomEdge) == false)
}
