import CoreGraphics
import Foundation

/// 불꽃 색. 조각 색(`PlazaFireworkArt`)과 땅에 던지는 빛의 색을 함께 정한다.
enum PlazaFireworkColor: Hashable, CaseIterable, Sendable {
    case gold, red, blue, pink, mint

    /// 금색은 모닥불과 같은 빛이다.
    var light: (r: Double, g: Double, b: Double) {
        switch self {
        case .gold: PlazaCampfireLight.warm
        case .red: (r: 1, g: 0.66, b: 0.6)
        case .blue: (r: 0.7, g: 0.8, b: 1)
        case .pink: (r: 1, g: 0.74, b: 0.84)
        case .mint: (r: 0.68, g: 1, b: 0.9)
        }
    }
}

/// 한 순간에 그릴 그림. 조각은 흐려지는 대신 `spark`에서 `plus`, `dot`으로 작아지며 사라진다. 풀밭 위에서 흐려지면 꽃처럼 보인다.
struct PlazaFireworkGlyph: Hashable, Sendable {
    /// `ember`는 올라가는 포탄의 점 하나로, 번호가 클수록 꼬리 쪽이다.
    enum Shape: Hashable, Sendable { case spark, plus, dot, ember(Int) }
    var shape: Shape
    var color: PlazaFireworkColor
}

/// 불꽃 조각 하나. 값만 다뤄 시간만 주면 어디에 무엇으로 보이는지 나온다. 거리는 월드 픽셀이고 y는 위쪽이 양수.
struct PlazaFireworkPiece: Equatable, Sendable {
    var shape: PlazaFireworkGlyph.Shape = .spark
    var color: PlazaFireworkColor
    /// 터진 자리에서 떨어진 출발점.
    var start: CGVector = .zero
    /// 터지고 1초 뒤까지 나아가는 거리.
    var reach: CGVector
    /// 클수록 빨리 나아가고 빨리 느려진다.
    var settle = 3.2
    /// 1초 뒤에 내려앉는 거리. 시간의 제곱으로 늘어난다.
    var droop = 9.0
    /// 터지고 이만큼 뒤에 나온다.
    var delay: TimeInterval = 0
    var life: TimeInterval = 1.7
    /// 수명의 이 몫이 지나면 `plus`, `dot`으로 줄어든다.
    var plusAt = 0.55
    var dotAt = 0.8

    /// 터지고 `age`초 뒤 터진 자리에서 떨어진 거리. 아직 안 나왔거나 끝났으면 nil.
    func offset(at age: TimeInterval) -> CGVector? {
        let a = age - delay
        guard a >= 0, a < life else { return nil }
        let flown = (1 - exp(-settle * a)) / (1 - exp(-settle))
        return CGVector(dx: start.dx + reach.dx * flown, dy: start.dy + reach.dy * flown - droop * a * a)
    }

    func glyph(at age: TimeInterval) -> PlazaFireworkGlyph? {
        let a = age - delay
        guard a >= 0, a < life else { return nil }
        let used = a / life
        return PlazaFireworkGlyph(shape: used < plusAt ? shape : used < dotAt ? .plus : .dot, color: color)
    }
}

/// 불꽃 한 종류.
struct PlazaFireworkStyle: Equatable, Sendable {
    /// 팀원에게 보내는 이름이다. 내보낸 뒤에는 바꾸지 않는다.
    let id: String
    /// 올라가는 포탄과 땅에 던지는 빛의 색.
    let shell: PlazaFireworkColor
    let pieces: [PlazaFireworkPiece]

    /// 터진 뒤 마지막 조각이 끝날 때까지.
    var duration: TimeInterval { pieces.map { $0.delay + $0.life }.max() ?? 0 }
}

/// 광장 불꽃의 종류와 정해진 값. 있는 모양과 색을 쓰는 새 종류는 `styles`에 한 줄이면 된다. 새 모양이면 아래에 모양 함수를 더하고,
/// 새 색이면 `PlazaFireworkColor`와 `PlazaFireworkArt`에도 더한다. 어느 쪽이든 `TEAM.md`의 종류 목록도 고친다.
enum PlazaFireworks {
    /// 조각이 움직이는 박자. 초당 10장으로 끊어 움직여야 도트 그림답고, 부드러우면 광장에서 튀어 보인다.
    static let beat: TimeInterval = 0.1
    static let riseDuration: TimeInterval = 0.6
    /// 포탄이 오르는 높이. 보통은 위 끝까지 오르고, 터지는 자리가 화면에 밀려 내려오면 그만큼 덜 오른다.
    static let riseRange: ClosedRange<CGFloat> = 24...90
    /// 터지는 자리를 보이는 영역의 가장자리에서 이만큼 띄운다. 둥근 불꽃이 잘리지 않는 거리다.
    static let burstMargin: CGFloat = 64
    /// 땅에 던지는 빛의 세계 좌표 반지름(가로, 세로). 머리 위에서 터져도 쏜 캐릭터까지 닿는다.
    static let lightRadii = CGSize(width: 220, height: 160)

    /// 첫 줄은 모르는 종류를 받았을 때 대신 보여 주는 기본 불꽃이다.
    static let styles: [PlazaFireworkStyle] = [
        PlazaFireworkStyle(id: "ring", shell: .gold, pieces: ring(12, radius: 58, color: .gold)),
        PlazaFireworkStyle(id: "double", shell: .red, pieces: ring(12, radius: 62, color: .red)
            + ring(8, radius: 32, color: .gold, rotation: 0.4, delay: 0.14)),
        PlazaFireworkStyle(id: "heartShape", shell: .pink, pieces: heartShape(color: .pink)),
        PlazaFireworkStyle(id: "willow", shell: .gold, pieces: willow(color: .gold)),
        PlazaFireworkStyle(id: "star", shell: .gold, pieces: star(color: .gold)),
        PlazaFireworkStyle(id: "spiral", shell: .blue, pieces: spiral(.blue, .mint)),
        PlazaFireworkStyle(id: "crossette", shell: .blue, pieces: crossette(color: .blue)),
        PlazaFireworkStyle(id: "salvo", shell: .gold, pieces: ring(8, radius: 26, color: .gold, center: CGVector(dx: -46, dy: -6))
            + ring(8, radius: 26, color: .blue, center: CGVector(dx: 44, dy: 14), delay: 0.35)
            + ring(8, radius: 26, color: .red, center: CGVector(dx: 0, dy: -24), delay: 0.7)),
    ]

    /// 그 이름의 종류. 나중 버전이 보낸 모르는 이름이면 기본 불꽃이다.
    static func style(id: String?) -> PlazaFireworkStyle {
        styles.first { $0.id == id } ?? styles[0]
    }

    /// 무작위 종류. 직전에 쏜 종류는 고르지 않는다.
    static func next(after last: String?, using rng: inout some RandomNumberGenerator) -> PlazaFireworkStyle {
        styles.filter { $0.id != last }.randomElement(using: &rng) ?? styles[0]
    }

    /// 터질 자리(장면 좌표). 머리 위지만 늘 `visible` 안으로 민다. 멀리 있는 팀원의 불꽃은 그쪽 가장자리에서 터진다.
    /// 하늘은 위쪽이고 아래 두 모서리에는 대화 기록과 작은 지도가 있어 가운데보다 낮게는 터지지 않는다.
    static func burstPoint(head: CGPoint, visible: CGRect) -> CGPoint {
        let left = visible.minX + burstMargin, right = visible.maxX - burstMargin
        let top = max(visible.maxY - burstMargin, visible.midY)
        return CGPoint(x: left <= right ? min(max(head.x, left), right) : visible.midX,
                       y: min(max(head.y + riseRange.upperBound, visible.midY), top))
    }

    /// 포탄이 오를 높이. 머리에서 출발해 터지는 자리에 닿는다. 밀려서 머리보다 낮아져도 조금은 오른다.
    static func rise(head: CGPoint, burst: CGPoint) -> CGFloat {
        min(max(burst.y - head.y, riseRange.lowerBound), riseRange.upperBound)
    }

    /// 터지고 `age`초 뒤의 빛 세기. 터지는 순간 가장 밝고, 모닥불빛의 고리처럼 계단으로 줄어 불꽃이 끝나기 전에 꺼진다.
    static func lightLevel(age: TimeInterval, duration: TimeInterval) -> Double {
        guard age >= 0, duration > 0 else { return 0 }
        switch age / duration {
        case ..<0.2: return 1
        case ..<0.45: return 0.75
        case ..<0.7: return 0.5
        case ..<0.9: return 0.25
        default: return 0
        }
    }

    // MARK: - 모양

    private static func ring(_ count: Int, radius: Double, color: PlazaFireworkColor, center: CGVector = .zero,
                             rotation: Double = 0, delay: TimeInterval = 0) -> [PlazaFireworkPiece] {
        (0..<count).map { i in
            let angle = rotation + Double(i) / Double(count) * 2 * .pi
            return PlazaFireworkPiece(color: color, start: center, reach: CGVector(dx: cos(angle) * radius, dy: sin(angle) * radius),
                                      delay: delay)
        }
    }

    /// 하트 곡선을 둘레 길이로 나눈다. 곡선의 매개변수로 나누면 윗골과 아래 끝에 조각이 몰려 하트로 보이지 않는다.
    private static func heartShape(color: PlazaFireworkColor) -> [PlazaFireworkPiece] {
        let samples = 2000, count = 18
        let points = (0..<samples).map { i -> CGVector in
            let t = Double(i) / Double(samples) * 2 * .pi
            return CGVector(dx: 16 * pow(sin(t), 3), dy: 13 * cos(t) - 5 * cos(2 * t) - 2 * cos(3 * t) - cos(4 * t))
        }
        let lengths = points.indices.map { i -> Double in
            let a = points[i], b = points[(i + 1) % samples]
            return hypot(a.dx - b.dx, a.dy - b.dy)
        }
        let spacing = lengths.reduce(0, +) / Double(count)
        var pieces: [PlazaFireworkPiece] = [], walked = 0.0
        for (point, length) in zip(points, lengths) {
            if pieces.count < count, walked >= Double(pieces.count) * spacing {
                pieces.append(PlazaFireworkPiece(color: color, reach: CGVector(dx: point.dx * 3, dy: point.dy * 3 - 4), droop: 2,
                                                 life: 2, plusAt: 0.65, dotAt: 0.85))
            }
            walked += length
        }
        return pieces
    }

    /// 위로 아치를 그리며 퍼진 뒤 작은 점을 줄줄이 끌며 떨어진다.
    private static func willow(color: PlazaFireworkColor) -> [PlazaFireworkPiece] {
        (0..<9).flatMap { i -> [PlazaFireworkPiece] in
            let angle = Double(i) / 8 * .pi
            let head = PlazaFireworkPiece(color: color, reach: CGVector(dx: cos(angle) * 52, dy: sin(angle) * 34), droop: 26,
                                          life: 2.3, plusAt: 0.6, dotAt: 0.85)
            let trail = [0.13, 0.26, 0.39].enumerated().map { n, lag in
                var dot = head
                dot.shape = .dot
                dot.delay = lag
                dot.life = 1.7 - Double(n) * 0.15
                dot.plusAt = 0
                dot.dotAt = 0
                return dot
            }
            return [head] + trail
        }
    }

    private static func star(color: PlazaFireworkColor) -> [PlazaFireworkPiece] {
        let corners = (0..<10).map { i -> CGVector in
            let radius = i.isMultiple(of: 2) ? 64.0 : 27.0, angle = .pi / 2 + Double(i) / 10 * 2 * .pi
            return CGVector(dx: cos(angle) * radius, dy: sin(angle) * radius)
        }
        return corners.indices.flatMap { i -> [PlazaFireworkPiece] in
            let a = corners[i], b = corners[(i + 1) % corners.count]
            return [0, 0.5].map { u in
                PlazaFireworkPiece(color: color, reach: CGVector(dx: a.dx + (b.dx - a.dx) * u, dy: a.dy + (b.dy - a.dy) * u), droop: 3,
                                   life: 1.9, plusAt: 0.65, dotAt: 0.85)
            }
        }
    }

    private static func spiral(_ first: PlazaFireworkColor, _ second: PlazaFireworkColor) -> [PlazaFireworkPiece] {
        [(first, 0.0), (second, Double.pi)].flatMap { color, turn in
            (0..<9).map { i in
                let angle = turn + Double(i) * 0.62, radius = 14 + Double(i) * 6
                return PlazaFireworkPiece(color: color, reach: CGVector(dx: cos(angle) * radius, dy: sin(angle) * radius), settle: 5,
                                          droop: 5, delay: Double(i) * 0.07, life: 1.5)
            }
        }
    }

    /// 여섯 갈래로 퍼진 조각이 그 자리에서 다시 네 갈래로 갈라진다.
    private static func crossette(color: PlazaFireworkColor) -> [PlazaFireworkPiece] {
        let split = 0.8
        return (0..<6).flatMap { i -> [PlazaFireworkPiece] in
            let angle = Double(i) / 6 * 2 * .pi + 0.26
            let out = CGVector(dx: cos(angle) * 40, dy: sin(angle) * 40)
            let first = PlazaFireworkPiece(color: color, reach: out, life: split, plusAt: 1, dotAt: 1)
            let second = [(1.0, 1.0), (1.0, -1.0), (-1.0, 1.0), (-1.0, -1.0)].map { x, y in
                PlazaFireworkPiece(shape: .plus, color: color, start: out, reach: CGVector(dx: x * 19, dy: y * 19), droop: 8,
                                   delay: split, life: 0.9, plusAt: 0.6, dotAt: 0.6)
            }
            return [first] + second
        }
    }
}
