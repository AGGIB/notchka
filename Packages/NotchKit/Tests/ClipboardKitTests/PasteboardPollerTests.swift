import Testing
@testable import ClipboardKit

// Positive expectations are written as `== true` rather than as a bare call.
// This isn't verbosity for its own sake: `#expect` expands into a
// closure where the call's receiver is immutable, but `shouldRead` is
// mutating, so the bare form simply doesn't compile. The comparison moves
// the call out from under that expansion. Don't "simplify" this back —
// the build will break.

@Test("first change count is read")
func firstChangeIsRead() {
    var poller = PasteboardPoller()
    #expect(poller.shouldRead(changeCount: 7, idleSeconds: 0) == true)
}

@Test("the same count is not read a second time")
func sameCountIsSkipped() {
    var poller = PasteboardPoller()
    _ = poller.shouldRead(changeCount: 7, idleSeconds: 0)
    #expect(poller.shouldRead(changeCount: 7, idleSeconds: 0) == false)
}

@Test("a new change is read")
func newChangeIsRead() {
    var poller = PasteboardPoller()
    _ = poller.shouldRead(changeCount: 7, idleSeconds: 0)
    #expect(poller.shouldRead(changeCount: 8, idleSeconds: 0) == true)
}

@Test("not read after a long idle period — no one around to copy")
func idleUserIsNotPolled() {
    var poller = PasteboardPoller()
    #expect(poller.shouldRead(changeCount: 9, idleSeconds: 120) == false)
}

@Test("a returning user is read again, and the missed change is picked up")
func returningUserIsReadAgain() {
    var poller = PasteboardPoller()
    _ = poller.shouldRead(changeCount: 9, idleSeconds: 120)
    #expect(poller.shouldRead(changeCount: 9, idleSeconds: 1) == true)
}

@Test("a change marked as our own is not read")
func ownChangeIsIgnored() {
    var poller = PasteboardPoller()
    poller.ignore(changeCount: 42)
    #expect(poller.shouldRead(changeCount: 42, idleSeconds: 0) == false)
    // The next one, no longer ours, is read as usual.
    #expect(poller.shouldRead(changeCount: 43, idleSeconds: 0) == true)
}

@Test("interval and idle threshold match the spec")
func constantsMatchSpec() {
    #expect(PasteboardPoller.interval == 0.4)
    #expect(PasteboardPoller.idleThreshold == 60)
}
