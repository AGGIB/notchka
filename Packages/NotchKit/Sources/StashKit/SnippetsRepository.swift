import Foundation
import GRDB
import NotchStore

/// Access to the pinned snippets repository.
public struct SnippetsRepository: Sendable {
    private let database: NotchDatabase

    // Owner kind in the shared search_index. A constant, not a literal
    // repeated in several places: a typo in one of them silently breaks
    // search, and the compiler won't catch it — only a runtime string mismatch.
    private static let ownerKind = "snippet"

    /// What part of a pin's value goes into the search index.
    ///
    /// The single place where this decision is made — so that "secrets
    /// aren't indexed" rests on one line instead of on discipline across
    /// three write sites. An empty string, not the value: the index isn't
    /// encrypted, and putting a secret there would defeat masking via search.
    private static func indexedValue(_ value: String, isSensitive: Bool) -> String {
        isSensitive ? "" : value
    }

    public init(database: NotchDatabase) {
        self.database = database
    }

    /// Saves a pin at the end of the list. After trimming whitespace, an
    /// empty label isn't saved — a pin without a caption is indistinguishable
    /// from its neighbor.
    ///
    /// The label always goes into the index; the value only for a
    /// non-sensitive pin. The rule "never index values at all" would be
    /// simpler, but it would make pins nearly unsearchable: people search
    /// for an email or phone number by the number itself at least as often
    /// as by the caption. What needs hiding is secrets, not everything —
    /// otherwise the protection costs the very feature it exists for.
    ///
    /// The new pin's order is the current maximum plus one, not the row
    /// count: after deletions from the middle of the list, the row count is
    /// less than the maximum sort_order, and counting via count() would
    /// stick the new pin in the middle instead of at the end.
    ///
    /// The pin record and the index row are written in a single
    /// transaction: without this, a failure between the two inserts could
    /// leave a saved pin without an index entry, and search wouldn't find it.
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
                arguments: [Self.ownerKind, id, trimmed, Self.indexedValue(value, isSensitive: isSensitive)]
            )
        }
    }

    /// All pins in user order. Duplicate sort_order values are allowed
    /// intentionally (see schema) — ties are broken by sorting on id, with
    /// the earlier-inserted of the tied rows coming first.
    public func all() throws -> [Snippet] {
        try database.queue.read { db in
            try Snippet.order(Column("sort_order"), Column("id")).fetchAll(db)
        }
    }

    /// Moves a pin to position `newIndex` and renumbers the entire list.
    /// Fractional orders (inserting between neighbors without shifting the
    /// rest) would save a write, but for a list of a dozen pins that
    /// saving isn't worth the added complexity of reading it.
    ///
    /// An out-of-range index is clamped rather than causing an error: the
    /// panel passes a position from drag-and-drop, where an off-by-one is
    /// routine, not a reason to fail the operation.
    ///
    /// Reading the current order goes through the same `db` obtained
    /// inside `write`, not through `self.all()`: a nested queue.read or
    /// queue.write call inside an already-open write is a fatal GRDB error
    /// in this project, not just a slow path.
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

    /// Updates the label, value, icon, color, and sensitivity flag. The
    /// creation time and sort_order aren't touched: an edit shouldn't look
    /// like a new pin and shouldn't by itself move it in the list —
    /// `move` exists for reordering.
    ///
    /// A label that's empty after trimming whitespace is rejected by the
    /// same rule as on creation.
    ///
    /// The index row is rewritten with the current label in the same
    /// transaction as the record itself — as with create and delete, so
    /// search doesn't lag behind the label if something fails between
    /// operations.
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
                sql: "UPDATE search_index SET title = ?, body = ? WHERE owner_kind = ? AND owner_id = ?",
                arguments: [
                    trimmed,
                    Self.indexedValue(snippet.value, isSensitive: snippet.isSensitive),
                    Self.ownerKind, id,
                ]
            )
        }
    }

    /// Deletes a pin together with its index row in a single transaction —
    /// otherwise, after a failure between operations, search could find a
    /// pin that's already been deleted.
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
