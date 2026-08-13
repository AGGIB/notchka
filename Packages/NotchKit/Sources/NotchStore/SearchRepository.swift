import Foundation
import GRDB

/// Какому репозиторию принадлежит найденная запись — по этому полю панель
/// решает, куда вести пользователя при выборе результата.
///
/// Строковые значения совпадают буквально с `owner_kind` в `search_index`
/// (см. `ClipboardRepository`, `NotesRepository`, `SnippetsRepository`) —
/// имена case здесь написаны теми же словами в нижнем регистре, поэтому
/// синтезированный Swift raw value уже равен нужной строке без явного
/// присвоения.
public enum SearchKind: String, Sendable {
    case clipboard
    case note
    case snippet
}

/// Одна строка сквозного поиска.
///
/// `snippet` здесь — фрагмент текста результата (тело индексной записи),
/// а не пин: совпадение имени с кейсом `SearchKind.snippet` случайно, оба
/// названы по смыслу интерфейса задачи.
public struct SearchResult: Sendable, Equatable {
    public let kind: SearchKind
    public let ownerID: Int64
    public let title: String
    public let snippet: String
}

/// Сквозной поиск по общему индексу `search_index`: история буфера,
/// заметки и закреплённые сниппеты одним запросом.
///
/// Значение чувствительного пина в индекс не попадает — это гарантирует
/// `SnippetsRepository` при записи. Поиск читает только `search_index` и
/// нигде не обращается к `snippets.value` напрямую, поэтому у него физически
/// нет способа вернуть скрытое значение в обход этой гарантии.
public struct SearchRepository: Sendable {
    private let database: NotchDatabase

    public init(database: NotchDatabase) {
        self.database = database
    }

    /// Ищет по всем трём источникам одним запросом к общему индексу.
    ///
    /// Пустой после отсечения пробелов ввод, а также ввод, из которого
    /// токенизатор FTS5 не извлекает ни одного токена (например, один
    /// голый `*`), даёт `nil` от `sanitize` и здесь превращается в пустой
    /// результат без обращения к базе — так же, как обычный пустой ввод.
    /// Порожний запрос не должен возвращать всё подряд, а `MATCH` с пустой
    /// строкой не осмысленный запрос, чтобы вообще идти в базу.
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

    /// Превращает свободный ввод в безопасный запрос FTS5.
    ///
    /// Без этого обычный ввод с кавычкой или звёздочкой роняет поиск
    /// синтаксической ошибкой — пользователь не обязан знать грамматику FTS.
    /// Каждое слово оборачивается в свои кавычки (с удвоением внутренних) и
    /// склеивается пробелом: несколько одно-словных фраз подряд FTS5 сам
    /// соединяет через AND, а кавычки заодно не дают словам вроде AND или OR
    /// быть понятыми как операторы.
    static func sanitize(_ query: String) -> String? {
        let words = query
            .split(whereSeparator: { $0.isWhitespace })
            // Слово без единой буквы или цифры (например, голая "*") не
            // даёт токенизатору FTS5 ни одного токена. Кавычки вокруг него
            // спасают от статуса оператора (AND/OR/NOT), но не от пустой
            // фразы внутри себя — а это тот же риск синтаксической ошибки,
            // которого экранирование и должно избегать. Поэтому такие слова
            // отбрасываются до кавычек, а не после.
            .filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
            .map { $0.replacingOccurrences(of: "\"", with: "\"\"") }
            .map { "\"\($0)\"" }
        guard !words.isEmpty else { return nil }
        // Префиксный поиск только для последнего слова: пользователь
        // дописывает его прямо сейчас, остальные уже введены целиком.
        return words.dropLast().joined(separator: " ") + (words.count > 1 ? " " : "") + words.last! + "*"
    }
}
