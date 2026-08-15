import Testing
import CoreGraphics
@testable import NotchUI

/// A solid-color 8×8 image of a given color.
private func solidImage(red: Double, green: Double, blue: Double) -> CGImage {
    let width = 8, height = 8
    let space = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

@Test("a dim color is brightened to readable on black")
func dimColourIsBrightened() {
    let corrected = ArtworkAccent.readable((h: 0.6, s: 0.5, b: 0.05))
    #expect(corrected.b >= ArtworkAccent.minBrightness)
}

@Test("a washed-out color gains saturation, otherwise it blends into gray")
func washedColourGainsSaturation() {
    let corrected = ArtworkAccent.readable((h: 0.1, s: 0.02, b: 0.8))
    #expect(corrected.s >= ArtworkAccent.minSaturation)
}

@Test("an already readable color is left unchanged")
func readableColourIsLeftAlone() {
    let input = (h: 0.9, s: 0.7, b: 0.8)
    let corrected = ArtworkAccent.readable(input)
    #expect(abs(corrected.h - input.h) < 0.0001)
    #expect(abs(corrected.s - input.s) < 0.0001)
    #expect(abs(corrected.b - input.b) < 0.0001)
}

@Test("hue is preserved during correction — the color stays \"the same\"")
func hueSurvivesCorrection() {
    let corrected = ArtworkAccent.readable((h: 0.33, s: 0.01, b: 0.02))
    #expect(abs(corrected.h - 0.33) < 0.0001)
}

@Test("a color is extracted from solid-color artwork")
func solidArtworkYieldsColour() {
    #expect(ArtworkAccent.color(from: solidImage(red: 0.9, green: 0.2, blue: 0.5)) != nil)
}

@Test("black artwork also yields a readable color, not black-on-black")
func blackArtworkStillReadable() throws {
    let colour = try #require(ArtworkAccent.hsb(from: solidImage(red: 0, green: 0, blue: 0)))
    let corrected = ArtworkAccent.readable(colour)
    #expect(corrected.b >= ArtworkAccent.minBrightness)
}
