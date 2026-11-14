import Foundation

/// The titles and rows of the member and campfire menus (shared text; `PlazaMenuPanel` draws them).
enum PlazaMenuText {
    /// The menu's usual width in points; it grows past it for a longer row.
    static let width: CGFloat = 180

    static func title(_ action: PlazaMemberAction) -> String {
        let l = L(.ko)
        return switch action {
        case .greet: l.plazaMenuGreet
        case .tackle: l.plazaMenuTackle
        case .follow: l.plazaMenuFollow
        case .viewCard: l.plazaMenuViewCard
        }
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
