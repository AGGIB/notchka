import AppKit
import Observation
import NotchCore
import NotchUI

/// Ties together event sources and the state machine.
/// This is also where the rule lives: the window catches the mouse whenever
/// the panel isn't `closed` — including the auto-peek `peek(.trackChanged)`,
/// where the cursor can be far from the hot zone (triggered by a track
/// change, not by hovering); in `closed` the mouse isn't caught, otherwise
/// the menu bar would become unreachable.
@MainActor
@Observable
final class NotchController {
    private(set) var state: NotchState = .closed
    /// The app that was frontmost immediately before the panel expanded.
    ///
    /// A fallback, not the primary source: see `pasteTarget`.
    private(set) var frontmostApplicationBeforeExpanding: NSRunningApplication?

    /// Where to paste the item picked from history.
    ///
    /// We ask the system at paste time rather than rely on the capture made
    /// at expand time: an expanded panel doesn't close on cursor exit or on
    /// loss of focus, so between expanding and clicking the user has time to
    /// ⌘Tab away to another app. The captured value would then point to
    /// wherever they left from, and the paste would land in the wrong place.
    ///
    /// The capture remains a safety net for exactly one case: if we ourselves
    /// are frontmost at that moment. A `.nonactivatingPanel` on an
    /// accessory app shouldn't make it frontmost, but relying on that
    /// without a live check isn't worth it — the difference between "pasted
    /// in the wrong place" and "pasted into ourselves" is huge.
    var pasteTarget: NSRunningApplication? {
        let frontmost = NSWorkspace.shared.frontmostApplication
        guard frontmost?.bundleIdentifier == Bundle.main.bundleIdentifier else { return frontmost }
        return frontmostApplicationBeforeExpanding
    }

    @ObservationIgnored private var machine = NotchStateMachine()
    @ObservationIgnored private var debouncer = HoverDebouncer()
    @ObservationIgnored private let cursor = CursorMonitor()
    @ObservationIgnored private let hotkey = HotkeyCenter()
    @ObservationIgnored private var geometry: NotchGeometry
    @ObservationIgnored private var screenFrame: CGRect
    @ObservationIgnored private weak var panel: NotchPanel?

    init(geometry: NotchGeometry, screenFrame: CGRect, panel: NotchPanel) {
        self.geometry = geometry
        self.screenFrame = screenFrame
        self.panel = panel
    }

    func start() {
        // The single source of truth for "closed ⇒ mouse-transparent": it
        // used to rely solely on NotchPanel.init and syncMouseHandling()
        // independently setting the same default value. Still holds after
        // geometry re-derivation too (see AppDelegate.refreshNotchScreen) —
        // when the panel is recreated, start() is called again, and when
        // geometry is updated in place, state doesn't change, so there's
        // nothing to sync.
        syncMouseHandling()
        cursor.start { [weak self] location, now in
            self?.cursorSampled(at: location, now: now)
        }
        hotkey.register { [weak self] in
            self?.handle(.hotkey)
        }
        // The expanded panel forwards already-parsed keypresses here (see
        // NotchPanel.keyDown(with:)). A closure rather than storing self in
        // the panel itself — the panel already has a path to the
        // controller, and a strong back-reference together with the
        // private weak var panel above would close a retain cycle.
        panel?.onKeyEvent = { [weak self] event in
            self?.handle(event)
        }
    }

    /// Stops the event sources. Exists separately from deinit because deinit
    /// can't be relied on: the controller is held not only by AppDelegate but
    /// also by the panel's NSHostingView through NotchRootView, so clearing
    /// the reference in AppDelegate alone doesn't release it. Both calls
    /// inside are idempotent, so a repeated stop() (including from deinit)
    /// is harmless.
    func stop() {
        cursor.stop()
        hotkey.unregister()
    }

    deinit {
        // Same technique and same rationale as in HotkeyCenter.deinit.
        MainActor.assumeIsolated { stop() }
    }

    /// Updates the geometry when the screen configuration changes — called
    /// from AppDelegate on NSApplication.didChangeScreenParametersNotification.
    /// The panel's visible state is left untouched: the screen moved, it
    /// didn't close, so an open panel isn't obligated to collapse because of
    /// that. The cursor and hotkey monitors are left untouched too —
    /// recreating them is AppDelegate's responsibility, for when the notch
    /// disappears or appears entirely, not just moves.
    func updateGeometry(_ geometry: NotchGeometry, screenFrame: CGRect) {
        self.geometry = geometry
        self.screenFrame = screenFrame
    }

    func handle(_ event: NotchEvent) {
        let wasExpanded = isExpanded(state)
        guard let newState = machine.handle(event) else { return }

        // Entering .expanded from .closed/.peek is the last moment when the
        // frontmost app is still guaranteed to be someone else's: below,
        // syncMouseHandling() will turn on panel.acceptsKeyboard and let the
        // panel become the key window, after which the frontmost app will be
        // Notchka itself. We check against the previous state, not just the
        // new one — otherwise switching tabs within an already-open panel
        // (selectTab, cycleTab: both .expanded → .expanded) would overwrite
        // the captured app with Notchka itself.
        if isExpanded(newState), !wasExpanded {
            frontmostApplicationBeforeExpanding = NSWorkspace.shared.frontmostApplication
        }

        state = newState
        syncMouseHandling()
    }

    /// true for any .expanded tab — the specific tab doesn't matter here.
    private func isExpanded(_ state: NotchState) -> Bool {
        if case .expanded = state { return true }
        return false
    }

    private func cursorSampled(at location: CGPoint, now: Date) {
        // NSEvent.mouseLocation is given in global AppKit coordinates: the
        // origin is the bottom-left corner of the entire monitor layout, Y
        // grows upward; this origin doesn't have to coincide with the
        // bottom-left corner of this particular screen (with multiple
        // displays, screenFrame can have a non-zero origin).
        // NotchGeometry.hotZone, on the other hand, is always given relative
        // to its own screen with the origin at the top-left corner. So X is
        // converted by shifting by screenFrame.origin.x — there's no flip,
        // X grows rightward in both systems — while Y is converted by
        // subtracting from screenFrame.maxY: here the shift and the flip
        // coincide in a single operation, because maxY already equals
        // origin.y + height.
        let screenRelative = CGPoint(
            x: location.x - screenFrame.origin.x,
            y: screenFrame.maxY - location.y
        )

        // While the panel is closed, entry is checked against the narrow
        // notch zone — it's deliberately small so that a cursor merely
        // gliding toward the menu bar doesn't open it. But that same zone is
        // smaller than the open panel (see spec §8), and as soon as the
        // panel is open (peek or expanded), the check needs to go against
        // its current visible bounds — otherwise hovering over the panel
        // itself would count as leaving the entry zone and it would close
        // right under the cursor.
        let containmentZone: CGRect = switch state {
        case .closed:
            geometry.hotZone
        case .peek, .expanded:
            geometry.retentionZone(for: PanelMetrics.size(for: state, notch: geometry.notchRect.size))
        }
        let isInside = containmentZone.contains(screenRelative)

        if let event = debouncer.cursorMoved(isInsideHotZone: isInside, at: now) {
            handle(event)
        }
        cursor.setTicking(debouncer.hasPendingTransition)
    }

    /// Mouse transparency of the window and the right to accept keyboard
    /// input. A closed panel must not get in the menu bar's way.
    ///
    /// In `.expanded` the panel not only gets the right to become the key
    /// window, it's actually made one: `canBecomeKey` is a permission, not
    /// an action. The panel is opened by a global hotkey that doesn't
    /// activate the app, and without an explicit `makeKey()` keyboard
    /// events never reach it at all — not ⌘1…⌘4, not ⇥, not Esc — until the
    /// user clicks inside. In other words, keyboard control wouldn't work in
    /// exactly the scenario it was built for.
    private func syncMouseHandling() {
        guard let panel else { return }
        switch state {
        case .closed:
            panel.ignoresMouseEvents = true
            panel.acceptsKeyboard = false
            panel.resignKeyIfNeeded()
        case .peek:
            panel.ignoresMouseEvents = false
            panel.acceptsKeyboard = false
            panel.resignKeyIfNeeded()
        case .expanded:
            panel.ignoresMouseEvents = false
            panel.acceptsKeyboard = true
            panel.makeKey()
        }
    }
}
