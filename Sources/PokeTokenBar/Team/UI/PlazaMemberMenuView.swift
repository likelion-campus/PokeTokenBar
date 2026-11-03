import SwiftUI

/// 팀원 옆에서 스페이스로 여는 메뉴. 위쪽 안내 자리에 뜬다. 고른 줄에 ▶가 붙고, 눌러서 골라도 된다.
@MainActor
struct PlazaMemberMenuView: View {
    static let width: CGFloat = 180
    let menu: PlazaMemberMenu
    let onChoose: (PlazaMemberAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(menu.nickname)
                .font(Font(PlazaResources.font(.body)))
                .foregroundStyle(Color(cgColor: PlazaNameColor.color(forMemberID: menu.memberID, chosen: menu.nameColor)))
                .shadow(color: .black.opacity(0.45), radius: 0, x: 1, y: 1)
                .lineLimit(1)
            ForEach(PlazaMemberAction.allCases, id: \.self) { action in
                Button { onChoose(action) } label: {
                    HStack(spacing: 6) {
                        Text("▶").opacity(action == menu.selection ? 1 : 0).accessibilityHidden(true)
                        Text(Self.title(action))
                    }
                    .font(Font(PlazaResources.font(.body)))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
            }
        }
        .padding(PlazaRosterMetrics.padding + 2)
        .frame(width: Self.width)
        .background(PlazaRosterBackground())
    }

    static func title(_ action: PlazaMemberAction) -> String {
        let l = L(.ko)
        return switch action {
        case .greet: l.plazaMenuGreet
        case .viewCard: l.plazaMenuViewCard
        }
    }
}
