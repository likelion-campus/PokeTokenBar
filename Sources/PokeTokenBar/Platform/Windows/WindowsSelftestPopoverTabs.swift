#if os(Windows)
import CPlazaD2D
import Foundation
import WinSDK

// Stage 7 Task 19: the tab strip's selftest group. Sample data only (fixture stores; nothing is read from this PC).

extension WindowsSelftest {
    @MainActor static func popoverTabsChecks(_ r: Recorder, _ app: WindowsAppDelegate) async {
        await WindowsSelftestPopoverTabs.run(r, app)
    }
}

@MainActor enum WindowsSelftestPopoverTabs {
    static let names = ["popover.tabs"]

    private static func wait(_ seconds: TimeInterval) async { _ = await WindowsSelftest.waitUntil(timeout: seconds) { false } }

    /// A page for `tab` in a kit window (no popover: a pick is reported through `tabChanged`).
    private static func harness(_ tab: PopoverState.Tab, language: AppLanguage) async -> HomeHarness? {
        let stores = await HomeStores.make(language: language)
        stores.state.tab = tab
        guard let h = HomeHarness(stores: stores, input: { HomeFixtures.update($0, now: $1) }, heightDIP: 640) else { return nil }
        return h
    }

    static func run(_ r: WindowsSelftest.Recorder, _ app: WindowsAppDelegate) async {
        var problems: [String] = []
        var notes: [String] = []
        // 1. every tab: the strip with the Mac's four titles, the tab selected, pinned above the scroller, the 520 pt rule
        var heights: [CGFloat] = []
        for language in [AppLanguage.en, .ko] {
            for tab in PopoverTabsModel.order {
                guard let h = await harness(tab, language: language) else { problems.append("no window for \(tab) \(language)"); continue }
                defer { h.destroy() }
                h.window.show(activate: false)
                await wait(0.3)
                let model = PopoverTabsModel(tab: tab, l: L(language))
                let strip = h.page.tabStrip
                let titles = strip?.parts.map { WinKit.text(of: $0) } ?? []
                let selected = strip?.selection ?? -1
                if titles != model.titles { problems.append("\(tab) \(language): strip titles \(titles) != \(model.titles)") }
                if selected != model.selected { problems.append("\(tab) \(language): selected \(selected) != \(model.selected)") }
                if h.page.builtTab != tab { problems.append("\(tab): page built for \(h.page.builtTab)") }
                if let area = h.window.scroll, let first = strip?.parts.first {
                    let view = WinKit.rect(area.viewport.hwnd, in: h.window.hwnd), at = WinKit.rect(first, in: h.window.hwnd)
                    if at.bottom > view.top { problems.append("\(tab): the strip is not above the scroller (\(at.bottom) > \(view.top))") }
                    area.scroll(to: area.contentHeight)
                    await wait(0.1)
                    let after = WinKit.rect(first, in: h.window.hwnd)
                    if after.top != at.top { problems.append("\(tab): the strip moved while the scroller scrolled") }
                }
                if language == .en { heights.append(h.page.heightDIP) }
            }
        }
        // The Mac frames a list at 520 pt and nothing else: an empty Bag or Pokédex (this fixture has neither items nor a dex) is as short as
        // its content. Home and Shop are the same height; the empty tabs are not taller.
        if heights.count == 4, heights[0] != heights[1] || heights[2] > heights[0] || heights[3] > heights[0] { problems.append("window heights by tab (Home, Shop, Bag, Collection): \(heights)") }
        notes.append("4 tabs x en/ko: strip titles, selected tab, pinned above the scroller; window heights \(heights)")

        // 2. picking a tab (kit window, no popover): `state.tab` changes and the page asks for the other tab; the arrow keys move
        //    inside the group and the picks follow; the keyboard needs the foreground
        if let h = await harness(.home, language: .en) {
            defer { h.destroy() }
            var picked: [PopoverState.Tab] = []
            h.page.tabChanged = { picked.append($0) }
            h.window.fitToContent()
            h.window.show(activate: WindowsSelftest.onCI)  // takes the foreground: CI only
            await wait(0.5)
            let foreground = GetForegroundWindow() == h.window.hwnd
            if !WindowsSelftest.onCI {
                notes.append("arrow key: skipped, not CI (a real key to the foreground window)")
            } else if let strip = h.page.tabStrip, strip.parts.count == 4 {
                _ = SetFocus(strip.parts[0])
                WindowsSelftestPopover.tap(0x27)  // VK_RIGHT
                await wait(0.3)
                let right = picked == [.shop] && h.stores.state.tab == .shop
                notes.append("foreground=\(foreground); Right arrow on Home -> pick \(picked) state.tab=\(h.stores.state.tab) ok=\(right)")
                if !foreground || !right { problems.append("arrow key: foreground=\(foreground) picks=\(picked)") }
            } else {
                problems.append("no strip with four buttons")
            }
        } else { problems.append("no window for the pick check") }

        // 3. open and close the pages four times: nothing left behind, no timer armed
        // every tab is built once first: the cycles below build a different tab each, and a tab's first build is not a leak
        for tab in PopoverTabsModel.order {
            guard let h = await harness(tab, language: .en) else { continue }
            h.window.fitToContent()
            h.window.show(activate: false)
            await wait(0.3)
            h.destroy()
            await wait(0.2)
        }
        var cycles: [KitResources] = []
        var armedAfter = false
        let start = KitResources.now()
        for i in 0..<4 {
            guard let h = await harness(PopoverTabsModel.order[i % 4], language: .en) else { break }
            h.window.fitToContent()
            h.window.show(activate: false)
            await wait(0.3)
            h.destroy()
            armedAfter = armedAfter || h.page.clock.isArmed
            await wait(0.2)
            cycles.append(KitResources.now())
        }
        if cycles.count == 4, let last = cycles.last {
            let verdict = PopoverResourceRule.judge(cycles.map { .init(gdi: $0.gdi, user: $0.user, handles: $0.handles) }, userSlack: 1)
            let ok = verdict.ok && last.controls == 0 && last.dialogs == start.dialogs && last.pumpDepth == 0 && !armedAfter
            if !ok { problems.append("open/close: \(verdict.summary); clock armed after close=\(armedAfter); \(last)") }
            notes.append("open/close x4 over the four tabs: \(verdict.summary); clock armed after a close=\(armedAfter); \(last)")
        } else { problems.append("open/close: only \(cycles.count) of 4 cycles") }

        // 4. the app's real popover (CI: it takes the foreground): pick Shop with the mouse path, the keyboard stays on the strip,
        //    Settings and back keeps the tab, a reopen starts on Home
        if WindowsSelftest.onCI, let popover = app.popover, let probe = WindowsSelftestPopoverWindow.makeProbe() {
            defer { probe.destroy() }
            popover.close(.destroyed)
            WindowsSelftest.forceForeground(probe.hwnd)
            _ = await WindowsSelftest.waitUntil(timeout: 1) { GetForegroundWindow() == probe.hwnd }
            _ = PostMessageW(app.sink.hwnd, WinTray.callbackMessage, 0, LPARAM(Int(PopoverRun.ninKeySelect) | (1 << 16)))
            if await WindowsSelftest.waitUntil(timeout: 3, { popover.isOpen }), let hwnd = popover.hwndForTesting {
                await wait(0.4)
                let l = L(app.companion.language)
                func button(_ text: String) -> HWND? {
                    var found: HWND?
                    func walk(_ root: HWND) {
                        var child = GetWindow(root, 5)
                        while let c = child, found == nil {
                            if WinKit.className(c) == "Button", WinKit.text(of: c) == text { found = c }
                            else { walk(c) }
                            child = GetWindow(c, 2)
                        }
                    }
                    walk(hwnd)
                    return found
                }
                var results: [String] = []
                for (title, tab) in [(l.shop, PopoverState.Tab.shop), (l.bag, .bag), (l.collection, .collection), (l.home, .home)] {
                    guard let b = button(title) else { problems.append("no '\(title)' button"); continue }
                    WinKit.send(b, 0x00F5 /* BM_CLICK */)
                    await wait(0.6)
                    let page = popover.pageForTesting as? WinHomePage
                    let focus = GetFocus()
                    let onStrip = page?.tabStrip?.parts.contains { $0 == focus } ?? false
                    let ok = page?.builtTab == tab && popover.state.tab == tab && onStrip
                    results.append("\(title): page=\(String(describing: page?.builtTab)) focus on the strip=\(onStrip)")
                    if !ok { problems.append("popover pick \(title): \(results.last ?? "")") }
                }
                // Settings and back: the tab is the one it was
                popover.state.tab = .bag
                popover.state.showSettings = true
                popover.replacePage()
                await wait(0.5)
                let onSettings = popover.pageForTesting is WinSettingsPage
                popover.state.showSettings = false
                popover.replacePage()
                await wait(0.5)
                let back = (popover.pageForTesting as? WinHomePage)?.builtTab == .bag
                popover.close(.destroyed)
                _ = PostMessageW(app.sink.hwnd, WinTray.callbackMessage, 0, LPARAM(Int(PopoverRun.ninKeySelect) | (1 << 16)))
                _ = await WindowsSelftest.waitUntil(timeout: 3) { popover.isOpen }
                await wait(0.4)
                let reopenedHome = (popover.pageForTesting as? WinHomePage)?.builtTab == .home && popover.state.tab == .home
                popover.close(.destroyed)
                if !onSettings || !back || !reopenedHome { problems.append("Settings round trip: settings=\(onSettings) back on Bag=\(back) reopened on Home=\(reopenedHome)") }
                notes.append("real popover: \(results.joined(separator: "; ")); Settings and back kept Bag=\(back); reopen on Home=\(reopenedHome)")
            } else {
                problems.append("the popover did not open")
            }
        } else {
            notes.append("real popover: skipped (CI not set)")
        }
        r.add("popover.tabs", problems.isEmpty, notes.joined(separator: " | ") + (problems.isEmpty ? "" : " | PROBLEMS: " + problems.joined(separator: "; ")))
    }
}
#endif
