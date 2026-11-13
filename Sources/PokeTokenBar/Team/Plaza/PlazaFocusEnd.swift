import Foundation

/// 집중이 끝났다. `completed`면 시간을 다 채웠고, 아니면 일어선 것이다.
struct PlazaFocusEnd: Equatable, Sendable {
    let minutes: Int
    let elapsedMinutes: Int
    let completed: Bool
}
