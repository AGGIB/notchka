import AppKit
import Observation
import NotchCore
import NotchUI

/// Сводит воедино источники событий и машину состояний.
/// Здесь же живёт правило: окно ловит мышь, пока панель не в `closed` —
/// включая автопик `peek(.trackChanged)`, где курсор может быть далеко
/// от горячей зоны (сработал на смену трека, а не на наведение); в
/// `closed` мышь не ловится, иначе меню-бар был бы недоступен.
@MainActor
@Observable
final class NotchController {
    private(set) var state: NotchState = .closed

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
        // Единственный источник истины про «closed ⇒ мышь прозрачна»:
        // раньше это держалось только на том, что NotchPanel.init и
        // syncMouseHandling() независимо друг от друга ставят одно и то же
        // значение по умолчанию. Актуально и после re-derivation геометрии
        // (см. AppDelegate.refreshNotchScreen) — при пересоздании панели
        // start() вызывается заново, а при обновлении геометрии на месте
        // state не меняется, так что синхронизировать нечего.
        syncMouseHandling()
        cursor.start { [weak self] location, now in
            self?.cursorSampled(at: location, now: now)
        }
        hotkey.register { [weak self] in
            self?.handle(.hotkey)
        }
    }

    /// Останавливает источники событий. Существует отдельно от deinit, потому
    /// что на deinit полагаться нельзя: контроллер держит не только AppDelegate,
    /// но и NSHostingView панели через NotchRootView, и обнуление ссылки в
    /// AppDelegate само по себе не освобождает его. Оба вызова внутри
    /// идемпотентны, так что повторный stop() (в том числе из deinit) безвреден.
    func stop() {
        cursor.stop()
        hotkey.unregister()
    }

    deinit {
        // Тот же приём и то же обоснование, что в HotkeyCenter.deinit.
        MainActor.assumeIsolated { stop() }
    }

    /// Обновляет геометрию при смене конфигурации экранов — вызывается из
    /// AppDelegate по NSApplication.didChangeScreenParametersNotification.
    /// Видимое состояние панели не трогаем: экран сдвинулся, а не закрылся,
    /// открытая панель не обязана из-за этого схлопнуться. Мониторы курсора
    /// и хоткея тоже не трогаем — их пересоздание принадлежит AppDelegate,
    /// когда чёлка пропадает или появляется целиком, а не просто двигается.
    func updateGeometry(_ geometry: NotchGeometry, screenFrame: CGRect) {
        self.geometry = geometry
        self.screenFrame = screenFrame
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

        // Пока панель закрыта, вход проверяется по узкой зоне выреза — она
        // мала намеренно, чтобы курсор, просто скользящий к меню-бару, её не
        // раскрывал. Но эта же зона меньше открытой панели (см. спеку §8),
        // и как только панель открыта (peek или expanded), проверка должна
        // идти по её текущим видимым границам — иначе наведение на саму
        // панель означало бы выход из зоны входа и закрытие под курсором.
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
