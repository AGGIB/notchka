import Testing
import CoreGraphics
import NotchCore
@testable import NotchUI

private let notch = CGSize(width: 200, height: 32)

@Test("в покое панель ровно по вырезу")
func closedMatchesNotch() {
    #expect(PanelMetrics.size(for: .closed, notch: notch) == notch)
}

@Test("peek шире и выше выреза")
func peekIsLarger() {
    let size = PanelMetrics.size(for: .peek(.hover), notch: notch)
    #expect(size.width > notch.width)
    #expect(size.height > notch.height)
}

@Test("разворот больше peek")
func expandedIsLargerThanPeek() {
    let peek = PanelMetrics.size(for: .peek(.hover), notch: notch)
    let expanded = PanelMetrics.size(for: .expanded(.music), notch: notch)
    #expect(expanded.width > peek.width)
    #expect(expanded.height > peek.height)
}

@Test("разворот одинаков для всех вкладок — панель не прыгает при переключении")
func expandedSizeIsTabIndependent() {
    let sizes = NotchTab.allCases.map { PanelMetrics.size(for: .expanded($0), notch: notch) }
    #expect(Set(sizes.map(\.width)).count == 1)
    #expect(Set(sizes.map(\.height)).count == 1)
}

@Test("разворот помещается в окно с запасом на вогнутые уши")
func expandedFitsWindow() {
    let expanded = PanelMetrics.size(for: .expanded(.music), notch: notch)
    #expect(expanded.width + 2 * PanelMetrics.concaveRadius <= PanelMetrics.windowSize.width)
    #expect(expanded.height <= PanelMetrics.windowSize.height)
}
