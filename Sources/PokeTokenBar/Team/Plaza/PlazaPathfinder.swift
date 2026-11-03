import Foundation

/// 목록에서 고른 팀원에게 걸어갈 길. 지도의 못 가는 칸과 `blocked`(다른 팀원이 선 칸)를 피한다.
enum PlazaPathfinder {
    static func isAdjacent(_ a: TilePoint, _ b: TilePoint) -> Bool {
        abs(a.x - b.x) + abs(a.y - b.y) == 1
    }

    /// `a`에서 `b`를 바라보는 방향. 바로 옆 칸일 때 쓴다.
    static func direction(from a: TilePoint, to b: TilePoint) -> PlazaDirection {
        if b.x > a.x { return .right }
        if b.x < a.x { return .left }
        return b.y > a.y ? .down : .up
    }

    /// `target` 바로 옆 칸에서 끝나는 가장 짧은 길. 이미 옆이면 빈 길, 갈 수 없으면 nil.
    static func path(from start: TilePoint, toNextTo target: TilePoint, map: PlazaMap,
                     blocked: Set<TilePoint> = []) -> [PlazaDirection]? {
        if isAdjacent(start, target) { return [] }
        var previous: [TilePoint: (TilePoint, PlazaDirection)] = [:]
        var seen: Set<TilePoint> = [start]
        var queue = [start], head = 0
        while head < queue.count {
            let p = queue[head]
            head += 1
            for d in [PlazaDirection.up, .down, .left, .right] {
                let n = PlazaWalker.offset(p, d)
                guard map.isWalkable(n), !blocked.contains(n), seen.insert(n).inserted else { continue }
                previous[n] = (p, d)
                if isAdjacent(n, target) && n != target {
                    var steps: [PlazaDirection] = []
                    var at = n
                    while let (from, step) = previous[at] { steps.append(step); at = from }
                    return steps.reversed()
                }
                queue.append(n)
            }
        }
        return nil
    }
}
