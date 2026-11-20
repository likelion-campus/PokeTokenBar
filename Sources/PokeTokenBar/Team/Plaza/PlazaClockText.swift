import Foundation

enum PlazaClockText {
    /// 24시간제 `HH:mm`.
    static func timeText(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}
