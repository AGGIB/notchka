import Testing
import Foundation
@testable import NotchStore

private func makeRepository() throws -> ClipboardRepository {
    let location = StoreLocation.temporary()
    let database = try NotchDatabase(location: location)
    try database.migrate()
    return ClipboardRepository(database: database, blobs: BlobStore(location: location))
}

private let t0 = Date(timeIntervalSince1970: 1_000_000)

@Test("defaults match the spec")
func defaultsMatchSpec() {
    #expect(RetentionPolicy.default.maxItems == 500)
    #expect(RetentionPolicy.default.maxAge == 30 * 24 * 3600)
    #expect(RetentionPolicy.default.maxBlobBytes == 2 * 1024 * 1024 * 1024)
}

@Test("excess items are dropped, oldest first")
func excessItemsAreDropped() throws {
    let repository = try makeRepository()
    for index in 0..<10 {
        try repository.saveText("\(index)", source: nil, at: t0.addingTimeInterval(Double(index)))
    }
    let removed = try repository.prune(
        policy: RetentionPolicy(maxItems: 4, maxAge: .infinity, maxBlobBytes: .max),
        now: t0.addingTimeInterval(100)
    )
    #expect(removed == 6)
    #expect(try repository.recent(limit: 100).map(\.textBody) == ["9", "8", "7", "6"])
}

@Test("stale items are dropped")
func staleItemsAreDropped() throws {
    let repository = try makeRepository()
    try repository.saveText("ancient", source: nil, at: t0)
    try repository.saveText("fresh", source: nil, at: t0.addingTimeInterval(86_400))
    let removed = try repository.prune(
        policy: RetentionPolicy(maxItems: .max, maxAge: 3600, maxBlobBytes: .max),
        now: t0.addingTimeInterval(86_400 + 60)
    )
    #expect(removed == 1)
    #expect(try repository.recent(limit: 10).map(\.textBody) == ["fresh"])
}

@Test("pinned item isn't evicted by count or by age")
func pinnedSurvivesEverything() throws {
    let repository = try makeRepository()
    try repository.saveText("pinned", source: nil, at: t0)
    let pinned = try #require(try repository.recent(limit: 1).first)
    try repository.setPinned(id: pinned.id!, true)
    for index in 0..<20 {
        try repository.saveText("noise \(index)", source: nil, at: t0.addingTimeInterval(Double(index + 1)))
    }

    _ = try repository.prune(
        policy: RetentionPolicy(maxItems: 3, maxAge: 1, maxBlobBytes: .max),
        now: t0.addingTimeInterval(10_000)
    )
    let survivors = try repository.recent(limit: 100).map(\.textBody)
    #expect(survivors.contains("pinned"))
    // Without this line the test would also pass with eviction completely broken:
    // the pinned item obviously survives if nothing gets deleted at all.
    // This checks not "this entry survived" but "it survived while pruning actually worked".
    #expect(survivors.contains("noise 0") == false)
}

/// Pinned items are excluded from the size budget entirely — not only protected
/// from deletion, but also not counted as taking up space. This is deliberate:
/// pinning is an explicit "keep this", while the budget limits what accumulates
/// on its own. The test locks in this decision so it doesn't get reverted by accident.
@Test("blobs of pinned entries are excluded from the size budget")
func pinnedBlobsAreOutsideTheBudget() throws {
    let repository = try makeRepository()
    try repository.saveImage(Data(repeating: 1, count: 4096), source: nil, at: t0)
    let pinned = try #require(try repository.recent(limit: 1).first)
    try repository.setPinned(id: pinned.id!, true)

    let removed = try repository.prune(
        policy: RetentionPolicy(maxItems: .max, maxAge: .infinity, maxBlobBytes: 1024),
        now: t0.addingTimeInterval(100)
    )
    #expect(removed == 0)
    #expect(try repository.blobBytes() == 4096)
}

/// Eviction selects candidates with a single query, then deletes them one by
/// one in separate transactions — otherwise GRDB would fail on a nested transaction.
/// Between selection and deletion of a given entry it can get pinned in time, and
/// the check inside the deletion transaction is the only thing standing between
/// such an entry and its loss. The race itself can't be reproduced in a test,
/// so the guard is verified directly instead.
@Test("guarded delete spares pinned items, direct delete does not")
func guardedDeleteSparesPinnedButDirectDoesNot() throws {
    let repository = try makeRepository()
    try repository.saveText("pinned later", source: nil, at: t0)
    let item = try #require(try repository.recent(limit: 1).first)
    let id = try #require(item.id)
    try repository.setPinned(id: id, true)

    _ = try repository.performDelete(id: id, sparingPinned: true)
    #expect(try repository.recent(limit: 10).count == 1)

    // A direct user command isn't stopped by pinning:
    // pinned doesn't mean "cannot be deleted", it means "won't delete itself".
    try repository.delete(id: id)
    #expect(try repository.recent(limit: 10).isEmpty)
}

@Test("exceeding the blob size budget evicts the oldest items with blobs")
func blobBudgetIsEnforced() throws {
    let repository = try makeRepository()
    for index in 0..<5 {
        try repository.saveImage(
            Data(repeating: UInt8(index), count: 1024),
            source: nil, at: t0.addingTimeInterval(Double(index))
        )
    }
    _ = try repository.prune(
        policy: RetentionPolicy(maxItems: .max, maxAge: .infinity, maxBlobBytes: 2048),
        now: t0.addingTimeInterval(100)
    )
    #expect(try repository.blobBytes() <= 2048)
}

@Test("pruning an empty database is safe")
func pruningEmptyIsSafe() throws {
    let repository = try makeRepository()
    #expect(try repository.prune(policy: .default, now: t0) == 0)
}
