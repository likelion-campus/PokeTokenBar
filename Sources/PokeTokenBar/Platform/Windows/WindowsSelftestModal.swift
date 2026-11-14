#if os(Windows)
import Foundation
import WinSDK

/// The tray menu's modal loop must not starve the main queue (`WinModalPump`). One real menu is held open ~1.5 s
/// (the menu key checks' technique: opened from a timer, closed by a posted Escape from a helper thread) while a
/// helper thread feeds the main queue; every item records whether it ran while the menu was open.
extension WindowsSelftest {
    private struct Ran: Sendable {
        let kind: String
        let atMs: Double
        let latencyMs: Double
        let whileOpen: Bool
    }

    private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [Ran] = []
        private var notes: [String] = []
        private var flags: [String: String] = [:]
        func record(_ kind: String, posted: Double) {
            let now = WindowsSelftest.nowMs()
            let open = WinPopupMenu.openMenuBits != 0
            lock.lock(); items.append(Ran(kind: kind, atMs: now, latencyMs: now - posted, whileOpen: open)); lock.unlock()
        }
        func note(_ s: String) { lock.lock(); notes.append(s); lock.unlock() }
        func set(_ key: String, _ value: String) { lock.lock(); flags[key] = value; lock.unlock() }
        func flag(_ key: String) -> String { lock.lock(); defer { lock.unlock() }; return flags[key] ?? "-" }
        var ran: [Ran] { lock.lock(); defer { lock.unlock() }; return items }
        var text: String { lock.lock(); defer { lock.unlock() }; return notes.joined(separator: ",") }
    }

    private final class Finished: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func finish() { lock.lock(); done = true; lock.unlock() }
        var isDone: Bool { lock.lock(); defer { lock.unlock() }; return done }
    }

    private typealias KindSummary = (open: Int, total: Int, maxGapMs: Double, maxLatencyMs: Double)

    private static func summarize(_ kind: String, _ all: [Ran]) -> KindSummary {
        let mine = all.filter { $0.kind == kind }
        let open = mine.filter(\.whileOpen).sorted { $0.atMs < $1.atMs }
        var gap = 0.0
        for i in 1..<max(open.count, 1) { gap = max(gap, open[i].atMs - open[i - 1].atMs) }
        return (open.count, mine.count, gap, open.map(\.latencyMs).max() ?? -1)
    }

    @MainActor static func modalPumpChecks(_ r: Recorder, _ app: WindowsAppDelegate) async {
        guard let host = app.tray else {
            r.add("modalPump.mainWork", false, "the app has no tray host")
            return
        }
        _ = await waitStable(timeout: 60, quiet: 1) { !app.store.isRefreshing }
        let idleBefore = await IdleSampler.measure(seconds: 10, mainThread: WindowsApp.mainThreadID)

        let notifier = Platform.current.notifications as? WindowsNotifications
        let presenter = notifier?.presenter
        let ci = onCI
        let probe = Probe()
        let finished = Finished()
        let owner = Int(bitPattern: app.sink.hwnd)
        let taskbarCreated = RegisterWindowMessageW(WinStr.w("TaskbarCreated"))
        let delivered0 = WinModalPump.delivered
        let sets0 = WinModalPump.timersSet, kills0 = WinModalPump.timersKilled, ticks0 = WinModalPump.ticks
        let adds0 = host.tray.addCount, refreshes0 = app.refreshCount, shown0 = presenter?.shownCount ?? 0

        onThread {
            func post(_ message: Int32, _ key: Int32) {
                _ = PostMessageW(HWND(bitPattern: owner), UINT(message), WPARAM(key), 0)
            }
            var waited = 0
            while WinPopupMenu.openMenuBits == 0, waited < 200 { Thread.sleep(forTimeInterval: 0.05); waited += 1 }
            guard WinPopupMenu.openMenuBits != 0 else { probe.note("menu never opened"); finished.finish(); return }
            for i in 0..<14 {
                let t0 = WindowsSelftest.nowMs()
                DispatchQueue.main.async { probe.record("queue", posted: t0) }
                Task { @MainActor in probe.record("task", posted: t0) }
                switch i {
                case 2:  // Explorer restarted while the menu is open
                    _ = PostMessageW(HWND(bitPattern: owner), taskbarCreated, 0, 0)
                case 4:  // app code inside the menu loop: a second menu, a rebuilt tip, a store refresh, a rebuilt item list
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            let open = WinPopupMenu.openMenuBits != 0
                            probe.set("reentrancyRanWhileOpen", String(open))
                            guard open else { return }  // never open a second real menu from a run after the first closed
                            let bits = WinPopupMenu.openMenuBits
                            host.openMenu(at: POINT(x: 10, y: 10))  // ignored: one menu at a time
                            let again = WinPopupMenu.run(host.menuItems(), at: POINT(x: 10, y: 10), owner: app.sink.hwnd)
                            probe.set("secondMenu", "bits_same=\(WinPopupMenu.openMenuBits == bits) run_returned=\(again.map(String.init) ?? "nil")")
                            host.refresh()
                            Task { await app.store.refresh() }
                        }
                    }
                case 6:  // a balloon queued while the menu is open
                    if ci, let notifier, let presenter {
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                let open = WinPopupMenu.openMenuBits != 0
                                let before = presenter.shownCount
                                notifier.post(id: "modal-pump", title: "PokeTokenBar self-test", body: "balloon queued in a menu", sound: false)
                                probe.set("balloonPostedWhileOpen", String(open))
                                probe.set("balloonShownAtPost", String(presenter.shownCount > before))
                            }
                        }
                    }
                default: break
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            Thread.sleep(forTimeInterval: 0.1)
            post(WM_KEYDOWN, Int32(VK_ESCAPE)); post(WM_KEYUP, Int32(VK_ESCAPE))
            for _ in 0..<40 where WinPopupMenu.openMenuBits != 0 { Thread.sleep(forTimeInterval: 0.2) }
            finished.finish()
        }

        let timer = Timer(fire: Date(timeIntervalSinceNow: 0.2), interval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated { probe.record("timer", posted: WindowsSelftest.nowMs()) }
        }
        let opener = Timer(fire: Date(timeIntervalSinceNow: 0.05), interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { host.openMenu(at: POINT(x: 300, y: 300)) }
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(opener, forMode: .common)
        let done = await waitUntil(timeout: 40) { finished.isDone }
        _ = await waitUntil(timeout: 10) { WinPopupMenu.openMenuBits == 0 }
        _ = await waitUntil(timeout: 5) { probe.ran.filter { $0.kind == "queue" }.count >= 14 && probe.ran.filter { $0.kind == "task" }.count >= 14 }
        timer.invalidate()
        let all = probe.ran

        // (1) the three kinds of main work ran while the menu was open
        let q = summarize("queue", all), t = summarize("task", all), tm = summarize("timer", all)
        func line(_ n: String, _ s: KindSummary) -> String {
            "\(n) ran_while_open=\(s.open)/\(s.total) max_gap_ms=\(Int(s.maxGapMs)) max_latency_ms=\(Int(s.maxLatencyMs))"
        }
        let mainOK = done && q.open >= 10 && t.open >= 10 && tm.open >= 8 && q.maxLatencyMs < 300 && t.maxLatencyMs < 300
            && q.maxGapMs < 300 && tm.maxGapMs < 300
        r.add("modalPump.mainWork", mainOK,
              "menu held ~1.5 s: " + [line("DispatchQueue.main.async", q), line("Task{@MainActor}", t), line("Timer(RunLoop.main)", tm)].joined(separator: "; ")
                + " (pass: >=10/10/8 ran while open, gaps and latencies < 300 ms) helper_finished=\(done) notes=\(probe.text)")

        // (2) app code inside the menu loop
        let created = host.tray.addCount - adds0
        let reentrancyRan = probe.flag("reentrancyRanWhileOpen") == "true"
        let refreshed = app.refreshCount - refreshes0
        r.add("modalPump.reentrancy", reentrancyRan && created >= 1 && host.tray.isPresent
              && probe.flag("secondMenu").contains("bits_same=true run_returned=nil") && !host.menuOpen,
              "ran_while_open=\(reentrancyRan) TaskbarCreated re-adds=\(created) tray_present=\(host.tray.isPresent) "
                + "second showMenu: \(probe.flag("secondMenu")) store_refreshes_during_or_after=\(refreshed) "
                + "ticks=\(WinModalPump.ticks - ticks0) nested_ticks_skipped=\(WinModalPump.reentrantTicksSkipped) menuOpen_after=\(host.menuOpen)")

        // (3) the balloon queued in the menu
        if ci, let presenter {
            let shown = presenter.shownCount - shown0
            r.add("modalPump.balloon", shown >= 1 && probe.flag("balloonPostedWhileOpen") == "true",
                  "queued while open=\(probe.flag("balloonPostedWhileOpen")) shell call made at post (during the menu)=\(probe.flag("balloonShownAtPost")) "
                    + "shown_count \(shown0) -> \(presenter.shownCount)")
            presenter.handle(.hidden)
        } else {
            r.add("modalPump.balloon", true, "skipped (not CI): a balloon would show on this PC")
        }

        // (4) which notifications a tray menu delivers; no timer after the menu closed
        let deliveredNow = WinModalPump.delivered
        func d(_ m: UINT) -> Int { (deliveredNow[m] ?? 0) - (delivered0[m] ?? 0) }
        let setNow = WinModalPump.timersSet - sets0, killedNow = WinModalPump.timersKilled - kills0
        let stillThere = WinModalPump.probeTimerExists()
        r.add("modalPump.notifications", true,
              "delivered to the sink for one tray menu: WM_ENTERMENULOOP=\(d(WinModalPump.enterMenuLoop)) WM_EXITMENULOOP=\(d(WinModalPump.exitMenuLoop)) "
                + "WM_ENTERSIZEMOVE=\(d(WinModalPump.enterSizeMove)) WM_EXITSIZEMOVE=\(d(WinModalPump.exitSizeMove)) (informational)")
        // Size/move notifications are the generic hook for later windows: sent to the sink, they start and stop the pump.
        let setBeforeSynthetic = WinModalPump.timersSet
        _ = SendMessageW(app.sink.hwnd, WinModalPump.enterSizeMove, 0, 0)
        let liveDuring = WinModalPump.timerLive, depthDuring = WinModalPump.depth
        _ = SendMessageW(app.sink.hwnd, WinModalPump.enterSizeMove, 0, 0)  // nested: no second timer
        let nestedSets = WinModalPump.timersSet - setBeforeSynthetic
        _ = SendMessageW(app.sink.hwnd, WinModalPump.exitSizeMove, 0, 0)
        let liveAfterOne = WinModalPump.timerLive
        _ = SendMessageW(app.sink.hwnd, WinModalPump.exitSizeMove, 0, 0)
        let gone = !WinModalPump.timerLive && WinModalPump.depth == 0 && !WinModalPump.probeTimerExists()
        r.add("modalPump.timerLifecycle", done && setNow == 1 && killedNow == 1 && WinModalPump.killFailures == 0 && !stillThere
              && WinModalPump.depth == 0 && !WinModalPump.timerLive
              && liveDuring && depthDuring == 1 && nestedSets == 1 && liveAfterOne && gone,
              "menu: SetTimer \(setNow)x KillTimer ok \(killedNow)x failures=\(WinModalPump.killFailures) exists_after_menu=\(stillThere) depth_after=\(WinModalPump.depth); "
                + "synthetic WM_ENTERSIZEMOVE: timer_live=\(liveDuring) depth=\(depthDuring) nested_total_sets=\(nestedSets) live_after_one_exit=\(liveAfterOne) gone_after_both=\(gone)")

        // (4b) keys while a tick is running must reach the menu
        await keyLossCheck(r, app)

        // (5) exit requested (from main-queue work) while a menu is open
        await menuExitCheck(r, app)

        // (6) idle: nothing wakes the main thread once the menu is closed
        _ = await waitStable(timeout: 30, quiet: 2) { !app.store.isRefreshing }
        let idleAfter = await IdleSampler.measure(seconds: 10, mainThread: WindowsApp.mainThreadID)
        if let idleBefore, let idleAfter {
            r.add("modalPump.idle", idleBefore.mainFound && idleAfter.mainFound && idleAfter.mainContextSwitches <= max(3, idleBefore.mainContextSwitches + 3),
                  "10 s windows, main_thread_cs before the menu=\(idleBefore.mainContextSwitches) -> after=\(idleAfter.mainContextSwitches) "
                    + "cycles \(idleBefore.mainCycles) -> \(idleAfter.mainCycles) (pass: after <= max(3, before + 3))")
        } else {
            r.add("modalPump.idle", false, "measurement failed")
        }
    }

    private final class KeyCounts: @unchecked Sendable {
        private let lock = NSLock()
        private var v = (sent: 0, finished: false)
        func sent(_ n: Int) { lock.lock(); v.sent = n; lock.unlock() }
        func finish() { lock.lock(); v.finished = true; lock.unlock() }
        var snapshot: (sent: Int, finished: Bool) { lock.lock(); defer { lock.unlock() }; return v }
    }

    /// A tick must not take keyboard input away from the menu loop. A tick that finds nothing to run used to poll the
    /// thread queue (CoreFoundation's own message pump) and a key that arrived in that instant was dispatched to the
    /// sink instead of the menu. The window is tens of microseconds per 50 ms, so a flood of Down keys at random
    /// sub-millisecond spacing (6000 over ~3 s) crosses it many times; every key that reaches the sink as a plain
    /// WM_KEYDOWN was taken from the menu (a key inside the menu loop is translated there and never dispatched).
    @MainActor private static func keyLossCheck(_ r: Recorder, _ app: WindowsAppDelegate) async {
        let total = 6000
        let counts = KeyCounts()
        let owner = Int(bitPattern: app.sink.hwnd)
        let items = (1...5).map { TrayMenuModel.Item(title: "Item \($0)", enabled: true, checked: false, action: .none) }
        var atSink = 0
        let ticks0 = WinModalPump.ticks
        let token = app.sink.on(UINT(WM_KEYDOWN)) { _, _ in atSink += 1; return nil }
        onThread {
            var waited = 0
            while WinPopupMenu.openMenuBits == 0, waited < 200 { Thread.sleep(forTimeInterval: 0.05); waited += 1 }
            guard WinPopupMenu.openMenuBits != 0 else { counts.finish(); return }
            Thread.sleep(forTimeInterval: 0.4)
            var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
            for i in 0..<total {
                _ = PostMessageW(HWND(bitPattern: owner), UINT(WM_KEYDOWN), WPARAM(VK_DOWN), 0)
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let gapMs = 0.2 + Double(seed >> 40 & 0x3FF) / 1024 * 0.6  // 0.2 ... 0.8 ms, spun (Sleep is ~15 ms)
                let t0 = WindowsSelftest.nowMs()
                while WindowsSelftest.nowMs() - t0 < gapMs {}
                if i % 500 == 499 { Thread.sleep(forTimeInterval: 0.02) }  // let the menu drain its queue now and then
                counts.sent(i + 1)
            }
            Thread.sleep(forTimeInterval: 0.3)
            _ = PostMessageW(HWND(bitPattern: owner), UINT(WM_KEYDOWN), WPARAM(VK_ESCAPE), 0)
            _ = PostMessageW(HWND(bitPattern: owner), UINT(WM_KEYUP), WPARAM(VK_ESCAPE), 0)
            for _ in 0..<40 where WinPopupMenu.openMenuBits != 0 { Thread.sleep(forTimeInterval: 0.2) }
            counts.finish()
        }
        let opener = Timer(fire: Date(timeIntervalSinceNow: 0.05), interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { _ = WinPopupMenu.run(items, at: POINT(x: 300, y: 300), owner: app.sink.hwnd) }
        }
        RunLoop.main.add(opener, forMode: .common)
        _ = await waitUntil(timeout: 60) { counts.snapshot.finished }
        _ = await waitUntil(timeout: 10) { WinPopupMenu.openMenuBits == 0 }
        app.sink.off(token)
        let v = counts.snapshot
        r.add("modalPump.keysReachMenu", v.finished && v.sent == total && atSink == 0,
              "\(v.sent) of \(total) Down keys posted at 0.2-0.8 ms spacing to an open menu while the pump ticked (\(WinModalPump.ticks - ticks0) ticks): "
                + "taken from the menu and dispatched to the sink as plain WM_KEYDOWN=\(atSink); mask_strategy=\(WinModalPump.maskStrategy)")
    }

    /// A child process holds a menu open, schedules `WindowsApp.exit` on the main queue, and only then gets Escape.
    /// With the pump the exit runs inside the menu loop (exit 0, setting saved). Without it the menu returns first (exit 5).
    @MainActor private static func menuExitCheck(_ r: Recorder, _ app: WindowsAppDelegate) async {
        let plist = WinDefaultsSync.plistURL(suite: WinDefaultsSync.selftestSuiteName)
        let key = "ptb.selftest.menuexit.\(String(UUID().uuidString.prefix(8)))"
        do {
            let child = try Helper.start(["--selftest-menu-exit", key], ready: true)
            let ready = await child.waitReady(timeout: 20)
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            var escape = "-"
            if child.exitCode == nil,
               let window = FindWindowW(WinStr.w(WinSinkWindow.className), WinStr.w("ptb-selftest-helper-\(child.pid)")) {
                _ = PostMessageW(window, UINT(WM_KEYDOWN), WPARAM(VK_ESCAPE), 0)
                _ = PostMessageW(window, UINT(WM_KEYUP), WPARAM(VK_ESCAPE), 0)
                escape = "sent"
            }
            let code = await child.waitExit(timeout: 15)
            if code == nil { child.kill() }
            child.close()
            let saved = plistValue(plist, key) == "v1"
            r.add("modalPump.exitInMenu", ready && code == 0 && saved,
                  "child holds a menu, WindowsApp.exit scheduled on the main queue 0.5 s after it opened, Escape only at 4 s: exit=\(describe(code)) "
                    + "(0 = the exit ran inside the menu; 5 = the menu returned first) setting_on_disk=\(saved) ready=\(ready) escape=\(escape)")
            app.defaults.removeObject(forKey: key)
            WinDefaultsSync.flushNow()
        } catch {
            r.add("modalPump.exitInMenu", false, "\(error)")
        }
    }

    /// `--selftest-menu-exit <key>`: the helper of `modalPump.exitInMenu`.
    @MainActor static func runMenuExit(_ args: [String]) -> Never {
        guard let key = args.first else { WindowsApp.exit(2, .helper) }
        _ = WinMainLoop.prepare()
        guard let window = try? WinSinkWindow(title: "ptb-selftest-helper-\(GetCurrentProcessId())") else { WindowsApp.exit(2, .helper) }
        WindowsAppDelegate.installExitHandlers(on: window)
        WinModalPump.install(on: window)
        WinDefaultsSync.makeAppDefaults().set("v1", forKey: key)
        signalReady()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated { () -> Void in WindowsApp.exit(0, .helper) }
        }
        let items = [TrayMenuModel.Item(title: "Self-test", enabled: true, checked: false, action: .none)]
        _ = WinPopupMenu.run(items, at: POINT(x: 300, y: 300), owner: window.hwnd)
        WindowsApp.exit(5, .helper)  // the menu returned before the exit ran
    }
}
#endif
