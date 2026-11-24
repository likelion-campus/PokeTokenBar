import Foundation

/// The ring under a character that is in a running minigame, and the colours the minimap rings its dot with.
/// A plain dot ellipse in world pixels, like the ground shadow it lies on: no new picture.
enum PlazaGameMarkArt {
    static let aliveColor = PlazaColor(hex: 0xF2C14E)
    static let holderColor = PlazaColor(hex: 0xE8402A)
    static let outColor = PlazaColor(hex: 0x8C8F99)

    private static func rgba(_ mark: PlazaGameMark) -> PlazaRGBA {
        switch mark {
        case .alive: PlazaRGBA(r: 0xF2, g: 0xC1, b: 0x4E, a: 255)
        case .holder: PlazaRGBA(r: 0xE8, g: 0x40, b: 0x2A, a: 255)
        case .out: PlazaRGBA(r: 0x8C, g: 0x8F, b: 0x99, a: 255)
        }
    }
    private static let edge = PlazaRGBA(r: 0x14, g: 0x16, b: 0x1F, a: 255)
    /// The coloured band and the dark line outside it, in world pixels.
    static let band = 2, line = 1

    /// The ring for a ground shadow of `shadow` world pixels: this much wider and taller, so it shows around the feet.
    static func size(forShadow shadow: CGSize) -> (width: Int, height: Int) {
        (Int(shadow.width.rounded()) + 12, Int(shadow.height.rounded()) + 8)
    }

    /// A hollow ellipse: a dark line outside, the mark's colour inside it, nothing in the middle.
    static func image(width: Int, height: Int, mark: PlazaGameMark) -> PlazaImage {
        var bitmap = PlazaBitmap(width: width, height: height)
        let hw = Double(width) / 2, hh = Double(height) / 2
        func inside(_ x: Int, _ y: Int, inset: Int) -> Bool {
            let a = hw - Double(inset), b = hh - Double(inset)
            guard a > 0, b > 0 else { return false }
            let nx = (Double(x) + 0.5 - hw) / a, ny = (Double(y) + 0.5 - hh) / b
            return nx * nx + ny * ny < 1
        }
        let colour = rgba(mark)
        for y in 0..<height {
            for x in 0..<width where inside(x, y, inset: 0) && !inside(x, y, inset: line + band) {
                bitmap[x, y] = inside(x, y, inset: line) ? colour : edge
            }
        }
        return PlazaImage(bitmap: bitmap)
    }
}
