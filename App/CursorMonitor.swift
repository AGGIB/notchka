import AppKit

/// Следит за положением курсора. Глобальный монитор мыши разрешений
/// не требует — в отличие от монитора клавиатуры.
///
/// Таймер запускается только когда есть ожидающий порог: в покое
/// приложение не должно просыпаться 20 раз в секунду.
@MainActor
final class CursorMonitor {
    private var monitor: Any?
    private var timer: Timer?
    private var onSample: ((CGPoint, Date) -> Void)?

    /// Шаг опроса, пока ждём истечения порога. 50 мс достаточно:
    /// самый короткий порог — 120 мс.
    private static let tickInterval: TimeInterval = 0.05

    func start(onSample: @escaping (CGPoint, Date) -> Void) {
        self.onSample = onSample
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.emit()
            }
        }
    }

    /// Включается контроллером, когда у порога есть незавершённый переход.
    func setTicking(_ isTicking: Bool) {
        guard isTicking != (timer != nil) else { return }
        if isTicking {
            timer = Timer.scheduledTimer(
                withTimeInterval: Self.tickInterval, repeats: true
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.emit() }
            }
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

    private func emit() {
        onSample?(NSEvent.mouseLocation, Date())
    }
}
