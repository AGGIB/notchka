/// The single source of truth for the panel's state.
/// Synchronous and time-independent: cursor thresholds and the auto-peek timer
/// live outside and arrive here as ready-made events.
public struct NotchStateMachine: Sendable {
    public private(set) var state: NotchState = .closed
    /// The tab the hotkey will return to.
    public private(set) var lastTab: NotchTab = .music
    public private(set) var isFullScreen = false

    public init() {}

    /// Returns the new state if it changed, otherwise nil.
    @discardableResult
    public mutating func handle(_ event: NotchEvent) -> NotchState? {
        guard let next = resolve(event), next != state else { return nil }
        if case .expanded(let tab) = next { lastTab = tab }
        state = next
        return next
    }

    private mutating func resolve(_ event: NotchEvent) -> NotchState? {
        if case .fullScreenChanged(let isActive) = event {
            isFullScreen = isActive
            // In full screen the menu bar is hidden and the notch area is black — there's nowhere for the panel to live.
            return isActive ? .closed : nil
        }
        guard !isFullScreen else { return nil }

        switch (state, event) {
        case (.closed, .cursorEnteredHotZone):
            return .peek(.hover)
        case (.closed, .trackChanged):
            return .peek(.trackChanged)
        case (.closed, .hotkey):
            return .expanded(lastTab)

        case (.peek, .click):
            return .expanded(.music)
        case (.peek, .hotkey):
            return .expanded(lastTab)
        case (.peek(.hover), .cursorLeftHotZone):
            return .closed
        case (.peek(.trackChanged), .peekTimedOut):
            return .closed
        case (.peek(.trackChanged), .cursorEnteredHotZone):
            return .peek(.hover)

        case (.expanded, .dismiss), (.expanded, .hotkey):
            return .closed
        case (.expanded, .selectTab(let tab)):
            return .expanded(tab)
        case (.expanded(let tab), .cycleTab):
            return .expanded(tab.next)

        // Cursor leaving the expanded panel doesn't close it: working with the
        // clipboard feed implies mouse movement anywhere.
        default:
            return nil
        }
    }
}
