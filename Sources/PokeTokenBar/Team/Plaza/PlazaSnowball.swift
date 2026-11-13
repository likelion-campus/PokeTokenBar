import CoreGraphics
import Foundation

/// 던진 눈덩이 하나의 경로. 어디서 어느 쪽으로 날아 어디서 끝나는가만 담은 값 타입이다.
struct PlazaSnowballShot: Equatable {
    enum End: Equatable { case actor(id: String?, tile: TilePoint), ground(TilePoint) }   // id nil = me
    let from: TilePoint
    let direction: PlazaDirection
    let end: End

    var endTile: TilePoint {
        switch end {
        case .actor(_, let tile): tile
        case .ground(let tile): tile
        }
    }

    /// 한 칸에 한 프레임. `from`에서 `endTile`까지 맨해튼 거리를 1...maxFrames로 맞춘다.
    var frames: Int {
        let d = abs(endTile.x - from.x) + abs(endTile.y - from.y)
        return min(max(d, 1), PlazaSnowball.maxFrames)
    }
}

/// 눈덩이 규칙. SpriteKit과 무관하다.
enum PlazaSnowball {
    static let range = 10, reach = 11, maxFrames = 10, burstFrames = 4
    static let frameDuration: TimeInterval = 0.1
    static let handHeight: CGFloat = 14, peak: CGFloat = 16, maxBodyHeight: CGFloat = 24
    static let handReach: CGFloat = 16      // the ball starts this far ahead of the thrower's feet
    static let bodyInset: CGFloat = 8       // a hit ends this far short of the target's feet
    static let cell: CGFloat = 4            // world px per grid cell
    static let shadowSize = CGSize(width: 16, height: 8)

    /// 걸을 수도 물도 아닌 칸: 나무·덤불·게시판·모닥불·지도 밖.
    static func blocksBall(_ t: TilePoint, in map: PlazaMap) -> Bool {
        !map.isWalkable(t) && !map.isWater(t)
    }

    /// 앞쪽 1...range칸. 막는 칸 앞에서 멈춘다. 대상이 있는 첫 칸이 맞는 곳(같은 칸이면 작은 ID)이고,
    /// 없으면 마지막 열린 칸이 땅 끝이다. 바로 앞 칸이 막혀 있으면 nil.
    static func aim(from: TilePoint, facing: PlazaDirection, targets: [String: TilePoint], map: PlazaMap) -> PlazaSnowballShot? {
        var tile = from
        var last: TilePoint?
        for _ in 1...range {
            tile = PlazaWalker.offset(tile, facing)
            if blocksBall(tile, in: map) { break }
            if let id = targets.filter({ $0.value == tile }).keys.min() {
                return PlazaSnowballShot(from: from, direction: facing, end: .actor(id: id, tile: tile))
            }
            last = tile
        }
        guard let last else { return nil }
        return PlazaSnowballShot(from: from, direction: facing, end: .ground(last))
    }

    /// 받는 쪽 확인: 같은 행이나 열, 대상이 던진 쪽 `direction`에 있고, 거리 1...reach.
    static func hits(thrower: TilePoint, target: TilePoint, direction: PlazaDirection) -> Bool {
        let dx = target.x - thrower.x, dy = target.y - thrower.y
        let along: Int, across: Int
        switch direction {
        case .right: (along, across) = (dx, dy)
        case .left: (along, across) = (-dx, dy)
        case .down: (along, across) = (dy, dx)
        case .up: (along, across) = (-dy, dx)
        }
        return across == 0 && (1...reach).contains(along)
    }

    /// handHeight + (endHeight - handHeight)·u + 4·peak·u·(1 - u).
    static func height(at u: CGFloat, endHeight: CGFloat) -> CGFloat {
        handHeight + (endHeight - handHeight) * u + 4 * peak * u * (1 - u)
    }

    /// min(max(spriteHeight, 28)·0.5, maxBodyHeight).
    static func bodyHeight(spriteHeight: CGFloat) -> CGFloat {
        min(max(spriteHeight, 28) * 0.5, maxBodyHeight)
    }

    /// 터짐 `step` 프레임의 조각들(중심 기준, 장면 픽셀, y 위쪽). glyph는 `PlazaSnowballArt.pieces` 색인.
    static func burstPieces(step: Int, onGround: Bool) -> [(offset: CGVector, glyph: Int)] {
        let radius: [CGFloat] = [18, 22, 28, 32], drop: [CGFloat] = [0, 2, 8, 16], glyph = [1, 0, 1, 2]
        let angles: [Double] = step == 0 ? (onGround ? [0, 45, 135, 180] : [45, 135, 225, 315])
                                         : (onGround ? [0, 45, 90, 135, 180] : [30, 90, 150, 210, 270, 330])
        var pieces: [(offset: CGVector, glyph: Int)] = []
        if step == 0 { pieces.append((CGVector(dx: 0, dy: 0), 0)) }
        for a in angles {
            let rad = a * .pi / 180
            let dx = radius[step] * CGFloat(cos(rad))
            var dy = radius[step] * CGFloat(sin(rad)) - drop[step]
            if onGround { dy = max(dy, 0) }
            pieces.append((CGVector(dx: dx, dy: dy), glyph[step]))
        }
        return pieces
    }
}

/// 눈덩이·터짐 그림. 눈 입자 격자에 그림자 한 칸을 계산으로 덧붙인다.
enum PlazaSnowballArt {
    private static let palette: [Character: (r: UInt8, g: UInt8, b: UInt8)] = [
        "W": (0xF6, 0xFA, 0xFF), "S": (0xC6, 0xDA, 0xF0), "o": (0x8D, 0xA3, 0xBF),
    ]

    /// 왼쪽이나 위쪽 이웃이 칠해진 빈 칸마다 그림자("o") 한 칸을 더한다. 격자는 오른쪽·아래로 한 칸씩 커진다.
    static func shaded(_ grid: [String]) -> [String] {
        let h = grid.count, w = grid.map(\.count).max() ?? 0
        let cells = grid.map { Array($0) }
        func painted(_ x: Int, _ y: Int) -> Bool {
            y >= 0 && y < h && x >= 0 && x < cells[y].count && cells[y][x] != "."
        }
        return (0...h).map { y in
            String((0...w).map { x in
                if painted(x, y) { return cells[y][x] }
                return painted(x - 1, y) || painted(x, y - 1) ? "o" : "."
            })
        }
    }

    /// `PlazaWeatherArt.grids(.snow)`의 눈송이 셋을 그림자와 함께 그린다. [0]이 공이다.
    static func pieces() -> [CGImage] {
        PlazaWeatherArt.grids(.snow).map { PlazaWeatherArt.image(shaded($0), palette: palette) }
    }
}
