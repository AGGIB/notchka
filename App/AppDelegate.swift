import AppKit
import SwiftUI
import NotchCore
import NotchUI
import MediaBridge
import NotchStore
import ClipboardKit
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

    /// Служба истории буфера обмена. Optional, а не `let` с прямой
    /// инициализацией, как у `musicModel`: `NotchDatabase.init` и `migrate()`
    /// бросают (например, при нехватке места на диске), а отказ здесь не
    /// должен ронять всё приложение — чёлка и музыка вполне работают без
    /// истории буфера. Поднимается в startClipboardService(), см. её doc.
    private var clipboardService: ClipboardService?

    /// Репозиторий истории буфера — тот же экземпляр, что получает
    /// ClipboardService. Второе соединение с той же базой заводить незачем:
    /// DatabaseQueue сериализует доступ сам, поэтому один репозиторий вполне
    /// обслуживает и опрос пастборда, и вкладку буфера (см.
    /// startClipboardService() и refreshNotchScreen()).
    private var clipboardRepository: ClipboardRepository?

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
        startClipboardService()
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
        // Страховка по сроку. `signal(SIGTERM, SIG_IGN)` выше сделан на всю
        // жизнь процесса, поэтому если остановка адаптера подвиснет — скажем,
        // актор занят незавершённой командой, — то exit(0) ниже не случится
        // никогда, и `pkill` перестанет убивать приложение вовсе. До этого
        // обработчика SIGTERM убивал гарантированно, и терять это свойство
        // нельзя: осиротевший подпроцесс дешевле неубиваемого приложения.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.shutdownDeadline) {
            exit(1)
        }
        // Синхронно и сразу: остановка таймеров не требует ожидания, в
        // отличие от адаптера музыки ниже, — тот же уклад, что и у
        // musicModel.stopAdapter(), но без async.
        clipboardService?.stop()
        Task {
            await musicModel.stopAdapter()
            exit(0)
        }
    }

    /// Сколько ждём корректной остановки адаптера, прежде чем выйти силой.
    /// Спайк намерил, что адаптер завершается по SIGINT меньше чем за секунду,
    /// так что двух хватает с запасом на планирование.
    private static let shutdownDeadline: TimeInterval = 2

    /// Поднимает хранилище истории буфера и запускает слежение за
    /// пастбордом (см. ClipboardService).
    ///
    /// Отдельным методом, а не прямой инициализацией свойства, как у
    /// musicModel: `NotchDatabase.init` и `migrate()` бросают, а брошенное
    /// внутри инициализатора хранимого свойства уронило бы весь процесс
    /// запуска приложения. Отказ здесь — не повод не показывать чёлку и не
    /// играть музыку, поэтому ошибка только логируется, а служба остаётся
    /// не запущенной.
    private func startClipboardService() {
        do {
            let location = StoreLocation(bundleID: "kz.mobilefirst.notchka")
            let database = try NotchDatabase(location: location)
            try database.migrate()
            let repository = ClipboardRepository(database: database, blobs: BlobStore(location: location))
            let service = ClipboardService(repository: repository)
            service.start()
            clipboardService = service
            clipboardRepository = repository
        } catch {
            Self.logger.error("не удалось поднять хранилище истории буфера: \(error, privacy: .public)")
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
        // Модель буфера строится один раз здесь же, вместе с контроллером —
        // не в свойстве AppDelegate, как musicModel: репозиторий появляется
        // позже, в startClipboardService(), а не в момент инициализации
        // AppDelegate, так что готовый экземпляр musicModel-стиля завести
        // нельзя. Дальше она живёт внутри NotchRootView ровно тот же срок,
        // что и сам контроллер — повторные вызовы refreshNotchScreen() (смена
        // экрана) сюда не доходят, см. ранний return выше.
        let clipboardModel = clipboardRepository.map { repository in
            ClipboardViewModel(repository: repository) { [weak self] in
                // Служба помечает наше собственное изменение пастборда как
                // прочитанное. Иначе достанутая из истории картинка через
                // доли секунды вернётся в неё вторым элементом: с пастборда
                // она приходит в другом представлении, хеш не совпадает, и
                // дедупликация её не ловит.
                self?.clipboardService?.ignoreOwnPasteboardWrite()
            }
        }
        panel.contentView = NSHostingView(
            rootView: NotchRootView(
                controller: controller, notchSize: geometry.notchRect.size,
                musicModel: musicModel, clipboardModel: clipboardModel
            )
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

    /// Убирает панель вместе с контроллером: монитор курсора и хоткей
    /// останавливаются явно — без чёлки на экране им нечего делать.
    ///
    /// Явно, а не через deinit, и close() вместо orderOut(nil), потому что
    /// обнуление ссылок здесь никого не освобождает. orderOut прячет окно, но
    /// оставляет его в списке окон приложения, а contentView панели держит
    /// NotchRootView и через него контроллер. Раньше отсюда уходили, обнулив
    /// обе ссылки, — и монитор курсора с зарегистрированным хоткеем продолжали
    /// жить в недостижимом контроллере. При возвращении чёлки создавался
    /// второй контроллер и регистрировал хоткей поверх ещё живого первого.
    private func teardownPanel() {
        // Порядок обязателен: сначала глушим источники событий, иначе
        // сработавший в процессе разбора хоткей или движение курсора позвали бы
        // handle() и через него syncMouseHandling() на уже закрываемом окне.
        controller?.stop()
        panel?.contentView = nil
        panel?.close()
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
    /// `nil`, когда startClipboardService() не смог поднять хранилище (см.
    /// её doc в AppDelegate) — вкладка буфера в этом случае показывает
    /// TabPlaceholderView вместо ленты, тем же путём, что и ещё не
    /// подключённые заметки и пины.
    let clipboardModel: ClipboardViewModel?

    /// Разрешение Accessibility, прочитанное на момент последней проверки.
    /// AXIsProcessTrusted() не даёт уведомлений о своей выдаче, поэтому само
    /// объявление этого свойства не гарантирует актуальность значения —
    /// её держит цикл опроса в .task(id: isClipboardTabActive) ниже, пока
    /// вкладка буфера открыта и разрешения ещё нет.
    @State private var isAccessibilityTrusted = AccessibilityPermission.isTrusted

    /// Минимальный промежуток между периодическими пересинхронизациями (см.
    /// MusicViewModel.resync() и .task(id: isExpanded) ниже). Каждая дёргает
    /// отдельный процесс perl — вшестеро чаще, чем раз в секунду, которым
    /// тикает позиция трека, плодить их незачем.
    private static let resyncInterval: TimeInterval = 5

    /// Раскрыта ли панель, независимо от того, какая именно вкладка внутри.
    /// Брифом задано именно такое условие для обновления позиции трека:
    /// `if case .expanded = controller.state`, без привязки к вкладке.
    private var isExpanded: Bool {
        if case .expanded = controller.state { return true }
        return false
    }

    /// Раскрыта ли панель именно на вкладке буфера — в отличие от isExpanded
    /// выше, здесь важна конкретная вкладка: лента должна перечитывать
    /// историю при своём открытии, а не при любом раскрытии панели.
    private var isClipboardTabActive: Bool {
        if case .expanded(.clipboard) = controller.state { return true }
        return false
    }

    var body: some View {
        NotchPanelView(
            state: controller.state,
            notchSize: notchSize,
            accent: musicModel.accent,
            // Тот же путь, что и клавиатура: клик по колонке вкладок и
            // ⌘1…⌘4/⇥ оба заканчиваются одним и тем же handle(.selectTab(_:))
            // на контроллере (см. PanelKeyHandler → KeyBinding → NotchPanel
            // .keyDown(with:) для клавиатурной стороны).
            onSelectTab: { tab in controller.handle(.selectTab(tab)) }
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
            // Пересинхронизация ровно один раз здесь, до входа в цикл, а не
            // внутри while ниже: там она звала бы get на каждую секунду
            // раскрытой панели, а это отдельный процесс perl на каждый тик
            // (см. MusicViewModel.resync()). Этого разового вызова хватает
            // на случай «интерцепция уже закончилась к моменту, когда
            // пользователь открыл панель» — не дожидаясь первого тика
            // периодической пересинхронизации в соседнем .task(id:) ниже.
            await musicModel.resync()
            while !Task.isCancelled {
                musicModel.refreshPosition()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .task(id: isExpanded) {
            // Периодическая пересинхронизация — отдельным .task(id:) на том
            // же isExpanded, а не веткой внутри секундного цикла позиции
            // выше: у неё свой период (Self.resyncInterval, не чаще раза в
            // 5 секунд — get поднимает отдельный процесс perl, ежесекундно
            // так нельзя), и раздельные циклы не завязывают один период на
            // другой. Ловит случай «интерцепция закончилась, пока панель уже
            // была открыта» — разовый вызов в соседнем .task(id:) выше
            // случается только в момент раскрытия и этот случай не видит.
            guard isExpanded else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.resyncInterval))
                guard !Task.isCancelled else { break }
                await musicModel.resync()
            }
        }
        .task(id: isClipboardTabActive) {
            // Не тикающий цикл, в отличие от позиции трека выше: истории
            // буфера не нужно опрашивать раз в секунду, она читается один
            // раз при открытии вкладки (решение №4 постановки) — .task(id:)
            // и так перезапустит этот блок при каждом новом открытии, ничего
            // отдельно повторять не нужно.
            guard isClipboardTabActive, let clipboardModel else { return }
            await clipboardModel.refresh()
        }
        .task(id: isClipboardTabActive) {
            // Тикающий цикл, в отличие от refresh() выше, — и здесь это
            // обязательно, а не выбор стиля: уход курсора из раскрытой
            // панели её не закрывает (см. NotchStateMachine — «работа с
            // лентой буфера подразумевает движение мыши куда угодно»), а
            // клик по «Открыть настройки» не бросает Esc и не жмёт хоткей.
            // Значит пользователь может уйти в Настройки и вернуться, ни разу
            // не покинув .expanded(.clipboard) — единственный способ
            // подхватить выданное разрешение в этом случае без перезапуска
            // приложения (решение №3 постановки задачи 10) — переопрашивать
            // самим, пока вкладка буфера открыта. Раз в секунду — тот же
            // порядок, что и у позиции трека в соседнем task(id:) выше.
            // Проверка происходит сразу при входе на вкладку, без ожидания
            // первого тика, и цикл останавливается сам, как только
            // разрешение выдано: опрашивать после этого нечего, а в покое
            // приложение обязано спать — то же правило, что и у refresh() выше.
            guard isClipboardTabActive, clipboardModel != nil else { return }
            while !Task.isCancelled {
                isAccessibilityTrusted = AccessibilityPermission.isTrusted
                guard !isAccessibilityTrusted else { return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Вкладки музыки и буфера подключены по-настоящему; заметки и пины
    /// ждут своих планов и показывают общую заглушку (TabPlaceholderView) —
    /// оболочка не должна знать, что у них внутри.
    ///
    /// switch без default — намеренно. С default новый case NotchTab
    /// молча провалился бы в заглушку без единой ошибки компиляции и без
    /// падения теста: именно эта дыра описана в задаче про колонку вкладок.
    /// Явные case делают то же самое надёжно — забытую вкладку поймает
    /// компилятор, а не пользователь месяц спустя.
    @ViewBuilder
    private func content(for tab: NotchTab) -> some View {
        switch tab {
        case .music:
            MusicTabView(
                track: musicModel.track,
                position: musicModel.position,
                artwork: musicModel.artwork,
                accent: musicModel.accent,
                onPreviousTrack: { musicModel.previousTrack() },
                onTogglePlayback: { musicModel.togglePlayback() },
                onNextTrack: { musicModel.nextTrack() }
            )
        case .clipboard:
            if let clipboardModel {
                clipboardContent(model: clipboardModel)
            } else {
                // Вкладка готова, но хранилище не открылось (см.
                // startClipboardService). «Скоро появится» здесь было бы
                // неправдой о причине.
                TabPlaceholderView(tab: tab, message: "Хранилище недоступно")
            }
        case .notes, .pins:
            TabPlaceholderView(tab: tab)
        }
    }

    /// Лента или объяснение про разрешение — что из двух, решает чистая
    /// функция ClipboardTabContent.resolve в NotchUI: здесь только читаем её
    /// результат, а сам выбор проверен тестом без окна (см.
    /// PermissionPromptViewTests).
    @ViewBuilder
    private func clipboardContent(model: ClipboardViewModel) -> some View {
        switch ClipboardTabContent.resolve(isAccessibilityTrusted: isAccessibilityTrusted) {
        case .ribbon:
            ClipboardTabView(
                cards: model.cards,
                selected: model.selectedID,
                accent: musicModel.accent,
                onActivate: { id in
                    // pasteTarget, а не захваченное при развороте: между
                    // разворотом и кликом пользователь успевает сменить
                    // приложение, см. его doc в NotchController.
                    model.activate(id: id, frontmostApplication: controller.pasteTarget)
                },
                onCopyOnly: { id in model.copyOnly(id: id) }
            )
        case .permissionPrompt:
            PermissionPromptView(
                onRequestPermission: {
                    // Системный диалог — только по этому явному нажатию,
                    // никогда сам по себе при запуске или раскрытии панели.
                    // Возвращаемое значение присваиваем сразу: оно почти
                    // всегда false (диалог только появился, пользователь ещё
                    // не ответил), но если разрешение уже было выдано другим
                    // путём — не заставляем ждать лишний тик опроса.
                    isAccessibilityTrusted = AccessibilityPermission.requestIfNeeded()
                },
                onOpenSettings: AccessibilityPermission.openSettings
            )
        }
    }
}
