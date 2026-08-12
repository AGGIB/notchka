import Testing
import Foundation
@testable import NotchCore

private let t0 = Date(timeIntervalSince1970: 1_000_000)
private func at(_ offset: TimeInterval) -> Date { t0.addingTimeInterval(offset) }

@Test("проезд мимо чёлки за 100 мс не открывает панель")
func briefPassByDoesNotTrigger() {
    var debouncer = HoverDebouncer()
    #expect(debouncer.cursorMoved(isInsideHotZone: true, at: at(0)) == nil)
    #expect(debouncer.cursorMoved(isInsideHotZone: false, at: at(0.100)) == nil)
    #expect(debouncer.tick(at: at(0.500)) == nil)
}

@Test("задержка 120 мс в зоне открывает панель")
func dwellTriggersEnter() {
    var debouncer = HoverDebouncer()
    debouncer.cursorMoved(isInsideHotZone: true, at: at(0))
    #expect(debouncer.tick(at: at(0.119)) == nil)
    #expect(debouncer.tick(at: at(0.120)) == .cursorEnteredHotZone)
}

@Test("после входа краткий выход не закрывает панель")
func briefExitDoesNotClose() {
    var debouncer = HoverDebouncer()
    debouncer.cursorMoved(isInsideHotZone: true, at: at(0))
    debouncer.tick(at: at(0.120))
    debouncer.cursorMoved(isInsideHotZone: false, at: at(0.200))
    #expect(debouncer.cursorMoved(isInsideHotZone: true, at: at(0.400)) == nil)
    #expect(debouncer.tick(at: at(1.000)) == nil)
}

@Test("выход дольше 250 мс закрывает панель")
func sustainedExitTriggersLeave() {
    var debouncer = HoverDebouncer()
    debouncer.cursorMoved(isInsideHotZone: true, at: at(0))
    debouncer.tick(at: at(0.120))
    debouncer.cursorMoved(isInsideHotZone: false, at: at(0.200))
    #expect(debouncer.tick(at: at(0.449)) == nil)
    #expect(debouncer.tick(at: at(0.450)) == .cursorLeftHotZone)
}

@Test("событие сообщается один раз")
func eventIsReportedOnce() {
    var debouncer = HoverDebouncer()
    debouncer.cursorMoved(isInsideHotZone: true, at: at(0))
    #expect(debouncer.tick(at: at(0.120)) == .cursorEnteredHotZone)
    #expect(debouncer.tick(at: at(0.500)) == nil)
}

@Test("ожидание перехода видно снаружи — по нему включается таймер")
func pendingTransitionIsObservable() {
    var debouncer = HoverDebouncer()
    #expect(debouncer.hasPendingTransition == false)
    debouncer.cursorMoved(isInsideHotZone: true, at: at(0))
    #expect(debouncer.hasPendingTransition == true)
    debouncer.tick(at: at(0.120))
    #expect(debouncer.hasPendingTransition == false)
}
