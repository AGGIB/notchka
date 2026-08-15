import Testing
import SwiftUI
import NotchCore
@testable import NotchUI

@Test("opening and expanding use a bouncy spring")
func openingUsesSpring() {
    let opening = NotchMotion.animation(for: .peek(.hover), reduceMotion: false)
    #expect(opening == .spring(response: 0.34, dampingFraction: 0.68))

    let expanding = NotchMotion.animation(for: .expanded(.music), reduceMotion: false)
    #expect(expanding == .spring(response: 0.34, dampingFraction: 0.68))
}

@Test("closing is faster than opening")
func closingIsSnappy() {
    #expect(NotchMotion.animation(for: .closed, reduceMotion: false)
            == .snappy(duration: 0.26))
}

@Test("reduce motion replaces the spring with a linear ease")
func reduceMotionReplacesSpring() {
    let reduced = NotchMotion.animation(for: .expanded(.music), reduceMotion: true)
    #expect(reduced == .easeInOut(duration: 0.18))
    #expect(NotchMotion.usesMorph(reduceMotion: true) == false)
    #expect(NotchMotion.usesMorph(reduceMotion: false) == true)
}
