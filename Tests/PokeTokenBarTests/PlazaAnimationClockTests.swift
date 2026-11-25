import XCTest
@testable import PokeTokenBar

/// The panel's animation clock (Track A Task 17c) and the roster's bouncing icons on it: the timer exists only while an
/// icon bounces and the plaza shows, one render per beat, none when nothing animates or the plaza is hidden.
@MainActor final class PlazaAnimationClockTests: XCTestCase {
    private func flush() async { for _ in 0..<20 { await Task.yield() } }

    func testTheClockIsATimerOnlyWhileItRuns() async {
        let beat = ManualBeat()
        var ticks = 0
        let clock = PlazaAnimationClock(interval: 0.5, schedule: { beat.schedule($0, $1) })
        clock.onTick = { ticks += 1 }
        XCTAssertFalse(clock.isRunning)
        XCTAssertEqual(beat.started, 0, "nothing scheduled until it is wanted")
        clock.setRunning(true)
        clock.setRunning(true)
        XCTAssertEqual(beat.started, 1, "starting twice is one timer")
        beat.beat(); beat.beat()
        XCTAssertEqual(ticks, 2)
        XCTAssertEqual(clock.beats, 2)
        clock.setRunning(false)
        XCTAssertEqual(beat.stopped, 1)
        XCTAssertFalse(beat.isScheduled)
        clock.setRunning(false)
        XCTAssertEqual(beat.stopped, 1, "stopping twice ends nothing more")
        clock.setRunning(true)
        XCTAssertEqual(clock.beats, 0, "a new start begins the count again")
    }

    func testAClockThatIsGoneEndsItsTimer() async {
        let beat = ManualBeat()
        var clock: PlazaAnimationClock? = PlazaAnimationClock(interval: 0.5, schedule: { beat.schedule($0, $1) })
        clock?.setRunning(true)
        clock = nil
        // The timer's callback finds the clock gone and says so; the real timer then invalidates itself.
        XCTAssertTrue(beat.isScheduled)
        let fired = beat.fireForTesting()
        XCTAssertEqual(fired, false)
    }

    func testTheRealTimerBeatsAndStops() async throws {
        let clock = PlazaAnimationClock(interval: 0.05)
        var ticks = 0
        clock.onTick = { ticks += 1 }
        clock.setRunning(true)
        // Wait for two beats (up to 10 s) instead of counting a fixed 380 ms, which a late timer empties. The interval bounds the
        // count from above: a timer cannot beat faster than it was asked to.
        let started = ContinuousClock.now
        while ticks < 2, ContinuousClock.now - started < .seconds(10) { try await Task.sleep(for: .milliseconds(10)) }
        clock.setRunning(false)
        let seen = ticks
        let elapsed = (ContinuousClock.now - started).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        XCTAssertGreaterThanOrEqual(seen, 2, "it beats while running")
        XCTAssertLessThanOrEqual(Double(seen), seconds / 0.05 + 1, "and no faster than its interval")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(ticks, seen, "stopped: no more beats")
    }

    // MARK: the roster's icons

    private func entry(_ n: Int, _ presence: PlazaPresence = .online) -> PlazaRosterEntry {
        PlazaRosterEntry(id: "m\(n)", nickname: "친구\(n)", speciesID: 25, speciesName: "피카츄", gender: nil, isShiny: false, presence: presence, isMe: false)
    }

    private struct Rig {
        let model: PlazaRosterModel, panel: PlazaRosterPanel, hud: PlazaHUD, host: RecordingPanelHost, graphics: CanvasKeepingGraphics, beat: ManualBeat
        func iconTops() -> [String] {
            (graphics.canvases.last?.calls ?? []).filter { $0.hasPrefix("image 40x30") }.map { String($0.split(separator: "(").last ?? "") }
        }
    }

    private func rig(_ entries: [PlazaRosterEntry], animating: Bool = true) -> Rig {
        let model = PlazaRosterModel()
        model.entries = entries
        model.isAnimating = animating
        let icons = FakeIcons()
        icons.have[25] = samplePicture()
        let beat = ManualBeat()
        let panel = PlazaRosterPanel(model: model, icons: icons, clock: PlazaAnimationClock(interval: 0.5, schedule: { beat.schedule($0, $1) }))
        let graphics = CanvasKeepingGraphics()
        let hud = PlazaHUD(panels: [panel], graphics: graphics)
        let host = RecordingPanelHost()
        hud.setViewport(CGSize(width: 960, height: 640), scale: 2)
        hud.host = host
        return Rig(model: model, panel: panel, hud: hud, host: host, graphics: graphics, beat: beat)
    }

    func testAnOnlineIconBouncesTwoPointsEveryOtherBeatAndEachBeatIsOneRender() async {
        let r = rig([entry(0)])
        await flush()
        XCTAssertTrue(r.panel.isAnimating)
        let base = r.hud.renderCounts[.roster] ?? 0
        var tops: [String] = [r.iconTops().last ?? ""]
        for _ in 0..<4 {
            r.beat.beat()
            await flush()
            tops.append(r.iconTops().last ?? "")
        }
        XCTAssertEqual((r.hud.renderCounts[.roster] ?? 0) - base, 4, "one render per beat: two a second")
        // The icon's rect: y (canvas, up) is 2 higher on the odd beats.
        func y(_ s: String) -> Double { Double(s.split(separator: ",")[1].trimmingCharacters(in: .whitespaces)) ?? -1 }
        XCTAssertEqual(y(tops[1]) - y(tops[0]), 2, accuracy: 0.001)
        XCTAssertEqual(y(tops[2]), y(tops[0]), accuracy: 0.001)
        XCTAssertEqual(y(tops[3]) - y(tops[0]), 2, accuracy: 0.001)
        XCTAssertEqual(y(tops[4]), y(tops[0]), accuracy: 0.001)
    }

    func testNoTimerWhenNothingBouncesOrThePlazaIsHidden() async {
        // Idle, asleep: nothing bounces. Online while the plaza is hidden (the model's flag): nothing bounces.
        for entries in [[entry(0, .idle), entry(1, .asleep)], []] {
            let r = rig(entries)
            await flush()
            XCTAssertFalse(r.panel.isAnimating)
            XCTAssertEqual(r.beat.started, 0, "no timer made at all")
        }
        let hidden = rig([entry(0)], animating: false)
        await flush()
        XCTAssertEqual(hidden.beat.started, 0)
        let counts = hidden.hud.renderCounts[.roster]
        for _ in 0..<500 { await Task.yield() }
        XCTAssertEqual(hidden.hud.renderCounts[.roster], counts, "idle visible with nothing animating: zero renders")
    }

    func testTheTimerEndsWhenThePlazaHidesAndWhenTheLastBouncerLeaves() async {
        let r = rig([entry(0), entry(1, .idle)])
        await flush()
        XCTAssertEqual(r.beat.started, 1)
        r.model.isAnimating = false          // the controller's setRendering(visible: false)
        await flush()
        XCTAssertFalse(r.panel.isAnimating)
        XCTAssertEqual(r.beat.stopped, 1)
        r.model.isAnimating = true
        await flush()
        XCTAssertEqual(r.beat.started, 2, "back: the clock runs again")
        r.model.entries = [entry(1, .idle)]  // the bouncing member left
        await flush()
        XCTAssertFalse(r.panel.isAnimating)
        XCTAssertEqual(r.beat.stopped, 2)
    }

    func testABeatNobodyDrewEndsTheClock() async {
        // The HUD stops rendering (the window closed or hid without the model hearing of it): the next beat finds nothing
        // drawn since the last one and ends the timer, so a forgotten roster costs one wake-up, not one every half second.
        let r = rig([entry(0)])
        await flush()
        r.hud.isRendering = false
        r.beat.beat()                       // marked, not drawn
        await flush()
        XCTAssertTrue(r.panel.isAnimating, "one beat is let through")
        let count = r.hud.renderCounts[.roster] ?? 0
        r.beat.beat()                       // still nothing drawn since: ends
        await flush()
        XCTAssertFalse(r.panel.isAnimating)
        XCTAssertEqual(r.beat.stopped, 1)
        XCTAssertEqual(r.hud.renderCounts[.roster] ?? 0, count, "hidden: not one render")
        r.hud.isRendering = true            // the plaza shows again: it draws what changed, and the clock runs again
        await flush()
        XCTAssertGreaterThan(r.hud.renderCounts[.roster] ?? 0, count)
        XCTAssertTrue(r.panel.isAnimating)
        XCTAssertEqual(r.beat.started, 2)
    }

    func testANewBouncerStartsDownEvenWhileTheOthersAreUp() async {
        let r = rig([entry(0)])
        await flush()
        r.beat.beat()
        await flush()                         // member 0 is up (beat 1)
        r.model.entries = [entry(0), entry(1)]
        await flush()
        let tops = r.iconTops()
        XCTAssertEqual(tops.count, 2)
        func y(_ s: String) -> Double { Double(s.split(separator: ",")[1].trimmingCharacters(in: .whitespaces)) ?? -1 }
        // Slot 0 is the first slot (higher up on screen = larger canvas y), slot 1 the second; the new icon is at its rest place.
        let slotPitch = 48.0 * 2   // device pixels? the canvas is in points: 44 + 4
        _ = slotPitch
        XCTAssertEqual(y(tops[0]) - y(tops[1]), 48 + 2, accuracy: 0.001, "slot 0 is 2 up, slot 1 at rest")
    }
}

extension ManualBeat {
    /// Fires the timer's callback by hand and says whether the clock wants more beats.
    @MainActor func fireForTesting() -> Bool? { fireValue() }
}
