import CoreGraphics
import Foundation

/// The drawing side of `PlazaWeatherArt` (the dot grids are in `PlazaWeatherGrids.swift`).
extension PlazaWeatherArt {
    static let palette: [Character: (r: UInt8, g: UInt8, b: UInt8)] = [
        "W": (0xF6, 0xFA, 0xFF), "S": (0xC6, 0xDA, 0xF0),
        "P": (0xF8, 0xBB, 0xCF), "p": (0xE8, 0x8D, 0xAC),
        "O": (0xE8, 0x83, 0x2A), "o": (0xB4, 0x5E, 0x14),
        "R": (0xD1, 0x43, 0x2E), "r": (0x96, 0x2A, 0x1C),
        "Y": (0xF2, 0xC2, 0x30), "y": (0xC4, 0x96, 0x1A),
        // 초록 잎. 풀(밝은 초록) 위에서 보이게 풀보다 훨씬 밝은 연두 잎에 짙은 잎맥을 넣는다.
        "G": (0xE4, 0xF7, 0x8C), "g": (0x2E, 0x5E, 0x18),
        "H": (0xC4, 0xEC, 0x5E), "h": (0x24, 0x4C, 0x12),
    ]

    /// 격자 하나를 칸당 1픽셀 그림으로 만든다(화면은 최근접 보간으로 키운다).
    static func images(_ kind: PlazaWeather.Kind) -> [CGImage] { grids(kind).map { image($0, palette: palette) } }

    static func image(_ rows: [String], palette: [Character: (r: UInt8, g: UInt8, b: UInt8)]) -> CGImage {
        let w = rows[0].count, h = rows.count
        let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setShouldAntialias(false)
        for (row, line) in rows.enumerated() {
            for (col, ch) in line.enumerated() {
                guard let c = palette[ch] else { continue }
                context.setFillColor(CGColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1))
                context.fill(CGRect(x: col, y: h - 1 - row, width: 1, height: 1))
            }
        }
        return context.makeImage()!
    }
}
