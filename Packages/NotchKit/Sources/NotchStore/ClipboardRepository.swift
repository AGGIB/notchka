import Foundation
import GRDB
import os

/// Доступ к истории буфера.
public struct ClipboardRepository: Sendable {
    private let database: NotchDatabase
    private let blobs: BlobStore
    private let logger = Logger(subsystem: "kz.mobilefirst.notchka", category: "clipboard")

    public init(database: NotchDatabase, blobs: BlobStore) {
        self.database = database
        self.blobs = blobs
    }

    public func saveText(
        _ text: String,
        source: (bundleID: String, appName: String)?,
        at now: Date = Date()
    ) throws {
        let data = Data(text.utf8)
        try save(
            kind: .text, hash: BlobStore.hash(data), text: text, blobPath: nil,
            byteSize: data.count, source: source, at: now
        )
    }

    public func saveImage(
        _ data: Data,
        source: (bundleID: String, appName: String)?,
        at now: Date = Date()
    ) throws {
        // Хеш считается один раз и отдаётся хранилищу готовым: путь блоба и
        // ключ дедупликации в базе — это одно и то же число, а лишний проход
        // SHA-256 по мегабайтам скриншота ничего не даёт.
        let hash = BlobStore.hash(data)
        let path = try blobs.store(data, hash: hash)
        try save(
            kind: .image, hash: hash, text: nil, blobPath: path,
            byteSize: data.count, source: source, at: now
        )
    }

    public func saveFile(
        _ data: Data,
        fileName: String,
        source: (bundleID: String, appName: String)?,
        at now: Date = Date()
    ) throws {
        let hash = BlobStore.hash(data)
        let path = try blobs.store(data, hash: hash)
        try save(
            kind: .file, hash: hash, text: fileName, blobPath: path,
            byteSize: data.count, source: source, at: now
        )
    }

    /// Повтор не создаёт вторую запись: уникальность хеша ловит его на уровне
    /// базы, а мы поднимаем существующую строку наверх ленты.
    private func save(
        kind: ClipboardKind, hash: String, text: String?, blobPath: String?,
        byteSize: Int, source: (bundleID: String, appName: String)?, at now: Date
    ) throws {
        try database.queue.write { db in
            if let existing = try ClipboardItem
                .filter(Column("content_hash") == hash)
                .fetchOne(db)
            {
                var updated = existing
                updated.lastUsedAt = now
                try updated.update(db)
                return
            }

            var item = ClipboardItem(
                id: nil, kind: kind, contentHash: hash, textBody: text,
                blobPath: blobPath, byteSize: byteSize,
                sourceBundleId: source?.bundleID, sourceAppName: source?.appName,
                createdAt: now, lastUsedAt: now, isPinned: false
            )
            try item.insert(db)

            if let text, !text.isEmpty, let id = item.id {
                try db.execute(
                    sql: "INSERT INTO search_index (owner_kind, owner_id, title, body) VALUES (?, ?, ?, ?)",
                    arguments: ["clipboard", id, source?.appName ?? "", text]
                )
            }
        }
    }

    public func recent(limit: Int) throws -> [ClipboardItem] {
        try database.queue.read { db in
            try ClipboardItem
                .order(Column("last_used_at").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    public func setPinned(id: Int64, _ isPinned: Bool) throws {
        try database.queue.write { db in
            try db.execute(
                sql: "UPDATE clipboard_items SET is_pinned = ? WHERE id = ?",
                arguments: [isPinned, id]
            )
        }
    }

    /// Удаляет запись вместе с блобом. Закрепление не спасает: это прямое
    /// распоряжение пользователя, а не ротация.
    public func delete(id: Int64) throws {
        _ = try performDelete(id: id, sparingPinned: false)
    }

    /// Поднимает запись наверх ленты, не меняя её содержимого.
    ///
    /// Нужен, когда пользователь вставляет старый элемент: он снова стал
    /// актуальным и должен оказаться под рукой, а не там, где лежал.
    public func touch(id: Int64, at now: Date = Date()) throws {
        try database.queue.write { db in
            try db.execute(
                sql: "UPDATE clipboard_items SET last_used_at = ? WHERE id = ?",
                arguments: [now, id]
            )
        }
    }

    /// Чем закончилась попытка удаления.
    enum DeletionOutcome: Sendable {
        case notFound
        case skippedPinned
        case deleted(blobPath: String?)
    }

    /// Общая механика удаления для прямого распоряжения и для вытеснения.
    ///
    /// Порядок неслучаен: сначала строки в одной транзакции, файл с диска —
    /// только после её успешного завершения. Удаление файла не откатывается
    /// вместе с SQL, поэтому при обратном порядке прерванная транзакция
    /// оставила бы запись, ссылающуюся на несуществующий блоб, — видимо
    /// сломанный элемент в ленте. Осиротевший файл при том же сбое стоит
    /// места на диске, но ничего не ломает; из двух исходов выбран он.
    ///
    /// `sparingPinned` проверяется внутри транзакции, а не снаружи, потому
    /// что вытеснение выбирает кандидатов отдельным запросом и удаляет их
    /// по одному. Между выбором и удалением конкретной записи проходит
    /// время, и пользователь успевает её закрепить; снаружи этого уже не
    /// увидеть — та транзакция закрыта.
    ///
    /// Не `private`, а внутренний: защиту закреплённого проверяет тест, и
    /// иначе до неё не дотянуться — `prune` отбирает кандидатов запросом,
    /// в котором закреплённых уже нет, а воспроизвести саму гонку в тесте
    /// нечем.
    func performDelete(id: Int64, sparingPinned: Bool) throws -> DeletionOutcome {
        let outcome = try database.queue.write { db -> DeletionOutcome in
            guard let item = try ClipboardItem.filter(Column("id") == id).fetchOne(db) else {
                return .notFound
            }
            guard !(sparingPinned && item.isPinned) else { return .skippedPinned }

            try db.execute(sql: "DELETE FROM clipboard_items WHERE id = ?", arguments: [id])
            try db.execute(
                sql: "DELETE FROM search_index WHERE owner_kind = 'clipboard' AND owner_id = ?",
                arguments: [id]
            )
            return .deleted(blobPath: item.blobPath)
        }

        if case .deleted(let blobPath) = outcome, let blobPath {
            do {
                try blobs.remove(at: blobPath)
            } catch {
                // Отсутствие файла BlobStore.remove гасит сам, так что сюда
                // долетает только настоящий сбой — прав доступа или
                // ввода-вывода. Проглотить его молча нельзя: запись уже
                // удалена, файл останется навсегда, и объяснить потерянное
                // место будет нечем.
                logger.error(
                    "не удалось удалить блоб \(blobPath, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return outcome
    }

    public func data(for item: ClipboardItem) throws -> Data? {
        guard let path = item.blobPath else { return nil }
        return try blobs.data(at: path)
    }

    public func blobBytes() throws -> Int {
        try blobs.totalSize()
    }

    /// Приводит историю к пределам политики. Возвращает число фактически
    /// удалённых записей — не намеченных к удалению.
    ///
    /// Закреплённое не трогается никогда, и это шире, чем «не удаляется»:
    /// блобы закреплённых записей не входят и в арифметику бюджета объёма.
    /// Закрепив достаточно картинок, можно вывести хранилище за
    /// `maxBlobBytes`, и вытеснение на это не отреагирует. Так и задумано:
    /// закрепление — явное «храни это», а бюджет ограничивает то, что
    /// накапливается само, без участия пользователя.
    @discardableResult
    public func prune(policy: RetentionPolicy, now: Date = Date()) throws -> Int {
        let candidates = try database.queue.read { db in
            try ClipboardItem
                .filter(Column("is_pinned") == false)
                .order(Column("last_used_at").desc)
                .fetchAll(db)
        }

        var doomed: [ClipboardItem] = []
        var keptBlobBytes = 0

        for (index, item) in candidates.enumerated() {
            let tooMany = index >= policy.maxItems
            let tooOld = now.timeIntervalSince(item.lastUsedAt) > policy.maxAge
            let hasBlob = item.blobPath != nil
            let overBudget = hasBlob && keptBlobBytes + item.byteSize > policy.maxBlobBytes

            if tooMany || tooOld || overBudget {
                doomed.append(item)
            } else if hasBlob {
                keptBlobBytes += item.byteSize
            }
        }

        // Считаем удалённое, а не намеченное. Запись из списка может исчезнуть
        // до того, как до неё дойдёт очередь (её удалили вручную), или успеть
        // стать закреплённой — и тогда она останется жить.
        var removed = 0
        for item in doomed {
            guard let id = item.id else { continue }
            if case .deleted = try performDelete(id: id, sparingPinned: true) { removed += 1 }
        }
        return removed
    }
}
