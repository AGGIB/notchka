import AppKit
import SwiftUI

/// Окно панели. Размер постоянен и равен максимальному развороту:
/// менять фрейм NSWindow во время пружины — значит получить рывки,
/// поэтому анимируется только содержимое внутри.
final class NotchPanel: NSPanel {
    /// Разрешает панели стать key-окном. Включается только на время
    /// разворота с полем поиска, иначе панель отобрала бы фокус
    /// у приложения, куда мы собираемся вставлять текст.
    var acceptsKeyboard = false

    override var canBecomeKey: Bool { acceptsKeyboard }
    override var canBecomeMain: Bool { false }

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
        // клики по меню-бару. Включается в Task 8, когда курсор входит в зону.
        ignoresMouseEvents = true

        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = CGRect(origin: .zero, size: contentRect.size)
        contentView = hosting
    }
}
