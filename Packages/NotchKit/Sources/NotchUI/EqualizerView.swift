import SwiftUI

/// Декоративный эквалайзер.
///
/// Настоящий спектр чужого приложения без виртуального аудиодрайвера
/// недоступен — ограничение зафиксировано в спеке §7. Полоски реагируют на
/// факт воспроизведения, а не на звук, и это осознанно.
///
/// `paused: !isAnimating` в TimelineView обязателен: без него таймлайн
/// продолжает будить рендер на паузе, а спека требует ноль работы в простое.
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
