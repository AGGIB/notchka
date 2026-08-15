import SwiftUI
import NotchCore

/// Tab icon and label for the switcher rail and for the placeholder.
///
/// Lives in NotchUI, not NotchCore: which symbol represents a tab is
/// a presentation question, not domain logic, and NotchCore deliberately
/// doesn't import anything that draws UI. Labels are in English — same as
/// the rest of the panel's user-facing text (see "Nothing playing" in
/// MusicTabView).
extension NotchTab {
    /// SF Symbol for the switcher rail. `TabRailView` iterates
    /// `NotchTab.allCases`, so a new tab case has no way to end up
    /// without an icon unnoticed — the compiler will require a branch in
    /// this switch (see also TabRailViewTests.everyTabHasIconAndLabel).
    var symbolName: String {
        switch self {
        case .music: "music.note"
        case .clipboard: "doc.on.clipboard"
        case .notes: "note.text"
        case .pins: "pin.fill"
        }
    }

    /// Human-readable name — for accessibilityLabel, the hover tooltip,
    /// and the tab placeholder's label.
    var title: String {
        switch self {
        case .music: "Music"
        case .clipboard: "Clipboard"
        case .notes: "Notes"
        case .pins: "Pins"
        }
    }
}

/// Tab switcher rail to the left of the panel's content area.
///
/// Fixed width and full height of the content area — the task
/// specifically asked for this layout to replace the single keyboard
/// path (`⌘1`…`⌘4`, `⇥`) that switching used to be limited to: three
/// of the four tabs had no way to be discovered on screen.
public struct TabRailView: View {
    private let selected: NotchTab
    private let accent: Color
    private let onSelect: (NotchTab) -> Void

    /// Namespace shared by all items: matchedGeometryEffect only
    /// interpolates the active item's backdrop between its old and new
    /// position when both use the same namespace and id (see
    /// TabRailItemStyle).
    @Namespace private var activeTabNamespace

    private static let width: CGFloat = 64
    private static let itemSpacing: CGFloat = 16

    public init(selected: NotchTab, accent: Color, onSelect: @escaping (NotchTab) -> Void) {
        self.selected = selected
        self.accent = accent
        self.onSelect = onSelect
    }

    public var body: some View {
        VStack(spacing: Self.itemSpacing) {
            Spacer(minLength: 0)
            ForEach(NotchTab.allCases, id: \.self) { tab in
                TabRailItem(
                    tab: tab,
                    isSelected: tab == selected,
                    accent: accent,
                    namespace: activeTabNamespace,
                    onSelect: { onSelect(tab) }
                )
            }
            Spacer(minLength: 0)
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        // A thin seam between the rail and the content — the only line on
        // the panel that gives the eye a border without a second color: the
        // same white opacity scale as the rest of "Obsidian"'s chrome.
        .overlay(alignment: .trailing) {
            Rectangle().fill(.white.opacity(0.08)).frame(width: 1)
        }
    }
}

/// A single rail item: an icon button; hover and click are passed
/// outward via onSelect — the rail itself knows nothing about how the
/// event reaches the state machine (see NotchPanelView.onSelectTab).
private struct TabRailItem: View {
    let tab: NotchTab
    let isSelected: Bool
    let accent: Color
    let namespace: Namespace.ID
    let onSelect: () -> Void

    @State private var isHovering = false

    private static let size: CGFloat = 36

    var body: some View {
        Button(action: onSelect) {
            Image(systemName: tab.symbolName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: Self.size, height: Self.size)
                .contentShape(Rectangle())
        }
        .buttonStyle(TabRailItemStyle(isSelected: isSelected, isHovering: isHovering, accent: accent, namespace: namespace))
        .onHover { isHovering = $0 }
        .help(tab.title)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The active tab is white at full opacity: the accent backdrop
    /// already signals "this is selected" (see TabRailItemStyle.backdrop),
    /// and the icon itself has to stay the most legible element whether
    /// on the black background or on the soft accent plate. Inactive tabs
    /// are low-opacity white per the task's requirement; hovering raises
    /// it noticeably, but not to the active level.
    private var iconColor: Color {
        if isSelected { return .white }
        return .white.opacity(isHovering ? 0.7 : 0.4)
    }
}

/// The active item's backdrop, hover, and press are three distinct
/// states each with their own visual signal, so "under the cursor"
/// doesn't read as "selected", and "selected" doesn't get lost against
/// a neighboring tab's "under the cursor".
private struct TabRailItemStyle: ButtonStyle {
    let isSelected: Bool
    let isHovering: Bool
    let accent: Color
    let namespace: Namespace.ID

    private static let cornerRadius: CGFloat = 10

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(backdrop)
            // The press responds instantly, with no easing: there's
            // deliberately no animation here. NotchMotion has no constant
            // of the right order — opening/closing are tied to panel
            // states, and accentFade at 0.6s is an order of magnitude
            // slower than a press needs — and introducing one of our own
            // is forbidden by the project's rule. The selected tab's
            // backdrop, unlike this, does animate: it inherits
            // NotchMotion's spring via .animation(value: state) in
            // NotchPanelView.body.
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
    }

    @ViewBuilder
    private var backdrop: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(accent.opacity(0.24))
                .matchedGeometryEffect(id: "activeTabBackdrop", in: namespace)
        } else if isHovering {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(.white.opacity(0.08))
        }
    }
}
