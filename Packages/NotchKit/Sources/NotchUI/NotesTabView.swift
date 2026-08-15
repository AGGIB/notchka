import SwiftUI
import Foundation
import NotchCore

/// Relative timestamp label for a note: time of day for today, "yesterday"
/// for yesterday, calendar date for anything earlier.
///
/// Pulled out of the view on the same principle as TrackFormatting in
/// MusicTabView: a pure function of a date and a reference point that a
/// test can verify without a window.
public enum NoteFormatting {
    /// `calendar` is a parameter defaulting to `.current`, not `.current`
    /// used directly in the body: otherwise "today" and "yesterday" would
    /// depend on the time zone of the machine running the code rather than
    /// on the dates passed in — a test green for the author would go red
    /// for someone running it further east or west (see NoteFormattingTests).
    ///
    /// The threshold is a calendar day, not "minus 24 hours": a note made
    /// at 23:59, under a fixed-interval subtraction, would show "yesterday"
    /// a minute later, even though calendrically it's the same day.
    /// `Calendar.isDate(_:inSameDayAs:)` compares by calendar day
    /// specifically, and the comparison doesn't depend on the sign of the
    /// difference — a future date doesn't break it.
    public static func relativeDate(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return timeOfDay(date, calendar: calendar)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday"
        }
        return calendarDate(date, calendar: calendar)
    }

    /// "14:32" — hours and minutes per the given calendar. Manual
    /// computation of the two components rather than DateFormatter: the
    /// format is fixed (24-hour, zero-padded) and doesn't adapt to locale,
    /// so a formatter object here buys nothing but an extra allocation.
    private static func timeOfDay(_ date: Date, calendar: Calendar) -> String {
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        return String(format: "%02d:%02d", hour, minute)
    }

    /// "Jan 15" — day and abbreviated month name via DateFormatter, not a
    /// custom name array: the given `calendar` can be any calendar system
    /// (the signature doesn't require Gregorian), and a hardcoded list of
    /// 12 month names would be wrong or run out of bounds — the Hebrew
    /// calendar, for instance, has 13 months in a leap year. The ICU data
    /// inside DateFormatter knows month names for any calendar system at once.
    private static func calendarDate(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.setLocalizedDateFormatFromTemplate("d MMM")
        return formatter.string(from: date)
    }
}

/// One note for display in the tab — a snapshot at read time, not a live
/// reference to the database record (the same decision as ClipboardCard).
///
/// `relativeDate` is already computed by the caller (see NotesViewModel)
/// from `createdAt`, not `updatedAt`: the list is sorted by creation time
/// (see doc NotesRepository.all()), and the label has to stay consistent
/// with that ordering — otherwise the "today" label would end up at the
/// bottom of the feed for a note that was only recently edited but
/// created a week ago.
public struct NoteRow: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let body: String
    public let relativeDate: String

    public init(id: Int64, body: String, relativeDate: String) {
        self.id = id
        self.body = body
        self.relativeDate = relativeDate
    }
}

/// Quick notes tab: a composer field on top, the feed below.
///
/// No markdown rendering and no separate editing window — an owner's
/// decision: a palm-sized inline editor is no place for formatting
/// (see task 5 brief, spec §7).
public struct NotesTabView: View {
    private let rows: [NoteRow]
    private let draft: Binding<String>
    private let accent: Color
    private let onSave: () -> Void
    private let onCommitEdit: (NoteRow.ID, String) -> Void
    private let onDelete: (NoteRow.ID) -> Void

    /// Which note is currently expanded into an inline editor.
    ///
    /// Local view state, not model state: unlike
    /// ClipboardViewModel.selectedID (which reflects the actual pasteboard
    /// contents — a fact that's meaningful beyond the view), which note is
    /// expanded right now means nothing outside the current panel viewing
    /// session — the same class of state as isHovering on
    /// ClipboardCardView.
    @State private var expandedID: NoteRow.ID?

    private static let rowSpacing: CGFloat = 6
    private static let sectionSpacing: CGFloat = 10

    public init(
        rows: [NoteRow],
        draft: Binding<String>,
        accent: Color,
        onSave: @escaping () -> Void,
        onCommitEdit: @escaping (NoteRow.ID, String) -> Void,
        onDelete: @escaping (NoteRow.ID) -> Void
    ) {
        self.rows = rows
        self.draft = draft
        self.accent = accent
        self.onSave = onSave
        self.onCommitEdit = onCommitEdit
        self.onDelete = onDelete
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Self.sectionSpacing) {
            NoteComposerView(
                text: draft,
                accent: accent,
                // While an existing note's inline editor is expanded, the
                // composer's ⌘↩ is disabled (see doc NoteComposerView) —
                // otherwise the same shortcut would be attached to two
                // buttons at once, and which one fires would be decided by
                // the responder chain, not the code.
                isEnabled: expandedID == nil,
                onSave: onSave
            )
            if rows.isEmpty {
                // An honest empty state — the same approach as "Clipboard
                // is empty" in ClipboardTabView and "Nothing playing" in
                // MusicTabView.
                Text("No notes yet")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var list: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: Self.rowSpacing) {
                ForEach(rows) { row in
                    NoteRowView(
                        row: row,
                        isExpanded: row.id == expandedID,
                        accent: accent,
                        onToggle: { toggle(row.id) },
                        onCommit: { text in
                            onCommitEdit(row.id, text)
                            expandedID = nil
                        },
                        onDelete: {
                            onDelete(row.id)
                            if expandedID == row.id { expandedID = nil }
                        }
                    )
                }
            }
            // The tail of the feed shouldn't get clipped flush with the
            // scroll edge — the same approach as ClipboardTabView's
            // horizontal feed.
            .padding(.bottom, 2)
        }
    }

    private func toggle(_ id: NoteRow.ID) {
        expandedID = (expandedID == id) ? nil : id
    }
}

/// New note composer field.
///
/// `⌘↩` saves, plain `↩` inserts a newline: a note can span more than one
/// line, and a Return that submits it mid-thought would get in the way
/// rather than help — decision #1 of the task 5 spec.
private struct NoteComposerView: View {
    @Binding var text: String
    let accent: Color
    /// `false` while another note's inline editor is expanded — see the
    /// doc at the call site in NotesTabView.body.
    let isEnabled: Bool
    let onSave: () -> Void

    @State private var isSaveHovering = false

    private static let fieldHeight: CGFloat = 40
    private static let buttonDiameter: CGFloat = 26

    /// Empty input keeps the save action from firing — the first of two
    /// safeguards required by the spec (see doc NotesViewModel.saveDraft
    /// for the second, covering a race past this check).
    private var isTextEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isSaveDisabled: Bool { isTextEmpty || !isEnabled }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            field
            saveButton
        }
    }

    /// Top inset for the real text inside TextEditor and for the
    /// placeholder overlaid on it — one constant shared by both, not two
    /// independent numbers. TextEditor draws its cursor at its own
    /// built-in inner inset, which is less than eight points; without
    /// this addition, typed text would start higher than the
    /// placeholder's position promises, and the two would visibly drift
    /// apart the moment the first key is pressed.
    private static let textTopInset: CGFloat = 8

    private var field: some View {
        TextEditor(text: $text)
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.9))
            // Without this, TextEditor draws its own opaque system
            // background over the black panel — on "Obsidian" it would
            // look like a hole.
            .scrollContentBackground(.hidden)
            .padding(.top, Self.textTopInset)
            .frame(height: Self.fieldHeight)
            // TextEditor on macOS — a known SwiftUI bug: the .frame height
            // you set constrains what the parent learns about the size,
            // but not what actually gets drawn — the NSScrollView inside
            // can render at its full content size, overflowing the
            // bounds. Without .clipped() the field would stretch to the
            // tab's full available height instead of the intended 40 pt.
            .clipped()
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text("New note…")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.3))
                        .padding(.top, Self.textTopInset)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(0.06))
            )
            .accessibilityLabel("New note")
    }

    /// Save button — must be an actual `Button`, not a view wrapping one:
    /// `.keyboardShortcut` binds to the control it's called on directly,
    /// it doesn't "shine through" a composite wrapper.
    private var saveButton: some View {
        Button(action: onSave) {
            Image(systemName: "arrow.up")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(isSaveDisabled ? 0.3 : 1))
                .frame(width: Self.buttonDiameter, height: Self.buttonDiameter)
                .contentShape(Rectangle())
        }
        .buttonStyle(NoteActionButtonStyle(isEnabled: !isSaveDisabled, isHovering: isSaveHovering, accent: accent))
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(isSaveDisabled)
        .onHover { isSaveHovering = $0 }
        .accessibilityLabel("Save note")
    }
}

/// One feed note: a collapsed row or an expanded inline editor.
///
/// Collapsed and expanded states are separate `body` branches, not one
/// shared frame with conditional contents: the expanded state has
/// several independently accessible controls (the field, "Cancel",
/// "Save"), and a single `.accessibilityElement(children: .combine)` over
/// the whole block would make them unreachable for VoiceOver
/// individually — see collapsedRow below, where combine is applied only
/// to the descriptive text, not to the delete button.
private struct NoteRowView: View {
    let row: NoteRow
    let isExpanded: Bool
    let accent: Color
    let onToggle: () -> Void
    let onCommit: (String) -> Void
    let onDelete: () -> Void

    /// Edit draft — local to the row: no need to push every keystroke
    /// through the model until the edit is confirmed. It's reseeded from
    /// row.body on every expand (see collapsedRow.onTapGesture), so a
    /// cancelled edit doesn't survive the next opening.
    @State private var editText: String = ""
    @State private var isHovering = false

    private static let editorHeight: CGFloat = 44

    var body: some View {
        Group {
            if isExpanded {
                expandedRow
            } else {
                collapsedRow
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(isExpanded ? 0.1 : (isHovering ? 0.08 : 0.05)))
        )
        .onHover { isHovering = $0 }
    }

    private var collapsedRow: some View {
        HStack(spacing: 8) {
            content
            if isHovering {
                deleteButton
            }
        }
    }

    /// Date and preview are combined into one accessible region — this is
    /// exactly the tappable area that triggers expansion, which is why
    /// combine/label/trait live here, not on the whole row (see the
    /// type's doc).
    private var content: some View {
        HStack(spacing: 8) {
            Text(row.relativeDate)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(accent)
                .frame(width: 44, alignment: .leading)
            Text(Self.previewLine(for: row.body, maxLength: 90))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            editText = row.body
            onToggle()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Note from \(row.relativeDate): \(row.body)")
        .accessibilityAddTraits(.isButton)
    }

    private var expandedRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(row.relativeDate)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(accent)
                Spacer()
                deleteButton
            }
            TextEditor(text: $editText)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.9))
                .scrollContentBackground(.hidden)
                .frame(height: Self.editorHeight)
                // The same TextEditor bug as the composer field above (see
                // its doc in NoteComposerView.field) — without .clipped()
                // this editor would grow the same way the first time it's
                // expanded.
                .clipped()
                .accessibilityLabel("Note text")
            editorActions
        }
    }

    /// Both buttons are literal `Button`s, not routed through a wrapping
    /// view: `.keyboardShortcut` on "Save" binds to the control it's
    /// called on directly, it doesn't "shine through" a composite wrapper
    /// (the same approach and the same rationale as
    /// NoteComposerView.saveButton).
    private var editorActions: some View {
        HStack(spacing: 10) {
            Button("Cancel", action: onToggle)
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.5))
            Spacer(minLength: 0)
            Button("Save") { onCommit(editText) }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isEditEmpty ? .white.opacity(0.25) : accent)
                .disabled(isEditEmpty)
                .keyboardShortcut(.return, modifiers: .command)
        }
    }

    private var isEditEmpty: Bool {
        editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Trash icon — on hover or while the row is expanded, not
    /// permanently: deletion is irreversible enough that it shouldn't sit
    /// in view on every note in its collapsed state.
    private var deleteButton: some View {
        Button(action: onDelete) {
            Image(systemName: "trash")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.4))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Delete note")
    }

    /// Note flattened to a single line for the collapsed card: newlines
    /// collapse into spaces, otherwise Text with lineLimit(1) would
    /// truncate right at the first "\n" rather than by width, hiding the
    /// rest of the text without an ellipsis. The same approach as
    /// ClipboardCard.preview, but an independent copy — tabs shouldn't
    /// depend on each other for a helper function that might diverge
    /// tomorrow (e.g. showing the first non-empty line instead of
    /// collapsing them all).
    private static func previewLine(for body: String, maxLength: Int) -> String {
        let flattened = body
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard flattened.count > maxLength else { return flattened }
        return flattened.prefix(maxLength) + "…"
    }
}

/// The composer's round save button. Accent fill when enabled is the only
/// "Obsidian" color here, and it signals the action's availability itself
/// rather than just decorating the button; otherwise the background is
/// low-opacity white and the glyph is white, the same visual language as
/// the rest of the panel's chrome.
private struct NoteActionButtonStyle: ButtonStyle {
    let isEnabled: Bool
    let isHovering: Bool
    let accent: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Circle().fill(backdropColor))
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
    }

    private var backdropColor: Color {
        guard isEnabled else { return .white.opacity(0.06) }
        return accent.opacity(isHovering ? 1 : 0.85)
    }
}
