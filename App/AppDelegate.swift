import AppKit
import SwiftUI
import NotchCore
import NotchUI
import os

@MainActor
@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NotchPanel?
    private var controller: NotchController?
    /// Токен подписки на смену конфигурации экранов — хранится, чтобы снять
    /// подписку в deinit.
    private var screenParametersObserver: NSObjectProtocol?

    /// Постоянный размер окна — максимум, которого панель достигает в `expanded`.
    /// Именованная константа вместо литерала: то же значение понадобится
    /// плану 2 при переходе на настоящее содержимое вкладок.
    private static let maxPanelSize = CGSize(width: 640, height: 260)
    private static let logger = Logger(subsystem: "kz.mobilefirst.notchka", category: "AppDelegate")

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        refreshNotchScreen()

        // Единственное уведомление AppKit, покрывающее сразу докинг/раздокинг
        // внешнего монитора, смену разрешения и открытие/закрытие крышки —
        // все они двигают origin встроенного экрана в глобальных координатах
        // или вовсе меняют состав NSScreen.screens. Без этой подписки
        // geometry и screenFrame, снятые один раз при запуске, замирают
        // навсегда: горячая зона перестаёт совпадать с курсором, а окно —
        // с самим вырезом, как только раскладка мониторов меняется.
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshNotchScreen()
            }
        }
    }

    deinit {
        // Тот же приём и то же обоснование, что в HotkeyCenter.deinit / CursorMonitor.deinit.
        MainActor.assumeIsolated {
            if let screenParametersObserver {
                NotificationCenter.default.removeObserver(screenParametersObserver)
            }
        }
    }

    /// Приводит панель и контроллер в соответствие текущей конфигурации
    /// экранов. Вызывается при запуске и затем при каждой смене конфигурации.
    /// Три исхода: чёлка нашлась (впервые или заново, например крышка была
    /// закрыта на старте) — панель создаётся; экран с чёлкой остался, но
    /// сдвинулся или изменился — geometry и фрейм окна обновляются на месте;
    /// чёлка пропала — панель убирается, а не висит по устаревшим координатам.
    private func refreshNotchScreen() {
        guard let screen = ScreenMetricsReader.builtInScreen(),
              let metrics = ScreenMetricsReader.metrics(for: screen),
              let geometry = NotchGeometryCalculator.geometry(for: metrics)
        else {
            Self.logger.notice("Дисплей с чёлкой недоступен: панель не отображается")
            teardownPanel()
            return
        }

        // Окно фиксировано по максимальному развороту и центрировано над вырезом.
        let frame = panelFrame(for: screen, size: Self.maxPanelSize)

        if let controller, let panel {
            // Чёлка та же, но экран сдвинулся или изменился: обновляем
            // геометрию и позицию окна на месте, не пересоздавая мониторы
            // курсора и хоткея — им нечего переучивать, кроме координат.
            controller.updateGeometry(geometry, screenFrame: screen.frame)
            panel.setFrame(frame, display: true)
            return
        }

        // Контроллеру нужна уже существующая панель (см. NotchController),
        // поэтому окно создаётся с пустым содержимым и получает настоящее
        // сразу же, синхронно, до первой отрисовки.
        let panel = NotchPanel(contentRect: frame, rootView: EmptyView())

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

    private func panelFrame(for screen: NSScreen, size: CGSize) -> CGRect {
        let origin = CGPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height
        )
        return CGRect(origin: origin, size: size)
    }

    /// Убирает панель вместе с контроллером: deinit контроллера остановит
    /// монитор курсора и снимет хоткей — им нечего делать без чёлки на экране.
    private func teardownPanel() {
        panel?.orderOut(nil)
        panel = nil
        controller = nil
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var animation: Animation {
        NotchMotion.animation(for: controller.state, reduceMotion: reduceMotion)
    }
}
