import CoreGraphics
import Foundation

/// 모닥불이 밤 장면에 던지는 빛의 수식. SpriteKit과 무관한 순수 계산이다.
enum PlazaCampfireLight {
    static let warm = (r: 1.0, g: 0.84, b: 0.62)
    /// 세계 좌표 반지름(가로, 세로).
    static let radii = CGSize(width: 150, height: 104)

    /// 불빛의 깜빡임 배율. 주기 12 위상에서 이음새 없이 반복된다.
    static func flicker(phase: Int) -> Double {
        let t = Double(phase) / Double(PlazaCampfire.frameCount)
        return 1 + 0.035 * sin(2 * .pi * t) + 0.025 * sin(4 * .pi * t + 1.3) + 0.015 * sin(6 * .pi * t + 0.4)
    }

    /// 밤이 깊을수록 1. 낮(흰색)이면 0이라 빛이 꺼진다.
    static func strength(_ tint: PlazaDaylight.Tint) -> Double {
        min(max((1 - min(tint.red, tint.green, tint.blue)) / (1 - 0.42), 0), 1)
    }

    /// 중심에서의 정규화 거리별 계단형 세기.
    static func mix(normalizedDistance d: Double) -> Double {
        if d < 0.42 { return 1 }
        if d < 0.62 { return 0.78 }
        if d < 0.82 { return 0.52 }
        if d < 1 { return 0.26 }
        return 0
    }

    /// 어두워진 장면 위에 한 번 더 곱하는 채널별 배율(최대 2).
    static func multiplier(tint: PlazaDaylight.Tint, mix k: Double) -> (r: Double, g: Double, b: Double) {
        let ks = k * strength(tint)
        func channel(_ warm: Double, _ tint: Double) -> Double { min(2, (1 - ks) + ks * warm / tint) }
        return (channel(warm.r, tint.red), channel(warm.g, tint.green), channel(warm.b, tint.blue))
    }

    /// 빛의 중심(세계 px, y 아래 방향). 발자국 가로 중앙, 아랫변에서 14 위.
    static func center(campfireTiles: [TilePoint]) -> CGPoint? {
        guard let minX = campfireTiles.map(\.x).min(), let maxX = campfireTiles.map(\.x).max(),
              let maxY = campfireTiles.map(\.y).max() else { return nil }
        return CGPoint(x: Double(minX + maxX + 1) / 2 * 32, y: Double(maxY + 1) * 32 - 14)
    }
}
