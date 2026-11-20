import XCTest
@testable import PokeTokenBar

/// The popover's tab strip model (stage 7 Task 19): the Mac's order, the selected tab, the titles from `L` in every language.
final class PopoverTabsModelTests: XCTestCase {
    func testOrderIsTheMacs() {
        XCTAssertEqual(PopoverTabsModel.order, [.home, .shop, .bag, .collection])
    }

    func testTitlesFollowTheLanguage() {
        for language in AppLanguage.allCases {
            let l = L(language)
            let m = PopoverTabsModel(tab: .bag, l: l)
            XCTAssertEqual(m.titles, [l.home, l.shop, l.bag, l.collection], "\(language)")
            XCTAssertEqual(Set(m.titles).count, 4, "\(language): four different titles")
        }
    }

    func testSelectedFollowsTheTab() {
        for (i, tab) in PopoverTabsModel.order.enumerated() {
            XCTAssertEqual(PopoverTabsModel(tab: tab, l: L(.en)).selected, i)
            XCTAssertEqual(PopoverTabsModel.tab(at: i), tab)
            XCTAssertEqual(PopoverTabsModel.index(of: tab), i)
        }
        XCTAssertNil(PopoverTabsModel.tab(at: -1))
        XCTAssertNil(PopoverTabsModel.tab(at: 4))
    }

    /// The strip covers every case of the Mac's `PopoverTab`: a new case without a tab fails here.
    func testEveryTabIsInTheStrip() {
        for tab in [PopoverState.Tab.home, .shop, .bag, .collection] {
            XCTAssertTrue(PopoverTabsModel.order.contains(tab))
        }
        switch PopoverState.Tab.home {  // exhaustive: a new case stops the build here
        case .home, .shop, .bag, .collection: break
        }
    }
}
