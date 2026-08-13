import Testing
@testable import ClipboardKit

// Положительные ожидания записаны как `== true`, а не голым вызовом.
// Это не многословие ради многословия: `#expect` разворачивается в
// замыкание, где получатель вызова неизменяем, а `shouldRead` — mutating,
// и голая форма просто не компилируется. Сравнение выводит вызов из-под
// этого разворачивания. Не «упрощать» обратно — сборка сломается.

@Test("первое изменение счётчика читается")
func firstChangeIsRead() {
    var poller = PasteboardPoller()
    #expect(poller.shouldRead(changeCount: 7, idleSeconds: 0) == true)
}

@Test("тот же счётчик второй раз не читается")
func sameCountIsSkipped() {
    var poller = PasteboardPoller()
    _ = poller.shouldRead(changeCount: 7, idleSeconds: 0)
    #expect(poller.shouldRead(changeCount: 7, idleSeconds: 0) == false)
}

@Test("новое изменение читается")
func newChangeIsRead() {
    var poller = PasteboardPoller()
    _ = poller.shouldRead(changeCount: 7, idleSeconds: 0)
    #expect(poller.shouldRead(changeCount: 8, idleSeconds: 0) == true)
}

@Test("при долгой неактивности не читаем — копировать некому")
func idleUserIsNotPolled() {
    var poller = PasteboardPoller()
    #expect(poller.shouldRead(changeCount: 9, idleSeconds: 120) == false)
}

@Test("вернувшийся пользователь снова читается, и пропущенное подхватывается")
func returningUserIsReadAgain() {
    var poller = PasteboardPoller()
    _ = poller.shouldRead(changeCount: 9, idleSeconds: 120)
    #expect(poller.shouldRead(changeCount: 9, idleSeconds: 1) == true)
}

@Test("помеченное своим изменение не читается")
func ownChangeIsIgnored() {
    var poller = PasteboardPoller()
    poller.ignore(changeCount: 42)
    #expect(poller.shouldRead(changeCount: 42, idleSeconds: 0) == false)
    // Следующее, уже чужое, читается как обычно.
    #expect(poller.shouldRead(changeCount: 43, idleSeconds: 0) == true)
}

@Test("интервал и порог неактивности совпадают со спекой")
func constantsMatchSpec() {
    #expect(PasteboardPoller.interval == 0.4)
    #expect(PasteboardPoller.idleThreshold == 60)
}
