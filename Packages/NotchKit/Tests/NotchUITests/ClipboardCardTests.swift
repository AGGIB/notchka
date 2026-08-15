import Testing
@testable import NotchUI

@Test("long text is truncated with an ellipsis")
func longTextIsTruncated() {
    let preview = ClipboardCard.preview(for: String(repeating: "a", count: 200), maxLength: 40)
    #expect(preview.count <= 41)
    #expect(preview.hasSuffix("…"))
}

@Test("short text is left unchanged")
func shortTextIsUnchanged() {
    #expect(ClipboardCard.preview(for: "short", maxLength: 40) == "short")
}

@Test("newlines collapse — card stays one to two lines tall")
func newlinesAreCollapsed() {
    #expect(ClipboardCard.preview(for: "first\nsecond\n\nthird", maxLength: 40) == "first second third")
}

@Test("leading and trailing whitespace is trimmed")
func whitespaceIsTrimmed() {
    #expect(ClipboardCard.preview(for: "   text   ", maxLength: 40) == "text")
}

@Test("empty text yields an empty preview, not an ellipsis")
func emptyStaysEmpty() {
    #expect(ClipboardCard.preview(for: "   ", maxLength: 40) == "")
}
