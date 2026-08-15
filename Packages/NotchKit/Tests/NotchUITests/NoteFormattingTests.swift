import Testing
import Foundation
@testable import NotchUI

/// A calendar pinned to a fixed time zone, not `.current`.
///
/// "Yesterday" is a calendar concept, not "minus 24 hours": whether a
/// moment falls on the previous day depends on the machine's time zone.
/// With `.current` the test would pass here and fail for whoever runs it
/// further east or west, with no connection at all to the code it's
/// actually checking.
private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

/// 2027-01-15T08:00:00Z — the middle of the day in UTC, so the multi-hour
/// shifts in the tests below don't accidentally cross midnight.
private let now = Date(timeIntervalSince1970: 1_800_000_000)

@Test("today's note shows the time")
func todayShowsTime() {
    let text = NoteFormatting.relativeDate(now.addingTimeInterval(-3600), now: now, calendar: calendar)
    #expect(text.contains(":"))
}

@Test("yesterday's note is labeled with a word")
func yesterdayIsNamed() {
    let text = NoteFormatting.relativeDate(now.addingTimeInterval(-26 * 3600), now: now, calendar: calendar)
    #expect(text == "yesterday")
}

@Test("an older note shows a date without a time")
func olderShowsDate() {
    let text = NoteFormatting.relativeDate(now.addingTimeInterval(-10 * 24 * 3600), now: now, calendar: calendar)
    #expect(text.contains(":") == false)
}

@Test("a future date doesn't break formatting")
func futureIsSafe() {
    let text = NoteFormatting.relativeDate(now.addingTimeInterval(3600), now: now, calendar: calendar)
    #expect(text.isEmpty == false)
}
