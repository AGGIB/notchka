import Foundation
import GRDB

/// Which repository a found record belongs to — the panel uses this field
/// to decide where to take the user when a result is selected.
///
/// The string values match `owner_kind` in `search_index` literally
/// (see `ClipboardRepository`, `NotesRepository`, `SnippetsRepository`) —
/// the case names here are written with the same words in lowercase, so
/// the synthesized Swift raw value already equals the needed string without
/// an explicit assignment.
public enum SearchKind: String, Sendable {
    case clipboard
    case note
    case snippet
}

/// A single row of cross-source search.
///
/// `snippet` here is a fragment of the result's text (the body of the index
/// record), not a pin: the name coinciding with the `SearchKind.snippet`
/// case is accidental — both are named for what they mean in the task's
/// interface.
public struct SearchResult: Sendable, Equatable {
    public let kind: SearchKind
    public let ownerID: Int64
    public let title: String
    public let snippet: String
}

/// Cross-source search over the shared `search_index`: clipboard history,
/// notes, and pinned snippets in a single query.
///
/// A sensitive pin's value never makes it into the index — `SnippetsRepository`
/// guarantees that on write. Search only reads `search_index` and never
/// touches `snippets.value` directly, so it has no physical way to leak the
/// hidden value around that guarantee.
public struct SearchRepository: Sendable {
    private let database: NotchDatabase

    public init(database: NotchDatabase) {
        self.database = database
    }

    /// Searches all three sources with a single query against the shared index.
    ///
    /// Input that's empty after trimming whitespace, as well as input from which
    /// the FTS5 tokenizer extracts no tokens at all (e.g. a bare `*`), yields
    /// `nil` from `sanitize` and turns into an empty result here without hitting
    /// the database — same as a plain empty input. An empty query shouldn't
    /// return everything, and `MATCH` with an empty string isn't a meaningful
    /// enough query to bother hitting the database for.
    public func search(_ query: String, limit: Int) throws -> [SearchResult] {
        guard let sanitized = Self.sanitize(query) else { return [] }

        return try database.queue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT owner_kind, owner_id, title, body
                    FROM search_index
                    WHERE search_index MATCH ?
                    ORDER BY rank
                    LIMIT ?
                    """,
                arguments: [sanitized, limit]
            )
            return rows.compactMap { row -> SearchResult? in
                guard let kind = SearchKind(rawValue: row["owner_kind"]) else { return nil }
                return SearchResult(
                    kind: kind,
                    ownerID: row["owner_id"],
                    title: row["title"],
                    snippet: row["body"]
                )
            }
        }
    }

    /// Turns free-form input into a safe FTS5 query.
    ///
    /// Without this, plain input containing a quote or asterisk crashes search
    /// with a syntax error — the user isn't obligated to know FTS grammar.
    /// Each word is wrapped in its own quotes (doubling any inner ones) and
    /// joined with a space: FTS5 itself ANDs together several single-word
    /// phrases in a row, and the quotes also keep words like AND or OR from
    /// being parsed as operators.
    static func sanitize(_ query: String) -> String? {
        let words = query
            .split(whereSeparator: { $0.isWhitespace })
            // A word with no letter or digit at all (e.g. a bare "*") gives the
            // FTS5 tokenizer no tokens. Quotes around it save it from being read
            // as an operator (AND/OR/NOT), but not from being an empty phrase
            // inside itself — which is the same syntax-error risk that escaping
            // is supposed to avoid. So such words are dropped before quoting,
            // not after.
            .filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
            .map { $0.replacingOccurrences(of: "\"", with: "\"\"") }
            .map { "\"\($0)\"" }
        guard !words.isEmpty else { return nil }
        // Prefix search only for the last word: the user is typing it
        // right now, the rest have already been entered in full.
        return words.dropLast().joined(separator: " ") + (words.count > 1 ? " " : "") + words.last! + "*"
    }
}
