import XCTest
@testable import PokeTokenBar

final class TrayMenuModelTests: XCTestCase {
    private let l = L(.en)

    func testMenuShowsTodayTokensAndCostOnlyWhenShown() {
        let cost = UsageCost(amount: 5.09, coverage: .estimate)
        let with = TrayMenuModel.items(l: l, todayTokens: 19_400_000, todayCost: cost, login: .off, update: nil)
        XCTAssertEqual(with.first??.title, "Today's tokens 19.4M · $5.09")
        XCTAssertEqual(with.first??.enabled, false)
        let without = TrayMenuModel.items(l: l, todayTokens: 19_400_000, todayCost: nil, login: .off, update: nil)
        XCTAssertEqual(without.first??.title, "Today's tokens 19.4M")
        let actions = without.map { $0?.action }
        XCTAssertEqual(actions, [TrayMenuModel.Action.none, nil, .refresh, .toggleLaunchAtLogin, .openLogFolder, nil, .quit])
    }

    func testLoginItemStatesMapToChecksAndTitles() {
        func login(_ s: TrayMenuModel.LoginState) -> TrayMenuModel.Item {
            TrayMenuModel.items(l: l, todayTokens: 0, todayCost: nil, login: s, update: nil)
                .compactMap { $0 }.first { $0.action == .toggleLaunchAtLogin }!
        }
        XCTAssertEqual(login(.on), .init(title: "Launch at login", enabled: true, checked: true, action: .toggleLaunchAtLogin))
        XCTAssertEqual(login(.off), .init(title: "Launch at login", enabled: true, checked: false, action: .toggleLaunchAtLogin))
        XCTAssertEqual(login(.disabledByUser).title, "Launch at login (Disabled in Task Manager)")
        XCTAssertFalse(login(.disabledByUser).enabled)
        XCTAssertFalse(login(.unavailable).enabled)
        XCTAssertFalse(login(.unavailable).checked)
    }

    func testUpdateItemAppearsOnlyWithAnUpdate() {
        let none = TrayMenuModel.items(l: l, todayTokens: 0, todayCost: nil, login: .off, update: nil)
        XCTAssertFalse(none.contains { $0?.action == .openRelease })
        let some = TrayMenuModel.items(l: l, todayTokens: 0, todayCost: nil, login: .off, update: "2.6.0")
        let item = some.compactMap { $0 }.first { $0.action == .openRelease }
        XCTAssertEqual(item?.title, l.updateFound("2.6.0"))
        XCTAssertEqual(some.last??.action, .quit)
    }

    func testTeammatesLineShowsOnlyWhileTheTeamIsOn() {
        let off = TrayMenuModel.items(l: l, todayTokens: 0, todayCost: nil, login: .off, update: nil)
        XCTAssertEqual(off, TrayMenuModel.items(l: l, todayTokens: 0, todayCost: nil, login: .off, update: nil, teammatesOnline: nil))
        XCTAssertFalse(off.contains { $0?.title.contains("Teammates") == true })
        let on = TrayMenuModel.items(l: l, todayTokens: 0, todayCost: nil, login: .off, update: nil, teammatesOnline: 3)
        XCTAssertEqual(on[1], .init(title: "Teammates online: 3", enabled: false, checked: false, action: .none))
        XCTAssertEqual(on.map { $0?.action }, [TrayMenuModel.Action.none, TrayMenuModel.Action.none, nil, .refresh, .toggleLaunchAtLogin, .openLogFolder, nil, .quit])
        XCTAssertEqual(TrayMenuModel.items(l: L(.ko), todayTokens: 0, todayCost: nil, login: .off, update: nil,
                                           teammatesOnline: 0)[1]?.title, "접속 중인 팀원 0명")
    }

    func testTooltipIsClippedToTheShellLimitWithoutSplittingCharacters() {
        let long = String(repeating: "한", count: 200)
        let clipped = TrayMenuModel.clipped(long)
        XCTAssertEqual(clipped.utf16.count, TrayMenuModel.tipLimit)
        XCTAssertTrue(clipped.hasSuffix("…"))
        // A surrogate pair straddling the limit is dropped whole.
        let emoji = String(repeating: "a", count: 125) + "😀😀"
        let cut = TrayMenuModel.clipped(emoji)
        XCTAssertLessThanOrEqual(cut.utf16.count, TrayMenuModel.tipLimit)
        XCTAssertEqual(cut, String(repeating: "a", count: 125) + "…")
        XCTAssertEqual(TrayMenuModel.clipped("short"), "short")
        let note = TrayMenuModel.tooltip(l: l, todayTokens: 1200, todayCost: nil, note: "acct")
        XCTAssertEqual(note, "Today's tokens 1.2K\nacct")
    }
}
