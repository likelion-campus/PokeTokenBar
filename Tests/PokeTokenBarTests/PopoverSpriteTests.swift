import Foundation
import XCTest
@testable import PokeTokenBar

/// Stage 7 Task 8, shared (both systems): the popover sprite's frame-selection rules, the load state machine with its
/// cancellation guard, the animation clock and the due times across slots. The Mac twins' equivalence is in
/// `PopoverTwinEquivalenceTests+Mac`.

private actor Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        if released { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            if released { c.resume() } else { continuation = c }
        }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private func picture(_ side: Int = 2) -> PlazaImage { PlazaImage(bitmap: PlazaBitmap(width: side, height: side)) }

/// A fetcher with no network: species with a GIF (delays per species), species with only a still, gates to hold a load.
private final class FakeFetcher: PlazaSpriteFetching, @unchecked Sendable {
    private let lock = NSLock()
    var delays: [Int: [TimeInterval]] = [:]
    var stills: Set<Int> = []
    var gates: [Int: Gate] = [:]
    var eggGate: Gate?
    private var asks: [String] = []
    var calls: [String] { lock.lock(); defer { lock.unlock() }; return asks }
    private func note(_ s: String) { lock.lock(); asks.append(s); lock.unlock() }

    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: PlazaImage, delay: TimeInterval)] {
        note("animated \(speciesID)\(back ? " back" : "")")
        if let gate = gates[speciesID] { await gate.wait() }
        return back ? [] : (delays[speciesID] ?? []).map { (picture(), $0) }   // no back sprites in the fake
    }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> PlazaImage? {
        note("still \(speciesID)\(back ? " back" : "")")
        if let gate = gates[speciesID] { await gate.wait() }
        return !back && stills.contains(speciesID) ? picture() : nil
    }
    func egg() async -> PlazaImage? {
        note("egg")
        if let eggGate { await eggGate.wait() }
        return picture(3)
    }
}

@MainActor
private func settle(_ what: String = "", until: () -> Bool) async {
    for _ in 0..<400 where !until() { await Task.yield(); try? await Task.sleep(nanoseconds: 1_000_000) }
    XCTAssertTrue(until(), "never settled: \(what)")
}

@MainActor
final class PopoverSpriteSubjectTests: XCTestCase {
    func testBecomingEggDropsThePreviousSpeciesPixels() async {
        let egg = picture(2)
        let next = PopoverSpriteSubject(image: picture(4), loadedID: 25).becomingEgg(cachedEgg: egg)
        XCTAssertTrue(next.image === egg)
        XCTAssertNil(next.loadedID)
        XCTAssertNil(PopoverSpriteSubject(image: picture(4), loadedID: 25).becomingEgg(cachedEgg: nil).image)
        let kept = picture(2)
        XCTAssertTrue(PopoverSpriteSubject(image: kept, loadedID: nil).becomingEgg(cachedEgg: nil).image === kept)
    }

    func testACancelledLoadChangesNothing() async {
        XCTAssertNil(PopoverSpriteSubject(image: nil, loadedID: nil).applyingLoad(picture(), for: 26, cancelled: true))
        XCTAssertNil(PopoverSpriteSubject(image: nil, loadedID: nil).applyingEgg(picture(), cancelled: true))
        XCTAssertEqual(PopoverSpriteSubject(image: nil, loadedID: nil).applyingLoad(nil, for: 26, cancelled: false)?.loadedID, 26,
                       "a failed load still marks the attempt")
        XCTAssertTrue(PopoverSpriteRules.framesToApply([(picture(), 0.1), (picture(), 0.1)], cancelled: true).isEmpty)
        XCTAssertTrue(PopoverSpriteRules.framesToApply([(picture(), 0.1)], cancelled: false).isEmpty)
        XCTAssertEqual(PopoverSpriteRules.framesToApply([(picture(), 0.1), (picture(), 0.1)], cancelled: false).count, 2)
    }

    func testReloadAndTaskIdentityFollowShinyFormAndBack() async {
        XCTAssertFalse(PopoverSpriteRules.needsReload(loadedID: 25, loadedShiny: false, id: 25, shiny: false))
        XCTAssertTrue(PopoverSpriteRules.needsReload(loadedID: 25, loadedShiny: false, id: 25, shiny: true))
        XCTAssertTrue(PopoverSpriteRules.needsReload(loadedID: 25, loadedShiny: false, id: 25, shiny: false, loadedBack: false, back: true))
        XCTAssertTrue(PopoverSpriteRules.needsReload(loadedID: nil, loadedShiny: false, id: 25, shiny: false))
        let a = PopoverSpriteRules.frameTaskID(speciesID: 25, shiny: false, floor: 0)
        XCTAssertNotEqual(a, PopoverSpriteRules.frameTaskID(speciesID: 25, shiny: true, floor: 0))
        XCTAssertNotEqual(a, PopoverSpriteRules.frameTaskID(speciesID: 25, shiny: false, floor: 0, animated: false))
        XCTAssertTrue(PopoverSpriteRules.frameTaskID(speciesID: nil, shiny: false, floor: 0, back: true).hasSuffix("-back"))
    }

    func testFitKeepsTheAspect() async {
        XCTAssertEqual(PopoverSpriteFit.size(for: CGSize(width: 36, height: 66), box: 76).height, 76, accuracy: 0.001)
        XCTAssertEqual(PopoverSpriteFit.size(for: CGSize(width: 36, height: 66), box: 76).width, 76 * 36 / 66, accuracy: 0.001)
        XCTAssertEqual(PopoverSpriteFit.size(for: .zero, box: 50), CGSize(width: 50, height: 50))
    }
}

@MainActor
final class PopoverSpriteModelTests: XCTestCase {
    private func model(_ fetcher: FakeFetcher, memory: PopoverSpriteMemory = PopoverSpriteMemory()) -> PopoverSpriteModel {
        PopoverSpriteModel(fetcher: fetcher, memory: memory)
    }
    private func species(_ id: Int) -> PlazaSpriteSubjectKey { PlazaSpriteSubjectKey(speciesID: id) }

    func testAnAnimatedSpeciesGetsItsFramesAndTheirDelays() async {
        let f = FakeFetcher(); f.delays[25] = [0.05, 0.1, 0.25]
        let m = model(f)
        m.show(species(25), animated: true, bob: false)
        await settle("frames") { m.frames.count == 3 }
        XCTAssertEqual(m.frames.map(\.delay), [0.05, 0.1, 0.25])
        XCTAssertTrue(m.isAnimating)
    }

    func testNoGIFFallsBackToTheStill() async {
        let f = FakeFetcher(); f.stills = [25]
        let m = model(f)
        m.show(species(25), animated: true, bob: true)
        await settle("still") { m.subject.image != nil }
        XCTAssertTrue(m.frames.isEmpty)
        XCTAssertFalse(m.isAnimating)
        XCTAssertEqual(f.calls, ["animated 25", "still 25"])
    }

    func testAMissingBackSpriteStandsTheFrontIn() async {
        let f = FakeFetcher(); f.delays[25] = [0.1, 0.1]
        let m = model(f)
        m.show(PlazaSpriteSubjectKey(speciesID: 25, back: true), animated: true, bob: false)
        await settle("front stands in") { m.frames.count == 2 }
        XCTAssertEqual(f.calls, ["animated 25 back", "animated 25"])
    }

    /// The load of a species that finishes after the subject became an egg must not show the species.
    func testALateSpeciesLoadNeverPaintsOverTheEgg() async {
        let f = FakeFetcher(); f.delays[25] = [0.1, 0.1]; f.stills = [25]
        let gate = Gate(); f.gates[25] = gate
        let m = model(f)
        m.show(species(25), animated: true, bob: false)
        await settle("species load started") { f.calls.contains("animated 25") }
        m.show(PlazaSpriteSubjectKey(speciesID: nil), animated: true, bob: false)
        await settle("egg shown") { m.subject.image != nil }
        let egg = m.subject.image
        await gate.release()
        for _ in 0..<30 { await Task.yield(); try? await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(m.frames.isEmpty, "the old species' frames came back over the egg")
        XCTAssertTrue(m.subject.image === egg)
        XCTAssertNil(m.subject.loadedID)
    }

    /// egg -> species -> egg: after the last egg, no pixel of the species is shown even when its load finishes last.
    func testEggSpeciesEggNeverShowsTheOldSpecies() async {
        let f = FakeFetcher(); f.stills = [7]; f.delays[7] = [0.1, 0.1]
        let gate = Gate(); f.gates[7] = gate
        let m = model(f)
        let egg = PlazaSpriteSubjectKey(speciesID: nil)
        m.show(egg, animated: true, bob: false)
        await settle("first egg") { m.subject.image != nil }
        m.show(species(7), animated: true, bob: false)
        await settle("species asked") { f.calls.contains("animated 7") }
        m.show(egg, animated: true, bob: false)
        await gate.release()
        for _ in 0..<30 { await Task.yield(); try? await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(m.frames.isEmpty)
        XCTAssertNil(m.subject.loadedID)
        XCTAssertEqual(m.subject.image?.width, 3, "the egg's own picture")
    }

    func testALoadFinishingAfterReleasePaintsNothing() async {
        let f = FakeFetcher(); f.delays[25] = [0.1, 0.1]
        let gate = Gate(); f.gates[25] = gate
        let m = model(f)
        var changes = 0
        m.onChange = { changes += 1 }
        m.show(species(25), animated: true, bob: false)
        await settle("asked") { f.calls.contains("animated 25") }
        m.release()
        await gate.release()
        for _ in 0..<30 { await Task.yield(); try? await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(m.frames.isEmpty)
        XCTAssertEqual(changes, 0)
        XCTAssertNil(m.nextDue)
    }

    func testTheSameSubjectDoesNotReloadAndShinyDoes() async {
        let f = FakeFetcher(); f.delays[25] = [0.1, 0.1]
        let m = model(f)
        m.show(species(25), animated: true, bob: false)
        await settle("frames") { m.frames.count == 2 }
        let asks = f.calls.count
        m.show(species(25), animated: true, bob: false)
        XCTAssertEqual(f.calls.count, asks)
        m.show(PlazaSpriteSubjectKey(speciesID: 25, shiny: true), animated: true, bob: false)
        XCTAssertTrue(m.frames.isEmpty || m.frames.count == 2)
        await settle("shiny asked") { f.calls.count > asks || !m.frames.isEmpty }
    }

    /// 50 subject changes keep both caches under their bounds.
    func testTheCachesStayBoundedOverManySubjectChanges() async {
        let f = FakeFetcher()
        for id in 1...50 { f.delays[id] = [0.1, 0.1] }
        for id in 51...100 { f.stills.insert(id) }
        let memory = PopoverSpriteMemory()
        let m = model(f, memory: memory)
        for id in 1...100 {
            m.show(species(id), animated: id <= 50, bob: false)
            await settle("loaded \(id)") { m.current != nil }
        }
        XCTAssertLessThanOrEqual(memory.frameSetCount, PopoverSpriteMemory.frameSets)
        XCTAssertLessThanOrEqual(memory.stillCount, PopoverSpriteMemory.stills)
        m.release()
        memory.release()
        XCTAssertEqual(memory.frameSetCount + memory.stillCount, 0)
    }

    /// The bob follows the Mac's `.easeInOut(duration: 0.9).repeatForever(autoreverses: true)` up 3 DIP and back, one wake per
    /// device-pixel step (stage 7 Task 9): 3 steps at 100 % (six wakes a round trip of 1.8 s), 6 at 200 %. Ticks a hair early
    /// (inside the clock's slack) still move it on.
    func testABobbingStillStepsAlongTheMacsEasedSwing() async {
        for (steps, expected) in [(3, [1, 2, 3, 2, 1, 0]), (6, [1, 2, 3, 4, 5, 6, 5, 4, 3, 2, 1, 0])] {
            let f = FakeFetcher(); f.stills = [25]
            let start = Date(timeIntervalSince1970: 1000)
            var time = start
            let m = PopoverSpriteModel(fetcher: f, memory: PopoverSpriteMemory(), now: { time })
            m.bobSteps = steps
            m.setPlaying(true)
            m.show(species(25), animated: false, bob: true)
            var levels: [Int] = []
            var top: CGFloat = 0
            while let due = m.nextDue, due.timeIntervalSince(start) < 1.8 + 1e-3, levels.count < 50 {
                time = due.addingTimeInterval(-0.0003)
                XCTAssertTrue(m.tick(at: time), "steps \(steps)")
                XCTAssertGreaterThan(m.nextDue ?? .distantPast, due, "steps \(steps): the clock moves on")
                levels.append(m.bobLevel)
                top = min(top, m.bobOffset)
            }
            XCTAssertEqual(levels, expected)
            XCTAssertEqual(top, -3)
            m.setPlaying(false)
            XCTAssertNil(m.nextDue)
            XCTAssertFalse(m.bobUp)
        }
    }
}

@MainActor
final class PopoverAnimationClockTests: XCTestCase {
    private final class Scheduler {
        var dues: [Date] = []
        var fires: [@MainActor () -> Void] = []
        var live = 0
        func schedule(_ due: Date, _ fire: @escaping @MainActor () -> Void) -> PopoverAnimationClock.Stop {
            dues.append(due); live += 1
            let index = fires.count
            fires.append(fire)
            var stopped = false
            return { if !stopped { stopped = true; self.live -= 1 }; _ = index }
        }
    }

    func testOneTimerAtMost() async {
        let s = Scheduler()
        let clock = PopoverAnimationClock(schedule: s.schedule)
        let t = Date(timeIntervalSince1970: 5)
        clock.setDue(t)
        clock.setDue(t)
        XCTAssertEqual(s.dues, [t], "the same due date does not re-arm")
        clock.setDue(t.addingTimeInterval(1))
        XCTAssertEqual(s.live, 1, "re-arming cancels the earlier timer")
        clock.setDue(nil)
        XCTAssertEqual(s.live, 0)
        XCTAssertFalse(clock.isArmed)
    }

    func testAFireClearsTheTimerAndTicksOnce() async {
        let s = Scheduler()
        let clock = PopoverAnimationClock(schedule: s.schedule)
        var ticks = 0
        clock.onTick = { ticks += 1 }
        clock.setDue(Date(timeIntervalSince1970: 5))
        s.fires[0]()
        XCTAssertEqual(ticks, 1)
        XCTAssertFalse(clock.isArmed, "no timer until the owner asks for the next one")
    }
}

@MainActor
final class PopoverSpritePlaybackTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 10_000)

    private final class Sched {
        var due: Date?
        var fire: (@MainActor () -> Void)?
        func schedule(_ d: Date, _ f: @escaping @MainActor () -> Void) -> PopoverAnimationClock.Stop {
            due = d; fire = f
            return { [weak self] in self?.due = nil; self?.fire = nil }
        }
    }

    private func slot(_ id: Int, animated: Bool = true, bob: Bool = false) -> SpriteSlot {
        SpriteSlot(frame: CGRect(x: 0, y: 0, width: 76, height: 76), subject: PlazaSpriteSubjectKey(speciesID: id), bob: bob, animated: animated)
    }

    /// Three slots at 0.05 / 0.1 / 0.07 s: one timer, always armed for the earliest, ticks at the merged times.
    func testThreeSlotsTickAtTheMergedDueTimes() async {
        let f = FakeFetcher(); f.delays[1] = [0.05, 0.05]; f.delays[2] = [0.1, 0.1]; f.delays[3] = [0.07, 0.07]
        var time = t0
        let s = Sched()
        let p = PopoverSpritePlayback(fetcher: f, clock: PopoverAnimationClock(schedule: s.schedule), now: { time })
        var painted: [Int] = []
        p.onInvalidate = { painted.append($0) }
        p.isActive = true
        p.update(slots: [slot(1), slot(2), slot(3)])
        await settle("frames") { p.models.allSatisfy { $0.isAnimating } }
        // the loads armed the clock at time == t0 (the frame set arrived at t0)
        painted = []
        var at: [Double] = []
        var who: [[Int]] = []
        for _ in 0..<8 {
            guard let due = s.due else { XCTFail("timer missing"); break }
            time = due
            at.append((due.timeIntervalSince(t0) * 1000).rounded() / 1000)
            painted = []
            s.fire?()
            who.append(painted.sorted())
        }
        XCTAssertEqual(at, [0.05, 0.07, 0.1, 0.14, 0.15, 0.2, 0.21, 0.25])
        XCTAssertEqual(who, [[0], [2], [0, 1], [2], [0], [0, 1], [2], [0]])
        p.release()
        XCTAssertNil(s.due, "closed: no timer")
    }

    func testHiddenOrDisabledOrStillMeansNoTimer() async {
        let f = FakeFetcher(); f.delays[1] = [0.05, 0.05]; f.stills = [2]
        let s = Sched()
        let p = PopoverSpritePlayback(fetcher: f, clock: PopoverAnimationClock(schedule: s.schedule))
        p.update(slots: [slot(1), slot(2, animated: false)])
        await settle("loaded") { p.models[0].isAnimating && p.models[1].subject.image != nil }
        XCTAssertNil(s.due, "not shown: no timer")
        p.isActive = true
        XCTAssertNotNil(s.due)
        p.isActive = false
        XCTAssertNil(s.due, "hidden or scrolled out: the timer goes")
        p.isActive = true
        p.animationsEnabled = false
        XCTAssertNil(s.due, "animation off: the timer goes")
        await settle("still shown") { p.models[0].subject.image != nil || f.calls.contains("still 1") }
        p.release()

        let still = Sched()
        let q = PopoverSpritePlayback(fetcher: f, clock: PopoverAnimationClock(schedule: still.schedule))
        q.isActive = true
        q.update(slots: [slot(2, animated: false)])
        await settle("still") { q.models[0].subject.image != nil }
        XCTAssertNil(still.due, "a single still without bob: nothing to time")
        q.update(slots: [])
        XCTAssertNil(still.due)
        q.release()
    }

    func testAnEmptySlotListHasNoTimerAndReleaseStopsLateLoads() async {
        let f = FakeFetcher(); f.delays[1] = [0.05, 0.05]
        let gate = Gate(); f.gates[1] = gate
        let s = Sched()
        let p = PopoverSpritePlayback(fetcher: f, clock: PopoverAnimationClock(schedule: s.schedule))
        p.isActive = true
        p.update(slots: [slot(1)])
        await settle("asked") { f.calls.contains("animated 1") }
        var invalidated = 0
        p.onInvalidate = { _ in invalidated += 1 }
        p.release()
        await gate.release()
        for _ in 0..<30 { await Task.yield(); try? await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(invalidated, 0)
        XCTAssertNil(s.due)
    }
}
