import Foundation

/// Состояние текущего воспроизведения на момент последнего события адаптера.
///
/// `elapsedTime` и `timestamp` намеренно хранятся парой: адаптер отдаёт их
/// как снимок и между событиями не обновляет, поэтому позиция без метки
/// времени бессмысленна. Живой расчёт — в `PlaybackPosition`.
public struct NowPlayingSnapshot: Sendable, Equatable {
    public var title: String
    public var artist: String
    public var album: String
    public var duration: TimeInterval
    public var elapsedTime: TimeInterval
    public var timestamp: Date
    public var playbackRate: Double
    public var isPlaying: Bool
    /// Bundle id приложения-источника: по нему UI показывает, откуда играет.
    public var sourceBundleID: String
    public var artworkData: Data?
    public var artworkMimeType: String?

    public init(
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval,
        elapsedTime: TimeInterval,
        timestamp: Date,
        playbackRate: Double,
        isPlaying: Bool,
        sourceBundleID: String,
        artworkData: Data?,
        artworkMimeType: String?
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.elapsedTime = elapsedTime
        self.timestamp = timestamp
        self.playbackRate = playbackRate
        self.isPlaying = isPlaying
        self.sourceBundleID = sourceBundleID
        self.artworkData = artworkData
        self.artworkMimeType = artworkMimeType
    }
}
