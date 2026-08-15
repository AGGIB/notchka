/// Playback control command.
///
/// The codes were confirmed empirically, not taken from a framework header —
/// but not in one and the same verification session. `play`/`pause`/`toggle` are
/// from the original spike: `play` and `pause` are idempotent, `toggle` inverts
/// the state on every call. `next`/`previous` were confirmed separately and
/// later, by sending commands to a YouTube video playing in Safari: in both
/// cases the track actually changed, in the matching direction. The method is
/// the same — empirical, not documentation or header-reading — but the
/// session was different, and verification only covered one source.
/// "Previous" behavior differs across players (where there's no track before
/// the current one, it usually rewinds to the start), but that's a property
/// of the players themselves, not of this code.
///
/// The lack of exactly this kind of verification once caused a bug: the
/// next/previous buttons in the UI sent the `toggle` code instead of real
/// next/previous, which nobody had confirmed at the time, and pressing "next
/// track" would actually stop the music. Because of this, the buttons were
/// temporarily removed from the UI entirely — until this verification landed
/// (see the PlayPauseButton doc in MusicTabView).
public enum MediaCommand: Sendable, Equatable {
    case play
    case pause
    case toggle
    case next
    case previous

    public var adapterCode: Int32 {
        switch self {
        case .play: 0
        case .pause: 1
        case .toggle: 2
        case .next: 4
        case .previous: 5
        }
    }
}
