import Testing
@testable import NotchUI

@Test("text wider than the available space needs scrolling")
func widerTextNeedsScroll() {
    #expect(MarqueeMetrics.shouldScroll(textWidth: 200, availableWidth: 150))
}

@Test("text narrower than the available space needs no scrolling")
func narrowerTextStaysStill() {
    #expect(!MarqueeMetrics.shouldScroll(textWidth: 100, availableWidth: 150))
}

@Test("text that fits exactly does not scroll")
func exactFitDoesNotScroll() {
    #expect(!MarqueeMetrics.shouldScroll(textWidth: 150, availableWidth: 150))
}

@Test("text a fraction of a point wider than the space still requires scrolling")
func fractionOverflowStillScrolls() {
    #expect(MarqueeMetrics.shouldScroll(textWidth: 150.5, availableWidth: 150))
}

@Test("pass duration equals distance divided by speed")
func passDurationDividesDistanceBySpeed() {
    #expect(MarqueeMetrics.passDuration(width: 120, speed: 30) == 4.0)
    #expect(MarqueeMetrics.passDuration(width: 90, speed: 30) == 3.0)
    #expect(MarqueeMetrics.passDuration(width: 60, speed: 20) == 3.0)
}

@Test("doubling the distance at the same speed doubles the pass duration")
func doublingWidthDoublesDuration() {
    let base = MarqueeMetrics.passDuration(width: 100, speed: 25)
    let doubled = MarqueeMetrics.passDuration(width: 200, speed: 25)
    #expect(doubled == base * 2)
}

@Test("a higher speed shortens the pass at the same width")
func fasterSpeedShortensPass() {
    let slow = MarqueeMetrics.passDuration(width: 200, speed: 20)
    let fast = MarqueeMetrics.passDuration(width: 200, speed: 40)
    #expect(fast == slow / 2)
}

@Test("zero or negative width yields no pass duration")
func nonPositiveWidthGivesNoDuration() {
    #expect(MarqueeMetrics.passDuration(width: 0, speed: 30) == 0)
    #expect(MarqueeMetrics.passDuration(width: -10, speed: 30) == 0)
}

@Test("zero or negative speed avoids division by zero")
func nonPositiveSpeedGivesNoDuration() {
    #expect(MarqueeMetrics.passDuration(width: 100, speed: 0) == 0)
    #expect(MarqueeMetrics.passDuration(width: 100, speed: -5) == 0)
}
