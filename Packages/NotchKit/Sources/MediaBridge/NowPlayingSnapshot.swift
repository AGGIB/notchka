import Foundation

/// Playback state as of the adapter's last event.
///
/// `elapsedTime` and `timestamp` are intentionally stored as a pair: the
/// adapter hands them over as a snapshot and doesn't update them between
/// events, so a position without a timestamp is meaningless. Live
/// calculation lives in `PlaybackPosition`.
public struct NowPlayingSnapshot: Sendable, Equatable {
    public var title: String
    public var artist: String
    public var album: String
    public var duration: TimeInterval
    public var elapsedTime: TimeInterval
    public var timestamp: Date
    public var playbackRate: Double
    public var isPlaying: Bool
    /// Bundle id of the source app: the UI uses it to show where playback
    /// is coming from. For sources that render media in a separate helper
    /// process (see `parentApplicationBundleID`), this is the bundle id of
    /// the helper itself, not the app — that's how MediaRemote reports it.
    public var sourceBundleID: String
    public var artworkData: Data?
    public var artworkMimeType: String?
    /// Bundle id of the parent application, if `sourceBundleID` is a
    /// helper process. Task 4 finding: Safari renders media in the
    /// `com.apple.WebKit.GPU` process, and only this field points to
    /// `com.apple.Safari` — the actual app that should be shown to the
    /// user. nil means the adapter didn't supply a parent: either
    /// sourceBundleID is already the real app, or the adapter didn't
    /// recognize the source as someone's helper process.
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
