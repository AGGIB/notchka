import AppKit

/// Tracks the cursor position. The global mouse monitor doesn't require
/// permissions — unlike the keyboard monitor.
///
/// The timer only runs when there's a pending threshold: at rest
/// the app shouldn't wake up 20 times a second.
@MainActor
final class CursorMonitor {
    private var monitor: Any?
    private var timer: Timer?
    private var onSample: ((CGPoint, Date) -> Void)?

    /// Polling step while waiting for the threshold to elapse. 50 ms is enough:
    /// the shortest threshold is 120 ms.
    private static let tickInterval: TimeInterval = 0.05

    func start(onSample: @escaping (CGPoint, Date) -> Void) {
        self.onSample = onSample
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.emit()
            }
        }
    }

    /// Enabled by the controller when the threshold has a pending transition.
    func setTicking(_ isTicking: Bool) {
        guard isTicking != (timer != nil) else { return }
        if isTicking {
            // Timer.scheduledTimer registers the timer only in .default mode —
            // this app lives next to the menu bar, and in that mode the timer
            // doesn't tick while an open menu is being tracked (RunLoop.Mode.eventTracking).
            // A cursor frozen for that duration would never reach the hover threshold.
            // .common combines both modes, so the timer is created manually and
            // added to the current run loop instead of via scheduledTimer.
            let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.emit() }
            }
            RunLoop.current.add(timer, forMode: .common)
            self.timer = timer
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        setTicking(false)
    }

    deinit {
        // Same trick and same rationale as in HotkeyCenter.deinit.
        MainActor.assumeIsolated { stop() }
    }

    private func emit() {
        onSample?(NSEvent.mouseLocation, Date())
    }
}
