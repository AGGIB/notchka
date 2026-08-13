import AppKit
import ApplicationServices

/// Разрешение Accessibility — единственное, которое нужно приложению,
/// и только ради посылки `⌘V` в чужое приложение.
enum AccessibilityPermission {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Показывает системный запрос. Возвращает состояние на момент вызова:
    /// разрешение выдаётся асинхронно, пользователь уходит в настройки.
    ///
    /// Ключ ниже — буквальное значение `kAXTrustedCheckOptionPrompt` (см.
    /// AXUIElement.h, стабильно с 10.9). Сама константа не используется:
    /// ClangImporter даёт её как `var` (Unmanaged<CFString>!), и Swift 6 при
    /// строгой конкурентности отказывается компилировать любое обращение к
    /// ней — это чтение «разделяемого мутируемого состояния» (не Sendable,
    /// не `let`). Обёртка через `nonisolated(unsafe)` не спасает: небезопасной
    /// остаётся сама точка чтения импортированного глобального символа, а не
    /// то, куда потом кладётся результат. Проверено эмпирически: typecheck
    /// под `-swift-version 6 -strict-concurrency=complete` проходит, а сама
    /// строка — ровно то, что печатает `kAXTrustedCheckOptionPrompt
    /// .takeUnretainedValue() as String` при исполнении на этой машине.
    @discardableResult
    static func requestIfNeeded() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
