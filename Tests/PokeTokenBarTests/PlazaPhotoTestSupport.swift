import CoreGraphics
@testable import PokeTokenBar

extension PlazaPhotoRenderer {
    /// The photo as the CGImage the pixel assertions read (Mac backend).
    static func renderCG(_ input: PlazaPhotoInput) -> CGImage? { render(input)?.cgImage }
}
