import Foundation

/// 풀숲 한 칸이 시트에서 쓸 조각. 이웃 풀숲에 따라 3×3 중 하나를 고른다.
struct PlazaTallGrassSlice: Hashable, Sendable {
    let col: Int
    let row: Int
}

enum PlazaRustleKind: Equatable, Sendable {
    /// +1 오른쪽, −1 왼쪽
    case sway(Int)
    case bounce
}

struct PlazaRustleCue: Equatable, Sendable {
    let tile: TilePoint
    let kind: PlazaRustleKind
    let strong: Bool
    let delay: TimeInterval
}

/// 풀숲에 가려지는 정도와 풀이 흔들리는 규칙. SpriteKit과 무관하다.
enum PlazaTallGrass {
    /// 풀숲 조각이 시트에서 시작하는 줄
    static let sheetRowOffset = 6
    static let frontFromRow = 9
    static let swayRows = 7
    static let leavesPerRustle = 3
    static let revealLift: CGFloat = 7
    static let hiddenPlateLift: CGFloat = 30
    static let myMinimumOpacity: CGFloat = 0.4
    static let twitchInterval: TimeInterval = 1.7
    static let leaveDelay: TimeInterval = 0.05
    static let leafLife: TimeInterval = 0.55

    static func slice(at p: TilePoint, isGrass: (TilePoint) -> Bool) -> PlazaTallGrassSlice {
        let left = isGrass(TilePoint(x: p.x - 1, y: p.y))
        let right = isGrass(TilePoint(x: p.x + 1, y: p.y))
        let up = isGrass(TilePoint(x: p.x, y: p.y - 1))
        let down = isGrass(TilePoint(x: p.x, y: p.y + 1))
        return PlazaTallGrassSlice(col: !left ? 0 : (!right ? 2 : 1), row: !up ? 0 : (!down ? 2 : 1))
    }

    /// 0(드러남)–1(완전히 가려짐). 걸음 중에는 출발·도착 칸을 섞고, 점프로 뜨면 드러난다.
    static func concealment(tile: TilePoint, step: PlazaStep?, jumpLift: CGFloat, isGrass: (TilePoint) -> Bool) -> CGFloat {
        func g(_ t: TilePoint) -> CGFloat { isGrass(t) ? 1 : 0 }
        var c: CGFloat
        if let step {
            let p = CGFloat(step.progress)
            c = (1 - p) * g(step.from) + p * g(step.to)
        } else {
            c = g(tile)
        }
        if jumpLift > 0 { c *= max(0, 1 - jumpLift / revealLift) }
        return c
    }

    static func opacity(concealment: CGFloat, isMe: Bool) -> CGFloat {
        let o = 1 - concealment
        return isMe ? max(myMinimumOpacity, o) : o
    }

    /// 장면 y(위로). 이름표 바닥을 둘 높이.
    static func plateBaseY(spriteTopY: CGFloat, footSceneY: CGFloat, concealment: CGFloat) -> CGFloat {
        spriteTopY + (footSceneY + hiddenPlateLift - spriteTopY) * min(1, concealment * 2)
    }

    static func cues(from: TilePoint, to: TilePoint, isGrass: (TilePoint) -> Bool) -> [PlazaRustleCue] {
        let dx = to.x - from.x
        let kind: PlazaRustleKind = dx == 0 ? .bounce : .sway(dx > 0 ? 1 : -1)
        var result: [PlazaRustleCue] = []
        if isGrass(to) {
            result.append(PlazaRustleCue(tile: to, kind: kind, strong: true, delay: 0))
        }
        if isGrass(from) {
            result.append(PlazaRustleCue(tile: from, kind: kind, strong: false, delay: leaveDelay))
        }
        return result
    }

    static func duration(_ kind: PlazaRustleKind, strong: Bool) -> TimeInterval {
        switch kind {
        case .sway: return strong ? 0.3 : 0.2
        case .bounce: return strong ? 0.15 : 0.1
        }
    }

    /// 시트 픽셀. dy −1 = 위로. 끝났으면 nil.
    static func offset(_ kind: PlazaRustleKind, strong: Bool, elapsed: TimeInterval) -> (dx: Int, dy: Int)? {
        guard elapsed >= 0, elapsed < duration(kind, strong: strong) else { return nil }
        switch kind {
        case .bounce:
            return (0, -1)
        case .sway(let dir):
            // 0.1초씩: 가는 쪽 → (센 신호만) 반대쪽 → 제자리
            let phases = strong ? [1, -1, 0] : [1, 0]
            return (phases[min(phases.count - 1, Int(elapsed / 0.1))] * dir, 0)
        }
    }
}
