import AppKit
import Observation
import NotchStore
import NotchUI
import StashKit
import os

/// Pins tab view model.
///
/// Like ClipboardViewModel (see its doc), doesn't hold a persistent
/// subscription to the database — the list is re-read every time the tab
/// opens via `refresh()`, called from NotchRootView.task(id:) using the same
/// approach as the clipboard and track position (decision #4 of the spec).
@MainActor
@Observable
final class PinsViewModel {
    private(set) var chips: [PinChip] = []

    @ObservationIgnored private let repository: SnippetsRepository
    /// Full records by id: PinChip only carries what's needed for display and
    /// insertion, while `SnippetsRepository.update(_:)` also requires
    /// `sortOrder` and `createdAt`, which the chip doesn't have at all — those
    /// come from here.
    @ObservationIgnored private var snippetsByID: [Int64: Snippet] = [:]

    // nonisolated: without this the static logger would inherit the class's
    // MainActor isolation and be unreachable from the nonisolated functions
    // below, which deliberately move database access off the main thread — the
    // same approach and rationale as ClipboardViewModel.logger.
    nonisolated private static let logger = Logger(subsystem: "kz.mobilefirst.notchka", category: "pins-tab")

    /// Called right after the model has put the pin's value on the
    /// pasteboard. Same approach and rationale as
    /// `ClipboardViewModel.didWritePasteboard`: without it, clipboard polling a
    /// fraction of a second later would read the pasted value back and add it
    /// to the clipboard history as a separate entry — in plain text, even if
    /// the pin was marked sensitive. Masking in the pins panel wouldn't help in
    /// this case: the clipboard feed shows content without a mask.
    @ObservationIgnored private let didWritePasteboard: () -> Void

    init(repository: SnippetsRepository, didWritePasteboard: @escaping () -> Void = {}) {
        self.repository = repository
        self.didWritePasteboard = didWritePasteboard
    }

    /// Re-reads the pin list. Call on every tab open — the model doesn't
    /// hold a persistent subscription to the database (see class doc).
    func refresh() async {
        let repository = repository
        let snippets = await Self.loadAll(repository: repository)
        apply(snippets)
    }

    /// Chip click: inserts the real value, not the mask (decision #1 of
    /// the spec). `frontmostApplication` is read from outside at the moment
    /// of the click, not captured on expand — see `NotchController.pasteTarget`
    /// and its doc on why that matters specifically at click time.
    func activate(id: Int64, frontmostApplication: NSRunningApplication?) {
        guard let snippet = snippetsByID[id] else { return }
        PasteService.paste(snippet.value, into: frontmostApplication)
        didWritePasteboard()
    }

    /// ⌥-click: copy only, using the same real value.
    func copyOnly(id: Int64) {
        guard let snippet = snippetsByID[id] else { return }
        PasteService.copyOnly(snippet.value)
        didWritePasteboard()
    }

    /// Dragging a chip to a new position — decision #2 of the spec: calls
    /// `move(id:to:)` and immediately re-reads the list so the new order is
    /// visible right away, in the same open panel, not only on the next tab
    /// open.
    func reorder(id: Int64, to newIndex: Int) {
        let repository = repository
        Task(priority: .utility) {
            let snippets = await Self.moveAndFetch(repository: repository, id: id, to: newIndex)
            apply(snippets)
        }
    }

    /// Saves a pin from the PinsTabView form: a new one if `chip.id` is
    /// empty, otherwise edits the existing record found by that id.
    func save(_ chip: PinChip) {
        let repository = repository
        let existing = chip.id.flatMap { snippetsByID[$0] }
        Task(priority: .utility) {
            let snippets = await Self.persistAndFetch(repository: repository, chip: chip, existing: existing)
            apply(snippets)
        }
    }

    /// Builds chips from an already-read list — on the main thread, using
    /// the same approach as `ClipboardViewModel.apply(_:)`.
    private func apply(_ snippets: [Snippet]) {
        var byID: [Int64: Snippet] = [:]
        var built: [PinChip] = []
        built.reserveCapacity(snippets.count)
        for snippet in snippets {
            guard let id = snippet.id else {
                Self.logger.error("pin without id skipped while building the list")
                continue
            }
            byID[id] = snippet
            built.append(PinChip(
                id: id, label: snippet.label, value: snippet.value,
                isSensitive: snippet.isSensitive, colorHex: snippet.colorHex, icon: snippet.icon
            ))
        }
        snippetsByID = byID
        chips = built
    }

    nonisolated private static func loadAll(repository: SnippetsRepository) async -> [Snippet] {
        do {
            return try repository.all()
        } catch {
            logger.error("failed to read pin list: \(error, privacy: .public)")
            return []
        }
    }

    nonisolated private static func moveAndFetch(
        repository: SnippetsRepository, id: Int64, to newIndex: Int
    ) async -> [Snippet] {
        do {
            try repository.move(id: id, to: newIndex)
        } catch {
            logger.error("failed to move pin \(id, privacy: .public): \(error, privacy: .public)")
        }
        return await loadAll(repository: repository)
    }

    /// Edits the existing record or adds a new one depending on whether
    /// `existing` was found — `save(_:)` looks it up before entering here,
    /// while `snippetsByID` is still accessible on the main thread.
    /// `update(_:)` inside `SnippetsRepository` doesn't decide this itself: it
    /// expects an already-assembled `Snippet` in full, including `sortOrder`
    /// and `createdAt`, which the form never sees.
    nonisolated private static func persistAndFetch(
        repository: SnippetsRepository, chip: PinChip, existing: Snippet?
    ) async -> [Snippet] {
        do {
            if var snippet = existing {
                snippet.label = chip.label
                snippet.value = chip.value
                snippet.icon = chip.icon
                snippet.colorHex = chip.colorHex
                snippet.isSensitive = chip.isSensitive
                try repository.update(snippet)
            } else {
                try repository.add(
                    label: chip.label, value: chip.value, icon: chip.icon,
                    colorHex: chip.colorHex, isSensitive: chip.isSensitive
                )
            }
        } catch {
            logger.error("failed to save pin: \(error, privacy: .public)")
        }
        return await loadAll(repository: repository)
    }
}
