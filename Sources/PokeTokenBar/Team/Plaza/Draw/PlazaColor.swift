import Foundation

/// A plaza colour: sRGB components with straight (not premultiplied) alpha. Equality is componentwise, which is what
/// `CGColor` equality amounted to before (every plaza colour was sRGB). The Mac turns it into a `CGColor` /
/// `SKColor` with the same components (`MacPlazaColor.swift`).
struct PlazaColor: Hashable, Sendable {
    var red: Double, green: Double, blue: Double, alpha: Double

    init(srgbRed: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = srgbRed
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// `0xRRGGBB`; each byte divided by 255. Bits above the low 24 are ignored.
    init(hex: UInt32, alpha: Double = 1) {
        self.init(srgbRed: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, alpha: alpha)
    }

    static let clear = PlazaColor(srgbRed: 0, green: 0, blue: 0, alpha: 0)
    static let white = PlazaColor(srgbRed: 1, green: 1, blue: 1)
    static let black = PlazaColor(srgbRed: 0, green: 0, blue: 0)
}
