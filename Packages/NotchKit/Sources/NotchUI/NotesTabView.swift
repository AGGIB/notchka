import SwiftUI
import Foundation
import NotchCore

/// Относительная подпись времени заметки: время — сегодня, «вчера» — вчера,
/// календарная дата — раньше.
///
/// Вынесено из вьюхи по тому же принципу, что и TrackFormatting в
/// MusicTabView: чистая функция от даты и точки отсчёта, которую тест
/// проверяет без окна.
public enum NoteFormatting {
    /// `calendar` — параметром со значением по умолчанию `.current`, а не
    /// `.current` внутри тела напрямую: иначе «сегодня» и «вчера» зависели
    /// бы от часового пояса машины, на которой запущен код, а не от
    /// переданных дат — тест, зелёный у автора, был бы красным у того, кто
    /// запустит его восточнее или западнее (см. NoteFormattingTests).
    ///
    /// Порог — календарные сутки, а не «минус 24 часа»: заметка, сделанная
    /// в 23:59, при вычитании фиксированного интервала показывала бы
    /// «вчера» уже через минуту, хотя календарно это тот же день.
    /// `Calendar.isDate(_:inSameDayAs:)` сравнивает именно по суткам, и
    /// сравнение не зависит от знака разницы — будущая дата не роняет его.
    public static func relativeDate(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return timeOfDay(date, calendar: calendar)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "вчера"
        }
        return calendarDate(date, calendar: calendar)
    }

    /// «14:32» — часы и минуты по переданному календарю. Ручной расчёт двух
    /// компонентов, а не DateFormatter: формат фиксирован (24-часовой, с
    /// нулём спереди) и не подстраивается под локаль, так что объект
    /// форматтера здесь не даёт ничего, кроме лишней аллокации.
    private static func timeOfDay(_ date: Date, calendar: Calendar) -> String {
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        return String(format: "%02d:%02d", hour, minute)
    }

    /// «15 янв» — день и сокращённое имя месяца через DateFormatter, а не
    /// свой массив названий: у переданного `calendar` может быть любая
    /// система (сигнатура не требует григорианский), и свой список из 12
    /// русских имён был бы неверен или вышел бы за его пределы — в
    /// еврейском календаре, например, в високосный год 13 месяцев. ICU
    /// внутри DateFormatter знает имена месяцев для любой системы разом.
    private static func calendarDate(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.setLocalizedDateFormatFromTemplate("d MMM")
        return formatter.string(from: date)
    }
}

/// Одна заметка для отображения во вкладке — снимок на момент чтения, а не
/// живая ссылка на запись базы (то же решение, что и у ClipboardCard).
///
/// `relativeDate` уже посчитан вызывающей стороной (см. NotesViewModel) от
/// `createdAt`, а не `updatedAt`: список отсортирован по времени создания
/// (см. doc NotesRepository.all()), и подпись обязана согласовываться с
/// этим порядком — иначе строка «сегодня» оказалась бы внизу ленты у
/// заметки, которую лишь недавно поправили, а создали неделю назад.
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

/// Вкладка быстрых заметок: поле создания сверху, лента ниже.
///
/// Без markdown-рендера и без отдельного окна редактирования — решение
/// владельца: инлайн-редактор размером с ладонь не место для форматирования
/// (см. бриф задачи 5, спека §7).
public struct NotesTabView: View {
    private let rows: [NoteRow]
    private let draft: Binding<String>
    private let accent: Color
    private let onSave: () -> Void
    private let onCommitEdit: (NoteRow.ID, String) -> Void
    private let onDelete: (NoteRow.ID) -> Void

    /// Какая заметка сейчас раскрыта инлайн-редактором.
    ///
    /// Локальное состояние вьюхи, а не модели: в отличие от
    /// ClipboardViewModel.selectedID (который отражает реальное содержимое
    /// пастборда — факт, осмысленный и за пределами вьюхи), то, какая
    /// заметка раскрыта прямо сейчас, не значит ничего вне текущего сеанса
    /// просмотра панели — тот же класс состояния, что и isHovering у
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
                // Пока раскрыт инлайн-редактор существующей заметки, ⌘↩
                // композера отключается (см. doc NoteComposerView) — иначе
                // одно и то же сочетание было бы навешено разом на две
                // кнопки, и то, какая из них сработает, решал бы responder
                // chain, а не код.
                isEnabled: expandedID == nil,
                onSave: onSave
            )
            if rows.isEmpty {
                // Честный пустой экран — тот же приём, что у «Буфер пуст»
                // в ClipboardTabView и «Ничего не играет» в MusicTabView.
                Text("Заметок пока нет")
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
            // Хвост ленты не должен обрезаться заподлицо с краем скролла —
            // тот же приём, что и у горизонтальной ленты ClipboardTabView.
            .padding(.bottom, 2)
        }
    }

    private func toggle(_ id: NoteRow.ID) {
        expandedID = (expandedID == id) ? nil : id
    }
}

/// Поле создания новой заметки.
///
/// `⌘↩` сохраняет, обычный `↩` переносит строку: заметка может занимать
/// больше одной строки, и Return, отправляющий её на середине мысли, мешал
/// бы, а не помогал — decision №1 постановки задачи 5.
private struct NoteComposerView: View {
    @Binding var text: String
    let accent: Color
    /// `false`, пока раскрыт инлайн-редактор другой заметки — см. doc
    /// вызова в NotesTabView.body.
    let isEnabled: Bool
    let onSave: () -> Void

    @State private var isSaveHovering = false

    private static let fieldHeight: CGFloat = 40
    private static let buttonDiameter: CGFloat = 26

    /// Пустой ввод не даёт нажать сохранение — первая линия защиты из двух,
    /// требуемых постановкой (см. doc NotesViewModel.saveDraft для второй,
    /// на случай гонки за эту проверку).
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

    private var field: some View {
        TextEditor(text: $text)
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.9))
            // Без этого TextEditor рисует свой непрозрачный системный фон
            // поверх чёрной панели — на «Обсидиане» это выглядело бы дырой.
            .scrollContentBackground(.hidden)
            .frame(height: Self.fieldHeight)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Новая заметка…")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.3))
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(0.06))
            )
            .accessibilityLabel("Новая заметка")
    }

    /// Кнопка сохранения — обязательно настоящий `Button`, а не вьюха,
    /// оборачивающая его: `.keyboardShortcut` привязывается к элементу
    /// управления, на котором вызван напрямую, а не «просвечивает» сквозь
    /// составную обёртку.
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
        .accessibilityLabel("Сохранить заметку")
    }
}

/// Одна заметка ленты: свёрнутая строка или раскрытый инлайн-редактор.
///
/// Свёрнутое и раскрытое состояния — разные ветки `body`, а не один и тот же
/// каркас с условной начинкой: у раскрытого состояния несколько независимо
/// доступных элементов управления (поле, «Отмена», «Сохранить»), и общий
/// `.accessibilityElement(children: .combine)` на весь блок сделал бы их
/// недостижимыми для VoiceOver по отдельности — см. ниже collapsedRow, где
/// combine применён только к описательному тексту, не к кнопке удаления.
private struct NoteRowView: View {
    let row: NoteRow
    let isExpanded: Bool
    let accent: Color
    let onToggle: () -> Void
    let onCommit: (String) -> Void
    let onDelete: () -> Void

    /// Черновик правки — локальный для строки: гонять каждое нажатие
    /// клавиши через модель незачем, пока правка не подтверждена. Заводится
    /// заново из row.body при каждом раскрытии (см. collapsedRow.onTapGesture),
    /// так что отменённая правка не переживает следующее открытие.
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

    /// Дата и превью объединены в одну доступную область — это и есть
    /// кликабельная зона раскрытия, поэтому combine/label/trait висят
    /// именно здесь, а не на всей строке (см. doc типа).
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
        .accessibilityLabel("Заметка от \(row.relativeDate): \(row.body)")
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
                .accessibilityLabel("Текст заметки")
            editorActions
        }
    }

    /// Обе кнопки — буквальные `Button`, не через оборачивающую вьюху:
    /// `.keyboardShortcut` на «Сохранить» привязывается к элементу
    /// управления, на котором вызван напрямую, а не «просвечивает» сквозь
    /// составную обёртку (тот же приём и то же обоснование, что у
    /// NoteComposerView.saveButton).
    private var editorActions: some View {
        HStack(spacing: 10) {
            Button("Отмена", action: onToggle)
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.5))
            Spacer(minLength: 0)
            Button("Сохранить") { onCommit(editText) }
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

    /// Корзина — по наведению или пока строка раскрыта, не постоянно:
    /// удаление достаточно необратимо, чтобы не держать его на виду у
    /// каждой заметки в свёрнутом состоянии.
    private var deleteButton: some View {
        Button(action: onDelete) {
            Image(systemName: "trash")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.4))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Удалить заметку")
    }

    /// Заметка одной строкой для свёрнутой карточки: переводы строк
    /// схлопываются в пробелы, иначе Text с lineLimit(1) обрежет ровно по
    /// первому «\n», а не по ширине, и спрячет остальной текст без
    /// многоточия. Тот же приём, что у ClipboardCard.preview, но
    /// независимая копия — вкладки не должны зависеть друг от друга ради
    /// вспомогательной функции, которая завтра может разойтись (например,
    /// показ первой непустой строки вместо схлопывания всех).
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

/// Круглая кнопка сохранения композера. Заливка акцентом, когда доступна, —
/// единственный цвет «Обсидиана» здесь и обозначает саму доступность
/// действия, а не просто украшает кнопку; в остальном фон — белый низкой
/// прозрачности, глиф — белый, тем же языком, что и остальной хром панели.
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
