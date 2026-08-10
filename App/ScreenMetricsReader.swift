import AppKit
import NotchCore

/// Единственное место, где AppKit превращается в чистые метрики.
/// Всё остальное приложение работает уже со ScreenMetrics.
enum ScreenMetricsReader {
    static func metrics(for screen: NSScreen) -> ScreenMetrics {
        ScreenMetrics(
            frame: screen.frame,
            safeAreaTopInset: screen.safeAreaInsets.top,
            auxiliaryTopLeftWidth: screen.auxiliaryTopLeftArea?.width ?? 0,
            auxiliaryTopRightWidth: screen.auxiliaryTopRightArea?.width ?? 0
        )
    }

    /// Экран с чёлкой. Первая версия живёт только на встроенном дисплее.
    static func builtInScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
    }
}
