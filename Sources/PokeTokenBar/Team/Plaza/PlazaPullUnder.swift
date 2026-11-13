import Foundation

/// 물귀신: 물속(헤엄치거나 잠수)에서 C를 누르면 바라보는 쪽 세 칸 안의 물가 팀원, 없으면 바로 옆 물가 팀원을 물로 끌어들인다.
/// 끄는 쪽은 잠수 중이면 떠오르고, 자기 칸으로 끌어들일 때는 한 칸 물러나 자리를 내준다.
/// 끌려가는 쪽 Mac이 그 물 칸까지 스스로 미끄러져 빠진다(몸통박치기와 같다).
enum PlazaPullUnder {
    /// 끌어들일 수 있는 가장 먼 거리(칸).
    static let reach = 3

    /// 끌려가는 팀원이 `direction` 쪽으로 `tiles`칸 미끄러져 물 칸 `landing`에 빠진다.
    /// 그 칸이 끄는 쪽의 칸이면 끄는 쪽은 `stepsBack`으로 한 칸 물러난다.
    struct Pull: Equatable {
        let direction: PlazaDirection
        let tiles: Int
        let landing: TilePoint
        let stepsBack: Bool
    }

    private static func opposite(_ d: PlazaDirection) -> PlazaDirection {
        switch d {
        case .up: .down
        case .down: .up
        case .left: .right
        case .right: .left
        }
    }

    private static func offset(_ t: TilePoint, _ d: PlazaDirection, _ n: Int) -> TilePoint {
        (0..<n).reduce(t) { tile, _ in PlazaWalker.offset(tile, d) }
    }

    /// 물속의 `me`가 끌어들일 팀원. 바라보는 줄에서 1~3칸 안의 첫 땅 위 팀원을 먼저 보고, 그가 안 되면 바로 옆 땅 위 팀원을 `otherSides` 순서로 본다.
    /// 팀원에서 나 쪽으로 첫 물 칸까지 모두 갈 수 있는 땅이고 비어 있어야 하며, 그 물 칸은 비어 있거나(그 팀원보다 앞) 내 칸이고 내 뒤 물 칸이 비어 있어야 한다.
    static func target(me: TilePoint, facing: PlazaDirection, members: [String: TilePoint], isWater: (TilePoint) -> Bool,
                       isWalkable: (TilePoint) -> Bool, isFree: (TilePoint) -> Bool) -> (id: String, pull: Pull)? {
        guard isWater(me) else { return nil }

        func pull(toward d: PlazaDirection, within n: Int) -> (id: String, pull: Pull)? {
            let back = opposite(d)   // 팀원에서 나를 향하는 방향
            for k in 1...n {
                let tile = offset(me, d, k)
                guard !isWater(tile), let id = PlazaTargeting.member(on: tile, members: members) else { continue }
                for j in 1...k {
                    let step = offset(tile, back, j)
                    if isWater(step) {
                        let behind = offset(me, back, 1)
                        let mine = step == me
                        guard mine ? isWater(behind) && isFree(behind) : isFree(step) else { return nil }
                        return (id, Pull(direction: back, tiles: j, landing: step, stepsBack: mine))
                    }
                    // isFree is unreachable here (a nearer member would itself be the target); kept for symmetry with `drag`
                    guard isWalkable(step), isFree(step) else { return nil }
                }
                return nil   // 나 쪽에 물이 없다: me가 물이라 여기 오지 않는다
            }
            return nil
        }

        if let hit = pull(toward: facing, within: reach) { return hit }
        for d in PlazaTargeting.otherSides(facing) {
            if let hit = pull(toward: d, within: 1) { return hit }
        }
        return nil
    }

    /// 땅에 선 `victim`이 끌려갈 방향과 칸 수. 끄는 쪽 `puller`가 물속에서 같은 줄 4칸 안에 있고(물러난 한 칸을 포함한다),
    /// 그쪽으로 첫 물 칸까지가 모두 갈 수 있는 땅이며 그 물 칸이 3칸 안이고 `puller`보다 가까울 때만 받는다. 그 밖의 자리에서 온 것은 무시한다.
    static func drag(victim: TilePoint, puller: TilePoint, isWater: (TilePoint) -> Bool,
                     isWalkable: (TilePoint) -> Bool) -> (direction: PlazaDirection, tiles: Int)? {
        guard !isWater(victim), isWater(puller) else { return nil }
        let dx = puller.x - victim.x, dy = puller.y - victim.y
        let distance = abs(dx) + abs(dy)
        guard (dx == 0) != (dy == 0), distance <= reach + 1 else { return nil }
        let d = PlazaPathfinder.direction(from: victim, to: puller)
        for k in 1...distance {
            let tile = offset(victim, d, k)
            if isWater(tile) { return k <= reach ? (d, k) : nil }
            guard isWalkable(tile) else { return nil }
        }
        return nil   // puller가 물이라 거기서 끝난다: 여기 오지 않는다
    }
}
