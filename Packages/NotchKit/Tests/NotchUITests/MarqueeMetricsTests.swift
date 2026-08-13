import Testing
@testable import NotchUI

@Test("текст шире доступного места — нужна прокрутка")
func widerTextNeedsScroll() {
    #expect(MarqueeMetrics.shouldScroll(textWidth: 200, availableWidth: 150))
}

@Test("текст уже доступного места — прокрутка не нужна")
func narrowerTextStaysStill() {
    #expect(!MarqueeMetrics.shouldScroll(textWidth: 100, availableWidth: 150))
}

@Test("текст, который влезает ровно впритык, не прокручивается")
func exactFitDoesNotScroll() {
    #expect(!MarqueeMetrics.shouldScroll(textWidth: 150, availableWidth: 150))
}

@Test("текст на долю точки шире места уже требует прокрутки")
func fractionOverflowStillScrolls() {
    #expect(MarqueeMetrics.shouldScroll(textWidth: 150.5, availableWidth: 150))
}

@Test("проход длится дистанцию, делённую на скорость")
func passDurationDividesDistanceBySpeed() {
    #expect(MarqueeMetrics.passDuration(width: 120, speed: 30) == 4.0)
    #expect(MarqueeMetrics.passDuration(width: 90, speed: 30) == 3.0)
    #expect(MarqueeMetrics.passDuration(width: 60, speed: 20) == 3.0)
}

@Test("вдвое большая дистанция при той же скорости — вдвое дольше проход")
func doublingWidthDoublesDuration() {
    let base = MarqueeMetrics.passDuration(width: 100, speed: 25)
    let doubled = MarqueeMetrics.passDuration(width: 200, speed: 25)
    #expect(doubled == base * 2)
}

@Test("более высокая скорость сокращает проход при той же ширине")
func fasterSpeedShortensPass() {
    let slow = MarqueeMetrics.passDuration(width: 200, speed: 20)
    let fast = MarqueeMetrics.passDuration(width: 200, speed: 40)
    #expect(fast == slow / 2)
}

@Test("нулевая или отрицательная ширина не даёт прохода")
func nonPositiveWidthGivesNoDuration() {
    #expect(MarqueeMetrics.passDuration(width: 0, speed: 30) == 0)
    #expect(MarqueeMetrics.passDuration(width: -10, speed: 30) == 0)
}

@Test("нулевая или отрицательная скорость не даёт деления на ноль")
func nonPositiveSpeedGivesNoDuration() {
    #expect(MarqueeMetrics.passDuration(width: 100, speed: 0) == 0)
    #expect(MarqueeMetrics.passDuration(width: 100, speed: -5) == 0)
}
