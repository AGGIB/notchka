import SwiftUI

/// Карточка ленты буфера обмена.
///
/// `Sendable` сознательно не выведен: `thumbnail` хранит SwiftUI `Image`,
/// который сам не `Sendable` (может оборачивать платформенный NSImage), а
/// присваивать конформанс через `@unchecked` ради этого поля было бы
/// обманом типа. `ClipboardCard` строится, хранится и читается только на
/// MainActor — как и всё остальное дерево SwiftUI панели, — и этого
/// достаточно; отдельной гарантии межпотокового обмена она не даёт и не
/// должна.
public struct ClipboardCard: Identifiable, Equatable {
    public enum Kind: Sendable { case text, image, file }

    public let id: Int64
    public let kind: Kind
    public let preview: String
    public let source: String
    public let isPinned: Bool
    /// Готовая картинка для карточки-скриншота.
    ///
    /// Именно `Image`, а не байты: NotchUI не импортирует AppKit, а без него
    /// собрать картинку из `Data` в SwiftUI нечем — `Image(data:)` не
    /// существует. Поэтому картинку строит app-таргет и передаёт готовой,
    /// ровно как уже сделано с обложкой альбома в MusicTabView.
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

    /// Превью для карточки.
    ///
    /// Переводы строк схлопываются, потому что карточка фиксированной
    /// высоты: многострочный текст иначе обрежется на первой строке и
    /// станет неузнаваемым.
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

/// Горизонтальная лента истории буфера обмена.
///
/// Лента, а не список — решение владельца на этапе дизайна: раскрытая
/// панель невысокая (см. PanelMetrics.expandedSize), а лента вдобавок
/// показывает картинки картинками, а не одной подписанной строкой на
/// элемент, как было бы в списке.
public struct ClipboardTabView: View {
    private let cards: [ClipboardCard]
    private let selected: ClipboardCard.ID?
    private let accent: Color
    private let onActivate: (ClipboardCard.ID) -> Void
    private let onCopyOnly: (ClipboardCard.ID) -> Void

    /// Состояние ⌥ — одно на всю ленту, а не по одному на карточку: клавиша
    /// либо зажата, либо нет, сразу для всех карточек. `onModifierKeysChanged`
    /// (macOS 15+) даёт этот статус без единого обращения к AppKit/NSEvent —
    /// NotchUI импортировать AppKit не должен (Global Constraints плана).
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
            // Честный пустой экран — тот же принцип, что в MusicTabView для
            // отсутствующего трека: вкладка уже работает, просто пока
            // нечего показать, это не «Скоро появится» (TabPlaceholderView).
            Text("Буфер пуст")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.4))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Self.cardSpacing) {
                    ForEach(cards) { card in
                        ClipboardCardView(card: card, isSelected: card.id == selected, accent: accent) {
                            // Решение №2 постановки: клик вставляет, ⌥клик
                            // только копирует. Само решение, каким действием
                            // ответить на клик, принимает вызывающая сторона
                            // (ClipboardViewModel) — карточка лишь сообщает id.
                            if isOptionHeld { onCopyOnly(card.id) } else { onActivate(card.id) }
                        }
                    }
                }
                // Хвост ленты не должен обрезаться заподлицо с краем скролла.
                .padding(.trailing, 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onModifierKeysChanged(mask: .option, initial: true) { _, new in
                isOptionHeld = new.contains(.option)
            }
        }
    }
}

/// Одна карточка ленты. Решение «вставить или скопировать» принимает
/// контейнер (см. ClipboardTabView.body) по общему для всей ленты статусу
/// ⌥ — карточка лишь сообщает о клике через onTap.
private struct ClipboardCardView: View {
    let card: ClipboardCard
    let isSelected: Bool
    let accent: Color
    let onTap: () -> Void

    @State private var isHovering = false

    private static let width: CGFloat = 76
    /// 202 pt — высота области содержимого раскрытой панели (PanelMetrics
    /// .expandedSize.height 240, минус отступы NotchPanelView.tabBody: 240 −
    /// 38 = 202). Та же величина и то же обоснование, что у MusicTabView
    /// .artworkSize — карточка занимает её почти целиком, не убегая за край.
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

    /// Ради этого поля целиком и затевался Step 3: скриншот обязан
    /// показывать себя, а не подпись «Снимок экрана» (см. thumbnail на
    /// ClipboardCard). Запасной вариант ниже — честный случай отказа
    /// декодирования байтов, а не ожидаемый путь.
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

    /// Источник — единственная подпись внизу карточки. Акцентным цветом, а
    /// не белым: тот же приём, что и у sourceBadge в MusicTabView, только
    /// без капсулы — на 76 pt ширины ей не хватило бы места.
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

    /// Выделенная карточка обводится акцентным цветом — единственный цвет
    /// «Обсидиана», остальное здесь белое разной прозрачности.
    @ViewBuilder
    private var selectionOutline: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .stroke(accent, lineWidth: 2)
        }
    }

    private var accessibilityLabel: String {
        let kindLabel = switch card.kind {
        case .text: "Текст"
        case .image: "Изображение"
        case .file: "Файл"
        }
        let pinSuffix = card.isPinned ? ", закреплено" : ""
        return "\(kindLabel): \(card.preview). Источник: \(card.source)\(pinSuffix)"
    }
}
