import Foundation

/// 물귀신: 잠수한 채 C를 누르면 떠오르면서 바로 옆 물가에 선 팀원을 물로 끌어들인다. 끄는 쪽은 한 칸 물러나 자리를 내주고,
/// 끌려가는 쪽 Mac이 그 빈 물 칸으로 스스로 빠진다(몸통박치기와 같다).
enum PlazaPullUnder {
    /// `diver` 바로 옆 땅 칸에 서 있고, 그 반대쪽 물 칸이 비어 `diver`가 물러날 수 있는 팀원과 그 자리.
    static func targets(diver: TilePoint, members: [String: TilePoint], isWater: (TilePoint) -> Bool,
                        isFree: (TilePoint) -> Bool) -> [String: TilePoint] {
        guard isWater(diver) else { return [:] }
        return members.filter { _, tile in
            guard !isWater(tile), PlazaPathfinder.isAdjacent(diver, tile) else { return false }
            let back = PlazaWalker.offset(diver, PlazaPathfinder.direction(from: tile, to: diver))
            return isWater(back) && isFree(back)
        }
    }

    /// 땅에 선 `victim`이 끌려갈 방향: 그쪽 바로 옆이 물이고, `puller`가 그 물 칸이나 한 칸 더 뒤의 물 칸에 있다.
    /// 끄는 쪽이 물러났다는 소식은 끌어당긴다는 소식보다 늦게 올 수 있어 둘 다 받는다. 그 밖의 자리에서 온 것은 무시한다.
    static func drag(victim: TilePoint, puller: TilePoint, isWater: (TilePoint) -> Bool) -> PlazaDirection? {
        guard !isWater(victim), isWater(puller) else { return nil }
        return PlazaDirection.allCases.first { d in
            let near = PlazaWalker.offset(victim, d)
            return isWater(near) && (puller == near || puller == PlazaWalker.offset(near, d))
        }
    }
}
