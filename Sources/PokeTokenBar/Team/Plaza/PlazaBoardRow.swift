import Foundation

// Moved verbatim from the Mac-only PlazaBoardView.swift (Track A Task 17d): the board panel is shared.
/// 소식판 한 줄에 그릴 값. 화면 없이 테스트할 수 있게 피드에서 미리 계산한다.
struct PlazaBoardRow: Identifiable, Equatable {
    struct Reaction: Equatable {
        let kind: TeamReactionKind
        let nicknames: [String]
    }

    /// 반응 버튼과 달린 반응을 보여 주는 순서. 댓글은 UI에 내지 않는다.
    static let buttonKinds: [TeamReactionKind] = [.cute, .lol, .congrats]

    let id: String
    let text: String
    let date: String
    let isBig: Bool
    let isShiny: Bool
    let reactions: [Reaction]
    /// 내가 이미 단 반응. 같은 버튼을 다시 누를 수 없게 한다.
    let mine: Set<TeamReactionKind>

    /// 새 소식이 위. `feed.events` 순서를 그대로 따른다.
    @MainActor
    static func rows(feed: TeamFeedStore, myMemberID: String, calendar: Calendar = .current) -> [PlazaBoardRow] {
        let l = L(.ko)
        return feed.events.map { e in
            let all = feed.reactions(for: e.id)
            return PlazaBoardRow(
                id: e.id, text: l.teamEventText(e), date: dateText(e, l: l, calendar: calendar),
                isBig: e.kind.isBig, isShiny: e.isShiny,
                reactions: buttonKinds.compactMap { kind in
                    let names = all.filter { $0.kind == kind }.map(\.authorNickname)
                    return names.isEmpty ? nil : Reaction(kind: kind, nicknames: names)
                },
                mine: Set(all.filter { $0.authorID == myMemberID }.map(\.kind)))
        }
    }

    private static func dateText(_ e: TeamEvent, l: L, calendar: Calendar) -> String {
        if let at = e.occurredAt {
            let c = calendar.dateComponents([.month, .day, .hour, .minute], from: at)
            return l.teamBoardDate(month: c.month ?? 0, day: c.day ?? 0,
                                   time: String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0))
        }
        let parts = e.day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return e.day }
        return l.teamBoardDate(month: parts[1], day: parts[2], time: nil)
    }
}
