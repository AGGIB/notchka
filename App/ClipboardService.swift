import AppKit
import ClipboardKit
import NotchStore
import CoreGraphics
import os

/// Clipboard-watching service.
///
/// Once per `PasteboardPoller.interval`, checks `changeCount` and user
/// idle time on the main thread — that's a cheap integer comparison and
/// one system call, so the timer lives right alongside the others on the
/// main thread instead of spinning up its own queue. If the poller decides
/// it's time to read, the `NSPasteboard` read itself also happens right
/// here, on the main thread (see `PasteboardReader`) — but everything after
/// that, starting with the privacy filter and going through reading the
/// file, hashing, writing the blob, and inserting into the database, moves
/// off the main thread: a copied megabyte-sized screenshot shouldn't hang
/// the panel.
///
/// What actually moves it off is `await` on a `nonisolated async` function,
/// not `Task(priority: .utility)` by itself: a task created inside a method
/// of this class inherits its MainActor, and executor priority doesn't
/// change that. A non-obvious subtlety — this branch has tripped over it
/// three times.
@MainActor
final class ClipboardService {
    private let repository: ClipboardRepository
    private let privacyFilter: PrivacyFilter
    private var poller = PasteboardPoller()

    private var pollTimer: Timer?
    private var pruneTimer: Timer?

    // nonisolated: without this the static logger would inherit the class's
    // MainActor isolation and would be unreachable from store()/prune()/
    // readFile() — all three run off the main thread (see their doc comments).
    // Logger is Sendable, the value is immutable, races are ruled out.
    nonisolated private static let logger = Logger(subsystem: "kz.mobilefirst.notchka", category: "ClipboardService")

    /// How often to prune the history while the app is running. Not on every
    /// entry: scanning the whole history on every ⌘C would be wasted work.
    /// The prune at launch happens separately, once, in start().
    private static let pruneInterval: TimeInterval = 24 * 3600

    init(repository: ClipboardRepository, privacyFilter: PrivacyFilter = PrivacyFilter()) {
        self.repository = repository
        self.privacyFilter = privacyFilter
    }

    /// Starts polling and pruning. Call once per service lifetime — the same
    /// idempotency approach as `MusicViewModel.start()`.
    func start() {
        guard pollTimer == nil else { return }
        pruneHistory()

        // The Timer is created manually and added to .common instead of via
        // scheduledTimer — same approach and same rationale as in
        // CursorMonitor.setTicking: in .default mode the timer doesn't tick while
        // tracking an open menu (RunLoop.Mode.eventTracking), and anything copied
        // during that time would be lost until the next click.
        let pollTimer = Timer(timeInterval: PasteboardPoller.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.current.add(pollTimer, forMode: .common)
        self.pollTimer = pollTimer

        let pruneTimer = Timer(timeInterval: Self.pruneInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pruneHistory() }
        }
        RunLoop.current.add(pruneTimer, forMode: .common)
        self.pruneTimer = pruneTimer
    }

    /// Stops both timers. Called explicitly on app quit — the same setup as
    /// `MusicViewModel.stopAdapter()`: the process exits via exit(), bypassing
    /// Swift stack unwinding (see AppDelegate.shutDown), so deinit can't be
    /// relied on.
    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        pruneTimer?.invalidate()
        pruneTimer = nil
    }

    deinit {
        // Same approach and same rationale as in CursorMonitor.deinit and
        // HotkeyCenter.deinit.
        MainActor.assumeIsolated { stop() }
    }

    /// Marks the current pasteboard content as our own.
    ///
    /// Called after the app itself puts something on the pasteboard — when
    /// the user pulls an entry out of history. Otherwise the poller would read
    /// its own entry back moments later (see `PasteboardPoller.ignore`).
    func ignoreOwnPasteboardWrite() {
        poller.ignore(changeCount: NSPasteboard.general.changeCount)
    }

    /// One polling tick. What stays on the main thread is exactly what has to:
    /// reading the pasteboard and resolving the source app's name — both are
    /// AppKit. Everything else moves into `store`.
    private func tick() {
        let changeCount = NSPasteboard.general.changeCount
        guard poller.shouldRead(changeCount: changeCount, idleSeconds: Self.idleSeconds()) else { return }
        guard let content = PasteboardReader.read() else { return }

        // The app name is resolved here, not in store: NSWorkspace and
        // FileManager.displayName are AppKit too, and calling them from another
        // thread would just trade one defect for another.
        let source = content.snapshot.sourceBundleID.map { bundleID in
            (bundleID: bundleID, appName: PasteboardReader.appName(for: bundleID) ?? bundleID)
        }

        let repository = repository
        let privacyFilter = privacyFilter
        Task(priority: .utility) {
            await Self.store(
                content: content, source: source,
                repository: repository, privacyFilter: privacyFilter
            )
        }
    }

    /// Privacy filter, file reading, hashing, blob writing, and database
    /// insertion — all off the main thread.
    ///
    /// `nonisolated` **and** `async` — both are required. `nonisolated` alone
    /// isn't enough: a `Task {}` created inside a method of an @MainActor
    /// class inherits its isolation, and a synchronous call from it stays on
    /// the main thread regardless. What actually moves off the actor is
    /// `await` on a function that isn't bound to it. This exact thing has
    /// already tripped up this same branch twice — in PasteboardReader and in
    /// ClipboardViewModel.writeTemporaryFile.
    ///
    /// Order matters: `shouldCapture` is checked first, and only on a
    /// positive answer does anything reach the repository — no branch below
    /// writes to the database before the filter.
    nonisolated private static func store(
        content: PasteboardReader.Content,
        source: (bundleID: String, appName: String)?,
        repository: ClipboardRepository,
        privacyFilter: PrivacyFilter
    ) async {
        guard privacyFilter.shouldCapture(content.snapshot) else { return }

        do {
            // Branch order matches PasteboardReader.read(): file before image, image
            // before text, for the same reason (a file may carry a text or image
            // representation, but it must be shown in history as a file).
            if let fileName = content.fileName, let fileURL = content.fileURL {
                // File bytes are read here, not in PasteboardReader.read():
                // that runs on the main thread, and a plain "copy a file" from a
                // network drive would stall the whole event loop along with
                // panel rendering. Here it happens after the filter — no I/O
                // is spent on rejected content at all.
                guard let fileData = try? await Self.readFile(at: fileURL) else {
                    // Between the poll and this moment the file may have been moved or
                    // deleted. Not cause for alarm, but not cause for silence either:
                    // otherwise a missing history entry would be unexplainable.
                    logger.notice(
                        "file \(fileName, privacy: .public) could not be read, not added to history"
                    )
                    return
                }
                try repository.saveFile(fileData, fileName: fileName, source: source)
            } else if let image = content.image {
                try repository.saveImage(image, source: source)
            } else if let text = content.text {
                try repository.saveText(text, source: source)
            }
        } catch {
            logger.error("failed to save clipboard content: \(error, privacy: .public)")
        }
    }

    /// File reading is a separate `async` function rather than an inline
    /// expression: inside an already-async `store`, a plain call would stay
    /// on its executor, but what's needed is to actually leave the caller's
    /// actor.
    nonisolated private static func readFile(at url: URL) async throws -> Data {
        try Data(contentsOf: url)
    }

    /// Trims the history down to `RetentionPolicy.default` limits. Also off
    /// the main thread: `prune` reads the whole table and, once a limit is
    /// hit, deletes entries one by one in separate transactions, along with
    /// their blob files on disk — not the kind of workload that belongs on
    /// the thread that draws the panel.
    private func pruneHistory() {
        let repository = repository
        Task(priority: .utility) {
            await Self.prune(repository: repository)
        }
    }

    /// `async` for the same reason as `store`: without it, pruning would run
    /// on the main thread, because the Task that spawned it inherited it.
    nonisolated private static func prune(repository: ClipboardRepository) async {
        do {
            try repository.prune(policy: .default)
        } catch {
            logger.error("clipboard history prune failed: \(error, privacy: .public)")
        }
    }

    /// User idle time in seconds.
    ///
    /// Not `.null` — that's the zero event, not "any", and doesn't reflect
    /// actual input. `kCGAnyInputEventType` has no named case in
    /// `CGEventType`, hence the raw value. Verified empirically (see the
    /// Task 6 report): on an active machine it stays under a second and
    /// doesn't grow while input is happening.
    private static func idleSeconds() -> TimeInterval {
        let anyInput = CGEventType(rawValue: ~0)!
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }
}
