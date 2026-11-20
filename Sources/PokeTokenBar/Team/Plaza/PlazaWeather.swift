import Foundation

/// 광장에 내리는 것. 계절(`PlazaSeason.weather`)이 정한다: 봄 벚꽃, 여름 초록 나뭇잎, 가을 낙엽, 겨울 눈.
enum PlazaWeather {
    enum Kind: Equatable, CaseIterable {
        /// 배경을 숨겼을 때만 쓴다. 계절로는 나오지 않는다.
        case clear, petals, greenLeaves, leaves, snow
    }

    /// 기본 달력. 시스템 달력이 일본력·불기여도 연월일이 같아야 팀원 모두 같은 날씨를 본다.
    static var gregorian: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }

    /// 한 화면에 그리는 입자 수의 상한. 넓은 화면에서도 노드 수가 이 값을 넘지 않는다.
    static let maxParticles = 120

    /// 종류별 움직임. 속도는 월드 픽셀/초이고 아래로 떨어지는 쪽이 양수.
    struct Motion {
        var fall: Double
        /// 옆으로 흐르는 속도(오른쪽이 양수).
        var drift: Double
        /// 좌우 흔들림의 속도 진폭과 각속도.
        var sway: Double
        var swayRate: Double
        /// 화면 한 픽셀(월드)당 입자 수.
        var density: Double
    }

    static func motion(_ kind: Kind) -> Motion {
        switch kind {
        case .clear: Motion(fall: 0, drift: 0, sway: 0, swayRate: 0, density: 0)
        case .petals: Motion(fall: 18, drift: 6, sway: 14, swayRate: 1.5, density: 7e-4)
        case .greenLeaves: Motion(fall: 22, drift: 5, sway: 16, swayRate: 1.6, density: 6e-4)
        case .leaves: Motion(fall: 24, drift: -5, sway: 18, swayRate: 1.8, density: 6e-4)
        case .snow: Motion(fall: 14, drift: 0, sway: 8, swayRate: 1.2, density: 1e-3)
        }
    }

    /// 보이는 넓이(월드 픽셀²)에 맞춘 입자 수. 상한을 넘지 않는다.
    static func count(_ kind: Kind, area: CGFloat) -> Int {
        min(maxParticles, Int((Double(area) * motion(kind).density).rounded()))
    }
}

/// 입자 하나. 위치는 장면 좌표(y가 위로)이고 그림은 `PlazaWeatherArt`의 번호.
struct PlazaWeatherParticle: Equatable {
    var x: Double
    var y: Double
    let variant: Int
    let fallScale: Double
    let swayScale: Double
    let rateScale: Double
    let phase: Double
}

/// 입자들의 움직임. 노드 없이 값만 다뤄 시계와 화면 영역만 주면 같은 결과가 나온다.
struct PlazaWeatherField {
    /// 화면 가장자리에서 입자가 튀어나오거나 사라지는 게 보이지 않게, 감는 영역을 이만큼 넓힌다.
    static let wrapMargin: CGFloat = 4

    let kind: PlazaWeather.Kind
    private(set) var particles: [PlazaWeatherParticle]
    private var elapsed: Double = 0

    /// 씨앗은 종류 이름의 FNV 해시라 같은 종류·개수·영역이면 늘 같은 배치다.
    init(kind: PlazaWeather.Kind, count: Int, in rect: CGRect) {
        self.kind = kind
        var rng = PlazaSplitMix64(seed: UInt64(PlazaNameColor.fnv1a("weather-\(kind)")))
        let variants = max(PlazaWeatherArt.grids(kind).count, 1)
        let area = Self.wrapRect(rect)
        particles = (0..<count).map { _ in
            PlazaWeatherParticle(x: area.minX + rng.unit() * area.width, y: area.minY + rng.unit() * area.height,
                                 variant: Int(rng.next() % UInt64(variants)), fallScale: 0.8 + rng.unit() * 0.45,
                                 swayScale: 0.6 + rng.unit() * 0.8, rateScale: 0.8 + rng.unit() * 0.4,
                                 phase: rng.unit() * 2 * .pi)
        }
    }

    private static func wrapRect(_ rect: CGRect) -> CGRect { rect.insetBy(dx: -wrapMargin, dy: -wrapMargin) }

    /// `rect`(장면 좌표)를 덮도록 움직인다. 아래로 나간 입자는 위로, 옆으로 나간 입자는 반대쪽 옆으로 돌아온다.
    mutating func advance(by dt: TimeInterval, in rect: CGRect) {
        let m = PlazaWeather.motion(kind)
        elapsed += dt
        let area = Self.wrapRect(rect)
        for i in particles.indices {
            let p = particles[i]
            let vx = m.drift + m.sway * p.swayScale * cos(m.swayRate * p.rateScale * elapsed + p.phase)
            particles[i].x = Self.wrap(p.x + vx * dt, from: Double(area.minX), length: Double(area.width))
            particles[i].y = Self.wrap(p.y - m.fall * p.fallScale * dt, from: Double(area.minY), length: Double(area.height))
        }
    }

    static func wrap(_ v: Double, from lo: Double, length: Double) -> Double {
        guard length > 0 else { return lo }
        let r = (v - lo).truncatingRemainder(dividingBy: length)
        return lo + (r < 0 ? r + length : r)
    }
}
