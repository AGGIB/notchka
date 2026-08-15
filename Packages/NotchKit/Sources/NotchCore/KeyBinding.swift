/// A key expressed independently of AppKit.
public enum PanelKey: Sendable, Equatable {
    case digit1, digit2, digit3, digit4
    case tab, escape
    case other(UInt16)
}

public struct PanelModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = PanelModifiers(rawValue: 1 << 0)
    public static let option = PanelModifiers(rawValue: 1 << 1)
    public static let shift = PanelModifiers(rawValue: 1 << 2)
}

/// What a key does in the expanded panel.
///
/// Separate from AppKit, because the layout is a rule, not a mechanism:
/// checking "⌘2 opens the clipboard" should work without a window and without key presses.
public enum KeyBinding {
    public static func event(forKeyCode key: PanelKey, modifiers: PanelModifiers) -> NotchEvent? {
        switch key {
        // Digits only work with Command: without it, this is regular input
        // that should reach the search field.
        case .digit1 where modifiers.contains(.command): .selectTab(.music)
        case .digit2 where modifiers.contains(.command): .selectTab(.clipboard)
        case .digit3 where modifiers.contains(.command): .selectTab(.notes)
        case .digit4 where modifiers.contains(.command): .selectTab(.pins)
        case .tab: .cycleTab
        case .escape: .dismiss
        default: nil
        }
    }
}
