import Testing
@testable import NotchUI

@Test("без разрешения показывается объяснение вместо ленты")
func promptShowsWhenNotTrusted() {
    #expect(ClipboardTabContent.resolve(isAccessibilityTrusted: false) == .permissionPrompt)
}

@Test("с разрешением показывается лента вместо объяснения")
func ribbonShowsWhenTrusted() {
    #expect(ClipboardTabContent.resolve(isAccessibilityTrusted: true) == .ribbon)
}
