import Testing
import Foundation
@testable import MediaBridge

/// Real payload from the spike, artwork truncated.
private let fullPayloadLine = """
{"type":"data","diff":false,"payload":{"playbackRate":1,"album":"","elapsedTime":200.349576,\
"timestamp":"2026-08-10T11:35:25Z","bundleIdentifier":"com.google.Chrome",\
"processIdentifier":59148,"artworkData":"/9j/4AAQSkZJRg==","title":"Deep Work Music",\
"artworkMimeType":"image/jpeg","duration":7279.961,"artist":"Deep Idle Room",\
"contentItemIdentifier":"F06E3460-AF16-445A-AF1E-2600F5CA2D5E","playing":true}}
"""

@Test("a full snapshot parses with all fields")
func fullSnapshotParses() throws {
    guard case .snapshot(let snapshot?) = AdapterLine.parse(fullPayloadLine) else {
        Issue.record("expected a snapshot")
        return
    }
    #expect(snapshot.title == "Deep Work Music")
    #expect(snapshot.artist == "Deep Idle Room")
    #expect(snapshot.sourceBundleID == "com.google.Chrome")
    #expect(snapshot.isPlaying == true)
    #expect(snapshot.playbackRate == 1)
    #expect(abs(snapshot.duration - 7279.961) < 0.001)
    #expect(abs(snapshot.elapsedTime - 200.349576) < 0.001)
    #expect(snapshot.artworkData != nil)
    // Chrome reports itself directly in this payload — the adapter sends no
    // parent, and that should stay nil, not turn into an empty string.
    #expect(snapshot.parentApplicationBundleID == nil)
}

/// Safari helper-process payload — an empirical finding from Task 4:
/// `bundleIdentifier` points at the WebKit rendering process, and the real
/// app arrives in a separate `parentApplicationBundleIdentifier` field.
private let safariPayloadLine = """
{"type":"data","diff":false,"payload":{"bundleIdentifier":"com.apple.WebKit.GPU",\
"parentApplicationBundleIdentifier":"com.apple.Safari","title":"Track",\
"artist":"Artist","album":"","duration":200,"elapsedTime":0,\
"timestamp":"2026-08-10T11:35:25Z","playbackRate":1,"playing":true}}
"""

@Test("a helper process carries the parent's bundle id in a separate field")
func helperProcessCarriesParentBundleID() throws {
    guard case .snapshot(let snapshot?) = AdapterLine.parse(safariPayloadLine) else {
        Issue.record("expected a snapshot")
        return
    }
    #expect(snapshot.sourceBundleID == "com.apple.WebKit.GPU")
    #expect(snapshot.parentApplicationBundleID == "com.apple.Safari")
}

@Test("the stream's opening housekeeping line means \"nothing playing\"")
func emptySnapshotMeansNoSession() {
    guard case .snapshot(let snapshot) = AdapterLine.parse(#"{"type":"data","diff":false,"payload":{}}"#) else {
        Issue.record("expected a snapshot")
        return
    }
    #expect(snapshot == nil)
}

@Test("a diff parses as a partial payload")
func diffParsesAsPartial() throws {
    guard case .diff(let payload) = AdapterLine.parse(#"{"type":"data","diff":true,"payload":{"playing":true}}"#) else {
        Issue.record("expected a diff")
        return
    }
    #expect(payload.playing == true)
    #expect(payload.title == nil)
}

/// Reference "now" instant for the `applied(to:now:)` tests. The value
/// itself doesn't matter — what matters is that it's fixed and distinct
/// from the timestamps in the snapshots below, so the re-anchoring test
/// can't accidentally collide with an existing timestamp.
private let now = Date(timeIntervalSince1970: 1_700_000_000)

@Test("a diff merges onto a snapshot without clobbering unset fields")
func diffMergesWithoutClobbering() throws {
    guard case .snapshot(let base?) = AdapterLine.parse(fullPayloadLine),
          case .diff(let payload) = AdapterLine.parse(#"{"type":"data","diff":true,"payload":{"playing":false}}"#)
    else {
        Issue.record("setup failed")
        return
    }
    let merged = try #require(payload.applied(to: base, now: now))
    #expect(merged.isPlaying == false)
    #expect(merged.title == "Deep Work Music")
    #expect(merged.sourceBundleID == "com.google.Chrome")
}

@Test("a playing:true diff without a timestamp re-anchors the timestamp to now after a pause")
func diffReanchorsTimestampOnFalseToTrueWithoutTimestamp() throws {
    guard case .snapshot(let playingBase?) = AdapterLine.parse(fullPayloadLine),
          case .diff(let payload) = AdapterLine.parse(#"{"type":"data","diff":true,"payload":{"playing":true}}"#)
    else {
        Issue.record("setup failed")
        return
    }
    // fullPayloadLine carries playing:true — the false→true transition
    // needs a paused snapshot to start from.
    var paused = playingBase
    paused.isPlaying = false
    let merged = try #require(payload.applied(to: paused, now: now))
    #expect(merged.isPlaying == true)
    #expect(merged.timestamp == now)
}

@Test("a playing:true diff with its own timestamp is not re-anchored to now")
func diffKeepsAdapterTimestampWhenPresent() throws {
    guard case .snapshot(let playingBase?) = AdapterLine.parse(fullPayloadLine) else {
        Issue.record("setup failed")
        return
    }
    var paused = playingBase
    paused.isPlaying = false
    let adapterTimestamp = Date(timeIntervalSince1970: 1_650_000_000)
    guard case .diff(let payload) = AdapterLine.parse(
        #"{"type":"data","diff":true,"payload":{"playing":true,"timestamp":"2022-04-15T05:20:00Z"}}"#
    ) else {
        Issue.record("setup failed")
        return
    }
    let merged = try #require(payload.applied(to: paused, now: now))
    #expect(merged.timestamp == adapterTimestamp)
    #expect(merged.timestamp != now)
}

@Test("timeout text is recognized as a transient failure, not garbage")
func timeoutTextIsTransient() {
    let line = "Reading now playing information timed out after 2000 milliseconds"
    guard case .transientFailure(let text) = AdapterLine.parse(line) else {
        Issue.record("expected a transient failure")
        return
    }
    #expect(text.contains("timed out"))
}

@Test("an unparsable line doesn't crash parsing")
func garbageIsUnrecognised() {
    guard case .unrecognized = AdapterLine.parse("{not json") else {
        Issue.record("expected an unrecognized line")
        return
    }
}

@Test("a blank line doesn't count as an event")
func blankLineIsUnrecognised() {
    guard case .unrecognized = AdapterLine.parse("   ") else {
        Issue.record("expected an unrecognized line")
        return
    }
}

@Test("a diff before the first snapshot yields no state")
func diffBeforeSnapshotIsIgnored() {
    guard case .diff(let payload) = AdapterLine.parse(#"{"type":"data","diff":true,"payload":{"playing":true}}"#) else {
        Issue.record("expected a diff")
        return
    }
    let result = payload.applied(to: nil, now: now)
    #expect(result == nil)
}

@Test("valid JSON containing \"timed out\" parses as a snapshot, not a failure")
func jsonWithTimeoutInDataIsNotTransientFailure() {
    let lineWithTimeoutInTitle = """
    {"type":"data","diff":false,"payload":{"title":"Reading timed out","artist":"Test","album":"","duration":0,"elapsedTime":0,"timestamp":"2026-08-10T11:35:25Z","bundleIdentifier":"test","playing":false}}
    """
    guard case .snapshot(let snapshot?) = AdapterLine.parse(lineWithTimeoutInTitle) else {
        Issue.record("expected a snapshot")
        return
    }
    #expect(snapshot.title == "Reading timed out")
}

// MARK: - parseSnapshot (bare `get` command payload, no envelope)

/// Verbatim output of `get`, captured manually from a live system while
/// diagnosing the "panel gets stuck forever on a brief interception's
/// source" defect — not made up. Unlike the `stream` lines above, this is
/// a bare `NowPlayingPayload`: `get` prints it as-is, with no
/// `{"type":..,"diff":..,"payload":..}` envelope.
private let getCommandPayloadLine =
    #"{"playbackRate":1,"album":"","elapsedTime":67.62,"timestamp":"2026-08-13T10:08:31Z","bundleIdentifier":"com.apple.WebKit.GPU","processIdentifier":63903,"parentApplicationBundleIdentifier":"com.apple.Safari","title":"Sam Smith - I'm Not The Only One (Lyrics)","uniqueIdentifier":6671484,"duration":237.561,"artist":"Dan Music","contentItemIdentifier":"6671484","playing":true}"#

@Test("a get command payload parses into a snapshot with the right title, artist, duration, and playing flag")
func getCommandPayloadParsesAsSnapshot() throws {
    let snapshot = try #require(AdapterLine.parseSnapshot(getCommandPayloadLine))
    #expect(snapshot.title == "Sam Smith - I'm Not The Only One (Lyrics)")
    #expect(snapshot.artist == "Dan Music")
    #expect(abs(snapshot.duration - 237.561) < 0.001)
    #expect(snapshot.isPlaying == true)
    // Bonus beyond the required fields: this payload is the same Safari
    // case (see helperProcessCarriesParentBundleID above) — useful to
    // confirm parseSnapshot carries the same source distinction as the
    // regular parse.
    #expect(snapshot.sourceBundleID == "com.apple.WebKit.GPU")
    #expect(snapshot.parentApplicationBundleID == "com.apple.Safari")
    #expect(abs(snapshot.elapsedTime - 67.62) < 0.001)
}

@Test("a bare get payload is not recognized by the old parse — it needs an envelope")
func bareGetPayloadIsUnrecognizedByEnvelopeParse() {
    // Regression on exactly the warning from the task brief: parse(_:)
    // parses stream lines and requires an envelope; the get format must
    // not silently turn into a snapshot or a diff through it.
    guard case .unrecognized = AdapterLine.parse(getCommandPayloadLine) else {
        Issue.record("a bare get payload must not pass through parse(_:) as a snapshot or diff")
        return
    }
}

@Test("parseSnapshot doesn't mistake a stream envelope for a bare payload")
func parseSnapshotIgnoresEnvelopedLine() {
    // The flip side of the test above: a stream envelope is also valid
    // JSON, but its fields live inside a nested "payload", not at the top
    // level. parseSnapshot looks for title/artist/... at the top level and
    // must not invent a track from the nested object — it should just find
    // no fields and return nil (isEmpty), not crash or assemble garbage.
    #expect(AdapterLine.parseSnapshot(fullPayloadLine) == nil)
}

@Test("parseSnapshot doesn't crash on garbage")
func parseSnapshotHandlesGarbage() {
    #expect(AdapterLine.parseSnapshot("{not json") == nil)
    #expect(AdapterLine.parseSnapshot("   ") == nil)
}
