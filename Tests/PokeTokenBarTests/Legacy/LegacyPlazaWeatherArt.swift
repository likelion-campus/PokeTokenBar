// Verbatim copy of the pre-Task-4 (base 98876aa) code named below, renamed. The oracle for PlazaArtParityTests;
// deleted in Task 19. Do not edit except to port a fix from main.
// Source: PlazaWeatherArt.swift (palette, images, image), PlazaFireworkLayer.swift (PlazaFireworkArt.image),
// PlazaSnowball.swift (PlazaSnowballArt.pieces).
import CoreGraphics
import Foundation
@testable import PokeTokenBar

enum LegacyPlazaWeatherArt {
    private static let palette: [Character: (r: UInt8, g: UInt8, b: UInt8)] = [
        "W": (0xF6, 0xFA, 0xFF), "S": (0xC6, 0xDA, 0xF0),
        "P": (0xF8, 0xBB, 0xCF), "p": (0xE8, 0x8D, 0xAC),
        "O": (0xE8, 0x83, 0x2A), "o": (0xB4, 0x5E, 0x14),
        "R": (0xD1, 0x43, 0x2E), "r": (0x96, 0x2A, 0x1C),
        "Y": (0xF2, 0xC2, 0x30), "y": (0xC4, 0x96, 0x1A),
        "G": (0xE4, 0xF7, 0x8C), "g": (0x2E, 0x5E, 0x18),
        "H": (0xC4, 0xEC, 0x5E), "h": (0x24, 0x4C, 0x12),
    ]

    static func images(_ kind: PlazaWeather.Kind) -> [CGImage] { PlazaWeatherArt.grids(kind).map { image($0, palette: palette) } }

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

enum LegacyPlazaFireworkArt {
    private typealias RGB = (r: UInt8, g: UInt8, b: UInt8)
    private static let core: RGB = (0xF6, 0xFA, 0xFF)

    private static func edge(_ color: PlazaFireworkColor) -> RGB {
        switch color {
        case .gold: (0xF2, 0xC2, 0x30)
        case .red: (0xD1, 0x43, 0x2E)
        case .blue: (0x3B, 0x82, 0xF6)
        case .pink: (0xE8, 0x8D, 0xAC)
        case .mint: (0x2F, 0xB8, 0xA6)
        }
    }

    private static func tail(_ color: PlazaFireworkColor) -> RGB {
        switch color {
        case .gold: (0xE8, 0x83, 0x2A)
        case .red: (0x96, 0x2A, 0x1C)
        case .blue: (0x9C, 0xC0, 0xEE)
        case .pink: (0xF8, 0xBB, 0xCF)
        case .mint: (0xB9, 0xF2, 0xE4)
        }
    }

    static func image(_ glyph: PlazaFireworkGlyph) -> CGImage {
        let flakes = PlazaWeatherArt.grids(.snow), edge = edge(glyph.color), tail = tail(glyph.color)
        return switch glyph.shape {
        case .spark: LegacyPlazaWeatherArt.image(PlazaEmoteArt.spark, palette: ["W": core, "Y": edge])
        case .plus: LegacyPlazaWeatherArt.image(flakes[0], palette: ["W": edge])
        case .dot: LegacyPlazaWeatherArt.image(flakes[1], palette: ["W": tail, "S": tail])
        case .ember(let n): LegacyPlazaWeatherArt.image(flakes[2], palette: ["W": [core, edge, tail][min(n, 2)]])
        }
    }
}

enum LegacyPlazaSnowballArt {
    typealias Piece = (image: CGImage, scale: CGFloat)

    static func pieces(_ season: PlazaSeason = .winter, balloon: CGImage? = nil) -> [Piece] {
        var pieces: [Piece] = PlazaWeatherArt.grids(.snow).map {
            (LegacyPlazaWeatherArt.image(PlazaSnowballArt.shaded($0), palette: PlazaSnowballArt.palette(season)), PlazaSnowball.cell)
        }
        if season == .summer, let balloon { pieces[0] = (balloon, 1) }
        return pieces
    }
}
