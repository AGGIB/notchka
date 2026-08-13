import SwiftUI
import NotchCore

/// Заглушка вкладок, которые ещё не подключены к данным.
///
/// Общая для буфера, заметок и пинов — сознательно не имитирует форму
/// будущего содержимого (у буфера это будет горизонтальная лента карточек,
/// у остальных — своя раскладка). Она просто занимает всю область
/// содержимого справа от колонки вкладок той же формы, что займёт настоящая
/// вкладка, и не больше: следующая задача заменит вызов этой вьюхи для
/// `.clipboard` целиком, а не будет подстраиваться под неё.
public struct TabPlaceholderView: View {
    private let tab: NotchTab

    public init(tab: NotchTab) {
        self.tab = tab
    }

    public var body: some View {
        VStack(spacing: 10) {
            Image(systemName: tab.symbolName)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.white.opacity(0.22))
            Text(tab.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
            Text("Скоро появится")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.3))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(tab.title). Скоро появится.")
    }
}
