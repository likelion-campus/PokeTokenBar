import Foundation

/// 광장의 낮과 밤. 이 Mac의 시계로 정하고, 바뀔 때는 한 시간쯤에 걸쳐 천천히 섞는다.
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

    /// 하루 중 분(0~1440)과 그때의 색, 작은 지도의 채도. 사이는 섞는다.
    private static let keys: [(minute: Double, tint: Tint, saturation: Double)] = [
        (0, night, 0.65), (5 * 60, night, 0.65), (6 * 60, dawn, 0.85), (7 * 60, .none, 1),
        (16 * 60, .none, 1), (17 * 60, dusk, 0.95), (18 * 60, night, 0.65), (24 * 60, night, 0.65),
    ]

    static func tint(minute: Double) -> Tint { look(minute: minute).tint }

    /// 작은 지도의 지도 그림 채도(1이면 그대로). 작은 지도는 광장과 같은 색을 곱하고, 밤으로 갈수록 채도도 낮춘다.
    static func minimapSaturation(minute: Double) -> Double { look(minute: minute).saturation }

    private static func look(minute: Double) -> (tint: Tint, saturation: Double) {
        let m = min(max(minute, 0), 24 * 60)
        guard let i = keys.indices.dropLast().first(where: { keys[$0].minute <= m && m <= keys[$0 + 1].minute }) else {
            return (night, keys[0].saturation)
        }
        let (a, b) = (keys[i], keys[i + 1])
        let t = (m - a.minute) / (b.minute - a.minute)
        func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
        return (Tint(red: mix(a.tint.red, b.tint.red), green: mix(a.tint.green, b.tint.green), blue: mix(a.tint.blue, b.tint.blue)),
                mix(a.saturation, b.saturation))
    }

    /// 시계에 붙이는 때. 새벽 5~7시, 낮 7~16시, 저녁 16~18시, 그 밖은 밤.
    static func phase(minute: Double) -> Phase {
        switch minute {
        case 5 * 60..<7 * 60: .dawn
        case 7 * 60..<16 * 60: .day
        case 16 * 60..<18 * 60: .dusk
        default: .night
        }
    }

    static func minute(of date: Date, calendar: Calendar = .current) -> Double {
        let c = calendar.dateComponents([.hour, .minute, .second], from: date)
        return Double((c.hour ?? 0) * 60 + (c.minute ?? 0)) + Double(c.second ?? 0) / 60
    }

    /// 광장 시계의 글. 예: "밤 21:34".
    @MainActor static func clockText(_ date: Date, calendar: Calendar = .current) -> String {
        L(.ko).plazaClock(phase: phase(minute: minute(of: date, calendar: calendar)),
                          time: PlazaChatLog.timeText(date, calendar: calendar))
    }
}
