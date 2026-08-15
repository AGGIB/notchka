import Testing
import Foundation
@testable import NotchUI

@Test("seconds format as minutes and seconds")
func timeFormatsAsMinutesSeconds() {
    #expect(TrackFormatting.time(0) == "0:00")
    #expect(TrackFormatting.time(9) == "0:09")
    #expect(TrackFormatting.time(62) == "1:02")
    #expect(TrackFormatting.time(216) == "3:36")
}

@Test("an hour or more is shown with hours")
func longTracksShowHours() {
    #expect(TrackFormatting.time(3600) == "1:00:00")
    #expect(TrackFormatting.time(7279) == "2:01:19")
}

@Test("degenerate time values don't break formatting")
func degenerateTimesAreSafe() {
    #expect(TrackFormatting.time(-5) == "0:00")
    #expect(TrackFormatting.time(.nan) == "0:00")
    #expect(TrackFormatting.time(.infinity) == "0:00")
}

@Test("progress fraction stays within bounds")
func progressIsClamped() {
    #expect(TrackFormatting.progress(position: 50, duration: 100) == 0.5)
    #expect(TrackFormatting.progress(position: 150, duration: 100) == 1)
    #expect(TrackFormatting.progress(position: -10, duration: 100) == 0)
}

@Test("a track without a duration gives zero progress, not division by zero")
func zeroDurationGivesZeroProgress() {
    #expect(TrackFormatting.progress(position: 42, duration: 0) == 0)
}
