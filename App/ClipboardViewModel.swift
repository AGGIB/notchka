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

    /// Зовётся сразу после того, как модель что-то положила в пастборд.
    /// Через него служба слежения помечает изменение как своё и не читает
    /// его обратно — иначе достанутая из истории картинка тут же попадала бы
    /// в неё второй раз, в другом представлении и с другим хешем.
    @ObservationIgnored private let didWritePasteboard: () -> Void

    init(repository: ClipboardRepository, didWritePasteboard: @escaping () -> Void = {}) {
        self.repository = repository
        self.didWritePasteboard = didWritePasteboard
    }

    /// Перечитывает историю. Вызывать при каждом открытии вкладки — модель
    /// не держит постоянной подписки на базу (см. doc класса).
    func refresh() async {
        let repository = repository
        let snapshot = await Self.loadRecent(repository: repository, limit: Self.limit)
        apply(snapshot)
    }

    /// Клик по карточке: содержимое вставляется в приложение, бывшее
    /// фронтовым до разворота панели (frontmostApplication приходит снаружи —
    /// NotchController.frontmostApplicationBeforeExpanding захватывает его
    /// раньше, чем панель заберёт фокус себе).
    ///
    /// Вставляются все три типа, а не только текст: правило «клик вставляет,
    /// ⌥клик копирует» оговорок по типу содержимого не имеет, и пользователь,
    /// кликнувший по скриншоту, не должен гадать, почему в этот раз ничего
    /// не произошло. Картинка и файл идут в пастборд объектами, но ⌘V после
    /// этого посылается тот же самый — ему всё равно, что там лежит.
    func activate(id: Int64, frontmostApplication: NSRunningApplication?) {
        guard let item = itemsByID[id] else { return }
        if item.kind == .text {
            PasteService.paste(item.textBody ?? "", into: frontmostApplication)
            markDelivered(id)
        } else {
            // Обводка ставится не здесь, а после того, как байты реально
            // доехали до пастборда: чтение блоба может и не удаться, а
            // обводка обещает пользователю «вот это сейчас в буфере».
            deliverBlob(item, pastingInto: frontmostApplication)
        }
        touchAndRefresh(id: id)
    }

    /// ⌥клик: только копирование, без вставки.
    func copyOnly(id: Int64) {
        guard let item = itemsByID[id] else { return }
        if item.kind == .text {
            PasteService.copyOnly(item.textBody ?? "")
            markDelivered(id)
        } else {
            deliverBlob(item, pastingInto: nil)
        }
        touchAndRefresh(id: id)
    }

    /// Отмечает карточку как ту, чьё содержимое сейчас в пастборде, и
    /// сообщает об этом службе слежения, чтобы она не прочитала нашу же
    /// запись обратно.
    private func markDelivered(_ id: Int64) {
        selectedID = id
        didWritePasteboard()
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

    /// Достаёт байты картинки или файла и кладёт их в пастборд, а при
    /// непустом `application` — сразу вставляет.
    ///
    /// Всё, что трогает диск — и чтение блоба, и восстановление файла, —
    /// делается внутри фоновой задачи, до возврата на главный поток.
    /// Скопированный скриншот бывает мегабайтным, и что чтение, что запись
    /// таких объёмов на потоке, рисующем панель, её подвешивают.
    private func deliverBlob(_ item: ClipboardItem, pastingInto application: NSRunningApplication?) {
        let repository = repository
        Task(priority: .utility) {
            guard let data = await Self.loadBlob(repository: repository, item: item) else { return }
            // Файл восстанавливается здесь же, вне главного потока: запись
            // байтов на диск — такой же ввод-вывод, как их чтение, и
            // оставлять её на MainActor значило бы починить одну половину
            // проблемы и не заметить вторую.
            let fileURL = item.kind == .file
                ? await Self.writeTemporaryFile(data, name: item.textBody)
                : nil
            deliver(data, fileURL: fileURL, item: item, pastingInto: application)
        }
    }

    /// NSImage и работа с NSPasteboard — на главном потоке: платформенная
    /// картинка не Sendable и покидать MainActor не должна.
    private func deliver(
        _ data: Data, fileURL: URL?, item: ClipboardItem, pastingInto application: NSRunningApplication?
    ) {
        let objects: [any NSPasteboardWriting]
        switch item.kind {
        case .image:
            guard let image = NSImage(data: data) else { return }
            objects = [image]
        case .file:
            guard let fileURL else { return }
            objects = [fileURL as NSURL]
        case .text:
            return  // сюда не попадает: текст идёт через PasteService напрямую
        }

        if let application {
            PasteService.paste(objects: objects, into: application)
        } else {
            PasteService.copyOnly(objects: objects)
        }
        guard let id = item.id else { return }
        markDelivered(id)
    }

    /// Восстанавливает файл во временном каталоге под исходным именем.
    /// История хранит копию байтов, а не путь (см. BlobStore) — класть на
    /// пастборд ссылку на давно исчезнувший или перемещённый оригинал было
    /// бы нечестно, поэтому создаётся новый файл с тем же содержимым и
    /// именем, и уже он идёт на пастборд.
    ///
    /// `async` не для красоты: без него функция выполнилась бы прямо на
    /// MainActor вызывающего, и `nonisolated` ничего бы не изменил — уводит
    /// с актора именно `await` на функции без привязки к нему.
    nonisolated private static func writeTemporaryFile(_ data: Data, name: String?) async -> URL? {
        let fileName = (name?.isEmpty == false) ? name! : "файл"
        let fileURL = temporaryDirectory.appendingPathComponent(fileName)
        do {
            // Каталог пересоздаётся целиком перед каждой выдачей: иначе
            // восстановленные файлы копились бы во временной папке до
            // перезагрузки, по одному на каждый клик по файловой карточке.
            // Отданный ранее файл к этому моменту уже вставлен.
            try? FileManager.default.removeItem(at: temporaryDirectory)
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            logger.error("не удалось восстановить файл из истории буфера: \(error, privacy: .public)")
            return nil
        }
    }

    /// Куда восстанавливаются файлы из истории. Один каталог на всё
    /// приложение, а не новый на каждую выдачу — см. writeTemporaryFile.
    nonisolated private static let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("kz.mobilefirst.notchka-paste", isDirectory: true)

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
