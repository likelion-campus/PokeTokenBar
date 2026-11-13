import Foundation
import CoreGraphics

/// 마지막으로 깨진 연못: 그 연못의 기준 칸과 깨진 차례. 점프 이모트와 프레즌스에 실려 간다.
struct PlazaIceBreak: Codable, Equatable, Sendable {
    var pond: TilePoint
    var turn: Int
}

/// 언 연못 규칙. SpriteKit과 무관하다.
enum PlazaIce {
    struct Pond: Equatable, Sendable {
        /// 행 우선 첫 칸.
        let anchor: TilePoint
        /// 행 우선.
        let tiles: [TilePoint]
        let minX: Int, minY: Int, maxX: Int, maxY: Int
        private let members: Set<TilePoint>

        init(tiles: [TilePoint]) {
            let sorted = tiles.sorted { ($0.y, $0.x) < ($1.y, $1.x) }
            self.tiles = sorted
            self.anchor = sorted[0]
            self.minX = sorted.map(\.x).min()!
            self.maxX = sorted.map(\.x).max()!
            self.minY = sorted[0].y
            self.maxY = sorted[sorted.count - 1].y
            self.members = Set(sorted)
        }

        func contains(_ t: TilePoint) -> Bool { members.contains(t) }

        /// 상하좌우 이웃이 모두 연못인 칸(행 우선).
        var inner: [TilePoint] {
            tiles.filter { t in
                PlazaDirection.allCases.allSatisfy { contains(PlazaWalker.offset(t, $0)) }
            }
        }

        /// 무게중심에 가장 가까운 칸. 동점은 행 우선.
        var center: TilePoint {
            let n = Double(tiles.count)
            let cx = Double(tiles.reduce(0) { $0 + $1.x }) / n
            let cy = Double(tiles.reduce(0) { $0 + $1.y }) / n
            var best = tiles[0]
            var bestDistance = Double.infinity
            for t in tiles {
                let d = (Double(t.x) - cx) * (Double(t.x) - cx) + (Double(t.y) - cy) * (Double(t.y) - cy)
                if d < bestDistance { best = t; bestDistance = d }
            }
            return best
        }

        /// 안이면 그 칸, 밖이면 가장 가까운(유클리드) 칸. 동점은 행 우선.
        func nearestTile(to t: TilePoint) -> TilePoint {
            if contains(t) { return t }
            var best = tiles[0]
            var bestDistance = Int.max
            for q in tiles {
                let d = PlazaIce.squaredDistance(q, t)
                if d < bestDistance { best = q; bestDistance = d }
            }
            return best
        }
    }

    static let turnLength: TimeInterval = 180
    static let freezeFade: TimeInterval = 1
    static let crackStep: TimeInterval = 0.055, crackSpan: TimeInterval = 0.33
    static let shardStart: TimeInterval = 0.26, shardStagger: TimeInterval = 0.04, shardFrameLength: TimeInterval = 0.07
    static let shardBursts = 6, shardFrames = 3
    static let fadeStart: TimeInterval = 0.5, fadeEnd: TimeInterval = 0.65
    static let sinkAt: TimeInterval = 0.6
    /// shardStart + 5·shardStagger + 3·shardFrameLength
    static let breakEnd: TimeInterval = 0.67

    static func turn(at date: Date) -> Int {
        Int((date.timeIntervalSince1970 / turnLength).rounded(.down))
    }

    /// 연못 칸의 상하좌우 연결 묶음, 기준 칸(행 우선) 순서. 물 없는 지도는 [].
    static func ponds(in map: PlazaMap) -> [Pond] {
        var seen = Set<TilePoint>()
        var result: [Pond] = []
        for y in 0..<map.height {
            for x in 0..<map.width {
                let start = TilePoint(x: x, y: y)
                guard map.isWater(start), !seen.contains(start) else { continue }
                var group = [start]
                seen.insert(start)
                var head = 0
                while head < group.count {
                    let q = group[head]
                    head += 1
                    for d in PlazaDirection.allCases {
                        let n = PlazaWalker.offset(q, d)
                        if map.isWater(n), seen.insert(n).inserted { group.append(n) }
                    }
                }
                result.append(Pond(tiles: group))
            }
        }
        return result
    }

    /// b.turn <= turn + 1 이고 b.pond 가 연못 기준 칸 중 하나일 때만 b.
    static func accepted(_ b: PlazaIceBreak?, turn: Int, ponds: [Pond]) -> PlazaIceBreak? {
        guard let b, ponds.contains(where: { $0.anchor == b.pond }) else { return nil }
        let limit = turn == Int.max ? Int.max : turn + 1
        return b.turn <= limit ? b : nil
    }

    /// (차례, 연못 순서)가 더 큰 쪽. nil 은 진다. 같으면 a.
    static func merged(_ a: PlazaIceBreak?, _ b: PlazaIceBreak?, ponds: [Pond]) -> PlazaIceBreak? {
        guard let a else { return b }
        guard let b else { return a }
        func index(_ x: PlazaIceBreak) -> Int { ponds.firstIndex { $0.anchor == x.pond } ?? -1 }
        if b.turn != a.turn { return b.turn > a.turn ? b : a }
        return index(b) > index(a) ? b : a
    }

    /// 연못 없음: nil. last 가 nil(또는 모르는 기준 칸): 0. turn <= last.turn: nil. 아니면 last 다음 연못(끝이면 처음).
    static func frozenIndex(last: PlazaIceBreak?, turn: Int, ponds: [Pond]) -> Int? {
        guard !ponds.isEmpty else { return nil }
        guard let last, let i = ponds.firstIndex(where: { $0.anchor == last.pond }) else { return 0 }
        guard turn > last.turn else { return nil }
        return (i + 1) % ponds.count
    }

    /// last 가 nil 이면 1. 아니면 clamp((now − (last.turn + 1)·180) / freezeFade, 0, 1). Double 로 계산해 넘치지 않는다.
    static func freezeAlpha(now: Date, last: PlazaIceBreak?) -> CGFloat {
        guard let last else { return 1 }
        let boundary = (Double(last.turn) + 1) * turnLength
        return CGFloat(min(max((now.timeIntervalSince1970 - boundary) / freezeFade, 0), 1))
    }

    static func ring(of t: TilePoint, hit: TilePoint) -> Int {
        Int(hypot(Double(t.x - hit.x), Double(t.y - hit.y)))
    }

    static func crackStep(maxRing: Int) -> TimeInterval {
        maxRing > 0 ? min(crackStep, crackSpan / Double(maxRing)) : crackStep
    }

    static func iceAlpha(elapsed: TimeInterval) -> CGFloat {
        if elapsed < fadeStart { return 1 }
        if elapsed >= fadeEnd { return 0 }
        return CGFloat(1 - (elapsed - fadeStart) / (fadeEnd - fadeStart))
    }

    static func shardFrame(burst: Int, elapsed: TimeInterval) -> Int? {
        let s = elapsed - shardStart - Double(burst) * shardStagger
        guard s >= 0 else { return nil }
        let f = Int(s / shardFrameLength)
        return f < shardFrames ? f : nil
    }

    /// [hit] + 5칸. 후보는 안쪽 칸(5칸 이상일 때) 아니면 연못 전부. 매번 hit 과 이미 고른 칸까지의
    /// 가장 가까운 유클리드 거리가 가장 큰 후보를 고른다. 동점은 행 우선.
    static func shardTiles(pond: Pond, hit: TilePoint) -> [TilePoint] {
        let inner = pond.inner
        let candidates = inner.count >= 5 ? inner : pond.tiles
        var picked = [hit]
        while picked.count < shardBursts {
            var best = candidates[0]
            var bestDistance = -1
            for c in candidates {
                let d = picked.map { squaredDistance(c, $0) }.min()!
                if d > bestDistance { best = c; bestDistance = d }
            }
            picked.append(best)
        }
        return picked
    }

    /// 칸 좌표로 정하는 고정 값 0..<12. 6 이상이면 (값 − 6)번 칸을 좌우로 뒤집는다.
    static func crackCell(at t: TilePoint) -> Int {
        var v = UInt32(truncatingIfNeeded: t.x) &* 7 &+ UInt32(truncatingIfNeeded: t.y) &* 2044
        v ^= v >> 7
        return Int(v % 12)
    }

    fileprivate static func squaredDistance(_ a: TilePoint, _ b: TilePoint) -> Int {
        (a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)
    }
}
