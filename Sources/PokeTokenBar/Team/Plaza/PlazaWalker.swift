import Foundation
import CoreGraphics

enum PlazaDirection: CaseIterable, Sendable { case up, down, left, right }

/// 한 칸씩 걷는 규칙. SpriteKit과 무관한 값 타입이다.
/// 키를 누른 순서대로 쌓고 마지막에 누른 키가 이긴다. 한 칸을 가는 도중에는 멈추지 않는다.
struct PlazaWalker: Sendable {
    static let stepDuration: TimeInterval = 0.2

    /// 걷는 중이면 도착할 칸
    private(set) var tile: TilePoint
    private(set) var facing: PlazaDirection

    private var held: [PlazaDirection] = []
    /// 다음 `advance`가 쓸 탭. 같은 프레임 안에 눌렀다 뗀 키도 한 칸은 간다.
    private var pendingTap: PlazaDirection?
    /// 걷는 중이면 출발한 칸
    private var stepFrom: TilePoint?
    private var stepElapsed: TimeInterval = 0

    var isWalking: Bool { stepFrom != nil }

    init(tile: TilePoint, facing: PlazaDirection = .down) {
        self.tile = tile
        self.facing = facing
    }

    mutating func press(_ d: PlazaDirection) {
        held.removeAll { $0 == d }
        held.append(d)
        pendingTap = d
    }

    mutating func release(_ d: PlazaDirection) {
        held.removeAll { $0 == d }
    }

    /// 눌린 키를 모두 놓는다. 아직 쓰지 않은 탭은 남긴다.
    mutating func releaseAll() {
        held.removeAll()
    }

    mutating func advance(by dt: TimeInterval, canEnter: (TilePoint) -> Bool) {
        var remaining = dt
        while true {
            if stepFrom != nil {
                let need = Self.stepDuration - stepElapsed
                if remaining < need {
                    stepElapsed += remaining
                    return
                }
                remaining -= need
                stepFrom = nil
                stepElapsed = 0
            }
            guard let d = held.last ?? pendingTap else { return }
            pendingTap = nil
            facing = d
            let target = Self.offset(tile, d)
            // 못 들어가면 돌아서기만 한다.
            guard canEnter(target) else { return }
            stepFrom = tile
            tile = target
            stepElapsed = 0
        }
    }

    /// 월드 픽셀(y 아래로). 칸 가로 가운데, 세로 0.875 지점. 걷는 중이면 보간한다.
    var footPoint: CGPoint {
        let from = stepFrom ?? tile
        let t = stepFrom == nil ? 0 : min(1, stepElapsed / Self.stepDuration)
        let x = Double(from.x) + Double(tile.x - from.x) * t
        let y = Double(from.y) + Double(tile.y - from.y) * t
        let s = Double(PlazaMap.tileSize)
        return CGPoint(x: (x + 0.5) * s, y: (y + 0.875) * s)
    }

    private static func offset(_ p: TilePoint, _ d: PlazaDirection) -> TilePoint {
        switch d {
        case .up: TilePoint(x: p.x, y: p.y - 1)
        case .down: TilePoint(x: p.x, y: p.y + 1)
        case .left: TilePoint(x: p.x - 1, y: p.y)
        case .right: TilePoint(x: p.x + 1, y: p.y)
        }
    }
}
