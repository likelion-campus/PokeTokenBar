import SwiftUI

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
                .font(Font(PlazaResources.font(.body)))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.45), radius: 0, x: 1, y: 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 24)
            if rows.isEmpty {
                Text(l.plazaBoardEmpty)
                    .font(Font(PlazaResources.font(.body)))
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
        let lineColor = row.isShiny ? Color(hex: 0xFFE060) : Color.white
        VStack(alignment: .leading, spacing: 4) {
            Text((row.isShiny ? "★ " : "") + row.text)
                .font(Font(PlazaResources.font(.body)))
                .foregroundStyle(lineColor)
                // Only regular weights ship, so `.fontWeight(.bold)` would do nothing: a same-colour shadow
                // one font dot (1pt at the body size) to the side thickens the strokes instead.
                .shadow(color: row.isBig ? lineColor : .clear, radius: 0, x: 1, y: 0)
                .fixedSize(horizontal: false, vertical: true)
            Text(row.date)
                .font(Font(PlazaResources.font(.small)))
                .foregroundStyle(.white.opacity(0.65))
            if !row.reactions.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(row.reactions, id: \.kind) { r in
                        Text(l.teamReactionLabel(r.kind) + " " + r.nicknames.joined(separator: ", "))
                            .font(Font(PlazaResources.font(.small)))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
            }
            HStack(spacing: 4) {
                ForEach(PlazaBoardRow.buttonKinds, id: \.self) { kind in
                    Button { onReact(kind) } label: {
                        Text(l.teamReactionLabel(kind))
                            .font(Font(PlazaResources.font(.small)))
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
