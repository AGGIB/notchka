import AppKit
import SwiftUI
import NotchCore

/// Окно панели. Размер постоянен и равен максимальному развороту:
/// менять фрейм NSWindow во время пружины — значит получить рывки,
/// поэтому анимируется только содержимое внутри.
final class NotchPanel: NSPanel {
    /// Разрешает панели стать key-окном. Включается только на время
    /// разворота с полем поиска, иначе панель отобрала бы фокус
    /// у приложения, куда мы собираемся вставлять текст.
    var acceptsKeyboard = false

    /// Куда уходит разобранное нажатие клавиши из keyDown(with:). Подключается
    /// снаружи (см. NotchController.start()) замыканием, а не хранением самого
    /// контроллера: у NotchController уже есть `weak var panel` в обратную
    /// сторону, и сильная ссылка здесь замкнула бы цикл удержания.
    var onKeyEvent: ((NotchEvent) -> Void)?

    override var canBecomeKey: Bool { acceptsKeyboard }
    override var canBecomeMain: Bool { false }

    /// Отпускает клавиатурный фокус, если он у панели.
    ///
    /// Просто снять `acceptsKeyboard` мало: окно, уже ставшее key, таковым и
    /// остаётся, и продолжало бы забирать нажатия у приложения, в котором
    /// пользователь работает, после схлопывания панели.
    func resignKeyIfNeeded() {
        guard isKeyWindow else { return }
        resignKey()
        // Фокус возвращается тому, у кого он был до нас. Без этого клавиатура
        // осталась бы висеть в воздухе: у accessory-приложения нет других
        // окон, которым её можно передать.
        NSApp.deactivate()
    }

    init(contentRect: CGRect, rootView: some View) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        // Выше меню-бара: панель должна перекрывать его, а не прятаться под ним.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenNone, .ignoresCycle]

        isOpaque = false
        backgroundColor = .clear
        // NSWindow по умолчанию сам себя освобождает при close(), а ARC об этом
        // не знает и освободит окно второй раз по своей сильной ссылке.
        // AppDelegate закрывает панель явно, когда чёлка пропадает с экрана.
        isReleasedWhenClosed = false
        // Тень рисуем сами — системная не умеет вогнутые углы.
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        // По умолчанию окно прозрачно для мыши, иначе оно перехватит
        // клики по меню-бару. Дальше переключается NotchController
        // .syncMouseHandling() по текущему состоянию панели.
        ignoresMouseEvents = true

        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = CGRect(origin: .zero, size: contentRect.size)
        contentView = hosting
    }

    /// Долетает сюда только пока панель — key-окно, то есть только в
    /// .expanded (acceptsKeyboard управляется NotchController
    /// .syncMouseHandling()), поэтому отдельная проверка состояния внутри
    /// не нужна. Нераспознанная раскладкой клавиша обязана уйти дальше по
    /// цепочке ответчиков через super — иначе поле поиска (следующий план)
    /// не получило бы ни одного печатного символа.
    override func keyDown(with event: NSEvent) {
        let key = PanelKeyHandler.panelKey(for: event)
        let modifiers = PanelKeyHandler.panelModifiers(for: event)
        guard let notchEvent = KeyBinding.event(forKeyCode: key, modifiers: modifiers) else {
            super.keyDown(with: event)
            return
        }
        onKeyEvent?(notchEvent)
    }
}
