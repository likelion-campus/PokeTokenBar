import CoreGraphics
import SpriteKit

extension PlazaColor {
    /// The same components in sRGB, as the plaza's `CGColor(srgbRed:...)` literals were.
    var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }

    /// `SKColor(srgbRed:)`; equal to `SKColor(red:)` component for component (`SpriteKitSemanticsTests`).
    var skColor: SKColor { SKColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
}
