import AppKit
import ClipboardKit

/// Bridge from NSPasteboard to clean types.
enum PasteboardReader {
    /// Ceiling on the size of a captured file — 50 MB. The value has margin
    /// for the usual case: documents, archives, images. Anything larger
    /// is copied for reasons other than pasting back from clipboard history.
    static let maxFileBytes = 50 * 1024 * 1024

    /// What was read from the pasteboard.
    ///
    /// For a file, this holds only a reference, not the content: reading
    /// bytes from disk isn't work for the main thread, yet `read()` is
    /// called exactly from there. The bytes are read by `ClipboardService`
    /// in a background task, and only after the privacy filter, so no I/O
    /// is spent on rejected content.
    struct Content {
        let snapshot: PasteboardSnapshot
        let text: String?
        let image: Data?
        let fileName: String?
        let fileURL: URL?
    }

    /// Reads the pasteboard. Main thread only: `NSPasteboard` and
    /// `NSWorkspace.frontmostApplication` are part of AppKit.
    static func read() -> Content? {
        let pasteboard = NSPasteboard.general
        let types = (pasteboard.types ?? []).map(\.rawValue)
        let frontmost = NSWorkspace.shared.frontmostApplication

        // The source is taken from the frontmost application at poll time,
        // which is up to 0.4s after the copy itself. If the user switched
        // apps in that window, the bundle id will belong to the neighboring
        // app instead. Nothing can fix this: macOS has no public notification
        // for pasteboard changes, so polling is all there is. This imprecision
        // doesn't affect password protection — its main layer is the marker
        // types, which travel with the content itself, not derived from the
        // environment.
        let snapshot = PasteboardSnapshot(
            types: types,
            sourceBundleID: frontmost?.bundleIdentifier
        )

        // Order matters: a file can carry both a text representation and a
        // preview image, but it must be shown as a file.
        //
        // Size is checked here even though the file will be read later: this
        // is a metadata request, it's cheap, and it's better to reject a
        // multi-gigabyte disk image before it enters the queue for copying
        // into blobs. Large files simply don't make it into history — more
        // honest than storing a truncated copy that can't be pasted back.
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
