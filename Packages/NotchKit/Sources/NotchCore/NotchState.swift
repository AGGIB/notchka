/// Вкладки панели. Сырые значения совпадают с цифрами хоткеев ⌘1…⌘4.
public enum NotchTab: Int, Sendable, Equatable, CaseIterable {
    case music = 1
    case clipboard
    case notes
    case pins

    /// Следующая вкладка по кругу — для ⇥.
    public var next: NotchTab {
        NotchTab(rawValue: rawValue % NotchTab.allCases.count + 1) ?? .music
    }
}

/// Почему панель находится в промежуточном состоянии.
/// Различие важно: hover закрывается уходом курсора, автопик — по таймеру.
public enum PeekReason: Sendable, Equatable {
    case hover
    case trackChanged
}

public enum NotchState: Sendable, Equatable {
    case closed
    case peek(PeekReason)
    case expanded(NotchTab)
}

public enum NotchEvent: Sendable, Equatable {
    case cursorEnteredHotZone
    case cursorLeftHotZone
    case click
    case hotkey
    /// Esc или клик вне панели.
    case dismiss
    case selectTab(NotchTab)
    case cycleTab
    case trackChanged
    /// Истекли 2 секунды автопика по смене трека.
    case peekTimedOut
    case fullScreenChanged(Bool)
}
