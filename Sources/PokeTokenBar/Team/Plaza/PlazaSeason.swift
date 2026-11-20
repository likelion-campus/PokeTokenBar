import Foundation

/// 광장의 계절. 지도 색, 내리는 것, 연못이 어는지를 정한다.
enum PlazaSeason: String, CaseIterable, Sendable {
    case spring, summer, autumn, winter

    /// 달력의 계절: 3~5월 봄, 6~8월 여름, 9~11월 가을, 12~2월 겨울.
    static func calendar(on date: Date, calendar: Calendar = PlazaWeather.gregorian) -> PlazaSeason {
        switch calendar.component(.month, from: date) {
        case 3...5: .spring
        case 6...8: .summer
        case 9...11: .autumn
        default: .winter
        }
    }

    var weather: PlazaWeather.Kind {
        switch self {
        case .spring: .petals
        case .summer: .greenLeaves
        case .autumn: .leaves
        case .winter: .snow
        }
    }
}

/// 팀이 고른 계절. `auto`는 달력을 따른다. 원시값이 팀 설정의 와이어 값(`PlazaSchedule.seasonPeriod`)이다.
enum PlazaSeasonChoice: String, CaseIterable, Sendable {
    case auto, spring, summer, autumn, winter

    /// 모르는 값은 겨울이다. v2.5.632 이하가 쓰던 "day"·"week"·"month"도 여기로 와서 그때처럼 눈이 온다.
    init(wire: String) { self = Self(rawValue: wire) ?? .winter }

    func season(on date: Date, calendar: Calendar = PlazaWeather.gregorian) -> PlazaSeason {
        switch self {
        case .auto: PlazaSeason.calendar(on: date, calendar: calendar)
        case .spring: .spring
        case .summer: .summer
        case .autumn: .autumn
        case .winter: .winter
        }
    }
}
