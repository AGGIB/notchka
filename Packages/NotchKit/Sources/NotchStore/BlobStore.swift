import Foundation
import CryptoKit
import os

/// Хранилище картинок и файлов, адресуемое содержимым.
///
/// Путь выводится из хеша, поэтому дедупликация получается сама собой:
/// один и тот же скриншот, скопированный дважды, занимает место один раз,
/// и запись в базе о нём тоже одна.
public struct BlobStore: Sendable {
    private let location: StoreLocation
    private let logger = Logger(subsystem: "kz.mobilefirst.notchka", category: "blobs")

    public init(location: StoreLocation) {
        self.location = location
    }

    public static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Сохраняет данные и возвращает относительный путь.
    @discardableResult
    public func store(_ data: Data) throws -> String {
        let path = Self.relativePath(for: Self.hash(data))
        let url = location.blobsDirectory.appending(path: path)
        // Файл с таким именем — это ровно эти байты: содержимое и есть имя.
        // Перезаписывать незачем, и это экономит запись на каждый повтор.
        guard !FileManager.default.fileExists(atPath: url.path) else { return path }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        return path
    }

    public func data(at path: String) throws -> Data {
        try Data(contentsOf: location.blobsDirectory.appending(path: path))
    }

    /// Удаляет блоб. Отсутствие файла — не ошибка: цель вызова достигнута.
    ///
    /// Именно удаление с перехватом, а не проверка существования перед ним.
    /// Проверка и удаление — две операции, и между ними файл может исчезнуть:
    /// вытеснение по объёму из RetentionPolicy вполне может совпасть по
    /// времени с удалением того же блоба вручную. Тогда проверка проходит,
    /// а удаление бросает — ровно там, где вызывающий вправе рассчитывать
    /// на тихий отказ.
    public func remove(at path: String) throws {
        let url = location.blobsDirectory.appending(path: path)
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
    }

    /// Сколько места занято блобами.
    ///
    /// На этом числе держится бюджет объёма в RetentionPolicy, поэтому ошибка
    /// обхода каталога обязана оставлять след. Без обработчика перечислитель
    /// пропускает недоступное поддерево молча, и метод возвращает
    /// правдоподобное заниженное число: вытеснение не срабатывает вовремя,
    /// а понять причину не по чему. Обработчик не прерывает обход — лучше
    /// посчитать остальное и сказать об этом, чем не посчитать ничего.
    public func totalSize() throws -> Int {
        let fm = FileManager.default
        let enumerator = fm.enumerator(
            at: location.blobsDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [],
            errorHandler: { [logger] url, error in
                logger.error(
                    "не удалось обойти \(url.lastPathComponent, privacy: .public) при подсчёте блобов: \(error.localizedDescription, privacy: .public)"
                )
                return true
            }
        )
        // Отсутствующий каталог блобов даёт не nil, а перечислитель с нулём
        // итераций, так что ветка ниже на практике не срабатывает. Она нужна
        // потому, что API возвращает Optional, а не потому, что защищает от
        // отсутствия каталога.
        guard let enumerator else { return 0 }

        var total = 0
        for case let url as URL in enumerator {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            total += size ?? 0
        }
        return total
    }

    /// Первые два символа хеша — подкаталог: тысячи файлов в одной папке
    /// замедляют файловую систему и делают каталог нечитаемым глазами.
    private static func relativePath(for hash: String) -> String {
        "\(hash.prefix(2))/\(hash)"
    }
}
