import Foundation

/// Частичный payload: адаптер шлёт диффы, где заданы только изменившиеся поля,
/// поэтому все свойства опциональны и «отсутствует» не равно «сброшено в ноль».
public struct NowPlayingPayload: Sendable, Equatable, Decodable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var duration: TimeInterval?
    public var elapsedTime: TimeInterval?
    public var timestamp: Date?
    public var playbackRate: Double?
    public var playing: Bool?
    public var bundleIdentifier: String?
    public var artworkData: Data?
    public var artworkMimeType: String?
    /// Bundle id родительского приложения — приходит отдельно от
    /// `bundleIdentifier`, когда источник на самом деле вспомогательный
    /// процесс. Находка Task 4: Safari отдаёт `bundleIdentifier ==
    /// "com.apple.WebKit.GPU"` (процесс рендеринга), а это поле несёт
    /// настоящее приложение, `"com.apple.Safari"`. У большинства
    /// источников (Chrome напрямую и т.п.) адаптер это поле не присылает
    /// вовсе — nil, а не пустая строка.
    public var parentApplicationBundleIdentifier: String?

    public init() {}

    /// Пустой payload значит «сессии нет», а не «трек без названия».
    public var isEmpty: Bool {
        title == nil && artist == nil && album == nil && duration == nil
            && elapsedTime == nil && timestamp == nil && playbackRate == nil
            && playing == nil && bundleIdentifier == nil && artworkData == nil
            && artworkMimeType == nil && parentApplicationBundleIdentifier == nil
    }

    /// Накладывает дифф на имеющийся снимок. Возвращает nil, если снимка ещё
    /// не было: дифф сам по себе не описывает трек целиком.
    public func applied(to base: NowPlayingSnapshot?) -> NowPlayingSnapshot? {
        guard var snapshot = base else { return nil }
        if let title { snapshot.title = title }
        if let artist { snapshot.artist = artist }
        if let album { snapshot.album = album }
        if let duration { snapshot.duration = duration }
        if let elapsedTime { snapshot.elapsedTime = elapsedTime }
        if let timestamp { snapshot.timestamp = timestamp }
        if let playbackRate { snapshot.playbackRate = playbackRate }
        if let playing { snapshot.isPlaying = playing }
        if let bundleIdentifier { snapshot.sourceBundleID = bundleIdentifier }
        if let artworkData { snapshot.artworkData = artworkData }
        if let artworkMimeType { snapshot.artworkMimeType = artworkMimeType }
        if let parentApplicationBundleIdentifier {
            snapshot.parentApplicationBundleID = parentApplicationBundleIdentifier
        }
        return snapshot
    }

    /// Полный снимок из payload. Недостающие поля заполняются нейтрально:
    /// адаптер опускает пустые строки и нулевые длительности.
    public func asSnapshot() -> NowPlayingSnapshot? {
        guard !isEmpty else { return nil }
        return NowPlayingSnapshot(
            title: title ?? "",
            artist: artist ?? "",
            album: album ?? "",
            duration: duration ?? 0,
            elapsedTime: elapsedTime ?? 0,
            timestamp: timestamp ?? Date(timeIntervalSince1970: 0),
            playbackRate: playbackRate ?? 0,
            isPlaying: playing ?? false,
            sourceBundleID: bundleIdentifier ?? "",
            artworkData: artworkData,
            artworkMimeType: artworkMimeType,
            parentApplicationBundleID: parentApplicationBundleIdentifier
        )
    }
}

/// Одна строка вывода адаптера.
public enum AdapterLine: Sendable, Equatable {
    /// Полное состояние. nil значит «сессии нет».
    case snapshot(NowPlayingSnapshot?)
    case diff(NowPlayingPayload)
    /// Адаптер жив, но конкретный ответ не получился — канал ронять не надо.
    case transientFailure(String)
    case unrecognized(String)

    private struct Envelope: Decodable {
        let type: String
        let diff: Bool
        let payload: NowPlayingPayload
    }

    /// Известный текст таймаута из адаптера. Проверяется перед разбором JSON
    /// чтобы отличить временную осечку от невалидного входа.
    private static let adapterTimeoutMessage = "timed out"

    public static func parse(_ line: String) -> AdapterLine {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unrecognized(line) }

        guard let data = trimmed.data(using: .utf8) else { return .unrecognized(line) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // Проверка таймаута идёт после попытки разобрать JSON. Если строка
        // — валидный JSON-объект, это не осечка адаптера, а просто данные.
        // Только открытый текст может быть ошибкой таймаута.
        if let envelope = try? decoder.decode(Envelope.self, from: data) {
            return envelope.diff ? .diff(envelope.payload) : .snapshot(envelope.payload.asSnapshot())
        }

        // Осечку адаптер печатает открытым текстом, не JSON-ом. Отличать её
        // от мусора важно: супервизор не должен считать это падением канала.
        if trimmed.contains(adapterTimeoutMessage) { return .transientFailure(trimmed) }

        return .unrecognized(line)
    }
}
