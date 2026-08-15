import Testing
import NotchCore
@testable import NotchUI

/// Every tab must have a non-empty icon and label.
///
/// NotchTab.symbolName/.title are currently written as a switch with no default, so
/// a forgotten case will fail to compile NotchUI right away. But that's a property
/// of the current implementation, not a guarantee in itself: a default branch
/// ("just in case — questionmark for anything unknown") would turn
/// this safeguard into a silent hole — the tab column (TabRailView) enumerates
/// NotchTab.allCases and never checks that the icon it gets is meaningful.
/// The test pins down the invariant itself, not however it's
/// achieved today — and it will survive a refactor of the switch that removes this safeguard.
@Test("every tab has a non-empty icon and label")
func everyTabHasIconAndLabel() {
    for tab in NotchTab.allCases {
        #expect(!tab.symbolName.isEmpty)
        #expect(!tab.title.isEmpty)
    }
}

@Test("tab icons are distinct — otherwise the column becomes unreadable")
func tabIconsAreDistinct() {
    let symbols = NotchTab.allCases.map(\.symbolName)
    #expect(Set(symbols).count == NotchTab.allCases.count)
}

@Test("tab labels are distinct")
func tabTitlesAreDistinct() {
    let titles = NotchTab.allCases.map(\.title)
    #expect(Set(titles).count == NotchTab.allCases.count)
}
