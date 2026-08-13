import AppKit
import Observation
import SwiftUI
import MediaBridge
import NotchUI

/// Держит текущий трек и переводит его в то, что показывает вкладка музыки.
///
/// Живёт весь срок работы приложения — создаётся один раз в AppDelegate и не
/// привязана к геометрии чёлки: адаптеру и его perl-подпроцессу нет дела до
/// того, куда сейчас смотрит панель или есть ли у экрана вырез вообще.
@MainActor
@Observable
final class MusicViewModel {
    private(set) var track: TrackDisplay?
    private(set) var artwork: Image?
    private(set) var accent: Color = .white
    private(set) var position: TimeInterval = 0

    @ObservationIgnored private let provider: any NowPlayingProvider
    @ObservationIgnored private var snapshot: NowPlayingSnapshot?
    @ObservationIgnored private var pump: Task<Void, Never>?

    init(provider: any NowPlayingProvider) {
        self.provider = provider
    }

    /// Поднимает насос подписки. Вызывать один раз за жизнь модели.
    ///
    /// `AdapterProvider.snapshots` не мультикастит (см. её doc-комментарий):
    /// повторная подписка разделила бы уже идущие снимки между двумя
    /// читателями вместо дублирования их обоим. Защита ниже делает start()
    /// идемпотентным — вызывающая сторона (AppDelegate) сама зовёт его
    /// ровно один раз, но пусть это гарантирует и сам метод, а не только
    /// дисциплина вызывающего.
    func start() {
        guard pump == nil else { return }
        pump = Task { [weak self] in
            guard let self else { return }
            // Task {}, созданный внутри @MainActor-метода, сам изолирован на
            // MainActor (наследует изоляцию места создания) — второй прыжок
            // через MainActor.run здесь был бы лишним поверх уже верного
            // актора, а не дополнительной гарантией.
            for await snapshot in await provider.snapshots {
                apply(snapshot)
            }
        }
    }

    deinit {
        // Тот же приём и то же обоснование, что в HotkeyCenter.deinit: deinit
        // класса на @MainActor компилятор считает nonisolated, поэтому
        // прямое обращение к pump здесь не пройдёт проверку Swift 6 без
        // явного assumeIsolated.
        MainActor.assumeIsolated {
            pump?.cancel()
        }
    }

    /// Гарантированно останавливает адаптер перед выходом из приложения.
    ///
    /// Отдельно от deinit не только формально (deinit не async и не может
    /// дождаться завершения provider.shutdown()), но и по существу: полагаться
    /// на то, что deinit вообще выполнится, нельзя — AppKit завершает процесс
    /// через exit(), в обход раскрутки стека Swift. Вызывающая сторона
    /// (AppDelegate, обработчик SIGTERM) обязана дождаться этого метода,
    /// прежде чем реально завершать процесс.
    func stopAdapter() async {
        pump?.cancel()
        await provider.shutdown()
    }

    /// Позиция пересчитывается по запросу, а не хранится тикающей: адаптер
    /// отдаёт её снимком и между событиями не обновляет (см.
    /// PlaybackPosition), поэтому единственный честный способ — считать от
    /// метки времени заново при каждом вызове. Вызывающая сторона
    /// (NotchRootView) обязана дёргать это только пока панель раскрыта — в
    /// покое приложение обязано спать, а не пересчитывать позицию трека,
    /// который никто не видит.
    func refreshPosition(now: Date = Date()) {
        guard let snapshot else { return }
        position = PlaybackPosition.current(in: snapshot, at: now)
    }

    /// Разовая пересинхронизация в обход потока и его накопителя.
    ///
    /// Существует ради дефекта, найденного владельцем на живой машине:
    /// короткое уведомление со звуком (например, WhatsApp Web) перехватывает
    /// сессию «сейчас играет», а по его завершении система иногда не
    /// присылает событие о возврате к прежнему источнику — долгоживущий
    /// поток адаптера в этот момент жив, но навсегда застревает на данных
    /// уведомления, потому что событию просто неоткуда взяться. Починить это
    /// разбором того, что уже пришло по потоку, нельзя: там ничего нет (см.
    /// doc NowPlayingProvider.refresh()).
    ///
    /// Результат применяется через apply(_:) — тем же путём, каким сюда
    /// попадают обычные снимки из потока в start(): трек, обложка, акцент и
    /// позиция обновляются одинаково независимо от источника значения.
    /// Вызывающая сторона (NotchRootView) обязана дёргать это только пока
    /// панель раскрыта — тот же принцип «спать в покое», что и у
    /// refreshPosition() выше: get поднимает отдельный процесс perl, и
    /// оправдан он только тогда, когда результат вообще кто-то увидит.
    func resync() async {
        do {
            apply(try await provider.refresh())
        } catch {
            // Осечка разового запроса — не повод гасить экран: последний
            // известный трек честнее пустоты. Провайдер уже записал причину
            // в журнал, дублировать её здесь нечем.
        }
    }

    /// Разворачивает/приостанавливает воспроизведение.
    ///
    /// Раньше это была единственная команда, которой управлял UI, и здесь
    /// же объяснялось, почему для неё нет типа TrackControl: кнопки
    /// перемотки были убраны из MusicTabView (см. тогдашний doc у
    /// playPauseButton там) вместе с TrackControl (previous/playPause/next)
    /// — обе стрелки слали тот же код toggle, что и play/pause, потому что
    /// спайк коды переключения треков эмпирически не проверял, а раз других
    /// команд не осталось, в enum и switch по нему тоже не было нужды.
    ///
    /// Коды next/previous с тех пор подтверждены отдельно (см. doc
    /// MediaCommand), кнопки вернулись — см. nextTrack()/previousTrack()
    /// ниже. TrackControl намеренно не восстановлен: с тремя командами он
    /// был бы просто вторым именем для того же набора значений, что уже
    /// есть в MediaCommand, без собственной семантики поверх него — UI и
    /// так вызывает три разных метода на три разных нажатия, оборачивать их
    /// в четвёртый enum, который тут же разбирается обратно switch'ем на те
    /// же три MediaCommand, нечего.
    func togglePlayback() {
        Task { try? await provider.send(.toggle) }
    }

    /// Следующий трек. Код — см. MediaCommand.next.adapterCode; там же doc
    /// о том, как и кем он подтверждён (не тем же спайком, что play/pause/
    /// toggle).
    func nextTrack() {
        Task { try? await provider.send(.next) }
    }

    /// Предыдущий трек. Код — см. MediaCommand.previous.adapterCode; там же
    /// doc о том, как и кем он подтверждён (не тем же спайком, что
    /// play/pause/toggle).
    func previousTrack() {
        Task { try? await provider.send(.previous) }
    }

    private func apply(_ snapshot: NowPlayingSnapshot?) {
        self.snapshot = snapshot
        guard let snapshot else {
            track = nil
            artwork = nil
            accent = .white
            return
        }
        track = TrackDisplay(
            title: snapshot.title,
            artist: snapshot.artist,
            source: Self.sourceName(for: snapshot),
            duration: snapshot.duration,
            isPlaying: snapshot.isPlaying
        )
        updateArtwork(from: snapshot)
        refreshPosition()
    }

    private func updateArtwork(from snapshot: NowPlayingSnapshot) {
        guard let data = snapshot.artworkData,
              let image = NSImage(data: data),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            artwork = nil
            return
        }
        artwork = Image(nsImage: image)
        if let colour = ArtworkAccent.color(from: cgImage) { accent = colour }
    }

    /// Человеческое имя источника вместо bundle id.
    ///
    /// Safari — и в принципе любой браузер, рендерящий медиа в отдельном
    /// вспомогательном процессе — отдаёт MediaRemote bundle id именно этого
    /// процесса, а не свой собственный. Эмпирическая находка Task 4:
    /// `sourceBundleID == "com.apple.WebKit.GPU"` для Safari, настоящее
    /// приложение приходит отдельным полем, `parentApplicationBundleID`.
    ///
    /// Здесь сознательно используется это поле, присланное адаптером, а не
    /// жёстко зашитая таблица «известный helper → имя»: такая таблица решала
    /// бы задачу только для уже виденных браузеров и воспроизводила бы эту
    /// же ошибку для любого прежде не встречавшегося вспомогательного
    /// процесса. Когда parentApplicationBundleID есть — используем его.
    /// Когда его нет (sourceBundleID уже и есть настоящее приложение, или
    /// адаптер не распознал в источнике чей-то помощник), используем
    /// sourceBundleID как раньше; если и он не резолвится в приложение через
    /// NSWorkspace, показываем bundle id текстом как есть — не самое
    /// красивое, но честное поведение, не хуже того, что было до этой
    /// задачи для любого нераспознанного источника.
    private static func sourceName(for snapshot: NowPlayingSnapshot) -> String {
        let bundleID = snapshot.parentApplicationBundleID ?? snapshot.sourceBundleID
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        return FileManager.default.displayName(atPath: url.path)
    }
}
