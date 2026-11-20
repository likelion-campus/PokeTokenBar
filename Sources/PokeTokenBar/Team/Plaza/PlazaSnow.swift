import Foundation

/// 눈 오는 날 광장의 규칙. SpriteKit과 무관한 값 타입이다.
enum PlazaSnow {
    /// 발자국 하나: 걸음 방향으로 6, 가로질러 4 월드 픽셀.
    static let footprintLength: CGFloat = 6, footprintWidth: CGFloat = 4, footprintSide: CGFloat = 3
    static let footprintHex: UInt32 = 0x8DA3BF

    /// 월드 픽셀(y 아래로). 걸음 방향이 x면 `alongX`.
    struct Footprint: Equatable {
        let center: CGPoint
        let alongX: Bool
    }

    /// 풀, 꽃밭, 쉼터.
    static func isSnowGround(_ t: TilePoint, in map: PlazaMap) -> Bool {
        switch map.tile(at: t) {
        case .grass, .flowers, .shelter: true
        case .tallGrass, .tree, .bush, .board, .campfire, .pond: false
        }
    }

    /// 한 걸음에 두 개: 왼발은 4분의 1 지점, 오른발은 4분의 3 지점에서 길 옆 3픽셀(걷는 쪽의 왼쪽 = 월드 y 아래 기준 (dy, -dx)).
    /// 중심 아래 칸이 눈 땅인 것만 남긴다. `from`이나 `to`가 물이면 없다.
    static func footprints(from: TilePoint, to: TilePoint, map: PlazaMap) -> [Footprint] {
        guard !map.isWater(from), !map.isWater(to) else { return [] }
        let dx = CGFloat(to.x - from.x), dy = CGFloat(to.y - from.y)
        let a = PlazaWalker.footPoint(from: from, to: from, progress: 0)
        let b = PlazaWalker.footPoint(from: to, to: to, progress: 0)
        let alongX = dx != 0
        let size = CGFloat(PlazaMap.tileSize)
        return [(0.25, CGFloat(1)), (0.75, CGFloat(-1))].compactMap { t, side in
            let center = CGPoint(x: a.x + (b.x - a.x) * t + side * dy * footprintSide,
                                 y: a.y + (b.y - a.y) * t - side * dx * footprintSide)
            let tile = TilePoint(x: Int((center.x / size).rounded(.down)), y: Int((center.y / size).rounded(.down)))
            return isSnowGround(tile, in: map) ? Footprint(center: center, alongX: alongX) : nil
        }
    }

    /// 4.5초까지 1, 6.5초까지 0.66, 9초까지 0.33, 그 뒤는 nil.
    static func footprintAlpha(age: TimeInterval) -> CGFloat? {
        if age < 4.5 { return 1 }
        if age < 6.5 { return 0.66 }
        if age < 9 { return 0.33 }
        return nil
    }
}
