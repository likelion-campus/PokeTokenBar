import Foundation

/// 팀이 정한 코어타임(시 단위). 새벽 노을이 시작 한 시간 전부터, 저녁 노을이 끝 한 시간 뒤까지 하루 안에 들어와야 한다.
struct PlazaCoreTime: Equatable, Sendable {
    let start: Int, end: Int
    static let standard = PlazaCoreTime(start: 10, end: 16)!

    init?(start: Int, end: Int) {
        guard start >= 1, start < end, end <= 23 else { return nil }
        self.start = start
        self.end = end
    }
}

/// 광장의 낮과 밤. 이 Mac의 시계로 정한다. 회사 코어타임(10~16시)은 내내 밝고, 그 앞뒤 한 시간(9~10시, 16~17시)은
/// 노을이 졌다 걷히며, 나머지는 밤이다. 노을은 반 시간에 걸쳐 짙어지고 반 시간에 걸쳐 걷힌다.
enum PlazaDaylight {
    enum Phase: Equatable, CaseIterable { case dawn, day, dusk, night }

    /// 지도와 캐릭터에 곱하는 색. 흰색(1, 1, 1)이면 그대로고, 낮을수록 어두워진다. 곱하기라 밤에도 무늬와 색이 살아 있다.
    struct Tint: Equatable {
        var red: Double, green: Double, blue: Double
        static let none = Tint(red: 1, green: 1, blue: 1)
    }

    static let night = Tint(red: 0.42, green: 0.48, blue: 0.78)
    static let dusk = Tint(red: 1.0, green: 0.76, blue: 0.58)
    static let dawn = Tint(red: 0.86, green: 0.8, blue: 0.98)

    /// 하루 중 분(0~1440)과 그때의 색, 작은 지도의 채도. 코어타임 `s~e`시는 내내 밝고, 그 앞 한 시간은 새벽 노을, 뒤 한 시간은 저녁 노을이다.
    private static func keys(_ core: PlazaCoreTime) -> [(minute: Double, tint: Tint, saturation: Double)] {
        let (s, e) = (Double(core.start * 60), Double(core.end * 60))
        return [
            (0, night, 0.65), (s - 60, night, 0.65), (s - 30, dawn, 0.85), (s, .none, 1),
            (e, .none, 1), (e + 30, dusk, 0.95), (e + 60, night, 0.65), (24 * 60, night, 0.65),
        ]
    }

    static func tint(minute: Double, core: PlazaCoreTime = .standard) -> Tint { look(minute: minute, core: core).tint }

    /// 작은 지도의 지도 그림 채도(1이면 그대로). 작은 지도는 광장과 같은 색을 곱하고, 밤으로 갈수록 채도도 낮춘다.
    static func minimapSaturation(minute: Double, core: PlazaCoreTime = .standard) -> Double {
        look(minute: minute, core: core).saturation
    }

    private static func look(minute: Double, core: PlazaCoreTime) -> (tint: Tint, saturation: Double) {
        let keys = keys(core)
        let m = min(max(minute, 0), 24 * 60)
        guard let i = keys.indices.dropLast().first(where: { keys[$0].minute <= m && m <= keys[$0 + 1].minute }) else {
            return (night, keys[0].saturation)
        }
        let (a, b) = (keys[i], keys[i + 1])
        // 코어타임이 하루 끝에 닿으면 길이 0인 구간이 생긴다. 0으로 나누지 않는다.
        let t = b.minute > a.minute ? (m - a.minute) / (b.minute - a.minute) : 0
        func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
        return (Tint(red: mix(a.tint.red, b.tint.red), green: mix(a.tint.green, b.tint.green), blue: mix(a.tint.blue, b.tint.blue)),
                mix(a.saturation, b.saturation))
    }

    /// 시계에 붙이는 때. 코어타임 앞 한 시간은 아침, 코어타임은 낮, 뒤 한 시간은 저녁, 그 밖은 밤.
    static func phase(minute: Double, core: PlazaCoreTime = .standard) -> Phase {
        let (s, e) = (Double(core.start * 60), Double(core.end * 60))
        switch minute {
        case (s - 60)..<s: return .dawn
        case s..<e: return .day
        case e..<(e + 60): return .dusk
        default: return .night
        }
    }

    static func minute(of date: Date, calendar: Calendar = .current) -> Double {
        let c = calendar.dateComponents([.hour, .minute, .second], from: date)
        return Double((c.hour ?? 0) * 60 + (c.minute ?? 0)) + Double(c.second ?? 0) / 60
    }

    /// 광장 시계의 글. 예: "밤 21:34".
    @MainActor static func clockText(_ date: Date, calendar: Calendar = .current, core: PlazaCoreTime = .standard) -> String {
        L(.ko).plazaClock(phase: phase(minute: minute(of: date, calendar: calendar), core: core),
                          time: PlazaChatLog.timeText(date, calendar: calendar))
    }
}
