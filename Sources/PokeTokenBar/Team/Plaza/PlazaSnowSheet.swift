import Foundation

/// 눈 오는 날의 시트. 실행 중에 정확히 같은 색의 불투명 픽셀만 바꿔 칠하고, 모양·알파·나머지 픽셀은 그대로 둔다.
/// 번들 PNG는 바뀌지 않는다.
enum PlazaSnowSheet {
    typealias Colors = [UInt32: UInt32]
    typealias Piece = (colors: Colors, cells: [(col: Int, row: Int)])

    static let groundColors: Colors = [0x3ABE41: 0xC6DAF0, 0x6ADD4B: 0xE8F0FA, 0x328E41: 0xB2C7E0,
                                       0x29973B: 0x9FC3E6, 0x315740: 0x8DA3BF]
    static let shoreColors: Colors = groundColors.merging([0x266433: 0x8DA3BF]) { $1 }
    static let flowerColors: Colors = [0xE8F8D0: 0xF6FAFF, 0x328E41: 0xC6DAF0, 0x60D0C0: 0x9FC3E6]
    static let bushColors: Colors = [0x2ECA35: 0xE8F0FA, 0x62EB3D: 0xF6FAFF, 0x29973B: 0xB2C7E0]
    static let treeColors: Colors = [0x2ECA5C: 0xE8F0FA, 0x50EB6C: 0xF6FAFF, 0x299750: 0xC6DAF0, 0x328E53: 0xC6DAF0]
    static let signColors: Colors = [0x2ECA35: 0xE8F0FA, 0x29973B: 0xB2C7E0]
    static let tallGrassColors: Colors = [0x99E550: 0xF6FAFF, 0x6ABE30: 0xC6DAF0]

    private static let cell = 16

    /// plaza-tiles.png 에서 눈색으로 바꿀 조각. 물·연잎 칸은 없다.
    static var tilePieces: [Piece] {
        let tree = PlazaTileArt.treeCell
        let treeCells = [(tree.col, tree.row), (tree.col + 1, tree.row),
                         (tree.col, tree.row + 1), (tree.col + 1, tree.row + 1)]
        return [
            (groundColors, PlazaTileArt.grassCells),
            (shoreColors, PlazaPond.shoreCells),
            (flowerColors, PlazaTileArt.flowerCells),
            (bushColors, [PlazaTileArt.bushCell]),
            (treeColors, treeCells),
            (signColors, [PlazaTileArt.signCell])
        ]
    }

    static func tiles(_ sheet: PlazaImage) -> PlazaImage { recolored(sheet, pieces: tilePieces) }

    static func tallGrass(_ sheet: PlazaImage) -> PlazaImage {
        let cells = (0..<(sheet.height / cell)).flatMap { row in (0..<(sheet.width / cell)).map { (col: $0, row: row) } }
        return recolored(sheet, pieces: [(tallGrassColors, cells)])
    }

    static func recolored(_ sheet: PlazaImage, pieces: [Piece]) -> PlazaImage {
        let (w, h) = (sheet.width, sheet.height)
        var data = sheet.pixels.bytes
        let source = data
        for piece in pieces {
            for c in piece.cells {
                for y in max(0, c.row * cell)..<min(h, (c.row + 1) * cell) {
                    for x in max(0, c.col * cell)..<min(w, (c.col + 1) * cell) {
                        let i = (y * w + x) * 4
                        guard source[i + 3] == 255 else { continue }
                        let key = (UInt32(source[i]) << 16) | (UInt32(source[i + 1]) << 8) | UInt32(source[i + 2])
                        guard let to = piece.colors[key] else { continue }
                        data[i] = UInt8(to >> 16 & 0xFF)
                        data[i + 1] = UInt8(to >> 8 & 0xFF)
                        data[i + 2] = UInt8(to & 0xFF)
                    }
                }
            }
        }
        var bitmap = PlazaBitmap(width: w, height: h)
        bitmap.bytes = data
        return PlazaImage(bitmap: bitmap)
    }
}

/// 눈 오는 날의 지도 그림과 풀숲 그림.
struct PlazaSnowLook {
    let mapImage: PlazaImage
    let tallGrass: PlazaTallGrassArt?
}
