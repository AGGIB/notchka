import AppKit
import Observation
import SwiftUI
import NotchStore
import NotchUI
import os

/// Модель вкладки буфера обмена.
///
/// В отличие от MusicViewModel не держит постоянной подписки: история
/// читается только пока раскрыта сама вкладка буфера (см. `refresh()`,
/// вызываемый из NotchRootView.task(id:) тем же приёмом, что и обновление
/// позиции трека) — в покое приложению нечего опрашивать, спека требует
/// именно этого.
@MainActor
@Observable
final class ClipboardViewModel {
    private(set) var cards: [ClipboardCard] = []
    /// Карточка последнего действия (вставки или копирования) — лента
    /// подсвечивает её акцентной обводкой как подтверждение того, что сейчас
    /// лежит в пастборде. `nil`, пока пользователь ничего не нажал в этом
    /// сеансе.
    private(set) var selectedID: Int64?

    @ObservationIgnored private let repository: ClipboardRepository
    /// Полные записи по id — карточка хранит только усечённое превью
    /// (см. ClipboardCard.preview), а вставлять и копировать нужно исходное
    /// содержимое.
    @ObservationIgnored private var itemsByID: [Int64: ClipboardItem] = [:]

    // nonisolated: без этого статический logger унаследовал бы MainActor-
    // изоляцию класса и был бы недоступен из nonisolated-функций ниже,
    // которые сознательно уводят чтение базы и блобов с главного потока —
    // тот же приём и то же обоснование, что у ClipboardService.logger.
    nonisolated private static let logger = Logger(subsystem: "kz.mobilefirst.notchka", category: "clipboard-tab")

    /// Сколько последних записей показывать. Лента прокручивается вбок, а не
    /// подгружается порциями по мере скролла, поэтому число — компромисс
    /// между «видно историю вглубь» и «не декодировать сотню миниатюр на
    /// каждое открытие вкладки».
    private static let limit = 50
    /// Символов в текстовом превью карточки. Подобрано под её ширину (см.
    /// ClipboardTabView.ClipboardCardView.width = 76 pt) — при переносе на
    /// мелком шрифте карточка заполняется по высоте, не убегая за край на
    /// более длинном тексте.
    private static let previewMaxLength = 64

    init(repository: ClipboardRepository) {
        self.repository = repository
    }

    /// Перечитывает историю. Вызывать при каждом открытии вкладки — модель
    /// не держит постоянной подписки на базу (см. doc класса).
    func refresh() async {
        let repository = repository
        let snapshot = await Self.loadRecent(repository: repository, limit: Self.limit)
        apply(snapshot)
    }

    /// Клик по карточке. Текст вставляется в приложение, бывшее фронтовым до
    /// разворота панели (frontmostApplication приходит снаружи —
    /// NotchController.frontmostApplicationBeforeExpanding захватывает его
    /// раньше, чем панель заберёт фокус себе). Картинка и файл кладутся в
    /// общий пастборд: вставить произвольные байты синтетическим ⌘V нечем
    /// без строки в пастборде, а PasteService умеет работать только со
    /// строками (см. её интерфейс) — расширять его вне файлов этой задачи
    /// незачем, поэтому для этих двух типов клик и ⌥клик совпадают.
    func activate(id: Int64, frontmostApplication: NSRunningApplication?) {
        guard let item = itemsByID[id] else { return }
        selectedID = id
        if item.kind == .text {
            PasteService.paste(item.textBody ?? "", into: frontmostApplication)
        } else {
            copyToPasteboard(item)
        }
        touchAndRefresh(id: id)
    }

    /// ⌥клик: только копирование, без вставки.
    func copyOnly(id: Int64) {
        guard let item = itemsByID[id] else { return }
        selectedID = id
        if item.kind == .text {
            PasteService.copyOnly(item.textBody ?? "")
        } else {
            copyToPasteboard(item)
        }
        touchAndRefresh(id: id)
    }

    /// Поднимает запись наверх ленты в базе и тут же перечитывает историю,
    /// чтобы переупорядочивание было видно сразу, в той же открытой панели —
    /// решение №2 постановки требует, чтобы вставленный элемент оказался в
    /// начале ленты, а не только при следующем открытии вкладки.
    private func touchAndRefresh(id: Int64) {
        let repository = repository
        Task(priority: .utility) {
            let snapshot = await Self.touchAndFetch(repository: repository, id: id, limit: Self.limit)
            apply(snapshot)
        }
    }

    /// Кладёт байты картинки или файла в общий пастборд. Чтение блоба уходит
    /// в фоновую задачу тем же приёмом, что и в ClipboardService: скопированный
    /// скриншот бывает мегабайтным, и синхронное чтение с диска на главном
    /// потоке подвесило бы панель.
    private func copyToPasteboard(_ item: ClipboardItem) {
        let repository = repository
        Task(priority: .utility) {
            guard let data = await Self.loadBlob(repository: repository, item: item) else { return }
            writeToPasteboard(data, item: item)
        }
    }

    /// NSImage и запись в NSPasteboard — на главном потоке. Тот же принцип,
    /// что «Image строится на главном потоке» в apply(_:) ниже: сам объект
    /// платформенной картинки не Sendable, поэтому он и не должен покидать
    /// MainActor.
    private func writeToPasteboard(_ data: Data, item: ClipboardItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch item.kind {
        case .image:
            guard let image = NSImage(data: data) else { return }
            pasteboard.writeObjects([image])
        case .file:
            guard let url = Self.writeTemporaryFile(data, name: item.textBody) else { return }
            pasteboard.writeObjects([url as NSURL])
        case .text:
            break  // сюда не попадает: activate/copyOnly отправляют текст через PasteService
        }
    }

    /// Восстанавливает файл во временном каталоге под исходным именем.
    /// История хранит копию байтов, а не путь (см. BlobStore) — класть на
    /// пастборд ссылку на давно исчезнувший или перемещённый оригинал было
    /// бы нечестно, поэтому создаётся новый файл с тем же содержимым и
    /// именем, и уже он идёт на пастборд.
    nonisolated private static func writeTemporaryFile(_ data: Data, name: String?) -> URL? {
        let fileName = (name?.isEmpty == false) ? name! : "файл"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent(fileName)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            logger.error("не удалось восстановить файл из истории буфера: \(error, privacy: .public)")
            return nil
        }
    }

    /// Читает блоб вне главного потока. `async`, хотя `ClipboardRepository
    /// .data(for:)` сама по себе синхронна: именно `await` на асинхронной
    /// nonisolated-функции гарантирует уход с MainActor, независимо от того,
    /// чем в итоге изолировано вызывающее замыкание Task — не пожелание, а
    /// свойство самого await на функции без привязки к актору.
    nonisolated private static func loadBlob(repository: ClipboardRepository, item: ClipboardItem) async -> Data? {
        do {
            return try repository.data(for: item)
        } catch {
            logger.error("не удалось прочитать блоб карточки буфера: \(error, privacy: .public)")
            return nil
        }
    }

    /// Поднимает запись наверх ленты в базе, потом читает свежий список —
    /// обе операции вне главного потока, одной цепочкой без промежуточного
    /// возврата на MainActor между ними.
    nonisolated private static func touchAndFetch(
        repository: ClipboardRepository, id: Int64, limit: Int
    ) async -> (items: [ClipboardItem], blobs: [Int64: Data]) {
        do {
            try repository.touch(id: id)
        } catch {
            logger.error("не удалось поднять запись \(id, privacy: .public) наверх ленты: \(error, privacy: .public)")
        }
        return await loadRecent(repository: repository, limit: limit)
    }

    /// Список последних записей и байты картинок среди них — вне главного
    /// потока целиком. Байты читаются здесь же, а не отдельным проходом по
    /// требованию: миниатюры нужны сразу при открытии вкладки, а решение №5
    /// постановки требует уводить чтение блобов с главного потока.
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
            logger.error("не удалось прочитать историю буфера: \(error, privacy: .public)")
            return ([], [:])
        }
    }

    /// Строит карточки из уже готового снимка данных, включая Image()
    /// миниатюр, — на главном потоке, как требует решение №5 постановки.
    private func apply(_ snapshot: (items: [ClipboardItem], blobs: [Int64: Data])) {
        var byID: [Int64: ClipboardItem] = [:]
        var built: [ClipboardCard] = []
        built.reserveCapacity(snapshot.items.count)
        for item in snapshot.items {
            guard let id = item.id else {
                Self.logger.error("запись истории буфера без id пропущена при построении ленты")
                continue
            }
            byID[id] = item
            built.append(ClipboardCard(
                id: id,
                kind: Self.cardKind(for: item.kind),
                preview: Self.preview(for: item),
                source: item.sourceAppName ?? "Неизвестно",
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

    /// Превью карточки. Для картинки — не подпись поверх пустоты: показать
    /// её саму обязан thumbnail (см. ClipboardCard), а этот текст — лишь
    /// запасной вариант на случай, если байты не декодировались в Image.
    private static func preview(for item: ClipboardItem) -> String {
        switch item.kind {
        case .text:
            ClipboardCard.preview(for: item.textBody ?? "", maxLength: previewMaxLength)
        case .file:
            ClipboardCard.preview(for: item.textBody ?? "Файл", maxLength: previewMaxLength)
        case .image:
            "Изображение"
        }
    }
}
