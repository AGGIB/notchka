import Foundation
import GRDB

/// Доступ к истории буфера.
public struct ClipboardRepository: Sendable {
    private let database: NotchDatabase
    private let blobs: BlobStore

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
        let path = try blobs.store(data)
        try save(
            kind: .image, hash: BlobStore.hash(data), text: nil, blobPath: path,
            byteSize: data.count, source: source, at: now
        )
    }

    public func saveFile(
        _ data: Data,
        fileName: String,
        source: (bundleID: String, appName: String)?,
        at now: Date = Date()
    ) throws {
        let path = try blobs.store(data)
        try save(
            kind: .file, hash: BlobStore.hash(data), text: fileName, blobPath: path,
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

    public func delete(id: Int64) throws {
        try database.queue.write { db in
            let item = try ClipboardItem.filter(Column("id") == id).fetchOne(db)
            // Блоб удаляется вместе с записью: осиротевший файл не найдёт
            // никто, а место он занимать продолжит.
            if let path = item?.blobPath { try? blobs.remove(at: path) }
            try db.execute(sql: "DELETE FROM clipboard_items WHERE id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM search_index WHERE owner_kind = 'clipboard' AND owner_id = ?", arguments: [id])
        }
    }

    public func data(for item: ClipboardItem) throws -> Data? {
        guard let path = item.blobPath else { return nil }
        return try blobs.data(at: path)
    }

    public func blobBytes() throws -> Int {
        try blobs.totalSize()
    }

    /// Приводит историю к пределам политики. Возвращает число удалённых.
    ///
    /// Закреплённое не трогается никогда: пользователь закрепил его именно
    /// затем, чтобы оно пережило ротацию.
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

        for item in doomed {
            if let id = item.id { try delete(id: id) }
        }
        return doomed.count
    }
}
