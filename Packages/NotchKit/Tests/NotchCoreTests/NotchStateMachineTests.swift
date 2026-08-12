import Testing
@testable import NotchCore

@Test("курсор в горячей зоне открывает peek")
func cursorOpensPeek() {
    var machine = NotchStateMachine()
    #expect(machine.handle(.cursorEnteredHotZone) == .peek(.hover))
}

@Test("хоткей из закрытого состояния разворачивает последнюю вкладку")
func hotkeyOpensLastTab() {
    var machine = NotchStateMachine()
    machine.handle(.hotkey)
    machine.handle(.selectTab(.notes))
    machine.handle(.dismiss)
    #expect(machine.handle(.hotkey) == .expanded(.notes))
}

@Test("смена трека даёт автопик, который сам истекает")
func trackChangeAutoPeeks() {
    var machine = NotchStateMachine()
    #expect(machine.handle(.trackChanged) == .peek(.trackChanged))
    #expect(machine.handle(.peekTimedOut) == .closed)
}

@Test("наведение во время автопика превращает его в hover")
func hoverTakesOverAutoPeek() {
    var machine = NotchStateMachine()
    machine.handle(.trackChanged)
    #expect(machine.handle(.cursorEnteredHotZone) == .peek(.hover))
}

@Test("клик по peek разворачивает вкладку музыки")
func clickExpandsToMusic() {
    var machine = NotchStateMachine()
    machine.handle(.cursorEnteredHotZone)
    #expect(machine.handle(.click) == .expanded(.music))
}

@Test("уход курсора закрывает peek")
func cursorLeaveClosesPeek() {
    var machine = NotchStateMachine()
    machine.handle(.cursorEnteredHotZone)
    #expect(machine.handle(.cursorLeftHotZone) == .closed)
}

@Test("уход курсора НЕ закрывает развёрнутую панель")
func cursorLeaveKeepsExpandedOpen() {
    var machine = NotchStateMachine()
    machine.handle(.hotkey)
    #expect(machine.handle(.cursorLeftHotZone) == nil)
    #expect(machine.state == .expanded(.music))
}

@Test("Esc и клик вне панели закрывают разворот")
func dismissClosesExpanded() {
    var machine = NotchStateMachine()
    machine.handle(.hotkey)
    #expect(machine.handle(.dismiss) == .closed)
}

@Test("хоткей на развёрнутой панели её закрывает")
func hotkeyTogglesExpandedClosed() {
    var machine = NotchStateMachine()
    machine.handle(.hotkey)
    #expect(machine.handle(.hotkey) == .closed)
}

@Test("цикл вкладок идёт по кругу")
func cycleTabWrapsAround() {
    var machine = NotchStateMachine()
    machine.handle(.hotkey)
    #expect(machine.handle(.cycleTab) == .expanded(.clipboard))
    #expect(machine.handle(.cycleTab) == .expanded(.notes))
    #expect(machine.handle(.cycleTab) == .expanded(.pins))
    #expect(machine.handle(.cycleTab) == .expanded(.music))
}

@Test("фуллскрин закрывает панель и глушит события")
func fullScreenDisablesPanel() {
    var machine = NotchStateMachine()
    machine.handle(.hotkey)
    #expect(machine.handle(.fullScreenChanged(true)) == .closed)
    #expect(machine.handle(.hotkey) == nil)
    #expect(machine.handle(.cursorEnteredHotZone) == nil)
    #expect(machine.state == .closed)
}

@Test("выход из фуллскрина возвращает реакцию на события")
func leavingFullScreenReenablesPanel() {
    var machine = NotchStateMachine()
    machine.handle(.fullScreenChanged(true))
    machine.handle(.fullScreenChanged(false))
    #expect(machine.handle(.cursorEnteredHotZone) == .peek(.hover))
}

@Test("хоткей в peek разворачивает на последнюю вкладку, отличаясь от клика")
func hotkeyInPeekUsesLastTabClickAlwaysMusic() {
    var machine = NotchStateMachine()
    // Set lastTab to something other than default
    machine.handle(.hotkey)  // Expand to .music
    machine.handle(.selectTab(.notes))  // Change to .notes, updating lastTab
    machine.handle(.dismiss)  // Close but keep lastTab as .notes

    // Test hotkey in peek: should use lastTab (.notes), not .music
    machine.handle(.cursorEnteredHotZone)  // Enter peek
    #expect(machine.handle(.hotkey) == .expanded(.notes))

    // Test click in peek: should always use .music, regardless of lastTab
    machine.handle(.dismiss)  // Close the expansion
    machine.handle(.trackChanged)  // Re-enter peek with .trackChanged reason
    #expect(machine.handle(.click) == .expanded(.music))
}

@Test("повторное событие без смены состояния не сообщается")
func idempotentEventsReturnNil() {
    var machine = NotchStateMachine()
    machine.handle(.cursorEnteredHotZone)
    #expect(machine.handle(.cursorEnteredHotZone) == nil)
}
