import Testing
import Foundation
@testable import MediaBridge

private let t0 = Date(timeIntervalSince1970: 1_000_000)

private func snapshot(
    elapsed: TimeInterval,
    rate: Double,
    playing: Bool,
    duration: TimeInterval = 300
) -> NowPlayingSnapshot {
    NowPlayingSnapshot(
        title: "t", artist: "a", album: "", duration: duration,
        elapsedTime: elapsed, timestamp: t0, playbackRate: rate,
        isPlaying: playing, sourceBundleID: "com.example",
        artworkData: nil, artworkMimeType: nil
    )
}

@Test("position doesn't advance while paused")
func pausedPositionIsFrozen() {
    let paused = snapshot(elapsed: 42, rate: 0, playing: false)
    #expect(PlaybackPosition.current(in: paused, at: t0.addingTimeInterval(30)) == 42)
}

@Test("position advances from the timestamp while playing")
func playingPositionAdvances() {
    let playing = snapshot(elapsed: 42, rate: 1, playing: true)
    let position = PlaybackPosition.current(in: playing, at: t0.addingTimeInterval(10))
    #expect(abs(position - 52) < 0.001)
}

@Test("fast playback accounts for the rate")
func rateIsApplied() {
    let fast = snapshot(elapsed: 100, rate: 1.5, playing: true)
    let position = PlaybackPosition.current(in: fast, at: t0.addingTimeInterval(10))
    #expect(abs(position - 115) < 0.001)
}

@Test("position doesn't exceed the track duration")
func positionIsClampedToDuration() {
    let nearEnd = snapshot(elapsed: 295, rate: 1, playing: true, duration: 300)
    #expect(PlaybackPosition.current(in: nearEnd, at: t0.addingTimeInterval(60)) == 300)
}

@Test("negative time never appears when the clock lags behind the timestamp")
func positionNeverGoesNegative() {
    let playing = snapshot(elapsed: 5, rate: 1, playing: true)
    #expect(PlaybackPosition.current(in: playing, at: t0.addingTimeInterval(-30)) == 0)
}

@Test("zero duration doesn't clamp the position")
func zeroDurationDoesNotClamp() {
    let live = snapshot(elapsed: 10, rate: 1, playing: true, duration: 0)
    let position = PlaybackPosition.current(in: live, at: t0.addingTimeInterval(20))
    #expect(abs(position - 30) < 0.001)
}
