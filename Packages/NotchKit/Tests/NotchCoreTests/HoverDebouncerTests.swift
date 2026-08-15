import Testing
import Foundation
@testable import NotchCore

private let t0 = Date(timeIntervalSince1970: 1_000_000)
private func at(_ offset: TimeInterval) -> Date { t0.addingTimeInterval(offset) }

@Test("a 100 ms pass-by over the notch does not open the panel")
func briefPassByDoesNotTrigger() {
    var debouncer = HoverDebouncer()
    #expect(debouncer.cursorMoved(isInsideHotZone: true, at: at(0)) == nil)
    #expect(debouncer.cursorMoved(isInsideHotZone: false, at: at(0.100)) == nil)
    #expect(debouncer.tick(at: at(0.500)) == nil)
}

@Test("a 120 ms dwell inside the zone opens the panel")
func dwellTriggersEnter() {
    var debouncer = HoverDebouncer()
    debouncer.cursorMoved(isInsideHotZone: true, at: at(0))
    #expect(debouncer.tick(at: at(0.119)) == nil)
    #expect(debouncer.tick(at: at(0.120)) == .cursorEnteredHotZone)
}

@Test("after entering, a brief exit does not close the panel")
func briefExitDoesNotClose() {
    var debouncer = HoverDebouncer()
    debouncer.cursorMoved(isInsideHotZone: true, at: at(0))
    debouncer.tick(at: at(0.120))
    debouncer.cursorMoved(isInsideHotZone: false, at: at(0.200))
    #expect(debouncer.cursorMoved(isInsideHotZone: true, at: at(0.400)) == nil)
    #expect(debouncer.tick(at: at(1.000)) == nil)
}

@Test("an exit longer than 250 ms closes the panel")
func sustainedExitTriggersLeave() {
    var debouncer = HoverDebouncer()
    debouncer.cursorMoved(isInsideHotZone: true, at: at(0))
    debouncer.tick(at: at(0.120))
    debouncer.cursorMoved(isInsideHotZone: false, at: at(0.200))
    #expect(debouncer.tick(at: at(0.449)) == nil)
    #expect(debouncer.tick(at: at(0.450)) == .cursorLeftHotZone)
}

@Test("the event is reported only once")
func eventIsReportedOnce() {
    var debouncer = HoverDebouncer()
    debouncer.cursorMoved(isInsideHotZone: true, at: at(0))
    #expect(debouncer.tick(at: at(0.120)) == .cursorEnteredHotZone)
    #expect(debouncer.tick(at: at(0.500)) == nil)
}

@Test("the pending transition is observable from outside — it drives the timer")
func pendingTransitionIsObservable() {
    var debouncer = HoverDebouncer()
    #expect(debouncer.hasPendingTransition == false)
    debouncer.cursorMoved(isInsideHotZone: true, at: at(0))
    #expect(debouncer.hasPendingTransition == true)
    debouncer.tick(at: at(0.120))
    #expect(debouncer.hasPendingTransition == false)
}
