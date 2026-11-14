// Verbatim copy of Sources/PokeTokenBar/Team/Plaza/PlazaSeasonSheet.swift before Track A Task 4 (base 98876aa), renamed. The oracle for
// PlazaArtParityTests; deleted in Task 19. Do not edit except to port a fix from main.
@testable import PokeTokenBar
import CoreGraphics
import Foundation

/// 봄과 가을의 시트. 눈 오는 날처럼 정확히 같은 색의 불투명 픽셀만 바꿔 칠한다. 여름은 원본 그대로다.
enum LegacyPlazaSeasonSheet {
    private static var treeCells: [(col: Int, row: Int)] {
        let tree = PlazaTileArt.treeCell
        return [(tree.col, tree.row), (tree.col + 1, tree.row), (tree.col, tree.row + 1), (tree.col + 1, tree.row + 1)]
    }

    private static let autumnGround: LegacyPlazaSnowSheet.Colors = [0x3ABE41: 0xC9B458, 0x6ADD4B: 0xE0CF78, 0x328E41: 0xA89040,
                                                               0x29973B: 0xA89040, 0x315740: 0x6E5A2E]

    /// plaza-tiles.png 에서 바꿔 칠할 조각. 여름은 없다. 겨울은 `LegacyPlazaSnowSheet.tilePieces`.
    static func tilePieces(_ season: PlazaSeason) -> [LegacyPlazaSnowSheet.Piece] {
        switch season {
        case .summer: []
        case .winter: LegacyPlazaSnowSheet.tilePieces
        case .spring: [
            ([0x2ECA5C: 0xF8BBCF, 0x50EB6C: 0xFDDCE6, 0x299750: 0xE88DAC, 0x328E53: 0xE88DAC], treeCells),
            ([0xE8F8D0: 0xFDDCE6, 0x60D0C0: 0xF2A0BC], PlazaTileArt.flowerCells),
        ]
        case .autumn: [
            (autumnGround, PlazaTileArt.grassCells),
            (autumnGround.merging([0x266433: 0x6E5A2E]) { $1 }, PlazaPond.shoreCells),
            ([0x328E41: 0xA89040, 0xE8F8D0: 0xF6E7B0, 0x60D0C0: 0xD98A2A], PlazaTileArt.flowerCells),
            ([0x2ECA35: 0xD9A72A, 0x62EB3D: 0xF2C230, 0x29973B: 0xB07A1A], [PlazaTileArt.bushCell]),
            ([0x2ECA5C: 0xE8832A, 0x50EB6C: 0xF2A63C, 0x299750: 0xC4521E, 0x328E53: 0xB4441A], treeCells),
            ([0x2ECA35: 0xD9A72A, 0x29973B: 0xB07A1A], [PlazaTileArt.signCell]),
        ]
        }
    }

    /// 풀숲 색. 봄과 여름은 원본 그대로라 비어 있다.
    static func tallGrassColors(_ season: PlazaSeason) -> LegacyPlazaSnowSheet.Colors {
        switch season {
        case .spring, .summer: [:]
        case .autumn: [0x99E550: 0xF2C230, 0x6ABE30: 0xD98A2A]
        case .winter: LegacyPlazaSnowSheet.tallGrassColors
        }
    }

    static func tiles(_ sheet: CGImage, season: PlazaSeason) -> CGImage {
        let pieces = tilePieces(season)
        return pieces.isEmpty ? sheet : LegacyPlazaSnowSheet.recolored(sheet, pieces: pieces)
    }

    static func tallGrass(_ sheet: CGImage, season: PlazaSeason) -> CGImage {
        let colors = tallGrassColors(season)
        guard !colors.isEmpty else { return sheet }
        let cells = (0..<(sheet.height / 16)).flatMap { row in (0..<(sheet.width / 16)).map { (col: $0, row: row) } }
        return LegacyPlazaSnowSheet.recolored(sheet, pieces: [(colors, cells)])
    }
}
