import AppKit
import SwiftUI
import NotchCore
import NotchUI

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NotchPanel?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = ScreenMetricsReader.builtInScreen(),
              let geometry = NotchGeometryCalculator.geometry(
                  for: ScreenMetricsReader.metrics(for: screen)
              )
        else {
            NSLog("Notchka: дисплей с чёлкой не найден, панель не создана")
            return
        }

        // Окно фиксировано по максимальному развороту и центрировано над вырезом.
        let panelSize = CGSize(width: 640, height: 260)
        let origin = CGPoint(
            x: screen.frame.midX - panelSize.width / 2,
            y: screen.frame.maxY - panelSize.height
        )
        let frame = CGRect(origin: origin, size: panelSize)

        let panel = NotchPanel(
            contentRect: frame,
            rootView: DebugNotchView(
                notchWidth: geometry.notchRect.width,
                notchHeight: geometry.notchRect.height
            )
        )
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        self.panel = panel
    }
}

/// Временная вьюха: рисует силуэт в размер настоящего выреза,
/// чтобы проверить попадание панели в чёлку. Уходит в Task 9.
private struct DebugNotchView: View {
    let notchWidth: CGFloat
    let notchHeight: CGFloat

    var body: some View {
        NotchShape(
            width: notchWidth,
            height: notchHeight,
            bottomRadius: 10,
            concaveRadius: 8
        )
        .fill(.red.opacity(0.6))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
