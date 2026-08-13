import AppKit
import Carbon.HIToolbox
import NotchCore

/// Перевод `NSEvent` в термины `NotchCore.KeyBinding` — единственное место
/// в приложении, где код клавиши AppKit встречается с `PanelKey`. Раскладка
/// (KeyBinding) намеренно ничего не знает про AppKit, поэтому мост живёт
/// здесь, в app-таргете.
enum PanelKeyHandler {
    /// Коды клавиш — из Carbon.HIToolbox (kVK_*), а не магические числа:
    /// раскладка клавиатуры может быть любой, но физическое расположение
    /// клавиш (и их virtual keyCode) от неё не зависит.
    static func panelKey(for event: NSEvent) -> PanelKey {
        switch event.keyCode {
        case UInt16(kVK_ANSI_1): .digit1
        case UInt16(kVK_ANSI_2): .digit2
        case UInt16(kVK_ANSI_3): .digit3
        case UInt16(kVK_ANSI_4): .digit4
        case UInt16(kVK_Tab): .tab
        case UInt16(kVK_Escape): .escape
        default: .other(event.keyCode)
        }
    }

    /// Из всего `NSEvent.ModifierFlags` раскладке нужны только три —
    /// остальные (control, function, caps lock и т.д.) ни на одно
    /// сочетание в KeyBinding не влияют.
    static func panelModifiers(for event: NSEvent) -> PanelModifiers {
        var modifiers: PanelModifiers = []
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        return modifiers
    }
}
