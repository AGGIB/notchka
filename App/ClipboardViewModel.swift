import AppKit
import Observation
import SwiftUI
import NotchStore
import NotchUI
import os

/// Clipboard tab model.
///
/// Unlike MusicViewModel, doesn't hold a persistent subscription: history
/// is only read while the clipboard tab itself is expanded (see `refresh()`,
/// called from NotchRootView.task(id:) with the same approach as track
/// position updates) — at rest the app has nothing to poll, and the spec
/// requires exactly that.
@MainActor
@Observable
final class ClipboardViewModel {
    private(set) var cards: [ClipboardCard] = []
    /// Card for the last action (paste or copy) — the feed
    /// highlights it with an accent outline as confirmation of what's currently
    /// in the pasteboard. `nil` until the user has clicked something in this
    /// session.
    private(set) var selectedID: Int64?

    @ObservationIgnored private let repository: ClipboardRepository
    /// Full records by id — the card only stores a truncated preview
    /// (see ClipboardCard.preview), but pasting and copying need the original
    /// content.
    @ObservationIgnored private var itemsByID: [Int64: ClipboardItem] = [:]

    // nonisolated: without this the static logger would inherit the class's
    // MainActor isolation and would be unreachable from the nonisolated functions
    // below, which deliberately move database and blob reads off the main
    // thread — the same approach and rationale as ClipboardService.logger.
    nonisolated private static let logger = Logger(subsystem: "kz.mobilefirst.notchka", category: "clipboard-tab")

    /// How many recent records to show. The feed scrolls sideways rather than
    /// loading in chunks as you scroll, so the number is a compromise
    /// between "history visible far enough back" and "not decoding a hundred
    /// thumbnails on every tab open".
    private static let limit = 50
    /// Characters in the card's text preview. Tuned to its width (see
    /// ClipboardTabView.ClipboardCardView.width = 76 pt) — when wrapped at the
    /// small font size, the card fills up in height without overflowing the
    /// edge on longer text.
    private static let previewMaxLength = 64

    /// Called right after the model has put something on the pasteboard.
    /// The watcher service uses it to mark the change as its own and not read
    /// it back — otherwise an image pulled from history would immediately land
    /// back in it a second time, in a different representation and with a
    /// different hash.
    @ObservationIgnored private let didWritePasteboard: () -> Void

    init(repository: ClipboardRepository, didWritePasteboard: @escaping () -> Void = {}) {
        self.repository = repository
        self.didWritePasteboard = didWritePasteboard
    }

    /// Re-reads history. Call on every tab open — the model doesn't hold a
    /// persistent subscription to the database (see the class doc).
    func refresh() async {
        let repository = repository
        let snapshot = await Self.loadRecent(repository: repository, limit: Self.limit)
        apply(snapshot)
    }

    /// Card click: content is pasted into the application that was frontmost
    /// before the panel expanded (frontmostApplication comes from outside —
    /// NotchController.frontmostApplicationBeforeExpanding captures it before
    /// the panel takes focus for itself).
    ///
    /// All three types get pasted, not just text: the rule "click pastes,
    /// ⌥click copies" has no exceptions by content type, and a user who clicked
    /// a screenshot shouldn't have to guess why nothing happened this time.
    /// Images and files go onto the pasteboard as objects, but the same ⌘V is
    /// sent afterward — it doesn't care what's on it.
    func activate(id: Int64, frontmostApplication: NSRunningApplication?) {
        guard let item = itemsByID[id] else { return }
        if item.kind == .text {
            PasteService.paste(item.textBody ?? "", into: frontmostApplication)
            markDelivered(id)
        } else {
            // The outline is set not here, but after the bytes have actually
            // made it to the pasteboard: reading the blob can fail, and the
            // outline promises the user "this is now in the clipboard".
            deliverBlob(item, pastingInto: frontmostApplication)
        }
        touchAndRefresh(id: id)
    }

    /// ⌥click: copy only, no paste.
    func copyOnly(id: Int64) {
        guard let item = itemsByID[id] else { return }
        if item.kind == .text {
            PasteService.copyOnly(item.textBody ?? "")
            markDelivered(id)
        } else {
            deliverBlob(item, pastingInto: nil)
        }
        touchAndRefresh(id: id)
    }

    /// Marks the card as the one whose content is currently in the pasteboard,
    /// and notifies the watcher service so it doesn't read our own record
    /// back.
    private func markDelivered(_ id: Int64) {
        selectedID = id
        didWritePasteboard()
    }

    /// Bumps the record to the top of the feed in the database and immediately
    /// re-reads history, so the reordering is visible right away, in the same
    /// open panel — spec decision #2 requires the pasted item to end up at the
    /// start of the feed, not only on the next tab open.
    private func touchAndRefresh(id: Int64) {
        let repository = repository
        Task(priority: .utility) {
            let snapshot = await Self.touchAndFetch(repository: repository, id: id, limit: Self.limit)
            apply(snapshot)
        }
    }

    /// Fetches the bytes of an image or file and puts them on the pasteboard,
    /// and if `application` is non-nil, pastes them right away.
    ///
    /// Everything that touches disk — both reading the blob and restoring the
    /// file — happens inside the background task, before returning to the main
    /// thread. A copied screenshot can be megabytes in size, and either
    /// reading or writing that much data on the thread that draws the panel
    /// would freeze it.
    private func deliverBlob(_ item: ClipboardItem, pastingInto application: NSRunningApplication?) {
        let repository = repository
        Task(priority: .utility) {
            guard let data = await Self.loadBlob(repository: repository, item: item) else { return }
            // The file is restored right here, off the main thread: writing
            // bytes to disk is just as much I/O as reading them, and
            // leaving it on MainActor would mean fixing one half of the
            // problem and missing the other.
            let fileURL = item.kind == .file
                ? await Self.writeTemporaryFile(data, name: item.textBody)
                : nil
            deliver(data, fileURL: fileURL, item: item, pastingInto: application)
        }
    }

    /// NSImage and NSPasteboard work happen on the main thread: the platform
    /// image type isn't Sendable and shouldn't leave MainActor.
    private func deliver(
        _ data: Data, fileURL: URL?, item: ClipboardItem, pastingInto application: NSRunningApplication?
    ) {
        let objects: [any NSPasteboardWriting]
        switch item.kind {
        case .image:
            guard let image = NSImage(data: data) else { return }
            objects = [image]
        case .file:
            guard let fileURL else { return }
            objects = [fileURL as NSURL]
        case .text:
            return  // never reached here: text goes through PasteService directly
        }

        if let application {
            PasteService.paste(objects: objects, into: application)
        } else {
            PasteService.copyOnly(objects: objects)
        }
        guard let id = item.id else { return }
        markDelivered(id)
    }

    /// Restores the file in a temporary directory under its original name.
    /// History stores a copy of the bytes, not a path (see BlobStore) — putting
    /// a reference to a long-gone or moved original on the pasteboard would be
    /// dishonest, so a new file with the same content and name is created, and
    /// that's what goes on the pasteboard.
    ///
    /// `async` isn't cosmetic: without it the function would run directly on
    /// the caller's MainActor, and `nonisolated` alone wouldn't change that —
    /// it's specifically `await` on a function with no actor binding that
    /// moves execution off the actor.
    nonisolated private static func writeTemporaryFile(_ data: Data, name: String?) async -> URL? {
        let fileName = (name?.isEmpty == false) ? name! : "file"
        let fileURL = temporaryDirectory.appendingPathComponent(fileName)
        do {
            // The directory is recreated from scratch before every delivery:
            // otherwise restored files would pile up in the temp folder until
            // reboot, one per click on a file card. The previously delivered
            // file has already been pasted by this point.
            try? FileManager.default.removeItem(at: temporaryDirectory)
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            logger.error("failed to restore file from clipboard history: \(error, privacy: .public)")
            return nil
        }
    }

    /// Where files from history are restored to. One directory for the whole
    /// app, not a new one per delivery — see writeTemporaryFile.
    nonisolated private static let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("kz.mobilefirst.notchka-paste", isDirectory: true)

    /// Reads the blob off the main thread. `async`, even though
    /// `ClipboardRepository.data(for:)` is itself synchronous: it's precisely
    /// `await` on an async nonisolated function that guarantees leaving
    /// MainActor, regardless of what the calling Task closure ends up isolated
    /// to — not a wish, but a property of await itself on a function with no
    /// actor binding.
    nonisolated private static func loadBlob(repository: ClipboardRepository, item: ClipboardItem) async -> Data? {
        do {
            return try repository.data(for: item)
        } catch {
            logger.error("failed to read clipboard card blob: \(error, privacy: .public)")
            return nil
        }
    }

    /// Bumps the record to the top of the feed in the database, then reads
    /// the fresh list — both operations off the main thread, in one chain
    /// with no intermediate return to MainActor between them.
    nonisolated private static func touchAndFetch(
        repository: ClipboardRepository, id: Int64, limit: Int
    ) async -> (items: [ClipboardItem], blobs: [Int64: Data]) {
        do {
            try repository.touch(id: id)
        } catch {
            logger.error("failed to bump record \(id, privacy: .public) to the top of the feed: \(error, privacy: .public)")
        }
        return await loadRecent(repository: repository, limit: limit)
    }

    /// The list of recent records and the bytes of images among them —
    /// entirely off the main thread. The bytes are read right here, not in a
    /// separate on-demand pass: thumbnails are needed right when the tab opens,
    /// and spec decision #5 requires moving blob reads off the main thread.
    nonisolated private static func loadRecent(
        repository: ClipboardRepository, limit: Int
    ) async -> (items: [ClipboardItem], blobs: [Int64: Data]) {
        do {
            let items = try repository.recent(limit: limit)
            var blobs: [Int64: Data] = [:]
            for item in items where item.kind == .image {
                guard let id = item.id, let data = await loadBlob(repository: repository, item: item) else { continue }
                blobs[id] = data
            }
            return (items, blobs)
        } catch {
            logger.error("failed to read clipboard history: \(error, privacy: .public)")
            return ([], [:])
        }
    }

    /// Builds cards from an already-ready data snapshot, including thumbnail
    /// Image() instances — on the main thread, as spec decision #5 requires.
    private func apply(_ snapshot: (items: [ClipboardItem], blobs: [Int64: Data])) {
        var byID: [Int64: ClipboardItem] = [:]
        var built: [ClipboardCard] = []
        built.reserveCapacity(snapshot.items.count)
        for item in snapshot.items {
            guard let id = item.id else {
                Self.logger.error("clipboard history record without id skipped while building the feed")
                continue
            }
            byID[id] = item
            built.append(ClipboardCard(
                id: id,
                kind: Self.cardKind(for: item.kind),
                preview: Self.preview(for: item),
                source: item.sourceAppName ?? "Unknown",
                isPinned: item.isPinned,
                thumbnail: snapshot.blobs[id].flatMap { NSImage(data: $0) }.map(Image.init(nsImage:))
            ))
        }
        itemsByID = byID
        cards = built
    }

    private static func cardKind(for kind: ClipboardKind) -> ClipboardCard.Kind {
        switch kind {
        case .text: .text
        case .image: .image
        case .file: .file
        }
    }

    /// Card preview. For an image this isn't a caption over emptiness:
    /// showing the image itself is thumbnail's job (see ClipboardCard), and
    /// this text is only a fallback for when the bytes failed to decode into
    /// an Image.
    private static func preview(for item: ClipboardItem) -> String {
        switch item.kind {
        case .text:
            ClipboardCard.preview(for: item.textBody ?? "", maxLength: previewMaxLength)
        case .file:
            ClipboardCard.preview(for: item.textBody ?? "File", maxLength: previewMaxLength)
        case .image:
            "Image"
        }
    }
}
