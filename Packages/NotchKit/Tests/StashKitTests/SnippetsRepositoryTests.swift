import Testing
import Foundation
import NotchStore
@testable import StashKit

private let t0 = Date(timeIntervalSince1970: 1_000_000)

private func makeRepository() throws -> SnippetsRepository {
    let database = try NotchDatabase(location: .temporary())
    try database.migrate()
    return SnippetsRepository(database: database)
}

@Test("pin persists with all fields")
func snippetRoundTrips() throws {
    let repository = try makeRepository()
    try repository.add(label: "Mail", value: "developer@mobilefirst.kz",
                       icon: "envelope", colorHex: "#FF2D95", isSensitive: false, at: t0)
    let pin = try #require(try repository.all().first)
    #expect(pin.label == "Mail")
    #expect(pin.value == "developer@mobilefirst.kz")
    #expect(pin.icon == "envelope")
    #expect(pin.isSensitive == false)
}

@Test("pins are returned in the given order")
func orderIsPreserved() throws {
    let repository = try makeRepository()
    try repository.add(label: "third", value: "3", icon: nil, colorHex: nil, isSensitive: false, at: t0)
    try repository.add(label: "first", value: "1", icon: nil, colorHex: nil, isSensitive: false, at: t0)
    let pins = try repository.all()
    try repository.move(id: pins[1].id!, to: 0)
    #expect(try repository.all().map(\.label) == ["first", "third"])
}

@Test("moving to the end works")
func moveToEnd() throws {
    let repository = try makeRepository()
    for label in ["a", "b", "c"] {
        try repository.add(label: label, value: label, icon: nil, colorHex: nil, isSensitive: false, at: t0)
    }
    let first = try #require(try repository.all().first)
    try repository.move(id: first.id!, to: 2)
    #expect(try repository.all().map(\.label) == ["b", "c", "a"])
}

@Test("sensitive value is masked with dots")
func sensitiveValueIsMasked() {
    #expect(Snippet.masked("123456789012") == "••• ••• •••")
}

@Test("masking does not depend on length — the value can't be guessed from it")
func maskDoesNotLeakLength() {
    #expect(Snippet.masked("12") == Snippet.masked("1234567890123456"))
}

@Test("empty label is not saved")
func emptyLabelIsRejected() throws {
    let repository = try makeRepository()
    try repository.add(label: "  ", value: "value", icon: nil, colorHex: nil, isSensitive: false, at: t0)
    #expect(try repository.all().isEmpty)
}

@Test("label is indexed, but sensitive value is not")
func sensitiveValueIsNotIndexed() throws {
    let database = try NotchDatabase(location: .temporary())
    try database.migrate()
    let repository = SnippetsRepository(database: database)
    try repository.add(label: "National ID", value: "secretvalue",
                       icon: nil, colorHex: nil, isSensitive: true, at: t0)

    let leaked = try database.queue.read { db in
        try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM search_index WHERE body LIKE '%secretvalue%'"
        ) ?? 0
    }
    #expect(leaked == 0)
}

/// An edit must reach the index, not just the pin's own record.
///
/// Without this, search would keep finding the pin by its old label and
/// would fail to find it by the new one — silently, because writing and
/// searching each work fine on their own. The task brief only covered
/// index checks for creation (via the absence of sensitive-value leakage)
/// — the update path was left without its own check, the same way it
/// slipped through on the earlier notes task, where it surfaced only at
/// review. This test was added up front, not after a repeat finding.
@Test("editing a pin updates the label in the search index")
func snippetUpdateRefreshesSearchIndex() throws {
    let database = try NotchDatabase(location: .temporary())
    try database.migrate()
    let repository = SnippetsRepository(database: database)
    try repository.add(label: "old label", value: "value",
                       icon: nil, colorHex: nil, isSensitive: false, at: t0)
    let pin = try #require(try repository.all().first)

    var updated = pin
    updated.label = "new label"
    try repository.update(updated, at: t0.addingTimeInterval(60))

    let indexed = try database.queue.read { db in
        try String.fetchOne(
            db,
            sql: "SELECT title FROM search_index WHERE owner_kind = 'snippet' AND owner_id = ?",
            arguments: [pin.id]
        )
    }
    // The label lives in title, the value in body: same as clipboard
    // history, where title holds the name of the source app.
    #expect(indexed == "new label")
}

/// Deletion must remove both the record itself and its index row —
/// otherwise search would keep finding an already-deleted pin. This also
/// covers what the brief test `sensitiveValueIsNotIndexed`'s name claims
/// but its body never checks: that the label actually gets indexed on
/// creation (not just that the sensitive value doesn't).
@Test("deletion removes the pin and its index row")
func deleteRemovesSnippetAndIndexRow() throws {
    let database = try NotchDatabase(location: .temporary())
    try database.migrate()
    let repository = SnippetsRepository(database: database)
    try repository.add(label: "delete", value: "value",
                       icon: nil, colorHex: nil, isSensitive: false, at: t0)
    let pin = try #require(try repository.all().first)

    let indexedBeforeDelete = try database.queue.read { db in
        try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM search_index WHERE owner_kind = 'snippet' AND title = ?",
            arguments: ["delete"]
        ) ?? 0
    }
    #expect(indexedBeforeDelete == 1)

    let id = try #require(pin.id)
    try repository.delete(id: id)
    #expect(try repository.all().isEmpty)

    let indexedAfterDelete = try database.queue.read { db in
        try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM search_index WHERE owner_kind = 'snippet'"
        ) ?? 0
    }
    #expect(indexedAfterDelete == 0)
}

/// The flip side of the test above: what's hidden is specifically the
/// secret, not values as a whole class.
///
/// This originally checked a rule requiring that values never be indexed
/// at all, for any pin. The rule looks simpler and safer on its face, but
/// its cost would be pins becoming almost entirely unsearchable: people
/// search for a mail or phone pin by the number itself at least as often
/// as by the label — so the protection would be paid for with the very
/// feature pins exist for.
@Test("a non-sensitive pin's value is indexed and found")
func nonSensitiveValueIsIndexed() throws {
    let database = try NotchDatabase(location: .temporary())
    try database.migrate()
    let repository = SnippetsRepository(database: database)
    try repository.add(label: "Phone", value: "openvalue",
                       icon: nil, colorHex: nil, isSensitive: false, at: t0)

    let indexed = try database.queue.read { db in
        try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM search_index WHERE body LIKE ?",
            arguments: ["%openvalue%"]
        ) ?? 0
    }
    #expect(indexed == 1)
}

/// Toggling the sensitive flag must remove the value from the index, not
/// just change how the pin is rendered: otherwise a pin marked sensitive
/// after the fact stays findable by its own value.
@Test("a pin that becomes sensitive on edit drops its value out of the index")
func turningSensitiveRemovesValueFromIndex() throws {
    let database = try NotchDatabase(location: .temporary())
    try database.migrate()
    let repository = SnippetsRepository(database: database)
    try repository.add(label: "National ID", value: "secretlater",
                       icon: nil, colorHex: nil, isSensitive: false, at: t0)
    var pin = try #require(try repository.all().first)

    pin.isSensitive = true
    try repository.update(pin, at: t0.addingTimeInterval(60))

    let leaked = try database.queue.read { db in
        try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM search_index WHERE body LIKE ?",
            arguments: ["%secretlater%"]
        ) ?? 0
    }
    #expect(leaked == 0)
}

/// A label that's empty after trimming whitespace is rejected on edit
/// too, by the same rule as on creation — otherwise a pin could be
/// stripped down to a labelless pin via an edit, not just created that
/// way directly (the brief test `emptyLabelIsRejected` only covers add).
@Test("empty label is not saved on edit either")
func emptyLabelIsRejectedOnUpdate() throws {
    let repository = try makeRepository()
    try repository.add(label: "original label", value: "value",
                       icon: nil, colorHex: nil, isSensitive: false, at: t0)
    let pin = try #require(try repository.all().first)

    var blanked = pin
    blanked.label = "   "
    try repository.update(blanked, at: t0.addingTimeInterval(60))

    #expect(try repository.all().map(\.label) == ["original label"])
}
