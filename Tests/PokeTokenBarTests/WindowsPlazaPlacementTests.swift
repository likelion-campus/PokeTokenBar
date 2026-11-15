#if os(Windows)
import XCTest
@testable import PokeTokenBar

/// Where the plaza window opens (D6, `WinPlazaPlacement`): the Mac's frame autosave rules on Windows' monitors. Pure
/// geometry with a fixed frame (8 px sides and bottom, 31 px caption at 96 dpi, scaled), so no window is made.
@MainActor final class WindowsPlazaPlacementTests: XCTestCase {
    private func frame(_ dpi: UInt32, _ w: Int32, _ h: Int32) -> WinPlazaPlacement.Rect {
        let s = Double(dpi) / 96
        let side = Int32((8 * s).rounded()), top = Int32((31 * s).rounded())
        return .init(left: -side, top: -top, right: w + side, bottom: h + side)
    }

    private func monitor(_ name: String, _ x: Int32, _ y: Int32, _ w: Int32, _ h: Int32, dpi: UInt32 = 96, primary: Bool = false,
                         taskbar: Int32 = 48) -> WinPlazaPlacement.Monitor {
        .init(name: name, bounds: .init(left: x, top: y, right: x + w, bottom: y + h),
              work: .init(left: x, top: y, right: x + w, bottom: y + h - taskbar), dpi: dpi, isPrimary: primary)
    }

    func testTheFirstOpenIsTheMacsSizeCentredOnThePrimaryWorkArea() async {
        let p = WinPlazaPlacement.restore(saved: nil, monitors: [monitor("\\\\.\\DISPLAY2", -1920, 0, 1920, 1080),
                                                                monitor("\\\\.\\DISPLAY1", 0, 0, 1920, 1080, primary: true)], frame: frame)
        XCTAssertFalse(p.restored)
        XCTAssertEqual(p.rect.width, 960 + 16)
        XCTAssertEqual(p.rect.height, 640 + 31 + 8)
        XCTAssertEqual(p.rect.left, (1920 - p.rect.width) / 2)
        XCTAssertEqual(p.rect.top, (1080 - 48 - p.rect.height) / 2)
    }

    func testTheContentKeepsItsDIPSizeOnA150PercentPrimary() async {
        let p = WinPlazaPlacement.restore(saved: nil, monitors: [monitor("A", 0, 0, 2880, 1620, dpi: 144, primary: true)], frame: frame)
        XCTAssertEqual(p.dpi, 144)
        XCTAssertEqual(p.rect.width, 1440 + 24)   // 960 DIP at 1.5, frame 12 px a side
        XCTAssertEqual(p.rect.height, 960 + 47 + 12)
    }

    func testASavedFrameWinsOverCentringAndKeepsItsPlace() async {
        let saved = WinPlazaPlacement.Saved(left: 100, top: 120, contentWidth: 1000, contentHeight: 660, maximized: true, monitor: "A")
        let p = WinPlazaPlacement.restore(saved: saved, monitors: [monitor("A", 0, 0, 1920, 1080, primary: true)], frame: frame)
        XCTAssertTrue(p.restored)
        XCTAssertTrue(p.maximized)
        XCTAssertEqual(p.rect, .init(left: 100, top: 120, right: 100 + 1016, bottom: 120 + 660 + 39))
    }

    func testAFramePartlyOffTheWorkAreaIsMovedOntoIt() async {
        let saved = WinPlazaPlacement.Saved(left: 1700, top: 900, contentWidth: 960, contentHeight: 640, maximized: false, monitor: "A")
        let p = WinPlazaPlacement.restore(saved: saved, monitors: [monitor("A", 0, 0, 1920, 1080, primary: true)], frame: frame)
        XCTAssertTrue(p.restored)
        XCTAssertEqual(p.rect.right, 1920)
        XCTAssertEqual(p.rect.bottom, 1080 - 48)
        XCTAssertEqual(p.rect.width, 976)
    }

    func testAFrameLargerThanTheWorkAreaShrinksToIt() async {
        let saved = WinPlazaPlacement.Saved(left: 10, top: 10, contentWidth: 3000, contentHeight: 2000, maximized: false, monitor: "A")
        let p = WinPlazaPlacement.restore(saved: saved, monitors: [monitor("A", 0, 0, 1366, 768, primary: true)], frame: frame)
        XCTAssertEqual(p.rect, .init(left: 0, top: 0, right: 1366, bottom: 768 - 48))
    }

    func testAFrameOnAMonitorThatIsGoneOpensCentredOnThePrimary() async {
        let saved = WinPlazaPlacement.Saved(left: -1500, top: 100, contentWidth: 960, contentHeight: 640, maximized: false, monitor: "B")
        let p = WinPlazaPlacement.restore(saved: saved, monitors: [monitor("A", 0, 0, 1920, 1080, primary: true)], frame: frame)
        XCTAssertFalse(p.restored)
        XCTAssertEqual(p.rect.left, (1920 - 976) / 2)
    }

    func testTheNamedMonitorWinsWhenTheFrameSpansTwo() async {
        // On A (96 dpi) the frame covers 920 x 679 px of the work area, on B (120 dpi) 300 x 849: A holds more, B is named.
        let saved = WinPlazaPlacement.Saved(left: 1000, top: 100, contentWidth: 960, contentHeight: 640, maximized: false, monitor: "B")
        let a = monitor("A", 0, 0, 1920, 1080, primary: true), b = monitor("B", 1920, 0, 2560, 1440, dpi: 120)
        let p = WinPlazaPlacement.restore(saved: saved, monitors: [a, b], frame: frame)
        XCTAssertTrue(p.restored)
        XCTAssertEqual(p.dpi, 120, "B is named and overlapped")
        XCTAssertGreaterThanOrEqual(p.rect.left, 1920, "moved onto B")
    }

    func testTheContentNeverGoesBelowTheMinimum() async {
        let saved = WinPlazaPlacement.Saved(left: 50, top: 50, contentWidth: 200, contentHeight: 100, maximized: false, monitor: "A")
        let p = WinPlazaPlacement.restore(saved: saved, monitors: [monitor("A", 0, 0, 1920, 1080, primary: true)], frame: frame)
        XCTAssertEqual(p.rect.width, 600 + 16)
        XCTAssertEqual(p.rect.height, 372 + 39)
    }

    func testTheSavedStringRoundTripsAndRejectsGarbage() async {
        let s = WinPlazaPlacement.Saved(left: -1920, top: 33, contentWidth: 1033.5, contentHeight: 700, maximized: true, monitor: "\\\\.\\DISPLAY;2")
        XCTAssertEqual(WinPlazaPlacement.Saved(encoded: s.encoded), s)
        for bad in ["", "2;1;2;3;4;0;A", "1;x;2;3;4;0;A", "1;1;2;0;4;0;A", "1;1;2;3;nan;0;A", "1;1;2;3;4;0"] {
            XCTAssertNil(WinPlazaPlacement.Saved(encoded: bad), bad)
        }
        let defaults = TestDefaults.make(suite: "plaza.placement.\(UUID())")
        WinPlazaPlacement.save(s, to: defaults, key: "k")
        XCTAssertEqual(WinPlazaPlacement.read(defaults, key: "k"), s)
    }
}
#endif
