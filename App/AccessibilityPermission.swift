import AppKit
// @preconcurrency — because of kAXTrustedCheckOptionPrompt below. ClangImporter
// exposes this C constant as a `var` (Unmanaged<CFString>!), and Swift 6's
// strict concurrency treats any access to it as a read of shared mutable
// state. The attribute surgically suppresses these diagnostics for symbols
// from a single module in a single file, without weakening checks for the
// rest of the file or the project. This is the standard SE-0337 mechanism
// for exactly this case — a C framework not ported to the concurrency
// model. A nonisolated(unsafe) wrapper doesn't work here: it's the read of
// the imported symbol itself that's unsafe, not where the result is stored.
@preconcurrency import ApplicationServices

/// Accessibility permission — the only one the app needs,
/// and only to send `⌘V` to another application.
enum AccessibilityPermission {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt. Returns the state at call time:
    /// permission is granted asynchronously, the user goes off to Settings.
    @discardableResult
    static func requestIfNeeded() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
