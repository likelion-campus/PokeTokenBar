import Foundation
import XCTest
@testable import PokeTokenBar

/// Stage 7 Task 22, shared (both systems): the floating pet's rules: the placement (the Mac's rule and its y-down use on
/// Windows), the pointer, the clicks, the menu, what the pet shows, the saved home, and the frame cap through the sprite
/// playback. The Mac twins' equivalence is in `PopoverPetTwinEquivalenceTests+Mac`.
@MainActor
final class FloatingPetRulesTests: XCTestCase {
    // MARK: placement (the Mac's terms: y up)

    private let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let visible = CGRect(x: 0, y: 40, width: 1920, height: 1015)   // a Dock below, the menu bar above

    func testNoHomeIsTheDefaultCornerOfTheMainScreen() async {
        let t = FloatingPetPlacement.targetFrame(saved: nil, petSize: 96, showingBubble: false, visibleFrames: [visible], mainVisible: visible)
        XCTAssertEqual(t.frame, CGRect(x: 1920 - 96 - 24, y: 40 + 24, width: 96, height: 96))
        XCTAssertTrue(t.isDefault)
        XCTAssertEqual(FloatingPetPlacement.targetFrame(saved: nil, petSize: 96, showingBubble: false, visibleFrames: [], mainVisible: nil).frame.origin,
                       CGPoint(x: 120, y: 120), "no screen at all: the Mac's (120, 120)")
    }

    func testAHomeThatMeetsAWorkAreaIsKeptEvenPartlyOffScreen() async {
        let partly = CGPoint(x: 1900, y: 500)   // 76 of 96 points past the right edge
        let t = FloatingPetPlacement.targetFrame(saved: partly, petSize: 96, showingBubble: false, visibleFrames: [visible], mainVisible: visible)
        XCTAssertEqual(t.frame.origin, partly, "the Mac does not clamp a pet that still meets a screen")
        XCTAssertFalse(t.isDefault)
    }

    func testAHomeOnNoScreenGoesToTheDefaultCorner() async {
        let gone = CGPoint(x: 4000, y: 300)   // the monitor it stood on is gone
        let t = FloatingPetPlacement.targetFrame(saved: gone, petSize: 96, showingBubble: false, visibleFrames: [visible], mainVisible: visible)
        XCTAssertEqual(t.frame.origin, CGPoint(x: 1800, y: 64))
        XCTAssertTrue(t.isDefault)
        let underTheDock = CGPoint(x: 500, y: -60)   // all of it below the work area (behind the Dock)
        XCTAssertTrue(FloatingPetPlacement.targetFrame(saved: underTheDock, petSize: 96, showingBubble: false, visibleFrames: [visible], mainVisible: visible).isDefault)
    }

    func testTheAwaySpotWinsAndABubbleWidensTheWindowAroundThePet() async {
        let t = FloatingPetPlacement.targetFrame(away: CGPoint(x: 100, y: 100), saved: CGPoint(x: 900, y: 500), petSize: 96, showingBubble: true,
                                                 visibleFrames: [visible], mainVisible: visible)
        XCTAssertEqual(t.frame, CGRect(x: 100 - 42, y: 100, width: 180, height: 96 + 72))
        XCTAssertEqual(FloatingPetPlacement.savedPetOrigin(panelOrigin: t.frame.origin, petSize: 96, showingBubble: true), CGPoint(x: 100, y: 100))
    }

    func testTheDefaultCornerUsesTheMainScreensSize() async {
        let t = FloatingPetPlacement.targetFrame(saved: nil, petSize: 144, showingBubble: false, visibleFrames: [visible], mainVisible: visible, defaultPetSize: 96)
        XCTAssertEqual(t.frame.size, CGSize(width: 96, height: 96))
        XCTAssertEqual(t.frame.origin, CGPoint(x: 1800, y: 64))
    }

    // MARK: placement on a y-down screen space (Windows)

    private func screens(secondScale: CGFloat = 1.5) -> [FloatingPetScreen] {
        [FloatingPetScreen(bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080), work: CGRect(x: 0, y: 0, width: 1920, height: 1032), scale: 1, isPrimary: true),
         FloatingPetScreen(bounds: CGRect(x: 1920, y: -200, width: 2560, height: 1440), work: CGRect(x: 1920, y: -200, width: 2560, height: 1392),
                           scale: secondScale, isPrimary: false),
         FloatingPetScreen(bounds: CGRect(x: -1280, y: 100, width: 1280, height: 1024), work: CGRect(x: -1280, y: 100, width: 1280, height: 984), scale: 1.25, isPrimary: false)]
    }

    func testOnWindowsTheDefaultIsThePrimaryWorkAreasCornerAtItsScale() async throws {
        let f = try XCTUnwrap(FloatingPetPlacement.screenFrame(petSize: 96, saved: nil, screens: screens()))
        XCTAssertEqual(f.frame, CGRect(x: 1920 - 96 - 24, y: 1032 - 24 - 96, width: 96, height: 96))
        XCTAssertEqual(f.scale, 1)
        XCTAssertTrue(f.isDefault)
        XCTAssertEqual(f.savedOrigin, CGPoint(x: 1800, y: 1008), "the pet's bottom-left corner")
    }

    func testOnWindowsAPetIsSizedAtItsMonitorsScale() async throws {
        let on150 = try XCTUnwrap(FloatingPetPlacement.screenFrame(petSize: 96, saved: CGPoint(x: 2400, y: 600), screens: screens()))
        XCTAssertEqual(on150.frame, CGRect(x: 2400, y: 600 - 144, width: 144, height: 144))
        XCTAssertEqual(on150.scale, 1.5)
        XCTAssertFalse(on150.isDefault)
        let left = try XCTUnwrap(FloatingPetPlacement.screenFrame(petSize: 96, saved: CGPoint(x: -1000, y: 900), screens: screens()))
        XCTAssertEqual(left.frame, CGRect(x: -1000, y: 900 - 120, width: 120, height: 120), "negative coordinates, 125 %")
        let forced = try XCTUnwrap(FloatingPetPlacement.screenFrame(petSize: 96, saved: CGPoint(x: 2400, y: 600), screens: screens(), scale: 2))
        XCTAssertEqual(forced.frame.size, CGSize(width: 192, height: 192), "the window's own DPI when it has one")
    }

    func testOnWindowsAHomeOnAMonitorThatWentAwayGoesToThePrimary() async throws {
        let all = screens()
        let f = try XCTUnwrap(FloatingPetPlacement.screenFrame(petSize: 96, saved: CGPoint(x: 2400, y: 600), screens: [all[0], all[2]]))
        XCTAssertTrue(f.isDefault)
        XCTAssertEqual(f.frame, CGRect(x: 1800, y: 912, width: 96, height: 96))
        XCTAssertEqual(f.scale, 1)
        XCTAssertNil(FloatingPetPlacement.screenFrame(petSize: 96, saved: nil, screens: []))
    }

    func testOnWindowsAPetHalfOffItsMonitorStays() async throws {
        let f = try XCTUnwrap(FloatingPetPlacement.screenFrame(petSize: 96, saved: CGPoint(x: 1890, y: 500), screens: [screens()[0]]))
        XCTAssertEqual(f.frame.origin.x, 1890)
        XCTAssertFalse(f.isDefault)
        XCTAssertEqual(FloatingPetPlacement.nearest(CGPoint(x: 5000, y: 5000), in: screens().map(\.bounds)), 1)
        XCTAssertEqual(FloatingPetPlacement.nearest(CGPoint(x: 10, y: 10), in: screens().map(\.bounds)), 0)
        XCTAssertNil(FloatingPetPlacement.nearest(.zero, in: []))
    }

    // MARK: the saved home

    func testTheSavedHomeRoundTripsAndStartsEmpty() async {
        let d = TestDefaults.make(suite: "ptb.test.floatingpet.\(UUID().uuidString)")
        XCTAssertNil(FloatingPetOrigin.saved(in: d))
        FloatingPetOrigin.save(CGPoint(x: -1234, y: 987), in: d)
        XCTAssertEqual(FloatingPetOrigin.saved(in: d), CGPoint(x: -1234, y: 987))
        d.set(12, forKey: FloatingPetOrigin.originXKey)   // an integer written by hand still reads
        XCTAssertEqual(FloatingPetOrigin.saved(in: d)?.x, 12)
        d.removeObject(forKey: FloatingPetOrigin.originYKey)
        XCTAssertNil(FloatingPetOrigin.saved(in: d), "half a home is no home")
    }

    // MARK: the pointer (PetHostingView's mouse handlers)

    func testAPressWithinTheClickDistanceIsAClickAndAnythingFurtherIsADrag() async {
        var p = FloatingPetPointer()
        p.down(at: CGPoint(x: 100, y: 100), windowOrigin: CGPoint(x: 10, y: 10))
        XCTAssertEqual(p.drag(to: CGPoint(x: 102, y: 101)), CGPoint(x: 12, y: 11), "the window follows from the first move")
        XCTAssertFalse(p.isDragging)
        XCTAssertEqual(p.up(at: CGPoint(x: 102, y: 101), windowOrigin: CGPoint(x: 12, y: 11)), FloatingPetPointer.Release(click: true, moved: true))
        XCTAssertFalse(p.isPressed)

        p.down(at: CGPoint(x: 100, y: 100), windowOrigin: .zero)
        _ = p.drag(to: CGPoint(x: 104, y: 100))   // 4 pt: 16, not < 16
        XCTAssertTrue(p.isDragging)
        XCTAssertEqual(p.drag(to: CGPoint(x: 101, y: 100)), CGPoint(x: 1, y: 0))
        XCTAssertEqual(p.up(at: CGPoint(x: 101, y: 100), windowOrigin: CGPoint(x: 1, y: 0)), FloatingPetPointer.Release(click: false, moved: true),
                       "back inside the distance after a drag is still no click")

        p.down(at: .zero, windowOrigin: .zero)
        XCTAssertEqual(p.up(at: CGPoint(x: 1, y: 1), windowOrigin: .zero), FloatingPetPointer.Release(click: true, moved: false))
        XCTAssertNil(p.drag(to: .zero), "no press, no move")
        XCTAssertEqual(p.up(at: .zero, windowOrigin: .zero), FloatingPetPointer.Release(click: false, moved: false))
    }

    func testTheClickDistanceScalesAndACancelKeepsTheMove() async {
        var p = FloatingPetPointer()
        p.down(at: .zero, windowOrigin: .zero)
        _ = p.drag(to: CGPoint(x: 5, y: 0), thresholdSquared: 16 * 2.25)   // 5 px at 150 % is 3.3 DIP
        XCTAssertFalse(p.isDragging)
        XCTAssertEqual(p.cancel(windowOrigin: CGPoint(x: 5, y: 0)), FloatingPetPointer.Release(click: false, moved: true))
        XCTAssertFalse(p.isPressed)
    }

    // MARK: clicks, the menu, what the pet shows

    private func stores(_ sample: CompanionHeaderSample) async -> (UsageStore, CompanionStore, URL) {
        let d = TestDefaults.make(suite: "ptb.test.floatingpet.\(UUID().uuidString)")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-pet-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let store = UsageStore(providers: [], autoRefresh: false, defaults: d)
        let companion = await CompanionHeaderSamples.store(sample, language: .en, defaults: d, directory: dir)
        return (store, companion, dir)
    }

    func testAnEggClickPraysAndAHatchedClickAsksForThePopover() async {
        let (store, egg, _) = await stores(.eggIncubating)
        var asked: [FloatingPetActions.Opener] = []
        let a = FloatingPetActions(store: store, companion: egg, openPopover: { asked.append($0) })
        var bursts = 0
        a.spawnEmoji = { bursts += 1 }
        a.petClicked()
        a.petClicked()
        XCTAssertEqual(egg.state.eggPrayers?.count, 2)
        XCTAssertEqual(bursts, 2, "Task 23's burst seam is called per prayer")
        XCTAssertEqual(asked, [])
        a.perform(.open)
        XCTAssertEqual(asked, [.menu], "the menu's Open opens for an egg too")

        let (store2, mon, _) = await stores(.hatched)
        let b = FloatingPetActions(store: store2, companion: mon, openPopover: { asked.append($0) })
        b.petClicked()
        XCTAssertEqual(asked, [.menu, .click])
        XCTAssertNil(mon.state.eggPrayers, "a hatched pet is not prayed over")
    }

    func testTheMenuHidesAndTurnsTheBackViewAsTheMacsDoes() async {
        let (store, mon, _) = await stores(.hatched)
        store.floatingPetEnabled = true
        let a = FloatingPetActions(store: store, companion: mon, openPopover: { _ in })
        a.perform(.toggleBackView)
        XCTAssertTrue(store.alwaysFacesBack)
        XCTAssertEqual(FloatingPetMenu.entries(l: L(.ko), backViewOn: store.alwaysFacesBack).map(\.checked), [false, false, true])
        a.perform(.hide)
        XCTAssertFalse(store.floatingPetEnabled)
        let titles = FloatingPetMenu.entries(l: L(.ja), backViewOn: false).map(\.title)
        XCTAssertEqual(titles, [L(.ja).floatingPetMenuOpen, L(.ja).floatingPetMenuHide, L(.ja).backViewLabel])
        XCTAssertEqual(FloatingPetMenu.entries(l: L(.en), backViewOn: false).map(\.action), [.open, .hide, .toggleBackView])
    }

    func testTheModelFollowsTheSettingsTheSubjectAndTheDisplays() async {
        let (store, mon, _) = await stores(.hatched)
        var m = FloatingPetModel.make(store: store, companion: mon, displayAwake: true, lowPower: false)
        XCTAssertFalse(m.visible, "off by default")
        store.floatingPetEnabled = true
        store.floatingPetSize = 144
        store.animationQuality = .smooth
        m = FloatingPetModel.make(store: store, companion: mon, displayAwake: true, lowPower: false)
        XCTAssertEqual(m, FloatingPetModel(visible: true, petSize: 144, subject: PlazaSpriteSubjectKey(speciesID: 1), animated: true, frameFloor: 0.1))
        XCTAssertFalse(m.subjectIsEgg)
        XCTAssertFalse(FloatingPetModel.make(store: store, companion: mon, displayAwake: false, lowPower: false).visible, "displays asleep: hidden")
        XCTAssertFalse(FloatingPetModel.make(store: store, companion: mon, displayAwake: true, lowPower: true).animated, "battery saver: the still")
        mon.alwaysFacesBack = true
        XCTAssertTrue(FloatingPetModel.make(store: store, companion: mon, displayAwake: true, lowPower: false).subject.back)
        let (_, egg, _) = await stores(.eggIncubating)
        XCTAssertTrue(FloatingPetModel.make(store: store, companion: egg, displayAwake: true, lowPower: false).subjectIsEgg)
        let (_, shiny, _) = await stores(.shiny)
        XCTAssertEqual(FloatingPetModel.make(store: store, companion: shiny, displayAwake: true, lowPower: false).subject, PlazaSpriteSubjectKey(speciesID: 4, shiny: true))
    }

    // MARK: the frame cap

    private func picture() -> PlazaImage { PlazaImage(bitmap: PlazaBitmap(width: 1, height: 1)) }

    func testTheCapDecimatesAndKeepsTheLoopsLength() async {
        let frames = (0..<55).map { _ in (image: picture(), delay: 0.05) }   // a Gen-V sprite: 2.75 s at 20 fps
        let capped = PopoverSpriteFrameCap.capFrameRate(frames, floor: 0.4)
        XCTAssertEqual(capped.count, 6)
        XCTAssertEqual(capped.map(\.delay).reduce(0, +), 2.75, accuracy: 1e-9, "the same speed")
        XCTAssertTrue(capped.dropLast().allSatisfy { abs($0.delay - 0.4) < 1e-9 })
        XCTAssertEqual(capped.last?.delay ?? 0, 0.75, accuracy: 1e-9, "a short last run joins the frame before it")
        XCTAssertTrue(capped[1].image === frames[8].image, "a run shows its first frame")
        XCTAssertEqual(PopoverSpriteFrameCap.capFrameRate(frames, floor: 0).count, 55, "no floor: as it is")
        XCTAssertEqual(PopoverSpriteFrameCap.capFrameRate(Array(frames.prefix(1)), floor: 0.4).count, 1)
        let three = PopoverSpriteFrameCap.capFrameRate(Array(frames.prefix(3)), floor: 0.4)
        XCTAssertEqual(three.count, 1)
        XCTAssertEqual(three.first?.delay ?? 0, 0.15, accuracy: 1e-9, "shorter than the floor: one frame for all of it")
    }

    private final class Sched {
        var due: Date?
        var fire: (@MainActor () -> Void)?
        func schedule(_ d: Date, _ f: @escaping @MainActor () -> Void) -> PopoverAnimationClock.Stop {
            due = d; fire = f
            return { [weak self] in self?.due = nil; self?.fire = nil }
        }
    }

    private struct Frames: PlazaSpriteFetching {
        let frames: [(image: PlazaImage, delay: TimeInterval)]
        func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: PlazaImage, delay: TimeInterval)] { frames }
        func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> PlazaImage? { frames.first?.image }
        func egg() async -> PlazaImage? { nil }
    }

    /// The playback at a floor: the frames it plays are the capped ones, their due times the floor apart; a new floor decodes
    /// again; floor 0 (the popover) is untouched.
    func testThePlaybackPlaysTheCappedFramesAndANewFloorReloads() async {
        let frames = (0..<40).map { _ in (image: picture(), delay: 0.05) }
        var time = Date(timeIntervalSince1970: 10_000)
        let s = Sched()
        let p = PopoverSpritePlayback(fetcher: Frames(frames: frames), clock: PopoverAnimationClock(schedule: s.schedule), now: { time })
        p.isActive = true
        p.frameFloor = 0.4
        let slot = SpriteSlot(frame: CGRect(x: 0, y: 0, width: 96, height: 96), subject: PlazaSpriteSubjectKey(speciesID: 1), bob: false, animated: true)
        p.update(slots: [slot])
        for _ in 0..<400 where p.models.first?.isAnimating != true { await Task.yield(); try? await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(p.models.first?.frames.count, 5)
        XCTAssertEqual(p.models.first?.isLoading, false)
        var gaps: [Double] = []
        for _ in 0..<4 {
            guard let due = s.due else { XCTFail("no timer"); break }
            gaps.append((due.timeIntervalSince(time) * 1000).rounded() / 1000)
            time = due
            s.fire?()
        }
        XCTAssertEqual(gaps, [0.4, 0.4, 0.4, 0.4])
        p.frameFloor = 0.1
        XCTAssertEqual(p.models.first?.isLoading, true, "a new floor decodes again")
        for _ in 0..<400 where p.models.first?.frames.count != 20 { await Task.yield(); try? await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(p.models.first?.frames.count, 20)
        p.frameFloor = 0
        for _ in 0..<400 where p.models.first?.frames.count != 40 { await Task.yield(); try? await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(p.models.first?.frames.count, 40, "no floor: the GIF's own frames")
        p.release()
        XCTAssertNil(s.due)
    }

    func testACapToOneFrameShowsItWithNoTimer() async {
        let frames = (0..<4).map { _ in (image: picture(), delay: 0.1) }   // 0.4 s at Power saver: one frame
        let s = Sched()
        let p = PopoverSpritePlayback(fetcher: Frames(frames: frames), clock: PopoverAnimationClock(schedule: s.schedule))
        p.isActive = true
        p.frameFloor = 0.4
        p.update(slots: [SpriteSlot(frame: CGRect(x: 0, y: 0, width: 96, height: 96), subject: PlazaSpriteSubjectKey(speciesID: 1), bob: false, animated: true)])
        for _ in 0..<400 where p.models.first?.frames.isEmpty != false { await Task.yield(); try? await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(p.models.first?.frames.count, 1)
        XCTAssertTrue(p.models.first?.current === frames[0].image)
        XCTAssertNil(s.due, "one frame: nothing to advance (the Mac wakes each floor to show the same frame)")
        p.release()
    }
}
