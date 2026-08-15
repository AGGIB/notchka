import SwiftUI
import NotchCore

/// A single pinned snippet on the pins grid.
///
/// A separate type from `StashKit.Snippet` — the same trick as
/// `ClipboardCard` relative to `ClipboardItem` (see its doc in
/// ClipboardTabView.swift): NotchUI doesn't know about StashKit, only about
/// the ready-made display model built by the app target (PinsViewModel).
public struct PinChip: Identifiable, Equatable, Sendable {
    /// `nil` — a draft in the add form, not yet saved to the database. Every
    /// pin actually shown on the grid always has an id: PinsViewModel
    /// builds chips from an already-read list, where GRDB assigns the id on
    /// insert (see Snippet.didInsert).
    public let id: Int64?
    public let label: String
    public let value: String
    public let isSensitive: Bool
    public let colorHex: String?
    public let icon: String?

    public init(
        id: Int64?, label: String, value: String, isSensitive: Bool,
        colorHex: String?, icon: String?
    ) {
        self.id = id
        self.label = label
        self.value = value
        self.isSensitive = isSensitive
        self.colorHex = colorHex
        self.icon = icon
    }

    /// What's drawn on the chip: a fixed mask for sensitive values,
    /// length-truncated for long ones. The truncation reuses
    /// `ClipboardCard.preview` — the same "collapse newlines and truncate by
    /// length" rule used for clipboard cards, rather than a second copy of
    /// the same algorithm in this module.
    public var displayValue: String {
        isSensitive ? Self.mask : ClipboardCard.preview(for: value, maxLength: Self.maxDisplayLength)
    }

    /// What actually goes to the pasteboard and gets inserted on click — the
    /// original value in full, not what's drawn on the chip (decision #1
    /// of the task spec).
    public var pasteValue: String { value }

    /// Color of the left-hand stripe. Always returns a value: for an empty
    /// or unparsable `colorHex` a neutral default is substituted instead of
    /// nil — `PinsTabView` has no `accent` input parameter, unlike
    /// ClipboardTabView/MusicTabView (see its doc), so each pin must decide
    /// its own color on its own.
    public var accentOrDefault: Color {
        colorHex.flatMap(Self.resolvedColor(fromHex:)) ?? Self.defaultAccent
    }

    /// The same mask as `StashKit.Snippet.masked` — fixed length, doesn't
    /// leak the real value's length (otherwise an IIN could be told apart
    /// from a card number just by its dot count). The string is duplicated,
    /// not reused: NotchUI doesn't depend on StashKit (see the type doc
    /// above).
    private static let mask = "••• ••• •••"

    /// Chosen so a chip in the two-column grid doesn't stretch across the
    /// whole panel width for one long value: short emails and phone numbers
    /// fit in full, while addresses and accidentally pasted long text get
    /// truncated with an ellipsis.
    private static let maxDisplayLength = 26

    private static let defaultAccent = Color.white.opacity(0.45)

    /// Parses `"#RRGGBB"`/`"RRGGBB"`. Any other input — a typo, random text
    /// — isn't a color, but that's not a reason to drop the card: a pin is
    /// added manually through the form, and an error in six characters
    /// shouldn't cost the whole entry (see PinChipTests.badColourFallsBack).
    ///
    /// `fileprivate`, not `private`: PinEditorView below, in this same file,
    /// reuses it for the color preview in the selection palette — a second
    /// copy of the same hex-parsing rule would be duplication.
    fileprivate static func resolvedColor(fromHex hex: String) -> Color? {
        var sanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if sanitized.hasPrefix("#") { sanitized.removeFirst() }
        guard sanitized.count == 6, let value = UInt32(sanitized, radix: 16) else { return nil }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

/// Grid of pinned snippets: email, card number, IIN — the whole reason this
/// project exists (see the task brief). Two columns, not a horizontal strip
/// like the clipboard: pins are short and single-line, and a vertical grid
/// fits more in the same area without horizontal scrolling.
///
/// Order changes by dragging (decision #2 of the spec) — each chip is
/// simultaneously both `.draggable` and a `.dropDestination`, not a
/// separate handle: a compact chip has no room for a handle, and dragging
/// the whole card is a standard gesture for both Finder and similar macOS
/// grids.
///
/// The add/edit form lives right here, inside the tab, switching via local
/// state — the same trick as the inline notes editor: this app has no
/// separate windows for subtasks, all work happens within the bounds of one
/// panel.
public struct PinsTabView: View {
    private let chips: [PinChip]
    private let onActivate: (Int64) -> Void
    private let onCopyOnly: (Int64) -> Void
    private let onReorder: (Int64, Int) -> Void
    private let onEdit: (PinChip) -> Void

    /// ⌥ state — one for the whole grid, the same trick and the same
    /// rationale as `ClipboardTabView.isOptionHeld`.
    @State private var isOptionHeld = false

    @State private var editorMode: EditorMode = .hidden
    @State private var draftLabel = ""
    @State private var draftValue = ""
    @State private var draftIsSensitive = false
    @State private var draftColorHex: String?
    @State private var draftIcon: String?

    private static let chipSpacing: CGFloat = 8
    private static let columns = [GridItem(.flexible()), GridItem(.flexible())]

    /// What's shown right now instead of the grid: nothing, the new-pin
    /// form, or the edit form for an existing one. A separate enum, not two
    /// interleaved optionals (`Bool` + `PinChip?`) — otherwise "creating a
    /// new one" and "not editing anything" would have to be distinguished
    /// by state that doesn't express that on its own.
    private enum EditorMode: Equatable {
        case hidden
        case creating
        case editing(PinChip)
    }

    public init(
        chips: [PinChip],
        onActivate: @escaping (Int64) -> Void,
        onCopyOnly: @escaping (Int64) -> Void,
        onReorder: @escaping (Int64, Int) -> Void,
        onEdit: @escaping (PinChip) -> Void
    ) {
        self.chips = chips
        self.onActivate = onActivate
        self.onCopyOnly = onCopyOnly
        self.onReorder = onReorder
        self.onEdit = onEdit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            switch editorMode {
            case .hidden: content
            case .creating, .editing: editorView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onModifierKeysChanged(mask: .option, initial: true) { _, new in
            isOptionHeld = new.contains(.option)
        }
    }

    /// The tab header reminds of the click rule (decision #3 of the spec) —
    /// the only place it's written out in full: the chip itself gives no
    /// indication that ⌥ changes its behavior.
    private var header: some View {
        HStack {
            Text("Click — paste · ⌥click — copy")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
            Spacer(minLength: 8)
            if editorMode == .hidden {
                addButton
            }
        }
    }

    private var addButton: some View {
        Button(action: startCreating) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 22, height: 22)
                .background(Circle().fill(.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add pin")
    }

    @ViewBuilder
    private var content: some View {
        if chips.isEmpty {
            emptyState
        } else {
            grid
        }
    }

    /// An honest empty screen — the same principle as "Clipboard is empty"
    /// in ClipboardTabView: the tab already works, there's just nothing to
    /// show yet.
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: NotchTab.pins.symbolName)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.white.opacity(0.22))
            Text("No pins yet")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var grid: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(columns: Self.columns, spacing: Self.chipSpacing) {
                ForEach(chips) { chip in
                    PinChipView(chip: chip, onTap: { handleTap(chip) }, onEditTap: { startEditing(chip) })
                        .draggable(dragPayload(chip))
                        .dropDestination(for: String.self) { items, _ in
                            handleDrop(items, onto: chip)
                        }
                }
            }
            .padding(.trailing, 2)
        }
    }

    private var editorView: some View {
        PinEditorView(
            label: $draftLabel, value: $draftValue, isSensitive: $draftIsSensitive,
            colorHex: $draftColorHex, icon: $draftIcon,
            canSave: canSaveDraft, onSave: commitDraft, onCancel: { editorMode = .hidden }
        )
    }

    private var canSaveDraft: Bool {
        !draftLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !draftValue.isEmpty
    }

    private func handleTap(_ chip: PinChip) {
        guard let id = chip.id else { return }
        if isOptionHeld { onCopyOnly(id) } else { onActivate(id) }
    }

    private func startCreating() {
        draftLabel = ""
        draftValue = ""
        draftIsSensitive = false
        draftColorHex = nil
        draftIcon = nil
        editorMode = .creating
    }

    private func startEditing(_ chip: PinChip) {
        draftLabel = chip.label
        draftValue = chip.value
        draftIsSensitive = chip.isSensitive
        draftColorHex = chip.colorHex
        draftIcon = chip.icon
        editorMode = .editing(chip)
    }

    /// Assembles the final chip from the form fields and hands it out via
    /// `onEdit` — the id comes from the edited chip (editing) or stays
    /// empty (new pin); which of the two actually happened — add or update —
    /// is decided by PinsViewModel from that id (see "what to wire up" in
    /// the report).
    private func commitDraft() {
        let id: Int64?
        switch editorMode {
        case .editing(let chip): id = chip.id
        default: id = nil
        }
        onEdit(PinChip(
            id: id, label: draftLabel.trimmingCharacters(in: .whitespacesAndNewlines), value: draftValue,
            isSensitive: draftIsSensitive, colorHex: draftColorHex, icon: draftIcon
        ))
        editorMode = .hidden
    }

    /// Only persistent pins end up in `chips` — they always have an id,
    /// guaranteed by PinsViewModel, which builds chips from an already-read
    /// database. `0` here is unreachable in practice, not a silent lie: an
    /// empty id would drop `.draggable` entirely, not just cause a miss on
    /// drag.
    private func dragPayload(_ chip: PinChip) -> String {
        String(chip.id ?? 0)
    }

    /// `Void`, not `Bool`: on macOS 26 `dropDestination(for:action:)`
    /// without `isEnabled` resolves to the overload taking `DropSession`
    /// and returning `-> Void`, not the older `-> Bool` one — with `Bool`
    /// the compiler here silently accepted the signature but dropped a
    /// "result … is unused" warning: the return value went to the overload
    /// that doesn't read it. An explicit `Void` removes the very
    /// possibility of hitting the wrong overload, not just the warning.
    private func handleDrop(_ items: [String], onto chip: PinChip) {
        guard let raw = items.first, let draggedID = Int64(raw),
              let destinationIndex = chips.firstIndex(where: { $0.id == chip.id })
        else { return }
        onReorder(draggedID, destinationIndex)
    }
}

/// One grid card: a colored stripe on the left, an icon, a label, and a
/// value. Editing is triggered by a separate pencil button, not a tap on
/// the whole card — a tap on the card is already taken by paste/copy, and a
/// second meaning for the same gesture wouldn't be distinguishable to the
/// user from the first one until the moment of the tap.
private struct PinChipView: View {
    let chip: PinChip
    let onTap: () -> Void
    let onEditTap: () -> Void

    @State private var isHovering = false

    private static let height: CGFloat = 52
    private static let cornerRadius: CGFloat = 12
    private static let stripeWidth: CGFloat = 3

    var body: some View {
        HStack(spacing: 0) {
            stripe
            info
        }
        .frame(height: Self.height)
        .background(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(.white.opacity(isHovering ? 0.1 : 0.06))
        )
        .overlay(alignment: .topTrailing) { editButton }
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }

    private var stripe: some View {
        Rectangle()
            .fill(chip.accentOrDefault)
            .frame(width: Self.stripeWidth)
            .frame(maxHeight: .infinity)
    }

    private var info: some View {
        HStack(spacing: 8) {
            Image(systemName: chip.icon ?? NotchTab.pins.symbolName)
                .font(.system(size: 13))
                .foregroundStyle(chip.accentOrDefault)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(chip.label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                Text(chip.displayValue)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// Visible not only on hover but always at low opacity: on a trackpad
    /// hover is detected worse than with a mouse, and a button that's
    /// entirely invisible at rest would be undiscoverable from a single
    /// glance at the panel.
    private var editButton: some View {
        Button(action: onEditTap) {
            Image(systemName: "pencil")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(isHovering ? 0.85 : 0.25))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .padding(4)
        .accessibilityLabel("Edit \"\(chip.label)\"")
    }

    private var accessibilityLabel: String {
        let valueLabel = chip.isSensitive ? "value hidden" : chip.displayValue
        return "\(chip.label): \(valueLabel)"
    }
}

/// The pin add/edit form. Save and cancel buttons are pinned at the bottom
/// outside the scroll area — the fields above may scroll, but shouldn't
/// carry away the only way to close the form.
private struct PinEditorView: View {
    @Binding var label: String
    @Binding var value: String
    @Binding var isSensitive: Bool
    @Binding var colorHex: String?
    @Binding var icon: String?
    let canSave: Bool
    let onSave: () -> Void
    let onCancel: () -> Void

    private static let presetIcons = [
        "envelope.fill", "creditcard.fill", "number", "house.fill", "phone.fill", "key.fill",
    ]
    private static let presetColors = [
        "#FF2D95", "#0A84FF", "#30D158", "#FF9F0A", "#BF5AF2", "#FF453A",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    labelField
                    valueField
                    sensitiveToggle
                    iconRow
                    colorRow
                }
            }
            buttons
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var labelField: some View {
        TextField("Label", text: $label)
            .textFieldStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .padding(6)
            .background(fieldBackground)
    }

    private var valueField: some View {
        TextField("Value", text: $value)
            .textFieldStyle(.plain)
            .font(.system(size: 11))
            .padding(6)
            .background(fieldBackground)
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(0.08))
    }

    /// The toggle uses the same neutral white as the rest of "Obsidian"'s
    /// chrome: the system `.switch` is tinted with the macOS accent color by
    /// default, and the only color allowed here to be a color, rather than
    /// white at varying opacity, is the pin itself (see
    /// PinChip.accentOrDefault).
    private var sensitiveToggle: some View {
        Toggle(isOn: $isSensitive) {
            Text("Sensitive value")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.75))
        }
        .toggleStyle(.switch)
        .tint(.white.opacity(0.5))
    }

    private var iconRow: some View {
        HStack(spacing: 5) {
            ForEach(Self.presetIcons, id: \.self) { symbol in
                Button(action: { icon = symbol }) {
                    Image(systemName: symbol)
                        .font(.system(size: 10))
                        .foregroundStyle(icon == symbol ? .black : .white.opacity(0.6))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(icon == symbol ? .white : .white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Icon \(symbol)")
            }
        }
    }

    private var colorRow: some View {
        HStack(spacing: 5) {
            ForEach(Self.presetColors, id: \.self) { hex in
                Button(action: { colorHex = hex }) {
                    Circle()
                        .fill(PinChip.resolvedColor(fromHex: hex) ?? .white)
                        .frame(width: 16, height: 16)
                        .overlay(Circle().stroke(.white, lineWidth: colorHex == hex ? 2 : 0))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Color \(hex)")
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Button("Cancel", action: onCancel)
                .buttonStyle(PinEditorButtonStyle(isProminent: false))
                .keyboardShortcut(.cancelAction)
            Button("Save", action: onSave)
                .buttonStyle(PinEditorButtonStyle(isProminent: true))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSave)
        }
    }
}

/// Form buttons. The same trick as PlayPauseButtonStyle/PermissionButtonStyle
/// elsewhere in the panel: the prominent one is solid white with black text,
/// the one deliberate exception to "white at varying opacity" for the sake
/// of an unambiguously clickable primary action; the secondary one is a
/// low-opacity plate. Doesn't reuse PermissionButtonStyle directly: that one
/// lives in PermissionPromptView.swift as a private type of that file.
private struct PinEditorButtonStyle: ButtonStyle {
    let isProminent: Bool

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .foregroundStyle(isProminent ? .black : .white.opacity(0.85))
            .background(backdrop)
            .clipShape(Capsule())
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
    }

    @ViewBuilder
    private var backdrop: some View {
        if isProminent {
            Capsule().fill(.white.opacity(0.9))
        } else {
            Capsule().fill(.white.opacity(0.08))
        }
    }
}
