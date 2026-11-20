import Foundation

/// The drawing side of `PlazaNameColor` (the hex palette and the hashing are in `PlazaNameColor.swift`).
extension PlazaNameColor {
    static let palette: [PlazaColor] = hexes.map { PlazaColor(hex: $0) }

    static func color(forMemberID id: String) -> PlazaColor { palette[index(forMemberID: id)] }

    static func color(forMemberID id: String, chosen: UInt32?) -> PlazaColor {
        // `hex` always returns one of `hexes`.
        palette[hexes.firstIndex(of: hex(forMemberID: id, chosen: chosen))!]
    }
}
