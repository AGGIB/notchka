/// Panel tabs. Raw values match the hotkey digits ⌘1…⌘4.
public enum NotchTab: Int, Sendable, Equatable, CaseIterable {
    case music = 1
    case clipboard
    case notes
    case pins

    /// Next tab in the cycle — for ⇥.
    public var next: NotchTab {
        NotchTab(rawValue: rawValue % NotchTab.allCases.count + 1) ?? .music
    }
}

/// Why the panel is in an intermediate state.
/// The distinction matters: hover closes when the cursor leaves, auto-peek closes on a timer.
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
    /// Esc or a click outside the panel.
    case dismiss
    case selectTab(NotchTab)
    case cycleTab
    case trackChanged
    /// The 2-second auto-peek on track change has expired.
    case peekTimedOut
    case fullScreenChanged(Bool)
}
