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

/// Обложка подобрана под текущий размер панели, и связь эта до сих пор
/// держалась на одном комментарии. Уменьшится expandedSize или вырастут
/// отступы — обложка перестанет помещаться, а SwiftUI об этом не скажет
/// ничего: он не даёт на переполнении ни ошибки, ни предупреждения, просто
/// обрезает или накладывает одно на другое.
@Test("обложка помещается в область содержимого по высоте")
func artworkFitsContentArea() {
    let content = PanelMetrics.contentSize(notchHeight: PanelMetrics.referenceNotchHeight)
    #expect(MusicTabView.artworkSize <= content.height)
}

/// Содержимое обязано начинаться ниже физического выреза. Отступ сверху
/// когда-то был зашит числом 24 при вырезе в 32 pt, и чёлка накрывала верх
/// обложки и название трека — снаружи это выглядело как обрезанная картинка,
/// а не как ошибка раскладки, и заметил это человек, а не тест.
@Test("верхний отступ не меньше высоты выреза")
func topInsetClearsTheNotch() {
    for notchHeight in [CGFloat(28), 32, 40] {
        let insets = PanelMetrics.contentInsets(notchHeight: notchHeight)
        #expect(insets.height - PanelMetrics.bottomInset >= notchHeight)
    }
}

/// Колонка вкладок и обложка делят одну строку. Их сумма со всеми зазорами
/// обязана оставлять плееру осмысленную ширину, а не съедать её в ноль.
@Test("после колонки вкладок и обложки плееру остаётся место")
func playerKeepsUsableWidth() {
    let content = PanelMetrics.contentSize(notchHeight: PanelMetrics.referenceNotchHeight)
    let takenByArtwork = MusicTabView.artworkSize + 2 * PanelMetrics.horizontalInset
    #expect(content.width - takenByArtwork > 200)
}
