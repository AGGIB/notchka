import Foundation
import GRDB
import NotchStore

/// Доступ к репозиторию быстрых заметок.
public struct NotesRepository: Sendable {
    private let database: NotchDatabase

    // Тип владельца в общем search_index. Константа, а не литерал в трёх
    // местах: опечатка в одном из них тихо ломает поиск, а компилятор
    // такое не ловит — только рантайм-несовпадение строк.
    private static let ownerKind = "note"

    public init(database: NotchDatabase) {
        self.database = database
    }

    /// Заметка не сохранилась, потому что после отсечения пробелов и
    /// переводов строк от неё ничего не осталось.
    public struct EmptyBodyError: Error, Sendable {}

    /// Сохраняет заметку. После отсечения пробелов и переводов строк пустая
    /// заметка не сохраняется, а бросает — иначе случайный ⌘↩ без текста
    /// молча ничего не делал бы, и вызывающий код не смог бы отличить
    /// «сохранено» от «отклонено», чтобы, например, не очищать поле ввода.
    ///
    /// Строка поискового индекса пишется в той же транзакции, что и сама
    /// заметка: без этого сбой между двумя вставками мог бы оставить
    /// сохранённую заметку без записи в индексе, и поиск бы её не находил.
    public func add(_ body: String, at now: Date = Date()) throws {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EmptyBodyError() }

        try database.queue.write { db in
            var note = Note(id: nil, body: trimmed, createdAt: now, updatedAt: now)
            try note.insert(db)
            guard let id = note.id else {
                // GRDB всегда проставляет id в didInsert после успешной
                // автоинкрементной вставки — это недостижимо на практике.
                // Но throw здесь, а не return: return означал бы COMMIT
                // заметки без строки индекса, и разошедшееся состояние
                // осталось бы в базе навсегда, а не только на время вызова.
                struct MissingInsertedID: Error, Sendable {}
                throw MissingInsertedID()
            }
            try db.execute(
                sql: "INSERT INTO search_index (owner_kind, owner_id, title, body) VALUES (?, ?, ?, ?)",
                arguments: [Self.ownerKind, id, "", trimmed]
            )
        }
    }

    /// Все заметки, самые новые сверху. Сортировка — по времени создания,
    /// а не правки: правка не должна двигать заметку в ленте.
    public func all() throws -> [Note] {
        try database.queue.read { db in
            try Note.order(Column("created_at").desc).fetchAll(db)
        }
    }

    /// Меняет текст и время правки. Время создания не трогается: иначе
    /// исправление опечатки переносило бы заметку в начало ленты, а
    /// пользователь ждёт, что она останется там, где была.
    ///
    /// Пустая после отсечения пробелов правка отклоняется тем же правилом
    /// и тем же способом, что и пустое создание — throw, а не тихий return,
    /// иначе стёршему весь текст пользователю нечем сказать, что правка не
    /// применилась, и старое содержимое просто беззвучно осталось на месте.
    ///
    /// Строка индекса обновляется в той же транзакции, что и заметка, —
    /// как при создании и удалении, чтобы поиск не отставал от текста
    /// заметки при сбое между двумя операциями.
    public func update(id: Int64, body: String, at now: Date = Date()) throws {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EmptyBodyError() }

        try database.queue.write { db in
            try db.execute(
                sql: "UPDATE notes SET body = ?, updated_at = ? WHERE id = ?",
                arguments: [trimmed, now, id]
            )
            try db.execute(
                sql: "UPDATE search_index SET body = ? WHERE owner_kind = ? AND owner_id = ?",
                arguments: [trimmed, Self.ownerKind, id]
            )
        }
    }

    /// Удаляет заметку вместе со строкой индекса в одной транзакции —
    /// иначе после сбоя между операциями поиск мог бы найти уже удалённую
    /// заметку.
    public func delete(id: Int64) throws {
        try database.queue.write { db in
            try db.execute(sql: "DELETE FROM notes WHERE id = ?", arguments: [id])
            try db.execute(
                sql: "DELETE FROM search_index WHERE owner_kind = ? AND owner_id = ?",
                arguments: [Self.ownerKind, id]
            )
        }
    }
}
