import AppKit
import Observation
import NotchStore
import NotchUI
import StashKit
import os

/// Модель вкладки пинов.
///
/// Как и ClipboardViewModel (см. её doc), не держит постоянной подписки на
/// базу — список читается заново при каждом открытии вкладки через
/// `refresh()`, вызываемый из NotchRootView.task(id:) тем же приёмом, что и
/// у буфера и позиции трека (решение №4 постановки задачи).
@MainActor
@Observable
final class PinsViewModel {
    private(set) var chips: [PinChip] = []

    @ObservationIgnored private let repository: SnippetsRepository
    /// Полные записи по id: PinChip несёт только то, что нужно для показа и
    /// вставки, а `SnippetsRepository.update(_:)` требует ещё `sortOrder` и
    /// `createdAt`, которых в чипе нет вовсе, — они берутся отсюда.
    @ObservationIgnored private var snippetsByID: [Int64: Snippet] = [:]

    // nonisolated: без этого статический logger унаследовал бы MainActor-
    // изоляцию класса и был бы недоступен из nonisolated-функций ниже,
    // которые сознательно уводят обращения к базе с главного потока — тот
    // же приём и то же обоснование, что у ClipboardViewModel.logger.
    nonisolated private static let logger = Logger(subsystem: "kz.mobilefirst.notchka", category: "pins-tab")

    /// Зовётся сразу после того, как модель положила значение пина в
    /// пастборд. Тот же приём и то же обоснование, что у
    /// `ClipboardViewModel.didWritePasteboard`: без него опрос буфера через
    /// доли секунды прочитал бы вставленное значение обратно и добавил бы
    /// его в историю буфера отдельной записью — открытым текстом, даже если
    /// пин был помечен чувствительным. Маскировка в панели пинов не спасла
    /// бы в этом случае: лента буфера показывает содержимое без маски.
    @ObservationIgnored private let didWritePasteboard: () -> Void

    init(repository: SnippetsRepository, didWritePasteboard: @escaping () -> Void = {}) {
        self.repository = repository
        self.didWritePasteboard = didWritePasteboard
    }

    /// Перечитывает список пинов. Вызывать при каждом открытии вкладки —
    /// модель не держит постоянной подписки на базу (см. doc класса).
    func refresh() async {
        let repository = repository
        let snippets = await Self.loadAll(repository: repository)
        apply(snippets)
    }

    /// Клик по чипу: вставляет настоящее значение, а не маску (решение №1
    /// постановки). `frontmostApplication` читается снаружи в момент клика,
    /// а не захватывается при развороте — см. `NotchController.pasteTarget`
    /// и её doc про то, почему это важно именно в момент клика.
    func activate(id: Int64, frontmostApplication: NSRunningApplication?) {
        guard let snippet = snippetsByID[id] else { return }
        PasteService.paste(snippet.value, into: frontmostApplication)
        didWritePasteboard()
    }

    /// ⌥клик: только копирование, тем же настоящим значением.
    func copyOnly(id: Int64) {
        guard let snippet = snippetsByID[id] else { return }
        PasteService.copyOnly(snippet.value)
        didWritePasteboard()
    }

    /// Перетаскивание чипа на новую позицию — решение №2 постановки: зовёт
    /// `move(id:to:)` и тут же перечитывает список, чтобы новый порядок был
    /// виден сразу, в той же открытой панели, а не только при следующем
    /// открытии вкладки.
    func reorder(id: Int64, to newIndex: Int) {
        let repository = repository
        Task(priority: .utility) {
            let snippets = await Self.moveAndFetch(repository: repository, id: id, to: newIndex)
            apply(snippets)
        }
    }

    /// Сохраняет пин из формы PinsTabView: новый, если `chip.id` пуст, иначе
    /// правит существующую запись, найденную по этому id.
    func save(_ chip: PinChip) {
        let repository = repository
        let existing = chip.id.flatMap { snippetsByID[$0] }
        Task(priority: .utility) {
            let snippets = await Self.persistAndFetch(repository: repository, chip: chip, existing: existing)
            apply(snippets)
        }
    }

    /// Строит чипы из уже прочитанного списка — на главном потоке, тем же
    /// приёмом, что и `ClipboardViewModel.apply(_:)`.
    private func apply(_ snippets: [Snippet]) {
        var byID: [Int64: Snippet] = [:]
        var built: [PinChip] = []
        built.reserveCapacity(snippets.count)
        for snippet in snippets {
            guard let id = snippet.id else {
                Self.logger.error("пин без id пропущен при построении списка")
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
            logger.error("не удалось прочитать список пинов: \(error, privacy: .public)")
            return []
        }
    }

    nonisolated private static func moveAndFetch(
        repository: SnippetsRepository, id: Int64, to newIndex: Int
    ) async -> [Snippet] {
        do {
            try repository.move(id: id, to: newIndex)
        } catch {
            logger.error("не удалось переместить пин \(id, privacy: .public): \(error, privacy: .public)")
        }
        return await loadAll(repository: repository)
    }

    /// Правит существующую запись или добавляет новую в зависимости от
    /// того, нашёлся ли `existing` — его ищет `save(_:)` до входа сюда, пока
    /// ещё есть доступ к `snippetsByID` на главном потоке. `update(_:)`
    /// внутри `SnippetsRepository` не решает это сама: она ожидает уже
    /// собранный `Snippet` целиком, включая `sortOrder` и `createdAt`,
    /// которых форма никогда не видит.
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
            logger.error("не удалось сохранить пин: \(error, privacy: .public)")
        }
        return await loadAll(repository: repository)
    }
}
