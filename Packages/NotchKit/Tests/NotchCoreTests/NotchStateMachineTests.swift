import Testing
@testable import NotchCore

@Test("cursor in hot zone opens peek")
func cursorOpensPeek() {
    var machine = NotchStateMachine()
    #expect(machine.handle(.cursorEnteredHotZone) == .peek(.hover))
}

@Test("hotkey from closed state expands the last tab")
func hotkeyOpensLastTab() {
    var machine = NotchStateMachine()
    machine.handle(.hotkey)
    machine.handle(.selectTab(.notes))
    machine.handle(.dismiss)
    #expect(machine.handle(.hotkey) == .expanded(.notes))
}

@Test("track change triggers an auto-peek that expires on its own")
func trackChangeAutoPeeks() {
    var machine = NotchStateMachine()
    #expect(machine.handle(.trackChanged) == .peek(.trackChanged))
    #expect(machine.handle(.peekTimedOut) == .closed)
}

@Test("hovering during auto-peek turns it into hover")
func hoverTakesOverAutoPeek() {
    var machine = NotchStateMachine()
    machine.handle(.trackChanged)
    #expect(machine.handle(.cursorEnteredHotZone) == .peek(.hover))
}

@Test("clicking peek expands the music tab")
func clickExpandsToMusic() {
    var machine = NotchStateMachine()
    machine.handle(.cursorEnteredHotZone)
    #expect(machine.handle(.click) == .expanded(.music))
}

@Test("cursor leaving closes peek")
func cursorLeaveClosesPeek() {
    var machine = NotchStateMachine()
    machine.handle(.cursorEnteredHotZone)
    #expect(machine.handle(.cursorLeftHotZone) == .closed)
}

@Test("cursor leaving does NOT close the expanded panel")
func cursorLeaveKeepsExpandedOpen() {
    var machine = NotchStateMachine()
    machine.handle(.hotkey)
    #expect(machine.handle(.cursorLeftHotZone) == nil)
    #expect(machine.state == .expanded(.music))
}

@Test("Esc and clicking outside the panel close the expanded view")
func dismissClosesExpanded() {
    var machine = NotchStateMachine()
    machine.handle(.hotkey)
    #expect(machine.handle(.dismiss) == .closed)
}

@Test("hotkey on the expanded panel closes it")
func hotkeyTogglesExpandedClosed() {
    var machine = NotchStateMachine()
    machine.handle(.hotkey)
    #expect(machine.handle(.hotkey) == .closed)
}

@Test("tab cycling wraps around")
func cycleTabWrapsAround() {
    var machine = NotchStateMachine()
    machine.handle(.hotkey)
    #expect(machine.handle(.cycleTab) == .expanded(.clipboard))
    #expect(machine.handle(.cycleTab) == .expanded(.notes))
    #expect(machine.handle(.cycleTab) == .expanded(.pins))
    #expect(machine.handle(.cycleTab) == .expanded(.music))
}

@Test("full screen closes the panel and suppresses events")
func fullScreenDisablesPanel() {
    var machine = NotchStateMachine()
    machine.handle(.hotkey)
    #expect(machine.handle(.fullScreenChanged(true)) == .closed)
    #expect(machine.handle(.hotkey) == nil)
    #expect(machine.handle(.cursorEnteredHotZone) == nil)
    #expect(machine.state == .closed)
}

@Test("exiting full screen restores event handling")
func leavingFullScreenReenablesPanel() {
    var machine = NotchStateMachine()
    machine.handle(.fullScreenChanged(true))
    machine.handle(.fullScreenChanged(false))
    #expect(machine.handle(.cursorEnteredHotZone) == .peek(.hover))
}

@Test("hotkey in peek expands to the last tab, unlike click")
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

@Test("a repeated event with no state change is not reported")
func idempotentEventsReturnNil() {
    var machine = NotchStateMachine()
    machine.handle(.cursorEnteredHotZone)
    #expect(machine.handle(.cursorEnteredHotZone) == nil)
}
