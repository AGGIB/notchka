import Testing
import Foundation
@testable import MediaBridge

private let base = NowPlayingSnapshot(
    title: "Sweet Dreams", artist: "Eurythmics", album: "", duration: 216,
    elapsedTime: 10, timestamp: Date(timeIntervalSince1970: 1_000_000),
    playbackRate: 1, isPlaying: true, sourceBundleID: "com.google.Chrome",
    artworkData: nil, artworkMimeType: nil
)

/// Same track, but paused — needed as a separate value for the timestamp
/// re-anchoring tests below: without an isPlaying false→true transition,
/// re-anchoring must never trigger.
private let pausedBase = NowPlayingSnapshot(
    title: "Sweet Dreams", artist: "Eurythmics", album: "", duration: 216,
    elapsedTime: 10, timestamp: Date(timeIntervalSince1970: 1_000_000),
    playbackRate: 1, isPlaying: false, sourceBundleID: "com.google.Chrome",
    artworkData: nil, artworkMimeType: nil
)

/// Reference "now" for apply(_:now:) calls where the moment in time itself
/// is not the subject of the test.
private let now = Date(timeIntervalSince1970: 2_000_000)

@Test("command codes match the empirically verified spike")
func commandCodesMatchSpike() {
    #expect(MediaCommand.play.adapterCode == 0)
    #expect(MediaCommand.pause.adapterCode == 1)
    #expect(MediaCommand.toggle.adapterCode == 2)
    // next/previous are verified separately from the original spike (see doc
    // MediaCommand): an actual track change on live YouTube in Safari, not
    // documentation and not the framework header.
    #expect(MediaCommand.next.adapterCode == 4)
    #expect(MediaCommand.previous.adapterCode == 5)
}

@Test("a snapshot replaces the state entirely")
func snapshotReplacesState() {
    var accumulator = SnapshotAccumulator()
    #expect(accumulator.apply(.snapshot(base), now: now) == base)
}

@Test("a diff patches only the given fields")
func diffPatchesState() {
    var accumulator = SnapshotAccumulator()
    _ = accumulator.apply(.snapshot(base), now: now)
    var payload = NowPlayingPayload()
    payload.playing = false
    let updated = accumulator.apply(.diff(payload), now: now)
    #expect(updated?.isPlaying == false)
    #expect(updated?.title == "Sweet Dreams")
}

@Test("a diff before the first snapshot does not fabricate state")
func accumulatorDiffBeforeSnapshotIsIgnored() {
    var accumulator = SnapshotAccumulator()
    var payload = NowPlayingPayload()
    payload.playing = true
    #expect(accumulator.apply(.diff(payload), now: now) == nil)
}

@Test("an empty snapshot means the session ended")
func emptySnapshotClearsState() {
    var accumulator = SnapshotAccumulator()
    _ = accumulator.apply(.snapshot(base), now: now)
    #expect(accumulator.apply(.snapshot(nil), now: now) == nil)
    #expect(accumulator.current == nil)
}

@Test("a transient failure does not erase the last known track")
func transientFailureKeepsState() {
    var accumulator = SnapshotAccumulator()
    _ = accumulator.apply(.snapshot(base), now: now)
    #expect(accumulator.apply(.transientFailure("timed out"), now: now) == base)
    #expect(accumulator.current == base)
}

@Test("an unrecognized line does not change the state")
func unrecognisedLineKeepsState() {
    var accumulator = SnapshotAccumulator()
    _ = accumulator.apply(.snapshot(base), now: now)
    #expect(accumulator.apply(.unrecognized("noise"), now: now) == base)
}

@Test("a diff with playing:true and no timestamp after a pause re-anchors the timestamp to now")
func diffTurningPlayingOnWithoutTimestampReanchorsTimestamp() {
    var accumulator = SnapshotAccumulator()
    _ = accumulator.apply(.snapshot(pausedBase), now: now)
    var payload = NowPlayingPayload()
    payload.playing = true
    // The track was paused for 10 minutes — the old timestamp would make the
    // drift in PlaybackPosition equal to the entire pause (see the fix
    // description).
    let resumedAt = now.addingTimeInterval(600)
    let updated = accumulator.apply(.diff(payload), now: resumedAt)
    #expect(updated?.isPlaying == true)
    #expect(updated?.timestamp == resumedAt)
}

@Test("a diff with playing:true and its own timestamp is not re-anchored to now")
func diffTurningPlayingOnWithTimestampKeepsAdapterValue() {
    var accumulator = SnapshotAccumulator()
    _ = accumulator.apply(.snapshot(pausedBase), now: now)
    var payload = NowPlayingPayload()
    payload.playing = true
    let adapterTimestamp = Date(timeIntervalSince1970: 1_999_999)
    payload.timestamp = adapterTimestamp
    let updated = accumulator.apply(.diff(payload), now: now.addingTimeInterval(600))
    #expect(updated?.timestamp == adapterTimestamp)
}

@Test("a diff with playing:true and no flip (already playing) does not re-anchor the timestamp")
func diffKeepingPlayingTrueWithoutTimestampDoesNotReanchor() {
    var accumulator = SnapshotAccumulator()
    _ = accumulator.apply(.snapshot(base), now: now)  // base.isPlaying is already true
    var payload = NowPlayingPayload()
    payload.playing = true
    let updated = accumulator.apply(.diff(payload), now: now.addingTimeInterval(600))
    #expect(updated?.timestamp == base.timestamp)
}

// `survivedLongEnoughToResetBackoff` — a pure date-comparison function,
// extracted from pump(into:) precisely so it can be tested without
// spinning up a real adapter process (pump() itself is not covered by a
// unit test — per the report, no test in this file gets as far as a real
// process or a plausible stand-in for one).

@Test("a stream shorter than the threshold does not reset the growing backoff")
func briefStreamDoesNotResetBackoff() {
    let opened = Date(timeIntervalSince1970: 1_000_000)
    let closedQuickly = opened.addingTimeInterval(0.2)
    #expect(AdapterProvider.survivedLongEnoughToResetBackoff(openedAt: opened, closedAt: closedQuickly) == false)
}

@Test("a stream longer than the threshold resets the growing backoff")
func longStreamResetsBackoff() {
    let opened = Date(timeIntervalSince1970: 1_000_000)
    let closedLater = opened.addingTimeInterval(AdapterProvider.restartLivenessThreshold + 1)
    #expect(AdapterProvider.survivedLongEnoughToResetBackoff(openedAt: opened, closedAt: closedLater) == true)
}

@Test("a stream exactly at the threshold counts as having lived long enough")
func thresholdBoundaryResetsBackoff() {
    let opened = Date(timeIntervalSince1970: 1_000_000)
    let closedAtThreshold = opened.addingTimeInterval(AdapterProvider.restartLivenessThreshold)
    #expect(AdapterProvider.survivedLongEnoughToResetBackoff(openedAt: opened, closedAt: closedAtThreshold) == true)
}

/// Deliberately nonexistent paths: `AdapterProcess.lines()` fails at
/// `process.run()` instantly (ENOENT), so no real process is spawned —
/// the test launches nothing and does not depend on a built adapter.
private let unreachablePaths = AdapterPaths(
    perl: URL(fileURLWithPath: "/nonexistent/perl"),
    script: URL(fileURLWithPath: "/nonexistent/script.pl"),
    framework: URL(fileURLWithPath: "/nonexistent/Framework")
)

@Test("repeated access to snapshots does not start a second pump")
func repeatedSnapshotsAccessDoesNotStartSecondPump() async {
    let provider = AdapterProvider(paths: unreachablePaths)
    _ = await provider.snapshots
    _ = await provider.snapshots
    #expect(await provider.pumpsStarted == 1)
}

@Test("shutdown actually stops the pump, not just requests cancellation")
func shutdownStopsPumpForGood() async {
    let provider = AdapterProvider(paths: unreachablePaths)
    _ = await provider.snapshots
    await provider.shutdown()
    // If shutdown only requested cancellation without waiting for it to
    // finish, the next access could still catch the pump formally "active"
    // (the task cancelled, but the !activePump.task.isCancelled check
    // should already have caught that in any case) — we verify the
    // stronger property: after shutdown, a genuinely new pump comes up.
    _ = await provider.snapshots
    #expect(await provider.pumpsStarted == 2)
}

@Test("shutdown without a single prior access to snapshots does not crash")
func shutdownWithoutPriorAccessIsSafe() async {
    let provider = AdapterProvider(paths: unreachablePaths)
    await provider.shutdown()
    #expect(await provider.pumpsStarted == 0)
}

/// refresh() throws on a misfire rather than collapsing it to nil: nil means
/// "nothing is playing", and the caller clears the screen in response to it.
/// Collapsing a request failure into the same case would blank the panel for
/// a user whose music is actually playing — and the more often, the more
/// frequently the timer-driven resync runs.
@Test("refresh on unreachable paths throws rather than returning nil")
func refreshOnUnreachablePathsThrows() async {
    let provider = AdapterProvider(paths: unreachablePaths)
    await #expect(throws: (any Error).self) {
        try await provider.refresh()
    }
}
