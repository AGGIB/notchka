import AppKit
import Carbon.HIToolbox
import NotchCore

/// Translates `NSEvent` into `NotchCore.KeyBinding` terms — the single place
/// in the app where an AppKit key code meets `PanelKey`. The layout
/// (KeyBinding) intentionally knows nothing about AppKit, so the bridge lives
/// here, in the app target.
enum PanelKeyHandler {
    /// Key codes come from Carbon.HIToolbox (kVK_*), not magic numbers:
    /// the keyboard layout can be anything, but the physical position of
    /// keys (and their virtual keyCode) doesn't depend on it.
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

    /// Of all `NSEvent.ModifierFlags`, the layout only needs three —
    /// the rest (control, function, caps lock, etc.) don't affect any
    /// combination in KeyBinding.
    static func panelModifiers(for event: NSEvent) -> PanelModifiers {
        var modifiers: PanelModifiers = []
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        return modifiers
    }
}
