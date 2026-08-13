import SwiftUI
import CoreGraphics

/// Акцентный цвет, вытянутый из обложки.
///
/// Панель чёрная, поэтому «средний цвет картинки» не годится: тёмная или
/// блёклая обложка дала бы акцент, неотличимый от фона. Оттенок берётся из
/// обложки, а яркость и насыщенность зажимаются в диапазон, где цвет
/// гарантированно виден на чёрном.
public enum ArtworkAccent {
    public static let minBrightness: Double = 0.55
    public static let minSaturation: Double = 0.35

    public static func color(from image: CGImage) -> Color? {
        guard let hsb = hsb(from: image) else { return nil }
        let corrected = readable(hsb)
        return Color(hue: corrected.h, saturation: corrected.s, brightness: corrected.b)
    }

    /// Средний цвет картинки в HSB. Усреднение отрисовкой в 1×1 — самый
    /// дешёвый способ; точности «на глаз» для акцента достаточно.
    ///
    /// Создание контекста, отрисовка и чтение буфера обязаны идти внутри
    /// одного `withUnsafeMutableBytes` — указатель, который context хранит и
    /// пишет через него при `draw`, валиден только на время этого closure.
    /// `&pixel`, переданный отдельным выражением в `CGContext(data:...)`
    /// (как было раньше), валиден лишь на длительность самого вызова
    /// инициализатора: компилятор вправе передать туда указатель на
    /// временную копию буфера массива, а не на его настоящий storage, и то,
    /// что на практике буфер не переезжает, — везение, а не гарантия.
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

    /// Поднимает яркость и насыщенность до порогов читаемости, не трогая оттенок.
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
