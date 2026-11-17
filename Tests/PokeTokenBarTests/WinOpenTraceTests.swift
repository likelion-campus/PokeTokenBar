#if os(Windows)
import XCTest
@testable import PokeTokenBar

/// The page-open trace (field report 2026-11-17, Settings stuttered for seconds): what it counts per page and what its log line
/// carries. The selftest's `settings.openCost` measures the real swap; these pin the counting rules it relies on.
@MainActor final class WinOpenTraceTests: XCTestCase {
    private final class HomeStandIn {}
    private final class SettingsStandIn {}

    override func setUp() async throws {
        WinOpenTrace.end()
    }

    func testOneTraceCountsEveryBuildOfItsPageAndThePaintsInsideThem() async {
        let page = SettingsStandIn()
        WinOpenTrace.build(page, via: "swap") {
            WinOpenTrace.note(.window)
            WinOpenTrace.note(.window)
            WinOpenTrace.note(.paint)
            WinOpenTrace.note(.erase)
            WinOpenTrace.step("general") {}
        }
        WinOpenTrace.note(.layout)
        WinOpenTrace.note(.paint)
        WinOpenTrace.note(.refresh)
        WinOpenTrace.build(page, via: "page rebuild") { WinOpenTrace.note(.window) }   // the same page again: the same trace
        let r = WinOpenTrace.running
        XCTAssertEqual(r?.via, "swap")
        XCTAssertEqual(r?.page, "SettingsStandIn")
        XCTAssertEqual(r?.builds, 2)
        XCTAssertEqual(r?.windows, 3)
        XCTAssertEqual(r?.paints, 2)
        XCTAssertEqual(r?.paintsInBuild, 1)
        XCTAssertEqual(r?.erasesInBuild, 1)
        XCTAssertEqual(r?.layouts, 1)
        XCTAssertEqual(r?.refreshes, 1)
        XCTAssertEqual(r?.steps.map(\.name), ["general"])
        let lines = WinOpenTrace.linesWritten
        WinOpenTrace.end()
        XCTAssertNil(WinOpenTrace.running)
        XCTAssertEqual(WinOpenTrace.last, r)
        XCTAssertEqual(WinOpenTrace.linesWritten, lines + 1)
        WinOpenTrace.end()   // nothing running: no second line
        XCTAssertEqual(WinOpenTrace.linesWritten, lines + 1)
    }

    func testAnotherPageEndsTheTraceAndStartsItsOwn() async {
        let home = HomeStandIn(), settings = SettingsStandIn()
        WinOpenTrace.build(home, via: "open") {}
        WinOpenTrace.build(settings, via: "swap") {}
        XCTAssertEqual(WinOpenTrace.last?.page, "HomeStandIn")
        XCTAssertEqual(WinOpenTrace.running?.page, "SettingsStandIn")
        XCTAssertEqual(WinOpenTrace.running?.builds, 1)
        WinOpenTrace.end()
    }

    func testADrawnViewsAnimationIsNotThePageChanging() async throws {
        WinOpenTrace.build(HomeStandIn(), via: "open") {}
        let settled = try XCTUnwrap(WinOpenTrace.running?.settledMs)
        let t0 = WinOpenTrace.now()
        while WinOpenTrace.now() - t0 < 30 {}   // a sprite frame later
        WinOpenTrace.note(.drawnPaint)
        XCTAssertEqual(WinOpenTrace.running?.drawnPaints, 1)
        XCTAssertEqual(WinOpenTrace.running?.settledMs, settled)
        WinOpenTrace.note(.paint)
        XCTAssertGreaterThanOrEqual(WinOpenTrace.running?.settledMs ?? 0, settled + 30)
        WinOpenTrace.end()
    }

    func testNothingIsCountedWithoutATrace() async {
        WinOpenTrace.note(.paint)
        WinOpenTrace.step("x") {}
        XCTAssertNil(WinOpenTrace.running)
    }

    func testTheLineNamesTheSlowStepsAndNothingElse() async {
        var r = WinOpenTrace.Report(page: "SettingsPage", via: "swap")
        r.builds = 1
        r.steps = [.init(name: "general", ms: 4), .init(name: "snapshots", ms: 812.4)]
        XCTAssertTrue(r.line.contains("popover page SettingsPage via swap"), r.line)
        XCTAssertTrue(r.line.contains("slow (>= 20 ms): snapshots 812 ms"), r.line)
        XCTAssertFalse(r.line.contains("general 4 ms"), r.line)
        XCTAssertTrue(r.line.contains("general 4, snapshots 812"), r.line)
        r.steps = []
        XCTAssertTrue(r.line.contains("slow (>= 20 ms): none"), r.line)
    }
}
#endif
