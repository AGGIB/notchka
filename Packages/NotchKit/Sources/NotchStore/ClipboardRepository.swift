import Foundation
import GRDB
import os

/// Access to the clipboard history.
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
        // The hash is computed once and handed to the store ready-made: the blob
        // path and the dedup key in the database are the same number, and an
        // extra SHA-256 pass over the screenshot's megabytes buys nothing.
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

    /// A repeat doesn't create a second record: hash uniqueness catches it at
    /// the database level, and we bump the existing row to the top of the feed.
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

    /// Deletes the record along with its blob. Pinning doesn't help here: this
    /// is a direct user command, not rotation.
    public func delete(id: Int64) throws {
        _ = try performDelete(id: id, sparingPinned: false)
    }

    /// Bumps the record to the top of the feed without changing its content.
    ///
    /// Needed when the user pastes an old item: it's relevant again and should
    /// be within reach, not wherever it used to sit.
    public func touch(id: Int64, at now: Date = Date()) throws {
        try database.queue.write { db in
            try db.execute(
                sql: "UPDATE clipboard_items SET last_used_at = ? WHERE id = ?",
                arguments: [now, id]
            )
        }
    }

    /// The outcome of a deletion attempt.
    enum DeletionOutcome: Sendable {
        case notFound
        case skippedPinned
        case deleted(blobPath: String?)
    }

    /// Shared deletion mechanics for direct commands and for eviction.
    ///
    /// The order isn't arbitrary: rows first, in a single transaction; the file
    /// on disk only after it commits successfully. File deletion doesn't roll
    /// back together with SQL, so in the reverse order an interrupted
    /// transaction would leave a record pointing at a nonexistent blob — a
    /// visibly broken item in the feed. An orphaned file from the same failure
    /// costs disk space but breaks nothing; of the two outcomes, that one is
    /// chosen.
    ///
    /// `sparingPinned` is checked inside the transaction, not outside it,
    /// because eviction picks candidates with a separate query and deletes them
    /// one by one. Time passes between selecting a given record and deleting
    /// it, and the user may manage to pin it in that window; from outside, this
    /// is no longer visible — that transaction is already closed.
    ///
    /// Not `private`, but internal: a test verifies the pinned-item guard, and
    /// there's no other way to reach it — `prune` selects candidates with a
    /// query that already excludes pinned items, so the race itself can't be
    /// reproduced in a test.
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
                // BlobStore.remove already swallows a missing file, so only a real
                // failure — permissions or I/O — reaches here. It can't be swallowed
                // silently: the record is already deleted, the file would remain
                // forever, and there'd be nothing to explain the lost space.
                logger.error(
                    "failed to remove blob \(blobPath, privacy: .public): \(error.localizedDescription, privacy: .public)"
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

    /// Brings the history within policy limits. Returns the number of records
    /// actually deleted — not the number marked for deletion.
    ///
    /// Pinned items are never touched, and that's broader than "not deleted":
    /// blobs of pinned records are also excluded from the volume-budget math.
    /// Pin enough images and storage can grow past `maxBlobBytes`, and eviction
    /// won't react to that. That's intentional: pinning is an explicit "keep
    /// this", while the budget limits only what accumulates on its own, without
    /// user involvement.
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

        // We count what's deleted, not what's marked. A record from the list may
        // disappear before its turn comes (deleted manually elsewhere), or manage
        // to become pinned — and then it survives.
        var removed = 0
        for item in doomed {
            guard let id = item.id else { continue }
            if case .deleted = try performDelete(id: id, sparingPinned: true) { removed += 1 }
        }
        return removed
    }
}
