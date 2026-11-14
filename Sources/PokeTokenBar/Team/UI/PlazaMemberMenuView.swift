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
                .foregroundStyle(Color(plaza: PlazaNameColor.color(forMemberID: menu.memberID, chosen: menu.nameColor)))
                .shadow(color: .black.opacity(0.45), radius: 0, x: 1, y: 1)
                .lineLimit(1)
                .frame(maxWidth: Self.width - 2 * (PlazaRosterMetrics.padding + 2), alignment: .leading)   // 이름은 늘 180pt 안에서 줄인다
            if let status = menu.status {
                Text(status)
                    .font(Font(PlazaResources.font(.body)))
                    .foregroundStyle(Color(hex: 0xF2C14E))
                    .lineLimit(1)
            }
            ForEach(menu.actions, id: \.self) { action in
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
        .frame(minWidth: PlazaMemberMenuView.width, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)   // 180pt 이상, 가장 긴 줄에 맞춰 자란다
        .background(PlazaRosterBackground())
    }

    static func title(_ action: PlazaMemberAction) -> String {
        let l = L(.ko)
        return switch action {
        case .greet: l.plazaMenuGreet
        case .tackle: l.plazaMenuTackle
        case .follow: l.plazaMenuFollow
        case .viewCard: l.plazaMenuViewCard
        }
    }
}

/// 모닥불 메뉴. 팀원 메뉴와 같은 모양이고 제목만 금색이다. 빈 자리가 없으면 안내 한 줄만 보인다.
@MainActor
struct PlazaCampfireMenuView: View {
    let menu: PlazaCampfireMenu
    let onChoose: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L(.ko).plazaCampfireMenuTitle(isJoin: menu.isJoin))
                .font(Font(PlazaResources.font(.body)))
                .foregroundStyle(Color(hex: 0xF2C14E))
                .shadow(color: .black.opacity(0.45), radius: 0, x: 1, y: 1)
                .lineLimit(1)
            if let notice = Self.notice(menu) {
                Text(notice)
                    .font(Font(PlazaResources.font(.body)))
                    .foregroundStyle(.white)
            }
            ForEach(Array(Self.rows(menu).indices), id: \.self) { i in
                Button { onChoose(i) } label: {
                    HStack(spacing: 6) {
                        Text("▶").opacity(i == menu.selection ? 1 : 0).accessibilityHidden(true)
                        Text(Self.rows(menu)[i])
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
        .frame(minWidth: PlazaMemberMenuView.width, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)   // 180pt 이상, 가장 긴 줄에 맞춰 자란다
        .background(PlazaRosterBackground())
    }

    /// 고를 수 있는 줄의 글: 시간들, 그리고 불 켜기나 끄기.
    static func rows(_ menu: PlazaCampfireMenu) -> [String] {
        let l = L(.ko)
        return menu.minutes.map { l.plazaCampfireRow(minutes: $0) } + [l.plazaCampfireToggle(isLit: menu.isLit)]
    }

    /// 고를 시간이 없고 내가 앉아 있지도 않으면 빈 자리가 없다는 안내.
    static func notice(_ menu: PlazaCampfireMenu) -> String? {
        menu.minutes.isEmpty && !menu.isSeated ? L(.ko).plazaCampfireFull : nil
    }
}
