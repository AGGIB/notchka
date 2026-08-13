import Testing
import Foundation
@testable import MediaBridge

private let base = NowPlayingSnapshot(
    title: "Sweet Dreams", artist: "Eurythmics", album: "", duration: 216,
    elapsedTime: 10, timestamp: Date(timeIntervalSince1970: 1_000_000),
    playbackRate: 1, isPlaying: true, sourceBundleID: "com.google.Chrome",
    artworkData: nil, artworkMimeType: nil
)

/// Тот же трек, но на паузе — нужен отдельным значением для тестов на
/// перепривязку метки времени ниже: без перехода isPlaying false→true
/// перепривязка не должна срабатывать вовсе.
private let pausedBase = NowPlayingSnapshot(
    title: "Sweet Dreams", artist: "Eurythmics", album: "", duration: 216,
    elapsedTime: 10, timestamp: Date(timeIntervalSince1970: 1_000_000),
    playbackRate: 1, isPlaying: false, sourceBundleID: "com.google.Chrome",
    artworkData: nil, artworkMimeType: nil
)

/// Опорное «сейчас» для вызовов apply(_:now:), где сам момент времени не
/// является предметом теста.
private let now = Date(timeIntervalSince1970: 2_000_000)

@Test("коды команд совпадают с проверенными спайком")
func commandCodesMatchSpike() {
    #expect(MediaCommand.play.adapterCode == 0)
    #expect(MediaCommand.pause.adapterCode == 1)
    #expect(MediaCommand.toggle.adapterCode == 2)
}

@Test("снимок заменяет состояние целиком")
func snapshotReplacesState() {
    var accumulator = SnapshotAccumulator()
    #expect(accumulator.apply(.snapshot(base), now: now) == base)
}

@Test("дифф правит только заданные поля")
func diffPatchesState() {
    var accumulator = SnapshotAccumulator()
    _ = accumulator.apply(.snapshot(base), now: now)
    var payload = NowPlayingPayload()
    payload.playing = false
    let updated = accumulator.apply(.diff(payload), now: now)
    #expect(updated?.isPlaying == false)
    #expect(updated?.title == "Sweet Dreams")
}

@Test("дифф до первого снимка не выдумывает состояние")
func accumulatorDiffBeforeSnapshotIsIgnored() {
    var accumulator = SnapshotAccumulator()
    var payload = NowPlayingPayload()
    payload.playing = true
    #expect(accumulator.apply(.diff(payload), now: now) == nil)
}

@Test("пустой снимок означает конец сессии")
func emptySnapshotClearsState() {
    var accumulator = SnapshotAccumulator()
    _ = accumulator.apply(.snapshot(base), now: now)
    #expect(accumulator.apply(.snapshot(nil), now: now) == nil)
    #expect(accumulator.current == nil)
}

@Test("временная осечка не стирает последний известный трек")
func transientFailureKeepsState() {
    var accumulator = SnapshotAccumulator()
    _ = accumulator.apply(.snapshot(base), now: now)
    #expect(accumulator.apply(.transientFailure("timed out"), now: now) == base)
    #expect(accumulator.current == base)
}

@Test("неопознанная строка не меняет состояние")
func unrecognisedLineKeepsState() {
    var accumulator = SnapshotAccumulator()
    _ = accumulator.apply(.snapshot(base), now: now)
    #expect(accumulator.apply(.unrecognized("шум"), now: now) == base)
}

@Test("дифф playing:true без timestamp после паузы перепривязывает метку к now")
func diffTurningPlayingOnWithoutTimestampReanchorsTimestamp() {
    var accumulator = SnapshotAccumulator()
    _ = accumulator.apply(.snapshot(pausedBase), now: now)
    var payload = NowPlayingPayload()
    payload.playing = true
    // Трек стоял на паузе 10 минут — старая timestamp сделала бы drift
    // в PlaybackPosition равным всей паузе целиком (см. описание правки).
    let resumedAt = now.addingTimeInterval(600)
    let updated = accumulator.apply(.diff(payload), now: resumedAt)
    #expect(updated?.isPlaying == true)
    #expect(updated?.timestamp == resumedAt)
}

@Test("дифф playing:true со своим timestamp не перепривязывается к now")
func diffTurningPlayingOnWithTimestampKeepsAdapterValue() {
    var accumulator = SnapshotAccumulator()
    _ = accumulator.apply(.snapshot(pausedBase), now: now)
    var payload = NowPlayingPayload()
    payload.playing = true
    let adapterTimestamp = Date(timeIntervalSince1970: 1_999_999)
    payload.timestamp = adapterTimestamp
    let updated = accumulator.apply(.diff(payload), now: now.addingTimeInterval(600))
    #expect(updated?.timestamp == adapterTimestamp)
}

@Test("дифф playing:true без флипа (уже играл) не перепривязывает метку")
func diffKeepingPlayingTrueWithoutTimestampDoesNotReanchor() {
    var accumulator = SnapshotAccumulator()
    _ = accumulator.apply(.snapshot(base), now: now)  // base.isPlaying уже true
    var payload = NowPlayingPayload()
    payload.playing = true
    let updated = accumulator.apply(.diff(payload), now: now.addingTimeInterval(600))
    #expect(updated?.timestamp == base.timestamp)
}

// `survivedLongEnoughToResetBackoff` — чистая функция сравнения дат,
// вынесенная из pump(into:) именно чтобы её можно было проверить без
// подъёма настоящего процесса адаптера (сам pump() юнит-тестом не покрыт —
// см. отчёт: до реального процесса или его правдоподобной подмены дело не
// доходит ни в одном тесте этого файла).

@Test("поток короче порога не сбрасывает нарастающую паузу")
func briefStreamDoesNotResetBackoff() {
    let opened = Date(timeIntervalSince1970: 1_000_000)
    let closedQuickly = opened.addingTimeInterval(0.2)
    #expect(AdapterProvider.survivedLongEnoughToResetBackoff(openedAt: opened, closedAt: closedQuickly) == false)
}

@Test("поток дольше порога сбрасывает нарастающую паузу")
func longStreamResetsBackoff() {
    let opened = Date(timeIntervalSince1970: 1_000_000)
    let closedLater = opened.addingTimeInterval(AdapterProvider.restartLivenessThreshold + 1)
    #expect(AdapterProvider.survivedLongEnoughToResetBackoff(openedAt: opened, closedAt: closedLater) == true)
}

@Test("поток ровно на пороге считается достаточно живым")
func thresholdBoundaryResetsBackoff() {
    let opened = Date(timeIntervalSince1970: 1_000_000)
    let closedAtThreshold = opened.addingTimeInterval(AdapterProvider.restartLivenessThreshold)
    #expect(AdapterProvider.survivedLongEnoughToResetBackoff(openedAt: opened, closedAt: closedAtThreshold) == true)
}

/// Заведомо несуществующие пути: `AdapterProcess.lines()` падает на
/// `process.run()` мгновенно (ENOENT), реального процесса не возникает —
/// тест ничего не запускает и не зависит от собранного адаптера.
private let unreachablePaths = AdapterPaths(
    perl: URL(fileURLWithPath: "/nonexistent/perl"),
    script: URL(fileURLWithPath: "/nonexistent/script.pl"),
    framework: URL(fileURLWithPath: "/nonexistent/Framework")
)

@Test("повторное обращение к snapshots не поднимает второй насос")
func repeatedSnapshotsAccessDoesNotStartSecondPump() async {
    let provider = AdapterProvider(paths: unreachablePaths)
    _ = await provider.snapshots
    _ = await provider.snapshots
    #expect(await provider.pumpsStarted == 1)
}

@Test("shutdown реально останавливает насос, а не просто просит отмены")
func shutdownStopsPumpForGood() async {
    let provider = AdapterProvider(paths: unreachablePaths)
    _ = await provider.snapshots
    await provider.shutdown()
    // Если бы shutdown только запрашивал отмену, не дожидаясь завершения,
    // следующее обращение могло бы застать насос ещё формально «активным»
    // (задача отменена, но проверка !activePump.task.isCancelled уже
    // должна была бы это заметить в любом случае) — проверяем более сильное
    // свойство: после shutdown снова поднимается настоящий новый насос.
    _ = await provider.snapshots
    #expect(await provider.pumpsStarted == 2)
}

@Test("shutdown без единого обращения к snapshots не падает")
func shutdownWithoutPriorAccessIsSafe() async {
    let provider = AdapterProvider(paths: unreachablePaths)
    await provider.shutdown()
    #expect(await provider.pumpsStarted == 0)
}

/// refresh() не throws (см. сигнатуру в NowPlayingProvider) — сбой запуска
/// get на недостижимых путях обязан свестись к nil, а не прорваться наружу
/// необработанным throw и не подвесить вызывающую сторону.
@Test("refresh на недостижимых путях не падает и возвращает nil")
func refreshOnUnreachablePathsReturnsNil() async {
    let provider = AdapterProvider(paths: unreachablePaths)
    let snapshot = await provider.refresh()
    #expect(snapshot == nil)
}
