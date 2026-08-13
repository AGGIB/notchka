import Foundation

/// Позиция воспроизведения на произвольный момент времени.
///
/// Существует потому, что адаптер отдаёт `elapsedTime` снимком и между
/// событиями его не обновляет: читать поле напрямую значит показывать
/// застывший прогресс-бар, пока не сменится трек.
public enum PlaybackPosition {
    public static func current(in snapshot: NowPlayingSnapshot, at now: Date) -> TimeInterval {
        // На паузе метка времени устаревает произвольно долго, поэтому
        // экстраполировать от неё нельзя — позиция просто замерла.
        guard snapshot.isPlaying else { return snapshot.elapsedTime }

        let drift = now.timeIntervalSince(snapshot.timestamp) * snapshot.playbackRate
        let raw = snapshot.elapsedTime + drift
        // Нулевая длительность значит «поток без конца» (радио, стрим),
        // ограничивать там нечем.
        let upperBound = snapshot.duration > 0 ? snapshot.duration : .greatestFiniteMagnitude
        return min(max(raw, 0), upperBound)
    }
}
