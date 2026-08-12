import AppKit
import Carbon.HIToolbox
import os

/// Глобальный хоткей через Carbon. Выбран сознательно:
/// NSEvent.addGlobalMonitorForEvents(matching: .keyDown) потребовал бы
/// разрешения Accessibility ещё до того, как оно понадобится для вставки.
///
/// Переназначение хоткея из настроек появится в плане 4 — тогда сюда
/// заедет KeyboardShortcuts, которая является обёрткой над этим же API.
@MainActor
final class HotkeyCenter {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var onFire: (() -> Void)?

    private static let signature = OSType(0x4E4F5443)  // 'NOTC'
    private static let hotKeyID: UInt32 = 1
    private static let logger = Logger(subsystem: "kz.mobilefirst.notchka", category: "HotkeyCenter")

    /// По умолчанию ⌥Space: ⌘Space занят Spotlight.
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
                // Carbon-обработчик вызывается на главном цикле выполнения.
                MainActor.assumeIsolated { center.onFire?() }
                return noErr
            },
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard installStatus == noErr else {
            // Без лога отказ установки обработчика неотличим от исправно
            // зарегистрированного, но никогда не срабатывающего хоткея:
            // RegisterEventHotKey ниже всё равно «успешно» отработает.
            Self.logFailure("Установка обработчика хоткея", status: installStatus, keyCode: keyCode, modifiers: modifiers)
            return
        }

        let id = EventHotKeyID(signature: Self.signature, id: Self.hotKeyID)
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr else {
            Self.logFailure("Регистрация хоткея", status: status, keyCode: keyCode, modifiers: modifiers)
            return
        }
    }

    /// Без этого лога отказ установки обработчика или регистрации хоткея
    /// неотличим от хоткея, который просто никто не нажимает — единственный
    /// способ узнать причину у пользователя ежедневного инструмента это
    /// системный лог. Значения помечены .public: это диагностика для
    /// Console.app, а не приватные данные пользователя — молча скрытые
    /// редакцией по умолчанию значения свели бы лог обратно к бесполезному.
    private static func logFailure(_ step: String, status: OSStatus, keyCode: UInt32, modifiers: UInt32) {
        logger.error(
            "\(step, privacy: .public) не удалась (keyCode=\(keyCode, privacy: .public), modifiers=\(modifiers, privacy: .public)), OSStatus=\(status, privacy: .public). Вероятная причина: сочетание уже занято другим приложением или системой."
        )
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
    }

    deinit {
        // deinit класса на @MainActor не наследует изоляцию автоматически —
        // компилятор считает его nonisolated, поэтому прямое чтение hotKeyRef/
        // eventHandler здесь не проходит проверку типов Swift 6. Допущение то
        // же, что и в обработчике выше: единственный владелец HotkeyCenter —
        // NotchController, который существует только на MainActor.
        MainActor.assumeIsolated {
            if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
            if let eventHandler { RemoveEventHandler(eventHandler) }
        }
    }
}
