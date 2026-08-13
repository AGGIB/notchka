import AppKit
// @preconcurrency — из-за kAXTrustedCheckOptionPrompt ниже. ClangImporter
// отдаёт эту C-константу как `var` (Unmanaged<CFString>!), и строгая
// конкурентность Swift 6 считает любое обращение к ней чтением
// разделяемого изменяемого состояния. Атрибут точечно снимает эти
// диагностики для символов одного модуля в одном файле, не ослабляя
// проверки ни для остального файла, ни для проекта. Это штатный механизм
// SE-0337 ровно для такого случая — фреймворк на C, не переведённый на
// модель конкурентности. Обёртка через nonisolated(unsafe) здесь не
// работает: небезопасно само чтение импортированного символа, а не то,
// куда кладётся результат.
@preconcurrency import ApplicationServices

/// Разрешение Accessibility — единственное, которое нужно приложению,
/// и только ради посылки `⌘V` в чужое приложение.
enum AccessibilityPermission {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Показывает системный запрос. Возвращает состояние на момент вызова:
    /// разрешение выдаётся асинхронно, пользователь уходит в настройки.
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
