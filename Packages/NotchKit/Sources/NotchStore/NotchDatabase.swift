import Foundation
import GRDB

/// Connection to the database and its schema.
///
/// Migrations are numbered and immutable after release: plan 4 will add its
/// own as a next step, not by editing this one. Otherwise a user's database
/// created today would diverge from the schema tomorrow's code expects.
public final class NotchDatabase: Sendable {
    public let queue: DatabaseQueue

    public init(location: StoreLocation) throws {
        try location.createDirectories()
        self.queue = try DatabaseQueue(path: location.databaseURL.path)
    }

    public func migrate() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1-clipboard") { db in
            try db.create(table: "clipboard_items") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull()
                // Content hash is unique: copying the same text again
                // bumps the existing record instead of creating duplicates.
                t.column("content_hash", .text).notNull().unique()
                t.column("text_body", .text)
                t.column("blob_path", .text)
                t.column("byte_size", .integer).notNull()
                t.column("source_bundle_id", .text)
                t.column("source_app_name", .text)
                t.column("created_at", .datetime).notNull()
                t.column("last_used_at", .datetime).notNull()
                t.column("is_pinned", .boolean).notNull().defaults(to: false)
            }
            // The feed is always sorted by last used time —
            // without an index that's a full scan on every panel open.
            try db.create(index: "idx_clipboard_last_used", on: "clipboard_items", columns: ["last_used_at"])
        }

        migrator.registerMigration("v2-search") { db in
            // A regular FTS5 table, not contentless: the index stores a copy
            // of the text. This is a deliberate tradeoff. Contentless
            // (content='') would save space, but deleting from it requires
            // a special rowid-based command, while index rows point back to
            // their owner via the (owner_kind, owner_id) pair — that's what
            // Task 4 deletes by, with an ordinary DELETE ... WHERE. The cost
            // of the tradeoff is small: only text enters the index, images
            // and files don't go there.
            try db.create(virtualTable: "search_index", using: FTS5()) { t in
                t.column("owner_kind").notIndexed()
                t.column("owner_id").notIndexed()
                t.column("title")
                t.column("body")
            }
        }

        migrator.registerMigration("v3-stash") { db in
            try db.create(table: "notes") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("body", .text).notNull()
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }

            try db.create(table: "snippets") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("label", .text).notNull()
                t.column("value", .text).notNull()
                t.column("icon", .text)
                t.column("color_hex", .text)
                // Order is set by the user via drag-and-drop; duplicates
                // are allowed and resolved by a stable sort on id.
                t.column("sort_order", .integer).notNull()
                t.column("is_sensitive", .boolean).notNull().defaults(to: false)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }
        }

        try migrator.migrate(queue)
    }
}
