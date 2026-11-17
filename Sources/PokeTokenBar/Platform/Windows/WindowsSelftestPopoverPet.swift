#if os(Windows)
import CPlazaD2D
import Foundation
import WinSDK

// Stage 7 Task 22: the floating pet's selftest group (`pet.*`). Each check prints one PASS/FAIL line with what it measured.
// Pets are FIXTURE companions (the companion header's sample states: public species numbers) with sprites from the FIXTURE
// folder `PTB_SELFTEST_SPRITES` (public PokeAPI files the workflow fetched), or a FIXTURE GIF built from the bundled
// ice-shatter frames for the frame-rate checks. Real input (`SendInput`) and the foreground only with `CI` set. With
// `--dump-ui <dir>` the pet's pictures go to `<dir>/pet/` ("Sample-data capture, Windows CI runner"). Runs after the idle
// window (the 🥚 fallback draws through DirectWrite) and leaves no pet, window or setting behind.

extension WindowsSelftest {
    @MainActor static func popoverPetChecks(_ r: Recorder, _ app: WindowsAppDelegate) async {
        await WindowsSelftestPopoverPet.run(r, app)
    }
}

/// A GIF of `count` frames of `delay` seconds each, cycling the bundled ice-shatter frames (FIXTURE: any species gets it).
private struct PetGifFetcher: PlazaSpriteFetching {
    let frames: [(image: PlazaImage, delay: TimeInterval)]
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: PlazaImage, delay: TimeInterval)] { frames }
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> PlazaImage? { frames.first?.image }
    func egg() async -> PlazaImage? { frames.first?.image }
}

/// A pet over sample stores of its own (the app's settings are not touched beyond the fixture suite the selftest runs in).
@MainActor final class PetHarness {
    let base: HomeStores
    let companion: CompanionStore
    private(set) var pet: WinFloatingPet!
    var animations = true, lowPower = false, asleep = false
    var screensOverride: [FloatingPetScreen]?
    private(set) var openers: [FloatingPetActions.Opener] = []
    /// What an open request does besides being counted (the app's popover, for the click checks).
    var onOpen: ((FloatingPetActions.Opener) -> Void)?
    var store: UsageStore { base.store }
    var window: WinPetWindow? { pet.window }

    /// One synced defaults object for every harness (the sample companions' and the pets' saved places).
    static let defaults = WinDefaultsSync.makeAppDefaults()

    private init(base: HomeStores, companion: CompanionStore) {
        self.base = base
        self.companion = companion
    }

    static func make(_ sample: CompanionHeaderSample, size: Double = 96, quality: UsageStore.AnimationQuality = .powerSaver,
                     saved: CGPoint? = nil, enabled: Bool = true, configure: (PetHarness) -> Void = { _ in }) async -> PetHarness {
        let base = await HomeStores.make(language: .en)
        let companion = await CompanionHeaderSamples.store(sample, language: .en, defaults: defaults, directory: base.directory.appendingPathComponent("sample"))
        let h = PetHarness(base: base, companion: companion)
        if let saved { FloatingPetOrigin.save(saved, in: defaults) } else { clearSaved() }
        base.store.floatingPetSize = size
        base.store.animationQuality = quality
        base.store.alwaysFacesBack = false
        base.store.floatingPetEnabled = enabled
        configure(h)
        h.start()
        return h
    }

    static func clearSaved() {
        defaults.removeObject(forKey: FloatingPetOrigin.originXKey)
        defaults.removeObject(forKey: FloatingPetOrigin.originYKey)
    }

    private func start() {
        pet = WinFloatingPet(store: store, companion: companion, defaults: Self.defaults, openPopover: { [weak self] opener in
            self?.openers.append(opener)
            self?.onOpen?(opener)
        }, configure: { [weak self] p in
            p.animationsEnabled = { self?.animations ?? true }
            p.lowPower = { self?.lowPower ?? false }
            p.displayAsleep = { self?.asleep ?? false }
            if let screens = self?.screensOverride { p.screens = { screens } }
            p.menuOwner = { WindowsSelftest.selftestApp?.sink?.hwnd }
            p.popoverWindow = { WindowsSelftest.selftestApp?.popover?.hwnd }
        })
    }

    /// On screen with its first picture in.
    func waitShown(_ timeout: TimeInterval = 4) async -> Bool {
        await WindowsSelftest.waitUntil(timeout: timeout) {
            guard let w = self.window else { return false }
            return w.revealed && IsWindowVisible(w.hwnd) && w.playback.models.first?.current != nil && !(w.playback.models.first?.isLoading ?? true)
        }
    }

    func destroy() {
        pet?.destroy()
        store.floatingPetEnabled = false
        store.alwaysFacesBack = false
        Self.clearSaved()
        base.remove()
    }
}

@MainActor enum WindowsSelftestPopoverPet {
    static let names = ["pet.show", "pet.hide", "pet.toggles", "pet.noActivate", "pet.drag", "pet.savedOrigin", "pet.clamp", "pet.dpi",
                        "pet.clickActions", "pet.menu", "pet.zOrder", "pet.animation", "pet.idle", "pet.capture", "pet.resources"]

    static func run(_ r: WindowsSelftest.Recorder, _ app: WindowsAppDelegate) async {
        WinFloatingPet.spriteFetcherOverride = WindowsSelftestPopoverCompanion.fixtureFetcher()
        defer { WinFloatingPet.spriteFetcherOverride = nil }
        AppLog.write("selftest: pet sprites from \(WindowsSelftestPopoverCompanion.spriteDirectory?.path ?? "nowhere (no PTB_SELFTEST_SPRITES)")")
        let start = KitResources.now()
        await showHideCheck(r, app)
        await togglesCheck(r, app)
        await noActivateCheck(r, app)
        await dragCheck(r)
        await clampCheck(r)
        await dpiCheck(r)
        await clickActionsCheck(r, app)
        await menuCheck(r, app)
        await zOrderCheck(r, app)
        await animationCheck(r)
        await idleCheck(r)
        await captureCheck(r)
        await resourcesCheck(r, start: start)
        app.store.floatingPetEnabled = false
        PetHarness.clearSaved()
    }

    // MARK: - helpers

    static func wait(_ seconds: TimeInterval) async { _ = await WindowsSelftest.waitUntil(timeout: seconds) { false } }

    static func rect(_ h: HWND) -> RECT {
        var r = RECT()
        _ = GetWindowRect(h, &r)
        return r
    }

    static func describe(_ r: RECT) -> String { "(\(r.left),\(r.top))-(\(r.right),\(r.bottom)) \(r.right - r.left)x\(r.bottom - r.top)" }

    /// The opaque pixels' bounding box and centre in the window's picture (client pixels), nil for an empty picture.
    static func opaqueBox(_ w: WinPetWindow) -> (box: RECT, centre: POINT, count: Int)? {
        guard let snap = w.snapshot() else { return nil }
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1, count = 0, sx = 0, sy = 0
        for y in 0..<snap.side {
            for x in 0..<snap.side where snap.bgra[(y * snap.side + x) * 4 + 3] > 200 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                count += 1; sx += x; sy += y
            }
        }
        guard count > 0 else { return nil }
        return (RECT(left: Int32(minX), top: Int32(minY), right: Int32(maxX + 1), bottom: Int32(maxY + 1)),
                POINT(x: Int32(sx / count), y: Int32(sy / count)), count)
    }

    /// The opaque pixel nearest the opaque centroid (a click there hits the pet, not a hole).
    static func opaquePoint(_ w: WinPetWindow) -> POINT? {
        guard let snap = w.snapshot(), let c = opaqueBox(w)?.centre else { return nil }
        var best: (point: POINT, distance: Int)?
        for y in 0..<snap.side {
            for x in 0..<snap.side where snap.bgra[(y * snap.side + x) * 4 + 3] == 255 {
                let d = (x - Int(c.x)) * (x - Int(c.x)) + (y - Int(c.y)) * (y - Int(c.y))
                if let kept = best, kept.distance <= d { continue }
                best = (POINT(x: Int32(x), y: Int32(y)), d)
            }
        }
        return best?.point
    }

    static func lParam(_ x: Int32, _ y: Int32) -> LPARAM { LPARAM(Int(UInt16(bitPattern: Int16(truncatingIfNeeded: x))) | (Int(UInt16(bitPattern: Int16(truncatingIfNeeded: y))) << 16)) }

    /// A press, moves and a release by window messages, each at a screen point turned into the window's client point at the time.
    static func postedDrag(_ w: WinPetWindow, from start: POINT, through points: [POINT]) {
        func client(_ p: POINT) -> LPARAM { let f = w.frame; return lParam(p.x - f.left, p.y - f.top) }
        _ = SendMessageW(w.hwnd, 0x0201 /* WM_LBUTTONDOWN */, 1, client(start))
        for p in points { _ = SendMessageW(w.hwnd, 0x0200 /* WM_MOUSEMOVE */, 1, client(p)) }
        _ = SendMessageW(w.hwnd, 0x0202 /* WM_LBUTTONUP */, 0, client(points.last ?? start))
    }

    static func screen(_ w: WinPetWindow, _ p: POINT) -> POINT { POINT(x: w.frame.left + p.x, y: w.frame.top + p.y) }

    /// `--dump-ui <dir>`: `<dir>/pet/`, nil without the flag.
    static func dumpDirectory() -> URL? {
        guard let dir = WinUIDump.directory(from: CommandLine.arguments)?.appendingPathComponent("pet", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A window as `PrintWindow` draws it, to `<dump>/pet/<name>` (Sample-data capture, Windows CI runner).
    @discardableResult
    static func printWindow(_ hwnd: HWND, _ name: String) -> Bool {
        guard let dir = dumpDirectory() else { return false }
        _ = RedrawWindow(hwnd, nil, nil, UINT(0x0001 | 0x0004 | 0x0080 | 0x0100))
        var w: UInt32 = 0, h: UInt32 = 0
        var out: UnsafeMutablePointer<UInt8>?
        guard ptb_window_print(UnsafeMutableRawPointer(hwnd), &w, &h, &out) == 0, let out else { return false }
        defer { ptb_plaza_free(out) }
        let bitmap = WinUIDump.Bitmap(width: Int(w), height: Int(h), bgra: Array(UnsafeBufferPointer(start: out, count: Int(w * h) * 4)))
        return WinUIDump.write(bitmap, to: dir.appendingPathComponent(name)) == 0
    }

    /// Real input at screen pixels (CI only).
    static func realClick(at p: POINT, right: Bool = false) async {
        WindowsSelftestPopover.mouse(x: p.x, y: p.y, flags: DWORD(MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE))
        await wait(0.08)
        WindowsSelftestPopover.mouse(x: p.x, y: p.y, flags: DWORD(MOUSEEVENTF_ABSOLUTE | (right ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_LEFTDOWN)))
        await wait(0.05)
        WindowsSelftestPopover.mouse(x: p.x, y: p.y, flags: DWORD(MOUSEEVENTF_ABSOLUTE | (right ? MOUSEEVENTF_RIGHTUP : MOUSEEVENTF_LEFTUP)))
        await wait(0.25)
    }

    static func realDrag(from a: POINT, by dx: Int32, _ dy: Int32, steps: Int32 = 6) async {
        WindowsSelftestPopover.mouse(x: a.x, y: a.y, flags: DWORD(MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE))
        await wait(0.08)
        WindowsSelftestPopover.mouse(x: a.x, y: a.y, flags: DWORD(MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_LEFTDOWN))
        await wait(0.05)
        for i in 1...steps {
            WindowsSelftestPopover.mouse(x: a.x + dx * i / steps, y: a.y + dy * i / steps, flags: DWORD(MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE))
            await wait(0.04)
        }
        WindowsSelftestPopover.mouse(x: a.x + dx, y: a.y + dy, flags: DWORD(MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_LEFTUP))
        await wait(0.25)
    }

    /// The keyboard focus of the foreground thread.
    static func foregroundFocus() -> HWND? {
        guard let fg = GetForegroundWindow() else { return nil }
        var info = GUITHREADINFO()
        info.cbSize = DWORD(MemoryLayout<GUITHREADINFO>.size)
        guard GetGUIThreadInfo(GetWindowThreadProcessId(fg, nil), &info) else { return nil }
        return info.hwndFocus
    }

    static func descendants(_ h: HWND) -> [HWND] {
        var out: [HWND] = []
        var child = GetWindow(h, UINT(GW_CHILD))
        while let c = child {
            out.append(c)
            out += descendants(c)
            child = GetWindow(c, UINT(GW_HWNDNEXT))
        }
        return out
    }

    /// The top-level windows below `top` in z order, down to `limit` of them.
    static func below(_ top: HWND, limit: Int = 4000) -> [HWND] {
        var out: [HWND] = []
        var next = GetWindow(top, UINT(GW_HWNDNEXT))
        while let n = next, out.count < limit {
            out.append(n)
            next = GetWindow(n, UINT(GW_HWNDNEXT))
        }
        return out
    }

    static func primaryWork() -> RECT {
        let m = WinPlazaPlacement.monitors()
        let p = m.first { $0.isPrimary } ?? m.first
        guard let p else { return RECT() }
        return RECT(left: p.work.left, top: p.work.top, right: p.work.right, bottom: p.work.bottom)
    }

    static func gifFixture(count: Int, delay: TimeInterval) -> (any PlazaSpriteFetching)? {
        guard let url = PlatformPlaza.graphics.assetURL(PlazaDecodeGoldens.iceGIFName, ext: "gif"), let data = try? Data(contentsOf: url) else { return nil }
        let source = PlazaStoreGIF.frames(from: data)
        guard !source.isEmpty else { return nil }
        return PetGifFetcher(frames: (0..<count).map { (source[$0 % source.count].image, delay) })
    }

    // MARK: - pet.show / pet.hide (the app's pet over the app's settings)

    static func showHideCheck(_ r: WindowsSelftest.Recorder, _ app: WindowsAppDelegate) async {
        guard let pet = WinFloatingPet.current else {
            r.add("pet.show", false, "the app made no floating pet at launch")
            r.add("pet.hide", false, "no pet")
            return
        }
        let defaults = app.defaults!
        defaults.removeObject(forKey: FloatingPetOrigin.originXKey)
        defaults.removeObject(forKey: FloatingPetOrigin.originYKey)
        let offBefore = pet.window == nil && !app.store.floatingPetEnabled
        let live0 = WinSinkWindow.liveCount
        app.store.floatingPetSize = 96
        app.store.floatingPetEnabled = true
        let shown = await WindowsSelftest.waitUntil(timeout: 4) { pet.window?.revealed == true && pet.window.map { IsWindowVisible($0.hwnd) } == true }
        guard let w = pet.window else {
            r.add("pet.show", false, "off before=\(offBefore); setting on: no window (stats \(pet.stats))")
            r.add("pet.hide", false, "no window to hide")
            return
        }
        let ex = DWORD(bitPattern: GetWindowLongW(w.hwnd, -20 /* GWL_EXSTYLE */))
        let style = DWORD(bitPattern: GetWindowLongW(w.hwnd, -16 /* GWL_STYLE */))
        let wanted: DWORD = 0x0800_0000 | 0x0008_0000 | 0x0000_0080 | 0x0000_0008
        let stylesOK = ex & wanted == wanted && ex & 0x0004_0000 /* WS_EX_APPWINDOW */ == 0 && style & 0x8000_0000 != 0 && style & 0x00C0_0000 /* WS_CAPTION */ == 0
        let owner = GetWindow(w.hwnd, UINT(GW_OWNER))
        var cls = [UInt16](repeating: 0, count: 64)
        let clsLen = GetClassNameW(w.hwnd, &cls, 64)
        let className = String(decoding: cls.prefix(Int(clsLen)), as: UTF16.self)
        let dpi = WinUIContext.dpi(of: w.hwnd)
        let side = Int32((96 * CGFloat(dpi) / 96).rounded())
        let rr = rect(w.hwnd)
        let work = primaryWork()
        let margin = Int32((24 * CGFloat(dpi) / 96).rounded())
        let corner = rr.right == work.right - margin && rr.bottom == work.bottom - margin
        let sizeOK = rr.right - rr.left == side && rr.bottom - rr.top == side
        let saved = FloatingPetOrigin.saved(in: defaults)
        let savedOK = saved == CGPoint(x: CGFloat(rr.left), y: CGFloat(rr.bottom))
        var pmv2: Int32 = 0
        let awareness = ptb_window_dpi_awareness(UnsafeMutableRawPointer(w.hwnd), &pmv2)
        let picture = opaqueBox(w)
        r.add("pet.show", offBefore && shown && stylesOK && owner == nil && className == WinPetWindow.className && sizeOK && corner && savedOK && pmv2 == 1
              && picture != nil && WinSinkWindow.liveCount == live0 + 1,
              "off before=\(offBefore); setting on -> shown=\(shown) class=\(className) exStyle=0x\(String(ex, radix: 16)) (NOACTIVATE|LAYERED|TOOLWINDOW|TOPMOST, no APPWINDOW: \(stylesOK)) "
              + "style=0x\(String(style, radix: 16)) owner=\(owner == nil ? "none" : "some") dpi=\(dpi) awareness=\(awareness) perMonitorV2=\(pmv2) rect \(describe(rr)) "
              + "(\(side) px square: \(sizeOK); the primary work area \(describe(work))'s bottom-right corner \(margin) px in: \(corner)) saved home \(saved.map { "\($0)" } ?? "none") = its bottom-left: \(savedOK); "
              + "opaque picture \(picture.map { "\($0.count) px in \(describe($0.box))" } ?? "none"); windows \(live0) -> \(WinSinkWindow.liveCount); stats \(pet.stats)")

        // Hidden: the setting off, then the displays asleep (the Mac's `sync`), each leaves nothing behind.
        let hwnd = w.hwnd
        app.store.floatingPetEnabled = false
        let gone = await WindowsSelftest.waitUntil(timeout: 2) { pet.window == nil && !IsWindow(hwnd) }
        let liveBack = WinSinkWindow.liveCount == live0
        // An animating pet turned off: its clock, loads and frames go with the window, at once (not at the clock's next tick).
        let h = await PetHarness.make(.hatched)
        let up = await h.waitShown()
        let animating = await WindowsSelftest.waitUntil(timeout: 2) { h.window?.playback.clock.isArmed == true }
        let playback = h.window?.playback
        h.store.floatingPetEnabled = false
        _ = await WindowsSelftest.waitUntil(timeout: 2, poll: 0.005) { h.window == nil }
        let released = playback?.released == true && playback?.clock.isArmed == false && playback?.memory.frameSetCount == 0
        h.store.floatingPetEnabled = true
        _ = await h.waitShown()
        h.asleep = true
        h.pet.sync()
        let asleepHidden = h.window == nil
        h.asleep = false
        h.pet.sync()
        let awake = await h.waitShown()
        h.destroy()
        r.add("pet.hide", gone && liveBack && up && animating && released && asleepHidden && awake,
              "setting off -> window destroyed=\(gone), windows back to \(WinSinkWindow.liveCount) (was \(live0)); an animating harness pet (shown=\(up), clock armed=\(animating)) "
              + "turned off -> playback released, clock gone, frame sets 0 at once=\(released); displays asleep -> hidden=\(asleepHidden), awake again -> shown=\(awake)")
    }

    // MARK: - pet.toggles: the tray item, Home's eye, Settings' rows (the Mac's three switches over one setting)

    static func togglesCheck(_ r: WindowsSelftest.Recorder, _ app: WindowsAppDelegate) async {
        guard WindowsSelftest.onCI, let pet = WinFloatingPet.current, let tray = app.tray else {
            r.add("pet.toggles", true, "skipped: CI not set (the popover takes the foreground)")
            return
        }
        let l = app.companion.l
        var notes: [String] = []
        var ok = true
        // Tray menu.
        app.store.floatingPetEnabled = false
        let offItem = tray.menuItems().compactMap { $0 }.first { $0.action == .toggleFloatingPet }
        tray.perform(.toggleFloatingPet)
        let trayOn = await WindowsSelftest.waitUntil(timeout: 3) { pet.window?.revealed == true }
        let onItem = tray.menuItems().compactMap { $0 }.first { $0.action == .toggleFloatingPet }
        tray.perform(.toggleFloatingPet)
        let trayOff = await WindowsSelftest.waitUntil(timeout: 3) { pet.window == nil }
        let trayOK = offItem?.title == l.floatingPetEnableLabel && onItem?.title == l.floatingPetHideLabel && trayOn && trayOff && !app.store.floatingPetEnabled
        ok = ok && trayOK
        notes.append("tray: '\(offItem?.title ?? "none")' -> pet shown=\(trayOn), then '\(onItem?.title ?? "none")' -> gone=\(trayOff)")

        // Home's footer eye.
        guard let probe = WindowsSelftestPopoverWindow.makeProbe() else {
            r.add("pet.toggles", false, "no probe window"); return
        }
        defer { probe.destroy() }
        func openPopover(settings: Bool) async -> WinPopover? {
            let host = WinPopoverHost(store: app.store, companion: app.companion, updater: nil, team: app.teamSettings, session: nil, feed: nil,
                                      tray: nil, loginItem: tray.loginItem, openPlaza: {})
            host.owner = app.sink.hwnd
            let p = WinPopover(host: host)
            p.makePage = WinSettingsPage.routed
            WindowsSelftest.forceForeground(probe.hwnd)
            _ = await WindowsSelftest.waitUntil(timeout: 1) { GetForegroundWindow() == probe.hwnd }
            p.present(.secondLaunch) { $0.showSettings = settings }
            let up = await WindowsSelftest.waitUntil(timeout: 3) { p.hwnd.map { IsWindowVisible($0) } == true }
            await wait(0.4)
            return up ? p : nil
        }
        if let p = await openPopover(settings: false), let h = p.hwnd {
            func eye() -> HWND? { descendants(h).first { WinKit.text(of: $0) == l.floatingPetEnableLabel || WinKit.text(of: $0) == l.floatingPetHideLabel } }
            let before = eye().map { WinKit.text(of: $0) }
            printWindow(h, "home-footer-eye-off-en.png")
            if let e = eye() { WinKit.send(e, 0x00F5 /* BM_CLICK */) }
            let shown = await WindowsSelftest.waitUntil(timeout: 3) { pet.window?.revealed == true }
            await wait(0.3)
            let after = eye().map { WinKit.text(of: $0) }
            printWindow(h, "home-footer-eye-on-en.png")
            if let e = eye() { WinKit.send(e, 0x00F5) }
            let hidden = await WindowsSelftest.waitUntil(timeout: 3) { pet.window == nil }
            let homeOK = before == l.floatingPetEnableLabel && shown && after == l.floatingPetHideLabel && hidden
            ok = ok && homeOK
            notes.append("Home footer eye '\(before ?? "none")' -> pet shown=\(shown), eye now '\(after ?? "none")' -> pet gone=\(hidden), popover stayed open=\(p.isOpen)")
            p.close(.destroyed)
        } else {
            ok = false
            notes.append("Home: the popover did not open")
        }

        // Settings: Animation (G4) in General, the pet group (G12) with enable, back view, size (while on).
        if let p = await openPopover(settings: true), let page = p.pageForTesting as? WinSettingsPage, let rows = page.petRowsForTesting {
            let q = rows.animationQualityRow?.control
            let qualityTitles = q.map { c in (0..<3).map { i -> String in
                var buf = [UInt16](repeating: 0, count: 128)
                let n = buf.withUnsafeMutableBufferPointer { p in SendMessageW(c.hwnd, 0x0148 /* CB_GETLBTEXT */, WPARAM(i), LPARAM(Int(bitPattern: p.baseAddress))) }
                return n > 0 ? String(decoding: buf.prefix(Int(n)), as: UTF16.self) : ""
            } } ?? []
            let sizeHiddenOff = rows.sizeRow?.isVisible == false
            let backViewInGroup = rows.backViewRow != nil
            if let c = rows.enableRow?.control { WinKit.send(c.parts[0], 0x00F5 /* BM_CLICK */) }
            let on = await WindowsSelftest.waitUntil(timeout: 3) { app.store.floatingPetEnabled && pet.window?.revealed == true }
            await wait(0.3)
            let sizeShownOn = rows.sizeRow?.isVisible == true
            if let bar = rows.sizeRow?.control, let parent = GetParent(bar.parts[0]) {
                WinKit.send(bar.parts[0], 0x0405 /* TBM_SETPOS */, 1, 192)
                _ = SendMessageW(parent, 0x0114 /* WM_HSCROLL */, 8 /* SB_ENDSCROLL */, LPARAM(Int(bitPattern: UnsafeMutableRawPointer(bar.parts[0]))))
            }
            // The group on screen (scrolled to its caption) for the captures.
            if let h = p.hwnd, let area = page.areaForTesting, let stack = page.stackForTesting, let frames = stack.frames,
               let index = stack.sections.firstIndex(where: { $0.caption?.text == l.floatingPetSectionTitle.uppercased() }),
               index < frames.sections.count, let frame = frames.sections[index] {
                area.scroll(to: Int32(max(0, (frame.caption?.minY ?? frame.card?.minY ?? 0) - 8)))
                await wait(0.35)
                printWindow(h, "settings-pet-group-en.png")
            }
            let resized = await WindowsSelftest.waitUntil(timeout: 3) {
                pet.window.map { w in w.frame.right - w.frame.left == Int32((192 * CGFloat(w.dpi) / 96).rounded()) } == true
            }
            if let c = q, let parent = GetParent(c.hwnd) {
                WinKit.send(c.hwnd, 0x014E /* CB_SETCURSEL */, 2)
                let id = Int(GetDlgCtrlID(c.hwnd))
                _ = SendMessageW(parent, UINT(WM_COMMAND), WPARAM(UInt(id & 0xFFFF) | (1 << 16) /* CBN_SELCHANGE */), LPARAM(Int(bitPattern: UnsafeMutableRawPointer(c.hwnd))))
            }
            let smooth = await WindowsSelftest.waitUntil(timeout: 2) {
                app.store.animationQuality == .smooth && pet.window?.playback.frameFloor == UsageStore.AnimationQuality.smooth.frameFloor
            }
            let settingsOK = qualityTitles == [l.animationPowerSaver, l.animationBalanced, l.animationSmooth] && sizeHiddenOff && backViewInGroup && on && sizeShownOn && resized && smooth
            ok = ok && settingsOK
            notes.append("Settings: Animation choices \(qualityTitles), size row hidden while off=\(sizeHiddenOff), back view in the pet group=\(backViewInGroup); "
                         + "enable -> pet shown=\(on), size row shown=\(sizeShownOn); size 192 -> window \(pet.window.map { describe($0.frame) } ?? "none") resized=\(resized); "
                         + "Smooth -> store and the pet's frame floor \(pet.window?.playback.frameFloor ?? -1)=\(smooth)")
            p.close(.destroyed)
        } else {
            ok = false
            notes.append("Settings: the page did not open")
        }
        app.store.floatingPetEnabled = false
        app.store.floatingPetSize = 96
        app.store.animationQuality = .powerSaver
        _ = await WindowsSelftest.waitUntil(timeout: 2) { pet.window == nil }
        r.add("pet.toggles", ok, notes.joined(separator: "; "))
    }

    // MARK: - pet.noActivate (CI: real clicks and a real drag over a pet in front of a focused window)

    static func noActivateCheck(_ r: WindowsSelftest.Recorder, _ app: WindowsAppDelegate) async {
        guard WindowsSelftest.onCI, let probe = WindowsSelftestPopoverWindow.makeProbe() else {
            r.add("pet.noActivate", true, "skipped: CI not set (real input only on the runner)")
            return
        }
        defer { probe.destroy() }
        let edit = CreateWindowExW(0x0200, WinStr.w("Edit"), WinStr.w("focus here"), DWORD(0x5001_0080) /* WS_CHILD | WS_VISIBLE | WS_TABSTOP | ES_AUTOHSCROLL */,
                                   10, 10, 200, 24, probe.hwnd, nil, GetModuleHandleW(nil), nil)
        WindowsSelftest.forceForeground(probe.hwnd)
        _ = SetFocus(edit)
        _ = await WindowsSelftest.waitUntil(timeout: 1) { GetForegroundWindow() == probe.hwnd && foregroundFocus() == edit }
        let fg0 = GetForegroundWindow(), focus0 = foregroundFocus()
        let work = primaryWork()
        let h = await PetHarness.make(.eggIncubating, saved: CGPoint(x: CGFloat(work.left + 420), y: CGFloat(work.top + 360)))
        defer { h.destroy() }
        let up = await h.waitShown()
        guard let w = h.window, let spot = opaquePoint(w) else {
            r.add("pet.noActivate", false, "the pet did not show a picture (shown=\(up))")
            return
        }
        let afterShow = (GetForegroundWindow() == fg0, foregroundFocus() == focus0)
        let prayers0 = h.companion.state.eggPrayers?.count ?? 0
        await realClick(at: screen(w, spot))
        let prayed = (h.companion.state.eggPrayers?.count ?? 0) == prayers0 + 1 && h.pet.stats.clicks == 1
        let afterClick = (GetForegroundWindow() == fg0, foregroundFocus() == focus0)
        let frame0 = w.frame
        await realDrag(from: screen(w, spot), by: 60, 40)
        let moved = w.frame.left - frame0.left == 60 && w.frame.top - frame0.top == 40
        let afterDrag = (GetForegroundWindow() == fg0, foregroundFocus() == focus0)
        let noClick = h.pet.stats.clicks == 1
        let active = GetActiveWindow() == w.hwnd
        // A click on a transparent pixel goes to the window below (the pet's shape is its picture).
        let hole = POINT(x: w.frame.left + 1, y: w.frame.top + 1)
        let corner = w.snapshot().map { $0.bgra[3] == 0 } ?? false
        let through = WindowFromPoint(hole) != w.hwnd
        let ok = up && afterShow == (true, true) && prayed && afterClick == (true, true) && moved && noClick && afterDrag == (true, true) && !active && (!corner || through)
        r.add("pet.noActivate", ok,
              "probe window foreground with its edit focused (\(fg0 == probe.hwnd), \(focus0 == edit)); after show fg/focus kept=\(afterShow); real click on an opaque pixel "
              + "\(spot.x),\(spot.y): prayed=\(prayed) (\(prayers0) -> \(h.companion.state.eggPrayers?.count ?? 0)), fg/focus kept=\(afterClick); real drag by (60,40): "
              + "moved \(w.frame.left - frame0.left),\(w.frame.top - frame0.top), no click=\(noClick), fg/focus kept=\(afterDrag); the pet active=\(active); "
              + "transparent corner pixel=\(corner): WindowFromPoint there is not the pet=\(through)")
    }

    // MARK: - pet.drag / pet.savedOrigin (window messages: every run)

    static func dragCheck(_ r: WindowsSelftest.Recorder) async {
        let h = await PetHarness.make(.eggIncubating)
        let up = await h.waitShown()
        guard let w = h.window, let spot = opaquePoint(w) else {
            r.add("pet.drag", false, "no picture (shown=\(up))")
            r.add("pet.savedOrigin", false, "no pet")
            h.destroy()
            return
        }
        let f0 = w.frame
        let start = screen(w, spot)
        let clicks0 = h.pet.stats.clicks, saves0 = h.pet.stats.saves
        postedDrag(w, from: start, through: [POINT(x: start.x + 3, y: start.y), POINT(x: start.x + 30, y: start.y - 20), POINT(x: start.x + 60, y: start.y - 40)])
        let f1 = w.frame
        let real = rect(w.hwnd)
        let moved = f1.left - f0.left == 60 && f1.top - f0.top == -40 && real.left == f1.left && real.top == f1.top
        let noClick = h.pet.stats.clicks == clicks0
        let saved = FloatingPetOrigin.saved(in: PetHarness.defaults)
        let savedOK = saved == CGPoint(x: CGFloat(f1.left), y: CGFloat(f1.bottom)) && h.pet.stats.saves == saves0 + 1
        // A press that moves 2 px and comes back up: the window follows (as on the Mac) and it is a click.
        let s2 = screen(w, spot)
        postedDrag(w, from: s2, through: [POINT(x: s2.x + 2, y: s2.y)])
        let jiggle = w.frame.left - f1.left == 2 && h.pet.stats.clicks == clicks0 + 1
        r.add("pet.drag", up && moved && noClick && jiggle,
              "press at \(start.x),\(start.y), moves +3 (within the 4 DIP click distance), +30/-20, +60/-40, release: window \(describe(f0)) -> \(describe(f1)) "
              + "(real \(describe(real))) moved=\(moved), a click=\(!noClick); a 2 px press: moved 2 and clicked=\(jiggle) (clicks \(h.pet.stats.clicks), prayers \(h.pet.actions.prayers))")
        // Restored: a new pet over the same settings stands where the last one was left.
        let left = w.frame
        h.pet.destroy()
        let again = WinFloatingPet(store: h.store, companion: h.companion, defaults: PetHarness.defaults, openPopover: { _ in })
        let up2 = await WindowsSelftest.waitUntil(timeout: 4) { again.window?.revealed == true }
        let restored = again.window.map { $0.frame.left == left.left && $0.frame.bottom == left.bottom } ?? false
        r.add("pet.savedOrigin", savedOK && up2 && restored,
              "saved after the drag \(saved.map { "\($0)" } ?? "none") = the new bottom-left (\(f1.left),\(f1.bottom)) once=\(savedOK); a new pet over the same settings at "
              + "\(again.window.map { describe($0.frame) } ?? "none") = where it was left=\(restored)")
        again.destroy()
        h.destroy()
    }

    // MARK: - pet.clamp: the Mac's rule (a home meeting no work area goes to the default corner; one that still meets one stays)

    static func clampCheck(_ r: WindowsSelftest.Recorder) async {
        let work = primaryWork()
        var notes: [String] = []
        var ok = true
        // 1. Far away (a monitor that is gone): the default corner, and that becomes the home.
        let far = await PetHarness.make(.hatched, saved: CGPoint(x: -100_000, y: -100_000))
        let up1 = await far.waitShown()
        let f1 = far.window.map { $0.frame } ?? RECT()
        let dpi1 = far.window.map { WinUIContext.dpi(of: $0.hwnd) } ?? 96
        let margin = Int32((24 * CGFloat(dpi1) / 96).rounded())
        let cornered = f1.right == work.right - margin && f1.bottom == work.bottom - margin
        let rehomed = FloatingPetOrigin.saved(in: PetHarness.defaults) == CGPoint(x: CGFloat(f1.left), y: CGFloat(f1.bottom))
        ok = ok && up1 && cornered && rehomed
        notes.append("saved (-100000,-100000) -> \(describe(f1)) default corner=\(cornered), saved again=\(rehomed)")
        far.destroy()
        // 2. Partly off the right edge but still on the work area: kept as it is (the Mac does not clamp).
        let edge = await PetHarness.make(.hatched, saved: CGPoint(x: CGFloat(work.right - 30), y: CGFloat(work.bottom - 100)))
        let up2 = await edge.waitShown()
        let f2 = edge.window.map { $0.frame } ?? RECT()
        let kept = f2.left == work.right - 30 && f2.bottom == work.bottom - 100 && f2.right > work.right
        ok = ok && up2 && kept
        notes.append("saved 30 px from the right edge -> \(describe(f2)) kept, partly off screen=\(kept)")
        // 3. On a second monitor that goes away: the display change puts it in the default corner of the primary.
        let monitors = WinPlazaPlacement.monitors()
        let primary = monitors.first { $0.isPrimary } ?? monitors.first
        if let primary {
            let p = FloatingPetScreen(bounds: CGRect(x: CGFloat(primary.bounds.left), y: CGFloat(primary.bounds.top), width: CGFloat(primary.bounds.width), height: CGFloat(primary.bounds.height)),
                                      work: CGRect(x: CGFloat(primary.work.left), y: CGFloat(primary.work.top), width: CGFloat(primary.work.width), height: CGFloat(primary.work.height)),
                                      scale: CGFloat(primary.dpi) / 96, isPrimary: true)
            let second = FloatingPetScreen(bounds: CGRect(x: p.bounds.maxX, y: 0, width: 1280, height: 720), work: CGRect(x: p.bounds.maxX, y: 0, width: 1280, height: 680),
                                           scale: p.scale, isPrimary: false)
            let gone = await PetHarness.make(.hatched, saved: CGPoint(x: p.bounds.maxX + 300, y: 500)) { $0.screensOverride = [p, second] }
            let up3 = await gone.waitShown()
            let before = gone.window.map { $0.frame } ?? RECT()
            gone.pet.screens = { [p] }
            if let w = gone.window { _ = SendMessageW(w.hwnd, 0x007E /* WM_DISPLAYCHANGE */, 32, 0) }
            let after = gone.window.map { $0.frame } ?? RECT()
            let moved = before.left == Int32(p.bounds.maxX + 300) && after.right == work.right - margin && after.bottom == work.bottom - margin
            ok = ok && up3 && moved
            notes.append("on a FIXTURE second monitor right of the primary at \(describe(before)); the monitor removed + WM_DISPLAYCHANGE -> \(describe(after)) default corner=\(moved)")
            gone.destroy()
        }
        edge.destroy()
        r.add("pet.clamp", ok, notes.joined(separator: "; "))
    }

    // MARK: - pet.dpi

    static func dpiCheck(_ r: WindowsSelftest.Recorder) async {
        let h = await PetHarness.make(.hatched)
        defer { h.destroy() }
        let up = await h.waitShown()
        guard let w = h.window, let box0 = opaqueBox(w) else {
            r.add("pet.dpi", false, "no picture (shown=\(up))")
            return
        }
        let f0 = w.frame, dpi0 = w.dpi
        _ = SendMessageW(w.hwnd, 0x02E0 /* WM_DPICHANGED */, WPARAM(144 | (144 << 16)), 0)
        let f1 = w.frame, real1 = rect(w.hwnd)
        let box1 = opaqueBox(w)
        let side1 = f1.right - f1.left
        let grown = side1 == Int32((96 * 1.5).rounded()) && real1.right - real1.left == side1 && f1.left == f0.left && f1.bottom == f0.bottom
        let wide0 = Double(box0.box.right - box0.box.left), wide1 = Double((box1?.box.right ?? 0) - (box1?.box.left ?? 0))
        let scaled = abs(wide1 / max(1, wide0) - 1.5) < 0.1
        _ = SendMessageW(w.hwnd, 0x02E0, WPARAM(Int(dpi0) | (Int(dpi0) << 16)), 0)
        let back = w.frame.right - w.frame.left == f0.right - f0.left && w.frame.bottom == f0.bottom
        r.add("pet.dpi", up && grown && scaled && back,
              "at \(dpi0) dpi \(describe(f0)), opaque \(Int(wide0)) px wide; WM_DPICHANGED 144 -> \(describe(f1)) (window \(describe(real1))) 144 px, bottom-left kept=\(grown); "
              + "opaque \(Int(wide1)) px (x\(String(format: "%.2f", wide1 / max(1, wide0))))=\(scaled); back to \(dpi0) -> \(describe(w.frame))=\(back)")
    }

    // MARK: - pet.clickActions

    static func clickActionsCheck(_ r: WindowsSelftest.Recorder, _ app: WindowsAppDelegate) async {
        var notes: [String] = []
        var ok = true
        // An egg: a click prays (no popover).
        let egg = await PetHarness.make(.eggIncubating)
        if await egg.waitShown(), let w = egg.window, let spot = opaquePoint(w) {
            let p0 = egg.companion.state.eggPrayers?.count ?? 0
            postedDrag(w, from: screen(w, spot), through: [])
            postedDrag(w, from: screen(w, spot), through: [])
            let prayed = (egg.companion.state.eggPrayers?.count ?? 0) == p0 + 2 && egg.openers.isEmpty
            ok = ok && prayed
            notes.append("egg: two clicks -> prayers \(p0) -> \(egg.companion.state.eggPrayers?.count ?? 0), popover asked \(egg.openers.count)x=\(prayed)")
        } else {
            ok = false
            notes.append("egg: no picture")
        }
        egg.destroy()
        // Hatched: a click opens the popover; a click while it is open closes it (the Mac's transient popover closes on that click).
        guard WindowsSelftest.onCI, let popover = app.popover else {
            r.add("pet.clickActions", ok, notes.joined(separator: "; ") + "; hatched: skipped (CI not set)")
            return
        }
        popover.close(.destroyed)
        // Away from the tray corner, where the popover opens: the second click must reach the pet, not the popover.
        let work = primaryWork()
        let mon = await PetHarness.make(.hatched, saved: CGPoint(x: CGFloat(work.left + 420), y: CGFloat(work.top + 360))) {
            $0.onOpen = { opener in WinFloatingPet.openPopover(popover, opener) }
        }
        defer { mon.destroy() }
        if await mon.waitShown(), let w = mon.window, let spot = opaquePoint(w) {
            await realClick(at: screen(w, spot))
            let opened = await WindowsSelftest.waitUntil(timeout: 3) { popover.isOpen && popover.hwnd.map { IsWindowVisible($0) } == true }
            let fg = popover.hwnd.map { GetForegroundWindow() == $0 } ?? false
            let opener = popover.stats.lastOpener == .pet
            await realClick(at: screen(w, spot))
            let closed = await WindowsSelftest.waitUntil(timeout: 2) { !popover.isOpen }
            let reason = popover.stats.lastClose
            let hatchedOK = opened && fg && opener && closed && mon.openers == [.click, .click]
            ok = ok && hatchedOK
            notes.append("hatched: real click -> popover open=\(opened) foreground=\(fg) opener .pet=\(opener) (refused foreground \(popover.stats.refusedForeground)); "
                         + "a second click -> closed=\(closed) (\(reason.map { "\($0)" } ?? "none")); openers \(mon.openers)")
        } else {
            ok = false
            notes.append("hatched: no picture")
        }
        popover.close(.destroyed)
        r.add("pet.clickActions", ok, notes.joined(separator: "; "))
    }

    // MARK: - pet.menu: Open, Turn off, Back view (checked), as the Mac's

    final class MenuDriver: @unchecked Sendable {
        private let lock = NSLock()
        private var _titles: [String] = [], _checked: [Bool] = [], _done = false, _notes: [String] = []
        func set(_ t: [String], _ c: [Bool]) { lock.lock(); _titles = t; _checked = c; lock.unlock() }
        func note(_ s: String) { lock.lock(); _notes.append(s); lock.unlock() }
        func finish() { lock.lock(); _done = true; lock.unlock() }
        var done: Bool { lock.lock(); defer { lock.unlock() }; return _done }
        var titles: [String] { lock.lock(); defer { lock.unlock() }; return _titles }
        var checked: [Bool] { lock.lock(); defer { lock.unlock() }; return _checked }
        var notes: String { lock.lock(); defer { lock.unlock() }; return _notes.joined(separator: ",") }
    }

    /// Opens the pet's menu (a posted WM_CONTEXTMENU), reads its entries from another thread, picks entry `pick` with the keys.
    static func runMenu(_ w: WinPetWindow, owner: HWND, pick: Int) async -> MenuDriver {
        let driver = MenuDriver()
        let ownerBits = Int(bitPattern: owner)
        Thread {
            func post(_ message: Int32, _ key: Int32) { _ = PostMessageW(HWND(bitPattern: ownerBits), UINT(message), WPARAM(key), 0) }
            var waited = 0
            while WinPopupMenu.openMenuBits == 0, waited < 100 { Thread.sleep(forTimeInterval: 0.05); waited += 1 }
            let bits = WinPopupMenu.openMenuBits
            guard bits != 0, let menu = HMENU(bitPattern: bits) else { driver.note("menu never opened"); driver.finish(); return }
            Thread.sleep(forTimeInterval: 0.3)
            let n = Int(GetMenuItemCount(menu))
            var titles: [String] = [], checked: [Bool] = []
            for i in 0..<max(0, n) {
                var buf = [UInt16](repeating: 0, count: 128)
                let len = GetMenuStringW(menu, UINT(i), &buf, 128, UINT(MF_BYPOSITION))
                titles.append(String(decoding: buf.prefix(Int(len)), as: UTF16.self))
                checked.append(GetMenuState(menu, UINT(i), UINT(MF_BYPOSITION)) & UINT(MF_CHECKED) != 0)
            }
            driver.set(titles, checked)
            var presses = 0
            while WinPopupMenu.highlightedIndex(menuBits: bits, count: n) != pick, presses < n + 2 {
                post(WM_KEYDOWN, Int32(VK_DOWN)); post(WM_KEYUP, Int32(VK_DOWN))
                presses += 1
                Thread.sleep(forTimeInterval: 0.2)
            }
            post(WM_KEYDOWN, Int32(VK_RETURN)); post(WM_KEYUP, Int32(VK_RETURN))
            for _ in 0..<40 where WinPopupMenu.openMenuBits != 0 { Thread.sleep(forTimeInterval: 0.1) }
            if WinPopupMenu.openMenuBits != 0 { driver.note("still open; Escape"); post(WM_KEYDOWN, Int32(VK_ESCAPE)); post(WM_KEYUP, Int32(VK_ESCAPE)) }
            driver.note("down=\(presses)")
            driver.finish()
        }.start()
        let c = POINT(x: (w.frame.left + w.frame.right) / 2, y: (w.frame.top + w.frame.bottom) / 2)
        _ = PostMessageW(w.hwnd, 0x007B /* WM_CONTEXTMENU */, WPARAM(UInt(bitPattern: Int(bitPattern: UnsafeMutableRawPointer(w.hwnd)))), lParam(c.x, c.y))
        _ = await WindowsSelftest.waitUntil(timeout: 15) { driver.done }
        await wait(0.3)
        return driver
    }

    static func menuCheck(_ r: WindowsSelftest.Recorder, _ app: WindowsAppDelegate) async {
        guard WindowsSelftest.onCI else {
            r.add("pet.menu", true, "skipped: CI not set (the menu takes the foreground)")
            return
        }
        let l = app.companion.l
        let h = await PetHarness.make(.eggIncubating)
        defer { h.destroy() }
        guard await h.waitShown(), let w = h.window else {
            r.add("pet.menu", false, "the pet did not show")
            return
        }
        let owner = app.sink.hwnd
        // Back view: checked state, then toggled.
        let a = await runMenu(w, owner: owner, pick: 2)
        let backOn = h.store.alwaysFacesBack
        let b = await runMenu(w, owner: owner, pick: 2)
        let backOff = !h.store.alwaysFacesBack
        // Open: always opens (an egg too): the host is asked with `.menu`.
        let c = await runMenu(w, owner: owner, pick: 0)
        let openAsked = h.openers == [.menu]
        // Turn off: the setting off, the window gone.
        let d = await runMenu(w, owner: owner, pick: 1)
        let off = await WindowsSelftest.waitUntil(timeout: 2) { !h.store.floatingPetEnabled && h.pet.window == nil }
        let titlesOK = a.titles == [l.floatingPetMenuOpen, l.floatingPetMenuHide, l.backViewLabel] && a.checked == [false, false, false] && b.checked == [false, false, true]
        r.add("pet.menu", titlesOK && backOn && backOff && openAsked && off && h.pet.stats.menus == 4,
              "entries \(a.titles) checked \(a.checked) (then \(b.checked)); Back view -> on=\(backOn), again -> off=\(backOff); Open -> host asked \(h.openers); "
              + "Turn off -> setting off and window gone=\(off); menus \(h.pet.stats.menus); keys [\(a.notes)|\(b.notes)|\(c.notes)|\(d.notes)]")
    }

    // MARK: - pet.zOrder: below the open popover (the Mac's popover level is above the pet's), above other windows

    static func zOrderCheck(_ r: WindowsSelftest.Recorder, _ app: WindowsAppDelegate) async {
        guard WindowsSelftest.onCI, let popover = app.popover else {
            r.add("pet.zOrder", true, "skipped: CI not set (the popover takes the foreground)")
            return
        }
        guard let probe = WindowsSelftestPopoverWindow.makeProbe() else { r.add("pet.zOrder", false, "no probe"); return }
        defer { probe.destroy() }
        WindowsSelftest.forceForeground(probe.hwnd)
        popover.close(.destroyed)
        popover.present(.secondLaunch) { _ in }
        let open = await WindowsSelftest.waitUntil(timeout: 3) { popover.hwnd.map { IsWindowVisible($0) } == true }
        let h = await PetHarness.make(.hatched)
        defer { h.destroy() }
        let up = await h.waitShown()
        let petBelow: Bool = {
            guard let p = popover.hwnd, let pet = h.window?.hwnd else { return false }
            return below(p).contains(pet)
        }()
        let topmost = h.window.map { DWORD(bitPattern: GetWindowLongW($0.hwnd, -20)) & 0x8 != 0 } ?? false
        let stillOpen = popover.isOpen
        popover.close(.destroyed)
        // The popover opening while the pet is up goes above it; the pet stays above the probe (a normal window).
        WindowsSelftest.forceForeground(probe.hwnd)
        popover.present(.secondLaunch) { _ in }
        let open2 = await WindowsSelftest.waitUntil(timeout: 3) { popover.hwnd.map { IsWindowVisible($0) } == true }
        let popoverAbove: Bool = {
            guard let p = popover.hwnd, let pet = h.window?.hwnd else { return false }
            return below(p).contains(pet)
        }()
        let aboveProbe = h.window.map { below($0.hwnd).contains(probe.hwnd) } ?? false
        popover.close(.destroyed)
        r.add("pet.zOrder", open && up && petBelow && topmost && stillOpen && open2 && popoverAbove && aboveProbe,
              "popover open=\(open), pet shown after it=\(up): below the popover=\(petBelow), topmost=\(topmost), popover still open=\(stillOpen); popover opened over the pet=\(open2): "
              + "above it=\(popoverAbove); pet above a normal window=\(aboveProbe)")
    }

    // MARK: - pet.animation: the frame floor (capFrameRate), and when the clock stops

    static func animationCheck(_ r: WindowsSelftest.Recorder) async {
        guard let fixture = gifFixture(count: 40, delay: 0.05) else {
            r.add("pet.animation", false, "the bundled ice-shatter GIF did not load")
            return
        }
        let saved = WinFloatingPet.spriteFetcherOverride
        WinFloatingPet.spriteFetcherOverride = fixture
        defer { WinFloatingPet.spriteFetcherOverride = saved }
        var notes: [String] = []
        var ok = true
        let h = await PetHarness.make(.hatched)
        defer { h.destroy() }
        guard await h.waitShown(), let w = h.window else {
            r.add("pet.animation", false, "no window")
            return
        }
        for quality in UsageStore.AnimationQuality.allCases {
            h.store.animationQuality = quality
            _ = await WindowsSelftest.waitUntil(timeout: 3) { w.playback.frameFloor == quality.frameFloor && w.playback.models.first?.isAnimating == true && w.playback.clock.isArmed }
            await wait(0.3)
            let frames = w.playback.models.first?.frames ?? []
            let ticks0 = w.playback.ticks, renders0 = h.pet.stats.renders
            await wait(2)
            let ticks = w.playback.ticks - ticks0, renders = h.pet.stats.renders - renders0
            let expected = 2 / quality.frameFloor
            let delaysOK = frames.allSatisfy { abs($0.delay - quality.frameFloor) < 0.001 } && frames.count == Int((2.0 / quality.frameFloor).rounded())
            let rateOK = Double(ticks) >= expected * 0.7 && Double(ticks) <= expected + 2 && renders >= ticks - 1 && renders <= ticks + 1
            ok = ok && delaysOK && rateOK
            notes.append("\(quality.rawValue) (floor \(quality.frameFloor) s): 40 x 0.05 s -> \(frames.count) frames of \(frames.first.map { String(format: "%.2f", $0.delay) } ?? "-") s=\(delaysOK); "
                         + "2 s: \(ticks) ticks (expected ~\(Int(expected))), \(renders) renders=\(rateOK)")
        }
        h.store.animationQuality = .powerSaver
        _ = await WindowsSelftest.waitUntil(timeout: 3) { w.playback.frameFloor == 0.4 && w.playback.clock.isArmed }
        // Stops: session lock, animations off, battery saver; and back.
        _ = SendMessageW(w.hwnd, 0x02B1 /* WM_WTSSESSION_CHANGE */, 7 /* WTS_SESSION_LOCK */, 0)
        let lockedOff = !w.playback.clock.isArmed
        let t0 = w.playback.ticks
        await wait(1)
        let lockedQuiet = w.playback.ticks == t0
        _ = SendMessageW(w.hwnd, 0x02B1, 8 /* WTS_SESSION_UNLOCK */, 0)
        let unlocked = w.playback.clock.isArmed
        h.animations = false
        h.pet.environmentChanged()
        let stillOff = await WindowsSelftest.waitUntil(timeout: 2) { !w.playback.clock.isArmed && w.playback.models.first?.isAnimating == false }
        h.animations = true
        h.pet.environmentChanged()
        let animAgain = await WindowsSelftest.waitUntil(timeout: 3) { w.playback.clock.isArmed && w.playback.models.first?.isAnimating == true }
        h.lowPower = true
        h.pet.sync()
        let saverOff = await WindowsSelftest.waitUntil(timeout: 2) { h.pet.model?.animated == false && !w.playback.clock.isArmed }
        h.lowPower = false
        h.pet.sync()
        let saverBack = await WindowsSelftest.waitUntil(timeout: 3) { w.playback.clock.isArmed }
        let playback = w.playback
        h.store.floatingPetEnabled = false
        let hidden = await WindowsSelftest.waitUntil(timeout: 2) { h.pet.window == nil && !playback.clock.isArmed }
        ok = ok && lockedOff && lockedQuiet && unlocked && stillOff && animAgain && saverOff && saverBack && hidden
        notes.append("lock -> clock off=\(lockedOff), no ticks in 1 s=\(lockedQuiet), unlock -> on=\(unlocked); \"Show animations\" off -> still, clock off=\(stillOff), on -> \(animAgain); "
                     + "battery saver -> still=\(saverOff), off -> \(saverBack); hidden -> clock gone=\(hidden)")
        r.add("pet.animation", ok, notes.joined(separator: "; "))
    }

    // MARK: - pet.idle: what a shown pet costs (in-process; the gate's windows are `--pet-idle-probe`)

    /// One window's numbers and the app's own timer wakes inside it (a store refresh costs ~45 main cs and lands in a short window
    /// now and then: `ui.kit.idle`'s budget rule; a window with a refresh is measured once more).
    struct IdleWindow {
        var sample: IdleSampler.Sample
        var known: String
        var extra: Int
    }

    static func idleCheck(_ r: WindowsSelftest.Recorder) async {
        let seconds = 8.0
        func sample(_ label: String) async -> IdleWindow? {
            var last: IdleWindow?
            for _ in 0..<2 {
                // The harness's own settings writes settle first (a debounced sync and the other synced defaults objects
                // reading it back cost the main thread ~25 cs in run 44034801215's 'hidden' window, the pet's window long gone).
                _ = await WindowsSelftest.waitStable(timeout: 10, quiet: 2) { !WinDefaultsSync.isSyncPending }
                let wakes0 = WindowsSelftest.selftestApp.map { WindowsSelftest.knownWakes($0) }
                guard let s = await IdleSampler.measure(seconds: seconds, mainThread: WindowsApp.mainThreadID) else { return nil }
                let wakes1 = WindowsSelftest.selftestApp.map { WindowsSelftest.knownWakes($0) }
                var extra = 0, known = "unknown (no app)", refreshed = false
                if let a = wakes0, let b = wakes1 {
                    extra = 5 * ((b.safety - a.safety) + (b.debounce - a.debounce) + (b.day - a.day)) + 60 * (b.refreshes - a.refreshes)
                    known = b.minus(a)
                    refreshed = b.refreshes != a.refreshes
                }
                last = IdleWindow(sample: s, known: known, extra: extra)
                if !refreshed { break }
            }
            return last
        }
        /// The process quiet (2 s windows of at most one main-thread switch, up to 20 s) before the pet shows: a new harness's
        /// stores finish their own loads first (run 44043860640: ~1.6 message wakes a second for many seconds after a raised
        /// sample was made, with or without a pet; the installed app's gate window, 30 s after start, has none).
        func waitQuiet() async -> TimeInterval {
            let start = Date()
            for _ in 0..<10 {
                guard let q = await IdleSampler.measure(seconds: 2, mainThread: WindowsApp.mainThreadID), q.mainContextSwitches > 1 else { break }
            }
            return Date().timeIntervalSince(start)
        }
        // Still: an egg (no GIF), shown once the process is quiet.
        let still = await PetHarness.make(.eggIncubating, enabled: false)
        let quiet1 = await waitQuiet()
        still.store.floatingPetEnabled = true
        _ = await still.waitShown()
        let armedStill = still.window?.playback.clock.isArmed == true
        let r0 = still.pet.stats.renders
        let s1 = await sample("still")
        let stillRenders = still.pet.stats.renders - r0
        still.destroy()
        // Animated: the FIXTURE 2 s GIF of 40 frames at the default "Power saver" floor (0.4 s: 2.5 frames a second), on a raised
        // sample (`midLevel`, not a fresh hatch: in a bundled app a hatch warms its sprites and names over the network). Then the
        // same pet turned off: what is left once it is hidden.
        let saved = WinFloatingPet.spriteFetcherOverride
        WinFloatingPet.spriteFetcherOverride = gifFixture(count: 40, delay: 0.05)
        let moving = await PetHarness.make(.midLevel, enabled: false)
        let quiet2 = await waitQuiet()
        moving.store.floatingPetEnabled = true
        _ = await moving.waitShown()
        _ = await WindowsSelftest.waitUntil(timeout: 2) { moving.window?.playback.clock.isArmed == true }
        let r1 = moving.pet.stats.renders
        let s2 = await sample("animated")
        let movingRenders = moving.pet.stats.renders - r1
        moving.store.floatingPetEnabled = false
        _ = await WindowsSelftest.waitUntil(timeout: 2) { moving.pet.window == nil }
        // Hidden is judged once quiet, as the gate's window (30 s after start): the bundle selftest of run 44049375908 counted
        // ~1.8 message wakes a second for the first seconds after the hide (18 loop iterations, no timer of ours: the installed
        // selftest of the same run measured 1 main cs). A wake source the pet left behind never goes quiet and fails here.
        let quiet3 = await waitQuiet()
        let s3 = await sample("hidden")
        moving.destroy()
        WinFloatingPet.spriteFetcherOverride = saved
        guard let s1, let s2, let s3 else {
            r.add("pet.idle", false, "measurement failed")
            return
        }
        let frameRate = 1 / UsageStore.AnimationQuality.powerSaver.frameFloor
        let ok = !armedStill && stillRenders == 0 && s1.sample.mainContextSwitches <= 6 + s1.extra && s3.sample.mainContextSwitches <= 6 + s3.extra
            && Double(s2.sample.mainContextSwitches) <= (frameRate + 2) * seconds + Double(s2.extra) && movingRenders >= Int(frameRate * seconds * 0.7)
        func line(_ w: IdleWindow) -> String {
            let s = w.sample
            return "main cs \(s.mainContextSwitches) (\(String(format: "%.1f", Double(s.mainContextSwitches) * 60 / seconds))/min), main cycles \(s.mainCycles), process cycles \(s.processCycles) "
                + "(\(UInt64(Double(s.processCycles) / seconds))/s), known wakes \(w.known) (+\(w.extra) to the budget), busy [\(s.busy)]"
        }
        r.add("pet.idle", ok,
              "\(Int(seconds)) s each, after the process was quiet (\(Int(quiet1)) s, \(Int(quiet2)) s; after the hide \(Int(quiet3)) s). still (egg, no GIF): clock armed=\(armedStill), \(stillRenders) renders, \(line(s1)); animated (FIXTURE 40 x 0.05 s at Power saver = \(frameRate) fps): "
              + "\(movingRenders) renders, \(line(s2)) (budget \(Int((frameRate + 2) * seconds))); hidden after shown: \(line(s3)) (budget for still and hidden: 6)")
    }

    // MARK: - pet.capture (`--dump-ui <dir>`: pet/)

    static func captureCheck(_ r: WindowsSelftest.Recorder) async {
        guard let root = WinUIDump.directory(from: CommandLine.arguments) else {
            r.add("pet.capture", true, "skipped: no --dump-ui")
            return
        }
        let dir = root.appendingPathComponent("pet", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var written: [String] = [], failed: [String] = []
        func write(_ w: WinPetWindow, _ name: String) {
            guard let snap = w.snapshot() else { failed.append(name); return }
            // Over white (premultiplied: out = src + (1 − a) × 255), the Mac renders' background.
            var bgra = snap.bgra
            for i in stride(from: 0, to: bgra.count, by: 4) {
                let a = Int(bgra[i + 3])
                for c in 0..<3 { bgra[i + c] = UInt8(min(255, Int(bgra[i + c]) + (255 - a))) }
                bgra[i + 3] = 255
            }
            let bitmap = WinUIDump.Bitmap(width: snap.side, height: snap.side, bgra: bgra)
            if WinUIDump.write(bitmap, to: dir.appendingPathComponent("pet-\(name).png")) == 0 { written.append(name) } else { failed.append(name) }
        }
        let cases: [(CompanionHeaderSample, Double, String)] = [(.eggIncubating, 96, "egg-96"), (.hatched, 96, "hatched-96"), (.shiny, 96, "shiny-96"),
                                                                 (.back, 96, "back-96"), (.form, 96, "form-96"), (.hatched, 48, "hatched-48"),
                                                                 (.hatched, 192, "hatched-192"), (.hatched, 384, "hatched-384")]
        for (sample, size, name) in cases {
            let h = await PetHarness.make(sample, size: size)
            if sample == .back { h.store.alwaysFacesBack = true }
            if await h.waitShown(), let w = h.window {
                write(w, name)   // right after it appears: the GIF's first frame (the clock's first tick is a floor later), as the Mac's offscreen render
                if name == "hatched-96" {
                    _ = SendMessageW(w.hwnd, 0x02E0 /* WM_DPICHANGED */, WPARAM(144 | (144 << 16)), 0)
                    write(w, "hatched-96-at-144dpi")
                    _ = SendMessageW(w.hwnd, 0x02E0, WPARAM(96 | (96 << 16)), 0)
                    // The pet on the screen: what the runner's desktop shows around it.
                    let f = w.frame
                    if let shot = WinUIDump.screenshot(x: Int(f.left) - 40, y: Int(f.top) - 40, w: Int(f.right - f.left) + 80, h: Int(f.bottom - f.top) + 80),
                       WinUIDump.write(shot, to: dir.appendingPathComponent("pet-hatched-96-screen.png")) == 0 {
                        written.append("hatched-96-screen")
                    }
                }
            } else {
                failed.append(name)
            }
            h.destroy()
        }
        r.add("pet.capture", failed.isEmpty, "wrote \(written.count) to \(dir.path): \(written); failed \(failed) (FIXTURE sprites: \(WindowsSelftestPopoverCompanion.spriteDirectory?.path ?? "none"))")
    }

    // MARK: - pet.resources: shown and hidden 4 times, judged by PopoverResourceRule

    static func resourcesCheck(_ r: WindowsSelftest.Recorder, start: KitResources) async {
        var cycles: [KitResources] = []
        let live0 = WinSinkWindow.liveCount
        let h = await PetHarness.make(.hatched)
        defer { h.destroy() }
        var armedAfter = false
        for _ in 0..<4 {
            h.store.floatingPetEnabled = true
            _ = await h.waitShown()
            let playback = h.window?.playback
            h.store.floatingPetEnabled = false
            _ = await WindowsSelftest.waitUntil(timeout: 2, poll: 0.005) { h.pet.window == nil }
            armedAfter = armedAfter || playback?.released != true || playback?.clock.isArmed == true
            await wait(0.3)
            cycles.append(KitResources.now())
        }
        let verdict = PopoverResourceRule.judge(cycles.map { .init(gdi: $0.gdi, user: $0.user, handles: $0.handles) })
        let liveOK = WinSinkWindow.liveCount == live0
        r.add("pet.resources", verdict.ok && liveOK && !armedAfter,
              "4 show/hide cycles: \(verdict.summary); windows \(live0) -> \(WinSinkWindow.liveCount); a playback not released or a clock armed right after a hide=\(armedAfter); group start \(start)")
    }

    // MARK: - the idle gate's windows (`--pet-idle-probe still|animated|hidden`; CI only)

    private static var idleProbe: PetHarness?

    /// The installed app with the gate's settings, and one pet over sample stores (the app's own pet stays off): `still` an egg,
    /// `animated` the raised sample's (Ivysaur) FIXTURE GIF at the stored animation quality (default Power saver) with Windows' "Show
    /// animations" taken as on (the runner has it off), `hidden` a pet shown for 3 s and turned off.
    static func startIdleProbe(mode: String) {
        guard WindowsSelftest.onCI else {
            AppLog.write("pet idle probe: CI not set; nothing shown")
            return
        }
        WinFloatingPet.spriteFetcherOverride = WindowsSelftestPopoverCompanion.fixtureFetcher()
        Task { @MainActor in
            await wait(3)
            let h = await PetHarness.make(mode == "still" ? .eggIncubating : .midLevel)   // not a fresh hatch: no network warm-up in the window
            idleProbe = h
            let shown = await h.waitShown()
            if mode == "hidden" {
                await wait(3)
                h.store.floatingPetEnabled = false
                _ = await WindowsSelftest.waitUntil(timeout: 2) { h.pet.window == nil }
            }
            let model = h.window?.playback.models.first
            AppLog.write("pet idle probe: mode=\(mode) shown=\(shown) window=\(h.window != nil) picture=\(model?.current == nil ? "none" : "loaded") gif frames=\(model?.frames.count ?? 0) "
                         + "floor=\(h.window?.playback.frameFloor ?? -1) clock armed=\(h.window?.playback.clock.isArmed == true) \(KitResources.now())")
        }
    }
}
#endif
