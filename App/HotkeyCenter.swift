import AppKit
import Carbon.HIToolbox
import os

/// Global hotkey via Carbon. Chosen deliberately:
/// NSEvent.addGlobalMonitorForEvents(matching: .keyDown) would require
/// Accessibility permission before it's actually needed for pasting.
///
/// Hotkey remapping from settings is planned for plan 4 — at that point
/// KeyboardShortcuts, which wraps this same API, will land here.
@MainActor
final class HotkeyCenter {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var onFire: (() -> Void)?

    private static let signature = OSType(0x4E4F5443)  // 'NOTC'
    private static let hotKeyID: UInt32 = 1
    private static let logger = Logger(subsystem: "kz.mobilefirst.notchka", category: "HotkeyCenter")

    /// Defaults to ⌥Space: ⌘Space is taken by Spotlight.
    func register(
        keyCode: UInt32 = UInt32(kVK_Space),
        modifiers: UInt32 = UInt32(optionKey),
        onFire: @escaping () -> Void
    ) {
        unregister()
        self.onFire = onFire

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData, let event else { return noErr }
                var firedID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &firedID
                )
                guard firedID.signature == HotkeyCenter.signature,
                      firedID.id == HotkeyCenter.hotKeyID
                else { return noErr }

                let center = Unmanaged<HotkeyCenter>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                // The Carbon handler is invoked on the main run loop.
                MainActor.assumeIsolated { center.onFire?() }
                return noErr
            },
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard installStatus == noErr else {
            // Without logging, a handler-install failure would be indistinguishable
            // from a hotkey that registered fine but never fires: RegisterEventHotKey
            // below will still "succeed" regardless.
            Self.logFailure("Hotkey handler installation", status: installStatus, keyCode: keyCode, modifiers: modifiers)
            return
        }

        let id = EventHotKeyID(signature: Self.signature, id: Self.hotKeyID)
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr else {
            Self.logFailure("Hotkey registration", status: status, keyCode: keyCode, modifiers: modifiers)
            return
        }
    }

    /// Without this log, a handler-install or hotkey-registration failure is
    /// indistinguishable from a hotkey nobody is pressing — for a daily-driver
    /// tool's user, the system log is the only way to find out why. Values are
    /// marked .public: this is diagnostics for Console.app, not private user
    /// data — values silently redacted by the default privacy policy would
    /// make the log useless again.
    private static func logFailure(_ step: String, status: OSStatus, keyCode: UInt32, modifiers: UInt32) {
        logger.error(
            "\(step, privacy: .public) failed (keyCode=\(keyCode, privacy: .public), modifiers=\(modifiers, privacy: .public)), OSStatus=\(status, privacy: .public). Likely cause: the combination is already taken by another app or the system."
        )
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
    }

    deinit {
        // A class's deinit on @MainActor doesn't automatically inherit isolation —
        // the compiler treats it as nonisolated, so reading hotKeyRef/eventHandler
        // directly here fails Swift 6 type checking. Same assumption as in the
        // handler above: HotkeyCenter's sole owner is NotchController, which only
        // ever exists on MainActor.
        MainActor.assumeIsolated {
            if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
            if let eventHandler { RemoveEventHandler(eventHandler) }
        }
    }
}
