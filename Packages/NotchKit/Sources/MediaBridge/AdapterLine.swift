import Foundation

/// Partial payload: the adapter sends diffs where only changed fields are set,
/// so every property is optional and "absent" does not mean "reset to zero".
public struct NowPlayingPayload: Sendable, Equatable, Decodable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var duration: TimeInterval?
    public var elapsedTime: TimeInterval?
    public var timestamp: Date?
    public var playbackRate: Double?
    public var playing: Bool?
    public var bundleIdentifier: String?
    public var artworkData: Data?
    public var artworkMimeType: String?
    /// Bundle id of the parent application — arrives separately from
    /// `bundleIdentifier` when the source is actually a helper
    /// process. Task 4 finding: Safari reports `bundleIdentifier ==
    /// "com.apple.WebKit.GPU"` (the rendering process), while this field carries
    /// the real app, `"com.apple.Safari"`. For most
    /// sources (Chrome directly, etc.) the adapter doesn't send this field
    /// at all — nil, not an empty string.
    public var parentApplicationBundleIdentifier: String?

    public init() {}

    /// An empty payload means "no session", not "track with no title".
    public var isEmpty: Bool {
        title == nil && artist == nil && album == nil && duration == nil
            && elapsedTime == nil && timestamp == nil && playbackRate == nil
            && playing == nil && bundleIdentifier == nil && artworkData == nil
            && artworkMimeType == nil && parentApplicationBundleIdentifier == nil
    }

    /// Applies a diff onto an existing snapshot. Returns nil if there was no
    /// snapshot yet: a diff alone doesn't describe a full track.
    ///
    /// `now` is used in exactly one case — see the timestamp rebinding block
    /// below; for any other transition it has no effect at all.
    public func applied(to base: NowPlayingSnapshot?, now: Date) -> NowPlayingSnapshot? {
        guard var snapshot = base else { return nil }
        let wasPlaying = snapshot.isPlaying
        if let title { snapshot.title = title }
        if let artist { snapshot.artist = artist }
        if let album { snapshot.album = album }
        if let duration { snapshot.duration = duration }
        if let elapsedTime { snapshot.elapsedTime = elapsedTime }
        if let timestamp { snapshot.timestamp = timestamp }
        if let playbackRate { snapshot.playbackRate = playbackRate }
        if let playing { snapshot.isPlaying = playing }
        if let bundleIdentifier { snapshot.sourceBundleID = bundleIdentifier }
        if let artworkData { snapshot.artworkData = artworkData }
        if let artworkMimeType { snapshot.artworkMimeType = artworkMimeType }
        if let parentApplicationBundleIdentifier {
            snapshot.parentApplicationBundleID = parentApplicationBundleIdentifier
        }

        // The play/pause toggle arrives as a pair of diffs (see the "Update
        // stream" section of the spike): the first line carries only {"playing":true},
        // with no timestamp of its own; the second delivers the real one shortly
        // after. Without rebinding here, snapshot.timestamp would stay whatever it
        // was before this diff — i.e. the moment the track was PAUSED,
        // not the moment it resumed. PlaybackPosition.current
        // extrapolates "now − timestamp" only while isPlaying is true, so
        // the entire pause duration turns into phantom progress, and the bar
        // jumps to the end of the track before the second diff line arrives. The
        // condition is deliberately narrow: only the false→true transition, and only
        // when the diff itself didn't send a timestamp — in every other case the
        // adapter's value (or lack thereof) is left as is.
        if timestamp == nil, playing == true, !wasPlaying {
            snapshot.timestamp = now
        }
        return snapshot
    }

    /// Full snapshot built from the payload. Missing fields are filled neutrally:
    /// the adapter omits empty strings and zero durations.
    public func asSnapshot() -> NowPlayingSnapshot? {
        guard !isEmpty else { return nil }
        return NowPlayingSnapshot(
            title: title ?? "",
            artist: artist ?? "",
            album: album ?? "",
            duration: duration ?? 0,
            elapsedTime: elapsedTime ?? 0,
            timestamp: timestamp ?? Date(timeIntervalSince1970: 0),
            playbackRate: playbackRate ?? 0,
            isPlaying: playing ?? false,
            sourceBundleID: bundleIdentifier ?? "",
            artworkData: artworkData,
            artworkMimeType: artworkMimeType,
            parentApplicationBundleID: parentApplicationBundleIdentifier
        )
    }
}

/// One line of adapter output.
public enum AdapterLine: Sendable, Equatable {
    /// Full state. nil means "no session".
    case snapshot(NowPlayingSnapshot?)
    case diff(NowPlayingPayload)
    /// The adapter is alive, but this particular response didn't come through — the channel shouldn't be dropped.
    case transientFailure(String)
    case unrecognized(String)

    private struct Envelope: Decodable {
        let type: String
        let diff: Bool
        let payload: NowPlayingPayload
    }

    /// Known timeout text from the adapter. Checked before parsing JSON
    /// to distinguish a transient misfire from invalid input.
    private static let adapterTimeoutMessage = "timed out"

    public static func parse(_ line: String) -> AdapterLine {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unrecognized(line) }

        guard let data = trimmed.data(using: .utf8) else { return .unrecognized(line) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // The timeout check happens after attempting to parse JSON. If the line
        // is a valid JSON object, it's not an adapter misfire, just data.
        // Only plain text can be a timeout error.
        if let envelope = try? decoder.decode(Envelope.self, from: data) {
            return envelope.diff ? .diff(envelope.payload) : .snapshot(envelope.payload.asSnapshot())
        }

        // A misfire is printed by the adapter as plain text, not JSON. Distinguishing it
        // from garbage matters: the supervisor shouldn't treat this as a channel failure.
        if trimmed.contains(adapterTimeoutMessage) { return .transientFailure(trimmed) }

        return .unrecognized(line)
    }

    /// Parses the bare payload of the `get` command — a separate path from
    /// `parse(_:)` above, not a branch inside it.
    ///
    /// `parse(_:)` is built for `stream` lines and always expects the envelope
    /// `{"type":..,"diff":..,"payload":..}`; `get` prints the `NowPlayingPayload`
    /// as-is, with no envelope at all, so `Envelope.decode` on such
    /// a line won't find the `payload` key and will fail — while the line itself
    /// is perfectly valid JSON, so `parse(_:)` would end up at `.unrecognized`,
    /// not at a misfire or a snapshot. Mixing the two formats into one method
    /// would mean either weakening Envelope down to optional fields (in which case
    /// a stream line without "type" would also silently pass through as a payload),
    /// or guessing based on which keys are present — both options are worse than
    /// an honest, separate, clearly named path.
    ///
    /// Exists for one-off resynchronization (see `AdapterProcess.get()`
    /// / `AdapterProvider.refresh()`): a full `NowPlayingSnapshot?` is needed,
    /// not `AdapterLine` — the caller has nowhere to get the `diff` flag
    /// for an envelope that this format never had in the first place.
    public static func parseSnapshot(_ line: String) -> NowPlayingSnapshot? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(NowPlayingPayload.self, from: data) else { return nil }
        return payload.asSnapshot()
    }
}
