import Foundation

// Moved verbatim from the Mac-only PlazaRosterView.swift (Track A Task 17c): the roster panel is shared.
extension PlazaPresence {
    /// 상태 칸의 글자와 바탕색. 접속은 초록, 자리비움은 주황, 잠은 보라.
    var badge: (text: String, color: UInt32) {
        let l = L(.ko)
        switch self {
        case .online: return (l.plazaStatusOnline, 0x48B860)
        case .idle: return (l.plazaStatusIdle, 0xD08830)
        case .asleep: return (l.plazaStatusAsleep, 0x9070B8)
        case .focus: return (l.plazaStatusFocus, 0xD9502A)
        }
    }
}
