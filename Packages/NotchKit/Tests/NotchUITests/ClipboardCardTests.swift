import Testing
@testable import NotchUI

@Test("длинный текст обрезается с многоточием")
func longTextIsTruncated() {
    let preview = ClipboardCard.preview(for: String(repeating: "а", count: 200), maxLength: 40)
    #expect(preview.count <= 41)
    #expect(preview.hasSuffix("…"))
}

@Test("короткий текст не трогается")
func shortTextIsUnchanged() {
    #expect(ClipboardCard.preview(for: "коротко", maxLength: 40) == "коротко")
}

@Test("переводы строк схлопываются — карточка в одну-две строки высотой")
func newlinesAreCollapsed() {
    #expect(ClipboardCard.preview(for: "первая\nвторая\n\nтретья", maxLength: 40) == "первая вторая третья")
}

@Test("ведущие и хвостовые пробелы убираются")
func whitespaceIsTrimmed() {
    #expect(ClipboardCard.preview(for: "   текст   ", maxLength: 40) == "текст")
}

@Test("пустой текст даёт пустое превью, а не многоточие")
func emptyStaysEmpty() {
    #expect(ClipboardCard.preview(for: "   ", maxLength: 40) == "")
}
