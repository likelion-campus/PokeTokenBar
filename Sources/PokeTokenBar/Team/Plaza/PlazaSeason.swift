import CoreGraphics
import Foundation

/// 광장의 계절. 지도 색, 내리는 것, 연못이 어는지를 정한다.
enum PlazaSeason: String, CaseIterable, Sendable {
    case spring, summer, autumn, winter

    /// 달력의 계절: 3~5월 봄, 6~8월 여름, 9~11월 가을, 12~2월 겨울.
    static func calendar(on date: Date, calendar: Calendar = PlazaWeather.gregorian) -> PlazaSeason {
        switch calendar.component(.month, from: date) {
        case 3...5: .spring
        case 6...8: .summer
        case 9...11: .autumn
        default: .winter
        }
    }

    var weather: PlazaWeather.Kind {
        switch self {
        case .spring: .petals
        case .summer: .greenLeaves
        case .autumn: .leaves
        case .winter: .snow
        }
    }
}

/// 팀이 고른 계절. `auto`는 달력을 따른다. 원시값이 팀 설정의 와이어 값(`PlazaSchedule.seasonPeriod`)이다.
enum PlazaSeasonChoice: String, CaseIterable, Sendable {
    case auto, spring, summer, autumn, winter

    /// 모르는 값은 겨울이다. v2.5.632 이하가 쓰던 "day"·"week"·"month"도 여기로 와서 그때처럼 눈이 온다.
    init(wire: String) { self = Self(rawValue: wire) ?? .winter }

    func season(on date: Date, calendar: Calendar = PlazaWeather.gregorian) -> PlazaSeason {
        switch self {
        case .auto: PlazaSeason.calendar(on: date, calendar: calendar)
        case .spring: .spring
        case .summer: .summer
        case .autumn: .autumn
        case .winter: .winter
        }
    }
}

/// 봄과 가을의 시트. 눈 오는 날처럼 정확히 같은 색의 불투명 픽셀만 바꿔 칠한다. 여름은 원본 그대로다.
enum PlazaSeasonSheet {
    private static var treeCells: [(col: Int, row: Int)] {
        let tree = PlazaTileArt.treeCell
        return [(tree.col, tree.row), (tree.col + 1, tree.row), (tree.col, tree.row + 1), (tree.col + 1, tree.row + 1)]
    }

    private static let autumnGround: PlazaSnowSheet.Colors = [0x3ABE41: 0xC9B458, 0x6ADD4B: 0xE0CF78, 0x328E41: 0xA89040,
                                                               0x29973B: 0xA89040, 0x315740: 0x6E5A2E]

    /// plaza-tiles.png 에서 바꿔 칠할 조각. 여름은 없다. 겨울은 `PlazaSnowSheet.tilePieces`.
    static func tilePieces(_ season: PlazaSeason) -> [PlazaSnowSheet.Piece] {
        switch season {
        case .summer: []
        case .winter: PlazaSnowSheet.tilePieces
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
    static func tallGrassColors(_ season: PlazaSeason) -> PlazaSnowSheet.Colors {
        switch season {
        case .spring, .summer: [:]
        case .autumn: [0x99E550: 0xF2C230, 0x6ABE30: 0xD98A2A]
        case .winter: PlazaSnowSheet.tallGrassColors
        }
    }

    static func tiles(_ sheet: CGImage, season: PlazaSeason) -> CGImage {
        let pieces = tilePieces(season)
        return pieces.isEmpty ? sheet : PlazaSnowSheet.recolored(sheet, pieces: pieces)
    }

    static func tallGrass(_ sheet: CGImage, season: PlazaSeason) -> CGImage {
        let colors = tallGrassColors(season)
        guard !colors.isEmpty else { return sheet }
        let cells = (0..<(sheet.height / 16)).flatMap { row in (0..<(sheet.width / 16)).map { (col: $0, row: row) } }
        return PlazaSnowSheet.recolored(sheet, pieces: [(colors, cells)])
    }
}
