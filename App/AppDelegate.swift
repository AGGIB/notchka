import AppKit
import SwiftUI
import NotchCore
import NotchUI
import MediaBridge
import Dispatch
import CoreGraphics
import os

@MainActor
@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NotchPanel?
    private var controller: NotchController?
    /// Токен подписки на смену конфигурации экранов — хранится, чтобы снять
    /// подписку в deinit.
    private var screenParametersObserver: NSObjectProtocol?
    /// Токен подписки на смену активного Space — тем же путём, что и
    /// screenParametersObserver, снимается в deinit. Долг фундамента:
    /// машина состояний обрабатывает .fullScreenChanged с плана 1, но до
    /// этой подписки отправлять его было некому (см. handleActiveSpaceChange).
    private var activeSpaceObserver: NSObjectProtocol?
    /// Источник сигнала SIGTERM — хранится, иначе GCD освободит его сразу
    /// после resume() и обработчик никогда не сработает.
    private var terminationSource: (any DispatchSourceSignal)?

    /// Корень репозитория, где лежит вендоренная копия адаптера.
    ///
    /// Вычисляется от расположения этого файла на диске: сейчас приложение
    /// работает только из дерева исходников (см. AdapterPaths.vendored), и
    /// другого способа найти vendor/ нет. В плане 4 адаптер переезжает
    /// внутрь бандла приложения — тогда это единственное место обновится на
    /// путь внутри Bundle.main, а не на вычисление через #filePath.
    private static let developmentRepoRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // AppDelegate.swift -> App
            .deletingLastPathComponent()  // App -> корень репозитория
    }()

    /// Модель музыки живёт весь срок работы приложения, а не пересоздаётся
    /// вместе с панелью в refreshNotchScreen(): адаптеру и его
    /// perl-подпроцессу нет дела до геометрии чёлки, которая может пропадать
    /// и появляться (закрытая крышка, смена монитора) независимо от того,
    /// играет ли в этот момент музыка. Пересоздавать пайплайн на каждое
    /// такое событие означало бы бессмысленно перезапускать внешний процесс.
    private let musicModel = MusicViewModel(
        provider: AdapterProvider(paths: AdapterPaths.vendored(repoRoot: developmentRepoRoot))
    )

    private static let logger = Logger(subsystem: "kz.mobilefirst.notchka", category: "AppDelegate")

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installTerminationHandling()
        musicModel.start()
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

        // activeSpaceDidChangeNotification — единственный публичный сигнал о
        // смене активного Space, и он же срабатывает, когда какое-то
        // приложение (не обязательно наше — API не различает, чьё именно)
        // входит или выходит из фуллскрина: на macOS фуллскрин всегда живёт
        // в отдельном Space. Сама по себе смена Space ничего не говорит про
        // фуллскрин — переключение между двумя обычными рабочими столами
        // шлёт то же уведомление, — поэтому решение принимается по факту,
        // проверкой в handleActiveSpaceChange().
        activeSpaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleActiveSpaceChange()
            }
        }
    }

    deinit {
        // Тот же приём и то же обоснование, что в HotkeyCenter.deinit / CursorMonitor.deinit.
        MainActor.assumeIsolated {
            if let screenParametersObserver {
                NotificationCenter.default.removeObserver(screenParametersObserver)
            }
            if let activeSpaceObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(activeSpaceObserver)
            }
        }
    }

    /// SIGTERM — то, чем `pkill -x Notchka` (сейчас единственный способ
    /// остановить это приложение: у accessory-приложения без Dock-иконки
    /// нет пункта меню «Quit») завершает процесс. По умолчанию это
    /// происходит мгновенно, в обход AppKit и раскрутки стека Swift — ни
    /// один deinit не выполняется, adapter-подпроцесс осиротевает.
    /// Подтверждено ручной проверкой: без этого обработчика `pgrep -f
    /// mediaremote-adapter` после `pkill -x Notchka` находил живой процесс.
    ///
    /// `signal(SIGTERM, SIG_IGN)` обязателен и должен идти первым — иначе
    /// DispatchSourceSignal сигнал не перехватит. Это задокументированное
    /// требование GCD, а не предположение.
    private func installTerminationHandling() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            // Источник сигнала выполняет обработчик на очереди .main, то
            // есть фактически на том же потоке, что MainActor, — тот же
            // приём и то же обоснование, что в HotkeyCenter.onFire.
            MainActor.assumeIsolated { self?.shutDown() }
        }
        source.resume()
        terminationSource = source
    }

    /// Останавливает адаптер и только потом завершает процесс.
    ///
    /// Task {} здесь безопасен и не виснет: обработчик GCD выше выполняется
    /// на обычной main-очереди, а не в контексте сырого сигнала, поэтому
    /// планирование async-работы и дальнейшая раскрутка событийного цикла
    /// ничем не блокированы. exit(0), а не NSApp.terminate(_:) — нужна
    /// гарантия, что процесс не завершится раньше, чем musicModel.stopAdapter()
    /// реально отправит SIGINT адаптеру и дождётся его; NSApp.terminate(_:)
    /// такой гарантии не даёт.
    private func shutDown() {
        Task {
            await musicModel.stopAdapter()
            exit(0)
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
        let frame = panelFrame(for: screen, size: PanelMetrics.windowSize)

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
            rootView: NotchRootView(controller: controller, notchSize: geometry.notchRect.size, musicModel: musicModel)
        )
        controller.start()
        self.controller = controller

        panel.orderFrontRegardless()
        self.panel = panel
    }

    /// Реакция на смену активного Space: пересчитывает признак фуллскрина и
    /// шлёт его в машину состояний. Спека §5 требует отключать панель в
    /// фуллскрине — на чёлочном дисплее там нет ни меню-бара, ни видимого
    /// выреза, панели негде жить.
    ///
    /// Признак дешёвый и косвенный, а не гарантированный: прямого API
    /// «фуллскрин ли сейчас чужой процесс» в AppKit нет, поэтому используется
    /// предположение, что safeAreaInsets.top встроенного экрана (высота зоны
    /// меню-бара) схлопывается в 0, когда меню-бар скрыт чужим фуллскрином.
    /// Живьём на этой машине не проверено — сессия оказалась залочена, и
    /// тестовый переход в fullscreen (обычное окно, toggleFullScreen на
    /// самом себе) завис на willEnterFullScreen и не завершился ни разу.
    /// Отсюда лог на debug-уровне ниже: он даёт способ проверить дёшево,
    /// не поднимая заново весь этот пробник.
    private func handleActiveSpaceChange() {
        guard let screen = Self.hardwareBuiltInScreen() else { return }
        let topInset = screen.safeAreaInsets.top
        let isFullScreen = topInset <= 0
        Self.logger.debug(
            "Смена активного Space: safeAreaInsets.top=\(topInset, privacy: .public) → isFullScreen=\(isFullScreen, privacy: .public)"
        )
        controller?.handle(.fullScreenChanged(isFullScreen))
    }

    /// Встроенный дисплей, найденный по аппаратному признаку
    /// (CGDisplayIsBuiltin), а не по наличию выреза.
    ///
    /// ScreenMetricsReader.builtInScreen() ищет экран с safeAreaInsets.top > 0
    /// — это правильно для его задачи (нет выреза — не с чем считать
    /// геометрию), но здесь этот же inset и есть искомый сигнал: в фуллскрине
    /// он временно схлопывается в 0, и фильтр ScreenMetricsReader в этот
    /// момент перестал бы находить именно тот экран, за которым мы следим.
    private static func hardwareBuiltInScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            else { return false }
            return CGDisplayIsBuiltin(screenNumber) != 0
        }
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

/// Мост между контроллером/моделью музыки и оболочкой панели.
///
/// NotchPanelView лежит в NotchUI и принимает NotchState значением, а не
/// сам контроллер, — иначе AppKit-независимый пакет пришлось бы завязывать
/// на App-таргет. Поэтому controller.state читается именно здесь, внутри
/// body: Observation подписывается на свойство только там, где оно было
/// прочитано во время отрисовки, — вычисли это значение один раз в
/// refreshNotchScreen() и передай константой, подписки бы не возникло, и
/// панель навсегда застыла бы в состоянии на момент запуска. То же самое
/// рассуждение относится и к musicModel — это тоже @Observable, и его
/// свойства (track/position/artwork/accent) читаются здесь же, внутри body
/// (через content(for:), вызываемый непосредственно из body), а не заранее.
private struct NotchRootView: View {
    let controller: NotchController
    let notchSize: CGSize
    let musicModel: MusicViewModel

    /// Раскрыта ли панель, независимо от того, какая именно вкладка внутри.
    /// Брифом задано именно такое условие для обновления позиции трека:
    /// `if case .expanded = controller.state`, без привязки к вкладке.
    private var isExpanded: Bool {
        if case .expanded = controller.state { return true }
        return false
    }

    var body: some View {
        NotchPanelView(
            state: controller.state,
            notchSize: notchSize,
            accent: musicModel.accent
        ) { tab in
            content(for: tab)
        }
        .task(id: isExpanded) {
            // Позиция трека не хранится тикающей (см.
            // MusicViewModel.refreshPosition) — кто-то обязан дёргать
            // пересчёт периодически, пока панель действительно раскрыта.
            // .task(id:) сам отменяет предыдущий прогон и не запускает
            // новый, пока id не станет true: на закрытой и на приоткрытой
            // (peek) панели цикл ниже не крутится вовсе, а не просто ничего
            // не делает на каждом шаге — именно это спека называет «спать
            // в покое».
            guard isExpanded else { return }
            while !Task.isCancelled {
                musicModel.refreshPosition()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Вкладка музыки подключена по-настоящему; остальные три ждут своих
    /// планов и по-прежнему показывают ту же заглушку, что и раньше —
    /// оболочка не должна знать, что у них внутри.
    @ViewBuilder
    private func content(for tab: NotchTab) -> some View {
        switch tab {
        case .music:
            MusicTabView(
                track: musicModel.track,
                position: musicModel.position,
                artwork: musicModel.artwork,
                accent: musicModel.accent
            ) { musicModel.handle($0) }
        default:
            Text(String(describing: tab))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
        }
    }
}
