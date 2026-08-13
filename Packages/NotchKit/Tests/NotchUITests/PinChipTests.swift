import Testing
@testable import NotchUI

@Test("обычный пин показывает значение")
func plainPinShowsValue() {
    let chip = PinChip(id: 1, label: "Почта", value: "a@b.kz", isSensitive: false, colorHex: nil, icon: nil)
    #expect(chip.displayValue == "a@b.kz")
}

@Test("чувствительный пин показывает маску, а не значение")
func sensitivePinIsMasked() {
    let chip = PinChip(id: 2, label: "ИИН", value: "123456789012", isSensitive: true, colorHex: nil, icon: nil)
    #expect(chip.displayValue.contains("123456") == false)
    #expect(chip.displayValue.contains("•"))
}

@Test("вставляется настоящее значение, а не маска")
func pasteUsesRealValue() {
    let chip = PinChip(id: 3, label: "ИИН", value: "123456789012", isSensitive: true, colorHex: nil, icon: nil)
    #expect(chip.pasteValue == "123456789012")
}

@Test("длинное значение обрезается в подписи, но не при вставке")
func longValueIsTruncatedOnlyForDisplay() {
    let long = String(repeating: "9", count: 100)
    let chip = PinChip(id: 4, label: "Длинный", value: long, isSensitive: false, colorHex: nil, icon: nil)
    #expect(chip.displayValue.count < long.count)
    #expect(chip.pasteValue == long)
}

@Test("некорректный цвет не роняет карточку")
func badColourFallsBack() {
    let chip = PinChip(id: 5, label: "П", value: "з", isSensitive: false, colorHex: "не цвет", icon: nil)
    #expect(chip.accentOrDefault != nil)
}
