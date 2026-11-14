// PlazaFocusTests+Mac: the campfire menu test asserts the SwiftUI menu view's rows and notice (PlazaCampfireMenuView)
import XCTest
import AppKit
import SwiftUI
@testable import PokeTokenBar

private let spaceKey: UInt16 = 49, upKey: UInt16 = 126, downKey: UInt16 = 125, leftKey: UInt16 = 123, returnKey: UInt16 = 36

extension PlazaFocusTests {
    func testNoFreeSeatShowsOnlyTheNotice() async {
        let me = node("나")
        let c = controller(me)
        c.prepareScene()
        var others: [Node] = []
        for (i, seat) in PlazaCampfire.seats.enumerated() {
            let n = node("팀\(i)")
            others.append(n)
            await connect(me, n)
            await place(n, at: seat.tile, in: c)
        }
        let scene = c.scene!
        key(scene, spaceKey)
        let menu = PlazaCampfireMenu(isJoin: false, minutes: [], selection: 0)
        XCTAssertEqual(c.overlayContent, .campfireMenu(menu))
        XCTAssertEqual(PlazaCampfireMenuView.notice(menu), "자리가 없어요")
        XCTAssertEqual(PlazaCampfireMenuView.rows(menu), ["불 켜기"])
        XCTAssertNil(PlazaCampfireMenuView.notice(.init(isJoin: false, minutes: [], selection: 0, isSeated: true)), "I already sit")
        XCTAssertEqual(PlazaCampfireMenuView.rows(.init(isJoin: false, minutes: [25, 480], selection: 0, isLit: true)),
                       ["25분 집중", "8시간 집중", "불 끄기"])
        key(scene, downKey)
        XCTAssertEqual(c.overlayContent, .campfireMenu(menu), "the fire row is the only row")
        key(scene, spaceKey)
        XCTAssertEqual(c.overlayContent, .none)
        XCTAssertTrue(c.isCampfireLit, "the only row lights the fire")
        XCTAssertFalse(c.isFocusing)
        XCTAssertNil(c.focus)
        key(scene, spaceKey)
        key(scene, returnKey)
        XCTAssertEqual(c.overlayContent, .none, "enter closes it too")
        XCTAssertNil(c.focus)
        c.startFocus(minutes: 25)
        XCTAssertNil(c.focus, "a seat taken after the menu opened still starts nothing")
        c.handleClose()
    }
}
