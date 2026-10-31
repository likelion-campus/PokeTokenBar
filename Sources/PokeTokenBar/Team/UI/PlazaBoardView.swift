import SwiftUI

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

/// 소식판: 새 소식이 위. 줄마다 문구, 날짜, 달린 반응, 반응 버튼 셋.
@MainActor
struct PlazaBoardView: View {
    let feed: TeamFeedStore
    let myMemberID: String
    let onReact: (_ eventID: String, _ kind: TeamReactionKind) -> Void

    var body: some View {
        let l = L(.ko)
        let rows = PlazaBoardRow.rows(feed: feed, myMemberID: myMemberID)
        VStack(spacing: 8) {
            Text(l.plazaBoardTitle)
                .font(Font(PlazaResources.font(size: 14)))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.45), radius: 0, x: 1, y: 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 24)
            if rows.isEmpty {
                Text(l.plazaBoardEmpty)
                    .font(Font(PlazaResources.font(size: 12)))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(rows) { row in
                            PlazaBoardRowView(row: row) { onReact(row.id, $0) }
                        }
                    }
                }
            }
        }
    }
}

@MainActor
private struct PlazaBoardRowView: View {
    let row: PlazaBoardRow
    let onReact: (TeamReactionKind) -> Void

    var body: some View {
        let l = L(.ko)
        VStack(alignment: .leading, spacing: 4) {
            Text((row.isShiny ? "★ " : "") + row.text)
                .font(Font(PlazaResources.font(size: 12)))
                .fontWeight(row.isBig ? .bold : .regular)
                .foregroundStyle(row.isShiny ? Color(hex: 0xFFE060) : .white)
                .fixedSize(horizontal: false, vertical: true)
            Text(row.date)
                .font(Font(PlazaResources.font(size: 10)))
                .foregroundStyle(.white.opacity(0.65))
            if !row.reactions.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(row.reactions, id: \.kind) { r in
                        Text(l.teamReactionLabel(r.kind) + " " + r.nicknames.joined(separator: ", "))
                            .font(Font(PlazaResources.font(size: 10)))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
            }
            HStack(spacing: 4) {
                ForEach(PlazaBoardRow.buttonKinds, id: \.self) { kind in
                    Button { onReact(kind) } label: {
                        Text(l.teamReactionLabel(kind))
                            .font(Font(PlazaResources.font(size: 11)))
                            .foregroundStyle(Color(hex: 0x2D4048))
                            .frame(minWidth: 30)
                            .padding(.vertical, 2)
                            .background(Color(hex: 0xF8F8F0).opacity(row.mine.contains(kind) ? 0.4 : 1),
                                        in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .disabled(row.mine.contains(kind))
                }
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }
}
