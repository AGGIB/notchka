import Testing
@testable import NotchCore

@Test("цифры с командой выбирают вкладки по порядку")
func digitsSelectTabs() {
    #expect(KeyBinding.event(forKeyCode: .digit1, modifiers: [.command]) == .selectTab(.music))
    #expect(KeyBinding.event(forKeyCode: .digit2, modifiers: [.command]) == .selectTab(.clipboard))
    #expect(KeyBinding.event(forKeyCode: .digit3, modifiers: [.command]) == .selectTab(.notes))
    #expect(KeyBinding.event(forKeyCode: .digit4, modifiers: [.command]) == .selectTab(.pins))
}

@Test("цифры без команды вкладки не переключают — это ввод в поиск")
func digitsWithoutCommandAreNotBindings() {
    #expect(KeyBinding.event(forKeyCode: .digit1, modifiers: []) == nil)
}

@Test("таб листает вкладки по кругу")
func tabCycles() {
    #expect(KeyBinding.event(forKeyCode: .tab, modifiers: []) == .cycleTab)
}

@Test("escape закрывает панель")
func escapeDismisses() {
    #expect(KeyBinding.event(forKeyCode: .escape, modifiers: []) == .dismiss)
}

@Test("неизвестная клавиша не даёт события")
func unknownKeyIsIgnored() {
    #expect(KeyBinding.event(forKeyCode: .other(99), modifiers: []) == nil)
}
