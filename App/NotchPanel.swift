import AppKit
import SwiftUI
import NotchCore

/// Panel window. Size is constant and equal to the maximum expanded state:
/// changing the NSWindow frame during the spring animation means jank,
/// so only the content inside is animated.
final class NotchPanel: NSPanel {
    /// Allows the panel to become the key window. Enabled only while
    /// expanded with a search field, otherwise the panel would steal focus
    /// from the app we're about to insert text into.
    var acceptsKeyboard = false

    /// Where the parsed key press from keyDown(with:) goes. Wired up
    /// externally (see NotchController.start()) via a closure rather than by
    /// holding the controller itself: NotchController already has a
    /// `weak var panel` pointing back the other way, and a strong reference
    /// here would close a retain cycle.
    var onKeyEvent: ((NotchEvent) -> Void)?

    override var canBecomeKey: Bool { acceptsKeyboard }
    override var canBecomeMain: Bool { false }

    /// Releases keyboard focus if the panel holds it.
    ///
    /// Just clearing `acceptsKeyboard` isn't enough: a window that has
    /// already become key stays key, and would keep stealing keystrokes
    /// from the app the user is working in after the panel collapses.
    func resignKeyIfNeeded() {
        guard isKeyWindow else { return }
        resignKey()
        // Focus goes back to whoever had it before us. Without this the
        // keyboard would be left hanging: an accessory app has no other
        // windows to hand it off to.
        NSApp.deactivate()
    }

    init(contentRect: CGRect, rootView: some View) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        // Above the menu bar: the panel must cover it, not hide underneath.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenNone, .ignoresCycle]

        isOpaque = false
        backgroundColor = .clear
        // NSWindow releases itself by default on close(), and ARC doesn't
        // know that and would release the window a second time via its own
        // strong reference. AppDelegate closes the panel explicitly when the
        // notch disappears from the screen.
        isReleasedWhenClosed = false
        // We draw the shadow ourselves — the system one can't do concave corners.
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        // By default the window is transparent to mouse events, otherwise it
        // would intercept clicks on the menu bar. NotchController
        // .syncMouseHandling() toggles this based on the panel's current state.
        ignoresMouseEvents = true

        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = CGRect(origin: .zero, size: contentRect.size)
        contentView = hosting
    }

    /// Only reaches here while the panel is the key window, i.e. only in
    /// .expanded (acceptsKeyboard is managed by NotchController
    /// .syncMouseHandling()), so no separate state check is needed inside.
    /// A key not recognized by the binding must keep going down the
    /// responder chain via super — otherwise the search field (next up)
    /// wouldn't get a single printable character.
    override func keyDown(with event: NSEvent) {
        let key = PanelKeyHandler.panelKey(for: event)
        let modifiers = PanelKeyHandler.panelModifiers(for: event)
        guard let notchEvent = KeyBinding.event(forKeyCode: key, modifiers: modifiers) else {
            super.keyDown(with: event)
            return
        }
        onKeyEvent?(notchEvent)
    }
}
