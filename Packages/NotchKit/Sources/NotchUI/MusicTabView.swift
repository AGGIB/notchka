import SwiftUI
import NotchCore

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

public struct MusicTabView: View {
    private let track: TrackDisplay?
    private let position: TimeInterval
    private let artwork: Image?
    private let accent: Color
    private let onTogglePlayback: () -> Void

    /// Сторона квадрата обложки. 190 pt подобраны под текущую высоту области
    /// содержимого раскрытой панели (PanelMetrics.expandedSize.height 240,
    /// минус отступы NotchPanelView даёт 202 pt) так, чтобы обложка занимала
    /// её почти целиком и под ней не оставалось пустой полосы — это была
    /// главная жалоба на прежний вид с обложкой 58×58. Изменится
    /// expandedSize — стоит пересмотреть и это число.
    private static let artworkSize: CGFloat = 190
    /// Скругление увеличено пропорционально стороне: было 10 pt на 58 pt
    /// (≈17%), то же соотношение на 190 pt даёт ≈33 pt.
    private static let artworkCornerRadius: CGFloat = 33
    private static let artworkGap: CGFloat = 16

    public init(
        track: TrackDisplay?,
        position: TimeInterval,
        artwork: Image?,
        accent: Color,
        onTogglePlayback: @escaping () -> Void
    ) {
        self.track = track
        self.position = position
        self.artwork = artwork
        self.accent = accent
        self.onTogglePlayback = onTogglePlayback
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

    /// Обложка слева, плеер справа. Вся строка растягивается на полную
    /// высоту области содержимого (а не только на высоту текста), иначе под
    /// обложкой и под текстом остаётся та же пустая полоса, из-за которой
    /// панель просили переделать.
    private func playing(_ track: TrackDisplay) -> some View {
        HStack(alignment: .center, spacing: Self.artworkGap) {
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

    /// Метаданные сверху, управление снизу, между ними — гибкий промежуток:
    /// колонка всегда растянута на полную высоту строки (см. .frame ниже), а
    /// не только на высоту своего содержимого, поэтому кнопка воспроизведения
    /// и прогресс оказываются внизу панели, а не сразу под текстом.
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
            Text(track.title)
                .font(.system(size: 18, weight: .semibold))
                .lineLimit(1)
            Text(track.artist)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
            sourceBadge(track.source)
                .padding(.top, 5)
        }
        // Явная граница ширины — иначе длинному названию трека нечего
        // truncate: lineLimit(1) укорачивает только там, где есть предел.
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
            PlayPauseButton(isPlaying: track.isPlaying, action: onTogglePlayback)
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
}

/// Play/pause — единственный элемент управления воспроизведением.
///
/// Кнопок «предыдущий»/«следующий» трек здесь нет — не скрыты, не
/// задизейблены, убраны совсем. Они рисовали backward.fill/forward.fill, но
/// обе слали тот же toggle-код, что и эта кнопка: переключение треков
/// спайком не проверялось эмпирически, точных кодов нет. Задизейбленная
/// кнопка не лучше — она всё равно обещает своим видом «пролистывание
/// треков», которого на самом деле нет, а нажатие на toggle во время
/// воспроизведения по факту ОСТАНАВЛИВАЕТ музыку: путать этим пользователя
/// на ежедневном инструменте хуже, чем временно недосчитаться двух кнопок.
///
/// Отдельная вьюха, а не функция внутри MusicTabView: нужен @State для
/// наведения курсора — свойство хранится, только когда есть стабильная
/// идентичность вьюхи, у функции её нет.
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
        .accessibilityLabel(isPlaying ? "Пауза" : "Воспроизвести")
    }
}

/// Единственный полностью непрозрачный элемент вкладки: белый залитый круг
/// с чёрным глифом — по правилам «Обсидиана» это осознанное исключение,
/// нужное ради тактильной, однозначно кликабельной кнопки на фоне текста,
/// который весь состоит из белого разной прозрачности.
private struct PlayPauseButtonStyle: ButtonStyle {
    let isHovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Circle().fill(.white.opacity(isHovering ? 1 : 0.85)))
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
