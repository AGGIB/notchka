import SwiftUI

/// Форматирование времени и прогресса.
///
/// Вынесено из вьюхи, потому что вырожденные значения приходят из внешнего
/// источника: длительность нулевая у радиопотоков, а позиция может оказаться
/// нечисловой при рассинхроне часов.
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

/// Что показывает вкладка музыки.
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

public enum TrackControl: Sendable { case previous, playPause, next }

public struct MusicTabView: View {
    private let track: TrackDisplay?
    private let position: TimeInterval
    private let artwork: Image?
    private let accent: Color
    private let onControl: (TrackControl) -> Void

    public init(
        track: TrackDisplay?,
        position: TimeInterval,
        artwork: Image?,
        accent: Color,
        onControl: @escaping (TrackControl) -> Void
    ) {
        self.track = track
        self.position = position
        self.artwork = artwork
        self.accent = accent
        self.onControl = onControl
    }

    public var body: some View {
        if let track {
            playing(track)
        } else {
            // Честный пустой экран лучше замороженного последнего трека:
            // спека требует не врать, когда источник недоступен.
            Text("Ничего не играет")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.4))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func playing(_ track: TrackDisplay) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                artworkView
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                    Text(track.source)
                        .font(.system(size: 9))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay(Capsule().stroke(accent.opacity(0.5)))
                        .padding(.top, 3)
                }
                Spacer(minLength: 0)
                EqualizerView(isAnimating: track.isPlaying, accent: accent)
            }

            HStack(spacing: 16) {
                control("backward.fill", .previous)
                control(track.isPlaying ? "pause.fill" : "play.fill", .playPause)
                control("forward.fill", .next)
            }

            ProgressBar(
                progress: TrackFormatting.progress(position: position, duration: track.duration),
                accent: accent
            )

            HStack {
                Text(TrackFormatting.time(position))
                Spacer()
                Text(TrackFormatting.time(track.duration))
            }
            .font(.system(size: 9))
            .foregroundStyle(.white.opacity(0.45))
        }
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
        .frame(width: 58, height: 58)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func control(_ symbol: String, _ command: TrackControl) -> some View {
        Button { onControl(command) } label: {
            Image(systemName: symbol).font(.system(size: 13))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.85))
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
        .frame(height: 3)
    }
}
