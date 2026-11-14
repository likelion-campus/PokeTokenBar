import XCTest
@testable import PokeTokenBar

/// A window shell that records every call the controller makes, in order, and hands back what a test sets.
@MainActor final class RecordingPlazaShell: PlazaWindowShell {
    enum Call: Equatable {
        case open(title: String), bringToFront, requestClose, stopPresenting, dismantle, setTitle(String)
        case setTransparent(Bool), setHUDHidden(Bool), focusScene, focusChatInput, setChatLogAboveInput(Bool)
    }

    private(set) var calls: [Call] = []
    weak var events: (any PlazaWindowEvents)?
    var isFrontmost = false
    var isInLiveResize = false
    var renderLoop: (any PlazaPausableView)?
    var diagnostics: (occlusionVisible: Bool?, isKey: Bool?) = (nil, nil)
    /// The presented stage, held weakly: the controller owns the scene that owns it.
    private(set) weak var presented: (any PlazaStage)?
    /// At each `stopPresenting`: whether the presented stage still had its scene (the stage's delegate).
    private(set) var sceneAliveAtStop: [Bool] = []
    private(set) var overlays: PlazaOverlayBindings?

    /// The calls since the last `take()`.
    func take() -> [Call] {
        defer { calls = [] }
        return calls
    }

    /// Shows the HUD's panels as a window would (a 960×640 window at 2x); `panels` records what it was asked to show.
    let panels = RecordingPanelHost()

    func open(stage: any PlazaStage, title: String, overlays: PlazaOverlayBindings) {
        presented = stage
        self.overlays = overlays
        calls.append(.open(title: title))
        overlays.hud.setViewport(CGSize(width: 960, height: 640), scale: 2)
        overlays.hud.host = panels
    }
    func bringToFront() { calls.append(.bringToFront) }
    func requestClose() { calls.append(.requestClose) }
    func stopPresenting() {
        sceneAliveAtStop.append(presented?.delegate != nil)
        presented = nil
        calls.append(.stopPresenting)
    }
    func dismantle() {
        overlays?.hud.host = nil
        calls.append(.dismantle)
    }
    func setTitle(_ title: String) { calls.append(.setTitle(title)) }
    func setTransparent(_ transparent: Bool) { calls.append(.setTransparent(transparent)) }
    func setHUDHidden(_ hidden: Bool) { calls.append(.setHUDHidden(hidden)) }
    func focusScene() { calls.append(.focusScene) }
    func focusChatInput() { calls.append(.focusChatInput) }
    func setChatLogAboveInput(_ above: Bool) { calls.append(.setChatLogAboveInput(above)) }
}

/// Remembers every pause and resume, and whether the scene was already paused when the view was.
@MainActor final class PauseOrderLoop: PlazaPausableView {
    var scenePausedAtSet: () -> Bool? = { nil }
    private(set) var sets: [(paused: Bool, scenePaused: Bool?)] = []
    var isPaused = false { didSet { sets.append((isPaused, scenePausedAtSet())) } }
}

/// Each tick of a controller loop waits here until the test lets it go.
@MainActor final class ShellTestGate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    var count: Int { waiting.count }
    func sleep() async { await withCheckedContinuation { waiting.append($0) } }
    func tick() { if !waiting.isEmpty { waiting.removeFirst().resume() } }
}

private struct NoSpritesFetcher: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: PlazaImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> PlazaImage? { nil }
    func egg() async -> PlazaImage? { nil }
}

/// The seam between the shared controller and the window (Track A Task 12): every call the controller makes to its shell,
/// in order, for the main flows, the scene's lifetime against presentation, and that a hidden plaza runs nothing new.
/// Runs on Windows too (the shell is a recording fake; the stage is the platform's).
@MainActor final class PlazaWindowShellTests: XCTestCase {
    private static let park: @MainActor (Duration) async -> Void = { _ in try? await Task.sleep(for: .seconds(3600)) }

    private func controller(_ shell: any PlazaWindowShell, chat: PlazaStubChatInput = PlazaStubChatInput(),
                            subject: @escaping () -> CompanionStore.RepresentativeSubject = { .init(speciesID: 25, isShiny: false) },
                            session: TeamSession? = nil, memberID: String = "member-1", teamName: String? = "개발팀",
                            renderCheckSleep: @escaping @MainActor (Duration) async -> Void = park,
                            focusTickSleep: @escaping @MainActor (Duration) async -> Void = park,
                            prayerCount: @escaping () -> Int = { 0 }) -> PlazaWindowController {
        PlazaWindowController(preferences: PlazaPreferences(defaults: TestDefaults.make(suite: "plaza.shell.\(UUID())")),
                              loader: PlazaCharacterLoader(fetcher: NoSpritesFetcher()),
                              nickname: { "tester" }, memberID: { memberID }, subject: subject,
                              teamName: { teamName }, prayerCount: prayerCount, session: session,
                              renderCheckSleep: renderCheckSleep, focusTickSleep: focusTickSleep,
                              dittoLoopSleep: Self.park, dittoSeed: { 7 }, shell: shell, chatInput: chat)
    }

    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() { await Task.yield() }
    }

    private func key(_ scene: PlazaScene, _ code: UInt16, _ modifiers: PlazaModifiers = []) {
        scene.handleKeyDown(keyCode: code, characters: nil, isRepeat: false, modifiers: modifiers)
        scene.handleKeyUp(keyCode: code)
    }

    // MARK: open, hide/show, close

    func testShowOpensTheShellOnceAndBringsItForward() async {
        let shell = RecordingPlazaShell()
        let loop = PauseOrderLoop()
        shell.renderLoop = loop
        let c = controller(shell)
        XCTAssertTrue(shell.events === c, "the controller hears the window's events")
        c.show()
        XCTAssertEqual(shell.take(), [.open(title: "팀 광장 · 개발팀"), .setTransparent(false), .bringToFront])
        XCTAssertTrue(shell.presented === c.scene?.stage, "the scene's own stage is presented")
        XCTAssertTrue(c.renderLoop === loop, "the shell's drawing loop is the one paused when hidden")
        c.show()
        XCTAssertEqual(shell.take(), [.bringToFront], "already open: only brought forward")
        c.handleClose()
    }

    func testTheOverlaysAreTheControllersModelsAndActions() async throws {
        let shell = RecordingPlazaShell()
        let c = controller(shell)
        c.show()
        let o = try XCTUnwrap(shell.overlays)
        XCTAssertTrue(o.rosterModel === c.rosterModel)
        XCTAssertEqual(o.myMemberID, "member-1")
        XCTAssertEqual(o.worldSize, PlazaMapData.map.pixelSize)
        XCTAssertTrue(o.chatInput === c.chatInputForTesting)
        _ = shell.take()
        o.toggleShortcuts()
        XCTAssertTrue(c.areShortcutsFolded)
        o.toggleChatLog()
        XCTAssertTrue(c.isChatLogExpanded)
        o.toggleNameColorPicker()
        XCTAssertTrue(c.isNameColorPickerOpen)
        o.pickNameColor(PlazaNameColor.hexes[3])
        XCTAssertEqual(c.shownNameColor, PlazaNameColor.hexes[3])
        XCTAssertFalse(c.isNameColorPickerOpen)
        o.turnRosterPage(1)
        o.toggleBackground()
        XCTAssertTrue(c.isBackgroundHidden)
        XCTAssertEqual(shell.take(), [.focusScene, .focusScene, .focusScene, .focusScene, .focusScene,
                                      .setTransparent(true), .focusScene],
                       "every HUD click hands the keys back to the scene; the background toggle turns the window see-through first")
        c.handleClose()
    }

    func testHidingAndShowingPauseTheLoopAndTheSceneWithoutTouchingTheWindow() async throws {
        let shell = RecordingPlazaShell()
        let loop = PauseOrderLoop()
        shell.renderLoop = loop
        let c = controller(shell)
        c.show()
        _ = shell.take()
        let events = try XCTUnwrap(shell.events)
        events.setRendering(visible: false)
        XCTAssertTrue(loop.isPaused)
        XCTAssertEqual(c.scene?.isPaused, true)
        XCTAssertFalse(c.rosterIsAnimating)
        events.setRendering(visible: true)
        XCTAssertFalse(loop.isPaused)
        XCTAssertEqual(c.scene?.isPaused, false)
        XCTAssertTrue(c.rosterIsAnimating)
        XCTAssertEqual(shell.take(), [], "hiding and showing are the controller's own switch")
        c.handleClose()
    }

    /// `setRendering` pauses the view before the scene: on the Mac the view's pause reaches the scene's pause work through
    /// SpriteKit, and the controller's own write after it is then a no-op (Task 10). The log line comes last.
    func testTheViewPausesBeforeTheScene() async {
        let shell = RecordingPlazaShell()
        let loop = PauseOrderLoop()
        shell.renderLoop = loop
        let c = controller(shell)
        c.show()
        loop.scenePausedAtSet = { [weak c] in c?.scene?.isPaused }
        var lines: [(String, Int)] = []
        c.stateLog = { lines.append(($0, loop.sets.count)) }
        c.setRendering(visible: false)
        c.setRendering(visible: true)
        XCTAssertEqual(loop.sets.map(\.paused), [true, false])
        XCTAssertEqual(loop.sets.map(\.scenePaused), [false, true], "the scene was not yet paused (resumed) when the view was")
        XCTAssertEqual(lines.map(\.1), [1, 2], "each log line after its view change")
        XCTAssertTrue(lines.first?.0.hasPrefix("plaza rendering visible=false:") == true)
        c.handleClose()
    }

    /// Closing: the chat field closes (and gives the keys back), then the shell stops presenting while the scene is still
    /// alive, then lets go of the window. Reopening opens a new window on a new scene.
    func testCloseStopsPresentingWhileTheSceneLivesThenDismantles() async throws {
        let shell = RecordingPlazaShell()
        shell.renderLoop = PauseOrderLoop()
        let c = controller(shell)
        c.show()
        let first = try XCTUnwrap(c.scene)
        key(first, PlazaKeyCode.returnKey)
        XCTAssertTrue(c.chatInputForTesting.isOpen)
        _ = shell.take()
        try XCTUnwrap(shell.events).handleClose()
        XCTAssertEqual(shell.take(), [.setChatLogAboveInput(false), .focusScene, .stopPresenting, .dismantle])
        XCTAssertEqual(shell.sceneAliveAtStop, [true])
        XCTAssertNil(c.scene)
        XCTAssertNil(c.renderLoop)
        c.show()
        XCTAssertEqual(shell.take(), [.open(title: "팀 광장 · 개발팀"), .setTransparent(false), .bringToFront], "a closed plaza opens again")
        XCTAssertFalse(c.scene === first)
        c.handleClose()
        XCTAssertEqual(shell.take(), [.stopPresenting, .dismantle])
        XCTAssertEqual(shell.sceneAliveAtStop, [true, true])
    }

    /// The scene outlives its presentation: nothing but the controller holds it, and it is released only after the shell
    /// stopped presenting its stage.
    func testTheSceneOutlivesItsPresentation() async {
        let shell = RecordingPlazaShell()
        let c = controller(shell)
        weak var scene: PlazaScene?
        weak var stage: (any PlazaStage)?
        c.show()
        scene = c.scene
        stage = c.scene?.stage
        for _ in 0..<50 { await Task.yield() }
        XCTAssertNotNil(scene, "presented: kept alive by the controller")
        XCTAssertTrue(shell.presented === stage)
        XCTAssertNotNil(shell.presented?.delegate, "the presented stage still has its scene")
        c.handleClose()
        XCTAssertEqual(shell.sceneAliveAtStop, [true], "presentation stopped before the scene went")
        for _ in 0..<50 { await Task.yield() }
        XCTAssertNil(scene, "after the shell stopped presenting, the scene is let go of")
        XCTAssertNil(stage)
    }

    /// Closing a plaza that was never shown (the app quitting, a team switch) makes the same no-op calls as before.
    func testClosingWithoutAWindowOnlyDismantles() async {
        let shell = RecordingPlazaShell()
        let c = controller(shell)
        c.prepareScene()
        c.handleClose()
        XCTAssertEqual(shell.take(), [.dismantle], "nothing was presented, so nothing stops presenting")
    }

    /// On the headless shell (Windows until stage 6) ⌘W and leaving the team (`closeIfOpen`) close the plaza as on the Mac: the
    /// shell reports `handleClose` at once, which stops the presentation and lets go of the scene. (The order — presentation
    /// stopped while the scene lives — is the controller's and is pinned with the recording shell above.)
    func testTheHeadlessShellClosesThePlazaOnRequest() async throws {
        let shell = PlazaHeadlessShell()
        let c = controller(shell)
        c.closeIfOpen()   // nothing open: nothing happens
        XCTAssertFalse(shell.isOpen)
        c.show()
        XCTAssertTrue(shell.isOpen)
        XCTAssertTrue(shell.presentedStage === c.scene?.stage)
        weak var scene = c.scene
        key(try XCTUnwrap(c.scene), PlazaKeyCode.w, .command)
        XCTAssertNil(c.scene, "⌘W closed the plaza")
        XCTAssertNil(c.renderLoop)
        XCTAssertNil(shell.presentedStage, "the presentation was stopped")
        XCTAssertFalse(shell.isOpen, "the window was dismantled")
        for _ in 0..<50 { await Task.yield() }
        XCTAssertNil(scene, "the scene is let go of")
        c.show()
        XCTAssertTrue(shell.isOpen, "a closed plaza opens again")
        XCTAssertNotNil(c.scene)
        c.closeIfOpen()   // leaving the team
        XCTAssertNil(c.scene)
        XCTAssertFalse(shell.isOpen)
        XCTAssertNil(shell.presentedStage)
    }

    func testCloseRequestGoesThroughTheShell() async throws {
        let shell = RecordingPlazaShell()
        let c = controller(shell)
        c.show()
        _ = shell.take()
        key(try XCTUnwrap(c.scene), PlazaKeyCode.w, .command)
        XCTAssertEqual(shell.take(), [.requestClose], "⌘W asks the window to close; the window then reports handleClose")
        XCTAssertNotNil(c.scene)
        c.closeIfOpen()
        XCTAssertEqual(shell.take(), [.requestClose])
        c.handleClose()
    }

    // MARK: keys, focus and the HUD

    func testToggleBackgroundSetsTransparencyAndRefocusesTheScene() async {
        let shell = RecordingPlazaShell()
        let c = controller(shell)
        c.show()
        _ = shell.take()
        c.toggleBackground()
        XCTAssertEqual(shell.take(), [.setTransparent(true), .focusScene])
        XCTAssertEqual(c.scene?.isBackgroundHidden, true)
        c.toggleBackground()
        XCTAssertEqual(shell.take(), [.setTransparent(false), .focusScene])
        c.handleClose()
        c.show()
        XCTAssertEqual(shell.take(), [.stopPresenting, .dismantle, .open(title: "팀 광장 · 개발팀"), .setTransparent(false), .bringToFront])
        c.handleClose()
    }

    func testOpenChatFocusesTheInputAndMovesTheLog() async throws {
        let shell = RecordingPlazaShell()
        let chat = PlazaStubChatInput()
        let c = controller(shell, chat: chat)
        c.show()
        _ = shell.take()
        let scene = try XCTUnwrap(c.scene)
        key(scene, PlazaKeyCode.returnKey)
        XCTAssertTrue(chat.isOpen)
        XCTAssertEqual(shell.take(), [.setChatLogAboveInput(true), .focusChatInput])
        XCTAssertEqual(chat.onSubmit?("안녕"), true)
        XCTAssertEqual(scene.shownChat(memberID: nil), "안녕")
        XCTAssertEqual(c.chatLogLines.map(\.text), ["안녕"])
        chat.close()
        XCTAssertEqual(shell.take(), [.setChatLogAboveInput(false), .focusScene])
        c.handleClose()
    }

    func testPhotoModeHidesTheHUD() async throws {
        let shell = RecordingPlazaShell()
        let c = controller(shell)
        c.show()
        _ = shell.take()
        let scene = try XCTUnwrap(c.scene)
        key(scene, PlazaKeyCode.p)
        XCTAssertTrue(c.overlayIsPhotoMode)
        XCTAssertEqual(shell.take(), [.setHUDHidden(true)])
        key(scene, PlazaKeyCode.escape)
        XCTAssertFalse(c.overlayIsPhotoMode)
        XCTAssertEqual(shell.take(), [.setHUDHidden(false)])
        c.handleClose()
    }

    /// A key that only changes overlay models reaches them without any window call: A as an egg prays and the hint shows
    /// the count at once, ahead of the board's hint at the spawn.
    func testAKeyReachesTheOverlayModelWithoutTheShell() async throws {
        let shell = RecordingPlazaShell()
        var prayers = 0
        let c = controller(shell, subject: { .init(speciesID: nil, isShiny: false) }, prayerCount: { prayers })
        c.show()
        _ = shell.take()
        let before = c.hint
        prayers = 1   // what the companion's pray() does
        key(try XCTUnwrap(c.scene), PlazaKeyCode.a)
        XCTAssertEqual(c.hint, L(.ko).plazaPrayedHint(prayers: 1))
        XCTAssertNotEqual(before, c.hint)
        XCTAssertEqual(shell.take(), [])
        c.handleClose()
    }

    func testRefreshTitleGoesThroughTheShell() async {
        let shell = RecordingPlazaShell()
        let c = controller(shell)
        c.refreshTitle()
        XCTAssertEqual(shell.take(), [.setTitle("팀 광장 · 개발팀")])
    }

    // MARK: window events and state

    func testWindowEventsDriveRenderingAndRoster() async throws {
        let shell = RecordingPlazaShell()
        let loop = PauseOrderLoop()
        shell.renderLoop = loop
        let c = controller(shell)
        c.show()
        let events = try XCTUnwrap(shell.events)
        events.contentHeightDidChange(320)
        XCTAssertEqual(c.rosterModel.capacity, PlazaRoster.capacity(forHeight: 320))
        XCTAssertEqual(c.rosterModel.maxListHeight, PlazaRoster.maxListHeight(forHeight: 320))
        events.contentHeightDidChange(900)
        XCTAssertEqual(c.rosterModel.capacity, PlazaRoster.capacity(forHeight: 900))
        XCTAssertNotEqual(PlazaRoster.capacity(forHeight: 320), PlazaRoster.capacity(forHeight: 900), "the fixture tells the sizes apart")
        events.setRendering(visible: false)   // miniaturized or covered
        XCTAssertEqual(loop.sets.map(\.paused), [true])
        events.setRendering(visible: true)
        XCTAssertEqual(loop.sets.map(\.paused), [true, false])
        let scene = try XCTUnwrap(c.scene)
        let start = scene.walker.tile
        scene.handleKeyDown(keyCode: PlazaKeyCode.right, characters: nil, isRepeat: false)
        events.didResignKey()
        var t = 0.0
        scene.update(t)
        while t < 1 { t += 1.0 / 30; scene.update(t) }
        XCTAssertFalse(scene.walker.isWalking, "losing key releases the held keys")
        XCTAssertLessThanOrEqual(abs(scene.walker.tile.x - start.x) + abs(scene.walker.tile.y - start.y), 1, "at most the tap's step")
        c.handleClose()
    }

    func testLogStateReadsTheShellDiagnostics() async throws {
        let shell = RecordingPlazaShell()
        let c = controller(shell)
        c.show()
        var lines: [String] = []
        c.stateLog = { lines.append($0) }
        shell.diagnostics = (occlusionVisible: true, isKey: false)
        let events = try XCTUnwrap(shell.events)
        events.didResignKey()
        shell.diagnostics = (occlusionVisible: false, isKey: true)
        events.didBecomeKey()
        shell.diagnostics = (nil, nil)
        events.setRendering(visible: false)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasPrefix("plaza resigned key: occlusionVisible=true key=false"), lines[0])
        XCTAssertTrue(lines[1].hasPrefix("plaza became key: occlusionVisible=false key=true"), lines[1])
        XCTAssertTrue(lines[2].hasPrefix("plaza rendering visible=false: occlusionVisible=- key=-"), lines[2])
        c.handleResignKey()
        c.handleBecomeKey()
        XCTAssertEqual(lines.count, 3, "the handlers themselves do not log; the window's key events do")
        c.handleClose()
    }

    func testWatchdogSkipsWhileTheShellIsInLiveResize() async throws {
        let shell = RecordingPlazaShell()
        let loop = PauseOrderLoop()
        shell.renderLoop = loop
        let c = controller(shell)
        c.show()
        shell.isInLiveResize = true
        c.checkRendering()
        c.checkRendering()
        c.checkRendering()
        XCTAssertEqual(loop.sets.count, 0, "SpriteKit does not draw during a live resize: no wake-up")
        shell.isInLiveResize = false
        c.checkRendering()          // first look after the resize only takes the count
        XCTAssertEqual(loop.sets.count, 0)
        c.checkRendering()          // a second without a frame
        XCTAssertEqual(loop.sets.map(\.paused), [true, false])
        c.handleClose()
    }

    func testIsFrontmostAsksTheShell() async {
        let shell = RecordingPlazaShell()
        let c = controller(shell)
        XCTAssertFalse(c.isFrontmost)
        shell.isFrontmost = true
        XCTAssertTrue(c.isFrontmost)
    }

    /// While hidden, the loops that ran before keep their schedule but the watchdog never wakes the view, the scene gets no
    /// frame and no window call is made.
    func testNothingRunsWhileHidden() async throws {
        let shell = RecordingPlazaShell()
        let loop = PauseOrderLoop()
        shell.renderLoop = loop
        let watchdog = ShellTestGate(), focus = ShellTestGate()
        let c = controller(shell, renderCheckSleep: { _ in await watchdog.sleep() }, focusTickSleep: { _ in await focus.sleep() })
        c.show()
        let scene = try XCTUnwrap(c.scene)
        await settle { watchdog.count == 1 && focus.count == 1 }
        try XCTUnwrap(shell.events).setRendering(visible: false)
        _ = shell.take()
        var lines: [String] = []
        c.stateLog = { lines.append($0) }
        let updates = scene.updateCount
        for _ in 0..<5 {
            watchdog.tick()
            focus.tick()
            await settle { watchdog.count == 1 && focus.count == 1 }
        }
        XCTAssertEqual(loop.sets.map(\.paused), [true], "never woken while hidden")
        XCTAssertEqual(scene.updateCount, updates)
        XCTAssertEqual(lines, [])
        XCTAssertEqual(shell.take(), [])
        c.handleClose()
    }

    // MARK: flows that need no window

    func testFocusStartAndEndTouchNoShell() async throws {
        let shell = RecordingPlazaShell()
        let c = controller(shell)
        var ends: [PlazaFocusEnd] = []
        c.onFocusEnd = { ends.append($0) }
        c.show()
        _ = shell.take()
        c.startFocus(minutes: 25)
        XCTAssertTrue(c.isFocusing)
        XCTAssertNotNil(c.hint)
        key(try XCTUnwrap(c.scene), PlazaKeyCode.left)   // an arrow stands me up
        XCTAssertFalse(c.isFocusing)
        XCTAssertEqual(ends.map(\.completed), [false])
        XCTAssertEqual(shell.take(), [])
        c.handleClose()
    }

    func testADanceRoundTouchesNoShell() async throws {
        let shell = RecordingPlazaShell()
        let c = controller(shell)
        c.show()
        _ = shell.take()
        let scene = try XCTUnwrap(c.scene)
        var rounds: [String] = []
        let controllers = scene.onDanceRound
        scene.onDanceRound = { rounds.append($0); controllers?($0) }
        key(scene, PlazaKeyCode.d)
        XCTAssertEqual(rounds.count, 1)
        XCTAssertTrue(scene.isDancing(memberID: nil))
        var t = 0.0
        scene.update(t)
        while t < 8 { t += 1.0 / 30; scene.update(t) }
        XCTAssertGreaterThan(rounds.count, 1, "the loop starts the next round by itself")
        XCTAssertEqual(shell.take(), [])
        c.handleClose()
    }

    /// Two sessions on a fake transport; my controller is wired to the first. The directory is removed at teardown.
    private struct TeamPair {
        let hub: FakeTransportHub
        let me: TeamSession, meT: FakeTeamTransport, meS: TeamSettings
        let other: TeamSession, otherT: FakeTeamTransport, otherS: TeamSettings
    }

    private func teamPair() throws -> TeamPair {
        let hub = FakeTransportHub()
        var rng = SystemRandomNumberGenerator()
        let code = TeamCode.generate(using: &rng)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PlazaWindowShellTests-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let mon = TeamMonSummary(speciesID: 25, isShiny: false, form: nil, speciesName: "Pikachu", gender: nil)
        func node(_ name: String) -> (TeamSession, FakeTeamTransport, TeamSettings) {
            let settings = TeamSettings(defaults: TestDefaults.make(suite: "plaza.shell.team.\(UUID())"))
            settings.code = code
            settings.nickname = name
            settings.isEnabled = true
            let feed = TeamFeedStore(fileURL: dir.appendingPathComponent("\(name).json"), myMemberID: settings.memberID)
            let transport = hub.makeTransport()
            let session = TeamSession(settings: settings, feed: feed, transport: transport,
                                      profileProvider: { TeamMemberProfile(memberID: settings.memberID, nickname: name, current: mon, dex: []) })
            session.updateCharacter(mon)
            session.applySettings()
            return (session, transport, settings)
        }
        let (me, meT, meS) = node("나")
        let (other, otherT, otherS) = node("가")
        return TeamPair(hub: hub, me: me, meT: meT, meS: meS, other: other, otherT: otherT, otherS: otherS)
    }

    func testATeammateJoiningAndLeavingTouchesNoShell() async throws {
        let t = try teamPair()
        let shell = RecordingPlazaShell()
        let c = controller(shell, session: t.me, memberID: t.meS.memberID)
        c.show()
        _ = shell.take()
        let link = t.hub.connect(t.meT, to: t.otherT)
        t.other.updatePlazaPosition(inPlaza: true, tile: PlazaMapData.map.spawn, facing: .down, isWalking: false)
        let scene = try XCTUnwrap(c.scene)
        let otherID = t.otherS.memberID
        await settle { scene.memberTiles[otherID] != nil }
        XCTAssertNotNil(scene.memberTiles[otherID], "the teammate walked in")
        XCTAssertTrue(c.rosterEntries.contains { $0.id == otherID })
        XCTAssertTrue(c.minimapDots.contains { $0.id == otherID })
        t.hub.disconnect(link)
        await settle { t.me.members[otherID] == nil }
        await settle { scene.memberTiles[otherID] == nil }
        XCTAssertNil(scene.memberTiles[otherID], "the teammate left")
        XCTAssertEqual(shell.take(), [], "member sync draws through the scene and the models only")
        c.handleClose()
    }

    /// What teammates and timers trigger (`PlazaPresenting`, member sync, the 1 s tick) never brings the plaza forward or
    /// moves the keyboard focus: the plaza comes forward only when the user opens it.
    func testWhatTeammatesAndTimersTriggerNeverBringsThePlazaForward() async throws {
        let t = try teamPair()
        let shell = RecordingPlazaShell()
        let tick = ShellTestGate()
        let c = controller(shell, session: t.me, memberID: t.meS.memberID, focusTickSleep: { _ in await tick.sleep() })
        c.show()
        _ = shell.take()
        _ = t.hub.connect(t.meT, to: t.otherT)
        let scene = try XCTUnwrap(c.scene)
        let me = t.meS.memberID, otherID = t.otherS.memberID
        let beside = TilePoint(x: scene.walker.tile.x + 1, y: scene.walker.tile.y)
        t.other.updatePlazaPosition(inPlaza: true, tile: beside, facing: .left, isWalking: false)
        await settle { scene.memberTiles[otherID] == beside }
        XCTAssertEqual(scene.memberTiles[otherID], beside, "test precondition: the teammate stands beside me")
        let presenting: any PlazaPresenting = c
        presenting.showEmote(memberID: otherID, kind: .heart, alsoOver: me, overDecoy: false)
        presenting.showChat(memberID: otherID, text: "안녕", isLoud: true)
        presenting.showJump(memberID: otherID, iceBreak: nil)
        presenting.showDance(memberID: otherID, style: nil, since: nil)
        presenting.stopDance(memberID: otherID)
        presenting.showFirework(memberID: otherID, style: nil)
        presenting.showTackle(from: otherID, on: me, tiles: 1)
        presenting.showSnowball(from: otherID, on: me, tiles: 1, direction: .left)
        presenting.showPull(from: otherID, on: me)
        presenting.showPickup(from: otherID, slot: 0)
        presenting.showGroupPhoto(from: otherID)
        presenting.applySchedule()
        presenting.endFocusIfDue()
        c.showBanner("배너")
        for _ in 0..<3 {
            await settle { tick.count == 1 }
            tick.tick()
        }
        var time = 0.0
        scene.update(time)
        while time < 2 { time += 1.0 / 30; scene.update(time) }
        let calls = shell.take()
        XCTAssertFalse(calls.contains(.bringToFront), "\(calls)")
        XCTAssertFalse(calls.contains(.focusScene), "\(calls)")
        XCTAssertFalse(calls.contains(.focusChatInput), "\(calls)")
        XCTAssertEqual(calls, [], "teammates and timers make no window call at all")
        c.handleClose()
    }
}
