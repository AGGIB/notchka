import Foundation

/// Playback position at an arbitrary point in time.
///
/// Exists because the adapter reports `elapsedTime` as a snapshot and doesn't
/// update it between events: reading the field directly would mean showing a
/// frozen progress bar until the track changes.
public enum PlaybackPosition {
    public static func current(in snapshot: NowPlayingSnapshot, at now: Date) -> TimeInterval {
        // While paused, the timestamp can go stale for an arbitrary length of
        // time, so extrapolating from it isn't valid — the position is just frozen.
        guard snapshot.isPlaying else { return snapshot.elapsedTime }

        let drift = now.timeIntervalSince(snapshot.timestamp) * snapshot.playbackRate
        let raw = snapshot.elapsedTime + drift
        // Zero duration means an "endless stream" (radio, live stream),
        // there's nothing to clamp against.
        let upperBound = snapshot.duration > 0 ? snapshot.duration : .greatestFiniteMagnitude
        return min(max(raw, 0), upperBound)
    }
}
