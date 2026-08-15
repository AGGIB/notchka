import Testing
@testable import NotchUI

@Test("plain pin shows its value")
func plainPinShowsValue() {
    let chip = PinChip(id: 1, label: "Mail", value: "a@b.kz", isSensitive: false, colorHex: nil, icon: nil)
    #expect(chip.displayValue == "a@b.kz")
}

@Test("sensitive pin shows a mask, not the value")
func sensitivePinIsMasked() {
    let chip = PinChip(id: 2, label: "IIN", value: "123456789012", isSensitive: true, colorHex: nil, icon: nil)
    #expect(chip.displayValue.contains("123456") == false)
    #expect(chip.displayValue.contains("•"))
}

@Test("pasting inserts the real value, not the mask")
func pasteUsesRealValue() {
    let chip = PinChip(id: 3, label: "IIN", value: "123456789012", isSensitive: true, colorHex: nil, icon: nil)
    #expect(chip.pasteValue == "123456789012")
}

@Test("long value is truncated for display only, not on paste")
func longValueIsTruncatedOnlyForDisplay() {
    let long = String(repeating: "9", count: 100)
    let chip = PinChip(id: 4, label: "Long", value: long, isSensitive: false, colorHex: nil, icon: nil)
    #expect(chip.displayValue.count < long.count)
    #expect(chip.pasteValue == long)
}

@Test("an invalid color doesn't crash the card")
func badColourFallsBack() {
    let chip = PinChip(id: 5, label: "P", value: "z", isSensitive: false, colorHex: "not a color", icon: nil)
    #expect(chip.accentOrDefault != nil)
}
