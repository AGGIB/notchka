import Testing
import CoreGraphics
@testable import NotchUI

/// Одноцветная картинка 8×8 заданного цвета.
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

@Test("тусклый цвет поднимается до читаемого на чёрном")
func dimColourIsBrightened() {
    let corrected = ArtworkAccent.readable((h: 0.6, s: 0.5, b: 0.05))
    #expect(corrected.b >= ArtworkAccent.minBrightness)
}

@Test("блёклый цвет получает насыщенность, иначе сольётся с серым")
func washedColourGainsSaturation() {
    let corrected = ArtworkAccent.readable((h: 0.1, s: 0.02, b: 0.8))
    #expect(corrected.s >= ArtworkAccent.minSaturation)
}

@Test("уже читаемый цвет не искажается")
func readableColourIsLeftAlone() {
    let input = (h: 0.9, s: 0.7, b: 0.8)
    let corrected = ArtworkAccent.readable(input)
    #expect(abs(corrected.h - input.h) < 0.0001)
    #expect(abs(corrected.s - input.s) < 0.0001)
    #expect(abs(corrected.b - input.b) < 0.0001)
}

@Test("оттенок сохраняется при коррекции — цвет остаётся «тем же»")
func hueSurvivesCorrection() {
    let corrected = ArtworkAccent.readable((h: 0.33, s: 0.01, b: 0.02))
    #expect(abs(corrected.h - 0.33) < 0.0001)
}

@Test("из одноцветной обложки извлекается цвет")
func solidArtworkYieldsColour() {
    #expect(ArtworkAccent.color(from: solidImage(red: 0.9, green: 0.2, blue: 0.5)) != nil)
}

@Test("чёрная обложка тоже даёт читаемый цвет, а не чёрный на чёрном")
func blackArtworkStillReadable() throws {
    let colour = try #require(ArtworkAccent.hsb(from: solidImage(red: 0, green: 0, blue: 0)))
    let corrected = ArtworkAccent.readable(colour)
    #expect(corrected.b >= ArtworkAccent.minBrightness)
}
