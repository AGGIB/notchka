import AppKit
import SwiftUI
import NotchCore
import NotchUI
import MediaBridge
import NotchStore
import ClipboardKit
import StashKit
import Dispatch
import CoreGraphics
import os

@MainActor
@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NotchPanel?
    private var controller: NotchController?
    /// Subscription token for screen configuration changes — stored so the
    /// subscription can be removed in deinit.
    private var screenParametersObserver: NSObjectProtocol?
    /// Subscription token for active Space changes — removed in deinit the
    /// same way as screenParametersObserver. Foundation debt: the state
    /// machine has handled .fullScreenChanged since plan 1, but before this
    /// subscription there was no one to send it (see handleActiveSpaceChange).
    private var activeSpaceObserver: NSObjectProtocol?
    /// SIGTERM signal source — stored, otherwise GCD would release it right
    /// after resume() and the handler would never fire.
    private var terminationSource: (any DispatchSourceSignal)?

    /// Repository root where the vendored copy of the adapter lives.
    ///
    /// Computed from this file's location on disk: right now the app only
    /// runs from the source tree (see AdapterPaths.vendored), and there's no
    /// other way to find vendor/. In plan 4 the adapter moves inside the app
    /// bundle — then this single spot will be updated to a path inside
    /// Bundle.main instead of a computation via #filePath.
    private static let developmentRepoRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // AppDelegate.swift -> App
            .deletingLastPathComponent()  // App -> repository root
    }()

    /// The music model lives for the app's entire runtime instead of being
    /// recreated along with the panel in refreshNotchScreen(): the adapter and
    /// its perl subprocess don't care about notch geometry, which can appear
    /// and disappear (closed lid, monitor change) independently of whether
    /// music happens to be playing at that moment. Recreating the pipeline on
    /// every such event would mean pointlessly restarting the external process.
    private let musicModel = MusicViewModel(
        provider: AdapterProvider(paths: AdapterPaths.vendored(repoRoot: developmentRepoRoot))
    )

    /// Clipboard history service. Optional rather than a `let` with direct
    /// initialization like `musicModel`: `NotchDatabase.init` and `migrate()`
    /// can throw (e.g. when disk space runs out), and a failure here shouldn't
    /// bring down the whole app — the notch and music work fine without
    /// clipboard history. Set up in startStorage(), see its doc.
    private var clipboardService: ClipboardService?

    /// Clipboard history repository — the same instance that ClipboardService
    /// receives. No point opening a second connection to the same database:
    /// DatabaseQueue serializes access on its own, so one repository is enough
    /// to serve both pasteboard polling and the clipboard tab (see
    /// startStorage() and refreshNotchScreen()).
    private var clipboardRepository: ClipboardRepository?

    /// Notes and pins repositories — the same database as the clipboard's
    /// (shared v3-stash migration on top of v1/v2, see NotchDatabase.migrate()).
    /// No point setting up a separate NotchDatabase for them, for the same
    /// reason as clipboardRepository above: DatabaseQueue serializes access on
    /// its own, and a second connection to the same file gives nothing but risk.
    private var notesRepository: NotesRepository?
    private var snippetsRepository: SnippetsRepository?

    private static let logger = Logger(subsystem: "kz.mobilefirst.notchka", category: "AppDelegate")

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installTerminationHandling()
        musicModel.start()
        startStorage()
        refreshNotchScreen()

        // The single AppKit notification that covers external monitor
        // docking/undocking, resolution changes, and opening/closing the lid all
        // at once — all of them move the built-in screen's origin in global
        // coordinates, or change the makeup of NSScreen.screens outright. Without
        // this subscription, the geometry and screenFrame captured once at launch
        // freeze forever: the hot zone stops matching the cursor, and the window
        // stops matching the notch itself, as soon as the monitor layout changes.
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshNotchScreen()
            }
        }

        // activeSpaceDidChangeNotification — the only public signal for an active
        // Space change, and it also fires when some app (not necessarily ours —
        // the API doesn't distinguish whose) enters or exits fullscreen: on macOS
        // fullscreen always lives in its own Space. A Space change by itself says
        // nothing about fullscreen — switching between two ordinary desktops sends
        // the same notification — so the decision is made after the fact, by
        // checking in handleActiveSpaceChange().
        activeSpaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleActiveSpaceChange()
            }
        }
    }

    deinit {
        // Same technique and same rationale as in HotkeyCenter.deinit / CursorMonitor.deinit.
        MainActor.assumeIsolated {
            if let screenParametersObserver {
                NotificationCenter.default.removeObserver(screenParametersObserver)
            }
            if let activeSpaceObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(activeSpaceObserver)
            }
        }
    }

    /// SIGTERM — what `pkill -x Notchka` (currently the only way to stop this
    /// app: an accessory app with no Dock icon has no "Quit" menu item) uses to
    /// terminate the process. By default this happens instantly, bypassing
    /// AppKit and Swift's stack unwinding — not a single deinit runs, and the
    /// adapter subprocess is orphaned. Confirmed by manual testing: without
    /// this handler, `pgrep -f mediaremote-adapter` after `pkill -x Notchka`
    /// found a live process.
    ///
    /// `signal(SIGTERM, SIG_IGN)` is mandatory and must come first — otherwise
    /// DispatchSourceSignal won't intercept the signal. This is a documented
    /// GCD requirement, not an assumption.
    private func installTerminationHandling() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            // The signal source runs the handler on the .main queue, i.e.
            // effectively the same thread as MainActor — same technique and same
            // rationale as in HotkeyCenter.onFire.
            MainActor.assumeIsolated { self?.shutDown() }
        }
        source.resume()
        terminationSource = source
    }

    /// Stops the adapter and only then terminates the process.
    ///
    /// Task {} is safe here and won't hang: the GCD handler above runs on a
    /// regular main queue, not in the context of a raw signal, so scheduling
    /// async work and the subsequent run-loop unwinding aren't blocked by
    /// anything. exit(0), not NSApp.terminate(_:) — we need a guarantee that
    /// the process won't terminate before musicModel.stopAdapter() actually
    /// sends SIGINT to the adapter and waits for it; NSApp.terminate(_:) gives
    /// no such guarantee.
    private func shutDown() {
        // Deadline safety net. `signal(SIGTERM, SIG_IGN)` above is set for the
        // entire life of the process, so if stopping the adapter hangs — say, the
        // actor is busy with an unfinished command — then the exit(0) below will
        // never happen, and `pkill` will stop killing the app altogether. Before
        // this handler, SIGTERM killed the process reliably, and that property
        // can't be lost: an orphaned subprocess is cheaper than an unkillable app.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.shutdownDeadline) {
            exit(1)
        }
        // Synchronously and right away: stopping the timers doesn't require
        // waiting, unlike the music adapter below — the same layout as
        // musicModel.stopAdapter(), but without async.
        clipboardService?.stop()
        Task {
            await musicModel.stopAdapter()
            exit(0)
        }
    }

    /// How long we wait for a clean adapter shutdown before force-exiting.
    /// A spike measured that the adapter terminates on SIGINT in under a
    /// second, so two seconds leaves plenty of margin for scheduling.
    private static let shutdownDeadline: TimeInterval = 2

    /// Opens the shared database (clipboard, notes, pins — one migration for
    /// all of them) and starts watching the pasteboard (see ClipboardService).
    ///
    /// A separate method rather than direct property initialization like
    /// musicModel: `NotchDatabase.init` and `migrate()` can throw, and a throw
    /// inside a stored property's initializer would bring down the entire app
    /// launch process. A failure here is not a reason to hide the notch or
    /// stop playing music, so the error is only logged, and all three stores
    /// remain unopened: in that case the clipboard, notes, and pins tabs show
    /// a placeholder instead of content (see content(for:) below).
    private func startStorage() {
        do {
            let location = StoreLocation(bundleID: "kz.mobilefirst.notchka")
            let database = try NotchDatabase(location: location)
            try database.migrate()

            let repository = ClipboardRepository(database: database, blobs: BlobStore(location: location))
            let service = ClipboardService(repository: repository)
            service.start()
            clipboardService = service
            clipboardRepository = repository

            notesRepository = NotesRepository(database: database)
            snippetsRepository = SnippetsRepository(database: database)
        } catch {
            Self.logger.error("failed to set up storage: \(error, privacy: .public)")
        }
    }

    /// Brings the panel and controller in line with the current screen
    /// configuration. Called at launch and then on every configuration change.
    /// Three outcomes: the notch was found (for the first time or again, e.g.
    /// the lid was closed at launch) — the panel is created; the screen with
    /// the notch stayed but moved or changed — geometry and the window frame
    /// are updated in place; the notch disappeared — the panel is torn down
    /// instead of lingering at stale coordinates.
    private func refreshNotchScreen() {
        guard let screen = ScreenMetricsReader.builtInScreen(),
              let metrics = ScreenMetricsReader.metrics(for: screen),
              let geometry = NotchGeometryCalculator.geometry(for: metrics)
        else {
            Self.logger.notice("No notch display available: panel is not shown")
            teardownPanel()
            return
        }

        // The window is fixed to its maximum expanded size and centered above the notch.
        let frame = panelFrame(for: screen, size: PanelMetrics.windowSize)

        if let controller, let panel {
            // Same notch, but the screen moved or changed: update geometry and
            // window position in place, without recreating the cursor and hotkey
            // monitors — they have nothing to relearn except coordinates.
            controller.updateGeometry(geometry, screenFrame: screen.frame)
            panel.setFrame(frame, display: true)
            return
        }

        // The controller needs an already-existing panel (see NotchController),
        // so the window is created with empty content and gets its real content
        // right away, synchronously, before the first render.
        let panel = NotchPanel(contentRect: frame, rootView: EmptyView())

        let controller = NotchController(
            geometry: geometry,
            screenFrame: screen.frame,
            panel: panel
        )
        // The clipboard, notes, and pins models are built once here, together
        // with the controller — not as AppDelegate properties like musicModel:
        // the repositories appear later, in startStorage(), not at the moment
        // AppDelegate is initialized, so a musicModel-style ready-made instance
        // isn't possible here. From here on they live inside NotchRootView for
        // exactly as long as the controller itself — repeated calls to
        // refreshNotchScreen() (screen changes) don't reach this point, see the
        // early return above.
        let clipboardModel = clipboardRepository.map { repository in
            ClipboardViewModel(repository: repository) { [weak self] in
                // Marks our own pasteboard write as already seen. Otherwise an image
                // pulled from history would come back into it as a second entry a
                // fraction of a second later: it arrives from the pasteboard in a
                // different representation, the hash doesn't match, and
                // deduplication doesn't catch it.
                self?.clipboardService?.ignoreOwnPasteboardWrite()
            }
        }
        let notesModel = notesRepository.map(NotesViewModel.init(repository:))
        let pinsModel = snippetsRepository.map { repository in
            PinsViewModel(repository: repository) { [weak self] in
                // Same technique and same rationale as clipboardModel above: without
                // this mark, pasteboard polling would read the pin's value back a
                // fraction of a second later and add it to clipboard history as a
                // separate entry — in plain text, even if the pin is marked sensitive.
                self?.clipboardService?.ignoreOwnPasteboardWrite()
            }
        }
        panel.contentView = NSHostingView(
            rootView: NotchRootView(
                controller: controller, notchSize: geometry.notchRect.size,
                musicModel: musicModel, clipboardModel: clipboardModel,
                notesModel: notesModel, pinsModel: pinsModel
            )
        )
        controller.start()
        self.controller = controller

        panel.orderFrontRegardless()
        self.panel = panel
    }

    /// Reaction to an active Space change: recomputes the fullscreen flag and
    /// sends it to the state machine. Spec §5 requires disabling the panel in
    /// fullscreen — on the notch display there's neither a menu bar nor a
    /// visible notch there, and the panel has nowhere to live.
    ///
    /// The signal is cheap and indirect, not guaranteed: AppKit has no direct
    /// API for "is some other process fullscreen right now", so this relies on
    /// the assumption that the built-in screen's safeAreaInsets.top (the menu
    /// bar area height) collapses to 0 when the menu bar is hidden by another
    /// app's fullscreen. Not verified live on this machine — the session ended
    /// up locked, and the test transition to fullscreen (a regular window,
    /// toggleFullScreen on itself) got stuck on willEnterFullScreen and never
    /// completed. Hence the debug-level log below: it gives a cheap way to
    /// verify this without setting up this whole probe again.
    private func handleActiveSpaceChange() {
        guard let screen = Self.hardwareBuiltInScreen() else { return }
        let topInset = screen.safeAreaInsets.top
        let isFullScreen = topInset <= 0
        Self.logger.debug(
            "Active Space change: safeAreaInsets.top=\(topInset, privacy: .public) → isFullScreen=\(isFullScreen, privacy: .public)"
        )
        controller?.handle(.fullScreenChanged(isFullScreen))
    }

    /// The built-in display, found by the hardware flag (CGDisplayIsBuiltin),
    /// not by the presence of a notch.
    ///
    /// ScreenMetricsReader.builtInScreen() looks for a screen with
    /// safeAreaInsets.top > 0 — that's correct for its job (no notch, nothing
    /// to compute geometry from), but here that very same inset is the signal
    /// we're looking for: in fullscreen it temporarily collapses to 0, and at
    /// that moment ScreenMetricsReader's filter would stop finding exactly the
    /// screen we're tracking.
    private static func hardwareBuiltInScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            else { return false }
            return CGDisplayIsBuiltin(screenNumber) != 0
        }
    }

    private func panelFrame(for screen: NSScreen, size: CGSize) -> CGRect {
        let origin = CGPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height
        )
        return CGRect(origin: origin, size: size)
    }

    /// Tears down the panel together with the controller: the cursor monitor
    /// and hotkey are stopped explicitly — with no notch on screen, they have
    /// nothing to do.
    ///
    /// Explicitly, rather than via deinit, and close() instead of
    /// orderOut(nil), because zeroing out references here doesn't release
    /// anything. orderOut hides the window but leaves it in the app's window
    /// list, and the panel's contentView holds onto NotchRootView and, through
    /// it, the controller. This used to just zero out both references and
    /// leave — and the cursor monitor with its registered hotkey kept living
    /// inside an unreachable controller. When the notch came back, a second
    /// controller was created and registered its hotkey on top of the still-
    /// living first one.
    private func teardownPanel() {
        // Order matters: silence the event sources first, otherwise a hotkey
        // firing mid-teardown or cursor movement would call handle() and
        // through it syncMouseHandling() on a window that's already closing.
        controller?.stop()
        panel?.contentView = nil
        panel?.close()
        panel = nil
        controller = nil
    }
}

/// Bridge between the controller/music model and the panel shell.
///
/// NotchPanelView lives in NotchUI and takes NotchState by value, not the
/// controller itself — otherwise the AppKit-independent package would have
/// to be tied to the App target. That's why controller.state is read right
/// here, inside body: Observation only subscribes to a property where it
/// was read during rendering — compute this value once in
/// refreshNotchScreen() and pass it as a constant, and no subscription
/// would arise, and the panel would freeze forever in the state it had at
/// launch. The same reasoning applies to musicModel too — it's also
/// @Observable, and its properties (track/position/artwork/accent) are
/// read right here, inside body (via content(for:), called directly from
/// body), not ahead of time.
private struct NotchRootView: View {
    let controller: NotchController
    let notchSize: CGSize
    let musicModel: MusicViewModel
    /// `nil` on any of the three models below means the same thing:
    /// startStorage() failed to set up storage (see its doc in AppDelegate) —
    /// the corresponding tab shows TabPlaceholderView instead of content in
    /// that case.
    let clipboardModel: ClipboardViewModel?
    let notesModel: NotesViewModel?
    let pinsModel: PinsViewModel?

    /// Accessibility permission, read as of the last check. AXIsProcessTrusted()
    /// gives no notification when it's granted, so simply declaring this
    /// property doesn't guarantee the value is current — that's kept up to
    /// date by the polling loop in .task(id: isClipboardTabActive) below, as
    /// long as the clipboard tab is open and permission hasn't been granted
    /// yet.
    @State private var isAccessibilityTrusted = AccessibilityPermission.isTrusted

    /// Minimum interval between periodic resyncs (see MusicViewModel.resync()
    /// and .task(id: isExpanded) below). Each one spawns a separate perl
    /// process — there's no point spawning them six times more often than the
    /// once-per-second tick that drives track position.
    private static let resyncInterval: TimeInterval = 5

    /// Whether the panel is expanded, regardless of which tab is active inside
    /// it. The brief specifies exactly this condition for updating track
    /// position: `if case .expanded = controller.state`, with no tie to a
    /// specific tab.
    private var isExpanded: Bool {
        if case .expanded = controller.state { return true }
        return false
    }

    /// Whether the panel is expanded specifically on the clipboard tab —
    /// unlike isExpanded above, the specific tab matters here: the feed should
    /// reload history when it's opened, not on every panel expansion.
    private var isClipboardTabActive: Bool {
        if case .expanded(.clipboard) = controller.state { return true }
        return false
    }

    /// Same principle as isClipboardTabActive above: notes and pins are
    /// reloaded when they're opened, not on every panel expansion.
    private var isNotesTabActive: Bool {
        if case .expanded(.notes) = controller.state { return true }
        return false
    }

    private var isPinsTabActive: Bool {
        if case .expanded(.pins) = controller.state { return true }
        return false
    }

    var body: some View {
        NotchPanelView(
            state: controller.state,
            notchSize: notchSize,
            accent: musicModel.accent,
            // Same path as the keyboard: clicking the tab column and
            // ⌘1…⌘4/⇥ both end up calling the same handle(.selectTab(_:))
            // on the controller (see PanelKeyHandler → KeyBinding → NotchPanel
            // .keyDown(with:) for the keyboard side).
            onSelectTab: { tab in controller.handle(.selectTab(tab)) }
        ) { tab in
            content(for: tab)
        }
        .task(id: isExpanded) {
            // Track position isn't stored as ticking (see
            // MusicViewModel.refreshPosition) — someone has to trigger a
            // recompute periodically while the panel is actually expanded.
            // .task(id:) cancels the previous run itself and doesn't start a new
            // one until id becomes true: on a closed or peeked panel the loop
            // below doesn't run at all, rather than just doing nothing on each
            // step — that's exactly what the spec calls "sleeping at rest".
            guard isExpanded else { return }
            // A resync exactly once here, before entering the loop, rather than
            // inside the while below: there it would call get on every second of
            // an expanded panel, and that's a separate perl process per tick (see
            // MusicViewModel.resync()). This one-off call handles the case "the
            // interception already ended by the time the user opened the panel" —
            // without waiting for the first tick of the periodic resync in the
            // neighboring .task(id:) below.
            await musicModel.resync()
            while !Task.isCancelled {
                musicModel.refreshPosition()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .task(id: isExpanded) {
            // Periodic resync — a separate .task(id:) on the same isExpanded,
            // rather than a branch inside the per-second position loop above: it
            // has its own period (Self.resyncInterval, no more often than once
            // every 5 seconds — get spawns a separate perl process, can't do that
            // every second), and separate loops don't tie one period to the
            // other. Catches the case "the interception ended while the panel was
            // already open" — the one-off call in the neighboring .task(id:)
            // above only happens at the moment of expansion and doesn't see this
            // case.
            guard isExpanded else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.resyncInterval))
                guard !Task.isCancelled else { break }
                await musicModel.resync()
            }
        }
        .task(id: isClipboardTabActive) {
            // Not a ticking loop, unlike track position above: clipboard history
            // doesn't need polling once a second, it's read once when the tab is
            // opened (decision #4 of the spec) — .task(id:) already restarts this
            // block on every new opening, nothing extra needs to be repeated.
            guard isClipboardTabActive, let clipboardModel else { return }
            await clipboardModel.refresh()
        }
        .task(id: isNotesTabActive) {
            // Same technique as the clipboard above: not ticking, read once when
            // the tab is opened, .task(id:) restarts the block on every new
            // opening.
            guard isNotesTabActive, let notesModel else { return }
            await notesModel.refresh()
        }
        .task(id: isPinsTabActive) {
            guard isPinsTabActive, let pinsModel else { return }
            await pinsModel.refresh()
        }
        .task(id: isClipboardTabActive) {
            // A ticking loop, unlike refresh() above — and here that's mandatory,
            // not a style choice: the cursor leaving the expanded panel doesn't
            // close it (see NotchStateMachine — "working with the clipboard feed
            // implies the mouse can move anywhere"), and clicking "Open Settings"
            // doesn't send Esc or press the hotkey. So the user can go to Settings
            // and come back without ever leaving .expanded(.clipboard) — the only
            // way to pick up the granted permission in this case without
            // restarting the app (decision #3 of task 10's spec) is to keep
            // polling ourselves while the clipboard tab is open. Once a second —
            // the same cadence as track position in the neighboring task(id:)
            // above. The check happens right away on entering the tab, without
            // waiting for the first tick, and the loop stops itself as soon as
            // permission is granted: nothing left to poll after that, and at
            // rest the app must sleep — the same rule as refresh() above.
            guard isClipboardTabActive, clipboardModel != nil else { return }
            while !Task.isCancelled {
                isAccessibilityTrusted = AccessibilityPermission.isTrusted
                guard !isAccessibilityTrusted else { return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// All four tabs are genuinely wired up — the placeholder remains only
    /// for the case of a storage failure (see its branches below), not as a
    /// stand-in for the future.
    ///
    /// switch with no default — intentional. With a default, a new NotchTab
    /// case would silently fall through to the placeholder with no compile
    /// error and no test failure: that's exactly the hole described in the
    /// task about the tab column. Explicit cases achieve the same thing
    /// reliably — a forgotten tab gets caught by the compiler, not by a user
    /// a month later.
    @ViewBuilder
    private func content(for tab: NotchTab) -> some View {
        switch tab {
        case .music:
            MusicTabView(
                track: musicModel.track,
                position: musicModel.position,
                artwork: musicModel.artwork,
                accent: musicModel.accent,
                onPreviousTrack: { musicModel.previousTrack() },
                onTogglePlayback: { musicModel.togglePlayback() },
                onNextTrack: { musicModel.nextTrack() }
            )
        case .clipboard:
            if let clipboardModel {
                clipboardContent(model: clipboardModel)
            } else {
                // The tab is ready, but storage didn't open (see startStorage).
                // "Coming soon" here would misrepresent the reason.
                TabPlaceholderView(tab: tab, message: "Storage unavailable")
            }
        case .notes:
            if let notesModel {
                notesContent(model: notesModel)
            } else {
                TabPlaceholderView(tab: tab, message: "Storage unavailable")
            }
        case .pins:
            if let pinsModel {
                pinsContent(model: pinsModel)
            } else {
                TabPlaceholderView(tab: tab, message: "Storage unavailable")
            }
        }
    }

    /// The draft's two-way binding is built by hand rather than via
    /// `@Bindable`: `notesModel` in this view is a constant (`let`), but it's
    /// a reference to a class, and writing to `draft` through the `set`
    /// closure mutates the very same live model state that `get` reads.
    private func notesContent(model: NotesViewModel) -> some View {
        NotesTabView(
            rows: model.rows,
            draft: Binding(get: { model.draft }, set: { model.draft = $0 }),
            accent: musicModel.accent,
            onSave: { model.saveDraft() },
            onCommitEdit: { id, body in model.commitEdit(id: id, body: body) },
            onDelete: { id in model.delete(id: id) }
        )
    }

    private func pinsContent(model: PinsViewModel) -> some View {
        PinsTabView(
            chips: model.chips,
            onActivate: { id in
                // pasteTarget, not a capture at expansion time — same reason as
                // clipboardContent below: between expansion and the click, the user
                // has time to switch the active app.
                model.activate(id: id, frontmostApplication: controller.pasteTarget)
            },
            onCopyOnly: { id in model.copyOnly(id: id) },
            onReorder: { id, newIndex in model.reorder(id: id, to: newIndex) },
            onEdit: { chip in model.save(chip) }
        )
    }

    /// The feed or an explanation about permission — which of the two is
    /// decided by the pure function ClipboardTabContent.resolve in NotchUI:
    /// here we just read its result, and the choice itself is covered by a
    /// windowless test (see PermissionPromptViewTests).
    @ViewBuilder
    private func clipboardContent(model: ClipboardViewModel) -> some View {
        switch ClipboardTabContent.resolve(isAccessibilityTrusted: isAccessibilityTrusted) {
        case .ribbon:
            ClipboardTabView(
                cards: model.cards,
                selected: model.selectedID,
                accent: musicModel.accent,
                onActivate: { id in
                    // pasteTarget, not something captured at expansion time: between
                    // expansion and the click, the user has time to switch apps, see its
                    // doc in NotchController.
                    model.activate(id: id, frontmostApplication: controller.pasteTarget)
                },
                onCopyOnly: { id in model.copyOnly(id: id) }
            )
        case .permissionPrompt:
            PermissionPromptView(
                onRequestPermission: {
                    // The system dialog — only from this explicit click, never on its own
                    // at launch or panel expansion. We assign the return value right
                    // away: it's almost always false (the dialog just appeared, the user
                    // hasn't answered yet), but if permission was already granted some
                    // other way, we don't make the user wait for an extra polling tick.
                    isAccessibilityTrusted = AccessibilityPermission.requestIfNeeded()
                },
                onOpenSettings: AccessibilityPermission.openSettings
            )
        }
    }
}
