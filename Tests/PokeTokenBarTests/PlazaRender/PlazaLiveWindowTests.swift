import XCTest
import AppKit
import SpriteKit
@testable import PokeTokenBar

// The live-window check of Track A Task 12 (plan Task 12 Step 3; the Task 10 ledger's checklist): the real Mac shell's
// `SKView` in a real window, which the offscreen `SKRenderer` harness cannot show. Mac only (PlazaRender/ is Mac-only) and
// skipped unless PTB_PLAZA_LIVE_WINDOW=<dir> is set. Run it only with the user's hands-off time:
//
//   cd /Users/simu/Documents/GitHub/PokeTokenBar/.worktrees/wa-t12 && \
//   while pgrep -x swift-build >/dev/null || pgrep -x swift-test >/dev/null || pgrep -x xctest >/dev/null; do sleep 10; done && \
//   swift build --build-tests && \
//   PTB_PLAZA_LIVE_WINDOW=/private/tmp/claude-501/-Users-simu-Documents-GitHub-PokeTokenBar/91160cc1-46af-46c5-90bf-69dfeff21416/scratchpad/plaza-live \
//   swift test --skip-build --filter PlazaLiveWindowTests
//
// How it stays out of the way: `NSApplication.shared` is touched once, after the env check, and never launched, run or
// activated; the shell is borderless and its "bring to front" orders it front at x -10000 (`orderFront(nil)`: not key, not
// main); before that the test skips if any screen reaches that rect; after every run-loop slice it checks that the frontmost
// app is unchanged, this process is not active and no window of it is key or main, and on any change it tears down at once
// and fails. Teardown (order out, stop presenting, release) also runs when an assertion throws. Files are written only into
// <dir> (findings.txt and PNGs); no window frame is saved; the plaza preferences go to the test defaults pool
// (`TestDefaults`), like every plaza test.
//
// What it covers: the production `show()` path minus activation; backing scale; frames on a real SKView (if SpriteKit draws
// off screen at all — recorded either way); the view's pause reaching SpriteKit's scene and the plaza scene's pause work
// before the controller's write and its log line; a pause/resume kick restarting frames; window/SKView background colour,
// opaque and shadow with the map shown and hidden; `.resizeFill` and a zoom change during a programmatic resize; ordering
// out and in; a hidden plaza getting no frames; close through the window delegate freeing the old SKScene and scene;
// reopening; frame pacing by SpriteKit's clock and main-thread CPU per update.
// What it cannot cover: app hide, display sleep, real occlusion (an off-screen window is never "visible"), live resize by
// drag (`inLiveResize`), moving between displays and backing scale changes, real display-link stalls, the production
// `bringToFront` (activation + `makeKeyAndOrderFront`), titled-window behaviour (title bar, frame constraints, autosave).

private struct LiveNoSprites: PlazaSpriteFetching {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: PlazaImage, delay: TimeInterval)] { [] }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> PlazaImage? { nil }
    func egg() async -> PlazaImage? { nil }
}

/// Wraps the window's real `SKView` as the controller's drawing loop and records, at each pause write, what SpriteKit's
/// scene and the shared scene say right after it.
@MainActor private final class LiveProbeLoop: PlazaPausableView {
    let view: SKView
    var record: (String) -> Void = { _ in }
    weak var scene: PlazaScene?
    init(view: SKView) { self.view = view }
    var isPaused: Bool {
        get { view.isPaused }
        set {
            view.isPaused = newValue
            let host = view.scene?.isPaused.description ?? "-"
            record("view.isPaused=\(newValue) -> SKScene.isPaused=\(host) PlazaScene.isPaused=\(scene?.isPaused.description ?? "-") dancing=\(scene?.isDancing(memberID: nil).description ?? "-")")
        }
    }
}

private struct FocusGuardTripped: Error, CustomStringConvertible { let description: String }

@MainActor final class PlazaLiveWindowTests: XCTestCase {
    private var lines: [String] = []
    private var out = URL(fileURLWithPath: "/dev/null")
    private var app: NSApplication?
    private var frontmostPID: pid_t?
    /// Every window this test ordered in.
    private var windows: [NSWindow] = []
    private var teardown: () -> Void = {}
    private var lastFocusCheck = Date.distantPast

    private func note(_ s: String) {
        lines.append(s)
        print("PLAZA-LIVE: \(s)")
    }

    /// The frontmost app is the one from the start, this process is not active, and no window of it is key or main.
    /// Otherwise: tear down at once and fail.
    private func checkFocus(_ at: String) throws {
        lastFocusCheck = Date()
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var problems: [String] = []
        if pid != frontmostPID { problems.append("frontmost app changed from pid \(frontmostPID.map(String.init) ?? "-") to \(pid.map(String.init) ?? "-")") }
        if app?.isActive == true { problems.append("this test process became active") }
        if windows.contains(where: { $0.isKeyWindow || $0.isMainWindow }) { problems.append("a test window became key or main") }
        guard !problems.isEmpty else { return }
        teardown()
        note("ABORTED at \(at): \(problems.joined(separator: "; "))")
        throw FocusGuardTripped(description: "focus guard tripped at \(at): \(problems.joined(separator: "; "))")
    }

    private func spin(_ seconds: TimeInterval, _ at: String) throws {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            RunLoop.main.run(until: min(end, Date().addingTimeInterval(0.05)))
            try checkFocus(at)
        } while Date() < end
    }

    private func png(_ rep: NSBitmapImageRep?, _ name: String) {
        guard let data = rep?.representation(using: .png, properties: [:]) else { return note("\(name): no image") }
        try? data.write(to: out.appendingPathComponent(name))
        note("\(name): \(rep?.pixelsWide ?? 0)x\(rep?.pixelsHigh ?? 0) written")
    }

    private func snapshot(_ view: NSView, _ name: String) -> NSBitmapImageRep? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { note("\(name): no rep"); return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        png(rep, name)
        return rep
    }

    private func sample(_ rep: NSBitmapImageRep?, _ label: String) {
        guard let rep else { return }
        let points = [(rep.pixelsWide / 2, rep.pixelsHigh / 2), (rep.pixelsWide / 3, rep.pixelsHigh / 3), (5, rep.pixelsHigh - 5)]
        let text = points.map { p -> String in
            guard let c = rep.colorAt(x: p.0, y: p.1)?.usingColorSpace(.sRGB) else { return "(\(p.0),\(p.1)) -" }
            return String(format: "(%d,%d) r%.2f g%.2f b%.2f a%.2f", p.0, p.1, c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
        }
        note("\(label) pixels: \(text.joined(separator: " "))")
    }

    private func texture(_ view: SKView, _ name: String) {
        guard let host = view.scene, let image = view.texture(from: host)?.cgImage() else { return note("\(name): SKView.texture(from:) gave nothing") }
        png(NSBitmapImageRep(cgImage: image), name)
    }

    /// Updates SpriteKit gives the scene over `seconds`, the frame intervals by SpriteKit's own clock, and main-thread CPU.
    private func frames(_ scene: PlazaScene, _ seconds: TimeInterval, _ label: String) throws -> Int {
        let start = scene.updateCount
        let cpu0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        var times: [TimeInterval] = []
        let end = Date().addingTimeInterval(seconds)
        var last = scene.lastFrameTime
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 480))
            if let t = scene.lastFrameTime, t != last { times.append(t); last = t }
            if Date().timeIntervalSince(lastFocusCheck) > 0.05 { try checkFocus(label) }
        }
        try checkFocus(label)
        let cpu = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpu0) / 1e6
        let n = scene.updateCount - start
        let gaps = zip(times.dropFirst(), times).map { ($0 - $1) * 1000 }.sorted()
        func pct(_ p: Double) -> Double { gaps.isEmpty ? 0 : gaps[min(gaps.count - 1, Int(Double(gaps.count) * p))] }
        note(String(format: "%@: %d updates in %.1f s (%.1f/s); frame gap ms p50 %.2f p95 %.2f max %.2f; main-thread CPU %.0f ms (%.3f ms/update)",
                    label, n, seconds, Double(n) / seconds, pct(0.5), pct(0.95), gaps.last ?? 0, cpu, n > 0 ? cpu / Double(n) : 0))
        return n
    }

    func testLiveWindowChecklist() throws {
        guard let dir = PlazaRenderEnv.value("PTB_PLAZA_LIVE_WINDOW") else { throw XCTSkip("PTB_PLAZA_LIVE_WINDOW not set (needs the user's hands-off time)") }
        let app = NSApplication.shared   // the one deliberate touch; never finishLaunching, run or activate
        self.app = app
        out = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        defer { try? (lines.joined(separator: "\n") + "\n").write(to: out.appendingPathComponent("findings.txt"), atomically: true, encoding: .utf8) }

        let offscreen = NSPoint(x: -10000, y: -10000)
        let reach = NSRect(origin: offscreen, size: NSSize(width: 1400, height: 1000))   // the largest window size used below
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(reach) }) {
            throw XCTSkip("a screen (\(screen.localizedName) \(NSStringFromRect(screen.frame))) reaches \(NSStringFromRect(reach)); the window would be visible")
        }
        frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        note("frontmost app at start: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "-") pid \(frontmostPID.map(String.init) ?? "-"); this process active \(app.isActive)")
        XCTAssertFalse(app.isActive)

        let shell = PlazaMacWindow(autosaveName: "", styleMask: [.borderless], front: { [weak self] w in
            self?.windows.append(w)
            w.setFrameOrigin(offscreen)
            w.orderFront(nil)   // not key, not main, not activated
        })
        var log: [String] = []
        let c = PlazaWindowController(preferences: PlazaPreferences(defaults: TestDefaults.make(suite: "plaza.live.\(UUID())")),
                                      loader: PlazaCharacterLoader(fetcher: LiveNoSprites()),
                                      nickname: { "tester" }, memberID: { "member-1" }, subject: { .init(speciesID: 25, isShiny: false) },
                                      dittoSeed: { 7 }, shell: shell)
        teardown = { [weak self, weak c, weak shell] in
            for w in self?.windows ?? [] { w.orderOut(nil) }
            c?.handleClose()      // stops presenting, dismantles the window
            shell?.stopPresenting()
            shell?.dismantle()
            self?.windows = []
        }
        defer { teardown() }
        c.stateLog = { [weak self] in log.append($0); self?.note("state log: \($0)") }

        // Open through the production path (show), minus activation.
        c.show()
        // Implicitly unwrapped so step 6 can drop the test's own strong references before asking whether the closed scene is freed.
        var w: NSWindow! = try XCTUnwrap(shell.windowForTesting)
        var view: SKView! = try XCTUnwrap(shell.skViewForTesting)
        var container: NSView! = try XCTUnwrap(w.contentView)
        var scene: PlazaScene! = try XCTUnwrap(c.scene)
        try spin(1, "open")
        note("opened: frame \(NSStringFromRect(w.frame)) screen \(w.screen?.localizedName ?? "none") visible \(w.isVisible) key \(w.isKeyWindow) main \(w.isMainWindow) "
            + "occlusionVisible \(w.occlusionState.contains(.visible))")
        note("state lines so far (occlusion reports, watchdog): \(log.count)")

        // Backing scale.
        note("backing: window \(w.backingScaleFactor) screen \(w.screen?.backingScaleFactor.description ?? "-") stage \(scene.stage.backingScale?.description ?? "nil") "
            + "screens \(NSScreen.screens.map { "\($0.localizedName)@\($0.backingScaleFactor)" })")
        XCTAssertEqual(scene.stage.backingScale, w.backingScaleFactor, "the scene reads the window's backing scale")

        // Rendering on whatever occlusion said, then real frames.
        c.setRendering(visible: true)
        let drawsOffscreen = try frames(scene, 2, "rendering on (offscreen window)") > 0
        if !drawsOffscreen { note("FINDING: the SKView draws no frames in a window off every screen; display-link, pacing and frame-dependent checks below are not observable this way") }

        // 1. The view's pause reaches the scene's setter before the controller writes it, then the log line.
        let probe = LiveProbeLoop(view: view)
        probe.scene = scene
        var order: [String] = []
        probe.record = { order.append($0) }
        c.renderLoop = probe
        c.stateLog = { order.append("log: \($0)"); log.append($0) }
        scene.handleKeyDown(keyCode: PlazaKeyCode.d, characters: nil, isRepeat: false)
        scene.handleKeyUp(keyCode: PlazaKeyCode.d)
        note("dancing before hide: \(scene.isDancing(memberID: nil))")
        c.setRendering(visible: false)
        c.setRendering(visible: true)
        for line in order { note("pause order: \(line)") }
        XCTAssertTrue(order.first?.contains("SKScene.isPaused=true") == true, "SpriteKit pauses its scene with the view")
        XCTAssertTrue(order.count >= 2 && order[1].hasPrefix("log: plaza rendering visible=false"), "the log line follows the view's pause")
        c.renderLoop = view
        c.stateLog = { [weak self] in log.append($0); self?.note("state log: \($0)") }
        try checkFocus("pause order")

        // 2. Display-link stall recovery through the host: what the watchdog's kick does to a running view.
        if drawsOffscreen {
            view.isPaused = true
            let paused = try frames(scene, 0.5, "view paused")
            view.isPaused = false
            let resumed = try frames(scene, 1, "after one pause/resume kick")
            XCTAssertEqual(paused, 0)
            XCTAssertGreaterThan(resumed, 0, "a pause and resume of the view brings frames back")
        }
        note("watchdog kicks logged so far: \(log.filter { $0.contains("render loop stalled") }.count)")

        // 3. Background: default (map shown) and hidden (see-through window), as the window caches them and as SpriteKit renders.
        sample(snapshot(container, "default-window.png"), "default window")
        texture(view, "default-skview-texture.png")
        note(String(format: "default: window opaque %@ shadow %@ bg %@ allowsTransparency %@ SKScene bg alpha %.2f",
                    "\(w.isOpaque)", "\(w.hasShadow)", "\(w.backgroundColor)", "\(view.allowsTransparency)", view.scene?.backgroundColor.alphaComponent ?? -1))
        c.toggleBackground()
        try spin(0.5, "background hidden")
        XCTAssertFalse(w.isOpaque)
        XCTAssertFalse(w.hasShadow)
        XCTAssertEqual(view.scene?.backgroundColor.alphaComponent, 0)
        sample(snapshot(container, "hidden-window.png"), "hidden window")
        texture(view, "hidden-skview-texture.png")
        note(String(format: "hidden: window opaque %@ shadow %@ bg %@ SKScene bg alpha %.2f", "\(w.isOpaque)", "\(w.hasShadow)", "\(w.backgroundColor)",
                    view.scene?.backgroundColor.alphaComponent ?? -1))
        c.toggleBackground()
        try spin(0.3, "background shown")

        // 4. Resize: .resizeFill keeps SpriteKit's scene at the view's size, and a zoom change during a resize lays out once more.
        for (i, size) in [NSSize(width: 600, height: 372), NSSize(width: 1201, height: 801), NSSize(width: 961, height: 641)].enumerated() {
            w.setFrame(NSRect(origin: offscreen, size: size), display: true)
            if i == 1 { scene.zoom = 3 }
            try spin(0.3, "resize \(i)")
            if i == 1 { scene.zoom = 1 }
            try spin(0.2, "resize \(i) zoom back")
            note("resize \(Int(size.width))x\(Int(size.height)): view \(NSStringFromSize(view.bounds.size)) SKScene \(NSStringFromSize(view.scene?.size ?? .zero)) "
                + "scene \(NSStringFromSize(scene.size)) zoom \(scene.zoom) visibleWorld \(NSStringFromRect(scene.visibleWorldRect)) liveResize \(shell.isInLiveResize) "
                + "roster capacity \(c.rosterModel.capacity)")
            XCTAssertEqual(scene.size, view.bounds.size, "the scene follows the view")
            XCTAssertEqual(c.rosterModel.capacity, PlazaRoster.capacity(forHeight: container.bounds.height), "a resize reaches the roster")
        }
        _ = snapshot(container, "after-resize-window.png")

        // 5. Ordered out and in again (no activation); then the controller's own hide.
        w.orderOut(nil)
        try spin(1, "ordered out")
        note("ordered out: occlusionVisible \(w.occlusionState.contains(.visible)) view paused \(view.isPaused) scene paused \(scene.isPaused)")
        w.orderFront(nil)
        try spin(1, "ordered in")
        note("ordered in again: occlusionVisible \(w.occlusionState.contains(.visible)) view paused \(view.isPaused) scene paused \(scene.isPaused)")
        c.setRendering(visible: false)
        XCTAssertEqual(try frames(scene, 1, "hidden by setRendering(false)"), 0, "a hidden plaza gets no frames")
        c.setRendering(visible: true)
        _ = try frames(scene, 1, "shown by setRendering(true)")

        // 6. Close through the window (the delegate path) and reopen: the old SKScene is freed.
        weak var oldHost = view.scene
        weak var oldScene = c.scene
        w.orderOut(nil)
        w.close()
        // The first run reported both alive only because these locals still held them.
        scene = nil; view = nil; container = nil; w = nil
        autoreleasepool {}
        try spin(0.5, "closed")
        note("closed: scene \(c.scene == nil ? "released" : "kept") old SKScene \(oldHost == nil ? "freed" : "alive") old PlazaScene \(oldScene == nil ? "freed" : "alive")")
        XCTAssertNil(c.scene)
        XCTAssertNil(oldScene, "the closed plaza's scene is freed")
        XCTAssertNil(oldHost, "the closed plaza's SKScene is freed")
        c.show()
        let view2 = try XCTUnwrap(shell.skViewForTesting)
        scene = try XCTUnwrap(c.scene)
        XCTAssertFalse(view2.scene === oldHost)
        c.setRendering(visible: true)

        // 7. Frame pacing under the real SKView.
        _ = try frames(scene, 3, "pacing after reopen")
        try checkFocus("end")
        XCTAssertFalse(app.isActive)
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, frontmostPID, "the frontmost app never changed")
        note("end: frontmost \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "-"), this process active \(app.isActive)")
    }
}
