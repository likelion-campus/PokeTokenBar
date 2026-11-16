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

    /// Stage 8: while the in-app update downloads or starts Setup, a disabled "Updating…" row stands where the update entry
    /// was (nothing to click twice); otherwise the menu is as before.
    func testUpdatingShowsADisabledRowInPlaceOfTheUpdateEntry() {
        let offer = TrayMenuModel.items(l: l, todayTokens: 0, todayCost: nil, login: .off, update: "2.6.0")
        XCTAssertEqual(offer, TrayMenuModel.items(l: l, todayTokens: 0, todayCost: nil, login: .off, update: "2.6.0", updating: false))
        let busy = TrayMenuModel.items(l: l, todayTokens: 0, todayCost: nil, login: .off, update: "2.6.0", updating: true)
        XCTAssertFalse(busy.contains { $0?.action == .openRelease })
        XCTAssertEqual(busy.count, offer.count)
        let row = busy.compactMap { $0 }.first { $0.title == l.updating }
        XCTAssertEqual(row, .init(title: "Updating…", enabled: false, checked: false, action: .none))
        XCTAssertEqual(TrayMenuModel.items(l: L(.ko), todayTokens: 0, todayCost: nil, login: .off, update: "2.6.0", updating: true)
            .compactMap { $0 }.first { !$0.enabled && $0.action == .none && $0.title.hasPrefix("업데이트") }?.title, "업데이트 중…")
        XCTAssertEqual(busy.last??.action, .quit)
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

    /// The Mac's status menu shows its plaza entry only while the team is ready (`plazaAvailable: teamSettings.isReady`), with
    /// the unread count; the tray does the same, in the Mac's (Korean) wording, after Refresh.
    func testPlazaEntryShowsOnlyWhileTheTeamIsReady() {
        let off = TrayMenuModel.items(l: l, todayTokens: 0, todayCost: nil, login: .off, update: nil)
        XCTAssertEqual(off, TrayMenuModel.items(l: l, todayTokens: 0, todayCost: nil, login: .off, update: nil, plazaUnread: nil))
        XCTAssertFalse(off.contains { $0?.action == .openPlaza })
        let ready = TrayMenuModel.items(l: l, todayTokens: 0, todayCost: nil, login: .off, update: nil, plazaUnread: 0)
        XCTAssertEqual(ready.map { $0?.action }, [TrayMenuModel.Action.none, nil, .refresh, .openPlaza, .toggleLaunchAtLogin, .openLogFolder, nil, .quit])
        XCTAssertEqual(ready[3], .init(title: "광장 열기…", enabled: true, checked: false, action: .openPlaza))
        let unread = TrayMenuModel.items(l: L(.ko), todayTokens: 0, todayCost: nil, login: .off, update: nil, teammatesOnline: 2, plazaUnread: 3)
        XCTAssertEqual(unread.compactMap { $0 }.first { $0.action == .openPlaza }?.title, "광장 열기… (3)")
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
