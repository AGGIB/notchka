import SwiftUI

/// Clipboard history strip card.
public struct ClipboardCard: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable { case text, image, file }

    public let id: Int64
    public let kind: Kind
    public let preview: String
    public let source: String
    public let isPinned: Bool
    /// Ready-made image for a screenshot card.
    ///
    /// `Image`, not raw bytes: NotchUI doesn't import AppKit, and without it
    /// there's nothing in SwiftUI to build an image from `Data` with —
    /// `Image(data:)` doesn't exist. So the app target builds the image and
    /// passes it in ready-made, exactly as already done for album art in
    /// MusicTabView.
    public let thumbnail: Image?

    public init(
        id: Int64, kind: Kind, preview: String, source: String,
        isPinned: Bool, thumbnail: Image? = nil
    ) {
        self.id = id
        self.kind = kind
        self.preview = preview
        self.source = source
        self.isPinned = isPinned
        self.thumbnail = thumbnail
    }

    /// Preview text for the card.
    ///
    /// Line breaks are collapsed because the card has a fixed height:
    /// otherwise multiline text would get cut off at the first line and
    /// become unrecognizable.
    public static func preview(for text: String, maxLength: Int) -> String {
        let flattened = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard flattened.count > maxLength else { return flattened }
        return flattened.prefix(maxLength) + "…"
    }
}

/// Horizontal strip of clipboard history.
///
/// A strip, not a list — an owner decision made at the design stage: the
/// expanded panel is short (see PanelMetrics.expandedSize), and a strip
/// also shows images as images rather than one captioned line per item,
/// as a list would.
public struct ClipboardTabView: View {
    private let cards: [ClipboardCard]
    private let selected: ClipboardCard.ID?
    private let accent: Color
    private let onActivate: (ClipboardCard.ID) -> Void
    private let onCopyOnly: (ClipboardCard.ID) -> Void

    /// ⌥ state — one for the whole strip, not per card: the key is either
    /// held or not, for all cards at once. `onModifierKeysChanged`
    /// (macOS 15+) gives this status without a single call to AppKit/NSEvent —
    /// NotchUI must not import AppKit (per the plan's Global Constraints).
    @State private var isOptionHeld = false

    private static let cardSpacing: CGFloat = 10

    public init(
        cards: [ClipboardCard],
        selected: ClipboardCard.ID?,
        accent: Color,
        onActivate: @escaping (ClipboardCard.ID) -> Void,
        onCopyOnly: @escaping (ClipboardCard.ID) -> Void
    ) {
        self.cards = cards
        self.selected = selected
        self.accent = accent
        self.onActivate = onActivate
        self.onCopyOnly = onCopyOnly
    }

    public var body: some View {
        if cards.isEmpty {
            // Honest empty state — same principle as MusicTabView for a missing
            // track: the tab already works, there's just nothing to show yet;
            // this isn't "Coming soon" (TabPlaceholderView).
            Text("Clipboard is empty")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.4))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Self.cardSpacing) {
                    ForEach(cards) { card in
                        ClipboardCardView(card: card, isSelected: card.id == selected, accent: accent) {
                            // Decision #2 from the spec: a click pastes, ⌥click
                            // only copies. The decision of which action to take
                            // in response to a click is made by the caller
                            // (ClipboardViewModel) — the card just reports the id.
                            if isOptionHeld { onCopyOnly(card.id) } else { onActivate(card.id) }
                        }
                    }
                }
                // The tail of the strip shouldn't be clipped flush with the scroll edge.
                .padding(.trailing, 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onModifierKeysChanged(mask: .option, initial: true) { _, new in
                isOptionHeld = new.contains(.option)
            }
        }
    }
}

/// A single strip card. The "paste or copy" decision is made by the
/// container (see ClipboardTabView.body) based on the strip-wide ⌥
/// status — the card just reports the tap via onTap.
private struct ClipboardCardView: View {
    let card: ClipboardCard
    let isSelected: Bool
    let accent: Color
    let onTap: () -> Void

    @State private var isHovering = false

    private static let width: CGFloat = 76
    /// 202 pt — height of the expanded panel's content area (PanelMetrics
    /// .expandedSize.height 240, minus NotchPanelView.tabBody's padding: 240 −
    /// 38 = 202). Same value and same rationale as MusicTabView's
    /// .artworkSize — the card fills nearly all of it without running off the edge.
    private static let height: CGFloat = 190
    private static let cornerRadius: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            content
            footer
        }
        .padding(8)
        .frame(width: Self.width, height: Self.height, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(.white.opacity(isHovering ? 0.12 : 0.07))
        )
        .overlay(alignment: .topTrailing) { pinBadge }
        .overlay(selectionOutline)
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var content: some View {
        switch card.kind {
        case .text:
            Text(card.preview)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.leading)
                .lineLimit(7)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .image:
            imageContent
        case .file:
            VStack(spacing: 6) {
                Image(systemName: "doc.fill")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(.white.opacity(0.4))
                Text(card.preview)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// This field is the entire reason Step 3 exists: a screenshot must
    /// show itself, not a "Screenshot" caption (see thumbnail on
    /// ClipboardCard). The fallback below is the honest case of a byte
    /// decoding failure, not the expected path.
    @ViewBuilder
    private var imageContent: some View {
        if let thumbnail = card.thumbnail {
            thumbnail
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            VStack(spacing: 4) {
                Image(systemName: "photo")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(.white.opacity(0.3))
                Text(card.preview)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Source is the only caption at the bottom of the card. In the accent
    /// color, not white: the same technique as sourceBadge in MusicTabView,
    /// just without the capsule — there wouldn't be room for it at 76 pt
    /// width.
    private var footer: some View {
        Text(card.source)
            .font(.system(size: 8, weight: .medium))
            .foregroundStyle(accent)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var pinBadge: some View {
        if card.isPinned {
            Image(systemName: "pin.fill")
                .font(.system(size: 8))
                .foregroundStyle(accent)
                .padding(4)
        }
    }

    /// A selected card gets an accent-colored outline — the only color in
    /// "Obsidian", everything else here is white at varying opacity.
    @ViewBuilder
    private var selectionOutline: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .stroke(accent, lineWidth: 2)
        }
    }

    private var accessibilityLabel: String {
        let kindLabel = switch card.kind {
        case .text: "Text"
        case .image: "Image"
        case .file: "File"
        }
        let pinSuffix = card.isPinned ? ", pinned" : ""
        return "\(kindLabel): \(card.preview). Source: \(card.source)\(pinSuffix)"
    }
}
