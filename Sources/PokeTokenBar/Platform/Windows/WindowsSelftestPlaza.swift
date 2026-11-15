#if os(Windows)
import CPlazaD2D
import CWinShim
import Foundation
import WinSDK

/// Stage 6 Task 5: the plaza window on the runner's desktop (`plaza.*`). A controller with in-memory settings, no team
/// session and the placeholder sprite, its window at a fixed place; teammates are FIXTURES (plain blocks of bytes standing
/// in for sprites) driven through the scene. Activation and the real move loop only when `CI` is set; on a person's PC the
/// window is shown without taking the foreground. Runs after the idle window (it loads Direct3D).
extension WindowsSelftest {
    static let plazaPlacementKey = "ptb.selftest.plaza.placement"

    /// A thread-safe counter / flag for the helper threads below.
    final class PlazaTally: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        private var flag = false
        func add() { lock.lock(); n += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
        func set() { lock.lock(); flag = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    }

    @MainActor static func plazaWindowChecks(_ r: Recorder, _ app: WindowsAppDelegate) async {
        guard WinPlazaLive.isInstalled else {
            r.add("plaza.window", false, "WinPlazaLive is not installed: the app would show the headless plaza")
            return
        }
        let defaults = WinDefaultsSync.makeAppDefaults()
        defaults.removeObject(forKey: plazaPlacementKey)
        defaults.removeObject(forKey: plazaPlacementKey + ".static")
        let events = Platform.current.events as? WindowsSystemEvents
        let bytesBefore = ptb_gfx_process_private_bytes(), handlesBefore = ptb_process_handle_count()
        let shell = WinPlazaWindow(placementKey: plazaPlacementKey, defaults: defaults, allowActivation: onCI, systemEvents: events)
        let prefs = PlazaPreferences(defaults: defaults)
        let c = PlazaWindowController(preferences: prefs, loader: PlazaCharacterLoader(fetcher: PlazaStubSpriteFetcher(log: { _ in })),
                                      nickname: { "selftest" }, memberID: { "selftest-me" },
                                      subject: { .init(speciesID: 25, isShiny: false) }, teamName: { "selftest" },
                                      shell: shell, chatInput: PlazaStubChatInput())
        await plazaStaticChecks(r, defaults: defaults, events: events, overlays: c.overlayBindings)
        await plazaLiveChecks(r, c, shell, app, bytesBefore: bytesBefore, handlesBefore: handlesBefore)
    }

    // MARK: - the shell alone, a still tree

    /// The window without a controller: hidden until `bringToFront`, its class, style, DPI awareness and title, the minimum
    /// size at 96 and at a synthetic 144 dpi, the first present, ZERO presents while nothing changes, and device losses.
    @MainActor private static func plazaStaticChecks(_ r: Recorder, defaults: UserDefaults, events: WindowsSystemEvents?,
                                                     overlays: PlazaOverlayBindings) async {
        let shell = WinPlazaWindow(placementKey: plazaPlacementKey + ".static", defaults: defaults, allowActivation: onCI, systemEvents: events)
        let stage = WinPlazaStage(size: CGSize(width: 960, height: 640))
        stage.backgroundColor = PlazaColor(hex: 0x2E7D32)
        let map = PlazaMapData.map
        let image = PlatformPlaza.tileSheet().map { PlazaTileArt.mapImage(map, sheet: $0, tallGrass: PlatformPlaza.tallGrassArt()) }
            ?? PlazaTileArt.plainGrassImage(map)
        let sprite = PlazaSprite(texture: PlazaTexture(image), size: CGSize(width: image.width, height: image.height))
        sprite.anchorPoint = .zero
        stage.root.addChild(sprite)
        let title = "PokeTokenBar selftest plaza"
        shell.open(stage: stage, title: title, overlays: overlays)
        guard let hwnd = shell.hwndForTesting else {
            r.add("plaza.window", false, "no window: \(shell.openFailure ?? "?")")
            return
        }
        let raw = UnsafeMutableRawPointer(hwnd)
        let hiddenAtOpen = !IsWindowVisible(hwnd)
        var classBuf = [UInt16](repeating: 0, count: 64), titleBuf = [UInt16](repeating: 0, count: 128)
        let classLen = Int(GetClassNameW(hwnd, &classBuf, Int32(classBuf.count)))
        let titleLen = Int(GetWindowTextW(hwnd, &titleBuf, Int32(titleBuf.count)))
        let className = String(decoding: classBuf.prefix(classLen), as: UTF16.self)
        let shownTitle = String(decoding: titleBuf.prefix(titleLen), as: UTF16.self)
        let style = UInt32(truncatingIfNeeded: GetWindowLongPtrW(hwnd, GWL_STYLE)), ex = UInt32(truncatingIfNeeded: GetWindowLongPtrW(hwnd, GWL_EXSTYLE))
        var v2: Int32 = 0
        let awareness = ptb_window_dpi_awareness(raw, &v2)
        var mmi = MINMAXINFO()
        _ = withUnsafeMutablePointer(to: &mmi) { SendMessageW(hwnd, 0x0024, 0, LPARAM(Int(bitPattern: $0))) }
        let dpi = shell.dpiForTesting
        let atDpi = shell.minTrackSize(dpi: dpi)
        let min96 = shell.minTrackSize(dpi: 96)
        let expected96 = WinPlazaWindow.frame(96, 600, 372)
        let min144 = shell.minTrackSize(dpi: 144)
        let expected144 = WinPlazaWindow.frame(144, 900, 558)
        let stillHidden = !IsWindowVisible(hwnd)
        shell.bringToFront()
        let shownAfter = IsWindowVisible(hwnd)
        if onCI { forceForeground(hwnd) }
        _ = await waitUntil(timeout: 2) { shell.stats.presents >= 1 }
        let firstPresents = shell.stats.presents
        let pixels = shell.frameRGBAForTesting()
        r.add("plaza.window",
              hiddenAtOpen && stillHidden && shownAfter && className == WinPlazaWindow.className && shownTitle == title
                && style & 0x00CF_0000 == 0x00CF_0000 && ex & 0x0020_0000 != 0 && awareness == 2 && v2 == 1
                && mmi.ptMinTrackSize.x == atDpi.width && mmi.ptMinTrackSize.y == atDpi.height
                && min96.width == expected96.width && min96.height == expected96.height
                && min144.width == expected144.width && min144.height == expected144.height,
              "hidden at open=\(hiddenAtOpen), still hidden before bringToFront=\(stillHidden), shown by bringToFront=\(shownAfter); "
                + "class=\(className) title='\(shownTitle)' style=0x\(String(style, radix: 16)) ex=0x\(String(ex, radix: 16)) "
                + "dpiAwareness=\(awareness) perMonitorV2=\(v2) dpi=\(dpi) WM_GETMINMAXINFO minTrack=\(mmi.ptMinTrackSize.x)x\(mmi.ptMinTrackSize.y) "
                + "(600x372 DIP at \(dpi): \(atDpi.width)x\(atDpi.height); at 96: \(min96.width)x\(min96.height), expected \(expected96.width)x\(expected96.height)) "
                + "minTrack@144=\(min144.width)x\(min144.height) "
                + "(expected \(expected144.width)x\(expected144.height))")
        r.add("plaza.firstFrame", firstPresents >= 1 && pixels != nil,
              "presents=\(firstPresents) before/at first show, frame readback \(pixels.map { "\($0.count / 4) px" } ?? "none")")

        // Nothing changes: the clock ticks, nothing is drawn or presented (D3).
        _ = await waitUntil(timeout: 1) { false }
        let s0 = shell.stats
        _ = await waitUntil(timeout: 10) { false }
        let s1 = shell.stats
        let ticks = s1.ticks - s0.ticks
        r.add("plaza.idleStatic", s1.presents == s0.presents && s1.draws == s0.draws && ticks >= 500,
              "a still tree, visible, 10 s: ticks=\(ticks) draws=\(s1.draws - s0.draws) presents=\(s1.presents - s0.presents) clean=\(s1.cleanTicks - s0.cleanTicks) "
                + "(ZERO presents when nothing changed; the clock still runs the scene's update every frame)")

        // Device loss: at EndDraw (the renderer's path) and at Present (the window's), each redrawn with the same pixels.
        if let device = shell.deviceForTesting, let before = shell.frameRGBAForTesting() {
            let g0 = device.generation, made0 = shell.surfaceForTesting?.windowStats.swapChainsMade ?? 0
            device.injectDeviceLoss()
            stage.setNeedsDraw()
            _ = await waitUntil(timeout: 2) { shell.stats.presents > s1.presents && device.generation > g0 }
            let afterEndDraw = shell.frameRGBAForTesting()
            let g1 = device.generation, p1 = shell.stats.presents
            ptb_gfx_inject_fault(device.owner.raw, 2)
            stage.setNeedsDraw()
            _ = await waitUntil(timeout: 2) { shell.stats.presents > p1 && device.generation > g1 }
            let afterPresent = shell.frameRGBAForTesting()
            let made = (shell.surfaceForTesting?.windowStats.swapChainsMade ?? 0) - made0
            r.add("plaza.deviceLoss", device.generation == g0 + 2 && afterEndDraw == before && afterPresent == before && made >= 2,
                  "EndDraw loss then Present loss: generation \(g0) -> \(device.generation), swap chains made again \(made), "
                    + "losses counted \(shell.stats.deviceLosses), pixels equal after each rebuild: \(afterEndDraw == before) / \(afterPresent == before)")
        } else {
            r.add("plaza.deviceLoss", false, "no device or no frame to compare")
        }
        shell.requestClose()   // no controller: the window dismantles itself
        r.add("plaza.staticClosed", shell.hwndForTesting == nil && shell.lastClosed?.clockJoined == true && ptb_window_hooks_live() == 0,
              "window gone=\(shell.hwndForTesting == nil) clock joined=\(shell.lastClosed?.clockJoined.description ?? "-") hooks=\(ptb_window_hooks_live())")
    }

    // MARK: - the controller's window

    @MainActor private static func plazaLiveChecks(_ r: Recorder, _ c: PlazaWindowController, _ shell: WinPlazaWindow,
                                                   _ app: WindowsAppDelegate, bytesBefore: UInt64, handlesBefore: UInt32) async {
        c.show()
        guard let hwnd = shell.hwndForTesting, c.scene != nil else {
            r.add("plaza.frames", false, "the controller's window did not open: \(shell.openFailure ?? "?")")
            return
        }
        var scene: PlazaScene? = c.scene   // dropped before the close check, which asks whether the controller let go of it
        weak var weakScene = scene
        weak var weakStage = shell.stageForTesting
        weak var weakDevice = shell.deviceForTesting?.owner
        _ = SetWindowPos(hwnd, nil, 40, 40, 0, 0, UINT(SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE))
        if onCI { forceForeground(hwnd) }
        _ = await waitUntil(timeout: 2) { shell.stats.presents >= 1 }
        let bytesOpen = ptb_gfx_process_private_bytes()

        // Fixture teammates walking around me.
        let frames = fixtureFrames()
        let me = scene?.walker.tile ?? TilePoint(x: 19, y: 10)
        var members = (0..<6).map { i in
            PlazaSceneMember(memberID: "fixture-\(i)", nickname: "Fixture \(i)", isAway: false,
                             tile: TilePoint(x: me.x - 3 + i, y: me.y + (i % 2 == 0 ? 2 : -2)), facing: .down, isWalking: true)
        }
        scene?.applyMembers(members)
        for m in members { scene?.setMemberFrames(m.memberID, frames) }
        func walk(_ step: Int) {
            for i in members.indices {
                guard let tile = members[i].tile else { continue }
                members[i] = PlazaSceneMember(memberID: members[i].memberID, nickname: members[i].nickname, isAway: false,
                                              tile: TilePoint(x: tile.x + ((step + i) % 2 == 0 ? 1 : -1), y: tile.y),
                                              facing: members[i].facing, isWalking: true)
            }
            scene?.applyMembers(members)
        }

        // plaza.frames: 3 s while teammates walk.
        _ = shell.viewForTesting?.clock?.stats(resetIntervals: true)
        let f0 = shell.stats
        for step in 0..<6 {
            walk(step)
            _ = await waitUntil(timeout: 0.5) { false }
        }
        let f1 = shell.stats
        let clock = shell.clockStatsForTesting ?? PTBClockStats()
        let ticksPerSecond = Double(f1.ticks - f0.ticks) / 3, draws = f1.draws - f0.draws, presents = f1.presents - f0.presents
        let source = clock.source == 1 ? "vblank \(clock.refreshHz) Hz / \(clock.divider)" : "timer 60 Hz (high resolution \(clock.highResolutionTimer != 0))"
        r.add("plaza.frames", abs(ticksPerSecond - 60) <= 5 && draws <= f1.ticks - f0.ticks && presents == draws && draws > 30,
              "3 s, 6 FIXTURE teammates walking: ticks/s=\(pf2(ticksPerSecond)) draws=\(draws) presents=\(presents) gpuBusy=\(f1.gpuBusy - f0.gpuBusy) "
                + "clean=\(f1.cleanTicks - f0.cleanTicks); clock source=\(source) fallbacks=\(clock.fallbacks) earlyReturns=\(clock.earlyReturns); "
                + "tick interval p50=\(pf2(clock.p50Ms)) p95=\(pf2(clock.p95Ms)) p99=\(pf2(clock.p99Ms)) max=\(pf2(clock.maxMs)) ms (n=\(clock.samples)); "
                + "last frame draw=\(pf2(f1.lastDrawMs)) present=\(pf2(f1.lastPresentMs)) ms; adapter='\(shell.deviceForTesting?.adapter ?? "-")' warp=\(shell.deviceForTesting?.isWarp ?? false)")

        // plaza.capture: what the screen shows over the window equals the frame bitmap (R3: is DComp content captured?).
        await captureCheck(r, shell, hwnd)

        // plaza.idleVisible: nobody moves (the fixtures stand still), visible: what the shared scene itself still changes.
        members = members.map { PlazaSceneMember(memberID: $0.memberID, nickname: $0.nickname, isAway: false, tile: $0.tile, facing: $0.facing, isWalking: false) }
        scene?.applyMembers(members)
        _ = await waitUntil(timeout: 2) { false }
        let clockTid = shell.clockStatsForTesting?.threadId ?? 0
        let i0 = shell.stats
        let idleSample = await IdleSampler.measure(seconds: 10, mainThread: WindowsApp.mainThreadID)
        let i1 = shell.stats
        let clockCs = idleSample?.active.first { $0.tid == clockTid }?.cs ?? 0
        r.add("plaza.idleVisible", Double(i1.draws - i0.draws) / 10 <= 20 && i1.presents - i0.presents == i1.draws - i0.draws,
              "visible, nobody walking, 10 s: ticks=\(i1.ticks - i0.ticks) draws=\(i1.draws - i0.draws) (\(pf2(Double(i1.draws - i0.draws) / 10))/s, D19 <= 20/s) "
                + "presents=\(i1.presents - i0.presents) clean=\(i1.cleanTicks - i0.cleanTicks) clock thread cs=\(clockCs) main cs=\(idleSample?.mainContextSwitches ?? -1) "
                + "main cycles=\(idleSample?.mainCycles ?? 0) process cycles=\(idleSample?.processCycles ?? 0); what still draws: the shared scene's own "
                + "animation (sprite frames, bobbing, daylight, water)")

        // plaza.minimize / plaza.restore: the clock thread parks (0 context switches in 5 s) and runs again.
        await pauseCheck(r, "plaza.minimize", "plaza.restore", shell, clockTid: clockTid, measure: true,
                         hide: { _ = ShowWindow(hwnd, 7 /* SW_SHOWMINNOACTIVE */) }, show: { _ = ShowWindow(hwnd, 4 /* SW_SHOWNOACTIVATE */) })
        if onCI { forceForeground(hwnd) }

        // plaza.cover: an opaque window over it, then moved away (the 1 Hz check; at once on activation events).
        await coverCheck(r, shell, hwnd)
        if onCI { forceForeground(hwnd) }

        // plaza.lock (WM_WTSSESSION_CHANGE lock / unlock, remote disconnect / connect), plaza.displayOff, plaza.cloak.
        await pauseCheck(r, "plaza.lock", nil, shell, clockTid: clockTid, measure: false,
                         hide: { _ = SendMessageW(hwnd, 0x02B1, 7, 0) }, show: { _ = SendMessageW(hwnd, 0x02B1, 8, 0) })
        await pauseCheck(r, "plaza.remoteDisconnect", nil, shell, clockTid: clockTid, measure: false,
                         hide: { _ = SendMessageW(hwnd, 0x02B1, 4, 0) }, show: { _ = SendMessageW(hwnd, 0x02B1, 3, 0) })
        await pauseCheck(r, "plaza.displayOff", nil, shell, clockTid: clockTid, measure: false,
                         hide: { WinPlazaLive.current?.displaysChanged(asleep: true) }, show: { WinPlazaLive.current?.displaysChanged(asleep: false) })
        let hooksBefore = shell.visibility.hookEvents
        await pauseCheck(r, "plaza.cloak", nil, shell, clockTid: clockTid, measure: false,
                         hide: { _ = ptb_window_set_cloak(UnsafeMutableRawPointer(hwnd), 1) },
                         show: { _ = ptb_window_set_cloak(UnsafeMutableRawPointer(hwnd), 0) },
                         note: { "cloak events through the WinEvent hook: \(shell.visibility.hookEvents - hooksBefore)" })
        if onCI { forceForeground(hwnd) }

        // plaza.dpi: a synthetic WM_DPICHANGED to 144 dpi and back.
        await dpiCheck(r, shell, hwnd)
        // plaza.resize: buffers follow the client area and a frame is drawn at the new size.
        await resizeCheck(r, shell, hwnd)
        // plaza.dragDraws: the window's move/size loop keeps the frames and the main queue going.
        await dragCheck(r, shell, hwnd)
        // plaza.focus: what teammates and timers trigger never brings the plaza forward.
        if let s = scene { await focusCheck(r, c, shell, hwnd, scene: s, members: members) }
        scene = nil   // the selftest's own reference: the close check below asks whether the controller let go of it

        // plaza.close (x3 open/close cycles), plaza.reopen, plaza.placement (a child process restores the saved frame).
        let closeFrame = WinPlazaWindow.frame(shell.dpiForTesting, 1000, 660)
        _ = SetWindowPos(hwnd, nil, 100, 120, closeFrame.width, closeFrame.height, UINT(SWP_NOZORDER | SWP_NOACTIVATE))
        var saved = RECT()
        _ = GetWindowRect(hwnd, &saved)
        let clockTidAtClose = shell.clockStatsForTesting?.threadId ?? 0
        shell.requestClose()
        _ = await waitUntil(timeout: 1) { false }
        let gone = clockThreadGone(clockTidAtClose)
        let released = weakScene == nil && weakStage == nil
        let deviceReleased = weakDevice == nil
        _ = await waitUntil(timeout: 10) { false }   // D19: "private bytes within +20 MB after 10 s"
        let bytesClosed = ptb_gfx_process_private_bytes(), handlesClosed = ptb_process_handle_count()
        var cycles: [(handles: UInt32, bytes: UInt64, presented: Bool, joined: Bool)] = []
        for _ in 0..<3 {
            c.show()
            let opened = await waitUntil(timeout: 3) { shell.stats.presents >= 1 }
            shell.requestClose()
            _ = await waitUntil(timeout: 0.5) { false }
            cycles.append((ptb_process_handle_count(), ptb_gfx_process_private_bytes(), opened, shell.lastClosed?.clockJoined == true))
        }
        let leak = Int(cycles.last?.handles ?? 0) - Int(cycles.first?.handles ?? 0)
        r.add("plaza.close",
              shell.hwndForTesting == nil && gone && released && deviceReleased && ptb_window_hooks_live() == 0 && leak <= 10
                && cycles.allSatisfy { $0.presented && $0.joined } && shell.visibility.isPolling == false,
              "clock thread \(clockTidAtClose) gone=\(gone), scene and stage released=\(released) (weak refs nil), Direct3D device released=\(deviceReleased), "
                + "WinEvent hooks=\(ptb_window_hooks_live()), cover timer off=\(!shell.visibility.isPolling); handles before first open \(handlesBefore), "
                + "after close \(handlesClosed), after cycles \(cycles.map { $0.handles }) (growth over cycles \(leak), budget 10); private MB before "
                + "\(pmb(bytesBefore)) open \(pmb(bytesOpen)) closed+10s \(pmb(bytesClosed)) cycles \(cycles.map { pmb($0.bytes) }) "
                + "(closed - before \(pmb(bytesClosed &- bytesBefore)) MB: graphics DLLs and WARP stay loaded); 3 open/close cycles presented=\(cycles.map { $0.presented })")
        r.add("plaza.reopen", cycles.count == 3 && cycles.allSatisfy { $0.presented },
              "three reopenings each presented a first frame: \(cycles.map { $0.presented })")
        await placementCheck(r, expected: saved)
    }

    // MARK: - pieces

    @MainActor private static func fixtureFrames() -> PlazaCharacterFrames {
        var block = PlazaBitmap(width: 20, height: 24)   // FIXTURE: a plain block standing in for a sprite
        for y in 2..<22 { for x in 3..<17 { block[x, y] = PlazaRGBA(r: 200, g: 60, b: 160, a: 255) } }
        var second = block
        for x in 6..<9 { second[x, 6] = PlazaRGBA(r: 20, g: 20, b: 20, a: 255) }
        return PlazaCharacterFrames(front: [PlazaFrame(image: PlazaImage(bitmap: block), delay: 0.2), PlazaFrame(image: PlazaImage(bitmap: second), delay: 0.2)],
                                    back: [PlazaFrame(image: PlazaImage(bitmap: block), delay: 0.2)])
    }

    @MainActor private static func captureCheck(_ r: Recorder, _ shell: WinPlazaWindow, _ hwnd: HWND) async {
        _ = await waitUntil(timeout: 0.3) { false }
        guard let stage = shell.stageForTesting else { r.add("plaza.capture", false, "no stage"); return }
        stage.isPaused = true   // a still frame to compare (the clock parks; nothing is drawn meanwhile)
        _ = await waitUntil(timeout: 0.5) { false }
        var client = RECT()
        _ = GetClientRect(hwnd, &client)
        var origin = POINT(x: 0, y: 0)
        _ = ClientToScreen(hwnd, &origin)
        let w = Int(client.right), h = Int(client.bottom)
        let frame = shell.frameRGBAForTesting()
        let screen = WinUIDump.screenshot(x: Int(origin.x), y: Int(origin.y), w: w, h: h)
        var printed: WinUIDump.Bitmap?
        var pw: UInt32 = 0, ph: UInt32 = 0
        var pbits: UnsafeMutablePointer<UInt8>?
        if ptb_window_print(UnsafeMutableRawPointer(hwnd), &pw, &ph, &pbits) == 0, let pbits {
            printed = WinUIDump.Bitmap(width: Int(pw), height: Int(ph), bgra: Array(UnsafeBufferPointer(start: pbits, count: Int(pw * ph * 4))))
            ptb_plaza_free(pbits)
        }
        stage.isPaused = false
        guard let frame, frame.count == w * h * 4 else { r.add("plaza.capture", false, "no frame readback at \(w)x\(h)"); return }
        // A map region away from the centre (my character) and the edges: 160 x 120 px from (24, 24).
        func compare(_ b: WinUIDump.Bitmap?) -> (worst: Int, over: Int)? {
            guard let b, b.width == w, b.height == h else { return nil }
            var worst = 0, over = 0
            for y in 24..<min(h, 144) {
                for x in 24..<min(w, 184) {
                    let i = (y * w + x) * 4
                    let d = max(abs(Int(frame[i]) - Int(b.bgra[i + 2])), abs(Int(frame[i + 1]) - Int(b.bgra[i + 1])), abs(Int(frame[i + 2]) - Int(b.bgra[i])))
                    worst = max(worst, d)
                    if d > 2 { over += 1 }
                }
            }
            return (worst, over)
        }
        let viaScreen = compare(screen), viaPrint = compare(printed)
        let dir = selftestOutDirectory()
        var bgra = [UInt8](repeating: 0, count: frame.count)
        for i in stride(from: 0, to: frame.count, by: 4) { bgra[i] = frame[i + 2]; bgra[i + 1] = frame[i + 1]; bgra[i + 2] = frame[i]; bgra[i + 3] = 255 }
        let wroteFrame = WinUIDump.write(WinUIDump.Bitmap(width: w, height: h, bgra: bgra), to: dir.appendingPathComponent("plaza-frame.png"))
        let wroteScreen = screen.map { WinUIDump.write($0, to: dir.appendingPathComponent("plaza-capture.png")) } ?? -1
        let wrotePrint = printed.map { WinUIDump.write($0, to: dir.appendingPathComponent("plaza-printwindow.png")) } ?? -1
        // The brief's evidence is the screen; PrintWindow is the R3 fallback when GDI cannot see the composition.
        r.add("plaza.capture", (viaScreen?.worst ?? 255) <= 2 || (viaPrint?.worst ?? 255) <= 2,
              "client \(w)x\(h) at (\(origin.x),\(origin.y)); screen (BitBlt CAPTUREBLT) vs frame bitmap over 160x120 map px: "
                + "\(viaScreen.map { "worst |d|=\($0.worst), \($0.over) px over 2" } ?? "no capture"); PrintWindow(PW_RENDERFULLCONTENT): "
                + "\(viaPrint.map { "worst |d|=\($0.worst), \($0.over) px over 2" } ?? "no capture"); PNGs written frame=\(wroteFrame) "
                + "screen=\(wroteScreen) print=\(wrotePrint) in \(WinPath.native(dir))")
    }

    /// `hide` must stop the frames (the view paused, the clock parked) within 1.5 s; `show` must bring them back.
    @MainActor private static func pauseCheck(_ r: Recorder, _ name: String, _ resumeName: String?, _ shell: WinPlazaWindow,
                                              clockTid: UInt32, measure: Bool, hide: () -> Void, show: () -> Void,
                                              note: () -> String = { "" }) async {
        guard let view = shell.viewForTesting else { r.add(name, false, "no view"); return }
        let t0 = WinPlazaClock.seconds()
        hide()
        let paused = await waitUntil(timeout: 1.5, poll: 0.01) { !view.isRunning }
        let pausedMs = (WinPlazaClock.seconds() - t0) * 1000
        _ = await waitUntil(timeout: 0.1) { false }
        let s0 = shell.stats
        var clockCs = -1, mainCs = -1
        if measure, let sample = await IdleSampler.measure(seconds: 5, mainThread: WindowsApp.mainThreadID) {
            clockCs = sample.active.first { $0.tid == clockTid }?.cs ?? 0
            mainCs = sample.mainContextSwitches
        } else {
            _ = await waitUntil(timeout: 1) { false }
        }
        let s1 = shell.stats
        let quiet = s1.ticks == s0.ticks && s1.presents == s0.presents && (!measure || clockCs == 0)
        let t1 = WinPlazaClock.seconds()
        show()
        let resumed = await waitUntil(timeout: 1.5, poll: 0.01) { view.isRunning }
        let resumedMs = (WinPlazaClock.seconds() - t1) * 1000
        let s2 = shell.stats
        _ = await waitUntil(timeout: 0.5) { false }
        let ticking = shell.stats.ticks > s2.ticks
        let extra = note()
        r.add(name, paused && quiet && (resumeName != nil || (resumed && ticking)),
              "paused=\(paused) after \(pf2(pausedMs)) ms; while hidden \(measure ? "5" : "1") s: ticks=\(s1.ticks - s0.ticks) presents=\(s1.presents - s0.presents)"
                + "\(measure ? " clock thread cs=\(clockCs) main cs=\(mainCs)" : ""); resumed=\(resumed) after \(pf2(resumedMs)) ms, ticking=\(ticking)"
                + " visible=\(shell.visibility.visible)\(extra.isEmpty ? "" : "; " + extra)")
        if let resumeName {
            r.add(resumeName, resumed && ticking, "resumed=\(resumed) after \(pf2(resumedMs)) ms, ticks in 0.5 s=\(shell.stats.ticks - s2.ticks)")
        }
    }

    @MainActor private static func coverCheck(_ r: Recorder, _ shell: WinPlazaWindow, _ hwnd: HWND) async {
        guard let view = shell.viewForTesting else { r.add("plaza.cover", false, "no view"); return }
        var wr = RECT()
        _ = GetWindowRect(hwnd, &wr)
        let checks0 = shell.visibility.coverChecks, micros0 = shell.visibility.coverMicros
        let cover: WinSinkWindow
        do {
            // WS_POPUP | WS_VISIBLE, WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE: opaque, above, never takes the foreground.
            cover = try WinSinkWindow(className: "PokeTokenBarSelftestCover", title: "cover", style: 0x9000_0000, exStyle: 0x0800_0080,
                                      x: wr.left - 20, y: wr.top - 20, width: wr.right - wr.left + 40, height: wr.bottom - wr.top + 40)
        } catch {
            r.add("plaza.cover", false, "no cover window: \(error)")
            return
        }
        defer { cover.destroy() }
        _ = SetWindowPos(cover.hwnd, nil /* HWND_TOP */, 0, 0, 0, 0, UINT(SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW))
        let t0 = WinPlazaClock.seconds()
        let paused = await waitUntil(timeout: 1.5, poll: 0.01) { !view.isRunning }
        let pausedMs = (WinPlazaClock.seconds() - t0) * 1000
        let above = shell.visibility.lastAbove
        _ = SetWindowPos(cover.hwnd, nil, wr.left - 4000, wr.top, 0, 0, UINT(SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE))
        let t1 = WinPlazaClock.seconds()
        let resumed = await waitUntil(timeout: 1.5, poll: 0.01) { view.isRunning }
        let resumedMs = (WinPlazaClock.seconds() - t1) * 1000
        let n = shell.visibility.coverChecks - checks0
        r.add("plaza.cover", paused && resumed,
              "covered -> paused=\(paused) after \(pf2(pausedMs)) ms (windows above counted \(above)); moved away -> resumed=\(resumed) after \(pf2(resumedMs)) ms; "
                + "cover checks \(n), cost avg \(pf2(n > 0 ? (shell.visibility.coverMicros - micros0) / Double(n) : 0)) us, last \(pf2(shell.visibility.lastCoverMicros)) us")
    }

    @MainActor private static func dpiCheck(_ r: Recorder, _ shell: WinPlazaWindow, _ hwnd: HWND) async {
        var wr = RECT()
        _ = GetWindowRect(hwnd, &wr)
        let p0 = shell.stats.presents
        var suggested = RECT(left: wr.left, top: wr.top, right: wr.left + (wr.right - wr.left) * 3 / 2, bottom: wr.top + (wr.bottom - wr.top) * 3 / 2)
        _ = withUnsafeMutablePointer(to: &suggested) { SendMessageW(hwnd, 0x02E0, WPARAM(144 | (144 << 16)), LPARAM(Int(bitPattern: $0))) }
        _ = await waitUntil(timeout: 1) { shell.stats.presents > p0 }
        var client = RECT()
        _ = GetClientRect(hwnd, &client)
        let backing = shell.stageForTesting?.backingScale ?? 0
        let ws = shell.surfaceForTesting?.windowStats ?? PTBGfxWindowStats()
        let size = shell.stageForTesting?.size ?? .zero
        var mmi = MINMAXINFO()
        _ = withUnsafeMutablePointer(to: &mmi) { SendMessageW(hwnd, 0x0024, 0, LPARAM(Int(bitPattern: $0))) }
        let min144 = WinPlazaWindow.frame(144, 900, 558)
        let ok = backing == 1.5 && ws.bufferWidth == UInt32(client.right) && ws.bufferHeight == UInt32(client.bottom)
            && abs(size.width * 1.5 - CGFloat(client.right)) < 0.01 && shell.stats.presents > p0
            && mmi.ptMinTrackSize.x == min144.width && mmi.ptMinTrackSize.y == min144.height
        let detail = "WM_DPICHANGED 144: backing=\(backing) client=\(client.right)x\(client.bottom) buffers=\(ws.bufferWidth)x\(ws.bufferHeight) "
            + "stage=\(pf2(Double(size.width)))x\(pf2(Double(size.height))) pt presents+\(shell.stats.presents - p0) minTrack=\(mmi.ptMinTrackSize.x)x\(mmi.ptMinTrackSize.y) "
            + "(expected \(min144.width)x\(min144.height)); panels re-render with Task 10"
        var back = wr
        let p1 = shell.stats.presents
        _ = withUnsafeMutablePointer(to: &back) { SendMessageW(hwnd, 0x02E0, WPARAM(96 | (96 << 16)), LPARAM(Int(bitPattern: $0))) }
        _ = await waitUntil(timeout: 1) { shell.stats.presents > p1 }
        let backingAfter = shell.stageForTesting?.backingScale ?? 0
        r.add("plaza.dpi", ok && backingAfter == 1, detail + "; back to 96: backing=\(backingAfter)")
    }

    @MainActor private static func resizeCheck(_ r: Recorder, _ shell: WinPlazaWindow, _ hwnd: HWND) async {
        let f = WinPlazaWindow.frame(shell.dpiForTesting, 1100, 700)
        let p0 = shell.stats.presents, resizes0 = shell.surfaceForTesting?.windowStats.resizes ?? 0
        _ = SetWindowPos(hwnd, nil, 0, 0, f.width, f.height, UINT(SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE))
        _ = await waitUntil(timeout: 1) { shell.stats.presents > p0 }
        var client = RECT()
        _ = GetClientRect(hwnd, &client)
        let ws = shell.surfaceForTesting?.windowStats ?? PTBGfxWindowStats()
        let frame = shell.frameRGBAForTesting()
        let w = Int(client.right), h = Int(client.bottom)
        let corner = frame.flatMap { px -> UInt8? in
            let i = ((h - 2) * w + (w - 2)) * 4
            return px.count == w * h * 4 ? px[i + 3] : nil
        }
        r.add("plaza.resize", client.right == 1100 && client.bottom == 700 && ws.bufferWidth == 1100 && ws.bufferHeight == 700
                && shell.stats.presents > p0 && corner == 255,
              "client=\(client.right)x\(client.bottom) buffers=\(ws.bufferWidth)x\(ws.bufferHeight) ResizeBuffers calls +\(ws.resizes - resizes0) "
                + "presents+\(shell.stats.presents - p0) frame bottom-right alpha=\(corner.map { "\($0)" } ?? "-") (opaque: drawn at the new size)")
    }

    /// The window's modal move loop (WM_SYSCOMMAND SC_MOVE, ended by a posted Escape; CI only) and a synthetic
    /// WM_ENTERSIZEMOVE / WM_EXITSIZEMOVE pair: frames keep coming (posted ticks are dispatched by the loop) and the main
    /// queue keeps running (`WinModalPump`, registered on this window).
    @MainActor private static func dragCheck(_ r: Recorder, _ shell: WinPlazaWindow, _ hwnd: HWND) async {
        let timers0 = WinModalPump.timersSet
        let s0 = shell.stats
        _ = SendMessageW(hwnd, WinModalPump.enterSizeMove, 0, 0)
        let depthDuring = WinModalPump.depth, timerDuring = WinModalPump.timerLive
        _ = await waitUntil(timeout: 1) { false }
        _ = SendMessageW(hwnd, WinModalPump.exitSizeMove, 0, 0)
        let s1 = shell.stats
        let synthetic = "synthetic pair: pump depth during=\(depthDuring) timer=\(timerDuring) after=\(WinModalPump.depth)/\(WinModalPump.timerLive), "
            + "ticks in 1 s=\(s1.ticks - s0.ticks) draws=\(s1.draws - s0.draws)"
        let syntheticOK = depthDuring >= 1 && timerDuring && WinModalPump.depth == 0 && !WinModalPump.timerLive && s1.ticks - s0.ticks >= 45
        guard onCI else {
            r.add("plaza.dragDraws", syntheticOK, synthetic + "; the real move loop runs only on CI")
            return
        }
        // The real loop: a helper thread posts Escape until the loop ends, and DispatchQueue.main blocks meanwhile.
        let done = PlazaTally(), posted = PlazaTally(), ranDuring = PlazaTally(), ranTotal = PlazaTally()
        let bits = Int(bitPattern: hwnd)
        onThread {
            Thread.sleep(forTimeInterval: 1.0)
            for i in 0..<20 where !done.isSet {
                guard let h = HWND(bitPattern: bits) else { return }
                _ = PostMessageW(h, 0x0100 /* WM_KEYDOWN */, 0x1B /* VK_ESCAPE */, 0x0001_0001)
                _ = PostMessageW(h, 0x0101 /* WM_KEYUP */, 0x1B, LPARAM(0xC001_0001))
                if i == 8 { _ = PostMessageW(h, 0x001F /* WM_CANCELMODE */, 0, 0) }
                Thread.sleep(forTimeInterval: 0.3)
            }
        }
        onThread {
            for _ in 0..<40 where !done.isSet {
                posted.add()
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        ranTotal.add()
                        if WinModalPump.depth > 0 { ranDuring.add() }
                    }
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        let d0 = shell.stats, t0 = WinPlazaClock.seconds(), sets0 = WinModalPump.timersSet
        _ = SendMessageW(hwnd, 0x0112 /* WM_SYSCOMMAND */, 0xF010 /* SC_MOVE */, 0)   // returns when the move loop ends
        done.set()
        let loopSeconds = WinPlazaClock.seconds() - t0
        let d1 = shell.stats
        let ticksPerSecond = Double(d1.ticks - d0.ticks) / max(loopSeconds, 0.001)
        r.add("plaza.dragDraws", syntheticOK && loopSeconds >= 0.8 && ticksPerSecond >= 45 && ranDuring.count >= 5 && WinModalPump.timersSet > sets0
                && WinModalPump.depth == 0,
              synthetic + "; real SC_MOVE loop \(pf2(loopSeconds)) s: ticks/s=\(pf2(ticksPerSecond)) draws=\(d1.draws - d0.draws) presents=\(d1.presents - d0.presents), "
                + "main-queue blocks run inside the loop \(ranDuring.count) of \(posted.count) posted, pump timers set \(WinModalPump.timersSet - timers0), depth after \(WinModalPump.depth)")
    }

    @MainActor private static func focusCheck(_ r: Recorder, _ c: PlazaWindowController, _ shell: WinPlazaWindow, _ hwnd: HWND,
                                              scene: PlazaScene, members: [PlazaSceneMember]) async {
        // Another window of ours takes the foreground first (CI), so "never comes forward" can be seen.
        let other: WinSinkWindow? = try? WinSinkWindow(className: "PokeTokenBarSelftestFocus", title: "focus", style: 0x10CF_0000, exStyle: 0,
                                                        x: 700, y: 60, width: 300, height: 200)
        defer { other?.destroy() }
        if onCI, let other { forceForeground(other.hwnd) }
        _ = await waitUntil(timeout: 0.3) { false }
        let foreground0 = GetForegroundWindow()
        let activations0 = shell.stats.activations, shows0 = shell.stats.shows
        let id = members.first?.memberID ?? "fixture-0"
        let presenting: any PlazaPresenting = c
        var joined = members
        joined.append(PlazaSceneMember(memberID: "fixture-new", nickname: "New", isAway: false, tile: members.first?.tile, facing: .left, isWalking: false))
        scene.applyMembers(joined)   // a teammate joins
        presenting.showEmote(memberID: id, kind: .heart, alsoOver: nil, overDecoy: false)
        presenting.showChat(memberID: id, text: "안녕", isLoud: true)
        presenting.showJump(memberID: id, iceBreak: nil)
        presenting.showDance(memberID: id, style: nil, since: nil)
        presenting.stopDance(memberID: id)
        presenting.showFirework(memberID: id, style: nil)
        presenting.showPickup(from: id, slot: 0)
        presenting.showGroupPhoto(from: id)
        presenting.applySchedule()
        presenting.endFocusIfDue()
        c.showBanner("selftest")
        _ = await waitUntil(timeout: 1.5) { false }   // ticks, the controller's 1 s timers
        let foreground1 = GetForegroundWindow()
        let unchanged = !onCI || foreground1 == foreground0
        r.add("plaza.focus", shell.stats.activations == activations0 && shell.stats.shows == shows0 && unchanged && (!onCI || !shell.isFrontmost),
              "teammate join, emote, chat, jump, dance, firework, pickup, group photo, schedule, focus tick, banner: activations +\(shell.stats.activations - activations0), "
                + "shows +\(shell.stats.shows - shows0), foreground unchanged=\(foreground1 == foreground0) (other window foreground at start=\(foreground0 == other?.hwnd)), plaza frontmost=\(shell.isFrontmost)")
        scene.applyMembers(members)
        if onCI { forceForeground(hwnd) }
    }

    @MainActor private static func placementCheck(_ r: Recorder, expected: RECT) async {
        WinDefaultsSync.flushNow()
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-plaza-placement-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: out) }
        let saved = WinPlazaPlacement.read(WinDefaultsSync.makeAppDefaults(), key: plazaPlacementKey)
        do {
            let child = try Helper.start(["--selftest-plaza-placement", plazaPlacementKey, WinPath.native(out)], ready: false)
            defer { child.close() }
            let code = await child.waitExit(timeout: 20)
            let text = (try? String(contentsOf: out, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let want = "\(expected.left) \(expected.top) \(expected.right) \(expected.bottom)"
            r.add("plaza.placement", code == 0 && text.hasPrefix(want + " restored"),
                  "saved '\(saved?.encoded ?? "-")'; a new process opens at '\(text)' (expected '\(want) restored'), exit \(describe(code))")
        } catch {
            r.add("plaza.placement", false, "child: \(error)")
        }
    }

    /// `--selftest-plaza-placement <key> <out>`: makes the plaza window (hidden) where the saved placement puts it and writes
    /// its rect and whether it was restored. No device, no stage: the placement only.
    @MainActor static func runPlazaPlacement(_ args: [String]) -> Never {
        guard args.count >= 2 else { WindowsApp.exit(2, .helper) }
        let place = WinPlazaPlacement.restore(saved: WinPlazaPlacement.read(WinDefaultsSync.makeAppDefaults(), key: args[0]),
                                              monitors: WinPlazaPlacement.monitors(), frame: WinPlazaWindow.frame)
        guard let window = try? WinSinkWindow(className: WinPlazaWindow.className, title: "placement", style: WinPlazaWindow.style,
                                              exStyle: WinPlazaWindow.exStyle, x: place.rect.left, y: place.rect.top,
                                              width: place.rect.width, height: place.rect.height) else { WindowsApp.exit(1, .helper) }
        var rect = RECT()
        _ = GetWindowRect(window.hwnd, &rect)
        window.destroy()
        let line = "\(rect.left) \(rect.top) \(rect.right) \(rect.bottom) \(place.restored ? "restored" : "centred") dpi \(place.dpi)\n"
        try? Data(line.utf8).write(to: URL(fileURLWithPath: args[1]))
        WindowsApp.exit(0, .helper)
    }

    /// `--selftest-plaza-idle visible|minimized`: the app as it runs, with its plaza open (no team needed: this is a
    /// measurement helper, not the app's open path) for the idle gate's two plaza windows. Logs the window's counters at
    /// the start and at exit (`WindowsApp.exit` writes the open plaza's line).
    @MainActor static func startPlazaIdle(_ app: WindowsAppDelegate, mode: String) {
        Task { @MainActor in
            _ = await waitUntil(timeout: 5) { false }
            app.plaza.show()
            guard let shell = WinPlazaLive.current, let hwnd = shell.hwndForTesting else {
                AppLog.write("plaza idle helper: the plaza did not open")
                return
            }
            _ = SetWindowPos(hwnd, nil, 40, 40, 0, 0, UINT(SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE))
            if onCI { forceForeground(hwnd) }
            if mode == "minimized" { _ = ShowWindow(hwnd, 7 /* SW_SHOWMINNOACTIVE */) }
            _ = await waitUntil(timeout: 20) { false }
            AppLog.write("plaza idle helper: mode=\(mode) at +25 s: \(shell.statsLine)")
        }
    }

    // MARK: - small helpers

    static func selftestOutDirectory() -> URL {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest-out"), i + 1 < args.count {
            return URL(fileURLWithPath: args[i + 1]).deletingLastPathComponent()
        }
        return FileManager.default.temporaryDirectory
    }

    private static func clockThreadGone(_ tid: UInt32) -> Bool {
        guard tid != 0 else { return false }
        guard let h = OpenThread(0x0010_0000 /* SYNCHRONIZE */, false, tid) else { return true }
        defer { _ = CloseHandle(h) }
        return WaitForSingleObject(h, 0) == 0
    }

    private static func pmb(_ bytes: UInt64) -> String { String(format: "%.1f", Double(bytes) / 1_048_576) }
    private static func pf2(_ v: Double) -> String { String(format: "%.2f", v) }
}
#endif
