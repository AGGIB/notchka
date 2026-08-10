/// Единственный источник истины о состоянии панели.
/// Синхронная и не зависит от времени: пороги курсора и таймер автопика
/// живут снаружи и приходят сюда уже готовыми событиями.
public struct NotchStateMachine: Sendable {
    public private(set) var state: NotchState = .closed
    /// Вкладка, на которую вернёт хоткей.
    public private(set) var lastTab: NotchTab = .music
    public private(set) var isFullScreen = false

    public init() {}

    /// Возвращает новое состояние, если оно изменилось, иначе nil.
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
            // В фуллскрине меню-бар скрыт, а область выреза чёрная — панели негде жить.
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

        // Уход курсора из развёрнутой панели её не закрывает: работа с лентой
        // буфера подразумевает движение мыши куда угодно.
        default:
            return nil
        }
    }
}
