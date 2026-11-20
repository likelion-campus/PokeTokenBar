import Foundation

/// 불꽃 조각 그림. 새로 그리지 않고 광장의 반짝임과 눈송이 그림에 색만 바꿔 입힌다. 색도 날씨와 말풍선에 이미 있는 색이다.
enum PlazaFireworkArt {
    private typealias RGB = (r: UInt8, g: UInt8, b: UInt8)
    /// 그림 한 칸의 월드 픽셀. 타일 그림의 점 크기와 같다.
    static let cell = 2
    private static let core: RGB = (0xF6, 0xFA, 0xFF)
    /// The same grid as `PlazaEmoteArt.spark` (that file moves to the shared set with the emote art; then this can
    /// point there). `PlazaArtParityTests` compares the glyph against the old code, which reads the emote's grid.
    private static let spark = [
        "..Y..",
        ".YWY.",
        "YWWWY",
        ".YWY.",
        "..Y..",
    ]

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

    /// 칸당 1픽셀 그림. 화면은 `cell`배로 키운다.
    static func image(_ glyph: PlazaFireworkGlyph) -> PlazaImage {
        let flakes = PlazaWeatherArt.grids(.snow), edge = edge(glyph.color), tail = tail(glyph.color)
        return switch glyph.shape {
        case .spark: PlazaWeatherArt.image(spark, palette: ["W": core, "Y": edge])
        case .plus: PlazaWeatherArt.image(flakes[0], palette: ["W": edge])
        case .dot: PlazaWeatherArt.image(flakes[1], palette: ["W": tail, "S": tail])
        case .ember(let n): PlazaWeatherArt.image(flakes[2], palette: ["W": [core, edge, tail][min(n, 2)]])
        }
    }
}
