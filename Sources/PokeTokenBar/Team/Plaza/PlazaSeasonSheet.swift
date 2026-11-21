import Foundation

/// 봄과 가을의 시트. 눈 오는 날처럼 정확히 같은 색의 불투명 픽셀만 바꿔 칠한다. 여름은 원본 그대로다.
enum PlazaSeasonSheet {
    private static var treeCells: [(col: Int, row: Int)] {
        let tree = PlazaTileArt.treeCell
        return [(tree.col, tree.row), (tree.col + 1, tree.row), (tree.col, tree.row + 1), (tree.col + 1, tree.row + 1)]
    }

    /// 가을: 땅과 연잎은 올리브빛으로 바랜다.
    private static let autumnGround: PlazaSnowSheet.Colors = [0x3ABE41: 0x8E9A44, 0x6ADD4B: 0xA8B052, 0x328E41: 0x6E7634,
                                                               0x29973B: 0x6E7634, 0x315740: 0x4A4626]

    /// 가을 나무의 세 가지 물듦. 위치마다 `PlazaTileArt.treeVariant` 가 하나를 고른다: 단풍(빨강), 주황, 은행(노랑).
    private static let autumnTrees: [PlazaSnowSheet.Colors] = [
        [0x2ECA5C: 0xC8402A, 0x50EB6C: 0xE86A3A, 0x299750: 0x8E2A1C, 0x328E53: 0x7A2418, 0x2B7D4A: 0x6A2016, 0x2D5B43: 0x4E1A12],
        [0x2ECA5C: 0xE07A2A, 0x50EB6C: 0xF2A03C, 0x299750: 0xA8501A, 0x328E53: 0x96441A, 0x2B7D4A: 0x7E3A16, 0x2D5B43: 0x5A2A10],
        [0x2ECA5C: 0xD9A72A, 0x50EB6C: 0xF2C840, 0x299750: 0xA0741A, 0x328E53: 0x8C6418, 0x2B7D4A: 0x74521A, 0x2D5B43: 0x523A12],
    ]

    /// 나무 한 그루가 시트에서 차지하는 영역(2×2 칸, 시트 픽셀).
    private static let treeRect = PlazaPixelRect(x: PlazaTileArt.treeCell.col * 16, y: PlazaTileArt.treeCell.row * 16, width: 32, height: 32)

    /// 나무를 따로 칠하는 계절의 색 목록. 봄·겨울·여름은 시트의 나무 칸을 그대로(또는 `tilePieces` 로) 쓰므로 비어 있다.
    static func treeColors(_ season: PlazaSeason) -> [PlazaSnowSheet.Colors] {
        season == .autumn ? autumnTrees : []
    }

    /// 계절의 나무 그림들(32×32). 없으면 nil이고 지도는 시트의 나무 칸을 쓴다.
    static func trees(_ sheet: PlazaImage, season: PlazaSeason) -> [PlazaImage]? {
        let colors = treeColors(season)
        guard !colors.isEmpty, let crop = sheet.cropping(to: treeRect) else { return nil }
        let cells = [(col: 0, row: 0), (col: 1, row: 0), (col: 0, row: 1), (col: 1, row: 1)]
        return colors.map { PlazaSnowSheet.recolored(crop, pieces: [($0, cells)]) }
    }

    /// plaza-tiles.png 에서 바꿔 칠할 조각. 여름은 없다. 겨울은 `PlazaSnowSheet.tilePieces` 에 온천 둑의 돌을 더한 것(`PlazaSnowSheet` 는 옛 구현과 바이트까지 같게 고정이라 여기서 더한다).
    /// 봄과 여름의 돌은 땅처럼 여름 초록 그대로다. 가을 나무는 `trees` 로 따로 그린다.
    static func tilePieces(_ season: PlazaSeason) -> [PlazaSnowSheet.Piece] {
        switch season {
        case .summer: []
        case .winter: PlazaSnowSheet.tilePieces + [(PlazaHotSpring.winterStoneColors, PlazaHotSpring.bankStoneCells)]
        case .spring: [
            ([0x2ECA5C: 0xF8BBCF, 0x50EB6C: 0xFDDCE6, 0x299750: 0xE88DAC, 0x328E53: 0xE88DAC], treeCells),
            ([0xE8F8D0: 0xFDDCE6, 0x60D0C0: 0xF2A0BC], PlazaTileArt.flowerCells),
        ]
        case .autumn: [
            (autumnGround, PlazaTileArt.grassCells + PlazaTileArt.lilyCells),
            (autumnGround.merging([0x266433: 0x4A4626]) { $1 }, PlazaPond.shoreCells),
            ([0x328E41: 0x6E7634, 0xE8F8D0: 0xF6E7B0, 0x60D0C0: 0xD98A2A], PlazaTileArt.flowerCells),
            ([0x2ECA35: 0xB4462A, 0x62EB3D: 0xD86A34, 0x29973B: 0x7E3020, 0x2D5B3F: 0x4E1A12], [PlazaTileArt.bushCell]),
            ([0x2ECA35: 0xB4462A, 0x29973B: 0x7E3020], [PlazaTileArt.signCell]),
            (PlazaHotSpring.autumnStoneColors, PlazaHotSpring.bankStoneCells),
        ]
        }
    }

    /// 풀숲 색. 봄과 여름은 원본 그대로라 비어 있다.
    static func tallGrassColors(_ season: PlazaSeason) -> PlazaSnowSheet.Colors {
        switch season {
        case .spring, .summer: [:]
        case .autumn: [0x99E550: 0xC8A050, 0x6ABE30: 0x9A6A2C, 0x4B692F: 0x5E4220]
        case .winter: PlazaSnowSheet.tallGrassColors
        }
    }

    static func tiles(_ sheet: PlazaImage, season: PlazaSeason) -> PlazaImage {
        let pieces = tilePieces(season)
        return pieces.isEmpty ? sheet : PlazaSnowSheet.recolored(sheet, pieces: pieces)
    }

    static func tallGrass(_ sheet: PlazaImage, season: PlazaSeason) -> PlazaImage {
        let colors = tallGrassColors(season)
        guard !colors.isEmpty else { return sheet }
        let cells = (0..<(sheet.height / 16)).flatMap { row in (0..<(sheet.width / 16)).map { (col: $0, row: row) } }
        return PlazaSnowSheet.recolored(sheet, pieces: [(colors, cells)])
    }

    /// 계절의 지도와 풀숲 그림 한 벌. 컨트롤러와 렌더 장면이 같은 조립을 쓴다.
    static func look(_ map: PlazaMap, sheet: PlazaImage, tallGrassSheet: PlazaImage?, season: PlazaSeason) -> PlazaSnowLook {
        let art = tallGrassSheet.map { tallGrass($0, season: season) }.flatMap(PlazaTallGrassArt.init(sheet:))
        return PlazaSnowLook(mapImage: PlazaTileArt.mapImage(map, sheet: tiles(sheet, season: season), tallGrass: art,
                                                             trees: trees(sheet, season: season)), tallGrass: art)
    }
}
