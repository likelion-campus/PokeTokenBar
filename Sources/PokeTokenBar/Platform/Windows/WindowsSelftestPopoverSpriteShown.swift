#if os(Windows)
import Foundation
import WinSDK

// fix/windows-popover-sprite-shown: `popover.spriteShown`. The user's PC (kit 11) showed every popover sprite decoded and its clock
// stopped at the first tick by `WinSpriteAnimator.isShown` reading false: the walk went from the top-level popover on to its owner
// (`GetParent` of a popup is the owner), the app's hidden sink, whose empty client area meets nothing. The sprite checks ran in a
// KitWindow, which has no owner. This one opens the real popover (`WinPopover`, owned by the app's sink as the app's is, at the tray
// position, Home inside its scroller), with the bundled FIXTURE GIF for #1 and animation on (the runner's "Show animations" is off),
// and judges the header and the Collection detail (reached by a real click on its grid cell, as a person does): shown, the clock
// running, the frame moving, the screen at the sprite's slot changing. Then a clock stops and comes back by
// itself: the header scrolled out of Home's viewport made short (the fixture's Home fits the popover) and back (its paint); the
// detail's pane hidden and shown again (the view gets no WM_SHOWWINDOW, only its paint); displays off and on (no paint: the wake).
// The walk before the fix is printed beside (the trigger: it reads false here). CI only (the popover takes the foreground). Fixture
// data only.

extension WindowsSelftest {
    @MainActor static func popoverSpriteShownCheck(_ r: Recorder, _ app: WindowsAppDelegate) async {
        await WindowsSelftestSpriteShown.run(r, app)
    }
}

@MainActor enum WindowsSelftestSpriteShown {
    static let names = ["popover.spriteShown"]

    /// What `isShown` read before the fix: up `GetParent`, which for the top-level popup is its owner.
    static func ownerWalkShown(_ hwnd: HWND) -> Bool {
        guard IsWindowVisible(hwnd) else { return false }
        var area = RECT()
        guard GetWindowRect(hwnd, &area) else { return false }
        var parent = GetParent(hwnd)
        while let p = parent {
            var client = RECT()
            var origin = POINT(x: 0, y: 0)
            guard GetClientRect(p, &client), ClientToScreen(p, &origin) else { return false }
            var bounds = RECT(left: origin.x, top: origin.y, right: origin.x + client.right, bottom: origin.y + client.bottom)
            var meet = RECT()
            guard IntersectRect(&meet, &area, &bounds) else { return false }
            area = meet
            parent = GetParent(p)
        }
        return true
    }

    /// Two seconds of one view's clock: shown, armed, ticks and frames moved, and the screen at the sprite's slot (eight looks
    /// 0.25 s apart, `ptb_capture_screen`: what the person sees, not the model; fix/windows-pet-and-detail-animation).
    struct Run { var shown: Bool, before: Bool, armed: Bool, ticks: Int, frames: Int, moved: Bool, at: RECT, screens: Int, slot: RECT }

    /// The first sprite slot of `view` on the screen (device pixels).
    static func slotOnScreen(_ view: WinDrawnView) -> RECT? {
        guard let slot = view.spriteSlots.first(where: { $0.subject != nil }) else { return nil }
        let s = view.ctx.scale
        var origin = POINT(x: Int32((slot.frame.minX * s).rounded()), y: Int32((slot.frame.minY * s).rounded()))
        guard ClientToScreen(view.hwnd, &origin) else { return nil }
        return RECT(left: origin.x, top: origin.y, right: origin.x + Int32((slot.frame.width * s).rounded()), bottom: origin.y + Int32((slot.frame.height * s).rounded()))
    }

    static func measure(_ animator: WinSpriteAnimator, _ view: WinDrawnView, _ popover: HWND) async -> Run {
        _ = await WindowsSelftest.waitUntil(timeout: 3) { animator.playback.models.first?.isAnimating == true && animator.playback.clock.isArmed }
        var at = RECT()
        _ = GetWindowRect(popover, &at)
        let slot = slotOnScreen(view) ?? RECT()
        let ticks0 = animator.playback.ticks, index0 = animator.playback.models.first?.frameIndex ?? -1
        var moved = false, screens: [Int] = []
        for i in 0..<8 {
            if i > 0 { _ = await WindowsSelftest.waitUntil(timeout: 0.25) { false } }
            if (animator.playback.models.first?.frameIndex ?? -1) != index0 { moved = true }
            if slot.right > slot.left, let shot = WinUIDump.screenshot(x: Int(slot.left), y: Int(slot.top), w: Int(slot.right - slot.left), h: Int(slot.bottom - slot.top)) {
                screens.append(shot.bgra.hashValue)
            }
        }
        return Run(shown: WinSpriteAnimator.isShown(view.hwnd), before: ownerWalkShown(view.hwnd), armed: animator.playback.clock.isArmed,
                   ticks: animator.playback.ticks - ticks0, frames: animator.playback.models.first?.frames.count ?? 0, moved: moved, at: at,
                   screens: Set(screens).count, slot: slot)
    }

    static func describe(_ name: String, _ m: Run) -> String {
        "\(name): popover at (\(m.at.left),\(m.at.top)) \(m.at.right - m.at.left)x\(m.at.bottom - m.at.top), \(m.frames) frames, shown=\(m.shown) "
            + "(the walk before the fix read \(m.before)), in 2 s: \(m.ticks) ticks, the frame moved=\(m.moved), clock armed=\(m.armed), "
            + "distinct screens at the slot (\(m.slot.left),\(m.slot.top)) \(m.slot.right - m.slot.left)x\(m.slot.bottom - m.slot.top): \(m.screens) of 8"
    }

    static func good(_ m: Run) -> Bool { m.shown && m.armed && m.ticks >= 8 && m.moved && m.frames > 1 && m.screens >= 2 }

    /// The app's displays-off / on, as Windows sends it to the sink (`GUID_CONSOLE_DISPLAY_STATE`).
    static func display(_ sink: HWND, _ state: UInt32) {
        var bytes: [UInt8] = []
        withUnsafeBytes(of: WindowsSystemEvents.displayStateGUID) { bytes += $0 }
        withUnsafeBytes(of: UInt32(4)) { bytes += $0 }
        withUnsafeBytes(of: state) { bytes += $0 }
        bytes.withUnsafeBytes {
            _ = SendMessageW(sink, UINT(WM_POWERBROADCAST), WPARAM(WindowsSystemEvents.pbtPowerSettingChange), LPARAM(Int(bitPattern: $0.baseAddress)))
        }
    }

    static func run(_ r: WindowsSelftest.Recorder, _ app: WindowsAppDelegate) async {
        let name = "popover.spriteShown"
        guard WindowsSelftest.onCI else {
            r.add(name, true, "skipped: CI not set (the popover takes the foreground)")
            return
        }
        guard let (fetcher, _, _) = WindowsSelftestPopover.fixtureGIF() else {
            r.add(name, false, "the bundled ice-shatter GIF did not load")
            return
        }
        guard let probe = WindowsSelftestPopoverWindow.makeProbe() else {
            r.add(name, false, "no probe window: \(GetLastError())")
            return
        }
        defer { probe.destroy() }
        let savedFetcher = WinCompanionSection.spriteFetcherOverride
        WinCompanionSection.spriteFetcherOverride = fetcher
        let suite = "ptb.selftest.spriteshown.\(UUID().uuidString.prefix(8))"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        let stores = await HomeStores.make(language: .en)
        let (companion, companionDir) = WindowsSelftestPopoverCompanion.fixtureCompanion(language: .en, eggUsage: 1)
        await companion.hatch(baseID: 1)
        let loginItem = WindowsLoginItem(runKey: #"Software\PokeTokenBarSelftest\SpriteShown\Run"#, approvedKey: #"Software\PokeTokenBarSelftest\SpriteShown\Approved"#,
                                         valueName: "PokeTokenBarSpriteShown", command: WindowsLoginItem.command(forExecutable: #"C:\Fixture\PokeTokenBar.exe"#))
        let host = WinPopoverHost(store: stores.store, companion: companion, updater: nil, team: TeamSettings(defaults: defaults), session: nil, feed: nil,
                                  tray: nil, loginItem: loginItem, openPlaza: {})
        host.owner = app.sink.hwnd   // as the app's popover: the owner is the hidden sink (the trigger)
        let popover = WinPopover(host: host)
        popover.makePage = { p in
            let page = WinSettingsPage.routed(p)
            (page as? WinHomePage)?.configureCompanion = { $0.animationsEnabled = { true } }   // the runner's "Show animations" is off
            return page
        }
        defer {
            popover.close(.destroyed)
            WinCompanionSection.spriteFetcherOverride = savedFetcher
            stores.remove()
            try? FileManager.default.removeItem(at: companionDir)
            UserDefaults.standard.removePersistentDomain(forName: suite)
            WinRegistry.deleteTree(#"Software\PokeTokenBarSelftest\SpriteShown"#)
        }
        var notes: [String] = []
        WindowsSelftest.forceForeground(probe.hwnd)
        _ = await WindowsSelftest.waitUntil(timeout: 1) { GetForegroundWindow() == probe.hwnd }
        popover.present(.secondLaunch) { _ in }
        let up = await WindowsSelftest.waitUntil(timeout: 3) { popover.pageForTesting is WinHomePage && popover.hwndForTesting.map { IsWindowVisible($0) } == true }
        guard up, let window = popover.hwndForTesting, let home = popover.pageForTesting as? WinHomePage,
              let header = home.companionSection?.header, let headerSprites = header.view.sprites else {
            r.add(name, false, "the real popover's Home with its companion header did not come up (up=\(up))")
            return
        }
        let owner = GetWindow(window, UINT(GW_OWNER))
        notes.append("the popover's owner is the app's sink=\(owner == app.sink.hwnd), a child window=\(GetWindowLongW(window, -16) & 0x4000_0000 != 0)")

        // 1. The header (Home, inside the scroller).
        let h = await measure(headerSprites, header.view, window)
        notes.append(describe("Home's header #1", h))

        // Scrolled out of Home's scroller and back (its paint). The viewport is made 80 px tall so the header can leave it whatever
        // Home's height (the fixture's Home fits the popover). Not the detail: its drawn view is the whole tab's content, so part
        // of it always stays in the viewport (`isShown` judges the view; its sprite slot may be out while the view is not).
        var back: [Bool] = []
        if let area = home.scrollAreaForTesting, let frame = GetParent(area.viewport.hwnd) {
            let full = WinKit.rect(area.viewport.hwnd, in: frame)
            area.move(RECT(left: full.left, top: full.top, right: full.right, bottom: full.top + 80))
            area.scroll(to: 100_000)
            var view = RECT(), port = RECT(), meet = RECT()
            _ = GetWindowRect(header.view.hwnd, &view)
            _ = GetWindowRect(area.viewport.hwnd, &port)
            let left = !IntersectRect(&meet, &view, &port)
            let offset = area.offset, content = area.contentHeight
            let out = await WindowsSelftest.waitUntil(timeout: 2) { !headerSprites.playback.clock.isArmed }
            area.scroll(to: 0)
            let again = await WindowsSelftest.waitUntil(timeout: 2) { headerSprites.playback.clock.isArmed }
            area.move(full)
            back.append(left && out && again)
            notes.append("Home scrolled (viewport 80 px, content \(content) px, offset \(offset)): the header out of the viewport=\(left), "
                         + "the clock stopped=\(out); scrolled back: running again=\(again)")
        } else {
            back.append(false)
            notes.append("scrolled out: Home has no scroll area")
        }

        // 2. The Collection detail of #1.
        popover.state.tab = .collection
        popover.replacePage()
        _ = await WindowsSelftest.waitUntil(timeout: 3) { (popover.pageForTesting as? WinHomePage)?.builtTab == .collection }
        guard let dexHome = popover.pageForTesting as? WinHomePage, let dex = dexHome.tabContent as? WinCollectionPage else {
            r.add(name, false, (notes + ["the Collection tab did not come up"]).joined(separator: "; "))
            return
        }
        dex.animationsEnabled = { true }
        // As the person does it: a real click on the grid's cell for #1 (fix/windows-pet-and-detail-animation; was `openEntry`).
        let cells: [WinControl] = {
            guard let grid = dex.dexView else { return [] }
            let list = (grid.drawing?.drawing.accessibility ?? []).filter { $0.role != .scrollArea }
            return zip(grid.items, list).filter { $0.1.action?.action == DexBodyPart.cellAction }.map(\.0)
        }()
        var cell = RECT()
        if let first = cells.first { _ = GetWindowRect(first.hwnd, &cell) }
        guard cell.right > cell.left else {
            r.add(name, false, (notes + ["the Collection grid has no cell to click (\(cells.count) cells)"]).joined(separator: "; "))
            return
        }
        await WindowsSelftestPopoverPet.realClick(at: POINT(x: (cell.left + cell.right) / 2, y: (cell.top + cell.bottom) / 2))
        _ = await WindowsSelftest.waitUntil(timeout: 4) { dex.detailView?.sprites?.playback.models.first?.isAnimating == true }
        notes.append("the grid cell clicked at (\((cell.left + cell.right) / 2),\((cell.top + cell.bottom) / 2)) -> the detail opened=\(dex.isShowingDetail) (\(dex.stats.opened))")
        guard let detail = dex.detailView, let detailSprites = detail.sprites else {
            r.add(name, false, (notes + ["the Collection detail of #1 has no sprite"]).joined(separator: "; "))
            return
        }
        let d = await measure(detailSprites, detail, window)
        notes.append(describe("the Collection detail #1", d))

        // 3. Stopped and back by itself: its pane hidden and shown (its paint), displays off and on.
        if let pane = GetParent(detail.hwnd) {
            _ = ShowWindow(pane, 0 /* SW_HIDE: the view itself gets no WM_SHOWWINDOW */)
            let stopped = await WindowsSelftest.waitUntil(timeout: 2) { !detailSprites.playback.clock.isArmed }
            _ = ShowWindow(pane, 8 /* SW_SHOWNA */)
            let again = await WindowsSelftest.waitUntil(timeout: 2) { detailSprites.playback.clock.isArmed }
            back.append(stopped && again)
            notes.append("its pane hidden: the clock stopped at its tick=\(stopped); shown again: running again (its paint)=\(again)")
        }
        let resumes1 = detailSprites.stats.resumes
        display(app.sink.hwnd, 0)
        let asleep = await WindowsSelftest.waitUntil(timeout: 2) { !detailSprites.playback.clock.isArmed }
        display(app.sink.hwnd, 1)
        let awake = await WindowsSelftest.waitUntil(timeout: 2) { detailSprites.playback.clock.isArmed }
        let byWake = detailSprites.stats.resumes > resumes1
        back.append(asleep && awake && byWake)
        notes.append("displays off: the clock stopped at its tick=\(asleep); displays on: running again=\(awake) (by the wake=\(byWake))")
        if Platform.current.events.displaysAreAsleep { display(app.sink.hwnd, 1) }

        let ok = good(h) && good(d) && !back.contains(false)
        r.add(name, ok, notes.joined(separator: "; "))
    }
}
#endif
