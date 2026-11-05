import CoreGraphics
import Foundation

/// 광장의 계절 날씨. 이 Mac의 날짜로만 정해서 같은 날은 팀원 모두 같은 날씨를 본다. 자정에 바뀐다.
enum PlazaWeather {
    enum Kind: Equatable, CaseIterable {
        case clear, petals, rain, leaves, snow
    }

    /// 한 화면에 그리는 입자 수의 상한. 넓은 화면에서도 노드 수가 이 값을 넘지 않는다.
    static let maxParticles = 120

    /// 날짜(월일)로 정한 날씨.
    /// 벚꽃 4/1~4/14 매일, 비 6/20~7/31 반쯤, 낙엽 10/20~11/20 매일, 눈 12/1~2월 말 반쯤. 나머지는 맑음.
    static func kind(on date: Date, calendar: Calendar = .current) -> Kind {
        let year = calendar.component(.year, from: date), month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)
        let wet = isWetDay(year: year, month: month, day: day)
        switch month * 100 + day {
        case 401...414: return .petals
        case 620...731: return wet ? .rain : .clear
        case 1020...1120: return .leaves
        case 1201...1231, 101...229: return wet ? .snow : .clear
        default: return .clear
        }
    }

    /// 비와 눈이 오는 날인가. 날짜의 FNV 해시를 섞어 정하므로 어느 Mac에서나 같다.
    static func isWetDay(year: Int, month: Int, day: Int) -> Bool {
        var z = UInt64(PlazaNameColor.fnv1a("\(year)-\(month)-\(day)")) &* 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return (z >> 33) & 1 == 1
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
        case .rain: Motion(fall: 150, drift: 70, sway: 0, swayRate: 0, density: 1.2e-3)
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
        "L": (0xDC, 0xEC, 0xFF), "D": (0x9C, 0xC0, 0xEE),
        "P": (0xF8, 0xBB, 0xCF), "p": (0xE8, 0x8D, 0xAC),
        "O": (0xE8, 0x83, 0x2A), "o": (0xB4, 0x5E, 0x14),
        "R": (0xD1, 0x43, 0x2E), "r": (0x96, 0x2A, 0x1C),
        "Y": (0xF2, 0xC2, 0x30), "y": (0xC4, 0x96, 0x1A),
    ]

    /// 위에서 아래로 읽는 도트 격자.
    static func grids(_ kind: PlazaWeather.Kind) -> [[String]] {
        switch kind {
        case .clear: []
        case .snow: [[".W.", "WWW", ".W."], ["WW", "WS"], ["W"]]
        case .rain: [["D.", "D.", ".L", ".L"]]
        case .petals: both([".PP", "PPp"])
        case .leaves: both(["OO.", "OoO", ".OO"]) + both(["RR.", "RrR", ".RR"]) + both(["YY.", "YyY", ".YY"])
        }
    }

    private static func both(_ grid: [String]) -> [[String]] { [grid, grid.map { String($0.reversed()) }] }

    /// 격자 하나를 칸당 1픽셀 그림으로 만든다(화면은 최근접 보간으로 키운다).
    static func images(_ kind: PlazaWeather.Kind) -> [CGImage] { grids(kind).map { image($0, palette: palette) } }

    static func image(_ rows: [String], palette: [Character: (r: UInt8, g: UInt8, b: UInt8)]) -> CGImage {
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
