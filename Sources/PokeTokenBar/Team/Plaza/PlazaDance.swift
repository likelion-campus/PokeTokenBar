import Foundation

/// 춤의 박자와 일곱 가지 춤의 동작표. 값만 다뤄 시간만 주면 어떤 자세인지 나온다.
/// 한 판은 4박자(1.6초)이고, 그림은 박자를 4등분한 0.1초 걸음마다 바뀐다(16걸음).
enum PlazaDance {
    /// 한 박자. 시계의 이 격자에 맞춰 시작하므로 어디서 누가 춰도 같은 박자에 뛴다.
    static let beat: TimeInterval = 0.4
    /// 그림이 바뀌는 간격. 부드러우면 광장의 다른 움직임과 달리 튀어 보인다.
    static let step: TimeInterval = 0.1
    static let beatsPerRound = 4
    static let ticksPerRound = 16
    static let round: TimeInterval = Double(beatsPerRound) * beat
    /// 팀원의 춤이 한 판이 끝난 뒤에도 다음 판 소식을 기다리는 시간. 네트워크 지연으로 다음 판 소식은 격자 경계보다 조금 늦게 오므로,
    /// 이 여유가 없으면 남의 춤이 판마다 멈췄다 다시 시작하고 ♪가 깜빡인다.
    static let remoteGrace: TimeInterval = beat
    /// 더해 온 시간의 부동소수점 오차(그리고 시계 값의 오차)가 걸음 경계를 한 걸음 넘기지 않게 하는 여유.
    private static let epsilon: TimeInterval = 1e-4

    /// 같이 추는 거리. 이 칸 수 안(대각선 포함)에서 춤추는 팀원끼리 같은 춤을 춘다.
    static let togetherRange = 3

    /// 내가 따라 출 팀원: 둘레 `togetherRange`칸 안에서 춤추는 팀원(`dancers`) 가운데 가장 먼저 춤을 시작한 팀원. 내가(`since`,
    /// 아직 안 추면 nil) 더 먼저 시작했으면 nil이다(그때는 그 팀원들이 나를 따른다). 시작 시각은 춘 사람이 춤 소식에 실어 보내는
    /// 값이라 모든 Mac이 같은 값을 견주고, 같은 시각이면 ID가 작은 쪽이 먼저다. 그래서 누가 누구를 따를지 서로 묻지 않아도 맞는다.
    static func leader(me: String, since: Date?, at tile: TilePoint, dancers: [String: (tile: TilePoint, since: Date)]) -> String? {
        let near = dancers.filter { max(abs($0.value.tile.x - tile.x), abs($0.value.tile.y - tile.y)) <= togetherRange }
        guard let first = near.min(by: { ($0.value.since, $0.key) < ($1.value.since, $1.key) }) else { return nil }
        if let since, (since, me) < (first.value.since, first.key) { return nil }
        return first.key
    }

    /// 춤 한 종류. `id`는 팀원에게 보내는 이름이라 내보낸 뒤에는 바꾸지 않는다.
    enum Style: String, CaseIterable, Sendable {
        case sway, bounce, spin, shuffle, wiggle, bigHop, twirl

        var id: String { rawValue }

        /// 그 이름의 종류. 나중 버전이 보낸 모르는 이름이면 좌우 흔들기다.
        static func style(id: String?) -> Style {
            allCases.first { $0.rawValue == id } ?? .sway
        }

        /// 무작위 종류. 직전에 춘 종류는 고르지 않는다.
        static func next(after last: Style?, using rng: inout some RandomNumberGenerator) -> Style {
            allCases.filter { $0 != last }.randomElement(using: &rng) ?? .sway
        }
    }

    /// 한 판에서 `elapsed`초가 지났을 때의 걸음(0...15). 한 판이 넘으면 되풀이한다.
    static func tick(elapsed: TimeInterval) -> Int {
        guard elapsed.isFinite else { return 0 }
        return max(0, Int(((elapsed + epsilon) / step).rounded(.down))) % ticksPerRound
    }

    /// 춤이 `length`초(기본은 한 판)를 채웠다.
    static func isOver(elapsed: TimeInterval, length: TimeInterval) -> Bool { elapsed + epsilon >= length }

    /// `date`가 박자 격자에서 지난 시간(0..<beat). 한 판은 이 값에서 시작해 격자에 맞춰 끝난다.
    /// 마이크로초 정수로 센다. 0.4는 이진수로 딱 떨어지지 않아 실수 나머지로는 격자 위의 시각이 0이 아닌 값이 나온다.
    static func gridOffset(at date: Date) -> TimeInterval {
        let micros = (date.timeIntervalSince1970 * 1_000_000).rounded()
        guard micros.isFinite, abs(micros) < 9e15 else { return 0 }
        let beatMicros = Int64(beat * 1_000_000)
        let r = Int64(micros) % beatMicros
        return Double(r < 0 ? r + beatMicros : r) / 1_000_000
    }
}

/// 춤 한 걸음의 자세. 길이는 월드 픽셀이고 위쪽이 양수다.
struct PlazaDancePose: Equatable, Sendable {
    var lift: CGFloat = 0
    var offsetX: CGFloat = 0
    var flipped = false
    /// 뒷모습으로 그린다. nil이면 걷기 자세를 따른다.
    var back: Bool?
    var squash: CGFloat = 1
    /// 라디안. 양수는 반시계 방향이고 발(그림 아래 가운데)을 축으로 기운다.
    var tilt: CGFloat = 0

    static let rest = PlazaDancePose()

    private static let shuffleOffsets: [CGFloat] = [0, 1, 3, 4, 4, 5, 7, 8, 8, 7, 5, 4, 4, 3, 1, 0]
    private static let bigHopLifts: [CGFloat] = [0, 2, 3, 2, 0, 2, 3, 2, 0, 7, 12, 15, 16, 15, 12, 7]
    private static let wiggleTilts: [CGFloat] = [0.2, 0.2, 0, 0, -0.2, -0.2, 0, 0]

    /// `style`의 `tick`번째 걸음(0...15)의 자세. 한 박자는 네 걸음이다.
    static func pose(_ style: PlazaDance.Style, tick rawTick: Int) -> PlazaDancePose {
        let tick = ((rawTick % PlazaDance.ticksPerRound) + PlazaDance.ticksPerRound) % PlazaDance.ticksPerRound
        let beat = tick / 4, stepInBeat = tick % 4
        var pose = PlazaDancePose()
        switch style {
        case .sway:
            pose.lift = [0, 3, 5, 3][stepInBeat]
            pose.flipped = beat % 2 == 1
        case .bounce:
            pose.lift = [0, 4, 7, 4][stepInBeat]
            pose.squash = stepInBeat == 0 ? 0.84 : 1.06
        case .spin:
            pose.lift = [0, 2, 3, 2][stepInBeat]
            pose.flipped = beat == 1 || beat == 2
            pose.back = beat >= 2
        case .shuffle:
            pose.lift = [0, 3, 4, 2][stepInBeat]
            pose.offsetX = shuffleOffsets[tick]
            pose.flipped = beat >= 2
        case .wiggle:
            pose.tilt = wiggleTilts[tick % 8]
        case .bigHop:
            pose.lift = bigHopLifts[tick]
            pose.squash = tick == 0 || tick == 8 ? 0.82 : 1
        case .twirl:
            pose.lift = 3
            pose.flipped = stepInBeat == 1 || stepInBeat == 2
            pose.back = stepInBeat >= 2
        }
        return pose
    }
}
