import XCTest
import AppKit
@testable import PokeTokenBar

extension PlazaActivityTests {

    /// A new view per case: without a window, macOS 15 does not refresh `fittingSize` after a second change to the model.
    private func height(hovering: String?, activity: PlazaActivity?) -> CGFloat {
        let model = PlazaRosterModel()
        model.entries = [entry("me", me: true), entry("a", activity: activity), entry("b")]
        if let hovering { model.hover(hovering, inside: true) }
        return PlazaRosterHostingView(rootView: PlazaRosterView(model: model)).fittingSize.height
    }

    func testHoveringGrowsTheSlotDownwardByTheSevenRowsAndPushesTheRestDown() {
        var a = PlazaActivity(day: "d")
        a.record(.firework)
        let rest = height(hovering: nil, activity: a)
        let grown = height(hovering: "a", activity: a)
        XCTAssertEqual(grown - rest, PlazaRosterMetrics.activityHeight(rows: 7), accuracy: 1)
        XCTAssertEqual(PlazaActivity.rows(a).count, 7)
        XCTAssertEqual(height(hovering: "b", activity: a) - rest, PlazaRosterMetrics.activityHeight(rows: 0), accuracy: 1,
                       "a slot with no record grows by its one line")
    }

    func testASlotWithNoRecordGrowsByOneLine() {
        let rest = height(hovering: nil, activity: nil)
        XCTAssertEqual(height(hovering: "a", activity: nil) - rest, PlazaRosterMetrics.activityHeight(rows: 0), accuracy: 1)
        XCTAssertLessThan(PlazaRosterMetrics.activityHeight(rows: 0), PlazaRosterMetrics.activityHeight(rows: 7))
    }

    func testMouseOutCollapsesTheSlotBack() {
        let model = PlazaRosterModel()
        var a = PlazaActivity(day: "d")
        a.record(.pickup)
        model.entries = [entry("a", activity: a)]
        let rest = PlazaRosterHostingView(rootView: PlazaRosterView(model: model)).fittingSize.height
        model.hover("a", inside: true)
        let grown = PlazaRosterHostingView(rootView: PlazaRosterView(model: model)).fittingSize.height
        model.hover("a", inside: false)
        let back = PlazaRosterHostingView(rootView: PlazaRosterView(model: model)).fittingSize.height
        XCTAssertGreaterThan(grown, rest)
        XCTAssertEqual(back, rest, accuracy: 1)
    }

    func testTheListEndsAboveTheMinimapForTheCapacityItChose() {
        for height in stride(from: CGFloat(372), through: 900, by: 37) {
            let slots = CGFloat(PlazaRoster.capacity(forHeight: height))
            let m = PlazaRosterMetrics.self
            XCTAssertLessThanOrEqual(slots * m.slotHeight + (slots - 1) * m.slotSpacing, PlazaRoster.maxListHeight(forHeight: height) + 0.5, "\(height)")
        }
    }

    func testThePanelNeverReachesTheMinimapEvenWhenTheLastSlotIsHovered() {
        let windowHeight: CGFloat = 460, m = PlazaRosterMetrics.self
        let model = PlazaRosterModel()
        model.entries = shortList()
        model.capacity = PlazaRoster.capacity(forHeight: windowHeight)
        model.maxListHeight = PlazaRoster.maxListHeight(forHeight: windowHeight)
        model.hover("m3", inside: true)
        let panel = PlazaRosterHostingView(rootView: PlazaRosterView(model: model)).fittingSize.height
        XCTAssertLessThanOrEqual(panel, windowHeight - m.margin - m.bottomClearance + 0.5)
    }
}
