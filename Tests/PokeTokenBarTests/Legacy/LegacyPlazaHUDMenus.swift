import SwiftUI
import AppKit
@testable import PokeTokenBar

/// The SwiftUI member menu, campfire menu and minimap as they were before Track A Task 16 drew them as shared panels:
/// `PlazaMemberMenuView.swift` and `PlazaMinimapView.swift` verbatim (renamed; the hosting views dropped).
/// `PlazaHUDMenuRenderTests+Mac` measures their layout and renders the PR's "before" images from them. Deleted in Task 19
/// with the rest of `Legacy/`.

/// 팀원 옆에서 스페이스로 여는 메뉴. 위쪽 안내 자리에 뜬다. 고른 줄에 ▶가 붙고, 눌러서 골라도 된다.
@MainActor
struct LegacyPlazaMemberMenuView: View {
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
        .frame(minWidth: LegacyPlazaMemberMenuView.width, alignment: .leading)
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
struct LegacyPlazaCampfireMenuView: View {
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
        .frame(minWidth: LegacyPlazaMemberMenuView.width, alignment: .leading)
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


/// 오른쪽 아래 작은 지도. 누가 어디에 있는지 한눈에 보인다. 배경을 숨기면 지도 그림과 바탕을 반투명하게 낮추고
/// 점과 영역 표시만 또렷하게 남긴다. 지도 그림은 광장처럼 때에 따라 색이 바뀌고 밤에는 채도도 낮아진다. 점과 영역 표시는 그대로다.
@MainActor
struct LegacyPlazaMinimapView: View {
    let model: PlazaMinimapModel
    var background = PlazaBackgroundModel()
    let mapImage: NSImage
    let worldSize: CGSize
    /// 정해진 시각으로 그린다(테스트용). nil이면 지금 시각을 1분마다 따른다.
    var fixedDate: Date?

    var body: some View {
        let width = PlazaMinimapModel.width
        let height = (width * worldSize.height / max(worldSize.width, 1)).rounded()
        let dimmed = background.isHidden
        ZStack {
            if let fixedDate {
                mapLayer(at: fixedDate, dimmed: dimmed)
            } else {
                TimelineView(.everyMinute) { context in mapLayer(at: context.date, dimmed: dimmed) }
            }
            Canvas { context, size in
                let s = size.width / max(worldSize.width, 1)
                let view = model.view
                if view.width > 0 {
                    let rect = CGRect(x: view.minX * s, y: view.minY * s, width: view.width * s, height: view.height * s)
                    context.stroke(Path(rect), with: .color(.white.opacity(0.9)), lineWidth: 1)
                }
                let tile = CGFloat(PlazaMap.tileSize) * s
                if let fire = model.campfire {
                    // 모닥불 자리는 2×2칸이라 중심은 왼쪽 위 칸에서 한 칸 오른쪽·아래다.
                    let c = CGPoint(x: (CGFloat(fire.x) + 1) * tile, y: (CGFloat(fire.y) + 1) * tile)
                    let square = Path(CGRect(x: c.x - 2.5, y: c.y - 2.5, width: 5, height: 5))
                    context.opacity = 1
                    context.fill(square, with: .color(Color(hex: 0xF08A24)))
                    context.stroke(square, with: .color(Color(hex: 0x14161F)), lineWidth: 1)
                }
                if let item = model.item {
                    let c = CGPoint(x: (CGFloat(item.x) + 0.5) * tile, y: (CGFloat(item.y) + 0.5) * tile)
                    var diamond = Path()
                    diamond.move(to: CGPoint(x: c.x, y: c.y - 4))
                    diamond.addLine(to: CGPoint(x: c.x + 4, y: c.y))
                    diamond.addLine(to: CGPoint(x: c.x, y: c.y + 4))
                    diamond.addLine(to: CGPoint(x: c.x - 4, y: c.y))
                    diamond.closeSubpath()
                    context.opacity = 1
                    context.fill(diamond, with: .color(Color(hex: 0xF2C14E)))
                    context.stroke(diamond, with: .color(Color(hex: 0x14161F)), lineWidth: 1)
                }
                for dot in model.dots.sorted(by: { !$0.isMe && $1.isMe }) {
                    let r: CGFloat = dot.isMe ? 4.5 : 3.5
                    let center = CGPoint(x: (CGFloat(dot.tile.x) + 0.5) * tile, y: (CGFloat(dot.tile.y) + 0.5) * tile)
                    let circle = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
                    context.opacity = dot.isAway ? 0.45 : 1
                    context.fill(circle, with: .color(Color(plaza: dot.color)))
                    context.stroke(circle, with: .color(dot.isMe ? .white : Color(hex: 0x14161F)), lineWidth: dot.isMe ? 1.5 : 1)
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 6).fill(dimmed ? Color.black.opacity(Self.dimmedPanelOpacity) : Color(hex: 0x1D4F5C)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(dimmed ? 0.3 : 0.5), lineWidth: 1.5))
    }

    /// 배경을 숨겼으면 광장처럼 색을 바꾸지 않는다.
    private func mapLayer(at date: Date, dimmed: Bool) -> some View {
        let minute = PlazaDaylight.minute(of: date)
        let tint = dimmed ? .none : PlazaDaylight.tint(minute: minute, core: model.coreTime)
        return Image(nsImage: model.seasonMapImage?.nsImage ?? mapImage).resizable().interpolation(.medium)
            .colorMultiply(Color(.sRGB, red: tint.red, green: tint.green, blue: tint.blue))
            .saturation(dimmed ? 1 : PlazaDaylight.minimapSaturation(minute: minute, core: model.coreTime))
            .opacity(dimmed ? Self.dimmedMapOpacity : 1)
    }

    static let dimmedMapOpacity = 0.3
    static let dimmedPanelOpacity = 0.45
}

