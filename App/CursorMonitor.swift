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
            // Timer.scheduledTimer регистрирует таймер только в режиме .default —
            // приложение живёт рядом с меню-баром, а там таймер в этом режиме не
            // тикает во время отслеживания открытого меню (RunLoop.Mode.eventTracking).
            // Замёрзший на это время курсор никогда не досчитал бы порог наведения.
            // .common объединяет оба режима, поэтому таймер создаётся вручную и
            // добавляется в текущий run loop, а не через scheduledTimer.
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
        // Тот же приём и то же обоснование, что в HotkeyCenter.deinit.
        MainActor.assumeIsolated { stop() }
    }

    private func emit() {
        onSample?(NSEvent.mouseLocation, Date())
    }
}
