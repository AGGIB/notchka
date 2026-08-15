import Foundation

/// Source of information about current playback.
///
/// The protocol exists for the risk the spec calls the main one: MediaRemote
/// is gated behind a private entitlement, and if the perl workaround stops
/// working, a second implementation can be written as a browser extension
/// without changing the UI.
public protocol NowPlayingProvider: Sendable {
    /// nil in the stream means "nothing is playing right now".
    ///
    /// How many consumers the stream can serve concurrently, honestly and
    /// without dropping events, is up to the implementation; check its
    /// documentation (`AdapterProvider` is designed for exactly one).
    var snapshots: AsyncStream<NowPlayingSnapshot?> { get async }
    func send(_ command: MediaCommand) async throws

    /// A one-off resync that bypasses the stream and its accumulator — a
    /// snapshot of what the source knows right now.
    ///
    /// Exists for a defect that is fundamentally invisible through the
    /// stream: the system sometimes never sends an event about returning to
    /// the previous source after a brief interception (a notification sound
    /// playing over real music) — the stream stays alive but gets stuck on
    /// the interception's data forever, because the event simply never
    /// arrives. Parsing what has already come through the stream doesn't
    /// fix this: there's nothing there to parse. `refresh()` is the
    /// caller's (MusicViewModel) only way to get the current state in this
    /// situation.
    ///
    /// Deliberately has no default implementation: a silent no-op that
    /// always returns nil would look like a working resync for the second
    /// protocol implementation (browser extension, see doc above), while
    /// actually having no effect — and the difference would only surface on
    /// a live machine, the same way the defect itself was found.
    ///
    /// nil means the same thing as nil in `snapshots` — "nothing is
    /// playing right now". A failure of the request itself (the adapter
    /// didn't launch, etc.) must be thrown by the implementation, not
    /// collapsed into nil: these two outcomes require opposite handling
    /// from the caller. On "nothing is playing" the screen should be
    /// cleared; on a misfire, the last known track should stay until the
    /// next attempt. Collapsed into one value, they'd cause flicker: resync
    /// runs on a timer, and every misfire would blank the panel for a user
    /// who actually has something playing.
    func refresh() async throws -> NowPlayingSnapshot?

    /// Stops the pipeline and guarantees it waits for completion — the
    /// caller (see AppDelegate) relies on no external process still running
    /// after this returns. Needed separately from a simple "cancel and
    /// forget": relying on deinit at app termination doesn't work — AppKit
    /// ends the process via exit(), bypassing Swift stack unwinding and
    /// deinitializers.
    func shutdown() async
}

/// Folds the adapter's stream into the current state.
///
/// Kept separate from the process, because all the "what to do with a
/// line" logic lives here, and it needs to be testable without running
/// perl.
public struct SnapshotAccumulator: Sendable {
    public private(set) var current: NowPlayingSnapshot?

    public init() {}

    /// Returns the state after applying a line.
    ///
    /// `now` is an injected clock, not `Date()` inside the method: this
    /// type is tested without running perl (see doc above), and a clock
    /// baked in would rule that out. The only consumer of the value is
    /// `NowPlayingPayload.applied(to:now:)`, where `now` matters only on an
    /// isPlaying false→true transition when the diff has no timestamp of
    /// its own (see its doc comment); for snapshots and misfires the
    /// parameter has no effect.
    @discardableResult
    public mutating func apply(_ line: AdapterLine, now: Date) -> NowPlayingSnapshot? {
        switch line {
        case .snapshot(let snapshot):
            current = snapshot
        case .diff(let payload):
            // A diff before the first snapshot describes a change to
            // something unknown — a track can't be invented from it.
            current = payload.applied(to: current, now: now)
        case .transientFailure, .unrecognized:
            // The channel is alive, this particular line is useless. The
            // last known track stays on screen: clearing it would be a lie
            // in the other direction.
            break
        }
        return current
    }
}
