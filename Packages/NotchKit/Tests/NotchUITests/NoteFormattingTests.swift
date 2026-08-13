import Testing
import Foundation
@testable import NotchUI

/// Календарь с прибитым поясом, а не `.current`.
///
/// «Вчера» — календарное понятие, а не «минус 24 часа»: попадёт ли момент
/// на предыдущий день, зависит от пояса машины. С `.current` тест был бы
/// зелёным здесь и красным у того, кто запустит его восточнее или западнее,
/// причём без всякой связи с кодом, который он проверяет.
private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

/// 2027-01-15T08:00:00Z — середина суток по UTC, чтобы сдвиги на несколько
/// часов в тестах ниже не перескакивали через полночь случайно.
private let now = Date(timeIntervalSince1970: 1_800_000_000)

@Test("сегодняшняя заметка показывает время")
func todayShowsTime() {
    let text = NoteFormatting.relativeDate(now.addingTimeInterval(-3600), now: now, calendar: calendar)
    #expect(text.contains(":"))
}

@Test("вчерашняя подписана словом")
func yesterdayIsNamed() {
    let text = NoteFormatting.relativeDate(now.addingTimeInterval(-26 * 3600), now: now, calendar: calendar)
    #expect(text == "вчера")
}

@Test("старая показывает дату без времени")
func olderShowsDate() {
    let text = NoteFormatting.relativeDate(now.addingTimeInterval(-10 * 24 * 3600), now: now, calendar: calendar)
    #expect(text.contains(":") == false)
}

@Test("будущая дата не ломает форматирование")
func futureIsSafe() {
    let text = NoteFormatting.relativeDate(now.addingTimeInterval(3600), now: now, calendar: calendar)
    #expect(text.isEmpty == false)
}
