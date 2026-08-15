import Foundation
import Observation
import NotchUI
import StashKit
import os

/// Model for the quick notes tab.
///
/// Unlike ClipboardViewModel, this does not move reads and writes off
/// MainActor into a background task: notes are short user text with no
/// blobs, and a synchronous GRDB call on them doesn't risk hanging the
/// panel, unlike the megabyte-sized clipboard history screenshots that
/// justify all the async machinery there. Here it would just be
/// complexity with no benefit.
@MainActor
@Observable
final class NotesViewModel {
    private(set) var rows: [NoteRow] = []
    /// Text of the new-note composer field — a two-way binding with
    /// `NotesTabView.draft` on the caller's side (see the task report on
    /// wiring it up in AppDelegate).
    var draft: String = ""

    @ObservationIgnored private let repository: NotesRepository

    private static let logger = Logger(subsystem: "kz.mobilefirst.notchka", category: "notes-tab")

    init(repository: NotesRepository) {
        self.repository = repository
    }

    /// Rereads the list. Call this every time the tab opens — the model does
    /// not keep a persistent subscription to the database (the same choice
    /// made by ClipboardViewModel.refresh(), called from
    /// NotchRootView.task(id:)).
    ///
    /// The signature is `async` even though the body is synchronous (see the
    /// class doc) — the call shape from `.task(id:)` in NotchRootView must
    /// not differ between the clipboard and notes tabs.
    func refresh() async {
        reload()
    }

    /// Saves the draft as a new note.
    ///
    /// Empty text should never reach the repository — the save button and
    /// its `⌘↩` shortcut are disabled on an empty field (see
    /// NotesTabView.NoteComposerView.isSaveDisabled). The `catch` below is a
    /// second line of defense for a race, not the main path: the draft is
    /// NOT cleared on failure, so the user can see that saving didn't
    /// happen instead of silently losing the typed text.
    func saveDraft() {
        do {
            try repository.add(draft)
            draft = ""
            reload()
        } catch is NotesRepository.EmptyBodyError {
            Self.logger.notice("rejected saving an empty note")
        } catch {
            Self.logger.error("failed to save note: \(error, privacy: .public)")
        }
    }

    /// Saves an edit to an existing note. The inline editor in
    /// NotesTabView.NoteRowView stays open on failure — for the same reason
    /// as saveDraft: clearing all the text and confirming doesn't mean
    /// "delete the note", there's a separate trash button for that.
    func commitEdit(id: Int64, body: String) {
        do {
            try repository.update(id: id, body: body)
            reload()
        } catch is NotesRepository.EmptyBodyError {
            Self.logger.notice("rejected saving an empty edit for note \(id, privacy: .public)")
        } catch {
            Self.logger.error("failed to save edit for note \(id, privacy: .public): \(error, privacy: .public)")
        }
    }

    /// Deletes a note. There is deliberately no empty catch — a failure here
    /// has no separate user-facing reaction (there's no "field" that needs
    /// to be left uncleared), just a log entry.
    func delete(id: Int64) {
        do {
            try repository.delete(id: id)
            reload()
        } catch {
            Self.logger.error("failed to delete note \(id, privacy: .public): \(error, privacy: .public)")
        }
    }

    private func reload() {
        do {
            rows = try repository.all().compactMap(Self.makeRow)
        } catch {
            Self.logger.error("failed to read notes: \(error, privacy: .public)")
            rows = []
        }
    }

    /// The date caption is computed from `createdAt`, not `updatedAt` — see
    /// the `NoteRow` doc in NotchUI: the list is sorted by creation time
    /// (NotesRepository.all()), and the caption must stay consistent with
    /// that order.
    private static func makeRow(_ note: Note) -> NoteRow? {
        guard let id = note.id else {
            logger.error("note without an id skipped when building the list")
            return nil
        }
        return NoteRow(id: id, body: note.body, relativeDate: NoteFormatting.relativeDate(note.createdAt))
    }
}
