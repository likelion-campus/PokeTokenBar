import CoreGraphics

/// The drawing side of `PlazaNameColor` (the hex palette and the hashing are in `PlazaNameColor.swift`).
extension PlazaNameColor {
    static let palette: [CGColor] = hexes.map { (hex: UInt32) -> CGColor in
        let r = CGFloat((hex >> 16) & 0xFF) / 255
        let g = CGFloat((hex >> 8) & 0xFF) / 255
        let b = CGFloat(hex & 0xFF) / 255
        return CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    static func color(forMemberID id: String) -> CGColor { palette[index(forMemberID: id)] }

    static func color(forMemberID id: String, chosen: UInt32?) -> CGColor {
        // `hex` always returns one of `hexes`.
        palette[hexes.firstIndex(of: hex(forMemberID: id, chosen: chosen))!]
    }
}
