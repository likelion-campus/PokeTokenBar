import XCTest
@testable import PokeTokenBar

/// Timers a test drives by hand, one per interval (the indicator has a hold timer and a fade timer).
@MainActor final class ManualTimers {
    private(set) var fires: [TimeInterval: @MainActor () -> Bool] = [:]
    private(set) var started: [TimeInterval: Int] = [:]
    func schedule(_ interval: TimeInterval, _ f: @escaping @MainActor () -> Bool) -> PlazaAnimationClock.Stop {
        started[interval, default: 0] += 1
        fires[interval] = f
        return { [weak self] in MainActor.assumeIsolated { _ = self?.fires.removeValue(forKey: interval) } }
    }
    func beat(_ interval: TimeInterval) { _ = fires[interval]?() }
    var running: [TimeInterval] { fires.keys.sorted() }
}

/// The scroll indicator (Track A Task 17w): the overlay scroller the Mac's SwiftUI scroll views showed, drawn by the shared
/// panels. Stub graphics, so it runs on Windows too.
@MainActor final class PlazaScrollIndicatorTests: XCTestCase {
    private func flush() async { for _ in 0..<20 { await Task.yield() } }
    private let hold = PlazaScrollIndicator.holdSeconds, fade = PlazaScrollIndicator.fadeBeat

    private func state(content: CGFloat, viewport: CGFloat, offset: CGFloat) -> PlazaScrollState {
        var s = PlazaScrollState()
        s.setMetrics(content: content, viewport: viewport)
        _ = s.scroll(deltaY: -offset)
        return s
    }
    private let window = CGRect(x: 10, y: 24, width: 340, height: 240)

    // MARK: geometry

    func testThumbLengthIsTheWindowsShareOfTheContentWithAMinimum() async {
        let i = PlazaScrollIndicator()
        let half = i.thumb(state: state(content: 480, viewport: 240, offset: 0), offset: 0, viewport: window, scale: 2)
        XCTAssertEqual(half?.height, 120)
        let tiny = i.thumb(state: state(content: 24000, viewport: 240, offset: 0), offset: 0, viewport: window, scale: 2)
        XCTAssertEqual(tiny?.height, PlazaScrollIndicator.minLength, "never shorter than the minimum")
        XCTAssertEqual(half?.width, PlazaScrollIndicator.width)
        XCTAssertEqual(half?.maxX, window.maxX - PlazaScrollIndicator.inset, "on the trailing edge, over the content")
    }

    func testThumbPositionFollowsTheOffsetFromTopToBottom() async {
        let i = PlazaScrollIndicator()
        let top = i.thumb(state: state(content: 480, viewport: 240, offset: 0), offset: 0, viewport: window, scale: 2)
        let middle = i.thumb(state: state(content: 480, viewport: 240, offset: 120), offset: 120, viewport: window, scale: 2)
        let bottom = i.thumb(state: state(content: 480, viewport: 240, offset: 240), offset: 240, viewport: window, scale: 2)
        XCTAssertEqual(top?.minY, window.minY)
        XCTAssertEqual(middle?.minY, window.minY + 60)
        XCTAssertEqual(bottom?.maxY, window.maxY, "at the end the thumb meets the window's end")
    }

    func testNoThumbWhileTheContentFits() async {
        let i = PlazaScrollIndicator()
        XCTAssertNil(i.thumb(state: state(content: 200, viewport: 240, offset: 0), offset: 0, viewport: window, scale: 2))
        XCTAssertNil(i.thumb(state: state(content: 240, viewport: 240, offset: 0), offset: 0, viewport: window, scale: 2))
        XCTAssertNil(i.thumb(state: PlazaScrollState(), offset: 0, viewport: window, scale: 2))
    }

    // MARK: time

    func testItAppearsOnAScrollHoldsThenFadesAndTheTimersEnd() async {
        let t = ManualTimers()
        let i = PlazaScrollIndicator(schedule: { t.schedule($0, $1) })
        var changes = 0
        i.onChange = { changes += 1 }
        XCTAssertEqual(i.opacity, 0)
        XCTAssertTrue(t.running.isEmpty, "idle: no timer at all")
        i.scrolled()
        XCTAssertEqual(i.opacity, 1)
        XCTAssertEqual(t.running, [hold], "the pause is one one-shot timer; no fade timer yet")
        XCTAssertEqual(changes, 0, "no render of its own while it holds")
        t.beat(hold)
        XCTAssertEqual(t.running, [fade], "the pause is over: the fade timer runs, the hold timer is gone")
        t.beat(fade)
        XCTAssertLessThan(i.opacity, 1)
        XCTAssertGreaterThan(i.opacity, 0)
        XCTAssertEqual(changes, 1, "one render per fade beat")
        for _ in 0..<20 { t.beat(fade) }
        XCTAssertEqual(i.opacity, 0)
        XCTAssertTrue(t.running.isEmpty, "faded out: nothing runs")
        XCTAssertLessThanOrEqual(changes, Int((PlazaScrollIndicator.fadeSeconds / fade).rounded(.up)) + 1, "the fade is about 12 renders, not more")
    }

    func testAScrollDuringTheFadeBringsItBack() async {
        let t = ManualTimers()
        let i = PlazaScrollIndicator(schedule: { t.schedule($0, $1) })
        i.scrolled(); t.beat(hold); t.beat(fade); t.beat(fade)
        XCTAssertLessThan(i.opacity, 1)
        i.scrolled()
        XCTAssertEqual(i.opacity, 1)
        XCTAssertEqual(t.running, [hold], "the fade timer stopped, the pause starts over")
    }

    func testAlwaysShowingStaysAndRunsNothing() async {
        let t = ManualTimers()
        let i = PlazaScrollIndicator(schedule: { t.schedule($0, $1) })
        i.alwaysVisible = true
        i.scrolled()
        XCTAssertTrue(t.running.isEmpty)
        let g = PlazaStubGraphics(log: { _ in })
        let layers = i.layers(state: state(content: 480, viewport: 240, offset: 0), offset: 0, viewport: window, scale: 2, graphics: g)
        XCTAssertEqual(layers.count, 7, "the legacy track (strip and its line), two ends and a middle of an edge, the knob and an edge")
        i.alwaysVisible = false
        XCTAssertEqual(i.layers(state: state(content: 480, viewport: 240, offset: 0), offset: 0, viewport: window, scale: 2, graphics: g).count, 0,
                       "back to the overlay style: nothing until a scroll")
    }

    func testTheThumbIsASolidMiddleBetweenTwoCachedEndsAndFadesWithTheOpacity() async {
        let t = ManualTimers()
        let i = PlazaScrollIndicator(schedule: { t.schedule($0, $1) })
        let g = PlazaStubGraphics(log: { _ in })
        i.scrolled()
        let s = state(content: 480, viewport: 240, offset: 60)
        let full = i.layers(state: s, offset: 60, viewport: window, scale: 2, graphics: g)
        guard full.count == 5, case .image(let topA, let topFrame) = full[0], case .color(_, let edgeFrame) = full[1], case .color(let tint, let mid) = full[2], case .image(let bottomA, let bottomFrame) = full[4] else {
            return XCTFail("expected end, middle, end: \(full)")
        }
        XCTAssertEqual(topFrame.maxY, edgeFrame.minY)
        XCTAssertEqual(mid.minX, edgeFrame.maxX, "the knob sits inside its edge")
        XCTAssertEqual(mid.maxY, bottomFrame.minY)
        XCTAssertEqual(tint.alpha, PlazaScrollIndicator.strength, accuracy: 0.001)
        let again = i.layers(state: s, offset: 60, viewport: window, scale: 2, graphics: g)
        guard case .image(let topB, _) = again[0], case .image(let bottomB, _) = again[4] else { return XCTFail() }
        XCTAssertTrue(topA === topB && bottomA === bottomB, "a scroll step reuses the cached ends (no bitmap per step)")
        t.beat(hold); t.beat(fade); t.beat(fade); t.beat(fade)
        let faded = i.layers(state: s, offset: 60, viewport: window, scale: 2, graphics: g)
        guard case .color(let dim, _) = faded[2] else { return XCTFail() }
        XCTAssertLessThan(dim.alpha, tint.alpha)
        for _ in 0..<20 { t.beat(fade) }
        XCTAssertTrue(i.layers(state: s, offset: 60, viewport: window, scale: 2, graphics: g).isEmpty, "faded out: no layers")
    }

    func testTheKnobIsLightInTheDarkAppearance() async {
        let i = PlazaScrollIndicator()
        i.alwaysVisible = true
        let g = PlazaStubGraphics(log: { _ in })
        let s = state(content: 480, viewport: 240, offset: 0)
        guard case .color(let dark, _) = i.layers(state: s, offset: 0, viewport: window, scale: 1, graphics: g)[4] else { return XCTFail() }
        i.isDark = true
        guard case .color(let light, _) = i.layers(state: s, offset: 0, viewport: window, scale: 1, graphics: g)[4] else { return XCTFail() }
        XCTAssertEqual(dark.red, 0); XCTAssertEqual(light.red, 1)
    }

    // MARK: through the panels

    func testAScrollingChatLogShowsTheThumbAndAFoldedOneDoesNot() async {
        let log = PlazaChatLog()
        for n in 0..<50 { log.append(time: Date(), name: "나", text: "줄 \(n)", color: PlazaNameColor.palette[0]) }
        log.isExpanded = true
        let panel = PlazaChatLogPanel(log: log)
        let g = PlazaStubGraphics(log: { _ in })
        let size = CGSize(width: 960, height: 640)
        func thumbLayers() -> Int { panel.render(scale: 2, viewport: size, graphics: g).layers.filter { if case .color = $0 { true } else { false } }.count }
        XCTAssertEqual(thumbLayers(), 3, "opening scrolls to the end: the scroller flashes, as SwiftUI's did")
        panel.scrollIndicator.reset()
        XCTAssertEqual(thumbLayers(), 0, "after the fade nothing shows")
        panel.scrollIndicator.alwaysVisible = true
        XCTAssertEqual(thumbLayers(), 5, "always show scroll bars: it stays")
        log.isExpanded = false
        XCTAssertEqual(thumbLayers(), 0, "a folded log fits: no thumb")
    }
}
