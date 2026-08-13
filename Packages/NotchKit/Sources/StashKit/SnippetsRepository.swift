import Foundation
import GRDB
import NotchStore

/// Доступ к репозиторию закреплённых сниппетов.
public struct SnippetsRepository: Sendable {
    private let database: NotchDatabase

    // Тип владельца в общем search_index. Константа, а не литерал в
    // нескольких местах: опечатка в одном из них тихо ломает поиск, а
    // компилятор такое не ловит — только рантайм-несовпадение строк.
    private static let ownerKind = "snippet"

    public init(database: NotchDatabase) {
        self.database = database
    }

    /// Сохраняет пин в конец списка. После отсечения пробелов пустая метка
    /// не сохраняется — пин без подписи неотличим от соседа.
    ///
    /// В индекс попадает только метка — значение не индексируется никогда,
    /// даже когда пин не отмечен чувствительным. Одно правило для всех
    /// пинов проще и надёжнее, чем ветвиться по `isSensitive` в месте
    /// записи индекса: цена ошибиться веткой и один раз проиндексировать
    /// секрет того не стоит.
    ///
    /// Порядок нового пина — на единицу больше текущего максимума, а не
    /// количество строк: после удалений из середины списка количество
    /// строк меньше максимального sort_order, и подсчёт по count() воткнул
    /// бы новый пин в середину вместо конца.
    ///
    /// Запись пина и строка индекса пишутся в одной транзакции: без этого
    /// сбой между двумя вставками мог бы оставить сохранённый пин без
    /// записи в индексе, и поиск бы его не находил.
    public func add(
        label: String, value: String, icon: String?, colorHex: String?,
        isSensitive: Bool, at now: Date = Date()
    ) throws {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        try database.queue.write { db in
            let nextOrder = try Int.fetchOne(
                db, sql: "SELECT COALESCE(MAX(sort_order), -1) + 1 FROM snippets"
            ) ?? 0
            var snippet = Snippet(
                id: nil, label: trimmed, value: value, icon: icon, colorHex: colorHex,
                sortOrder: nextOrder, isSensitive: isSensitive, createdAt: now, updatedAt: now
            )
            try snippet.insert(db)
            guard let id = snippet.id else { return }
            try db.execute(
                sql: "INSERT INTO search_index (owner_kind, owner_id, title, body) VALUES (?, ?, ?, ?)",
                arguments: [Self.ownerKind, id, "", trimmed]
            )
        }
    }

    /// Все пины в пользовательском порядке. Дубли sort_order допустимы
    /// намеренно (см. схему) — совпадения разрешаются сортировкой по id,
    /// раньше вставленный из совпавших идёт первым.
    public func all() throws -> [Snippet] {
        try database.queue.read { db in
            try Snippet.order(Column("sort_order"), Column("id")).fetchAll(db)
        }
    }

    /// Перемещает пин на позицию `newIndex` и перенумеровывает список
    /// целиком. Дробные порядки (вставка между соседями без сдвига
    /// остальных) сэкономили бы запись, но на список из десятка пинов эта
    /// экономия не стоит усложнения чтения.
    ///
    /// Индекс вне диапазона зажимается, а не приводит к ошибке: панель
    /// передаёт позицию из drag-and-drop, где промах на единицу — обычное
    /// дело, а не повод ронять операцию.
    ///
    /// Чтение текущего порядка идёт через тот же `db`, что получен внутри
    /// `write`, а не через `self.all()`: вложенный вызов queue.read или
    /// queue.write внутри уже открытого write — фатальная ошибка GRDB в
    /// этом проекте, а не просто медленный путь.
    public func move(id: Int64, to newIndex: Int) throws {
        try database.queue.write { db in
            var orderedIDs = try Int64.fetchAll(
                db, sql: "SELECT id FROM snippets ORDER BY sort_order, id"
            )
            guard let currentIndex = orderedIDs.firstIndex(of: id) else { return }

            orderedIDs.remove(at: currentIndex)
            let clampedIndex = min(max(newIndex, 0), orderedIDs.count)
            orderedIDs.insert(id, at: clampedIndex)

            for (index, snippetID) in orderedIDs.enumerated() {
                try db.execute(
                    sql: "UPDATE snippets SET sort_order = ? WHERE id = ?",
                    arguments: [index, snippetID]
                )
            }
        }
    }

    /// Обновляет метку, значение, иконку, цвет и признак чувствительности.
    /// Время создания и sort_order не трогаются: правка не должна
    /// выглядеть как новый пин и не должна сама по себе двигать его в
    /// списке — для перестановки есть `move`.
    ///
    /// Пустая после отсечения пробелов метка отклоняется тем же правилом,
    /// что и при создании.
    ///
    /// Строка индекса переписывается текущей меткой в той же транзакции,
    /// что и сама запись, — как при создании и удалении, чтобы поиск не
    /// отставал от метки при сбое между операциями.
    public func update(_ snippet: Snippet, at now: Date = Date()) throws {
        guard let id = snippet.id else { return }
        let trimmed = snippet.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        try database.queue.write { db in
            try db.execute(
                sql: """
                    UPDATE snippets
                    SET label = ?, value = ?, icon = ?, color_hex = ?, is_sensitive = ?, updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [
                    trimmed, snippet.value, snippet.icon, snippet.colorHex,
                    snippet.isSensitive, now, id,
                ]
            )
            try db.execute(
                sql: "UPDATE search_index SET body = ? WHERE owner_kind = ? AND owner_id = ?",
                arguments: [trimmed, Self.ownerKind, id]
            )
        }
    }

    /// Удаляет пин вместе со строкой индекса в одной транзакции — иначе
    /// после сбоя между операциями поиск мог бы найти уже удалённый пин.
    public func delete(id: Int64) throws {
        try database.queue.write { db in
            try db.execute(sql: "DELETE FROM snippets WHERE id = ?", arguments: [id])
            try db.execute(
                sql: "DELETE FROM search_index WHERE owner_kind = ? AND owner_id = ?",
                arguments: [Self.ownerKind, id]
            )
        }
    }
}
