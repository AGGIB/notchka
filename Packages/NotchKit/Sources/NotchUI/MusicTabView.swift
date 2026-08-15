import SwiftUI
import NotchCore

/// Time and progress formatting.
///
/// Pulled out of the view because degenerate values come from an external
/// source: duration is zero for radio streams, and position can be
/// non-numeric when clocks desync.
public enum TrackFormatting {
    public static func time(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        let (hours, minutes, secs) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    public static func progress(position: TimeInterval, duration: TimeInterval) -> Double {
        guard duration > 0, position.isFinite else { return 0 }
        return min(max(position / duration, 0), 1)
    }
}

/// What the music tab displays.
public struct TrackDisplay: Equatable, Sendable {
    public let title: String
    public let artist: String
    public let source: String
    public let duration: TimeInterval
    public let isPlaying: Bool

    public init(title: String, artist: String, source: String, duration: TimeInterval, isPlaying: Bool) {
        self.title = title
        self.artist = artist
        self.source = source
        self.duration = duration
        self.isPlaying = isPlaying
    }
}

public struct MusicTabView: View {
    private let track: TrackDisplay?
    private let position: TimeInterval
    private let artwork: Image?
    private let accent: Color
    private let onPreviousTrack: () -> Void
    private let onTogglePlayback: () -> Void
    private let onNextTrack: () -> Void

    /// Side of the artwork square. 190 pt was chosen to match the height of
    /// the expanded panel's content area, so the artwork fills nearly all of
    /// it and leaves no empty strip below it — that was the main complaint
    /// about the previous 58×58 artwork.
    ///
    /// See `PanelMetrics.contentSize(notchHeight:)` for the actual area
    /// height — the numbers are deliberately not repeated here: they already
    /// drifted out of sync with reality once, when the panel grew to add
    /// clearance for the physical notch. Not `private`, so a test checks the
    /// size's relationship to the panel instead of a comment alone: SwiftUI
    /// does not diagnose overflow in any way.
    static let artworkSize: CGFloat = 190
    /// Corner radius scaled up proportionally to the side: it was 10 pt on
    /// 58 pt (≈17%), the same ratio at 190 pt gives ≈33 pt.
    private static let artworkCornerRadius: CGFloat = 33
    private static let artworkGap: CGFloat = 16

    public init(
        track: TrackDisplay?,
        position: TimeInterval,
        artwork: Image?,
        accent: Color,
        onPreviousTrack: @escaping () -> Void,
        onTogglePlayback: @escaping () -> Void,
        onNextTrack: @escaping () -> Void
    ) {
        self.track = track
        self.position = position
        self.artwork = artwork
        self.accent = accent
        self.onPreviousTrack = onPreviousTrack
        self.onTogglePlayback = onTogglePlayback
        self.onNextTrack = onNextTrack
    }

    public var body: some View {
        if let track {
            playing(track)
        } else {
            // An honest empty screen beats a frozen last track: the spec
            // requires not lying when the source is unavailable.
            Text("Nothing playing")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.4))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Artwork on the left, player on the right. The whole row stretches to
    /// the full height of the content area (not just the text height),
    /// otherwise the same empty strip remains under the artwork and text
    /// that the panel was asked to be redone for.
    private func playing(_ track: TrackDisplay) -> some View {
        // Top alignment, not center: the player column is stretched to the
        // full height of the row and starts its text at the top, while the
        // artwork sits 12 pt below it. With centering it would drop by
        // 6 pt, and the top of the title would end up above the top of the
        // artwork — the edges wouldn't line up.
        HStack(alignment: .top, spacing: Self.artworkGap) {
            artworkView
            playerColumn(track)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private var artworkView: some View {
        Group {
            if let artwork {
                artwork.resizable().aspectRatio(contentMode: .fill)
            } else {
                accent.opacity(0.35)
            }
        }
        .frame(width: Self.artworkSize, height: Self.artworkSize)
        .clipShape(RoundedRectangle(cornerRadius: Self.artworkCornerRadius, style: .continuous))
    }

    /// Metadata on top, controls at the bottom, with a flexible gap between
    /// them: the column is always stretched to the full height of the row
    /// (see .frame below), not just the height of its own content, so the
    /// play button and progress end up at the bottom of the panel rather
    /// than right under the text.
    private func playerColumn(_ track: TrackDisplay) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                trackInfo(track)
                Spacer(minLength: 8)
                EqualizerView(isAnimating: track.isPlaying, accent: accent)
            }
            Spacer(minLength: 12)
            playbackControls(track)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func trackInfo(_ track: TrackDisplay) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            // MarqueeText decides on its own whether to truncate the text or
            // scroll it — the owner asked for scrolling instead of a silent
            // "…" on long titles (see MarqueeMetrics.shouldScroll). The
            // artist follows the same principle: short stays put, long
            // scrolls.
            MarqueeText(track.title, font: .system(size: 18, weight: .semibold))
            MarqueeText(track.artist, font: .system(size: 13))
                .foregroundStyle(.white.opacity(0.55))
            sourceBadge(track.source)
                .padding(.top, 5)
        }
        // Explicit width bound — otherwise a long track title has nothing to
        // truncate against: lineLimit(1) only shortens where a limit
        // exists. MarqueeText relies on the same principle: without a real,
        // non-infinite width here it has nothing to compare the text width
        // against to decide whether scrolling is needed
        // (MarqueeMetrics.shouldScroll).
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sourceBadge(_ source: String) -> some View {
        Text(source)
            .font(.system(size: 10, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(accent)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .overlay(Capsule().stroke(accent.opacity(0.5)))
    }

    private func playbackControls(_ track: TrackDisplay) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            transportRow(track)
            ProgressBar(
                progress: TrackFormatting.progress(position: position, duration: track.duration),
                accent: accent
            )
            HStack {
                Text(TrackFormatting.time(position))
                Spacer()
                Text(TrackFormatting.time(track.duration))
            }
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.45))
        }
    }

    /// Previous / play-pause / next in a single row. Play/pause sits in the
    /// center and remains the primary element — larger, and the only fully
    /// opaque one (see doc on PlayPauseButtonStyle); the side buttons are
    /// smaller and unfilled at rest, so they don't compete for attention
    /// with the center one.
    ///
    /// The row's width (24 + 12 + 30 + 12 + 24 = 102 pt) is well within the
    /// budget that PanelMetricsTests.playerKeepsUsableWidth checks for the
    /// whole player column (> 200 pt) — the column's own layout
    /// (PanelMetrics, artworkSize) is untouched by this row.
    private func transportRow(_ track: TrackDisplay) -> some View {
        HStack(spacing: 12) {
            TrackSkipButton(systemName: "backward.fill", label: "Previous track", action: onPreviousTrack)
            PlayPauseButton(isPlaying: track.isPlaying, action: onTogglePlayback)
            TrackSkipButton(systemName: "forward.fill", label: "Next track", action: onNextTrack)
        }
    }
}

/// Play/pause is the primary of the three elements in the playback control
/// row (see transportRow(_:) above). Flanking it — TrackSkipButton below,
/// for "previous"/"next"; this button is larger than them and the only one
/// in the row drawn as a fully opaque filled circle (see doc on
/// PlayPauseButtonStyle).
///
/// The history of this view is the reason the project has a rule at all
/// that "a command's code is verified empirically, not taken from a
/// framework header." Skip buttons had previously been placed in the
/// interface next to this one, drawing backward.fill/forward.fill, but both
/// sent the same toggle code as play/pause: nobody had actually verified
/// the track-switching codes in practice — they were taken off the top of
/// someone's head. Pressing "next track" actually STOPPED the music — the
/// interface promised one thing, the code did another. The buttons were
/// removed entirely at that point rather than disabled: a disabled button
/// would have made the same false promise of skipping with no result, only
/// quieter.
///
/// The next/previous codes have since been confirmed empirically — with
/// commands actually sent to a playing track, verifying the track changed
/// in the right direction, rather than assumed from documentation (see doc
/// on MediaCommand) — and the buttons came back. This isn't a repeat of the
/// earlier mistake precisely because this time the codes are verified, not
/// guessed.
///
/// A separate view rather than a function inside MusicTabView: it needs
/// @State for hover tracking — a property is only retained when the view
/// has a stable identity, which a function doesn't have.
private struct PlayPauseButton: View {
    let isPlaying: Bool
    let action: () -> Void

    @State private var isHovering = false
    private static let diameter: CGFloat = 30

    var body: some View {
        Button(action: action) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.black)
                .frame(width: Self.diameter, height: Self.diameter)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlayPauseButtonStyle(isHovering: isHovering))
        .onHover { isHovering = $0 }
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
    }
}

/// The only fully opaque element in the tab: a solid white circle with a
/// black glyph — under the "Obsidian" rules this is a deliberate exception,
/// needed for a tactile, unambiguously clickable button set against text
/// that otherwise consists entirely of white at varying opacity.
private struct PlayPauseButtonStyle: ButtonStyle {
    let isHovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Circle().fill(.white.opacity(isHovering ? 1 : 0.85)))
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
    }
}

/// The "previous"/"next" track buttons are secondary elements in the row,
/// so the glyph is white at varying opacity (the "Obsidian" rule) rather
/// than a fill: PlayPauseButtonStyle above is deliberately the only fully
/// opaque element in the tab, and a second such button would break that
/// "only."
///
/// Same technique and same rationale as PlayPauseButton: a separate view
/// rather than a function, for a stable identity under @State hover
/// tracking.
private struct TrackSkipButton: View {
    let systemName: String
    let label: String
    let action: () -> Void

    @State private var isHovering = false
    private static let diameter: CGFloat = 24

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(isHovering ? 1 : 0.7))
                .frame(width: Self.diameter, height: Self.diameter)
                .contentShape(Rectangle())
        }
        .buttonStyle(TrackSkipButtonStyle(isHovering: isHovering))
        .onHover { isHovering = $0 }
        .accessibilityLabel(label)
    }
}

/// Hover is a barely visible white circle (0.14, not 1 like play/pause:
/// this isn't the row's primary button), press is the same scale-down as
/// PlayPauseButtonStyle, speaking that same button's language rather than
/// being reinvented.
private struct TrackSkipButtonStyle: ButtonStyle {
    let isHovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Circle().fill(.white.opacity(isHovering ? 0.14 : 0)))
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
    }
}

private struct ProgressBar: View {
    let progress: Double
    let accent: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.13))
                Capsule().fill(accent).frame(width: proxy.size.width * progress)
            }
        }
        .frame(height: 4)
    }
}
