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

    /// 터짐 `step` 프레임의 조각들(중심 기준, 장면 픽셀, y 위쪽). glyph는 `PlazaSnowballArt.Art.burst` 색인(공 그림은 들어 있지 않다).
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

/// 던지는 것과 터짐 그림. 공은 계절마다 번들 파일 그림이고, 파일이 없으면 눈 입자 격자에 그림자 한 칸을 덧붙인 공이다.
/// 터짐 조각은 겨울 눈 알갱이, 봄 꽃잎, 여름 물방울 색 알갱이, 가을 낙엽이다.
enum PlazaSnowballArt {
    typealias Palette = [Character: (r: UInt8, g: UInt8, b: UInt8)]
    /// 그림과, 그림 한 픽셀의 월드 픽셀 수.
    typealias Piece = (image: PlazaImage, scale: CGFloat)

    /// 밝은 칸("W"), 어두운 칸("S"), 그림자("o").
    static func palette(_ season: PlazaSeason) -> Palette {
        switch season {
        case .winter: ["W": (0xF6, 0xFA, 0xFF), "S": (0xC6, 0xDA, 0xF0), "o": (0x8D, 0xA3, 0xBF)]
        case .spring: ["W": (0xFD, 0xDC, 0xE6), "S": (0xF2, 0xA0, 0xBC), "o": (0xB8, 0x5A, 0x80)]
        case .summer: ["W": (0xD6, 0xF0, 0xFF), "S": (0x6C, 0xB8, 0xF0), "o": (0x2E, 0x78, 0xC0)]
        case .autumn: ["W": (0xF2, 0xA6, 0x3C), "S": (0xC4, 0x52, 0x1E), "o": (0x6E, 0x3A, 0x10)]
        }
    }

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

    /// 던지는 공 하나와 터질 때 흩어지는 조각 셋. 둘은 따로다: 터짐 조각이 공 그림을 그릴 수 없다.
    struct Art {
        let ball: Piece
        /// 항상 셋. `PlazaSnowball.burstPieces`의 glyph가 이 목록의 색인이다.
        let burst: [Piece]
    }

    /// 그림 한 픽셀의 월드 픽셀 수. 파일 그림은 높이 12~20 월드 픽셀로 날도록 10픽셀 이하면 2배다.
    static func ballScale(_ image: PlazaImage) -> CGFloat { image.height <= 10 ? 2 : 1 }

    /// `ball`(그 계절의 파일 그림)이 있으면 공은 그 그림 그대로, 없으면 그 계절 색의 눈 격자 공이다.
    /// 터짐 조각: 겨울·여름은 눈 격자 셋(그림자 포함, 그 계절 색), 봄은 꽃잎, 가을은 낙엽.
    static func art(_ season: PlazaSeason = .winter, ball: PlazaImage? = nil) -> Art {
        let snow = PlazaWeatherArt.grids(.snow).map {
            (image: PlazaWeatherArt.image(shaded($0), palette: palette(season)), scale: PlazaSnowball.cell)
        }
        let burst: [Piece]
        switch season {
        case .winter, .summer: burst = snow
        case .spring:
            let p = PlazaWeatherArt.images(.petals)
            burst = [p[0], p[1], p[0]].map { ($0, PlazaSnowball.cell) }
        case .autumn:
            let l = PlazaWeatherArt.images(.leaves)
            burst = [l[0], l[2], l[4]].map { ($0, PlazaSnowball.cell) }
        }
        return Art(ball: ball.map { ($0, ballScale($0)) } ?? snow[0], burst: burst)
    }
}
