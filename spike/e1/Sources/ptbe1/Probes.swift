// Throwaway (Track B experiment E1). Each probe prints greppable lines: `E1.Pn[strategy] PASS|FAIL|VALUE ...`.
import CE1Shim
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Observation

func say(_ s: String) { e1_log(s) }
var onMain: Bool { e1_tid() == e1_ctor_tid() }
func f2(_ d: Double) -> String { String(format: "%.2f", d) }

let kWM_APP: UInt32 = 0x8000
let kWM_TIMER: UInt32 = 0x0113
let kWM_ENTERMENULOOP: UInt32 = 0x0211
let kWM_EXITMENULOOP: UInt32 = 0x0212

struct Sample: Sendable {
    let tid: UInt32
    let value: Double
}

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: [Sample]] = [:]
    func add(_ key: String, _ value: Double) {
        let s = Sample(tid: e1_tid(), value: value)
        lock.lock()
        items[key, default: []].append(s)
        lock.unlock()
    }
    func get(_ key: String) -> [Sample] {
        lock.lock()
        defer { lock.unlock() }
        return items[key] ?? []
    }
}

enum G {
    static let rec = Recorder()
    nonisolated(unsafe) static var hwnd: UnsafeMutableRawPointer? = nil
    nonisolated(unsafe) static var t0: Double = 0
    nonisolated(unsafe) static var menuEnter: Double = -1
    nonisolated(unsafe) static var menuExit: Double = -1
    nonisolated(unsafe) static var drainMode = ""
    nonisolated(unsafe) static var keysMs: Int32 = 0
    nonisolated(unsafe) static var drainCalls = 0
    /// cur / dhc: never touch RunLoop.main (whose first use turns on CF's Win32 message mask); use RunLoop.current.
    nonisolated(unsafe) static var useCurrent = false
}

func rl() -> RunLoop { G.useCurrent ? RunLoop.current : RunLoop.main }

@MainActor enum MainState {
    static var counter = 0
}

@Observable final class Model: @unchecked Sendable {
    var value = 0
}

// MARK: - Strategies

/// cf = CF run loop + message mask (CF's one-message pump); cfh = + drain-all pump handler; cf0 = control, no mask;
/// dh = own MsgWait loop on the dispatch main-queue handle; poll = GetMessageW + 250 ms SetTimer.
/// cur = control: RunLoop.current on the main thread, RunLoop.main never touched; dhc = dh with RunLoop.current.
func setup(_ s: String) -> String {
    var notes: [String] = []
    G.useCurrent = s == "cur" || s == "dhc"
    switch s {
    case "cf":
        notes.append("set_mask=\(e1_cf_set_mask(e1_qs_allinput()))")
    case "cfh":
        notes.append("set_mask=\(e1_cf_set_mask(e1_qs_allinput()))")
        notes.append("set_handler=\(e1_cf_install_drain_handler())")
    default:
        break
    }
    notes.append("wake_observer=\(e1_cf_count_wakeups())")
    return notes.joined(separator: " ")
}

func timersPass() -> Double {
    guard let d = rl().limitDate(forMode: .default) else { return -1 }
    return d.timeIntervalSinceNow * 1000
}

func pollPass() {
    _ = rl().run(mode: .default, before: Date())
}

func runLoop(_ s: String) {
    switch s {
    case "dh", "dhc":
        if e1_run_dispatch_loop(timersPass) < 0 { say("E1 dh loop: dispatch handle missing") }
    case "poll":
        _ = e1_run_polling_loop(pollPass, 250)
    default:
        while e1_is_done() == 0 {
            _ = rl().run(mode: .default, before: .distantFuture)
        }
    }
}

func onMessage(_ msg: UInt32, _ w: UInt, _ l: Int) {
    switch msg {
    case kWM_APP + 2:
        p3Assume(w == 1 ? "direct" : "pump")
    case kWM_APP + 3:
        startMenu()
    case kWM_TIMER where w == 3:
        G.drainCalls += 1
        MainActor.assumeIsolated { MainState.counter += 1 }  // inside a Win32 modal loop: still the main actor
        if G.drainMode == "rl" {
            _ = RunLoop.main.run(mode: .default, before: Date())
        } else if G.drainMode == "dq" {
            _ = e1_dispatch_drain()
        }
    case kWM_ENTERMENULOOP:
        G.menuEnter = e1_now_ms()
    case kWM_EXITMENULOOP:
        G.menuExit = e1_now_ms()
    default:
        break
    }
}

// MARK: - P1

func runSymbols() {
    _ = RunLoop.main
    DispatchQueue.main.async {}
    say("E1.P1 VALUE ctor_tid=\(e1_ctor_tid()) toplevel_tid=\(e1_tid()) exe=\(String(cString: e1_self_path()))")
    e1_list_modules("E1.P1 MODULE", "swift")
    e1_list_modules("E1.P1 MODULE", "dispatch")
    let names = [
        "_CFRunLoopSetWindowsMessageQueueMask", "_CFRunLoopGetWindowsMessageQueueMask",
        "_CFRunLoopSetWindowsMessageQueueHandler", "_CFRunLoopGetWindowsMessageQueueHandler",
        "CFRunLoopGetMain", "CFRunLoopGetCurrent", "CFRunLoopWakeUp", "CFRunLoopObserverCreate",
        "CFRunLoopAddObserver", "kCFRunLoopDefaultMode", "kCFRunLoopCommonModes",
        "_dispatch_get_main_queue_port_4CF", "_dispatch_main_queue_callback_4CF", "dispatch_main",
        "swift_task_enqueueMainExecutor", "swift_task_asyncMainDrainQueue",
    ]
    for n in names {
        if let m = e1_symbol_module(n) {
            say("E1.P1 PASS symbol \(n) module=\(String(cString: m))")
        } else {
            say("E1.P1 FAIL symbol \(n) MISSING")
        }
    }
}

// MARK: - P2 / P5

func runP2(_ s: String) {
    let notes = setup(s)
    e1_set_msg_callback(onMessage)
    G.hwnd = e1_make_window(0)
    say("E1.P2[\(s)] VALUE \(notes) ctor_tid=\(e1_ctor_tid()) toplevel_tid=\(e1_tid()) toplevel_on_main=\(onMain) "
        + "cf_mask=0x\(String(e1_cf_get_mask(), radix: 16)) hwnd=\(G.hwnd != nil)")
    G.t0 = e1_now_ms()
    let rec = G.rec
    // (a) Task { @MainActor } created on the main thread before the loop runs.
    Task { @MainActor in rec.add("a", e1_now_ms() - G.t0) }
    // (b) Task.detached hopping to the main actor.
    Task.detached { await MainActor.run { rec.add("b", e1_now_ms() - G.t0) } }
    // (c) DispatchQueue.main.async from a background Thread, 20 times.
    Thread {
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.1)
            let t = e1_now_ms()
            DispatchQueue.main.async { rec.add("c", e1_now_ms() - t) }
        }
    }.start()
    // (h) Task { @MainActor } created on a background Thread, 20 times.
    Thread {
        Thread.sleep(forTimeInterval: 0.05)
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.1)
            let t = e1_now_ms()
            Task { @MainActor in rec.add("h", e1_now_ms() - t) }
        }
    }.start()
    // (d) A 200 ms repeating Timer on RunLoop.main in .common.
    let timer = Timer(timeInterval: 0.2, repeats: true) { _ in rec.add("d", e1_now_ms()) }
    rl().add(timer, forMode: .common)
    // (k) WM_CHAR 'A' and U+D55C posted with PostMessageW; (l) a WH_GETMESSAGE hook on the main thread.
    let hook = e1_install_getmsg_hook()
    Thread {
        Thread.sleep(forTimeInterval: 2.5)
        _ = e1_post(G.hwnd, 0x0102, 0x41, 0)
        _ = e1_post(G.hwnd, 0x0102, 0xD55C, 0)
        for _ in 0..<3 { _ = e1_post(G.hwnd, kWM_APP + 5, 0, 0) }  // (l) the hook should eat these
    }.start()
    // (m) cross-thread SendMessageTimeoutW, 5 times from 0.2 s.
    e1_start_sender(G.hwnd)
    // (e) PostMessageW from a background thread, 20 times, 100 ms apart (latency measured in the C WndProc).
    e1_start_poster(G.hwnd, 20, 100, 300)
    // (f) withObservationTracking onChange -> Task { @MainActor }; (j) asyncAfter lateness.
    let model = Model()
    withObservationTracking {
        _ = model.value
    } onChange: {
        rec.add("f-onchange", 0)
        Task { @MainActor in rec.add("f", e1_now_ms() - G.t0) }
    }
    let tj = e1_now_ms()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        rec.add("j", e1_now_ms() - tj - 500)
        model.value += 1
    }
    // (g) Task.sleep(1 s) on the main actor.
    Task { @MainActor in
        let t = e1_now_ms()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        rec.add("g", e1_now_ms() - t - 1000)
    }
    Thread {
        Thread.sleep(forTimeInterval: 4.0)
        DispatchQueue.main.async { e1_set_done() }
    }.start()
    Thread {
        Thread.sleep(forTimeInterval: 20)
        say("E1.P2[\(s)] WATCHDOG the loop did not finish in 20 s")
        reportP2(s)
        exit(3)
    }.start()
    let loopStart = e1_now_ms()
    runLoop(s)
    timer.invalidate()
    say("E1.P2[\(s)] VALUE loop_ms=\(f2(e1_now_ms() - loopStart)) wakeups=\(e1_wakeups()) pump_calls=\(e1_pump_calls()) "
        + "pumped_by_our_W_pump=\(e1_pumped()) (posted 20 + 2 WM_CHAR)")
    reportP2(s)
    var chars = [UInt32](repeating: 0, count: 8)
    let n = e1_chars(&chars, 8)
    let got = chars.prefix(Int(n)).map { "0x" + String($0, radix: 16) }
    let kPass = n == 2 && chars[0] == 0x41 && chars[1] == 0xD55C
    say("E1.P2[\(s)] (k) \(kPass ? "PASS" : "FAIL") WM_CHAR-unicode-through-the-pump sent=[0x41,0xd55c] got=\(got) "
        + "IsWindowUnicode=\(e1_is_window_unicode(G.hwnd)) ACP=\(e1_acp())")
    var hp: Int32 = 0, hc: Int32 = 0
    var lc: UInt32 = 0
    e1_hook_stats(&hp, &hc, &lc)
    let eaten = e1_hook_eaten(), app5 = e1_app5_seen()
    say("E1.P2[\(s)] (l) \(hook == 0 && hp == 20 && eaten == 3 && app5 == 0 ? "PASS" : "FAIL") WH_GETMESSAGE-hook-sees-and-can-eat "
        + "install=\(hook) posted_seen=\(hp)/20 remove_flags=\(e1_hook_flags_seen()) chars_seen=\(hc) last_char=0x\(String(lc, radix: 16)) "
        + "eaten=\(eaten)/3 reached_wndproc=\(app5)")
    var smx = 0.0
    var sok: Int32 = 0, sonm: Int32 = 0
    let sn = e1_sender_stats(&smx, &sok, &sonm)
    say("E1.P2[\(s)] (m) \(sn == 5 && sok == 5 && sonm == 5 && smx < 50 ? "PASS" : "FAIL") cross-thread-SendMessageTimeoutW "
        + "n=\(sn)/5 returned_ok=\(sok) wndproc_on_main=\(sonm) max_ms=\(f2(smx))")
}

func line(_ id: String, _ name: String, _ xs: [Sample], expect: Int, maxLat: Double? = nil, extra: String = "") -> String {
    let mainN = xs.filter { $0.tid == e1_ctor_tid() }.count
    let v = xs.map(\.value).sorted()
    let med = v.isEmpty ? -1 : v[v.count / 2]
    let mx = v.last ?? -1
    var pass = xs.count >= expect && mainN == xs.count && expect > 0
    if let m = maxLat { pass = pass && mx < m }
    return "\(id) \(pass ? "PASS" : "FAIL") \(name) n=\(xs.count)/\(expect) on_main=\(mainN) median_ms=\(f2(med)) max_ms=\(f2(mx))\(extra)"
}

func reportP2(_ s: String) {
    let p = "E1.P2[\(s)]"
    let r = G.rec
    say(line("\(p) (a)", "Task-MainActor-from-main(ms-after-setup)", r.get("a"), expect: 1))
    say(line("\(p) (b)", "detached-then-MainActor.run(ms-after-setup)", r.get("b"), expect: 1))
    say(line("\(p) (c)", "DispatchQueue.main.async-from-thread", r.get("c"), expect: 20, maxLat: 50))
    let d = r.get("d")
    let times = d.map(\.value)
    let intervals = zip(times.dropFirst(), times).map { $0 - $1 }.sorted()
    let dMain = d.filter { $0.tid == e1_ctor_tid() }.count
    let dPass = d.count >= 15 && dMain == d.count
    say("\(p) (d) \(dPass ? "PASS" : "FAIL") Timer-200ms-common n=\(d.count)/~19 on_main=\(dMain) "
        + "interval_median_ms=\(f2(intervals.isEmpty ? -1 : intervals[intervals.count / 2])) interval_max_ms=\(f2(intervals.last ?? -1))")
    var med = 0.0, mx = 0.0
    var onm: Int32 = 0
    let delivered = e1_poster_stats(&med, &mx, &onm)
    let ePass = delivered == 20 && onm == 20 && mx < 50
    say("\(p) (e) \(ePass ? "PASS" : "FAIL") PostMessageW-from-thread n=\(delivered)/20 on_main=\(onm) median_ms=\(f2(med)) max_ms=\(f2(mx))")
    let fo = r.get("f-onchange")
    say(line("\(p) (f)", "observation-onChange-then-Task(ms-after-setup)", r.get("f"), expect: 1,
             extra: " onChange_n=\(fo.count) onChange_on_main=\(fo.filter { $0.tid == e1_ctor_tid() }.count)"))
    say(line("\(p) (g)", "Task.sleep-1s-on-MainActor(lateness)", r.get("g"), expect: 1, maxLat: 100))
    say(line("\(p) (h)", "Task-MainActor-from-thread", r.get("h"), expect: 20, maxLat: 50))
    say(line("\(p) (j)", "asyncAfter-0.5s(lateness)", r.get("j"), expect: 1, maxLat: 100))
}

// MARK: - P3

func p3Assume(_ variant: String) {
    say("E1.P3 \(variant) VALUE before-assume tid=\(e1_tid()) on_main=\(onMain)")
    MainActor.assumeIsolated { MainState.counter += 1 }
    say("E1.P3 \(variant) VALUE after-assume (no trap)")
}

func runP3(_ v: String) {
    let notes = setup("cfh")
    e1_set_msg_callback(onMessage)
    G.hwnd = e1_make_window(0)
    say("E1.P3 \(v) VALUE \(notes)")
    switch v {
    case "toplevel": p3Assume("toplevel")  // synchronous main, before the loop runs
    case "direct": _ = e1_send(G.hwnd, kWM_APP + 2, 1, 0)  // SendMessageW on the main thread, outside the loop
    case "pump": _ = e1_post(G.hwnd, kWM_APP + 2, 0, 0)  // WndProc called by CF's message pump
    case "timer": RunLoop.main.add(Timer(timeInterval: 0.1, repeats: false) { _ in p3Assume("timer") }, forMode: .common)
    case "dispatch": DispatchQueue.main.async { p3Assume("dispatch") }
    case "task": Task { @MainActor in p3Assume("task") }
    case "bg": Thread { p3Assume("bg") }.start()  // fault injection: off the main thread this must trap
    default:
        say("E1.P3 unknown variant \(v)")
        exit(2)
    }
    Thread {
        Thread.sleep(forTimeInterval: 1.5)
        DispatchQueue.main.async { e1_set_done() }
    }.start()
    Thread {
        Thread.sleep(forTimeInterval: 15)
        say("E1.P3 \(v) WATCHDOG")
        exit(4)
    }.start()
    runLoop("cfh")
    say("E1.P3 \(v) VALUE loop-finished")
}

// MARK: - P4

func runIdle(_ s: String, _ secs: Double) {
    if s == "baseline" {
        _ = RunLoop.main
        Task.detached {}
        DispatchQueue.global().async {}
        Thread.sleep(forTimeInterval: 2)
        measureIdle(s, secs)
        return
    }
    let notes = setup(s)
    e1_set_msg_callback(onMessage)
    G.hwnd = e1_make_window(0)
    // Timer(fire:) because corelibs' Timer(timeInterval:repeats:block:) fires at once (see the timers probe).
    let t = Timer(fire: Date(timeIntervalSinceNow: 120), interval: 120, repeats: true) { _ in say("E1.P4[\(s)] VALUE the 120 s timer fired") }
    rl().add(t, forMode: .common)
    Task { @MainActor in }
    Task.detached {}
    say("E1.P4[\(s)] VALUE \(notes)")
    Thread {
        Thread.sleep(forTimeInterval: 2)
        measureIdle(s, secs)
        DispatchQueue.main.async { e1_set_done() }
    }.start()
    runLoop(s)
    t.invalidate()
}

func measureIdle(_ s: String, _ secs: Double) {
    let threadsBefore = e1_thread_count()
    e1_threads_mark()
    var a = e1_cpu()
    e1_cpu_now(&a)
    let w0 = e1_wakeups()
    Thread.sleep(forTimeInterval: secs)
    var b = e1_cpu()
    e1_cpu_now(&b)
    let w1 = e1_wakeups()
    let threadsAfter = e1_thread_count()
    let user = b.user_ms - a.user_ms, kernel = b.kernel_ms - a.kernel_ms
    let cpu = user + kernel
    let pass = cpu < 50 * secs / 30
    say("E1.P4[\(s)] \(pass ? "PASS" : "FAIL") idle_secs=\(Int(secs)) cpu_ms=\(f2(cpu)) user_ms=\(f2(user)) kernel_ms=\(f2(kernel)) "
        + "cycles=\(b.cycles &- a.cycles) main_thread_cycles=\(b.main_cycles &- a.main_cycles) loop_wakeups=\(w1 - w0) threads=\(threadsBefore)->\(threadsAfter)")
    e1_threads_report("E1.P4[\(s)] THREAD")
    guard s != "baseline" else { return }
    // Wake latency right after the idle stretch: 3 posted messages and 3 main-queue blocks, interleaved.
    let rec = G.rec
    e1_start_poster(G.hwnd, 3, 700, 0)
    for _ in 0..<3 {
        Thread.sleep(forTimeInterval: 0.35)
        let t = e1_now_ms()
        DispatchQueue.main.async { rec.add("idle-dq", e1_now_ms() - t) }
        Thread.sleep(forTimeInterval: 0.35)
    }
    Thread.sleep(forTimeInterval: 0.5)
    var med = 0.0, mx = 0.0
    var onm: Int32 = 0
    let delivered = e1_poster_stats(&med, &mx, &onm)
    say("E1.P4[\(s)] VALUE wake-after-idle PostMessageW n=\(delivered)/3 on_main=\(onm) median_ms=\(f2(med)) max_ms=\(f2(mx))")
    say(line("E1.P4[\(s)]", "wake-after-idle DispatchQueue.main.async", rec.get("idle-dq"), expect: 3, maxLat: 50))
}

// MARK: - P7

func runModal(_ variant: String) {
    G.drainMode = variant.hasSuffix("keys") ? String(variant.dropLast(4)) : variant
    G.keysMs = variant.hasSuffix("keys") ? 300 : 0
    let notes = setup("cfh")
    e1_set_msg_callback(onMessage)
    G.hwnd = e1_make_window(0)
    let rec = G.rec
    let t = Timer(timeInterval: 0.2, repeats: true) { _ in rec.add("m-timer", e1_now_ms()) }
    RunLoop.main.add(t, forMode: .common)
    _ = e1_post(G.hwnd, kWM_APP + 3, 0, 0)
    say("E1.P7[\(variant)] VALUE \(notes)")
    Thread {
        Thread.sleep(forTimeInterval: 20)
        say("E1.P7[\(variant)] WATCHDOG")
        exit(4)
    }.start()
    runLoop("cfh")
    t.invalidate()
}

/// Called from the WndProc (inside CF's message pump), like a tray icon's right-click would be.
func startMenu() {
    let rec = G.rec
    Task { @MainActor in rec.add("m-task", e1_now_ms()) }
    DispatchQueue.main.async { rec.add("m-dq", e1_now_ms()) }
    Thread {
        Thread.sleep(forTimeInterval: 0.3)
        DispatchQueue.main.async { rec.add("m-dq-bg", e1_now_ms()) }
        Task { @MainActor in rec.add("m-task-bg", e1_now_ms()) }
    }.start()
    var tc = 0.0, tr = 0.0
    var err: CUnsignedLong = 0
    let drainMs: Int32 = G.drainMode == "plain" ? 0 : 16
    let r = e1_track_menu(G.hwnd, 1000, drainMs, G.keysMs, &tc, &tr, &err)
    let v = G.drainMode + (G.keysMs > 0 ? "keys" : "")
    let callT = tc, retT = tr
    if G.keysMs > 0 {
        say("E1.P7[\(v)] \(r == 1 ? "PASS" : "FAIL") menu-receives-keys-posted-at-300ms TrackPopupMenuEx=\(r) (1 = item chosen by VK_DOWN+VK_RETURN)")
    }
    say("E1.P7[\(v)] VALUE TrackPopupMenuEx=\(r) err=\(err) menu_ms=\(f2(retT - callT)) entered_menu_loop=\(G.menuEnter >= 0) "
        + "drain_timer_calls=\(G.drainCalls)")
    Thread {
        Thread.sleep(forTimeInterval: 1.2)
        DispatchQueue.main.async {
            for key in ["m-timer", "m-task", "m-dq", "m-task-bg", "m-dq-bg"] {
                let xs = rec.get(key)
                let during = xs.filter { $0.value > callT && $0.value < retT }.count
                let after = xs.filter { $0.value >= retT }
                let firstAfter = after.map { $0.value - retT }.min() ?? -1
                let onm = xs.filter { $0.tid == e1_ctor_tid() }.count
                say("E1.P7[\(v)] VALUE \(key) total=\(xs.count) during_menu=\(during) after_menu=\(after.count) "
                    + "first_after_ms=\(f2(firstAfter)) on_main=\(onm)")
            }
            e1_set_done()
        }
    }.start()
}

// MARK: - P8

func runTray() {
    G.hwnd = e1_make_window(0)
    e1_tray_probe(G.hwnd)
}

// MARK: - P9

func findPlists() -> [String] {
    let fm = FileManager.default
    let env = ProcessInfo.processInfo.environment
    var out: [String] = []
    for k in ["LOCALAPPDATA", "APPDATA", "USERPROFILE"] {
        guard let root = env[k] else { continue }
        for n in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            let p1 = root + "\\" + n
            if n.lowercased().contains("ptbe1") { out.append(p1) }
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: p1, isDirectory: &isDir), isDir.boolValue {
                for n2 in (try? fm.contentsOfDirectory(atPath: p1)) ?? [] where n2.lowercased().contains("ptbe1") {
                    out.append(p1 + "\\" + n2)
                }
            }
        }
    }
    return Array(Set(out)).sorted()
}

func runFacts() {
    let fm = FileManager.default
    let lib = fm.urls(for: .libraryDirectory, in: .userDomainMask)
    say("E1.P9 VALUE urls(.libraryDirectory,.userDomainMask).count=\(lib.count) \(lib.map(\.path))")
    let dirs: [(String, FileManager.SearchPathDirectory)] = [
        ("applicationSupportDirectory", .applicationSupportDirectory), ("cachesDirectory", .cachesDirectory),
        ("documentDirectory", .documentDirectory), ("desktopDirectory", .desktopDirectory),
        ("downloadsDirectory", .downloadsDirectory),
    ]
    for (name, d) in dirs {
        say("E1.P9 VALUE \(name) \(fm.urls(for: d, in: .userDomainMask).map(\.path))")
    }
    say("E1.P9 VALUE NSHomeDirectory=\(NSHomeDirectory()) homeDirectoryForCurrentUser=\(fm.homeDirectoryForCurrentUser.path) "
        + "temporaryDirectory=\(fm.temporaryDirectory.path)")
    let b = Bundle.main
    say("E1.P9 VALUE Bundle.main bundleIdentifier=\(b.bundleIdentifier ?? "nil") bundlePath=\(b.bundlePath) "
        + "bundleURL=\(b.bundleURL.path) executablePath=\(b.executablePath ?? "nil") resourcePath=\(b.resourcePath ?? "nil") "
        + "infoDictionary_keys=\(b.infoDictionary?.keys.sorted() ?? [])")
    say("E1.P9 VALUE processName=\(ProcessInfo.processInfo.processName) argv0=\(CommandLine.arguments[0]) NSUserName=\(NSUserName()) "
        + "self=\(String(cString: e1_self_path()))")
    let env = ProcessInfo.processInfo.environment
    say("E1.P9 VALUE env LOCALAPPDATA=\(env["LOCALAPPDATA"] ?? "nil") APPDATA=\(env["APPDATA"] ?? "nil") "
        + "USERPROFILE=\(env["USERPROFILE"] ?? "nil") USERNAME=\(env["USERNAME"] ?? "nil")")

    let d = UserDefaults.standard
    say("E1.P9 VALUE plists before any write: \(findPlists())")
    d.set("facts-\(Int(Date().timeIntervalSince1970))", forKey: "e1.facts")
    say("E1.P9 VALUE plists after set, before synchronize: \(findPlists())")
    let syncOK = d.synchronize()
    let found = findPlists()
    say("E1.P9 VALUE synchronize=\(syncOK) plists after synchronize: \(found)")
    guard let path = found.first(where: { $0.hasSuffix(".plist") }) else {
        say("E1.P9 FAIL no plist found after synchronize")
        return
    }
    func mtime() -> Double {
        ((try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
    }
    let m0 = mtime()
    Thread.sleep(forTimeInterval: 1.5)
    let s1 = d.synchronize()
    let m1 = mtime()
    let current = d.string(forKey: "e1.facts")
    d.set(current, forKey: "e1.facts")
    let s2 = d.synchronize()
    let m2 = mtime()
    Thread.sleep(forTimeInterval: 1.5)
    d.set("changed-\(Int(e1_now_ms()))", forKey: "e1.facts")
    let s3 = d.synchronize()
    let m3 = mtime()
    say("E1.P9 \(m1 == m0 ? "PASS" : "FAIL") no-change-synchronize-keeps-mtime path=\(path) m0=\(m0) "
        + "nochange_sync(\(s1))=\(m1) same_value_set_sync(\(s2))=\(m2) real_change_sync(\(s3))=\(m3) control_changed=\(m3 != m0)")
    if let data = fm.contents(atPath: path) {
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: " ")
        say("E1.P9 VALUE plist bytes=\(data.count) head=\(text.prefix(400))")
    }
}

func runPChild(_ key: String, _ mode: String) {
    let d = UserDefaults.standard
    let value = "\(mode)-\(Int(e1_now_ms()))"
    d.set(value, forKey: key)
    if mode.hasPrefix("sync") { _ = d.synchronize() }
    say("E1.P9 VALUE child key=\(key) mode=\(mode) set=\(value)")
    switch mode {
    case "nosync-kill", "sync-kill":
        Thread.sleep(forTimeInterval: 3)
        e1_kill_self(9)
    case "nosync-exit":
        exit(0)
    case "nosync-runloop-kill":
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(5))
        e1_kill_self(9)
    default:
        say("E1.P9 unknown child mode \(mode)")
    }
}

func runPRead(_ specs: [String]) {
    guard let path = findPlists().first(where: { $0.hasSuffix(".plist") }) else {
        say("E1.P9 FAIL pread: no plist")
        return
    }
    let data = FileManager.default.contents(atPath: path)
    let plist = data.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) }
    let dict = plist as? [String: Any]
    for spec in specs {
        let parts = spec.split(separator: "=").map(String.init)
        let key = parts[0], expect = parts.count > 1 ? parts[1] : "info"
        let present = dict?[key] != nil
        let verdict = expect == "info" ? "VALUE" : ((expect == "present") == present ? "PASS" : "FAIL")
        say("E1.P9 \(verdict) read-plist-file key=\(key) expect=\(expect) present=\(present) value=\(dict?[key].map { "\($0)" } ?? "nil")")
    }
}

// MARK: - P10

func runProcess() {
    let fm = FileManager.default
    let exe = String(cString: e1_self_path())
    let stamp = Int(e1_now_ms())
    let spaced = fm.temporaryDirectory.appendingPathComponent("e1 dir \(stamp)", isDirectory: true)
    let plain = fm.temporaryDirectory.appendingPathComponent("e1plain\(stamp)", isDirectory: true)
    try? fm.createDirectory(at: spaced, withIntermediateDirectories: true)
    try? fm.createDirectory(at: plain, withIntermediateDirectories: true)
    let body = "@\"\(exe)\" argv %*\r\n"
    let shimSpaced = spaced.appendingPathComponent("argv shim.cmd")
    let shimPlain = plain.appendingPathComponent("argvshim.cmd")
    try? body.write(to: shimSpaced, atomically: true, encoding: .utf8)
    try? body.write(to: shimPlain, atomically: true, encoding: .utf8)
    let txt = plain.appendingPathComponent("note.txt")
    try? "x".write(to: txt, atomically: true, encoding: .utf8)
    say("E1.P10 VALUE isExecutableFile self.exe=\(fm.isExecutableFile(atPath: exe)) "
        + "cmd.exe=\(fm.isExecutableFile(atPath: "C:\\Windows\\System32\\cmd.exe")) shim.cmd=\(fm.isExecutableFile(atPath: shimPlain.path)) "
        + "note.txt=\(fm.isExecutableFile(atPath: txt.path)) missing.exe=\(fm.isExecutableFile(atPath: plain.appendingPathComponent("nope.exe").path))")
    let args = ["a b", "\"q\"", "x&y"]
    let cases: [(String, URL, [String])] = [
        ("exe-direct", URL(fileURLWithPath: exe), ["argv"] + args),
        ("cmd-shim-plain-path", shimPlain, args),
        ("cmd-shim-path-with-spaces", shimSpaced, args),
        ("cmd-shim-plain-args", shimPlain, ["a", "b-c", "--flag=1"]),
    ]
    for (label, url, argv) in cases {
        let want = label == "exe-direct" ? args : argv
        let p = Process()
        p.executableURL = url
        p.arguments = argv
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let out = String(decoding: data, as: UTF8.self)
            let got = out.split(whereSeparator: \.isNewline).compactMap { l -> String? in
                l.hasPrefix("ARGV ") ? String(l.dropFirst(5)) : nil
            }
            let raw = out.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: " | ")
            say("E1.P10 \(got == want ? "PASS" : "FAIL") \(label) status=\(p.terminationStatus) got=\(got) want=\(want) raw=\(raw)")
        } catch {
            say("E1.P10 FAIL \(label) run threw \(error)")
        }
    }
}

// MARK: - P11

func runNet() {
    var req = URLRequest(url: URL(string: "https://api.github.com/repos/likelion-campus/PokeTokenBar/releases/latest")!)
    req.setValue("ptb-e1-spike", forHTTPHeaderField: "User-Agent")
    req.timeoutInterval = 20
    let sem = DispatchSemaphore(value: 0)
    let t0 = e1_now_ms()
    URLSession.shared.dataTask(with: req) { data, resp, err in
        let ms = e1_now_ms() - t0
        if let h = resp as? HTTPURLResponse {
            say("E1.P11 PASS https-get status=\(h.statusCode) bytes=\(data?.count ?? 0) ms=\(f2(ms)) callback_on_main=\(onMain)")
        } else {
            say("E1.P11 FAIL https-get error=\(String(describing: err)) ms=\(f2(ms))")
        }
        sem.signal()
    }.resume()
    if sem.wait(timeout: .now() + 30) == .timedOut { say("E1.P11 FAIL timeout after 30 s") }
}

// MARK: - Timer first-fire semantics (Darwin: Timer(timeInterval:) first fires after the interval)

func runTimers() {
    _ = setup("cf")
    let rec = G.rec
    let t0 = e1_now_ms()
    RunLoop.main.add(Timer(timeInterval: 1.0, repeats: false) { _ in rec.add("A", e1_now_ms() - t0) }, forMode: .common)
    RunLoop.main.add(Timer(timeInterval: 1.0, repeats: true) { _ in rec.add("B", e1_now_ms() - t0) }, forMode: .common)
    _ = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { _ in rec.add("C", e1_now_ms() - t0) }
    RunLoop.main.add(Timer(fire: Date(timeIntervalSinceNow: 1.0), interval: 1.0, repeats: true) { _ in rec.add("D", e1_now_ms() - t0) },
                     forMode: .common)
    Thread {
        Thread.sleep(forTimeInterval: 2.5)
        DispatchQueue.main.async { e1_set_done() }
    }.start()
    runLoop("cf")
    let cases = [
        ("A", "Timer(timeInterval:1,repeats:false)+add"), ("B", "Timer(timeInterval:1,repeats:true)+add"),
        ("C", "Timer.scheduledTimer(withTimeInterval:1)"), ("D", "Timer(fire:now+1,interval:1)+add"),
    ]
    for (key, name) in cases {
        let fires = rec.get(key).map(\.value)
        let first = fires.first ?? -1
        let darwinLike = first > 900 && first < 1200
        say("E1.TIMER \(darwinLike ? "PASS" : "FAIL") \(name) first_fire_ms=\(f2(first)) fires_ms=\(fires.map { f2($0) }) (Darwin: first fire ~1000)")
    }
}

// MARK: - Text through the loop (stages 6-7 need it): posted WM_CHAR and SendInput(KEYEVENTF_UNICODE)

/// cf = CF's pump; cfhook = CF's pump + a WH_GETMESSAGE hook that re-dispatches WM_CHAR with DispatchMessageW;
/// dhc = own PeekMessageW pump.
func runText(_ mode: String) {
    let strategy = mode == "dhc" ? "dhc" : "cf"
    let notes = setup(strategy)
    e1_set_msg_callback(onMessage)
    G.hwnd = e1_make_visible_window()
    let hook = e1_install_getmsg_hook()
    if mode == "cfhook" { e1_set_hook_redispatch(1) }
    say("E1.TEXT[\(mode)] VALUE \(notes) hook=\(hook) foreground=\(e1_is_foreground(G.hwnd)) ACP=\(e1_acp())")
    Thread {
        Thread.sleep(forTimeInterval: 0.3)
        _ = e1_post(G.hwnd, 0x0102, 0xD55C, 0)  // posted path
        Thread.sleep(forTimeInterval: 0.3)
        let fg = e1_is_foreground(G.hwnd)
        let a = e1_send_unicode_input(0x42)  // input path: 'B' then U+D55C
        let b = e1_send_unicode_input(0xD55C)
        say("E1.TEXT[\(mode)] VALUE SendInput injected=\(a)+\(b) foreground_at_send=\(fg)")
        Thread.sleep(forTimeInterval: 0.6)
        DispatchQueue.main.async { e1_set_done() }
    }.start()
    Thread {
        Thread.sleep(forTimeInterval: 10)
        say("E1.TEXT[\(mode)] WATCHDOG")
        exit(4)
    }.start()
    runLoop(strategy)
    var chars = [UInt32](repeating: 0, count: 8)
    let n = e1_chars(&chars, 8)
    let got = chars.prefix(Int(min(n, 8))).map { "0x" + String($0, radix: 16) }
    let posted = got.first == "0xd55c"
    let typed = Array(got.dropFirst()) == ["0x42", "0xd55c"]
    say("E1.TEXT[\(mode)] \(posted ? "PASS" : "FAIL") posted-WM_CHAR got_first=\(got.first ?? "none")")
    say("E1.TEXT[\(mode)] \(typed ? "PASS" : "FAIL") SendInput-unicode got_rest=\(Array(got.dropFirst())) want=[0x42, 0xd55c] "
        + "hook_redispatched=\(e1_hook_redispatched())")
}
