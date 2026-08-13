import Foundation
import CryptoKit

/// Хранилище картинок и файлов, адресуемое содержимым.
///
/// Путь выводится из хеша, поэтому дедупликация получается сама собой:
/// один и тот же скриншот, скопированный дважды, занимает место один раз,
/// и запись в базе о нём тоже одна.
public struct BlobStore: Sendable {
    private let location: StoreLocation

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

    public func remove(at path: String) throws {
        let url = location.blobsDirectory.appending(path: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public func totalSize() throws -> Int {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: location.blobsDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }

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
