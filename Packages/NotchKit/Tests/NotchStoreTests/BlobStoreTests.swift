import Testing
import Foundation
@testable import NotchStore

private func makeStore() throws -> BlobStore {
    let location = StoreLocation.temporary()
    try location.createDirectories()
    return BlobStore(location: location)
}

@Test("одинаковые данные дают одинаковый путь")
func identicalDataSharesPath() throws {
    let store = try makeStore()
    let data = Data("одно и то же".utf8)
    #expect(try store.store(data) == store.store(data))
}

@Test("разные данные дают разные пути")
func differentDataDiffers() throws {
    let store = try makeStore()
    #expect(try store.store(Data("a".utf8)) != store.store(Data("b".utf8)))
}

@Test("сохранённые данные читаются обратно без изменений")
func roundTripPreservesBytes() throws {
    let store = try makeStore()
    let original = Data((0..<1024).map { UInt8($0 % 256) })
    let path = try store.store(original)
    #expect(try store.data(at: path) == original)
}

@Test("повторное сохранение не удваивает место на диске")
func duplicateStoreDoesNotGrow() throws {
    let store = try makeStore()
    let data = Data(repeating: 7, count: 4096)
    _ = try store.store(data)
    let afterFirst = try store.totalSize()
    _ = try store.store(data)
    #expect(try store.totalSize() == afterFirst)
}

@Test("путь разложен по подкаталогам, чтобы не собирать тысячи файлов в одном")
func pathIsSharded() throws {
    let store = try makeStore()
    let path = try store.store(Data("x".utf8))
    #expect(path.contains("/"))
    #expect(path.split(separator: "/").first?.count == 2)
}

@Test("удаление убирает файл и освобождает место")
func removeFreesSpace() throws {
    let store = try makeStore()
    let path = try store.store(Data(repeating: 1, count: 2048))
    try store.remove(at: path)
    #expect(try store.totalSize() == 0)
}

@Test("чтение отсутствующего блоба бросает, а не отдаёт пустые данные")
func missingBlobThrows() throws {
    let store = try makeStore()
    #expect(throws: (any Error).self) { try store.data(at: "aa/несуществующий") }
}
