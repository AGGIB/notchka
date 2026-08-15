import Foundation
import os

/// Long-lived adapter `stream` process, plus one-off commands to it.
///
/// An actor, not a class: stdout reading happens in the background, and `send`
/// can come from the UI, so process state can't be touched from both sides at once.
public actor AdapterProcess {
    private let paths: AdapterPaths
    private let logger = Logger(subsystem: "kz.mobilefirst.notchka", category: "adapter")
    private var streamProcess: Process?

    public init(paths: AdapterPaths) {
        self.paths = paths
    }

    /// A stream of parsed lines. Finishes when the process dies —
    /// restarting is handled by the provider from Task 5, not this type.
    ///
    /// `Process` and `Pipe` are assembled here, BEFORE building the `AsyncStream`, not
    /// inside its closure. The closure that `AsyncStream.init` takes is
    /// typed as `@Sendable` — the compiler checks it against the declared
    /// type, not against the fact that this particular implementation calls it
    /// synchronously right here — so writing to mutable actor state
    /// (`streamProcess`) from inside it fails Swift 6's strict
    /// concurrency checking. The assignment is pulled out to a separate line after
    /// the stream has already been built: that's ordinary actor-isolated code,
    /// not the closure body.
    public func lines() -> AsyncStream<AdapterLine> {
        let process = Process()
        process.executableURL = paths.perl
        process.arguments = [paths.script.path, paths.framework.path, "stream"]

        let pipe = Pipe()
        process.standardOutput = pipe
        // We don't need the adapter's stderr, but there's no reason to dump it to the console either.
        process.standardError = FileHandle.nullDevice

        let stream = AsyncStream<AdapterLine> { continuation in
            // A buffer is needed because reads arrive in chunks, not lines:
            // a single line can arrive split across two callbacks.
            let buffer = LineBuffer()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                for line in buffer.take(handle.availableData) {
                    continuation.yield(AdapterLine.parse(line))
                }
            }

            process.terminationHandler = { _ in
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.finish()
            }

            do {
                try process.run()
            } catch {
                self.logger.error("failed to start adapter: \(error.localizedDescription, privacy: .public)")
                continuation.finish()
                return
            }

            continuation.onTermination = { _ in
                Task { await self.stop() }
            }
        }

        // If process.run() above failed, the process just stays
        // unstarted here — stop() won't break anything: process.isRunning
        // is false for it, and the guard there just exits without doing anything.
        streamProcess = process
        return stream
    }

    /// A one-off control command. A separate short-lived process —
    /// `stream` has no input channel for commands.
    ///
    /// We wait for completion via `terminationHandler`, not `process.waitUntilExit()`:
    /// the latter blocks the thread entirely, and that's the actor's executor
    /// thread — until `send` finishes, the actor can't serve anything else,
    /// including `stop()`. If at that moment the supervisor from Task 5 tears down
    /// the stream (app quit, restart), `stop()` would queue up behind the
    /// already-running `send` and lose the very sub-second budget for
    /// SIGINT that the adapter intercepts it for in the first place. `await` on
    /// the continuation is a suspension point, not a blocking one: the actor is
    /// free to serve other calls in the meantime.
    public func send(code: Int32) async throws {
        let process = Process()
        process.executableURL = paths.perl
        process.arguments = [paths.script.path, paths.framework.path, "send", String(code)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // Resolves exactly once: either from here after the process
            // finishes, or from the catch below if it couldn't even
            // start — in that case terminationHandler is never called by the system,
            // so there's no double resume.
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Stops the stream. SIGINT, not SIGKILL: a spike confirmed that
    /// the adapter intercepts it and exits cleanly in under a second.
    public func stop() {
        guard let process = streamProcess, process.isRunning else { return }
        process.interrupt()
        streamProcess = nil
    }

    /// A one-off resync: `get` prints the current state exactly
    /// once and exits on its own — like `stream`, it needs no
    /// separate input channel for commands either. It exists for a
    /// case that the stream simply can't ever observe: the system sometimes
    /// doesn't send an event when returning to the previous source after a brief
    /// interception (a notification sound playing over real music) — the stream
    /// stays alive but gets stuck on the interception's data forever, because
    /// there's simply nowhere for the event to come from. `get` at that moment,
    /// unlike the stream, returns whatever the system knows right now (confirmed
    /// manually on a live machine while diagnosing this defect).
    ///
    /// Unlike `send(code:)`, what's needed isn't a return code but stdout's
    /// contents: `get` prints a bare JSON object there — `NowPlayingPayload`
    /// without the `{"type":..,"diff":..,"payload":..}` envelope that
    /// `stream` lines are wrapped in (see `AdapterLine.parseSnapshot`, a parsing
    /// path separate from `AdapterLine.parse` precisely for this reason).
    ///
    /// stdout is read by the `readabilityHandler` as data arrives, not
    /// all at once via `readDataToEndOfFile()` after the process has already
    /// exited: `get` can return artwork — on a live machine while
    /// testing this method, 256062 bytes of already-decoded data came through,
    /// i.e. more than 300 KiB of base64 in the JSON itself — that easily
    /// overflows the pipe's default buffer (64 KiB). Without draining the pipe as
    /// data arrives, a deadlock is possible: the child process blocks on
    /// writing to a full pipe, and nothing wakes it up — the pipe isn't
    /// read until the process itself exits, and it won't exit until
    /// it finishes writing the very data that isn't being read.
    ///
    /// What signals the end of reading here is the pipe's EOF (empty
    /// `availableData`), not `terminationHandler` as with `send(code:)` above:
    /// `send` doesn't look at stdout at all, and the ordering between two
    /// independent GCD callbacks (process termination and pipe drain) is
    /// documented nowhere, whereas the pipe's EOF is guaranteed to arrive only
    /// after every byte written to it has already been read.
    public func get() async throws -> NowPlayingSnapshot? {
        let process = Process()
        process.executableURL = paths.perl
        process.arguments = [paths.script.path, paths.framework.path, "get"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        let buffer = OutputBuffer()
        let output: Data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else {
                    // Empty availableData means EOF: the pipe is closed, nothing
                    // can write to it anymore. We resolve right here, rather than waiting
                    // for a separate process-termination signal (see the method's
                    // doc above).
                    pipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(returning: buffer.snapshot())
                    return
                }
                buffer.append(chunk)
            }
            do {
                try process.run()
            } catch {
                // Same trick as in send(code:): run() failed — the pipe
                // itself is still empty, readabilityHandler never fired,
                // so there's no double resume.
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }

        guard let text = String(data: output, encoding: .utf8) else { return nil }
        return AdapterLine.parseSnapshot(text)
    }
}

/// A byte accumulator that yields complete lines.
///
/// A separate type because the `readabilityHandler` callback is invoked
/// on an arbitrary thread and can't own mutable actor state.
private final class LineBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func take(_ chunk: Data) -> [String] {
        guard !chunk.isEmpty else { return [] }
        lock.lock()
        defer { lock.unlock() }

        data.append(chunk)
        var lines: [String] = []
        while let newline = data.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = data[data.startIndex..<newline]
            data.removeSubrange(data.startIndex...newline)
            if let line = String(data: lineData, encoding: .utf8) { lines.append(line) }
        }
        return lines
    }
}

/// A byte accumulator for a one-off `get`.
///
/// Doesn't reuse `LineBuffer` above: that one needs a `\n` to yield a
/// line, whereas `get` prints a single JSON object and isn't obligated to
/// end it with a newline — if it didn't, LineBuffer would stay silent forever,
/// never yielding a single "line". This one accumulates everything up to EOF
/// as a whole, with no notion of lines at all; the same rationale for
/// `@unchecked Sendable` and locking applies as for LineBuffer — access comes
/// from readabilityHandler, invoked on an arbitrary GCD thread, not the
/// actor's executor thread.
private final class OutputBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
