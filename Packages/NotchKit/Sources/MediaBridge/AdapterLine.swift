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
    ///
    /// `now` используется ровно в одном случае — см. блок про перепривязку
    /// метки времени ниже; для любого другого перехода он не влияет ни на что.
    public func applied(to base: NowPlayingSnapshot?, now: Date) -> NowPlayingSnapshot? {
        guard var snapshot = base else { return nil }
        let wasPlaying = snapshot.isPlaying
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

        // Play/pause-тумблер приходит парой диффов (спайк, раздел «Поток
        // обновлений»): первая строка несёт только {"playing":true}, без
        // собственной timestamp, вторая донесёт настоящую метку чуть позже.
        // Без перепривязки здесь snapshot.timestamp остался бы тем, что было
        // до этого диффа, — то есть моментом, когда трек ПОСТАВИЛИ на паузу,
        // а не моментом, когда его возобновили. PlaybackPosition.current
        // экстраполирует «now − timestamp» только пока isPlaying истинно, так
        // что вся длительность паузы превращается в мнимый прогресс, и бар
        // прыгает к концу трека до прихода второй строки диффа. Условие
        // узкое нарочно: только переход false→true и только когда сам дифф
        // не прислал timestamp — во всех остальных случаях значение адаптера
        // (или его отсутствие) остаётся как есть.
        if timestamp == nil, playing == true, !wasPlaying {
            snapshot.timestamp = now
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

    /// Разбирает голый payload команды `get` — отдельный путь от `parse(_:)`
    /// выше, а не его ветка внутри.
    ///
    /// `parse(_:)` рассчитан на строки `stream` и всегда ждёт конверт
    /// `{"type":..,"diff":..,"payload":..}`; `get` печатает `NowPlayingPayload`
    /// как есть, без конверта вообще, поэтому `Envelope.decode` на такой
    /// строке не найдёт ключ `payload` и провалится — сама строка при этом
    /// вполне валидный JSON, так что `parse(_:)` доехал бы до `.unrecognized`,
    /// а не до осечки или снимка. Смешивать два формата в одном методе
    /// значило бы либо ослаблять Envelope до опциональных полей (и тогда
    /// строка stream без "type" тоже стала бы молча проходить как payload),
    /// либо гадать по наличию ключей — оба варианта хуже честного отдельного
    /// пути с говорящим именем.
    ///
    /// Существует ради разовой пересинхронизации (см. `AdapterProcess.get()`
    /// / `AdapterProvider.refresh()`): нужен полный `NowPlayingSnapshot?`,
    /// а не `AdapterLine` — вызывающей стороне неоткуда взять `diff`-флаг
    /// для конверта, которого в этом формате не было изначально.
    public static func parseSnapshot(_ line: String) -> NowPlayingSnapshot? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(NowPlayingPayload.self, from: data) else { return nil }
        return payload.asSnapshot()
    }
}
