import Testing
@testable import ClipboardKit

@Test("первое изменение счётчика читается")
func firstChangeIsRead() {
    var poller = PasteboardPoller()
    #expect(poller.shouldRead(changeCount: 7, idleSeconds: 0))
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
    #expect(poller.shouldRead(changeCount: 8, idleSeconds: 0))
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
    #expect(poller.shouldRead(changeCount: 9, idleSeconds: 1))
}

@Test("интервал и порог неактивности совпадают со спекой")
func constantsMatchSpec() {
    #expect(PasteboardPoller.interval == 0.4)
    #expect(PasteboardPoller.idleThreshold == 60)
}
