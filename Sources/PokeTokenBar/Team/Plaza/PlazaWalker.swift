import Foundation
import CoreGraphics

enum PlazaDirection: String, CaseIterable, Codable, Sendable { case up, down, left, right }

/// 한 칸씩 걷는 규칙. SpriteKit과 무관한 값 타입이다.
/// 키를 누른 순서대로 쌓고 마지막에 누른 키가 이긴다. 한 칸을 가는 도중에는 멈추지 않는다.
struct PlazaWalker: Sendable {
    /// 한 칸에 걸리는 시간. 걷는 도중에는 멈추거나 돌지 않으므로, 짧을수록 키를 떼거나 바꿨을 때 바로 반응한다.
    static let stepDuration: TimeInterval = 0.15
    /// 달릴 때(Shift) 한 칸에 걸리는 시간. 걷기의 절반이다.
    static let runStepDuration: TimeInterval = 0.075

    /// 걷는 중이면 도착할 칸
    private(set) var tile: TilePoint
    private(set) var facing: PlazaDirection

    private var held: [PlazaDirection] = []
    /// 다음 `advance`가 쓸 탭. 같은 프레임 안에 눌렀다 뗀 키도 한 칸은 간다.
    private var pendingTap: PlazaDirection?
    /// 몸통박치기로 밀려 갈 방향과 남은 칸 수. 누른 키보다 먼저 쓴다.
    private var pendingPush: (direction: PlazaDirection, tiles: Int)?
    /// 걷는 중이면 출발한 칸
    private var stepFrom: TilePoint?
    private var stepElapsed: TimeInterval = 0
    /// 지금 가는 칸에 걸리는 시간. 칸을 출발할 때 정한다.
    private var stepLength: TimeInterval = Self.stepDuration
    /// Shift를 누르고 있다. 다음에 출발하는 칸부터 달린다. 밀려 가는 칸은 늘 걷는 빠르기다.
    var wantsToRun = false

    var isWalking: Bool { stepFrom != nil }
    /// 지금 가는 칸을 달리고 있다.
    var isRunning: Bool { stepFrom != nil && stepLength == Self.runStepDuration }

    init(tile: TilePoint, facing: PlazaDirection = .down) {
        self.tile = tile
        self.facing = facing
    }

    mutating func press(_ d: PlazaDirection) {
        held.removeAll { $0 == d }
        held.append(d)
        pendingTap = d
    }

    /// 키 없이 한 칸 걷는다(목록에서 팀원을 골라 걸어갈 때).
    mutating func step(_ d: PlazaDirection) {
        pendingTap = d
    }

    /// 다른 캐릭터에게 밀려 `tiles`칸 미끄러진다. 누른 키보다 먼저 가고 돌아서지 않는다. 못 들어가는 칸을 만나면 그 앞에 선다.
    mutating func push(_ d: PlazaDirection, tiles: Int = 1) {
        pendingPush = (d, tiles)
    }

    /// 서 있을 때만 돌아선다.
    mutating func face(_ d: PlazaDirection) {
        if stepFrom == nil { facing = d }
    }

    mutating func release(_ d: PlazaDirection) {
        held.removeAll { $0 == d }
    }

    /// 눌린 키를 모두 놓는다. 아직 쓰지 않은 탭은 남긴다.
    mutating func releaseAll() {
        held.removeAll()
    }

    /// 눌린 키와 아직 쓰지 않은 탭을 모두 지운다. 걷던 칸은 마저 간다.
    mutating func clearInput() {
        held.removeAll()
        pendingTap = nil
    }

    mutating func advance(by dt: TimeInterval, canEnter: (TilePoint) -> Bool) {
        var remaining = dt
        while true {
            if stepFrom != nil {
                let need = stepLength - stepElapsed
                if remaining < need {
                    stepElapsed += remaining
                    return
                }
                remaining -= need
                stepFrom = nil
                stepElapsed = 0
            }
            if let push = pendingPush {
                let target = Self.offset(tile, push.direction)
                if canEnter(target) {
                    pendingPush = push.tiles > 1 ? (push.direction, push.tiles - 1) : nil
                    stepLength = Self.stepDuration
                    stepFrom = tile
                    tile = target
                    stepElapsed = 0
                    continue
                }
                pendingPush = nil
            }
            guard let d = held.last ?? pendingTap else { return }
            pendingTap = nil
            facing = d
            let target = Self.offset(tile, d)
            // 못 들어가면 돌아서기만 한다.
            guard canEnter(target) else { return }
            stepLength = wantsToRun ? Self.runStepDuration : Self.stepDuration
            stepFrom = tile
            tile = target
            stepElapsed = 0
        }
    }

    /// 월드 픽셀(y 아래로). 칸 가로 가운데, 세로 0.875 지점. 걷는 중이면 보간한다.
    var footPoint: CGPoint {
        let t = stepFrom == nil ? 0 : min(1, stepElapsed / stepLength)
        return Self.footPoint(from: stepFrom ?? tile, to: tile, progress: t)
    }

    /// `from`에서 `to`로 `progress`(0–1)만큼 간 발 위치. 팀원 보간도 같은 식을 쓴다.
    static func footPoint(from: TilePoint, to: TilePoint, progress t: Double) -> CGPoint {
        let x = Double(from.x) + Double(to.x - from.x) * t
        let y = Double(from.y) + Double(to.y - from.y) * t
        let s = Double(PlazaMap.tileSize)
        return CGPoint(x: (x + 0.5) * s, y: (y + 0.875) * s)
    }

    /// `p`에서 `d` 방향으로 한 칸 옆.
    static func offset(_ p: TilePoint, _ d: PlazaDirection) -> TilePoint {
        switch d {
        case .up: TilePoint(x: p.x, y: p.y - 1)
        case .down: TilePoint(x: p.x, y: p.y + 1)
        case .left: TilePoint(x: p.x - 1, y: p.y)
        case .right: TilePoint(x: p.x + 1, y: p.y)
        }
    }
}
