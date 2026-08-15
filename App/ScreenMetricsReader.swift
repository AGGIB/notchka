import AppKit
import NotchCore

/// The single place where AppKit turns into pure metrics.
/// The rest of the app works only with ScreenMetrics.
enum ScreenMetricsReader {
    /// Returns nil if the screen has a notch (`safeAreaInsets.top > 0`)
    /// but at least one side area isn't measured. `?? 0` in that case
    /// would turn the unknown into a plausible lie — a notch almost as wide
    /// as the whole screen — instead of an honest refusal. NSScreen is documented
    /// to return nil for these properties on some configurations; a screen without a notch
    /// isn't subject to that, nil there is expected and harmless, hence the conditional check.
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

    /// The screen with a notch. The first version only lives on the built-in display.
    static func builtInScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
    }
}
