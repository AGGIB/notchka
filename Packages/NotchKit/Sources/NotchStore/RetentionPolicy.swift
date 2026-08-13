import Foundation

/// Сколько истории хранить.
///
/// Три независимых предела, а не один: количество бережёт скорость ленты,
/// возраст — приватность (скопированное полгода назад пользователь давно
/// забыл), объём — диск, потому что один скриншот весит как тысяча строк
/// текста. Срабатывает тот, до которого дошли первым.
public struct RetentionPolicy: Sendable, Equatable {
    public let maxItems: Int
    public let maxAge: TimeInterval
    public let maxBlobBytes: Int

    public init(maxItems: Int, maxAge: TimeInterval, maxBlobBytes: Int) {
        self.maxItems = maxItems
        self.maxAge = maxAge
        self.maxBlobBytes = maxBlobBytes
    }

    public static let `default` = RetentionPolicy(
        maxItems: 500,
        maxAge: 30 * 24 * 3600,
        maxBlobBytes: 2 * 1024 * 1024 * 1024
    )
}
