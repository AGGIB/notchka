import Foundation

/// Решает, надо ли читать пастборд.
///
/// Публичного уведомления об изменении пастборда в macOS нет — остаётся
/// опрос счётчика. Логика «читать или нет» отделена от `NSPasteboard`,
/// чтобы проверяться без него: подделать `changeCount` живой системы
/// в тесте нельзя.
public struct PasteboardPoller: Sendable {
    /// Чаще нет смысла: человек не копирует по пять раз в секунду.
    public static let interval: TimeInterval = 0.4
    /// Неактивный пользователь ничего не копирует — незачем будить процесс.
    public static let idleThreshold: TimeInterval = 60

    private var lastSeenCount: Int?

    public init() {}

    public mutating func shouldRead(changeCount: Int, idleSeconds: TimeInterval) -> Bool {
        guard idleSeconds < Self.idleThreshold else { return false }
        // Счётчик не запоминаем, пока пользователь неактивен: иначе
        // скопированное во время его отсутствия потерялось бы навсегда.
        guard lastSeenCount != changeCount else { return false }
        lastSeenCount = changeCount
        return true
    }

    /// Помечает изменение как своё — читать его не надо.
    ///
    /// Приложение само пишет в пастборд, когда пользователь достаёт что-то
    /// из истории. Без этой отметки опрос через доли секунды прочитает
    /// собственную запись и заведёт вторую запись о том же. Для текста это
    /// сходило бы с рук: побайтово он тот же, и дедупликация по хешу просто
    /// подняла бы существующую строку. Но картинка возвращается с пастборда
    /// в другом представлении и с другим размером — хеш не совпадает, и в
    /// истории появляется дубль, вдобавок заметно тяжелее оригинала.
    public mutating func ignore(changeCount: Int) {
        lastSeenCount = changeCount
    }
}
