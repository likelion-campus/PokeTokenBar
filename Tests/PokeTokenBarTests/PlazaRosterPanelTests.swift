import XCTest
@testable import PokeTokenBar

/// A beat by hand: the animation clock's timer, so a test decides when a beat comes and sees when the timer is made and ended.
final class ManualBeat: @unchecked Sendable {
    private(set) var started = 0, stopped = 0
    private var fire: (@MainActor () -> Bool)?
    var isScheduled: Bool { fire != nil }
    func schedule(_ interval: TimeInterval, _ f: @escaping @MainActor () -> Bool) -> PlazaAnimationClock.Stop {
        started += 1
        fire = f
        return { [self] in stopped += 1; fire = nil }
    }
    @MainActor func beat() { _ = fire?() }
    /// The callback's own answer: false once the clock behind it is gone.
    @MainActor func fireValue() -> Bool? { fire?() }
}

/// Pictures a test controls: `have` is in memory, `loadable` arrives when asked for (after a turn of the main actor).
@MainActor final class FakeIcons: PlazaIconSource {
    var have: [Int?: PlazaImage] = [:]
    var loadable: [Int?: PlazaImage] = [:]
    private(set) var asked: [Int?] = []
    private(set) var spritesAsked: [Int?] = []
    func cachedIcon(speciesID: Int?) -> PlazaImage? { have[speciesID] }
    func icon(speciesID: Int?) async -> PlazaImage? {
        asked.append(speciesID)
        await Task.yield()
        return loadable[speciesID]
    }
    func sprite(speciesID: Int?, shiny: Bool, form: PokemonForm?) async -> PlazaImage? {
        spritesAsked.append(speciesID)
        await Task.yield()
        return loadable[speciesID]
    }
}

func samplePicture(_ w: Int = 40, _ h: Int = 30) -> PlazaImage {
    PlazaImage(bitmap: PlazaBitmap(width: w, height: h, fill: PlazaRGBA(r: 90, g: 160, b: 60, a: 255)))
}

/// The roster as a panel (Track A Task 17c), stub graphics (monospace text: the body font's character is 9 points wide,
/// a line 15 tall), so it runs on Windows too. The SwiftUI view's own numbers are in `PlazaRosterPanelRenderTests+Mac`.
@MainActor final class PlazaRosterPanelTests: XCTestCase {
    private func flush() async { for _ in 0..<20 { await Task.yield() } }

    private func entry(_ n: Int, _ presence: PlazaPresence = .online, me: Bool = false, nick: String? = nil, species: String = "피카츄",
                       sid: Int? = 25, gender: PokemonGender? = nil, shiny: Bool = false) -> PlazaRosterEntry {
        PlazaRosterEntry(id: "m\(n)", nickname: nick ?? "친구\(n)", speciesID: sid, speciesName: species, gender: gender, isShiny: shiny, presence: presence, isMe: me)
    }

    private struct Rig {
        let model: PlazaRosterModel, panel: PlazaRosterPanel, hud: PlazaHUD, host: RecordingPanelHost, graphics: CanvasKeepingGraphics
        let icons: FakeIcons, beat: ManualBeat, actions: Actions
    }
    @MainActor final class Actions { var list: [String] = [] }

    private func rig(_ entries: [PlazaRosterEntry] = [], capacity: Int = 6, page: Int = 0, animating: Bool = false, viewport: CGSize = CGSize(width: 960, height: 640),
                     scale: CGFloat = 2) -> Rig {
        let model = PlazaRosterModel()
        model.entries = entries
        model.capacity = capacity
        model.page = page
        model.isAnimating = animating
        let icons = FakeIcons(), beat = ManualBeat()
        let panel = PlazaRosterPanel(model: model, icons: icons, clock: PlazaAnimationClock(interval: 0.5, schedule: { beat.schedule($0, $1) }))
        let graphics = CanvasKeepingGraphics()
        let hud = PlazaHUD(panels: [panel], graphics: graphics)
        let host = RecordingPanelHost(), actions = Actions()
        hud.onAction = { id, hit in actions.list.append("\(id) \(hit.action) \(hit.index.map(String.init) ?? "-")") }
        hud.setViewport(viewport, scale: scale)
        hud.host = host
        return Rig(model: model, panel: panel, hud: hud, host: host, graphics: graphics, icons: icons, beat: beat, actions: actions)
    }

    private func frame(_ r: Rig) -> CGRect? { r.hud.layout(viewport: r.hud.viewport, scale: r.hud.scale)[.roster] }
    private func click(_ r: Rig, _ p: CGPoint) {
        let f = frame(r) ?? .zero
        let at = CGPoint(x: f.minX + p.x, y: f.minY + p.y)
        _ = r.hud.handleMouse(PlazaMouseEvent(kind: .down, location: at), in: .roster)
        _ = r.hud.handleMouse(PlazaMouseEvent(kind: .up, location: at), in: .roster)
    }

    // MARK: size and place

    /// 10 + header 20 + 6 + n slots of 44 with 4 between + 10, 232 wide, 14 from the top right corner, at every window size and scale.
    func testSizeAndPlaceAtEveryWindowSize() async {
        for v in [CGSize(width: 600, height: 372), CGSize(width: 960, height: 640), CGSize(width: 2560, height: 1440)] {
            for scale in [CGFloat(1), 2] {
                let cap = PlazaRoster.capacity(forHeight: v.height)
                for n in [0, 1, 3, 9] {
                    let r = rig((0..<n).map { entry($0) }, capacity: cap, viewport: v, scale: scale)
                    let shown = CGFloat(min(n, cap))
                    let height = 10 + 20 + 6 + shown * 44 + max(0, shown - 1) * 4 + 10
                    XCTAssertEqual(frame(r), CGRect(x: v.width - 14 - 232, y: 14, width: 232, height: height), "\(v) \(scale)x \(n) members, capacity \(cap)")
                }
            }
        }
    }

    func testCapacityFollowsTheWindowHeight() async {
        XCTAssertEqual(PlazaRoster.capacity(forHeight: 372), 2)
        XCTAssertEqual(PlazaRoster.capacity(forHeight: 640), 6)
        XCTAssertEqual(PlazaRoster.capacity(forHeight: 100), 1, "never fewer than one slot")
        let r = rig((0..<9).map { entry($0) }, capacity: PlazaRoster.capacity(forHeight: 372), viewport: CGSize(width: 600, height: 372))
        XCTAssertEqual(r.panel.layout(scale: 2, text: r.graphics.text).slots.count, 2)
        r.model.capacity = PlazaRoster.capacity(forHeight: 640)   // the window grows: the controller sets it
        await flush()
        XCTAssertEqual(r.panel.layout(scale: 2, text: r.graphics.text).slots.count, 6)
        let expected: CGFloat = 10 + 20 + 6 + 264 + 20 + 10   // six slots of 44 and five gaps of 4
        XCTAssertEqual(frame(r)?.height, expected)
    }

    func testAnEmptyRosterIsTheHeaderOnly() async {
        let r = rig()
        XCTAssertEqual(frame(r)?.height, 46)
        let items = r.host.drawings[.roster]?.accessibility ?? []
        XCTAssertEqual(items.map(\.label), ["팀원", "접속 0 / 0"])
        XCTAssertTrue(items.allSatisfy { $0.role == .staticText })
        XCTAssertEqual(r.host.drawings[.roster]?.tooltips, [])
    }

    // MARK: paging

    func testPagesShowTheirSlotsAndTheArrowsTellWhereYouAre() async {
        let entries = (0..<14).map { entry($0) }
        for (page, count, prev, next) in [(0, 6, false, true), (1, 6, true, true), (2, 2, true, false)] {
            let r = rig(entries, page: page)
            let items = r.host.drawings[.roster]?.accessibility ?? []
            XCTAssertEqual(items.filter { $0.label.hasPrefix("친구") }.count, count, "page \(page)")
            let arrows = items.filter { $0.label == "<" || $0.label == ">" }
            XCTAssertEqual(arrows.map(\.label), ["<", ">"])
            XCTAssertEqual(arrows[0].action != nil, prev, "page \(page): previous enabled")
            XCTAssertEqual(arrows[1].action != nil, next, "page \(page): next enabled")
        }
        XCTAssertEqual((rig((0..<6).map { entry($0) }).host.drawings[.roster]?.accessibility ?? []).filter { $0.label == "<" }.count, 0, "one page: no arrows")
    }

    func testAPageThatWentAwayShowsTheLastOne() async {
        let r = rig((0..<14).map { entry($0) }, page: 2)
        r.model.entries = (0..<7).map { entry($0) }   // two pages now
        await flush()
        let items = r.host.drawings[.roster]?.accessibility ?? []
        XCTAssertEqual(items.filter { $0.label.hasPrefix("친구") }.map(\.label.count).count, 1)
        XCTAssertEqual(items.first { $0.label == ">" }?.action == nil, true, "on the last page")
    }

    func testClickingAnArrowTurnsThePageThroughTheOwner() async {
        let r = rig((0..<14).map { entry($0) })
        let arrows = r.host.drawings[.roster]!.accessibility.filter { $0.role == .button && ($0.label == "<" || $0.label == ">") }
        click(r, CGPoint(x: arrows[1].frame.midX, y: arrows[1].frame.midY))
        XCTAssertEqual(r.actions.list, ["roster next -"])
        click(r, CGPoint(x: arrows[0].frame.midX, y: arrows[0].frame.midY))
        XCTAssertEqual(r.actions.list.last, "roster roster -", "a disabled arrow is only the plate")
    }

    // MARK: clicks

    /// Review item 8: the hit carries WHO was pressed. A member joining between the press and the release shifts the slots; the release lands on
    /// another member and acts on nothing.
    func testAFeedUpdateBetweenPressAndReleaseCancelsTheClick() async {
        let r = rig([entry(0), entry(1)])
        let slots = r.panel.layout(scale: 2, text: r.graphics.text).slots
        let p = CGPoint(x: r.hud.layout(viewport: r.hud.viewport, scale: r.hud.scale)[.roster]!.minX + slots[0].frame.midX,
                        y: r.hud.layout(viewport: r.hud.viewport, scale: r.hud.scale)[.roster]!.minY + slots[0].frame.midY)
        _ = r.hud.handleMouse(PlazaMouseEvent(kind: .down, location: p), in: .roster)
        r.model.entries = [entry(7)] + r.model.entries   // someone joins on top: slot 0 is now m7
        await flush()
        _ = r.hud.handleMouse(PlazaMouseEvent(kind: .up, location: p), in: .roster)
        XCTAssertEqual(r.actions.list, [], "the release was on another member: nothing happens")
        // The same press and release with nothing changed does act.
        click(r, CGPoint(x: slots[0].frame.midX, y: slots[0].frame.midY))
        XCTAssertEqual(r.actions.list, ["roster select 0"])
    }

    func testASlotSelectsItsMemberAndTheMeSlotAndPlateOnlyTakeTheClick() async {
        let r = rig([entry(0, me: true), entry(1), entry(2, .asleep)])
        let slots = r.panel.layout(scale: 2, text: r.graphics.text).slots
        XCTAssertEqual(slots.count, 3)
        click(r, CGPoint(x: slots[1].frame.midX, y: slots[1].frame.midY))
        XCTAssertEqual(r.actions.list, ["roster select 1"])
        XCTAssertEqual(r.panel.entry(forHit: PlazaPanelHit(action: "select", index: 1))?.id, "m1")
        click(r, CGPoint(x: slots[2].frame.midX, y: slots[2].frame.midY))
        XCTAssertEqual(r.actions.list.last, "roster select 2", "an asleep member can be selected (the owner walks there)")
        click(r, CGPoint(x: slots[0].frame.midX, y: slots[0].frame.midY))
        XCTAssertEqual(r.actions.list.last, "roster me -", "my own slot takes the click and does nothing")
        click(r, CGPoint(x: 3, y: 3))
        XCTAssertEqual(r.actions.list.last, "roster roster -")
        XCTAssertNil(r.hud.hit(at: CGPoint(x: 100, y: 300), in: .roster), "outside the plate: the scene gets it")
        XCTAssertNil(r.panel.entry(forHit: PlazaPanelHit(action: "select", index: 9)))
    }

    func testPressingAnArrowDimsItAndReleasingOutsideDoesNotTurn() async {
        let r = rig((0..<14).map { entry($0) })
        await flush()
        let before = r.hud.renderCounts[.roster] ?? 0
        let f = frame(r)!
        let next = r.host.drawings[.roster]!.accessibility.first { $0.label == ">" }!.frame
        let p = CGPoint(x: f.minX + next.midX, y: f.minY + next.midY)
        _ = r.hud.handleMouse(PlazaMouseEvent(kind: .down, location: p), in: .roster)
        _ = r.hud.handleMouse(PlazaMouseEvent(kind: .moved, location: p), in: .roster)
        await flush()
        XCTAssertEqual((r.hud.renderCounts[.roster] ?? 0) - before, 1, "pressed: one render (drawn dimmed)")
        _ = r.hud.handleMouse(PlazaMouseEvent(kind: .up, location: CGPoint(x: f.minX + 5, y: f.minY + 5)), in: .roster)
        XCTAssertEqual(r.actions.list, [])
    }

    // MARK: accessibility and tooltips

    func testAccessibilityAndTooltips() async {
        let r = rig([entry(0, me: true, nick: "나"), entry(1, nick: "민수", species: "파이리"), entry(2, .asleep, nick: "바다"), entry(3, .idle, nick: "하늘")])
        let d = r.host.drawings[.roster]!
        XCTAssertEqual(d.accessibility.map(\.label), ["팀원", "접속 2 / 4", "나, 피카츄, 접속", "민수, 파이리, 접속", "바다, 피카츄, 잠", "하늘, 피카츄, 자리비움"])
        XCTAssertEqual(d.accessibility.map(\.role), [.staticText, .staticText, .staticText, .button, .button, .button])
        XCTAssertEqual(d.accessibility[3].action, PlazaPanelHit(action: "select", index: 1, target: "m1"))
        let slots = r.panel.layout(scale: 2, text: r.graphics.text).slots
        // The walk hint on every slot you can walk to: not mine, not an asleep member's.
        XCTAssertEqual(d.tooltips, [PlazaTooltip(frame: slots[1].frame, text: "누르면 이 팀원에게 걸어가요"), PlazaTooltip(frame: slots[3].frame, text: "누르면 이 팀원에게 걸어가요")])
        r.hud.press(PlazaPanelHit(action: "select", index: 1, target: "m1"), in: .roster)
        XCTAssertEqual(r.actions.list, ["roster select 1"])
    }

    // MARK: text

    func testLongNamesAreCutToTheColumnAndTheMarksKeepTheirPlace() async {
        let long = String(repeating: "가", count: 30)
        let r = rig([entry(0, nick: long, species: long, gender: .female, shiny: true)])
        let slot = r.panel.layout(scale: 2, text: r.graphics.text).slots[0]
        // 212 wide: 6 + 40 icon, 4, text, 4 + 4, the status (the stub's 2 characters 18 + 10 padding), 6.
        let column: CGFloat = 212 - 46 - 4 - 8 - 28 - 6
        let marks: CGFloat = 2 * 3 + 2 * 9
        XCTAssertLessThanOrEqual(slot.nameWidth, column - marks, "the nickname gives way to the gender and shiny marks")
        XCTAssertLessThanOrEqual(slot.species.width, column)
        XCTAssertEqual(slot.symbols.count, 2)
        XCTAssertEqual(slot.nickname.native.flatMap { ($0 as? PlazaStubText)?.text }?.hasSuffix("…"), true)
    }

    // MARK: pictures

    func testAMissingIconIsAPlaceholderAndEachPictureIsAskedForOnce() async {
        let r = rig([entry(0, sid: 25), entry(1, sid: 4), entry(2, sid: 25)])
        await flush()
        XCTAssertEqual((r.graphics.canvases.last?.calls ?? []).filter { $0.hasPrefix("image") }, [], "nothing arrived: no picture drawn (a rounded rectangle stands in)")
        XCTAssertTrue((r.graphics.canvases.last?.calls ?? []).contains { $0.hasPrefix("fillRoundedRect") && $0.hasSuffix(" 6.0") }, "the 6-point placeholder")
        XCTAssertEqual(r.icons.asked.compactMap { $0 }.sorted(), [4, 25], "each picture once, however many slots use it")
        r.model.page = 0
        r.model.entries = [entry(0, sid: 25), entry(1, sid: 4)]
        await flush()
        XCTAssertEqual(r.icons.asked.compactMap { $0 }.sorted(), [4, 25], "a picture that failed is not asked again at once (it retries after its delay)")
    }

    func testAnIconThatArrivesRendersTheRosterOnceMoreWithThePicture() async {
        let model = PlazaRosterModel()
        model.entries = [entry(0, sid: 25)]
        let icons = FakeIcons()
        icons.loadable[25] = samplePicture()
        let panel = PlazaRosterPanel(model: model, icons: icons)
        let graphics = CanvasKeepingGraphics()
        let hud = PlazaHUD(panels: [panel], graphics: graphics)
        let host = RecordingPanelHost()
        hud.setViewport(CGSize(width: 960, height: 640), scale: 2)
        hud.host = host
        XCTAssertEqual(hud.renderCounts[.roster], 1, "attaching renders once, the placeholder")
        XCTAssertEqual((graphics.canvases.last?.calls ?? []).filter { $0.hasPrefix("image") }.count, 0)
        await flush()
        XCTAssertEqual(hud.renderCounts[.roster], 2, "the picture arrived: one more render")
        let calls = (graphics.canvases.last?.calls ?? []).filter { $0.hasPrefix("image") }
        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(calls[0].hasPrefix("image 40x30 "), calls[0])
        await flush()
        XCTAssertEqual(hud.renderCounts[.roster], 2, "and nothing more")
    }

    func testAnIconInMemoryIsDrawnAtOnceAndScaledToFitItsFrame() async {
        let model = PlazaRosterModel()
        model.entries = [entry(0, sid: 25), entry(1, sid: nil)]
        let icons = FakeIcons()
        icons.have[25] = samplePicture()
        icons.have[nil] = samplePicture(28, 28)   // the egg, cropped square: fits 30 of the frame's 40 x 30
        let graphics = CanvasKeepingGraphics()
        let panel = PlazaRosterPanel(model: model, icons: icons)
        let hud = PlazaHUD(panels: [panel], graphics: graphics)
        hud.setViewport(CGSize(width: 960, height: 640), scale: 2)
        hud.host = RecordingPanelHost()
        let calls = (graphics.canvases.last?.calls ?? []).filter { $0.hasPrefix("image") }
        XCTAssertEqual(calls.count, 2, "no placeholder first: pages turned keep their pictures")
        XCTAssertEqual(icons.asked, [])
        XCTAssertTrue(calls[1].contains(", 30.0, 30.0)"), "the square egg is scaled up to the frame's 30 high, not stretched: \(calls[1])")
        XCTAssertTrue(calls[0].contains(", 40.0, 30.0)"), calls[0])
    }
}
