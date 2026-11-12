import Foundation
import CoreGraphics

enum PlazaPondAction: Equatable, Sendable { case jump, shoreJump, plunge(PlazaDirection), dive, surface }

enum PlazaPondShore: Equatable, Sendable {
    case notShore
    case cell(col: Int, row: Int)
    case unsupported
}

/// 연못 규칙. SpriteKit과 무관하다.
enum PlazaPond {
    static let swimStepDuration: TimeInterval = 0.25
    /// `PlazaActor.jumpDuration`과 같아야 한다(테스트가 지킨다).
    static let plungeStepDuration: TimeInterval = 0.36
    static let swimVisibleFraction: CGFloat = 0.45
    static let swimMinVisible: CGFloat = 10
    static let diveLimit: TimeInterval = 6
    static let waterTypeDiveLimit: TimeInterval = 15
    static let wetDuration: TimeInterval = 2
    static let bubbleInterval: TimeInterval = 0.4
    static let diveFade: TimeInterval = 0.2

    private static let edgeSearchRadius = 64

    private static func at(_ p: TilePoint, _ dx: Int, _ dy: Int) -> TilePoint {
        TilePoint(x: p.x + dx, y: p.y + dy)
    }

    /// `shore(at:isWater:)` 가 돌려줄 수 있는 모든 시트 칸.
    static let shoreCells: [(col: Int, row: Int)] = [
        (2, 6), (3, 6), (4, 6), (2, 7), (4, 7), (2, 8), (3, 8), (4, 8), (2, 9), (3, 9), (2, 10), (3, 10)
    ]

    /// 물 칸 그림은 늘 (3,7). 땅 칸의 물가 그림(5.1 표). 물 칸 자신은 `.notShore`.
    static func shore(at p: TilePoint, isWater: (TilePoint) -> Bool) -> PlazaPondShore {
        if isWater(p) { return .notShore }
        let n = isWater(at(p, 0, -1)), s = isWater(at(p, 0, 1))
        let w = isWater(at(p, -1, 0)), e = isWater(at(p, 1, 0))
        switch [n, s, w, e].filter({ $0 }).count {
        case 0:
            let nw = isWater(at(p, -1, -1)), ne = isWater(at(p, 1, -1))
            let sw = isWater(at(p, -1, 1)), se = isWater(at(p, 1, 1))
            switch [nw, ne, sw, se].filter({ $0 }).count {
            case 0: return .notShore
            case 1:
                if se { return .cell(col: 2, row: 6) }
                if sw { return .cell(col: 4, row: 6) }
                if ne { return .cell(col: 2, row: 8) }
                return .cell(col: 4, row: 8)
            default: return .unsupported
            }
        case 1:
            if s { return .cell(col: 3, row: 6) }
            if n { return .cell(col: 3, row: 8) }
            if e { return .cell(col: 2, row: 7) }
            return .cell(col: 4, row: 7)
        case 2:
            if s && e { return .cell(col: 3, row: 10) }
            if s && w { return .cell(col: 2, row: 10) }
            if n && e { return .cell(col: 3, row: 9) }
            if n && w { return .cell(col: 2, row: 9) }
            return .unsupported
        default:
            return .unsupported
        }
    }

    static func action(tile: TilePoint, facing: PlazaDirection, isDiving: Bool, canMove: Bool,
                       isWater: (TilePoint) -> Bool, isFree: (TilePoint) -> Bool) -> PlazaPondAction {
        // 물속의 알은 잠수하지 않고 폴짝 뛰기만 한다(이미 잠수 중이면 떠오른다).
        if isWater(tile) { return isDiving ? .surface : (canMove ? .dive : .jump) }
        let ahead = PlazaWalker.offset(tile, facing)
        if canMove, isWater(ahead), isFree(ahead) { return .plunge(facing) }
        let nearWater = PlazaDirection.allCases.contains { isWater(PlazaWalker.offset(tile, $0)) }
        return nearWater ? .shoreJump : .jump
    }

    /// 작은 물보라 지점: 바라보는 쪽이 물이면 그 칸, 아니면 북·동·남·서 순서로 첫 물 칸. 물 이웃이 없으면 nil.
    static func shoreSplashTile(tile: TilePoint, facing: PlazaDirection,
                                isWater: (TilePoint) -> Bool) -> TilePoint? {
        let ahead = PlazaWalker.offset(tile, facing)
        if isWater(ahead) { return ahead }
        for d in [PlazaDirection.up, .right, .down, .left] {
            let q = PlazaWalker.offset(tile, d)
            if isWater(q) { return q }
        }
        return nil
    }

    static func splashRadius(stage: Int) -> Int {
        TeamEmote.pushTiles(stage)
    }

    static func diveLimit(types: [String]?) -> TimeInterval {
        (types ?? []).contains("water") ? waterTypeDiveLimit : diveLimit
    }

    /// 젖는 대상: 땅에 선 배우 중 물보라 칸과 체비셰프 거리 ≤ radius, 일으킨 사람 제외. id nil = 나.
    static func wetTargets(splash: TilePoint, radius: Int, splasher: String?,
                           actors: [(id: String?, tile: TilePoint)],
                           isWater: (TilePoint) -> Bool) -> [String?] {
        actors.compactMap { a in
            guard a.id != splasher, !isWater(a.tile),
                  max(abs(a.tile.x - splash.x), abs(a.tile.y - splash.y)) <= radius else { return nil }
            return .some(a.id)
        }
    }

    static func swimSink(spriteHeight h: CGFloat) -> CGFloat {
        h - max(min(swimMinVisible, h), h * swimVisibleFraction)
    }

    /// 한 걸음 시간: 땅→물 0.36, 물→물 0.25, 물→땅 0.15, 땅→땅 running ? 0.075 : 0.15
    static func stepDuration(from: TilePoint, to: TilePoint, running: Bool,
                             isWater: (TilePoint) -> Bool) -> TimeInterval {
        switch (isWater(from), isWater(to)) {
        case (false, true): plungeStepDuration
        case (true, true): swimStepDuration
        case (true, false): PlazaWalker.stepDuration
        case (false, false): running ? PlazaWalker.runStepDuration : PlazaWalker.stepDuration
        }
    }

    /// 걸어가기 목표: 물속 팀원에게 가장 가까운(맨해튼) 물 칸 중 상하좌우에 땅이 있는 칸. 없으면 nil.
    /// 같은 거리의 후보 가운데에서는 걷는 쪽(`from`)에 가장 가까운 칸, 그래도 같으면 위쪽(y), 그다음 왼쪽(x) 칸.
    static func nearestEdgeWater(to target: TilePoint, from: TilePoint, isWater: (TilePoint) -> Bool,
                                 isLand: (TilePoint) -> Bool) -> TilePoint? {
        func isEdge(_ q: TilePoint) -> Bool {
            isWater(q) && PlazaDirection.allCases.contains { isLand(PlazaWalker.offset(q, $0)) }
        }
        for d in 0...edgeSearchRadius {
            var best: (tile: TilePoint, distance: Int)?
            for dy in -d...d {
                let rest = d - abs(dy)
                for dx in Set([-rest, rest]).sorted() {
                    let q = at(target, dx, dy)
                    guard isEdge(q) else { continue }
                    let distance = abs(q.x - from.x) + abs(q.y - from.y)
                    if best == nil || distance < best!.distance { best = (q, distance) }
                }
            }
            if let best { return best.tile }
        }
        return nil
    }

    /// 물속의 알이 물가로 나가는 다음 한 걸음. 물 칸만 지나 가장 가까운 `isLand` 칸으로 가는 길의 첫 방향이다.
    /// 거리가 같으면 위·오른쪽·아래·왼쪽 순서로 먼저 찾은 길이다. 물 밖이거나 닿을 땅이 없으면 nil.
    static func stepAshore(from start: TilePoint, isWater: (TilePoint) -> Bool,
                           isLand: (TilePoint) -> Bool) -> PlazaDirection? {
        guard isWater(start) else { return nil }
        var first: [TilePoint: PlazaDirection] = [:]
        var queue = [start]
        var head = 0
        while head < queue.count {
            let q = queue[head]
            head += 1
            for d in [PlazaDirection.up, .right, .down, .left] {
                let n = PlazaWalker.offset(q, d)
                guard n != start, first[n] == nil else { continue }
                let step = first[q] ?? d
                if isLand(n) { return step }
                guard isWater(n) else { continue }
                first[n] = step
                queue.append(n)
            }
        }
        return nil
    }
}
