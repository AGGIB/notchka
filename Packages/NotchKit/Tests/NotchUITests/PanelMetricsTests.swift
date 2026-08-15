import Testing
import CoreGraphics
import NotchCore
@testable import NotchUI

private let notch = CGSize(width: 200, height: 32)

@Test("panel matches the notch exactly at rest")
func closedMatchesNotch() {
    #expect(PanelMetrics.size(for: .closed, notch: notch) == notch)
}

@Test("peek is wider and taller than the notch")
func peekIsLarger() {
    let size = PanelMetrics.size(for: .peek(.hover), notch: notch)
    #expect(size.width > notch.width)
    #expect(size.height > notch.height)
}

@Test("expanded is larger than peek")
func expandedIsLargerThanPeek() {
    let peek = PanelMetrics.size(for: .peek(.hover), notch: notch)
    let expanded = PanelMetrics.size(for: .expanded(.music), notch: notch)
    #expect(expanded.width > peek.width)
    #expect(expanded.height > peek.height)
}

@Test("expanded size is the same across all tabs — the panel doesn't jump when switching")
func expandedSizeIsTabIndependent() {
    let sizes = NotchTab.allCases.map { PanelMetrics.size(for: .expanded($0), notch: notch) }
    #expect(Set(sizes.map(\.width)).count == 1)
    #expect(Set(sizes.map(\.height)).count == 1)
}

@Test("expanded fits in the window with room to spare for the concave ears")
func expandedFitsWindow() {
    let expanded = PanelMetrics.size(for: .expanded(.music), notch: notch)
    #expect(expanded.width + 2 * PanelMetrics.concaveRadius <= PanelMetrics.windowSize.width)
    #expect(expanded.height <= PanelMetrics.windowSize.height)
}

/// The artwork is sized to match the panel's current size, and until now
/// that relationship was held together by a single comment. If expandedSize
/// shrinks or the insets grow, the artwork stops fitting, and SwiftUI won't
/// say a word about it: it gives no error or warning on overflow, it just
/// clips or overlaps.
@Test("artwork fits the content area's height")
func artworkFitsContentArea() {
    let content = PanelMetrics.contentSize(notchHeight: PanelMetrics.referenceNotchHeight)
    #expect(MusicTabView.artworkSize <= content.height)
}

/// Content must start below the physical notch. The top inset used to be
/// hardcoded as 24 for a 32 pt notch, and the notch ended up covering the
/// top of the artwork and the track title — from the outside it looked like
/// a cropped image, not a layout bug, and a human spotted it, not a test.
@Test("top inset is never smaller than the notch height")
func topInsetClearsTheNotch() {
    for notchHeight in [CGFloat(28), 32, 40] {
        let insets = PanelMetrics.contentInsets(notchHeight: notchHeight)
        #expect(insets.height - PanelMetrics.bottomInset >= notchHeight)
    }
}

/// The tab column and the artwork share one row. Their combined width, plus
/// all the gaps, must leave the player a reasonable width — not eat it down
/// to zero.
@Test("player keeps a usable width after the tab column and artwork")
func playerKeepsUsableWidth() {
    let content = PanelMetrics.contentSize(notchHeight: PanelMetrics.referenceNotchHeight)
    let takenByArtwork = MusicTabView.artworkSize + 2 * PanelMetrics.horizontalInset
    #expect(content.width - takenByArtwork > 200)
}
