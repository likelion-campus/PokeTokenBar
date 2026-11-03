import CoreGraphics

/// 이름 색. 고르지 않았으면 멤버 ID로만 정해지므로 기기가 달라도 같은 색이고, 고르면 이 팔레트의 한 색이다.
enum PlazaNameColor {
    /// 고를 수 있는 색. 잔디와 판 위에서 모두 읽히는 밝은 색만 둔다.
    static let hexes: [UInt32] = [
        0xFFFFFF, 0xFFE14D, 0x7FD4FF, 0xFF9ECF, 0xFFB054, 0xC9A6FF,
        0x8FF0C8, 0xFF8A80, 0xB6F24D, 0x6FE8E8, 0xF2D6A2, 0xA8C8FF,
    ]

    static let palette: [CGColor] = hexes.map { (hex: UInt32) -> CGColor in
        let r = CGFloat((hex >> 16) & 0xFF) / 255
        let g = CGFloat((hex >> 8) & 0xFF) / 255
        let b = CGFloat(hex & 0xFF) / 255
        return CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    /// UTF-8 바이트의 32비트 FNV-1a. `hashValue`는 실행마다 달라 쓰지 않는다.
    static func fnv1a(_ id: String) -> UInt32 {
        var hash: UInt32 = 2166136261
        for byte in id.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16777619
        }
        return hash
    }

    /// `fnv1a`를 팔레트 크기로 나눈 나머지.
    static func index(forMemberID id: String) -> Int {
        Int(fnv1a(id) % UInt32(palette.count))
    }

    static func color(forMemberID id: String) -> CGColor { palette[index(forMemberID: id)] }

    /// 고른 색이 팔레트에 있으면 그 색, 아니면(안 골랐거나 모르는 값) 멤버 ID의 색. 받은 값은 여기서만 거른다.
    static func hex(forMemberID id: String, chosen: UInt32?) -> UInt32 {
        if let chosen, hexes.contains(chosen) { return chosen }
        return hexes[index(forMemberID: id)]
    }

    static func color(forMemberID id: String, chosen: UInt32?) -> CGColor {
        // `hex` always returns one of `hexes`.
        palette[hexes.firstIndex(of: hex(forMemberID: id, chosen: chosen))!]
    }
}
