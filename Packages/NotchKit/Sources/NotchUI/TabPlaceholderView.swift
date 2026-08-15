import SwiftUI
import NotchCore

/// Placeholder for tabs that aren't wired to data yet.
///
/// Shared by the clipboard, notes, and pins tabs — deliberately doesn't mimic
/// the shape of future content (for the clipboard that'll be a horizontal
/// card strip, the others have their own layout). It just fills the entire
/// content area to the right of the tab column, the same shape the real tab
/// will occupy, and no more: the next task will replace the call to this
/// view for `.clipboard` entirely, rather than adapting it to fit.
public struct TabPlaceholderView: View {
    private let tab: NotchTab
    private let message: String

    /// `message` is overridden when a tab is empty for a reason other than
    /// not being implemented yet. The clipboard has such a case: the store
    /// failed to open, and showing "coming soon" for an already-built
    /// feature would lie to the user about the cause.
    public init(tab: NotchTab, message: String = "Coming soon") {
        self.tab = tab
        self.message = message
    }

    public var body: some View {
        VStack(spacing: 10) {
            Image(systemName: tab.symbolName)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.white.opacity(0.22))
            Text(tab.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.3))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(tab.title). \(message).")
    }
}
