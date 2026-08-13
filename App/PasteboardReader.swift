import AppKit
import ClipboardKit

/// Мост от NSPasteboard к чистым типам.
enum PasteboardReader {
    /// Потолок на размер захватываемого файла — 50 МБ. Величина взята с
    /// запасом на обычное: документы, архивы, картинки. Всё, что крупнее,
    /// копируют не для того, чтобы вставлять из истории буфера.
    static let maxFileBytes = 50 * 1024 * 1024

    /// Прочитанное с пастборда.
    ///
    /// У файла здесь только ссылка, а не содержимое: чтение байтов с диска —
    /// работа не для главного потока, а `read()` вызывается именно с него.
    /// Байты читает `ClipboardService` в фоновой задаче, и уже после фильтра
    /// приватности, так что на отвергнутое содержимое ввод-вывод не тратится.
    struct Content {
        let snapshot: PasteboardSnapshot
        let text: String?
        let image: Data?
        let fileName: String?
        let fileURL: URL?
    }

    /// Читает пастборд. Только главный поток: `NSPasteboard` и
    /// `NSWorkspace.frontmostApplication` — часть AppKit.
    static func read() -> Content? {
        let pasteboard = NSPasteboard.general
        let types = (pasteboard.types ?? []).map(\.rawValue)
        let frontmost = NSWorkspace.shared.frontmostApplication

        // Источник берётся из фронтового приложения в момент опроса, то есть
        // до 0.4 с позже самого копирования. Если пользователь за это время
        // успел переключиться, bundle id окажется от соседнего приложения.
        // Устранить это нечем: публичного уведомления об изменении пастборда
        // в macOS нет, остаётся опрос. На защиту от паролей неточность не
        // влияет — её главный слой это маркер-типы, а они едут вместе с
        // содержимым, а не берутся из окружения.
        let snapshot = PasteboardSnapshot(
            types: types,
            sourceBundleID: frontmost?.bundleIdentifier
        )

        // Порядок важен: файл может нести и текстовое представление,
        // и картинку-превью, а показать его надо файлом.
        //
        // Размер проверяется здесь, хотя читаться файл будет позже: это
        // запрос метаданных, он дешёвый, и отсечь образ диска на несколько
        // гигабайт лучше до того, как он попадёт в очередь на копирование
        // в блобы. Крупные файлы просто не попадают в историю — честнее,
        // чем класть в неё усечённую копию, которую нельзя вставить обратно.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           let url = urls.first, url.isFileURL,
           let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size <= maxFileBytes
        {
            return Content(snapshot: snapshot, text: nil, image: nil,
                           fileName: url.lastPathComponent, fileURL: url)
        }
        if let image = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            return Content(snapshot: snapshot, text: nil, image: image, fileName: nil, fileURL: nil)
        }
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            return Content(snapshot: snapshot, text: text, image: nil, fileName: nil, fileURL: nil)
        }
        return nil
    }

    static func appName(for bundleID: String?) -> String? {
        guard let bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        return FileManager.default.displayName(atPath: url.path)
    }
}
