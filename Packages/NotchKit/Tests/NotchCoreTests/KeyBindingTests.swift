import Testing
@testable import NotchCore

@Test("digits with command select tabs in order")
func digitsSelectTabs() {
    #expect(KeyBinding.event(forKeyCode: .digit1, modifiers: [.command]) == .selectTab(.music))
    #expect(KeyBinding.event(forKeyCode: .digit2, modifiers: [.command]) == .selectTab(.clipboard))
    #expect(KeyBinding.event(forKeyCode: .digit3, modifiers: [.command]) == .selectTab(.notes))
    #expect(KeyBinding.event(forKeyCode: .digit4, modifiers: [.command]) == .selectTab(.pins))
}

@Test("digits without command don't switch tabs — that's search input")
func digitsWithoutCommandAreNotBindings() {
    #expect(KeyBinding.event(forKeyCode: .digit1, modifiers: []) == nil)
}

@Test("tab cycles through tabs")
func tabCycles() {
    #expect(KeyBinding.event(forKeyCode: .tab, modifiers: []) == .cycleTab)
}

@Test("escape dismisses the panel")
func escapeDismisses() {
    #expect(KeyBinding.event(forKeyCode: .escape, modifiers: []) == .dismiss)
}

@Test("unknown key produces no event")
func unknownKeyIsIgnored() {
    #expect(KeyBinding.event(forKeyCode: .other(99), modifiers: []) == nil)
}
