import XCTest
@testable import PokeTokenBar

/// The scroll model for scrolling panels (Track A Task 17a): clamping, the end rule for wheel input, which rows show.
final class PlazaScrollStateTests: XCTestCase {
    /// At `offset`, or at the bottom.
    private func state(content: CGFloat = 900, viewport: CGFloat = 240, offset: CGFloat? = nil) -> PlazaScrollState {
        var s = PlazaScrollState()
        s.setMetrics(content: content, viewport: viewport)
        s.scrollToBottom()
        if let offset, offset < s.maxOffset { _ = s.scroll(deltaY: s.maxOffset - offset) }
        return s
    }

    func testTheOffsetStaysInsideTheContent() {
        var s = state()
        XCTAssertEqual(s.maxOffset, 660)
        XCTAssertEqual(s.offset, 660, "scrollToBottom: the content's end meets the viewport's end")
        s.setMetrics(content: 500, viewport: 240)
        XCTAssertEqual(s.offset, 260, "content shrinking keeps the offset inside the new range")
        s.setMetrics(content: 100, viewport: 240)
        XCTAssertEqual(s.offset, 0)
        XCTAssertFalse(s.canScroll, "content that fits does not scroll")
    }

    func testAWheelDeltaMovesTheContentWhileItCanAndIsPassedOnAtTheEnds() {
        var s = state(offset: 100)
        XCTAssertTrue(s.scroll(deltaY: 30), "positive: the content moves down, the offset falls")
        XCTAssertEqual(s.offset, 70)
        XCTAssertTrue(s.scroll(deltaY: -50))
        XCTAssertEqual(s.offset, 120)
        XCTAssertTrue(s.scroll(deltaY: 500), "a delta that overshoots still moves it to the end: consumed")
        XCTAssertEqual(s.offset, 0, "clamped, no overshoot")
        XCTAssertFalse(s.scroll(deltaY: 10), "at the top, further up is passed on")
        XCTAssertTrue(s.scroll(deltaY: -10), "but down is not")
        s.scrollToBottom()
        XCTAssertFalse(s.scroll(deltaY: -10), "at the bottom, further down is passed on")
        XCTAssertTrue(s.scroll(deltaY: 10))
        var fits = state(content: 100)
        XCTAssertFalse(fits.scroll(deltaY: 10), "content that fits passes everything on")
        var z = state(offset: 100)
        XCTAssertFalse(z.scroll(deltaY: 0), "no vertical delta moves nothing")
    }

    func testVisibleRowsAreTheOnesInTheViewport() {
        let frames = (0..<50).map { CGRect(x: 0, y: CGFloat($0) * 18, width: 340, height: 15) }
        var s = state(content: 897)
        XCTAssertEqual(s.offset, 657)
        XCTAssertEqual(s.visibleRows(frames), 36..<50)
        _ = s.scroll(deltaY: 657)
        XCTAssertEqual(s.visibleRows(frames), 0..<14, "rows 0...13 intersect 0..<240 (row 13 spans 234...249)")
        XCTAssertEqual(PlazaScrollState().visibleRows([]), 0..<0)
        XCTAssertEqual(PlazaScrollState().visibleRows(frames), 0..<0, "no viewport, nothing shows")
    }

    func testAVisibleRectIsCutToTheViewport() {
        let s = state(content: 897, offset: 657)
        let partly = CGRect(x: 0, y: 648, width: 340, height: 15)
        XCTAssertEqual(s.visible(partly), CGRect(x: 0, y: 0, width: 340, height: 6), "9 points are above the viewport")
        XCTAssertEqual(s.visible(CGRect(x: 0, y: 700, width: 340, height: 15)), CGRect(x: 0, y: 43, width: 340, height: 15))
        XCTAssertNil(s.visible(CGRect(x: 0, y: 600, width: 340, height: 15)), "above")
        var top = s
        _ = top.scroll(deltaY: 657)
        XCTAssertEqual(top.visible(CGRect(x: 0, y: 230, width: 340, height: 15)), CGRect(x: 0, y: 230, width: 340, height: 10), "cut at the bottom")
        XCTAssertNil(top.visible(CGRect(x: 0, y: 240, width: 340, height: 15)), "below")
    }
}
