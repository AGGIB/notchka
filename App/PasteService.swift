import AppKit
import CoreGraphics
import os

/// Кладёт текст в пастборд и вставляет его в активное приложение.
///
/// Оригинал пастборда сознательно не восстанавливается: восстановление
/// через задержку ломает приложения, читающие буфер асинхронно, и даёт
/// гонки, которые пользователь увидит как «вставилось не то».
@MainActor
enum PasteService {
    private static let logger = Logger(subsystem: "kz.mobilefirst.notchka", category: "paste")

    static func copyOnly(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// То же для не-текстового содержимого: картинки, ссылки на файл.
    ///
    /// Отдельный вход, потому что байты картинки нельзя положить строкой, а
    /// «клик вставляет» обещано всем типам истории, не только тексту.
    static func copyOnly(objects: [any NSPasteboardWriting]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(objects)
    }

    /// Возвращает false, если нет разрешения: вызывающий показывает подсказку.
    @discardableResult
    static func paste(_ text: String, into application: NSRunningApplication?) -> Bool {
        copyOnly(text)
        return pasteWhatIsOnPasteboard(into: application)
    }

    /// Вставка не-текстового содержимого. Механика ниже общая с текстом:
    /// ⌘V не разбирается, что именно лежит в пастборде.
    @discardableResult
    static func paste(objects: [any NSPasteboardWriting], into application: NSRunningApplication?) -> Bool {
        copyOnly(objects: objects)
        return pasteWhatIsOnPasteboard(into: application)
    }

    private static func pasteWhatIsOnPasteboard(into application: NSRunningApplication?) -> Bool {
        guard AccessibilityPermission.isTrusted else {
            logger.notice("вставка невозможна: нет разрешения Accessibility, содержимое только скопировано")
            return false
        }

        // Фокус возвращается тому приложению, у которого его забрала
        // раскрытая панель, иначе ⌘V уйдёт в пустоту.
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
            logger.error("не удалось создать событие ⌘V")
            return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
