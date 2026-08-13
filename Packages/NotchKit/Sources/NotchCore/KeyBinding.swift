/// Клавиша в терминах, независимых от AppKit.
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

/// Что делает клавиша в раскрытой панели.
///
/// Отдельно от AppKit, потому что раскладка — это правило, а не механика:
/// проверять «⌘2 открывает буфер» надо без окна и без нажатий.
public enum KeyBinding {
    public static func event(forKeyCode key: PanelKey, modifiers: PanelModifiers) -> NotchEvent? {
        switch key {
        // Цифры работают только с командой: без неё это обычный ввод,
        // который должен попасть в поле поиска.
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
