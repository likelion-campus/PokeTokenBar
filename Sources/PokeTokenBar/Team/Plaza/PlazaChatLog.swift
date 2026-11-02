import Foundation
import CoreGraphics
import Observation

/// 광장 왼쪽 아래 대화 기록. 광장이 열려 있을 때 오간 한마디만 담고, 앱이 켜져 있는 동안 메모리에만 둔다(파일에 쓰지 않는다).
@MainActor @Observable
final class PlazaChatLog {
    struct Line: Identifiable, Equatable {
        let id: Int
        let time: Date
        let name: String
        let text: String
        let color: CGColor
        var isLoud = false
    }

    static let capacity = 50
    static let visibleCount = 6
    static let width: CGFloat = 360

    private(set) var lines: [Line] = []
    /// 펼치면 담아 둔 줄을 모두 스크롤해서 본다.
    var isExpanded = false
    static let expandedHeight: CGFloat = 240
    private var nextID = 0

    var visible: [Line] { Array(lines.suffix(Self.visibleCount)) }

    func append(time: Date, name: String, text: String, color: CGColor, isLoud: Bool = false) {
        lines.append(Line(id: nextID, time: time, name: name, text: text, color: color, isLoud: isLoud))
        nextID += 1
        if lines.count > Self.capacity { lines.removeFirst(lines.count - Self.capacity) }
    }

    /// 24시간제 `HH:mm`.
    static func timeText(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}
