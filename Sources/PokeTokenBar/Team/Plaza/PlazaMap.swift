import Foundation
import CoreGraphics

/// 광장 지도의 칸 좌표. y는 아래로 증가한다.
struct TilePoint: Hashable, Codable, Sendable {
    var x: Int
    var y: Int
}

/// 지도 한 칸의 종류. rawValue가 지도 문자열에서 쓰는 문자다.
enum PlazaTile: Character, Sendable {
    // 지나갈 수 있음
    case grass = ".", flowers = "f", shelter = "S", tallGrass = "g"
    // 지나갈 수 없음
    case tree = "T", bush = "b", board = "N"

    var isWalkable: Bool {
        switch self {
        case .grass, .flowers, .shelter, .tallGrass: true
        case .tree, .bush, .board: false
        }
    }
}

enum PlazaMapError: Error, Equatable {
    case empty
    case ragged(row: Int)
    case unknown(Character)
    case missingBoard
    case missingShelter
}

/// 광장 타일 지도. SpriteKit과 무관한 순수 모델이다.
struct PlazaMap: Sendable {
    /// 한 칸의 월드 픽셀 크기.
    static let tileSize = 32

    let width: Int
    let height: Int
    private let tiles: [[PlazaTile]]
    let shelterTiles: [TilePoint]
    let boardTile: TilePoint
    let spawn: TilePoint

    init(rows: [String]) throws(PlazaMapError) {
        guard let first = rows.first, !first.isEmpty else { throw .empty }
        let width = first.count
        var grid: [[PlazaTile]] = []
        for (y, row) in rows.enumerated() {
            guard row.count == width else { throw .ragged(row: y) }
            var line: [PlazaTile] = []
            for ch in row {
                guard let tile = PlazaTile(rawValue: ch) else { throw .unknown(ch) }
                line.append(tile)
            }
            grid.append(line)
        }
        var shelter: [TilePoint] = []
        var board: TilePoint?
        for (y, line) in grid.enumerated() {
            for (x, tile) in line.enumerated() {
                if tile == .shelter { shelter.append(TilePoint(x: x, y: y)) }
                if tile == .board, board == nil { board = TilePoint(x: x, y: y) }
            }
        }
        guard let board else { throw .missingBoard }
        guard !shelter.isEmpty else { throw .missingShelter }

        // 쉼터 칸들의 무게중심에 가장 가까운 칸. 동률이면 행 우선 첫 칸(min은 먼저 나온 것을 유지).
        let n = Double(shelter.count)
        let cx = Double(shelter.reduce(0) { $0 + $1.x }) / n
        let cy = Double(shelter.reduce(0) { $0 + $1.y }) / n
        var best = shelter[0]
        var bestDistance = Double.infinity
        for p in shelter {
            let d = (Double(p.x) - cx) * (Double(p.x) - cx) + (Double(p.y) - cy) * (Double(p.y) - cy)
            if d < bestDistance { best = p; bestDistance = d }
        }

        self.width = width
        self.height = grid.count
        self.tiles = grid
        self.shelterTiles = shelter
        self.boardTile = board
        self.spawn = best
    }

    /// 지도 밖은 나무로 본다.
    func tile(at p: TilePoint) -> PlazaTile {
        guard p.x >= 0, p.y >= 0, p.x < width, p.y < height else { return .tree }
        return tiles[p.y][p.x]
    }

    func isWalkable(_ p: TilePoint) -> Bool { tile(at: p).isWalkable }

    /// 월드 픽셀 크기.
    var pixelSize: CGSize {
        CGSize(width: width * Self.tileSize, height: height * Self.tileSize)
    }
}
