import Testing
@testable import NotchUI

@Test("without permission, the explanation is shown instead of the ribbon")
func promptShowsWhenNotTrusted() {
    #expect(ClipboardTabContent.resolve(isAccessibilityTrusted: false) == .permissionPrompt)
}

@Test("with permission, the ribbon is shown instead of the explanation")
func ribbonShowsWhenTrusted() {
    #expect(ClipboardTabContent.resolve(isAccessibilityTrusted: true) == .ribbon)
}
