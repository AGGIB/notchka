import AppKit
import NotchCore

/// Единственное место, где AppKit превращается в чистые метрики.
/// Всё остальное приложение работает уже со ScreenMetrics.
enum ScreenMetricsReader {
    /// Возвращает nil, если у экрана есть чёлка (`safeAreaInsets.top > 0`),
    /// но хотя бы одна боковая область не измерена. `?? 0` в такой ситуации
    /// превратил бы неизвестность в правдоподобную ложь — вырез шириной
    /// почти во весь экран, — а не в честный отказ. NSScreen документированно
    /// отдаёт эти свойства nil на части конфигураций; экран без чёлки этому
    /// не подвержен, там nil ожидаем и безвреден, поэтому проверка условная.
    static func metrics(for screen: NSScreen) -> ScreenMetrics? {
        let topInset = screen.safeAreaInsets.top
        let leftWidth = screen.auxiliaryTopLeftArea?.width
        let rightWidth = screen.auxiliaryTopRightArea?.width
        guard topInset <= 0 || (leftWidth != nil && rightWidth != nil) else {
            return nil
        }
        return ScreenMetrics(
            frame: screen.frame,
            safeAreaTopInset: topInset,
            auxiliaryTopLeftWidth: leftWidth ?? 0,
            auxiliaryTopRightWidth: rightWidth ?? 0
        )
    }

    /// Экран с чёлкой. Первая версия живёт только на встроенном дисплее.
    static func builtInScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
    }
}
