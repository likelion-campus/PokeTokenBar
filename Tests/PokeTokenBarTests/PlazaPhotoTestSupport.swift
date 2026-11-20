import Foundation
@testable import PokeTokenBar

extension PlazaPhotoRenderer {
    /// The photo as the shared pixels the assertions read (premultiplied sRGB RGBA8, row 0 at the top), on both OSes.
    static func renderBitmap(_ input: PlazaPhotoInput) -> PlazaBitmap? { render(input)?.pixels }
}

/// A bundled plaza file through the platform's own graphics (ImageIO on the Mac, WIC on Windows), as the app reads it.
enum BundledArt {
    static func image(_ name: String, ext: String = "png") -> PlazaImage? {
        PlatformPlaza.graphics.assetURL(name, ext: ext).flatMap { PlatformPlaza.graphics.decodeImage(at: $0) }
    }
}
