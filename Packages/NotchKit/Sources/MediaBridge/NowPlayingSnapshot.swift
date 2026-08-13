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
    /// Для источников, рендерящих медиа в отдельном вспомогательном
    /// процессе (см. `parentApplicationBundleID`), это bundle id именно
    /// помощника, а не самого приложения — таким его отдаёт MediaRemote.
    public var sourceBundleID: String
    public var artworkData: Data?
    public var artworkMimeType: String?
    /// Bundle id родительского приложения, если `sourceBundleID` — это
    /// вспомогательный процесс. Находка Task 4: Safari рендерит медиа в
    /// процессе `com.apple.WebKit.GPU`, и только это поле указывает на
    /// `com.apple.Safari` — само приложение, которое стоит показывать
    /// пользователю. nil значит, что адаптер не прислал родителя: либо
    /// sourceBundleID уже и есть настоящее приложение, либо адаптер не
    /// распознал в источнике чей-то вспомогательный процесс.
    public var parentApplicationBundleID: String?

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
        artworkMimeType: String?,
        parentApplicationBundleID: String? = nil
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
        self.parentApplicationBundleID = parentApplicationBundleID
    }
}
