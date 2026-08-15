import AppKit
import CoreGraphics
import os

/// Puts text on the pasteboard and pastes it into the active application.
///
/// The original pasteboard contents are deliberately not restored: restoring
/// after a delay breaks apps that read the buffer asynchronously, and causes
/// races the user would see as "the wrong thing got pasted."
@MainActor
enum PasteService {
    private static let logger = Logger(subsystem: "kz.mobilefirst.notchka", category: "paste")

    static func copyOnly(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Same idea for non-text content: images, file references.
    ///
    /// A separate entry point because image bytes can't be put on as a
    /// string, and "click to paste" is promised for every history item type, not just text.
    static func copyOnly(objects: [any NSPasteboardWriting]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(objects)
    }

    /// Returns false if permission is missing: the caller shows a hint.
    @discardableResult
    static func paste(_ text: String, into application: NSRunningApplication?) -> Bool {
        copyOnly(text)
        return pasteWhatIsOnPasteboard(into: application)
    }

    /// Pastes non-text content. The mechanics below are shared with text:
    /// ⌘V doesn't care what's actually on the pasteboard.
    @discardableResult
    static func paste(objects: [any NSPasteboardWriting], into application: NSRunningApplication?) -> Bool {
        copyOnly(objects: objects)
        return pasteWhatIsOnPasteboard(into: application)
    }

    private static func pasteWhatIsOnPasteboard(into application: NSRunningApplication?) -> Bool {
        guard AccessibilityPermission.isTrusted else {
            logger.notice("paste unavailable: no Accessibility permission, content only copied")
            return false
        }

        // Focus is returned to the application it was taken from by the
        // expanded panel, otherwise ⌘V would go nowhere.
        application?.activate()
        postCommandV()
        return true
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKeyCode: CGKeyCode = 0x09  // kVK_ANSI_V

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        else {
            logger.error("failed to create ⌘V event")
            return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
