import Foundation
import os

/// Provider on top of the perl adapter: keeps the stream alive and stitches lines together.
///
/// The pump is per-actor — never more than one at a time: `snapshots` caches
/// an already-started stream and its task in `activePump` and returns the
/// same ones on repeat access, instead of spinning up a second adapter
/// process on top of the first (details are on `snapshots` itself).
public actor AdapterProvider: NowPlayingProvider {
    private let paths: AdapterPaths
    private let logger = Logger(subsystem: "kz.mobilefirst.notchka", category: "media")
    private var process: AdapterProcess?

    /// The currently running pump: the stream for consumers and the task
    /// that feeds it. A single field guarantees there is never more than
    /// one pump at a time; only `startPump()` writes it.
    private var activePump: (stream: AsyncStream<NowPlayingSnapshot?>, task: Task<Void, Never>)?

    /// How many times the actor has started a new pump over its lifetime.
    ///
    /// Exists only for tests. `AsyncStream` and `Task` have no public way to
    /// compare two values for identity, so the property "repeat access to
    /// `snapshots` didn't start a second pump" can't be verified by
    /// equality of the returned values — this counter substitutes for that
    /// check without running perl.
    private(set) var pumpsStarted = 0

    /// How long the stream has to survive for the adapter to be considered
    /// working, rather than dying right after connecting.
    ///
    /// A spike measured this: the first line after connecting is always the
    /// housekeeping `{"diff":false,"payload":{}}`, and it takes "hundreds of
    /// milliseconds", not whole seconds, before diff lines start showing up
    /// in the stream. 5 seconds gives a comfortable margin above that noise
    /// (process startup, first line, a couple of exchanges), while staying
    /// well below the first genuinely significant escalation pause, so a
    /// genuinely alive but slow adapter isn't penalized the same as one
    /// that dies right after the housekeeping line.
    static let restartLivenessThreshold: TimeInterval = 5

    /// A pure "lived long enough" check, factored out of `pump(into:)`
    /// into its own function specifically for unit testing: `pump` itself
    /// drives a real adapter process and can't be exercised in isolation
    /// without perl, whereas this check is just an ordinary date
    /// comparison.
    static func survivedLongEnoughToResetBackoff(openedAt: Date, closedAt: Date) -> Bool {
        closedAt.timeIntervalSince(openedAt) >= Self.restartLivenessThreshold
    }

    public init(paths: AdapterPaths) {
        self.paths = paths
    }

    /// Stream of snapshots.
    ///
    /// Contract: NOT multicast. `AsyncStream` does not fan out elements to
    /// multiple consumers — if two consumers attach to an already-running
    /// stream via `for await`, each snapshot goes to exactly one of them,
    /// not to both. Designed for a single consumer at a time, matching the
    /// current plan overall; this type doesn't implement real broadcast
    /// and isn't meant to.
    ///
    /// Repeat access while the pump is alive returns the already-running
    /// stream instead of starting a second one. The pump stops being
    /// considered alive the moment its task is cancelled (the only way for
    /// it to finish, see `pump`) — at that point access starts a fresh,
    /// working one instead of returning a dead one.
    public var snapshots: AsyncStream<NowPlayingSnapshot?> {
        get async {
            if let activePump, !activePump.task.isCancelled {
                return activePump.stream
            }
            return startPump()
        }
    }

    public func send(_ command: MediaCommand) async throws {
        let adapter = process ?? AdapterProcess(paths: paths)
        process = adapter
        try await adapter.send(code: command.adapterCode)
    }

    /// One-off resync via `get` — see the protocol doc for why it's
    /// needed at all.
    ///
    /// Reuses the same `process` as `send(_:)` above rather than a separate
    /// field: the `AdapterProcess` held in this field is just a convenient
    /// holder for short-lived commands (`send`/`get` never touch
    /// `streamProcess` themselves — that one belongs to the pump in
    /// `pump(into:)`), so there's no reason to spin up a second instance
    /// for the same purpose.
    ///
    /// The `pump(into:)` accumulator (`SnapshotAccumulator`) is neither
    /// consulted nor updated here: it's local to the body of `pump(into:)`
    /// and exists to merge diffs on top of the stream's last snapshot —
    /// `get` already returns full state, so there's nothing to merge. This
    /// is asymmetric with respect to the stream (the next diff from the
    /// stream, if one ever arrives, will land on top of the accumulator's
    /// stale base rather than on top of what this refresh returned), but
    /// fixing that is out of scope here: the underlying defect is that
    /// there's no mechanism to intercept the diff sequence.
    public func refresh() async throws -> NowPlayingSnapshot? {
        let adapter = process ?? AdapterProcess(paths: paths)
        process = adapter
        do {
            return try await adapter.get()
        } catch {
            // Log and rethrow, rather than swallowing into nil: nil would
            // mean "nothing is playing", and the panel would clear for a
            // user who actually has music playing.
            logger.error("failed to perform get resync: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Immediately and reliably stops the pump: not just requesting
    /// cancellation, but waiting until pump(into:) actually runs to
    /// completion (its own tail already sends SIGINT to the adapter via
    /// process?.stop() and closes the continuation — see pump(into:)
    /// below). Lazy cancellation propagation through AsyncStream (as
    /// happens on ordinary disconnection of the last consumer) isn't
    /// enough here: that path gives the CALLER no guarantee that the
    /// process has already stopped by the time it returns, and that
    /// guarantee is exactly what's needed before the app quits.
    public func shutdown() async {
        guard let activePump else { return }
        activePump.task.cancel()
        await activePump.task.value
    }

    /// Starts a new pump and stores it in `activePump`.
    ///
    /// `AsyncStream.makeStream`, not `AsyncStream.init(_:)` with a closure:
    /// `activePump` needs to hold the `Task` itself, not just the stream,
    /// and the `Task` is only created after the `continuation` has been
    /// obtained. `makeStream` hands back `continuation` as an ordinary
    /// value synchronously, with no closure involved — all the code below
    /// is linear and never raises the question of what can and can't be
    /// written from inside an `AsyncStream.init` body (cf. the comment
    /// about the `@Sendable` closure in `AdapterProcess.lines()`).
    private func startPump() -> AsyncStream<NowPlayingSnapshot?> {
        let (stream, continuation) = AsyncStream.makeStream(of: NowPlayingSnapshot?.self)
        let task = Task { await self.pump(into: continuation) }
        continuation.onTermination = { _ in task.cancel() }
        activePump = (stream, task)
        pumpsStarted += 1
        return stream
    }

    /// Starts the stream, stitches lines together, and restarts it on
    /// disconnect.
    ///
    /// A new `AdapterProcess` is created for each attempt rather than
    /// reused: the actor has a single field for the current process with
    /// no generation token, and its cleanup on stream disconnect runs on a
    /// separate detached `Task` (see `AdapterProcess.lines()`). Calling
    /// `lines()` again on the same instance would risk delayed cleanup
    /// from the previous stream tearing down the one just started.
    private func pump(into continuation: AsyncStream<NowPlayingSnapshot?>.Continuation) async {
        var policy = RestartPolicy()
        var accumulator = SnapshotAccumulator()

        while !Task.isCancelled {
            let adapter = AdapterProcess(paths: paths)
            process = adapter
            let openedAt = Date()

            for await line in await adapter.lines() {
                continuation.yield(accumulator.apply(line, now: Date()))
            }

            guard !Task.isCancelled else { break }

            // Liveness is measured by the stream's lifetime, not by whether
            // any line arrived at all: the spike established that the
            // first line after connecting is always the housekeeping
            // {"diff":false,"payload":{}}, even if the adapter dies right
            // after it. Judging by any line arriving would reset the delay
            // on every attempt for an adapter that has died for good —
            // exactly the case the growing backoff exists for; it would
            // stay stuck at the bottom step forever instead of climbing to
            // the ceiling.
            if Self.survivedLongEnoughToResetBackoff(openedAt: openedAt, closedAt: Date()) {
                policy.reset()
            }
            let delay = policy.nextDelay()
            logger.notice("adapter stream disconnected, retrying in \(delay, privacy: .public) s")
            try? await Task.sleep(for: .seconds(delay))
        }

        await process?.stop()
        continuation.finish()
    }
}
