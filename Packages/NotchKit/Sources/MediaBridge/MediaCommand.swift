/// Команда управления воспроизведением.
///
/// Коды подтверждены спайком эмпирически, а не взяты из заголовка фреймворка:
/// `play` и `pause` идемпотентны, `toggle` инвертирует состояние на каждый вызов.
public enum MediaCommand: Sendable, Equatable {
    case play
    case pause
    case toggle

    public var adapterCode: Int32 {
        switch self {
        case .play: 0
        case .pause: 1
        case .toggle: 2
        }
    }
}
