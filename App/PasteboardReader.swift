import AppKit
import ClipboardKit

/// Мост от NSPasteboard к чистым типам.
enum PasteboardReader {
    /// Потолок на размер захватываемого файла — 50 МБ. Величина взята с
    /// запасом на обычное: документы, архивы, картинки. Всё, что крупнее,
    /// копируют не для того, чтобы вставлять из истории буфера.
    static let maxFileBytes = 50 * 1024 * 1024

    struct Content {
        let snapshot: PasteboardSnapshot
        let text: String?
        let image: Data?
        let fileName: String?
        let fileData: Data?
    }

    static func read() -> Content? {
        let pasteboard = NSPasteboard.general
        let types = (pasteboard.types ?? []).map(\.rawValue)
        let frontmost = NSWorkspace.shared.frontmostApplication

        let snapshot = PasteboardSnapshot(
            types: types,
            sourceBundleID: frontmost?.bundleIdentifier
        )

        // Порядок важен: файл может нести и текстовое представление,
        // и картинку-превью, а показать его надо файлом.
        //
        // Размер ограничен: содержимое файла читается в память целиком и
        // копируется в блобы, поэтому скопированный в Finder образ диска
        // на несколько гигабайт иначе подвесил бы приложение и съел диск.
        // Крупные файлы просто не попадают в историю — это честнее, чем
        // класть в неё усечённую копию, которую нельзя вставить обратно.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           let url = urls.first, url.isFileURL,
           let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size <= maxFileBytes,
           let data = try? Data(contentsOf: url)
        {
            return Content(snapshot: snapshot, text: nil, image: nil,
                           fileName: url.lastPathComponent, fileData: data)
        }
        if let image = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            return Content(snapshot: snapshot, text: nil, image: image, fileName: nil, fileData: nil)
        }
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            return Content(snapshot: snapshot, text: text, image: nil, fileName: nil, fileData: nil)
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
