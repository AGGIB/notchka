import Foundation
import Observation
import NotchUI
import StashKit
import os

/// Модель вкладки быстрых заметок.
///
/// В отличие от ClipboardViewModel не уводит чтение и запись с MainActor в
/// фоновую задачу: заметки — короткий пользовательский текст без блобов, и
/// синхронный вызов GRDB на них не рискует подвесить панель, в отличие от
/// мегабайтных скриншотов истории буфера, ради которых там заведена вся
/// асинхронная машинерия. Здесь она была бы сложностью без пользы.
@MainActor
@Observable
final class NotesViewModel {
    private(set) var rows: [NoteRow] = []
    /// Текст поля создания новой заметки — двусторонний биндинг с
    /// `NotesTabView.draft` со стороны вызывающего (см. отчёт задачи о
    /// подключении в AppDelegate).
    var draft: String = ""

    @ObservationIgnored private let repository: NotesRepository

    private static let logger = Logger(subsystem: "kz.mobilefirst.notchka", category: "notes-tab")

    init(repository: NotesRepository) {
        self.repository = repository
    }

    /// Перечитывает список. Вызывать при каждом открытии вкладки — модель не
    /// держит постоянной подписки на базу (то же решение, что у
    /// ClipboardViewModel.refresh(), вызываемого из NotchRootView.task(id:)).
    ///
    /// Сигнатура `async`, хотя тело синхронно (см. doc класса) — форма
    /// вызова из `.task(id:)` в NotchRootView не должна отличаться между
    /// вкладками буфера и заметок.
    func refresh() async {
        reload()
    }

    /// Сохраняет черновик как новую заметку.
    ///
    /// Пустой текст не должен долетать до репозитория — кнопка сохранения и
    /// её сочетание `⌘↩` недоступны на пустом поле (см.
    /// NotesTabView.NoteComposerView.isSaveDisabled). `catch` ниже — вторая
    /// линия защиты на случай гонки, а не основной путь: черновик НЕ
    /// очищается при отказе, чтобы пользователь видел, что сохранение не
    /// произошло, а не потерял набранный текст молча.
    func saveDraft() {
        do {
            try repository.add(draft)
            draft = ""
            reload()
        } catch is NotesRepository.EmptyBodyError {
            Self.logger.notice("сохранение пустой заметки отклонено")
        } catch {
            Self.logger.error("не удалось сохранить заметку: \(error, privacy: .public)")
        }
    }

    /// Сохраняет правку существующей заметки. Инлайн-редактор в
    /// NotesTabView.NoteRowView остаётся открытым при отказе — по той же
    /// причине, что и у saveDraft: стереть весь текст и подтвердить не
    /// значит «удалить заметку», для этого есть отдельная кнопка корзины.
    func commitEdit(id: Int64, body: String) {
        do {
            try repository.update(id: id, body: body)
            reload()
        } catch is NotesRepository.EmptyBodyError {
            Self.logger.notice("сохранение пустой правки заметки \(id, privacy: .public) отклонено")
        } catch {
            Self.logger.error("не удалось сохранить правку заметки \(id, privacy: .public): \(error, privacy: .public)")
        }
    }

    /// Удаляет заметку. Пустой catch намеренно отсутствует — отказ здесь не
    /// имеет отдельной пользовательской реакции (нет «поля», которое нужно
    /// было бы не очищать), только лог.
    func delete(id: Int64) {
        do {
            try repository.delete(id: id)
            reload()
        } catch {
            Self.logger.error("не удалось удалить заметку \(id, privacy: .public): \(error, privacy: .public)")
        }
    }

    private func reload() {
        do {
            rows = try repository.all().compactMap(Self.makeRow)
        } catch {
            Self.logger.error("не удалось прочитать заметки: \(error, privacy: .public)")
            rows = []
        }
    }

    /// Подпись даты считается от `createdAt`, не `updatedAt` — см. doc
    /// `NoteRow` в NotchUI: список отсортирован по времени создания
    /// (NotesRepository.all()), и подпись обязана согласовываться с этим
    /// порядком.
    private static func makeRow(_ note: Note) -> NoteRow? {
        guard let id = note.id else {
            logger.error("заметка без id пропущена при построении списка")
            return nil
        }
        return NoteRow(id: id, body: note.body, relativeDate: NoteFormatting.relativeDate(note.createdAt))
    }
}
