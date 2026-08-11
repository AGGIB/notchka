import AppKit
import SwiftUI
import NotchCore
import NotchUI

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NotchPanel?
    private var controller: NotchController?

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

        // Контроллеру нужна уже существующая панель (см. NotchController),
        // поэтому окно создаётся с пустым содержимым и получает настоящее
        // сразу же, синхронно, до первой отрисовки.
        let panel = NotchPanel(contentRect: frame, rootView: EmptyView())
        panel.setFrame(frame, display: true)

        let controller = NotchController(
            geometry: geometry,
            screenFrame: screen.frame,
            panel: panel
        )
        panel.contentView = NSHostingView(
            rootView: DebugNotchView(
                controller: controller,
                notchWidth: geometry.notchRect.width,
                notchHeight: geometry.notchRect.height
            )
        )
        controller.start()
        self.controller = controller

        panel.orderFrontRegardless()
        self.panel = panel
    }
}

/// Отладочная вьюха: переводит состояние машины в геометрию силуэта,
/// чтобы визуально проверить пороги и пружины до появления настоящего
/// содержимого панели.
private struct DebugNotchView: View {
    let controller: NotchController
    let notchWidth: CGFloat
    let notchHeight: CGFloat

    var body: some View {
        NotchShape(
            width: currentWidth,
            height: currentHeight,
            bottomRadius: currentHeight > 60 ? 22 : 10,
            concaveRadius: 8
        )
        .fill(.black)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(animation, value: controller.state)
    }

    private var currentWidth: CGFloat {
        switch controller.state {
        case .closed: notchWidth
        case .peek: notchWidth + 120
        case .expanded: 620
        }
    }

    private var currentHeight: CGFloat {
        switch controller.state {
        case .closed: notchHeight
        case .peek: notchHeight + 28
        case .expanded: 200
        }
    }

    private var animation: Animation {
        if case .closed = controller.state {
            return .snappy(duration: 0.26)
        }
        return .spring(response: 0.34, dampingFraction: 0.68)
    }
}
