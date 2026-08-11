import AppKit
import Observation
import NotchCore

/// Сводит воедино источники событий и машину состояний.
/// Здесь же живёт правило: окно ловит мышь только когда панель раскрыта
/// или курсор в горячей зоне — иначе меню-бар был бы недоступен.
@MainActor
@Observable
final class NotchController {
    private(set) var state: NotchState = .closed

    @ObservationIgnored private var machine = NotchStateMachine()
    @ObservationIgnored private var debouncer = HoverDebouncer()
    @ObservationIgnored private let cursor = CursorMonitor()
    @ObservationIgnored private let hotkey = HotkeyCenter()
    @ObservationIgnored private let geometry: NotchGeometry
    @ObservationIgnored private let screenFrame: CGRect
    @ObservationIgnored private weak var panel: NotchPanel?

    init(geometry: NotchGeometry, screenFrame: CGRect, panel: NotchPanel) {
        self.geometry = geometry
        self.screenFrame = screenFrame
        self.panel = panel
    }

    func start() {
        cursor.start { [weak self] location, now in
            self?.cursorSampled(at: location, now: now)
        }
        hotkey.register { [weak self] in
            self?.handle(.hotkey)
        }
    }

    deinit {
        // Тот же приём и то же обоснование, что в HotkeyCenter.deinit.
        MainActor.assumeIsolated {
            cursor.stop()
            hotkey.unregister()
        }
    }

    func handle(_ event: NotchEvent) {
        guard machine.handle(event) != nil else { return }
        state = machine.state
        syncMouseHandling()
    }

    private func cursorSampled(at location: CGPoint, now: Date) {
        // NSEvent.mouseLocation задан в глобальных координатах AppKit: начало
        // отсчёта — левый нижний угол всей раскладки мониторов, Y растёт вверх;
        // это начало не обязано совпадать с левым нижним углом именно этого
        // экрана (при нескольких дисплеях у screenFrame бывает ненулевой origin).
        // NotchGeometry.hotZone, наоборот, всегда задана относительно своего
        // экрана с началом в левом верхнем углу. Поэтому X переводится сдвигом
        // на screenFrame.origin.x — переворота нет, в обеих системах X растёт
        // вправо, — а Y вычитанием из screenFrame.maxY: здесь сдвиг и переворот
        // совпадают в одном действии, потому что maxY уже равен origin.y + height.
        let screenRelative = CGPoint(
            x: location.x - screenFrame.origin.x,
            y: screenFrame.maxY - location.y
        )
        let isInside = geometry.hotZone.contains(screenRelative)

        if let event = debouncer.cursorMoved(isInsideHotZone: isInside, at: now) {
            handle(event)
        }
        cursor.setTicking(debouncer.hasPendingTransition)
    }

    /// Прозрачность окна для мыши. Закрытая панель не должна мешать меню-бару.
    private func syncMouseHandling() {
        guard let panel else { return }
        switch state {
        case .closed:
            panel.ignoresMouseEvents = true
            panel.acceptsKeyboard = false
        case .peek:
            panel.ignoresMouseEvents = false
            panel.acceptsKeyboard = false
        case .expanded:
            panel.ignoresMouseEvents = false
            panel.acceptsKeyboard = true
        }
    }
}
