import Testing
import Foundation
@testable import MediaBridge

private let base = NowPlayingSnapshot(
    title: "Sweet Dreams", artist: "Eurythmics", album: "", duration: 216,
    elapsedTime: 10, timestamp: Date(timeIntervalSince1970: 1_000_000),
    playbackRate: 1, isPlaying: true, sourceBundleID: "com.google.Chrome",
    artworkData: nil, artworkMimeType: nil
)

@Test("коды команд совпадают с проверенными спайком")
func commandCodesMatchSpike() {
    #expect(MediaCommand.play.adapterCode == 0)
    #expect(MediaCommand.pause.adapterCode == 1)
    #expect(MediaCommand.toggle.adapterCode == 2)
}

@Test("снимок заменяет состояние целиком")
func snapshotReplacesState() {
    var accumulator = SnapshotAccumulator()
    #expect(accumulator.apply(.snapshot(base)) == base)
}

@Test("дифф правит только заданные поля")
func diffPatchesState() {
    var accumulator = SnapshotAccumulator()
    _ = accumulator.apply(.snapshot(base))
    var payload = NowPlayingPayload()
    payload.playing = false
    let updated = accumulator.apply(.diff(payload))
    #expect(updated?.isPlaying == false)
    #expect(updated?.title == "Sweet Dreams")
}

@Test("дифф до первого снимка не выдумывает состояние")
func accumulatorDiffBeforeSnapshotIsIgnored() {
    var accumulator = SnapshotAccumulator()
    var payload = NowPlayingPayload()
    payload.playing = true
    #expect(accumulator.apply(.diff(payload)) == nil)
}

@Test("пустой снимок означает конец сессии")
func emptySnapshotClearsState() {
    var accumulator = SnapshotAccumulator()
    _ = accumulator.apply(.snapshot(base))
    #expect(accumulator.apply(.snapshot(nil)) == nil)
    #expect(accumulator.current == nil)
}

@Test("временная осечка не стирает последний известный трек")
func transientFailureKeepsState() {
    var accumulator = SnapshotAccumulator()
    _ = accumulator.apply(.snapshot(base))
    #expect(accumulator.apply(.transientFailure("timed out")) == base)
    #expect(accumulator.current == base)
}

@Test("неопознанная строка не меняет состояние")
func unrecognisedLineKeepsState() {
    var accumulator = SnapshotAccumulator()
    _ = accumulator.apply(.snapshot(base))
    #expect(accumulator.apply(.unrecognized("шум")) == base)
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
