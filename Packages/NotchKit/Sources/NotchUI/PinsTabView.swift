import SwiftUI
import NotchCore

/// Один закреплённый сниппет на сетке пинов.
///
/// Отдельный от `StashKit.Snippet` тип — тот же приём, что и у
/// `ClipboardCard` относительно `ClipboardItem` (см. её doc в
/// ClipboardTabView.swift): NotchUI не знает про StashKit, только про уже
/// готовую модель показа, которую строит app-таргет (PinsViewModel).
public struct PinChip: Identifiable, Equatable, Sendable {
    /// `nil` — черновик формы добавления, ещё не сохранённый в базе. У всех
    /// пинов, реально показанных на сетке, id всегда есть: PinsViewModel
    /// строит чипы из уже прочитанного списка, где GRDB проставляет id при
    /// вставке (см. Snippet.didInsert).
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

    /// Что нарисовано на чипе: фиксированная маска для чувствительных,
    /// обрезанное по длине — для длинных. Труcкейт переиспользует
    /// `ClipboardCard.preview` — то же правило «схлопнуть переводы строк и
    /// обрезать по длине», что и у карточек буфера, а не второй такой же
    /// алгоритм в этом же модуле.
    public var displayValue: String {
        isSensitive ? Self.mask : ClipboardCard.preview(for: value, maxLength: Self.maxDisplayLength)
    }

    /// Что реально уходит в пастборд и вставляется по клику — исходное
    /// значение целиком, а не то, что нарисовано на чипе (решение №1
    /// постановки задачи).
    public var pasteValue: String { value }

    /// Цвет полосы слева. Всегда возвращает значение: при пустом или
    /// нечитаемом `colorHex` подставляется нейтральный дефолт, а не nil, —
    /// у `PinsTabView` нет входного параметра `accent`, в отличие от
    /// ClipboardTabView/MusicTabView (см. её doc), и каждый пин обязан сам
    /// решить, каким цветом рисоваться.
    public var accentOrDefault: Color {
        colorHex.flatMap(Self.resolvedColor(fromHex:)) ?? Self.defaultAccent
    }

    /// Та же маска, что у `StashKit.Snippet.masked` — фиксированной длины,
    /// не выдаёт длину настоящего значения (по числу точек ИИН отличим бы
    /// был от номера карты). Строка продублирована, а не переиспользована:
    /// NotchUI не зависит от StashKit (см. doc типа выше).
    private static let mask = "••• ••• •••"

    /// Подобрано так, чтобы чип в двухколоночной сетке не растягивался на
    /// всю ширину панели одним длинным значением: короткие email и номера
    /// телефонов умещаются целиком, адреса и вставленный по ошибке длинный
    /// текст — обрезаются с многоточием.
    private static let maxDisplayLength = 26

    private static let defaultAccent = Color.white.opacity(0.45)

    /// Разбирает `"#RRGGBB"`/`"RRGGBB"`. Любой другой ввод — опечатка,
    /// случайный текст — не цвет, а не повод ронять карточку: пин заводится
    /// вручную через форму, и ошибка в шести символах не должна стоить всей
    /// записи (см. PinChipTests.badColourFallsBack).
    ///
    /// `fileprivate`, а не `private`: PinEditorView ниже, в этом же файле,
    /// переиспользует её для предпросмотра цвета в палитре выбора — второй
    /// такой же разбор хексов был бы дублированием того же правила.
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

/// Сетка закреплённых сниппетов: почта, номер карты, ИИН — то, ради чего
/// затевался весь проект (см. бриф задачи). Два столбца, а не горизонтальная
/// лента, как у буфера: пины короткие и однострочные, вертикальная сетка
/// вмещает больше на той же площади без горизонтальной прокрутки.
///
/// Порядок меняется перетаскиванием (решение №2 постановки) — каждый чип
/// одновременно и `.draggable`, и `.dropDestination`, а не отдельная ручка:
/// на компактном чипе у ручки не нашлось бы места, а перетаскивание всей
/// карточки — стандартный жест и для Finder, и для похожих сеток macOS.
///
/// Форма добавления и правки живёт здесь же, внутри вкладки, переключаясь
/// локальным состоянием, — тем же приёмом, что и inline-редактор заметок:
/// в этом приложении нет отдельных окон под подзадачи, вся работа происходит
/// в границах одной панели.
public struct PinsTabView: View {
    private let chips: [PinChip]
    private let onActivate: (Int64) -> Void
    private let onCopyOnly: (Int64) -> Void
    private let onReorder: (Int64, Int) -> Void
    private let onEdit: (PinChip) -> Void

    /// Состояние ⌥ — одно на всю сетку, тем же приёмом и с тем же
    /// обоснованием, что и `ClipboardTabView.isOptionHeld`.
    @State private var isOptionHeld = false

    @State private var editorMode: EditorMode = .hidden
    @State private var draftLabel = ""
    @State private var draftValue = ""
    @State private var draftIsSensitive = false
    @State private var draftColorHex: String?
    @State private var draftIcon: String?

    private static let chipSpacing: CGFloat = 8
    private static let columns = [GridItem(.flexible()), GridItem(.flexible())]

    /// Что сейчас показано вместо сетки: ничего, форма нового пина или форма
    /// правки существующего. Отдельный enum, а не два optional вперемешку
    /// (`Bool` + `PinChip?`) — иначе «создаём новый» и «ничего не редактируем»
    /// пришлось бы различать состоянием, которое само по себе это не выражает.
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

    /// Заголовок вкладки напоминает правило клика (решение №3 постановки) —
    /// единственное место, где оно написано целиком: чип сам по себе ничем
    /// не показывает, что ⌥ меняет его поведение.
    private var header: some View {
        HStack {
            Text("Клик — вставить · ⌥клик — скопировать")
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
        .accessibilityLabel("Добавить пин")
    }

    @ViewBuilder
    private var content: some View {
        if chips.isEmpty {
            emptyState
        } else {
            grid
        }
    }

    /// Честный пустой экран — тот же принцип, что у «Буфер пуст» в
    /// ClipboardTabView: вкладка уже работает, просто пока нечего показать.
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: NotchTab.pins.symbolName)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.white.opacity(0.22))
            Text("Пока нет пинов")
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

    /// Собирает итоговый чип из полей формы и отдаёт его наружу через
    /// `onEdit` — id берётся из редактируемого чипа (правка) или остаётся
    /// пустым (новый пин); что из двух в итоге произошло — add или update —
    /// решает уже PinsViewModel по этому id (см. «что подключить» отчёта).
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

    /// Только персистентные пины попадают в `chips` — id у них всегда есть,
    /// это гарантирует PinsViewModel, строящий чипы из уже прочитанной базы.
    /// `0` здесь недостижим на практике, а не тихий обман: пустой id уронил
    /// бы `.draggable` целиком, а не просто дал бы промах при перетаскивании.
    private func dragPayload(_ chip: PinChip) -> String {
        String(chip.id ?? 0)
    }

    /// `Void`, а не `Bool`: на macOS 26 `dropDestination(for:action:)` без
    /// `isEnabled` резолвится в перегрузку с `DropSession` и `-> Void`, а не
    /// в более старую `-> Bool`, — с `Bool` здесь компилятор молча принимал
    /// сигнатуру, но ронял предупреждение «result … is unused»: возврат
    /// уходил в перегрузку, которая его не читает. Явный `Void` убирает саму
    /// возможность угодить не в ту перегрузку, а не только предупреждение.
    private func handleDrop(_ items: [String], onto chip: PinChip) {
        guard let raw = items.first, let draggedID = Int64(raw),
              let destinationIndex = chips.firstIndex(where: { $0.id == chip.id })
        else { return }
        onReorder(draggedID, destinationIndex)
    }
}

/// Одна карточка сетки: цветная полоса слева, иконка, метка и значение.
/// Правка вызывается отдельной кнопкой-карандашом, а не кликом по всей
/// карточке — клик по карточке уже занят вставкой/копированием, и второе
/// значение того же жеста ничем не отличалось бы для пользователя одно от
/// другого до самого нажатия.
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

    /// Видна не только по наведению, а всегда на малой прозрачности:
    /// на трекпаде hover обнаруживается хуже, чем мышью, и кнопка,
    /// целиком невидимая в покое, была бы недоступна для открытия одним
    /// взглядом на панель.
    private var editButton: some View {
        Button(action: onEditTap) {
            Image(systemName: "pencil")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(isHovering ? 0.85 : 0.25))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .padding(4)
        .accessibilityLabel("Править «\(chip.label)»")
    }

    private var accessibilityLabel: String {
        let valueLabel = chip.isSensitive ? "значение скрыто" : chip.displayValue
        return "\(chip.label): \(valueLabel)"
    }
}

/// Форма добавления/правки пина. Кнопки сохранения и отмены закреплены
/// снизу вне прокрутки — поля выше могут прокручиваться, но не должны
/// уносить с собой единственный способ форму закрыть.
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
        TextField("Метка", text: $label)
            .textFieldStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .padding(6)
            .background(fieldBackground)
    }

    private var valueField: some View {
        TextField("Значение", text: $value)
            .textFieldStyle(.plain)
            .font(.system(size: 11))
            .padding(6)
            .background(fieldBackground)
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(0.08))
    }

    /// Тумблер — тем же нейтральным белым, что и остальной хром «Обсидиана»:
    /// системный `.switch` по умолчанию красится акцентным цветом macOS, а
    /// единственный цвет, которому здесь позволено быть цветом, а не белым
    /// разной прозрачности, — сам пин (см. PinChip.accentOrDefault).
    private var sensitiveToggle: some View {
        Toggle(isOn: $isSensitive) {
            Text("Чувствительное значение")
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
                .accessibilityLabel("Иконка \(symbol)")
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
                .accessibilityLabel("Цвет \(hex)")
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Button("Отмена", action: onCancel)
                .buttonStyle(PinEditorButtonStyle(isProminent: false))
                .keyboardShortcut(.cancelAction)
            Button("Сохранить", action: onSave)
                .buttonStyle(PinEditorButtonStyle(isProminent: true))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSave)
        }
    }
}

/// Кнопки формы. Тот же приём, что PlayPauseButtonStyle/PermissionButtonStyle
/// в остальной панели: проминентная — сплошная белая с чёрным текстом,
/// единственное намеренное исключение из «белого разной прозрачности» ради
/// однозначно кликабельного основного действия; второстепенная — плашка
/// низкой непрозрачности. Не переиспользует PermissionButtonStyle напрямую:
/// та лежит в PermissionPromptView.swift как приватный тип этого файла.
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
