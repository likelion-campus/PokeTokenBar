import Foundation

/// 오른쪽 연못: 온천. 이 파일은 SpriteKit 없이 쓰는 규칙만 둔다(`PlazaPond`·`PlazaDrag`처럼).
enum PlazaHotSpring {
    /// 온천 칸을 행 우선 순서로. 온천 없는 지도는 [].
    static func tiles(in map: PlazaMap) -> [TilePoint] {
        var out: [TilePoint] = []
        for y in 0..<map.height {
            for x in 0..<map.width where map.tile(at: TilePoint(x: x, y: y)) == .hotSpring { out.append(TilePoint(x: x, y: y)) }
        }
        return out
    }
}
