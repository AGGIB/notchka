import Testing
import Foundation
@testable import NotchStore

private func makeStore() throws -> BlobStore {
    let location = StoreLocation.temporary()
    try location.createDirectories()
    return BlobStore(location: location)
}

@Test("identical data produces the same path")
func identicalDataSharesPath() throws {
    let store = try makeStore()
    let data = Data("identical data".utf8)
    #expect(try store.store(data) == store.store(data))
}

@Test("different data produces different paths")
func differentDataDiffers() throws {
    let store = try makeStore()
    #expect(try store.store(Data("a".utf8)) != store.store(Data("b".utf8)))
}

@Test("stored data reads back unchanged")
func roundTripPreservesBytes() throws {
    let store = try makeStore()
    let original = Data((0..<1024).map { UInt8($0 % 256) })
    let path = try store.store(original)
    #expect(try store.data(at: path) == original)
}

@Test("storing the same data twice does not double disk usage")
func duplicateStoreDoesNotGrow() throws {
    let store = try makeStore()
    let data = Data(repeating: 7, count: 4096)
    _ = try store.store(data)
    let afterFirst = try store.totalSize()
    _ = try store.store(data)
    #expect(try store.totalSize() == afterFirst)
}

@Test("path is sharded into subdirectories so thousands of files don't pile up in one")
func pathIsSharded() throws {
    let store = try makeStore()
    let path = try store.store(Data("x".utf8))
    #expect(path.contains("/"))
    #expect(path.split(separator: "/").first?.count == 2)
}

@Test("removal deletes the file and frees space")
func removeFreesSpace() throws {
    let store = try makeStore()
    let path = try store.store(Data(repeating: 1, count: 2048))
    try store.remove(at: path)
    #expect(try store.totalSize() == 0)
}

@Test("reading a missing blob throws instead of returning empty data")
func missingBlobThrows() throws {
    let store = try makeStore()
    #expect(throws: (any Error).self) { try store.data(at: "aa/nonexistent") }
}

/// The other size checks compare the value against itself: "didn't grow,"
/// "went to zero." An implementation that always returns zero would pass
/// those too — but RetentionPolicy's size budget relies on this number, and
/// an understated answer there means eviction simply won't trigger.
@Test("size is counted in actual bytes, not approximated")
func totalSizeCountsActualBytes() throws {
    let store = try makeStore()
    try store.store(Data(repeating: 1, count: 3000))
    #expect(try store.totalSize() == 3000)

    try store.store(Data(repeating: 2, count: 500))
    #expect(try store.totalSize() == 3500)
}

/// Deleting an already-deleted blob happens when eviction coincides in time
/// with a manual removal of the same blob. This should be quiet.
@Test("removing twice does not throw")
func removingTwiceIsQuiet() throws {
    let store = try makeStore()
    let path = try store.store(Data("twice".utf8))
    try store.remove(at: path)
    try store.remove(at: path)
    #expect(try store.totalSize() == 0)
}
