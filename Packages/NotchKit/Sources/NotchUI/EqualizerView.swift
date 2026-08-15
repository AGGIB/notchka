import SwiftUI

/// Decorative equalizer.
///
/// The real spectrum of another app's audio is unavailable without a virtual
/// audio driver — the limitation is documented in spec §7. The bars react to
/// the fact of playback, not the sound itself, and that's intentional.
///
/// `paused: !isAnimating` in TimelineView is mandatory: without it the timeline
/// keeps waking the renderer while paused, and the spec requires zero work when idle.
public struct EqualizerView: View {
    private static let periods: [Double] = [0.9, 0.62, 1.15, 0.75, 0.95]

    let isAnimating: Bool
    let accent: Color

    public init(isAnimating: Bool, accent: Color) {
        self.isAnimating = isAnimating
        self.accent = accent
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isAnimating)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Self.periods.indices, id: \.self) { index in
                    Capsule()
                        .fill(accent)
                        .frame(width: 2.5, height: height(at: index, time: time))
                }
            }
        }
        .frame(height: 16)
    }

    private func height(at index: Int, time: Double) -> CGFloat {
        guard isAnimating else { return 3 }
        let phase = sin(time / Self.periods[index] * .pi * 2)
        return 3 + CGFloat((phase + 1) / 2) * 13
    }
}
