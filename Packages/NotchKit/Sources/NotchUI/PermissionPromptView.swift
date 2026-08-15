import SwiftUI

/// What to show in the clipboard tab: the permission explanation or
/// the history ribbon itself.
///
/// A separate branch point, not a condition inside the view — the same
/// technique and the same reason as KeyBinding.event and ClipboardCard.preview:
/// the "what to show" decision is verified by a windowless test, not by
/// clicking through the live panel (see PermissionPromptViewTests).
public enum ClipboardTabContent: Equatable, Sendable {
    case permissionPrompt
    case ribbon

    public static func resolve(isAccessibilityTrusted: Bool) -> ClipboardTabContent {
        isAccessibilityTrusted ? .ribbon : .permissionPrompt
    }
}

/// Accessibility permission onboarding — shown in the clipboard tab
/// instead of the ribbon until the permission is granted (see ClipboardTabContent).
/// Not a separate window and not a layer over the panel: the panel is the
/// app's interface, the tab just shows a different step instead of the ribbon.
///
/// Doesn't itself call AccessibilityPermission.requestIfNeeded() or
/// .openSettings(): NotchUI doesn't import AppKit (Global Constraints
/// of the plan), so both buttons only report the tap outward via
/// closures — the actual call is made by the app target (see NotchRootView in
/// AppDelegate.swift). It follows from this that the system dialog can't
/// pop up on its own while this view is being built — only from the user's
/// direct tap on "Allow".
public struct PermissionPromptView: View {
    private let onRequestPermission: () -> Void
    private let onOpenSettings: () -> Void

    /// Width of the explanation text. The tab's content area is about 514×202 pt
    /// (PanelMetrics.contentSize minus the tab column and gap, see
    /// NotchPanelView.tabBody), and without a width constraint the text would
    /// stretch across all of it as one long line instead of a readable paragraph.
    private static let explanationWidth: CGFloat = 260

    public init(
        onRequestPermission: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        self.onRequestPermission = onRequestPermission
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        VStack(spacing: 16) {
            explanation
            buttons
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The icon, title, and text are combined into one accessibility element:
    /// this is a description of the whole screen, not three independent items for
    /// VoiceOver — the same technique as TabPlaceholderView. The buttons below are
    /// deliberately outside this block, to stay independently reachable by keyboard.
    private var explanation: some View {
        VStack(spacing: 8) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.white.opacity(0.3))
            Text("Paste into apps")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            // Names the action (⌘V into the active app) and honestly states
            // what happens if the user declines — no scare tactics, no persuasion.
            //
            // Can't say "a click just copies" here, even though that's exactly the
            // fallback path in PasteService: while there's no permission, this
            // screen is shown instead of the ribbon, so there's nothing to click.
            // The actual consequence of declining is that it stays in the ribbon's
            // place — and that's exactly what's said. Deliberately short: the tab
            // only has ~202 pt of height, there's no room to spend on a paragraph.
            Text("Clicking a card sends ⌘V to the active app. Clipboard history is recorded even without the permission — but the ribbon will stay hidden behind this screen.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: Self.explanationWidth)
        }
        .accessibilityElement(children: .combine)
        // The label is set explicitly, same as TabPlaceholderView: without it
        // VoiceOver would assemble the phrase itself and insert the auto-description
        // of the hand.raised.fill symbol, which has nothing to do with the
        // rest of the screen's text.
        .accessibilityLabel("Paste into apps. Requires the Accessibility permission to paste the selected history item into the active app.")
    }

    /// Two buttons, not one: the macOS system dialog shows once and then
    /// stays silent, so a user who dismissed it needs a separate path to
    /// Settings. "Allow" is the primary action (the prominent button on the
    /// right, closer to the usual default-button position in macOS dialogs),
    /// "Open Settings" is the fallback path.
    private var buttons: some View {
        HStack(spacing: 10) {
            PermissionButton(title: "Open Settings", isProminent: false, action: onOpenSettings)
            PermissionButton(title: "Allow", isProminent: true, action: onRequestPermission)
        }
    }
}

/// Button for the permission screen.
///
/// Prominent — solid white with black text: the same technique and the same
/// rationale as PlayPauseButtonStyle in MusicTabView — the one deliberate
/// exception from "white at varying opacity" for the sake of an unambiguously
/// clickable primary button. Secondary — a low-opacity plate, like an inactive
/// TabRailView item. The button's visible text itself serves as the
/// accessibility label, no separate one is needed.
private struct PermissionButton: View {
    let title: String
    let isProminent: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .buttonStyle(PermissionButtonStyle(isProminent: isProminent, isHovering: isHovering))
        .onHover { isHovering = $0 }
    }
}

private struct PermissionButtonStyle: ButtonStyle {
    let isProminent: Bool
    let isHovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isProminent ? .black : .white.opacity(0.85))
            .background(backdrop)
            .clipShape(Capsule())
            // The press responds instantly, without .animation(): the same technique
            // as PlayPauseButtonStyle and TabRailItemStyle — there's deliberately no
            // animation of its own here; the project rule forbids introducing a new
            // one, and there's no ready-made constant of a suitable order in NotchMotion.
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
    }

    @ViewBuilder
    private var backdrop: some View {
        if isProminent {
            Capsule().fill(.white.opacity(isHovering ? 1 : 0.88))
        } else {
            Capsule().fill(.white.opacity(isHovering ? 0.16 : 0.08))
        }
    }
}
