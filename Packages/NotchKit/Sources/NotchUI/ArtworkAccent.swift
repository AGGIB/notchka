import SwiftUI
import CoreGraphics

/// Accent color extracted from the artwork.
///
/// The panel is black, so a plain "average color of the image" approach
/// won't work: a dark or washed-out cover would produce an accent
/// indistinguishable from the background. Hue is taken from the artwork,
/// while brightness and saturation are clamped to a range that's
/// guaranteed to be visible on black.
public enum ArtworkAccent {
    public static let minBrightness: Double = 0.55
    public static let minSaturation: Double = 0.35

    public static func color(from image: CGImage) -> Color? {
        guard let hsb = hsb(from: image) else { return nil }
        let corrected = readable(hsb)
        return Color(hue: corrected.h, saturation: corrected.s, brightness: corrected.b)
    }

    /// Average color of the image in HSB. Averaging by rendering into a 1×1
    /// context is the cheapest approach; "good enough by eye" precision is
    /// all an accent color needs.
    ///
    /// Context creation, drawing, and reading the buffer must all happen
    /// inside a single `withUnsafeMutableBytes` — the pointer the context
    /// stores and writes through during `draw` is only valid for the
    /// duration of that closure. `&pixel` passed as a separate expression to
    /// `CGContext(data:...)` (as it was before) is only valid for the
    /// duration of the initializer call itself: the compiler is free to pass
    /// a pointer to a temporary copy of the array's buffer rather than its
    /// actual storage, and the fact that in practice the buffer doesn't
    /// move is luck, not a guarantee.
    public static func hsb(from image: CGImage) -> (h: Double, s: Double, b: Double)? {
        var pixel = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpaceCreateDeviceRGB()
        return pixel.withUnsafeMutableBytes { buffer -> (h: Double, s: Double, b: Double)? in
            guard let baseAddress = buffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                    bytesPerRow: 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return nil }

            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return rgbToHSB(
                r: Double(buffer[0]) / 255,
                g: Double(buffer[1]) / 255,
                b: Double(buffer[2]) / 255
            )
        }
    }

    /// Raises brightness and saturation to the readability thresholds without touching the hue.
    public static func readable(
        _ hsb: (h: Double, s: Double, b: Double)
    ) -> (h: Double, s: Double, b: Double) {
        (h: hsb.h, s: max(hsb.s, minSaturation), b: max(hsb.b, minBrightness))
    }

    private static func rgbToHSB(r: Double, g: Double, b: Double) -> (h: Double, s: Double, b: Double) {
        let maxValue = max(r, g, b)
        let minValue = min(r, g, b)
        let delta = maxValue - minValue

        var hue: Double = 0
        if delta > 0 {
            switch maxValue {
            case r: hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            case g: hue = (b - r) / delta + 2
            default: hue = (r - g) / delta + 4
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        let saturation = maxValue > 0 ? delta / maxValue : 0
        return (h: hue, s: saturation, b: maxValue)
    }
}
