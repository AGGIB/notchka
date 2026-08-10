import AppKit

/// Точка входа. Приложение-агент: без иконки в Dock и без главного окна,
/// вся видимая часть появится в Task 9.
@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("Notchka запущена")
    }
}
