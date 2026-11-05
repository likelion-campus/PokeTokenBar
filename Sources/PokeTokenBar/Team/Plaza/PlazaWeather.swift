import CoreGraphics
import Foundation

/// 광장의 계절 날씨. 실제 계절과 상관없이 벚꽃·초록 나뭇잎·낙엽·눈이 하루씩 차례로 돈다. 바뀌는 주기는 팀이 고른다(하루·한 주·한 달).
/// 이 Mac의 날짜로만 정해서 같은 주기 안에서는 팀원 모두 같은 날씨를 보고, 주기가 바뀔 때(자정 등) 바뀐다.
enum PlazaWeather {
    enum Kind: Equatable, CaseIterable {
        /// 배경을 숨겼을 때만 쓴다. 날짜로는 나오지 않는다.
        case clear, petals, greenLeaves, leaves, snow
    }

    /// 주기마다 도는 순서. 2026-11-05가 낙엽이다.
    static let cycle: [Kind] = [.petals, .greenLeaves, .leaves, .snow]

    /// 기본 달력. 시스템 달력이 일본력·불기여도 연월일이 같아야 팀원 모두 같은 날씨를 본다.
    static var gregorian: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }

    /// 한 화면에 그리는 입자 수의 상한. 넓은 화면에서도 노드 수가 이 값을 넘지 않는다.
    static let maxParticles = 120

    /// 날씨가 바뀌는 주기. 주는 월요일에 시작한다.
    enum Period: String, CaseIterable, Sendable { case day, week, month }

    /// 그 주기의 날씨. 날짜(연월일)로 센 주기 번호로 `cycle`을 돌아서, 이어지는 두 주기는 늘 다르고 넷마다 한 번씩 나온다.
    static func kind(on date: Date, calendar: Calendar = gregorian, period: Period = .day) -> Kind {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        let (y, m, d) = (c.year ?? 1970, c.month ?? 1, c.day ?? 1)
        let n: Int
        switch period {
        case .day: n = dayNumber(year: y, month: m, day: d)
        case .week: n = Int(floor(Double(dayNumber(year: y, month: m, day: d) + 3) / 7))   // 1970-01-01이 목요일
        case .month: n = y * 12 + m - 1
        }
        return cycle[((n % cycle.count) + cycle.count) % cycle.count]
    }

    /// 1970-01-01부터 센 그레고리력 날짜 수(그 전은 음수). 시간대와 상관없이 같은 연월일이면 같은 수다.
    static func dayNumber(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * ((month + 9) % 12) + 2) / 5 + day - 1   // 3월 1일이 0
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

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

/// 입자 그림. 한 칸이 월드 픽셀 하나라 지도 도트와 같은 크기로 보인다. 회전 대신 좌우로 뒤집은 그림을 따로 둔다.
enum PlazaWeatherArt {
    private static let palette: [Character: (r: UInt8, g: UInt8, b: UInt8)] = [
        "W": (0xF6, 0xFA, 0xFF), "S": (0xC6, 0xDA, 0xF0),
        "P": (0xF8, 0xBB, 0xCF), "p": (0xE8, 0x8D, 0xAC),
        "O": (0xE8, 0x83, 0x2A), "o": (0xB4, 0x5E, 0x14),
        "R": (0xD1, 0x43, 0x2E), "r": (0x96, 0x2A, 0x1C),
        "Y": (0xF2, 0xC2, 0x30), "y": (0xC4, 0x96, 0x1A),
        // 초록 잎. 풀(밝은 초록) 위에서 보이게 풀보다 훨씬 밝은 연두 잎에 짙은 잎맥을 넣는다.
        "G": (0xE4, 0xF7, 0x8C), "g": (0x2E, 0x5E, 0x18),
        "H": (0xC4, 0xEC, 0x5E), "h": (0x24, 0x4C, 0x12),
    ]

    /// 위에서 아래로 읽는 도트 격자.
    static func grids(_ kind: PlazaWeather.Kind) -> [[String]] {
        switch kind {
        case .clear: []
        case .snow: [[".W.", "WWW", ".W."], ["WW", "WS"], ["W"]]
        case .petals: both([".PP", "PPp"])
        case .greenLeaves: both(["GG.", "GgG", ".GG"]) + both(["HH.", "HhH", ".HH"])
        case .leaves: both(["OO.", "OoO", ".OO"]) + both(["RR.", "RrR", ".RR"]) + both(["YY.", "YyY", ".YY"])
        }
    }

    private static func both(_ grid: [String]) -> [[String]] { [grid, grid.map { String($0.reversed()) }] }

    /// 격자 하나를 칸당 1픽셀 그림으로 만든다(화면은 최근접 보간으로 키운다).
    static func images(_ kind: PlazaWeather.Kind) -> [CGImage] { grids(kind).map(image) }

    private static func image(_ rows: [String]) -> CGImage {
        let w = rows[0].count, h = rows.count
        let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setShouldAntialias(false)
        for (row, line) in rows.enumerated() {
            for (col, ch) in line.enumerated() {
                guard let c = palette[ch] else { continue }
                context.setFillColor(CGColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1))
                context.fill(CGRect(x: col, y: h - 1 - row, width: 1, height: 1))
            }
        }
        return context.makeImage()!
    }
}

/// SplitMix64. 씨앗이 같으면 같은 수열이다.
struct PlazaSplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// 0 이상 1 미만.
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
