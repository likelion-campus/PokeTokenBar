#if os(Windows)
import CTeamTLS
import CWinShim
import Foundation
import WinSDK

/// `--selftest --selftest-out <file>`: runs inside the shipped loop and writes
/// `{"result":"pass"|"fail","version","openssl","checks":[{"name","ok","detail"}]}`, then leaves through
/// `WindowsApp.exit` with 0 or 1. While it runs, each check is appended to `<file>.lines` as one JSON line, so a hang
/// or crash still shows how far it got. Safe on a user's PC: it reads (never changes) the AI tools' logs, its own
/// settings keys are named `ptb.selftest.*` and removed at the end, `refreshInterval` is put back, and it types into
/// a window only when `CI` is set.
enum WindowsSelftest {
    struct Check: Codable, Equatable {
        let name: String
        let ok: Bool
        let detail: String
    }

    private struct Report: Codable {
        let result: String
        let version: String
        let openssl: String
        let checks: [Check]
    }

    nonisolated(unsafe) private static var progressURL: URL?

    /// CI runs may show balloons and type into windows; a person's PC may not (this file is on the env-read allow-list).
    static var onCI: Bool { ProcessInfo.processInfo.environment["CI"] != nil }
    /// Length of the idle windows (`PTB_SELFTEST_IDLE_SECONDS`, default 60), read here for the other selftest files too.
    static var idleSeconds: Double { Double(ProcessInfo.processInfo.environment["PTB_SELFTEST_IDLE_SECONDS"] ?? "") ?? 60 }

    /// Starts the run on the main actor once the loop turns, then exits with its result.
    @MainActor static func start(_ app: WindowsAppDelegate, writingTo url: URL) {
        let progress = url.appendingPathExtension("lines")
        try? FileManager.default.removeItem(at: progress)
        try? FileManager.default.removeItem(at: url)
        progressURL = progress
        Task { @MainActor in
            let checks = await run(app)
            do { try write(checks, to: url) } catch { AppLog.write("selftest: cannot write \(url.path): \(error)") }
            WindowsApp.exit(checks.allSatisfy(\.ok) ? 0 : 1, .selftest)
        }
    }

    /// Longest launch-refresh stall the selftest accepts, in ms. The flushed writes it guards against took 146-231 ms on the
    /// CI runner, and after `PlatformCompat.atomicWrite` 8 launches showed none over the probe's 30 ms. But the same runner
    /// also showed single 157 and 221 ms stalls on plain log writes and file opens in later runs (disk latency, nothing of
    /// ours), and a real PC may scan every new file (Defender). A tight time bound would fail on that noise, so the
    /// regression itself is caught by name (any sample inside FlushFileBuffers fails) and the time bound is generous (1000 ms,
    /// 4x the worst noise seen). The measured number is in the check's detail either way.
    static let launchStallFailMs = 1000

    /// The longest stall's top frames show `FlushFileBuffers` under a Foundation file write that is not CoreFoundation's
    /// preferences writer (`_CFWriteBytesToFile` flushes on Windows, corelibs CFFileUtilities.c; the 2 s settings sync
    /// runs on the main thread inside the probe window and is a separate known cost).
    static func stallIsOurFlush(_ detail: String) -> Bool {
        let flush = detail.contains("FlushBuffersFile") || detail.contains("FlushFileBuffers")
        let cf = detail.contains("_CFWriteBytesToFile") || detail.contains("CFURLWriteDataAndPropertiesToResource")
            || detail.contains("CFPreferences") || detail.contains("CFXMLPreferences")
            || detail.contains("UserDefaultsC11synchronize")  // seen on the runner (run 43608614954): the 2 s settings sync, 83 ms
        return flush && !cf
    }

    @MainActor static func run(_ app: WindowsAppDelegate) async -> [Check] {
        let r = Recorder()
        // Watches the main thread from launch until the store has settled. Before PlatformCompat.atomicWrite the
        // companion and parity saves flushed to disk on the main actor (FlushFileBuffers, 146-231 ms on the runner;
        // defect log), so the loop checks still run after the store settles, with the same bounds. This check reports
        // the stalls and what held the thread, and fails above `launchStallFailMs`.
        let realBefore = [Self.modification(of: WinDefaultsSync.expectedPlistURL()),
                          Self.modification(of: SettingsPlistGuard.backupURL(for: WinDefaultsSync.expectedPlistURL()))]
        let stalls = MainStallProbe.start(mainThread: WindowsApp.mainThreadID)
        r.add("build.shims", ptb_shim_abi() == 1, "CWinShim abi=\(ptb_shim_abi()) openssl=\(String(cString: ptb_tls_openssl_version()))")
        pathChecks(r)
        await storeChecks(r, app)
        let quiet = await waitStable(timeout: 120, quiet: 1) { !app.store.isRefreshing && !WinDefaultsSync.isSyncPending }
        if let stalls {
            let report = await stalls.stop()
            r.add("loop.mainThreadStalls", report.longestMs < launchStallFailMs && !Self.stallIsOurFlush(report.detail), report.detail + " (fails over \(launchStallFailMs) ms, or when the longest stall's top frames are a Foundation Data.write inside FlushFileBuffers; CoreFoundation's own plist write flushes too and is not counted)")
        } else {
            r.add("loop.mainThreadStalls", true, "probe unavailable (thread handle or stack limits)")
        }
        if !quiet { AppLog.write("selftest: the store did not settle within 120 s; loop checks run anyway") }
        await loopChecks(r, app)
        await limitsCheck(r)
        await defaultsChecks(r, app)
        await shellChecks(r)
        await crashChecks(r)
        await singleInstanceCheck(r, app)
        await guardChecks(r)
        let real = WinDefaultsSync.expectedPlistURL()
        let realAfter = [Self.modification(of: real), Self.modification(of: SettingsPlistGuard.backupURL(for: real))]
        func show(_ d: [Date?]) -> String { d.map { $0.map { "\($0)" } ?? "absent" }.joined(separator: " / ") }
        r.add("defaults.realSettingsUntouched", realBefore == realAfter,
              "\(WinPath.native(real)) and its .bak modified before=\(show(realBefore)) after=\(show(realAfter)); "
                + "the selftest keeps its settings in suite \(WinDefaultsSync.selftestSuiteName ?? "-")")
        await systemServiceChecks(r)
        await trayChecks(r, app)
        await modalPumpChecks(r, app)
        await notifyChecks(r, app)
        if let dir = WinUIDump.directory(from: CommandLine.arguments) { await WinUIDump.run(r, app, into: dir) }
        await teamChecks(r, app)  // Task 19 (WindowsSelftestTeam.swift); shuts its transports down before the idle window
        await idleCheck(r, app)
        return r.checks
    }

    static func write(_ checks: [Check], to url: URL) throws {
        let report = Report(result: checks.allSatisfy(\.ok) ? "pass" : "fail", version: WindowsInstall.version ?? "unknown",
                            openssl: String(cString: ptb_tls_openssl_version()), checks: checks)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: url)
    }

    @MainActor final class Recorder {
        private(set) var checks: [Check] = []

        func add(_ name: String, _ ok: Bool, _ detail: String) {
            let check = Check(name: name, ok: ok, detail: detail)
            checks.append(check)
            AppLog.write("selftest \(ok ? "PASS" : "FAIL") \(name): \(detail)")
            guard let url = WindowsSelftest.progressURL, let json = try? JSONEncoder().encode(check) else { return }
            let line = json + Data("\n".utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
                try? handle.close()
            } else {
                try? line.write(to: url)
            }
        }
    }

    // MARK: - loop (F4, F15, F16)

    private struct Hit: Sendable {
        let tid: DWORD
        let ms: Double
    }

    private final class Box<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [T] = []
        func append(_ item: T) { lock.lock(); items.append(item); lock.unlock() }
        var values: [T] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private static let postedMessage = UINT(WM_APP) + 0x20
    private static let sentMessage = UINT(WM_APP) + 0x21

    @MainActor private static func loopChecks(_ r: Recorder, _ app: WindowsAppDelegate) async {
        let env = ProcessInfo.processInfo.environment
        let expected: WinMainLoop.Strategy = env["PTB_WIN_LOOP"]?.lowercased() == "dispatch" ? .dispatchHandle
            : .cfRunLoopWithMessages
        r.add("loop.strategy", app.loopStrategy == expected,
              "strategy=\(app.loopStrategy.rawValue) expected=\(expected.rawValue)")

        let main = WindowsApp.mainThreadID
        // Right after launch the store's first refresh is running; the brief's bound here is the thread only.
        let burst = await taskBurst()
        r.add("loop.mainActorTask", burst.complete && onMain(burst.task, main), burst.detail)

        let queueHits = Box<Hit>()
        onThread {
            for _ in 0..<10 {
                let t0 = nowMs()
                DispatchQueue.main.async { queueHits.append(Hit(tid: GetCurrentThreadId(), ms: nowMs() - t0)) }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        let queueDone = await waitUntil(timeout: 3) { queueHits.values.count >= 10 }
        r.add("loop.mainQueue", queueDone && onMain(queueHits.values, main) && maxMs(queueHits.values) < 50,
              "DispatchQueue.main.async from a thread: " + summary(queueHits.values, main, of: 10))

        let timerHits = Box<Hit>()
        let timerStart = nowMs()
        let timer = Timer(fire: Date(timeIntervalSinceNow: 0.2), interval: 0, repeats: false) { _ in
            timerHits.append(Hit(tid: GetCurrentThreadId(), ms: nowMs() - timerStart))
        }
        RunLoop.main.add(timer, forMode: .common)
        let fired = await waitUntil(timeout: 3) { !timerHits.values.isEmpty }
        let firstFire = timerHits.values.first?.ms ?? -1
        r.add("loop.runLoopTimer", fired && onMain(timerHits.values, main) && firstFire >= 180 && firstFire < 250,
              "Timer(fire: now + 0.2 s) on RunLoop.main fired at \(f2(firstFire)) ms on_main=\(onMain(timerHits.values, main))")

        let sinkBits = Int(bitPattern: app.sink.hwnd)
        let posted = Box<Hit>()
        let postedToken = app.sink.on(postedMessage) { wParam, _ in
            posted.append(Hit(tid: GetCurrentThreadId(), ms: nowMs() - Double(bitPattern: UInt64(wParam))))
            return 0
        }
        onThread {
            for _ in 0..<20 {
                _ = PostMessageW(HWND(bitPattern: sinkBits), postedMessage, WPARAM(nowMs().bitPattern), 0)
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        let postedDone = await waitUntil(timeout: 3) { posted.values.count >= 20 }
        app.sink.off(postedToken)
        r.add("loop.postedMessage", postedDone && onMain(posted.values, main) && maxMs(posted.values) < 50,
              "PostMessageW from a thread: " + summary(posted.values, main, of: 20))

        let sentOnMain = Box<Hit>()
        let sends = Box<Hit>()  // tid = 1 when the send returned OK with our reply
        let sentToken = app.sink.on(sentMessage) { _, _ in
            sentOnMain.append(Hit(tid: GetCurrentThreadId(), ms: 0))
            return 0x5151
        }
        onThread {
            for _ in 0..<5 {
                Thread.sleep(forTimeInterval: 0.05)
                let t0 = nowMs()
                var reply: DWORD_PTR = 0
                let rc = SendMessageTimeoutW(HWND(bitPattern: sinkBits), sentMessage, 0, 0, UINT(SMTO_NORMAL), 2000, &reply)
                sends.append(Hit(tid: rc != 0 && reply == 0x5151 ? 1 : 0, ms: nowMs() - t0))
            }
        }
        let sendsDone = await waitUntil(timeout: 15) { sends.values.count >= 5 }
        app.sink.off(sentToken)
        let sendOK = sends.values.filter { $0.tid == 1 }.count
        r.add("loop.crossThreadSend",
              sendsDone && sendOK == 5 && onMain(sentOnMain.values, main) && maxMs(sends.values) < 50,
              "SendMessageTimeoutW from a thread: n=\(sends.values.count)/5 returned_ok=\(sendOK) "
                + "wndproc_on_main=\(sentOnMain.values.filter { $0.tid == main }.count) max_ms=\(f2(maxMs(sends.values)))")

        let chars = Box<UInt32>()
        let charToken = app.sink.on(UINT(WM_CHAR)) { wParam, _ in chars.append(UInt32(truncatingIfNeeded: wParam)); return 0 }
        let before = WinMessageHook.redispatchedChars
        _ = PostMessageW(app.sink.hwnd, UINT(WM_CHAR), 0x41, 0)
        _ = PostMessageW(app.sink.hwnd, UINT(WM_CHAR), 0xD55C, 0)
        _ = await waitUntil(timeout: 2) { chars.values.count >= 2 }
        app.sink.off(charToken)
        let redispatched = WinMessageHook.redispatchedChars - before
        r.add("loop.postedUnicodeChar", chars.values == [0x41, 0xD55C] && redispatched >= 2,
              "posted [0x41, 0xd55c] got=\(hex(chars.values)) redispatched=\(redispatched) acp=\(GetACP())")

        await typedCharCheck(r)
    }

    /// Ten rounds, from one plain thread, of a `Task { @MainActor }`, a `Task.detached` (the cooperative pool) and a
    /// `DispatchQueue.main.async`, so a slow main-actor task can be told apart: a busy main thread delays the main
    /// queue too, a busy pool delays the detached task too.
    @MainActor private static func taskBurst() async -> (task: [Hit], complete: Bool, detail: String) {
        let task = Box<Hit>(), detached = Box<Hit>(), queue = Box<Hit>()
        onThread {
            for _ in 0..<10 {
                let t0 = nowMs()
                Task { @MainActor in task.append(Hit(tid: GetCurrentThreadId(), ms: nowMs() - t0)) }
                Task.detached { detached.append(Hit(tid: GetCurrentThreadId(), ms: nowMs() - t0)) }
                DispatchQueue.main.async { queue.append(Hit(tid: GetCurrentThreadId(), ms: nowMs() - t0)) }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        let complete = await waitUntil(timeout: 5) {
            task.values.count >= 10 && detached.values.count >= 10 && queue.values.count >= 10
        }
        let main = WindowsApp.mainThreadID
        let pool = detached.values.map(\.ms).sorted()
        let detail = "Task { @MainActor } from a thread: " + summary(task.values, main, of: 10)
            + "; same rounds: DispatchQueue.main " + summary(queue.values, main, of: 10)
            + "; Task.detached (pool) n=\(pool.count) median_ms=\(f2(pool.isEmpty ? -1 : pool[pool.count / 2])) "
            + "max_ms=\(f2(pool.last ?? -1))"
        return (task.values, complete, detail)
    }

    /// Real typed input: `SendInput(KEYEVENTF_UNICODE)` to a shown foreground window (F15). CI only, so a user's own
    /// selftest never types into their desktop.
    @MainActor private static func typedCharCheck(_ r: Recorder) async {
        guard ProcessInfo.processInfo.environment["CI"] != nil else {
            r.add("loop.typedUnicodeChar", true, "skipped: CI not set (the selftest types only on CI)")
            return
        }
        let window: WinSinkWindow
        do {
            window = try WinSinkWindow(className: "PokeTokenBarSelftestInput", title: "PokeTokenBar selftest input",
                                       style: DWORD(WS_OVERLAPPEDWINDOW) | DWORD(WS_VISIBLE), exStyle: 0,
                                       x: 40, y: 40, width: 260, height: 140)
        } catch {
            r.add("loop.typedUnicodeChar", false, "\(error)")
            return
        }
        let chars = Box<UInt32>()
        window.on(UINT(WM_CHAR)) { wParam, _ in chars.append(UInt32(truncatingIfNeeded: wParam)); return 0 }
        _ = ShowWindow(window.hwnd, SW_SHOW)
        forceForeground(window.hwnd)
        _ = SetFocus(window.hwnd)
        try? await Task.sleep(nanoseconds: 100_000_000)
        let foreground = GetForegroundWindow() == window.hwnd
        let before = WinMessageHook.redispatchedChars
        let injected = sendUnicode(0x42) + sendUnicode(0xD55C)
        _ = await waitUntil(timeout: 3) { chars.values.count >= 2 }
        let redispatched = WinMessageHook.redispatchedChars - before
        window.destroy()
        r.add("loop.typedUnicodeChar", chars.values == [0x42, 0xD55C],
              "typed [0x42, 0xd55c] got=\(hex(chars.values)) foreground=\(foreground) injected=\(injected) "
                + "redispatched=\(redispatched)")
    }

    /// E1's way past the foreground lock: try, then a synthetic Alt press, then attach to the foreground thread.
    @MainActor private static func forceForeground(_ hwnd: HWND) {
        _ = SetForegroundWindow(hwnd)
        if GetForegroundWindow() == hwnd { return }
        var alt = [INPUT(), INPUT()]
        alt[0].type = DWORD(INPUT_KEYBOARD)
        alt[0].ki.wVk = WORD(VK_MENU)
        alt[1] = alt[0]
        alt[1].ki.dwFlags = DWORD(KEYEVENTF_KEYUP)
        _ = SendInput(2, &alt, Int32(MemoryLayout<INPUT>.stride))
        _ = SetForegroundWindow(hwnd)
        if GetForegroundWindow() == hwnd { return }
        let foregroundThread = GetForegroundWindow().map { GetWindowThreadProcessId($0, nil) } ?? 0
        let me = GetCurrentThreadId()
        let attach = foregroundThread != 0 && foregroundThread != me
        if attach { _ = AttachThreadInput(me, foregroundThread, true) }
        _ = BringWindowToTop(hwnd)
        _ = SetForegroundWindow(hwnd)
        if attach { _ = AttachThreadInput(me, foregroundThread, false) }
    }

    private static func sendUnicode(_ ch: UInt16) -> UInt32 {
        var input = [INPUT(), INPUT()]
        input[0].type = DWORD(INPUT_KEYBOARD)
        input[0].ki.wScan = ch
        input[0].ki.dwFlags = DWORD(KEYEVENTF_UNICODE)
        input[1] = input[0]
        input[1].ki.dwFlags = DWORD(KEYEVENTF_UNICODE) | DWORD(KEYEVENTF_KEYUP)
        return SendInput(2, &input, Int32(MemoryLayout<INPUT>.stride))
    }

    // MARK: - paths and log

    @MainActor private static func pathChecks(_ r: Recorder) {
        let local = WinDefaultsSync.localAppDataFolder()
        let override = (ProcessInfo.processInfo.environment["PTB_STATE_DIR"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let state = AppStatePaths.directory()
        let expectedState = override.isEmpty ? local?.appendingPathComponent("PokeTokenBar")
            : URL(fileURLWithPath: override, isDirectory: true)
        r.add("paths.state", expectedState.map { WinPath.sameFile(state, $0) } ?? false,
              "state=\(WinPath.native(state)) expected=\(expectedState.map(WinPath.native) ?? "nil")"
                + (override.isEmpty ? "" : " (PTB_STATE_DIR)"))

        let logs = PlatformCompat.logsDirectory()
        let expectedLogs = local?.appendingPathComponent("PokeTokenBar").appendingPathComponent("Logs")
        r.add("paths.logs", expectedLogs.map { WinPath.sameFile(logs, $0) } ?? false,
              "logs=\(WinPath.native(logs)) expected=\(expectedLogs.map(WinPath.native) ?? "nil")")

        guard PlatformCompat.isBundledApp else {
            r.add("log.writes", true, "skipped: not packaged (no \(WindowsInstall.versionFileName) next to the exe)")
            return
        }
        let marker = "selftest log marker \(UUID().uuidString)"
        AppLog.writeAndFlush(marker)
        let text = (try? String(contentsOf: AppLog.logFileURL, encoding: .utf8)) ?? ""
        r.add("log.writes", text.contains(marker),
              "file=\(WinPath.native(AppLog.logFileURL)) bytes=\(text.utf8.count) marker_found=\(text.contains(marker))")
    }

    // MARK: - stores

    @MainActor private static func storeChecks(_ r: Recorder, _ app: WindowsAppDelegate) async {
        let env = ProcessInfo.processInfo.environment
        let store = app.store!
        let before = app.refreshCount
        await store.refresh()  // may join the launch refresh still in flight; wait for one to finish
        let refreshed = await waitUntil(timeout: 120) { app.refreshCount > before && !store.isRefreshing }
        let today = store.todayTotalTokens
        let byProvider = store.todayTokensByProvider.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
        let common = "today=\(today) providers=[\(byProvider)] refreshes=\(app.refreshCount) "
            + "CLAUDE_CONFIG_DIR=\(env["CLAUDE_CONFIG_DIR"] ?? "unset")"
        let expected = env["PTB_SELFTEST_EXPECT_TODAY_TOKENS"].flatMap { Int($0) }
        if let expected {
            r.add("store.refresh", refreshed && today == expected, common + " expected=\(expected)")
        } else {
            r.add("store.refresh", refreshed, common + " (PTB_SELFTEST_EXPECT_TODAY_TOKENS unset: not compared)")
        }

        let companion = app.companion!
        let ledger = companion.state.claimedTodayTokensByProvider
        let detail = "updates=\(app.companionUpdates) sawUsage=\(app.lastCompanionSawUsage) "
            + "ledger=\(ledger.map { $0.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",") } ?? "nil") "
            + "display=\(companion.displayState)"
        if expected == nil, !store.hasUsageData {
            r.add("companion.update", true, "skipped: no usage on this machine; " + detail)
        } else {
            r.add("companion.update",
                  app.companionUpdates > 0 && app.lastCompanionSawUsage && ledger == store.todayTokensByProvider, detail)
        }

        // F14: a `Timer(timeInterval:)` first fires at once on Windows; the store's reschedule must wait the interval.
        _ = await waitStable(timeout: 120, quiet: 0.5) { !store.isRefreshing }
        let oldInterval = store.refreshInterval
        let hadKey = app.defaults.object(forKey: "refreshInterval") != nil
        let t0 = nowMs()
        store.refreshInterval = 2
        let started = await waitUntil(timeout: 6, poll: 0.005) { store.isRefreshing }
        let elapsed = (nowMs() - t0) / 1000
        store.refreshInterval = oldInterval
        if !hadKey { app.defaults.removeObject(forKey: "refreshInterval") }
        r.add("store.timer", started && elapsed >= 1.8 && elapsed <= 3.5,
              "refreshInterval=2: first timer refresh after \(f2(elapsed)) s (F14 would be ~0.01 s); restored \(oldInterval)")
    }

    // MARK: - defaults (F2): each writer is a child process; the plist is read from disk

    @MainActor private static func defaultsChecks(_ r: Recorder, _ app: WindowsAppDelegate) async {
        let plist = WinDefaultsSync.plistURL(suite: WinDefaultsSync.selftestSuiteName)
        let run = String(UUID().uuidString.prefix(8))
        var keys: [String] = []
        func key(_ name: String) -> String { let k = "ptb.selftest.\(name).\(run)"; keys.append(k); return k }

        let local = WinDefaultsSync.localAppDataFolder()
        r.add("defaults.location", local.map { WinPath.sameFile(plist.deletingLastPathComponent(), $0) } ?? false,
              "cf=\(WinPath.native(plist.deletingLastPathComponent())) FOLDERID_LocalAppData=\(local.map(WinPath.native) ?? "nil")")

        // Debounce + TerminateProcess, then a new process reads it back (the kill test).
        let debounceKey = key("debounce")
        do {
            let child = try Helper.start(["--selftest-defaults-writer", "syncing", "kill", debounceKey, "v1"], ready: true)
            let ready = await child.waitReady(timeout: 20)
            let readyAt = nowMs()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let at1s = plistValue(plist, debounceKey) != nil
            try? await Task.sleep(nanoseconds: UInt64(max(0, 3000 - (nowMs() - readyAt)) * 1_000_000))
            child.kill()
            let code = await child.waitExit(timeout: 10)
            child.close()
            let present = plistValue(plist, debounceKey) == "v1"
            r.add("defaults.persist.debounce", ready && present,
                  "WinSyncingDefaults set, TerminateProcess 3 s later: on_disk_at_1s=\(at1s) on_disk_after_kill=\(present) "
                    + "ready=\(ready) exit=\(describe(code))")
            let reader = try Helper.start(["--selftest-defaults-reader", debounceKey, "v1"], ready: false)
            let readerCode = await reader.waitExit(timeout: 20)
            reader.close()
            r.add("defaults.persist.restart", readerCode == 0,
                  "a new process reads \(debounceKey)=v1 through the selftest's own settings suite: exit=\(describe(readerCode))")
        } catch {
            r.add("defaults.persist.debounce", false, "\(error)")
        }

        await exitWriter(r, "defaults.persist.exit", ["standard", "exit"], key("exit"), plist, expectPresent: true,
                         note: "settings suite set, then WindowsApp.exit")
        await exitWriter(r, "defaults.control", ["raw", "exit"], key("raw"), plist, expectPresent: nil,
                         note: "settings suite set, then the C exit call without a sync")
        await exitWriter(r, "exit.closeRequest", ["standard", "close"], key("close"), plist, expectPresent: true,
                         note: "settings suite set, then WM_CLOSE to its sink")
        await exitWriter(r, "exit.endSession", ["standard", "endsession"], key("endsession"), plist, expectPresent: true,
                         note: "settings suite set, then WM_ENDSESSION(TRUE) to its sink")

        let name = ProcessInfo.processInfo.processName
        let exists = FileManager.default.fileExists(atPath: plist.path)
        let real = WinDefaultsSync.expectedPlistURL()
        r.add("defaults.plistName", real.lastPathComponent == name + ".plist" && name.lowercased().hasSuffix(".exe") && exists,
              "selftest suite file=\(WinPath.native(plist)) exists=\(exists); the app's own would be \(WinPath.native(real)); processName=\(name)")

        for k in keys { app.defaults.removeObject(forKey: k) }
        WinDefaultsSync.flushNow()
        let left = keys.filter { plistValue(plist, $0) != nil }
        r.add("defaults.cleanup", left.isEmpty, left.isEmpty ? "removed \(keys.count) selftest keys" : "still on disk: \(left)")
    }

    /// `expectPresent` nil: informational (the F2 control), passes either way and says what happened.
    @MainActor private static func exitWriter(_ r: Recorder, _ name: String, _ mode: [String], _ key: String, _ plist: URL,
                                              expectPresent: Bool?, note: String) async {
        do {
            let ending = mode[1]
            let child = try Helper.start(["--selftest-defaults-writer", mode[0], ending, key, "v1"], ready: true)
            let ready = await child.waitReady(timeout: 20)
            var delivered = "-"
            if ready, ending == "close" || ending == "endsession" {
                let title = WinStr.w("ptb-selftest-helper-\(child.pid)")
                if let window = FindWindowW(WinStr.w(WinSinkWindow.className), title) {
                    if ending == "close" {
                        delivered = "posted=\(PostMessageW(window, UINT(WM_CLOSE), 0, 0))"
                    } else {
                        var reply: DWORD_PTR = 0
                        _ = SendMessageTimeoutW(window, UINT(WM_ENDSESSION), 1, 0, UINT(SMTO_NORMAL), 3000, &reply)
                        delivered = "sent"
                    }
                } else {
                    delivered = "no helper window"
                }
            }
            let code = await child.waitExit(timeout: 15)
            if code == nil { child.kill() }
            child.close()
            let present = plistValue(plist, key) == "v1"
            let detail = "\(note): on_disk=\(present) exit=\(describe(code)) ready=\(ready) \(delivered)"
            if let expectPresent {
                r.add(name, ready && code == 0 && present == expectPresent, detail)
            } else {
                r.add(name, true, detail + (present ? " (Foundation now saves on exit: F2 changed)" : " (F2 holds: lost)"))
            }
        } catch {
            r.add(name, expectPresent == nil, "\(error)")
        }
    }

    /// The settings-plist guard against a torn write (CF writes in place): child processes find a damaged plist at launch.
    @MainActor private static func guardChecks(_ r: Recorder) async {
        let folder = WinDefaultsSync.expectedPlistURL().deletingLastPathComponent()
        let key = "ptb.selftest.guard"
        func plistData(_ value: String) -> Data {
            (try? PropertyListSerialization.data(fromPropertyList: [key: value, "team.memberID": "M-\(value)"], format: .xml, options: 0)) ?? Data()
        }
        func scenario(_ name: String, current: Data?, backup: Data?, expect: String?, touch: Bool = false,
                      bakMember: String?? = nil) async {
            let suite = "ptb.selftest.guard." + String(UUID().uuidString.prefix(8))
            let plist = folder.appendingPathComponent(suite + ".plist")
            let bak = SettingsPlistGuard.backupURL(for: plist)
            defer { try? FileManager.default.removeItem(at: plist); try? FileManager.default.removeItem(at: bak) }
            if let current { try? current.write(to: plist) }
            if let backup { try? backup.write(to: bak) }
            do {
                let child = try Helper.start(["--selftest-guard-reader", suite, key, expect ?? "-"] + (touch ? ["touch"] : []), ready: false)
                let code = await child.waitExit(timeout: 30)
                child.close()
                let onDisk = (try? Data(contentsOf: plist)).map { SettingsPlistGuard.parses($0) } ?? false
                // The backup afterwards: its team.memberID, or nil when there is none.
                let member = (try? Data(contentsOf: bak)).flatMap {
                    (try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil)) as? [String: Any]
                }?["team.memberID"] as? String
                let bakOK = bakMember.map { $0 == member } ?? true
                r.add("defaults.guard.\(name)", code == 0 && bakOK, "child exit=\(describe(code)) expected value=\(expect ?? "absent") plist parses afterwards=\(onDisk) "
                      + "backup memberID afterwards=\(member ?? "none")\(bakMember.map { " (expected \($0 ?? "none"))" } ?? "")")
            } catch {
                r.add("defaults.guard.\(name)", false, "\(error)")
            }
        }
        let good = plistData("saved")
        await scenario("truncated", current: good.prefix(good.count / 2), backup: good, expect: "saved")
        await scenario("garbage", current: Data("not a plist \u{0}\u{1}".utf8), backup: good, expect: "saved")
        await scenario("missing", current: nil, backup: good, expect: "saved")
        await scenario("noBackup", current: Data("garbage".utf8), backup: nil, expect: nil)
        await scenario("goodNotOverwritten", current: plistData("new"), backup: plistData("old"), expect: "new")
        // Backups: a sync after a write backs a good plist up, but never over another team.memberID, and never at all in a
        // session whose launch could not establish a good plist.
        await scenario("backupFollowsGoodSettings", current: plistData("new"), backup: nil, expect: "new", touch: true, bakMember: .some("M-new"))
        await scenario("backupKeepsTheOldMemberID", current: plistData("new"), backup: plistData("old"), expect: "new", touch: true,
                       bakMember: .some("M-old"))
        await scenario("noBackupsAfterAFailedStart", current: Data("garbage".utf8), backup: nil, expect: nil, touch: true,
                       bakMember: .some(nil))
    }

    // MARK: - single instance

    @MainActor private static func singleInstanceCheck(_ r: Recorder, _ app: WindowsAppDelegate) async {
        let before = app.showRequests
        do {
            let child = try Helper.start(["--selftest-second"], ready: false)
            let code = await child.waitExit(timeout: 20)
            if code == nil { child.kill() }
            child.close()
            let notified = await waitUntil(timeout: 3) { app.showRequests > before }
            r.add("singleInstance.second", code == 3 && notified,
                  "second start exit=\(describe(code)) (expected 3) running instance notified=\(notified) mutex=\(app.mutexName)")
        } catch {
            r.add("singleInstance.second", false, "\(error)")
        }
    }

    // MARK: - tray (Task 6): the runner has a working shell tray, so add / modify / rect / re-add / delete are real

    @MainActor private static func trayChecks(_ r: Recorder, _ app: WindowsAppDelegate) async {
        guard let host = app.tray else {
            r.add("tray.add", false, "the app has no tray host")
            return
        }
        let tray = host.tray
        r.add("tray.add", tray.isPresent && tray.lastAddOK && tray.lastVersionOK,
              "NIM_ADD=\(tray.lastAddOK) NIM_SETVERSION(4)=\(tray.lastVersionOK) adds=\(tray.addCount) present=\(tray.isPresent)")

        let long = "selftest 한국어 😀 " + String(repeating: "x", count: 200)
        tray.setTip(long)
        let clippedUnits = tray.lastTipUnits
        let modifiedLong = tray.lastModifyOK
        let fixture = WinIcon(png: WinIcon.fixturePNG, size: 16)
        tray.setIcon(fixture)
        let modifiedIcon = tray.lastModifyOK
        host.refresh()
        let compact = TokenFormatter.compact(app.store.todayTotalTokens)
        r.add("tray.modify", modifiedLong && modifiedIcon && fixture != nil && clippedUnits == TrayMenuModel.tipLimit,
              "tip \(long.utf16.count) -> \(clippedUnits) units (limit \(TrayMenuModel.tipLimit)) NIM_MODIFY tip=\(modifiedLong) icon=\(modifiedIcon) fixtureIcon=\(fixture != nil)")
        r.add("tray.tooltip", host.lastTip.contains(compact) && host.lastTip.utf16.count <= TrayMenuModel.tipLimit,
              "tip=\(host.lastTip.debugDescription) units=\(host.lastTip.utf16.count) expects \(compact)")

        let rect = tray.anchorRect()
        r.add("tray.anchorRect", rect != nil,
              "Shell_NotifyIconGetRect hr=0x\(String(UInt32(bitPattern: tray.lastAnchorResult), radix: 16)) rect=\(rect.map { "(\($0.left),\($0.top),\($0.right),\($0.bottom))" } ?? "nil")")

        let iconName = "tray.icon"
        let loaded = await waitUntil(timeout: 20) { host.iconLoads > 0 }
        if loaded {
            r.add(iconName, host.iconPixels > 0, "sprite icon from \(host.iconSource) at \(host.iconPixels) px, loads=\(host.iconLoads)")
        } else {
            let egg = await SpriteStore.shared.eggData()
            r.add(iconName, egg == nil, egg == nil ? "offline: no sprite could be fetched; the generic icon stays (honest fallback)"
                  : "the egg sprite is available but no icon was set within 20 s")
        }
        let dpiSize = host.iconPixelSize()
        r.add("tray.iconSize", (16...64).contains(dpiSize), "SM_CXSMICON for the window's DPI = \(dpiSize) px")

        // Explorer restart: TaskbarCreated reaches the sink, which adds the icon again.
        let before = tray.addCount
        let created = RegisterWindowMessageW(WinStr.w("TaskbarCreated"))
        _ = SendMessageW(app.sink.hwnd, created, 0, 0)
        r.add("tray.reAddOnTaskbarCreated", created != 0 && tray.addCount == before + 1 && tray.lastAddOK && tray.isPresent,
              "message=\(created) adds \(before) -> \(tray.addCount) NIM_ADD=\(tray.lastAddOK) NIM_SETVERSION=\(tray.lastVersionOK)")

        await menuKeysCheck(r, app, host, name: "tray.menuKeys", mnemonic: false)
        await menuKeysCheck(r, app, host, name: "tray.menuMnemonic", mnemonic: true)

        // Several parties register for one message on the sink: all run in order, and off removes only its own.
        let probe = UINT(WM_APP) + 0x22
        var order: [Int] = []
        let first = app.sink.on(probe) { _, _ in order.append(1); return nil }
        let second = app.sink.on(probe) { _, _ in order.append(2); return 7 }
        let both = SendMessageW(app.sink.hwnd, probe, 0, 0)
        let orderBoth = order
        app.sink.off(first)
        order = []
        _ = SendMessageW(app.sink.hwnd, probe, 0, 0)
        let orderOne = order
        app.sink.off(second)
        let none = SendMessageW(app.sink.hwnd, probe, 0, 0)
        r.add("sink.handlerList", orderBoth == [1, 2] && both == 7 && orderOne == [2] && none == 0,
              "two handlers: order=\(orderBoth) result=\(both); after off(first): \(orderOne); after off(second): result=\(none)")

        if ProcessInfo.processInfo.environment["CI"] != nil {
            let ok = tray.showBalloon(title: "PokeTokenBar", body: "selftest", sound: false)
            r.add("tray.balloon", ok, "NIM_MODIFY with NIF_INFO returned \(ok)")
        } else {
            r.add("tray.balloon", true, "skipped (not CI): a balloon would show on this PC")
        }

        // Tray and system events are both registered on the live sink: one WM_TIMECHANGE must reach every party.
        let timeChange = UINT(WM_TIMECHANGE)
        var probeHits = 0
        let probeToken = app.sink.on(timeChange) { _, _ in probeHits += 1; return nil }
        let events = Platform.current.events as? WindowsSystemEvents
        let eventsBefore = events?.timeChangeCount ?? -1
        _ = SendMessageW(app.sink.hwnd, timeChange, 0, 0)
        app.sink.off(probeToken)
        r.add("sink.sharedWithSystemEvents", events != nil && probeHits == 1 && events!.timeChangeCount == eventsBefore + 1 && tray.isPresent,
              "WM_TIMECHANGE to the live sink: probe handler hits=\(probeHits) system-events handler runs \(eventsBefore) -> \(events?.timeChangeCount ?? -1) tray present=\(tray.isPresent)")

        tray.remove()
        let removed = tray.lastDeleteOK && !tray.isPresent
        let readded = tray.add()
        host.refresh()
        r.add("tray.remove", removed && readded, "NIM_DELETE=\(tray.lastDeleteOK) present after=\(!removed ? "?" : "false") then NIM_ADD again=\(readded)")
    }

    private final class KeyDriver: @unchecked Sendable {
        private let lock = NSLock()
        private var log: [String] = []
        private var finished = false
        func note(_ s: String) { lock.lock(); log.append(s); lock.unlock() }
        func finish() { lock.lock(); finished = true; lock.unlock() }
        var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
        var text: String { lock.lock(); defer { lock.unlock() }; return log.joined(separator: ",") }
    }

    /// Opens the real menu from a timer, drives it with posted keys (Down until "Refresh" is highlighted, then Return)
    /// and asserts the store refreshed. A helper thread does the key work because the menu loop blocks the main thread.
    @MainActor private static func menuKeysCheck(_ r: Recorder, _ app: WindowsAppDelegate, _ host: WinTrayHost,
                                                   name: String, mnemonic: Bool) async {
        let items = host.menuItems()
        guard let target = items.firstIndex(where: { $0?.action == .refresh }) else {
            r.add(name, false, "no Refresh item in the menu")
            return
        }
        // The letter to type: the first letter of the title, which must pick exactly one enabled item.
        let letter = items[target]?.title.first.map { String($0).lowercased() } ?? ""
        let candidates = items.compactMap { $0 }.filter { $0.enabled && $0.title.lowercased().hasPrefix(letter) }
        if mnemonic, letter.isEmpty || candidates.count != 1 {
            r.add(name, false, "first letter '\(letter)' of the Refresh title does not pick exactly one item (\(candidates.count))")
            return
        }
        let code = letter.utf16.first ?? 0
        _ = await waitUntil(timeout: 60) { !app.store.isRefreshing }
        host.resetLastAction()
        let refreshesBefore = app.refreshCount
        let driver = KeyDriver()
        let owner = Int(bitPattern: app.sink.hwnd)
        let count = items.count
        onThread {
            func post(_ message: Int32, _ key: Int32) {
                _ = PostMessageW(HWND(bitPattern: owner), UINT(message), WPARAM(key), 0)
            }
            var waited = 0
            while WinPopupMenu.openMenuBits == 0, waited < 200 { Thread.sleep(forTimeInterval: 0.05); waited += 1 }
            let bits = WinPopupMenu.openMenuBits
            guard bits != 0 else { driver.note("menu never opened"); driver.finish(); return }
            Thread.sleep(forTimeInterval: 0.4)
            if mnemonic {
                post(WM_CHAR, Int32(code))  // the letter the menu loop reads as type-to-select / mnemonic
                driver.note("char=\(code)")
            } else {
                var presses = 0
                while WinPopupMenu.highlightedIndex(menuBits: bits, count: count) != target, presses < count + 2 {
                    post(WM_KEYDOWN, Int32(VK_DOWN)); post(WM_KEYUP, Int32(VK_DOWN))
                    presses += 1
                    Thread.sleep(forTimeInterval: 0.2)
                }
                driver.note("down=\(presses) highlighted=\(WinPopupMenu.highlightedIndex(menuBits: bits, count: count).map(String.init) ?? "none")")
                post(WM_KEYDOWN, Int32(VK_RETURN)); post(WM_KEYUP, Int32(VK_RETURN))
            }
            for _ in 0..<40 where WinPopupMenu.openMenuBits != 0 { Thread.sleep(forTimeInterval: 0.2) }
            if WinPopupMenu.openMenuBits != 0 {  // the keys did not work: do not hang the run
                driver.note("still open after Return; Escape")
                post(WM_KEYDOWN, Int32(VK_ESCAPE)); post(WM_KEYUP, Int32(VK_ESCAPE))
            }
            driver.finish()
        }
        let timer = Timer(fire: Date(timeIntervalSinceNow: 0.05), interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated {
                driver.note("timer fired")
                host.openMenu(at: POINT(x: 300, y: 300))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        let finished = await waitUntil(timeout: 30) { driver.isFinished }
        let ran = await waitUntil(timeout: 30) { app.refreshCount > refreshesBefore }
        r.add(name, finished && driver.text.contains("timer fired") && host.lastAction == .refresh && ran,
              "menu opened from a timer; keys: \(driver.text) action=\(host.lastAction) store refreshes \(refreshesBefore) -> \(app.refreshCount)")
    }

    // MARK: - idle (D8): cycles and context switches, never GetProcessTimes (F20)

    /// Claude limits from a fixture credentials file: the moved file-reading path must reach the network boundary.
    /// Unpackaged: the gate stops it (`liveFetchNotPermitted`). Packaged: the fixture token goes to the real endpoint
    /// and is refused (401/403), which is recorded, not a failure. Offline is recorded too: the file was read.
    @MainActor private static func limitsCheck(_ r: Recorder) async {
        // `PlatformLimits.current` is a `static let`: touched before WindowsApp set the factory it would keep the stubs.
        let live = PlatformLimits.current is WindowsLimitsProviders
        r.add("limits.factory", live, "PlatformLimits.current is \(type(of: PlatformLimits.current))")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-selftest-claude-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let expiresAt = Int((Date().timeIntervalSince1970 + 3600) * 1000)
        let json = #"{"claudeAiOauth":{"accessToken":"ptb-selftest-fixture-token","expiresAt":\#(expiresAt),"subscriptionType":"pro"}}"#
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data(json.utf8).write(to: ClaudeAccountRoots.credentialsFileURL(for: root))
        } catch {
            r.add("limits.claude", false, "cannot write the fixture: \(error)")
            return
        }
        let gate = AppEnv.allowsLiveLimitsFetch ? "gate open" : "gate closed"
        do {
            _ = try await OAuthLimitsProvider(accessTokenCache: .forConfigRoot(root)).fetch(allowKeychainPrompt: false)
            r.add("limits.claude", true, "\(gate): the fixture token was accepted (unexpected, but the file was read)")
        } catch LimitsError.liveFetchNotPermitted {
            r.add("limits.claude", !AppEnv.allowsLiveLimitsFetch, "\(gate): file read, stopped at the live-fetch gate")
        } catch LimitsError.httpStatus(let status) {
            r.add("limits.claude", status == 401 || status == 403, "\(gate): file read, endpoint answered HTTP \(status)")
        } catch LimitsError.rateLimited(let after) {
            r.add("limits.claude", true, "\(gate): file read, endpoint answered 429 retryAfter=\(String(describing: after))")
        } catch let error as URLError {
            r.add("limits.claude", true, "\(gate): file read, network unavailable (\(error.code.rawValue))")
        } catch {
            r.add("limits.claude", false, "\(gate): the file path did not reach the network boundary: \(error)")
        }
    }

    @MainActor private static func idleCheck(_ r: Recorder, _ app: WindowsAppDelegate) async {
        let seconds = Double(ProcessInfo.processInfo.environment["PTB_SELFTEST_IDLE_SECONDS"] ?? "") ?? 60
        _ = await waitStable(timeout: 120, quiet: 2) { !app.store.isRefreshing }
        let settled = await taskBurst()
        r.add("loop.mainActorTaskSettled",
              settled.complete && onMain(settled.task, WindowsApp.mainThreadID) && maxMs(settled.task) < 50,
              "store idle; " + settled.detail)
        _ = await waitStable(timeout: 10, quiet: 2) { !app.store.isRefreshing }
        let dayFires0 = (Platform.current.events as? WindowsSystemEvents)?.dayTimerFires ?? 0
        let c0 = (WinDefaultsSync.safetyFires, WinDefaultsSync.debounceFires, app.refreshCount, WinMainLoop.iterations)
        let sample = await IdleSampler.measure(seconds: seconds, mainThread: WindowsApp.mainThreadID)
        let safety = WinDefaultsSync.safetyFires - c0.0, debounce = WinDefaultsSync.debounceFires - c0.1
        let refreshes = app.refreshCount - c0.2, iterations = WinMainLoop.iterations - c0.3
        guard let sample else {
            r.add("idle.window", false, "measurement failed (NtQuerySystemInformation / QueryThreadCycleTime unavailable)")
            return
        }
        // A wake by a known timer costs a few context switches; anything else showing up here is a busy loop.
        let dayFires = ((Platform.current.events as? WindowsSystemEvents)?.dayTimerFires ?? 0) - dayFires0
        let explained = safety + debounce + dayFires
        let budget = 3 + 3 * explained + 60 * refreshes
        r.add("idle.window", sample.layoutOK && sample.mainFound && sample.mainContextSwitches <= budget,
              "\(Int(seconds)) s idle: main_thread_cs=\(sample.mainContextSwitches) main_thread_cycles=\(sample.mainCycles) "
                + "process_cycles=\(sample.processCycles) budget_cs=\(budget) known_wakes={safety_sync:\(safety), "
                + "debounce_sync:\(debounce), store_refresh:\(refreshes), day_timer:\(dayFires)} loop_iterations=\(iterations) "
                + "loop_finished_returns=\(WinMainLoop.finishedReturns) layout_ok=\(sample.layoutOK) threads=\(sample.threadCount) "
                + "busy_threads=[\(sample.busy)]")
    }

    // MARK: - helper processes (internal flags)

    /// `--selftest-defaults-writer <syncing|standard|raw> <exit|kill|close|endsession> <key> <value>`.
    @MainActor static func runDefaultsWriter(_ args: [String]) -> Never {
        guard args.count >= 4 else { WindowsApp.exit(2, .helper) }
        let (writer, ending, key, value) = (args[0], args[1], args[2], args[3])
        _ = WinMainLoop.prepare()
        var window: WinSinkWindow?
        if ending == "close" || ending == "endsession" {
            window = try? WinSinkWindow(title: "ptb-selftest-helper-\(GetCurrentProcessId())")
            if let window { WindowsAppDelegate.installExitHandlers(on: window) }
        }
        switch writer {
        case "syncing", "standard": WinDefaultsSync.makeAppDefaults().set(value, forKey: key)  // registered: arms the 2 s save, synced on exit
        default: (WinDefaultsSync.selftestSuiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard).set(value, forKey: key)  // raw: nothing syncs it
        }
        signalReady()
        switch ending {
        case "exit":
            if writer == "raw" { WindowsApp.exitWithoutSyncForF2Control(0) }
            WindowsApp.exit(0, .helper)
        default:  // kill, close, endsession: the parent ends it
            withExtendedLifetime(window) { WinMainLoop.run(.cfRunLoopWithMessages) { false } }
            WindowsApp.exit(0, .helper)
        }
    }

    /// `--selftest-guard-reader <suite> <key> <expected|-> [touch]`: the launch guard on `<suite>.plist`, then a read through a
    /// fresh `UserDefaults(suiteName:)`. Exit 0 when the value is `expected` (`-`: absent).
    @MainActor static func runGuardReader(_ args: [String]) -> Never {
        guard args.count >= 3 else { WindowsApp.exit(2, .helper) }
        WinDefaultsSync.guardAtLaunch(suites: [args[0]])
        let touching = WinSyncingDefaults(suiteName: args[0])
        let value = touching?.string(forKey: args[1])
        if args.count >= 4, args[3] == "touch" {  // a write, then the sync that backs the plist up (or refuses to)
            touching?.set("1", forKey: "ptb.selftest.touch")
            WinDefaultsSync.flushNow()
        }
        WindowsApp.exit(value == (args[2] == "-" ? nil : args[2]) ? 0 : 1, .helper)
    }

    /// `--selftest-defaults-reader <key> <value>`: exit 0 when a fresh process reads the value.
    @MainActor static func runDefaultsReader(_ args: [String]) -> Never {
        guard args.count >= 2 else { WindowsApp.exit(2, .helper) }
        WindowsApp.exit(WinDefaultsSync.makeAppDefaults().string(forKey: args[0]) == args[1] ? 0 : 1, .helper)
    }

    static func signalReady() {
        guard let name = ProcessInfo.processInfo.environment["PTB_SELFTEST_READY_EVENT"],
              let event = OpenEventW(0x0002 /* EVENT_MODIFY_STATE */, false, WinStr.w(name)) else { return }
        _ = SetEvent(event)
        _ = CloseHandle(event)
    }

    /// A child copy of this exe, waited on through its process handle.
    @MainActor final class Helper {
        let pid: Int32
        private let handle: HANDLE
        private let ready: HANDLE?

        private init(pid: Int32, handle: HANDLE, ready: HANDLE?) {
            self.pid = pid
            self.handle = handle
            self.ready = ready
        }

        static func start(_ arguments: [String], ready: Bool) throws -> Helper {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath())
            process.arguments = arguments
            var env = ProcessInfo.processInfo.environment
            var event: HANDLE?
            if ready {
                let name = "Local\\PokeTokenBar-selftest-\(UUID().uuidString)"
                event = CreateEventW(nil, true, false, WinStr.w(name))
                env["PTB_SELFTEST_READY_EVENT"] = name
            }
            process.environment = env
            try process.run()
            let access: DWORD = 0x0001 | 0x0010_0000 | 0x1000  // TERMINATE | SYNCHRONIZE | QUERY_LIMITED_INFORMATION
            guard let handle = OpenProcess(access, false, DWORD(process.processIdentifier)) else {
                throw WinError(call: "OpenProcess", code: GetLastError())
            }
            return Helper(pid: process.processIdentifier, handle: handle, ready: event)
        }

        var exitCode: DWORD? {
            guard WaitForSingleObject(handle, 0) == 0 else { return nil }
            var code: DWORD = 0
            return GetExitCodeProcess(handle, &code) ? code : nil
        }

        func waitExit(timeout: TimeInterval) async -> DWORD? {
            _ = await WindowsSelftest.waitUntil(timeout: timeout) { self.exitCode != nil }
            return exitCode
        }

        func waitReady(timeout: TimeInterval) async -> Bool {
            guard let ready else { return true }
            return await WindowsSelftest.waitUntil(timeout: timeout) { WaitForSingleObject(ready, 0) == 0 }
        }

        func kill() { _ = TerminateProcess(handle, 9) }

        func close() {
            _ = CloseHandle(handle)
            if let ready { _ = CloseHandle(ready) }
        }
    }

    static func executablePath() -> String {
        var buffer = [UInt16](repeating: 0, count: 32_768)
        let n = Int(GetModuleFileNameW(nil, &buffer, DWORD(buffer.count)))
        return String(decoding: buffer.prefix(n), as: UTF16.self)
    }

    // MARK: - small helpers

    static func nowMs() -> Double {
        var counter = LARGE_INTEGER(), frequency = LARGE_INTEGER()
        _ = QueryPerformanceCounter(&counter)
        _ = QueryPerformanceFrequency(&frequency)
        return Double(counter.QuadPart) * 1000 / Double(frequency.QuadPart)
    }

    static func onThread(_ body: @escaping @Sendable () -> Void) { Thread(block: body).start() }

    @MainActor static func waitUntil(timeout: TimeInterval, poll: TimeInterval = 0.02, _ condition: () -> Bool) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition() {
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: UInt64(poll * 1_000_000_000))
        }
        return true
    }

    /// Waits until `condition` has held for `quiet` seconds in a row.
    @MainActor static func waitStable(timeout: TimeInterval, quiet: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        var since: Date?
        while Date() < deadline {
            if condition() {
                let start = since ?? Date()
                since = start
                if Date().timeIntervalSince(start) >= quiet { return true }
            } else {
                since = nil
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    private static func modification(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    static func plistValue(_ url: URL, _ key: String) -> String? {
        guard let data = try? Data(contentsOf: url),
              let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else { return nil }
        return dict[key] as? String
    }

    private static func onMain(_ hits: [Hit], _ main: DWORD) -> Bool { !hits.isEmpty && hits.allSatisfy { $0.tid == main } }
    private static func maxMs(_ hits: [Hit]) -> Double { hits.map(\.ms).max() ?? -1 }

    private static func summary(_ hits: [Hit], _ main: DWORD, of total: Int) -> String {
        let sorted = hits.map(\.ms).sorted()
        let median = sorted.isEmpty ? -1 : sorted[sorted.count / 2]
        return "n=\(hits.count)/\(total) on_main=\(hits.filter { $0.tid == main }.count) median_ms=\(f2(median)) "
            + "max_ms=\(f2(sorted.last ?? -1))"
    }

    private static func f2(_ value: Double) -> String { String(format: "%.2f", value) }
    private static func hex(_ values: [UInt32]) -> String { "[" + values.map { "0x" + String($0, radix: 16) }.joined(separator: ", ") + "]" }
    static func describe(_ code: DWORD?) -> String { code.map { String($0) } ?? "still running" }
}

/// Per-thread context switches (`NtQuerySystemInformation(SystemProcessInformation)`, the wakeup count) and cycles
/// (`QueryThreadCycleTime`, exact), read only at the window's edges from a thread of its own (F20).
enum IdleSampler {
    struct Sample: Sendable {
        let layoutOK: Bool
        let mainFound: Bool
        let mainContextSwitches: Int
        let mainCycles: UInt64
        let processCycles: UInt64
        let threadCount: Int
        let busy: String
    }

    private struct Snapshot {
        var contextSwitches: [UInt32: UInt32] = [:]
        var cycles: [UInt32: UInt64] = [:]
        var processCycles: UInt64 = 0
        var layoutOK = true
    }

    private typealias NtQuery = @convention(c) (UInt32, UnsafeMutableRawPointer?, UInt32, UnsafeMutablePointer<UInt32>?) -> Int32
    private typealias ThreadCycles = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt64>?) -> Int32
    private typealias ProcessCycles = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt64>?) -> Int32

    static func measure(seconds: Double, mainThread: DWORD) async -> Sample? {
        await withCheckedContinuation { continuation in
            Thread {
                guard let a = snapshot() else { continuation.resume(returning: nil); return }
                Thread.sleep(forTimeInterval: seconds)
                guard let b = snapshot() else { continuation.resume(returning: nil); return }
                continuation.resume(returning: diff(a, b, mainThread: mainThread, sampler: GetCurrentThreadId()))
            }.start()
        }
    }

    private static func diff(_ a: Snapshot, _ b: Snapshot, mainThread: DWORD, sampler: DWORD) -> Sample {
        var busy: [(tid: UInt32, cs: Int, cycles: UInt64)] = []
        for (tid, cs) in b.contextSwitches {
            let dcs = Int(cs) - Int(a.contextSwitches[tid] ?? 0)
            let dcy = (b.cycles[tid] ?? 0) &- (a.cycles[tid] ?? 0)
            if dcs > 0 || dcy > 0 { busy.append((tid, dcs, dcy)) }
        }
        busy.sort { $0.cycles > $1.cycles }
        let main = UInt32(mainThread)
        let mainCS = b.contextSwitches[main].map { Int($0) - Int(a.contextSwitches[main] ?? 0) } ?? -1
        let mainCycles = (b.cycles[main] ?? 0) &- (a.cycles[main] ?? 0)
        let text = busy.prefix(10).map { t -> String in
            let who = t.tid == main ? "main" : t.tid == UInt32(sampler) ? "sampler" : "\(t.tid) \(label(t.tid))"
            return "\(who):cs=\(t.cs),cycles=\(t.cycles)\(a.contextSwitches[t.tid] == nil ? ",new" : "")"
        }.joined(separator: "; ")
        return Sample(layoutOK: a.layoutOK && b.layoutOK, mainFound: b.contextSwitches[main] != nil,
                      mainContextSwitches: mainCS, mainCycles: mainCycles,
                      processCycles: b.processCycles &- a.processCycles, threadCount: b.contextSwitches.count, busy: text)
    }

    private typealias QueryThread = @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafeMutableRawPointer?, UInt32,
                                                    UnsafeMutablePointer<UInt32>?) -> Int32
    private typealias ThreadDescription = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<PWSTR?>?) -> Int32

    /// Who a thread is: its description (`GetThreadDescription`) and the module + offset of its start routine
    /// (`NtQueryInformationThread(ThreadQuerySetWin32StartAddress)`), read after the window closed.
    private static func label(_ tid: UInt32) -> String {
        guard let h = OpenThread(0x0040 | 0x0800 /* QUERY_INFORMATION | QUERY_LIMITED_INFORMATION */, false, tid) else {
            return "(no access)"
        }
        defer { _ = CloseHandle(h) }
        var parts: [String] = []
        if let describe = WinDynamic.symbol("kernel32.dll", "GetThreadDescription", as: ThreadDescription.self) {
            var text: PWSTR?
            if describe(h, &text) >= 0, let text {
                let name = String(decodingCString: text, as: UTF16.self)
                if !name.isEmpty { parts.append("'\(name)'") }
                _ = LocalFree(text)
            }
        }
        if let query = WinDynamic.symbol("ntdll.dll", "NtQueryInformationThread", as: QueryThread.self) {
            var start: UInt = 0
            if query(h, 9 /* ThreadQuerySetWin32StartAddress */, &start, UInt32(MemoryLayout<UInt>.size), nil) >= 0, start != 0 {
                parts.append("start=" + winModuleOffset(start))
            }
        }
        return parts.isEmpty ? "(unnamed)" : parts.joined(separator: " ")
    }

    private static func snapshot() -> Snapshot? {
        guard let query = WinDynamic.symbol("ntdll.dll", "NtQuerySystemInformation", as: NtQuery.self),
              let threadCycles = WinDynamic.symbol("kernel32.dll", "QueryThreadCycleTime", as: ThreadCycles.self),
              let processCycles = WinDynamic.symbol("kernel32.dll", "QueryProcessCycleTime", as: ProcessCycles.self)
        else { return nil }
        var snap = Snapshot()
        let me = UInt(GetCurrentProcessId())
        var size: UInt32 = 1 << 20
        while true {
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
            defer { buffer.deallocate() }
            var needed: UInt32 = 0
            let status = query(5 /* SystemProcessInformation */, buffer, size, &needed)
            if status == Int32(bitPattern: 0xC000_0004) /* STATUS_INFO_LENGTH_MISMATCH */ {
                size = max(size * 2, needed + 65_536)
                continue
            }
            guard status >= 0 else { return nil }
            // x64 layout: SYSTEM_PROCESS_INFORMATION is 0x100 bytes (NumberOfThreads at 4, UniqueProcessId at 0x50),
            // then SYSTEM_THREAD_INFORMATION entries of 0x50 bytes (ClientId at 40/48, ContextSwitches at 64).
            var offset = 0
            while true {
                let next = Int(buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                let threads = Int(buffer.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self))
                if buffer.loadUnaligned(fromByteOffset: offset + 0x50, as: UInt.self) == me {
                    for t in 0..<threads {
                        let base = offset + 0x100 + t * 0x50
                        let owner = buffer.loadUnaligned(fromByteOffset: base + 40, as: UInt.self)
                        let tid = UInt32(truncatingIfNeeded: buffer.loadUnaligned(fromByteOffset: base + 48, as: UInt.self))
                        if owner != me { snap.layoutOK = false }
                        snap.contextSwitches[tid] = buffer.loadUnaligned(fromByteOffset: base + 64, as: UInt32.self)
                    }
                }
                if next == 0 { break }
                offset += next
            }
            break
        }
        for tid in snap.contextSwitches.keys {
            guard let h = OpenThread(0x0800 /* THREAD_QUERY_LIMITED_INFORMATION */, false, tid) else { continue }
            var cycles: UInt64 = 0
            if threadCycles(h, &cycles) != 0 { snap.cycles[tid] = cycles }
            _ = CloseHandle(h)
        }
        var cycles: UInt64 = 0
        if processCycles(GetCurrentProcess(), &cycles) != 0 { snap.processCycles = cycles }
        return snap
    }
}

/// The loaded module an address falls in, and the offset: `Foundation.dll+0x1a2b`.
private func winModule(_ address: UInt) -> (name: String, base: UInt)? {
    var module: HMODULE?
    // GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT
    guard GetModuleHandleExW(0x4 | 0x2, UnsafePointer<WCHAR>(bitPattern: address), &module), let module else { return nil }
    var buffer = [UInt16](repeating: 0, count: 1024)
    let n = Int(GetModuleFileNameW(module, &buffer, DWORD(buffer.count)))
    let path = String(decoding: buffer.prefix(n), as: UTF16.self)
    return (path.split(separator: "\\").last.map(String.init) ?? path, UInt(bitPattern: module))
}

private func winModuleOffset(_ address: UInt) -> String {
    guard let module = winModule(address) else { return "0x" + String(address, radix: 16) }
    return module.name + "+0x" + String(address &- module.base, radix: 16)
}

/// Finds what holds the main thread. A ping goes to the main queue every few milliseconds; while one is overdue by
/// more than 30 ms the main thread is stalled, and the probe copies its instruction pointer and the top of its stack.
/// The thread is suspended only for that copy, and nothing is allocated meanwhile, so a heap lock the main thread
/// holds cannot deadlock the probe. `stop()` symbolizes the copies (dbghelp, with the exe's PDB when present): the
/// frames seen in most samples of the longest stall name the work.
private final class MainStallProbe: @unchecked Sendable {
    private static let thresholdMs = 30.0
    private static let maxSamples = 400
    private static let stackBytes = 16 * 1024
    private static let slotBytes = 16 + stackBytes

    private typealias StackLimits = @convention(c) (UnsafeMutablePointer<UInt>?, UnsafeMutablePointer<UInt>?) -> Void

    private let mainThread: HANDLE
    private let stackHigh: UInt
    private let startedAt = WindowsSelftest.nowMs()
    private let samples = UnsafeMutableRawPointer.allocate(byteCount: maxSamples * slotBytes, alignment: 16)
    private let lock = NSLock()
    private var stopRequested = false
    private var finished = false
    private var serviced = 0
    // Written by the probe thread only; read after `finished`.
    private var sampleCount = 0
    private var stalls: [(start: Double, end: Double, first: Int, last: Int)] = []

    private init(mainThread: HANDLE, stackHigh: UInt) {
        self.mainThread = mainThread
        self.stackHigh = stackHigh
    }

    /// On the main thread: it reads its own stack limits.
    @MainActor static func start(mainThread id: DWORD) -> MainStallProbe? {
        guard let limits = WinDynamic.symbol("kernel32.dll", "GetCurrentThreadStackLimits", as: StackLimits.self),
              let handle = OpenThread(0x0002 | 0x0008 | 0x0040, false, id)  // SUSPEND_RESUME | GET_CONTEXT | QUERY_INFORMATION
        else { return nil }
        var low: UInt = 0, high: UInt = 0
        limits(&low, &high)
        let probe = MainStallProbe(mainThread: handle, stackHigh: high)
        Thread { probe.loop() }.start()
        return probe
    }

    @MainActor func stop() async -> (longestMs: Int, detail: String) {
        requestStop()
        _ = await WindowsSelftest.waitUntil(timeout: 5) { self.isFinished }
        return isFinished ? report() : (longestMs: 0, detail: "probe thread did not stop")
    }

    private func requestStop() { lock.lock(); stopRequested = true; lock.unlock() }
    private var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    private var isStopping: Bool { lock.lock(); defer { lock.unlock() }; return stopRequested }
    private func markServiced(_ seq: Int) { lock.lock(); serviced = max(serviced, seq); lock.unlock() }
    private func hasServiced(_ seq: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return serviced >= seq }

    private func loop() {
        let context = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<CONTEXT>.size, alignment: 64)
            .bindMemory(to: CONTEXT.self, capacity: 1)
        context.initialize(to: CONTEXT())
        defer { context.deallocate() }
        var seq = 0
        var sentAt = 0.0
        var stallStart: Double?
        var stallFirst = 0
        while !isStopping {
            let now = WindowsSelftest.nowMs()
            if seq == 0 || hasServiced(seq) {
                if let start = stallStart {
                    stalls.append((start, now, stallFirst, sampleCount))
                    stallStart = nil
                }
                seq += 1
                let ping = seq
                sentAt = now
                DispatchQueue.main.async { self.markServiced(ping) }
            } else if now - sentAt > Self.thresholdMs {
                if stallStart == nil { stallStart = sentAt; stallFirst = sampleCount }
                if sampleCount < Self.maxSamples { capture(context) }
            }
            Sleep(2)
        }
        if let start = stallStart { stalls.append((start, WindowsSelftest.nowMs(), stallFirst, sampleCount)) }
        lock.lock(); finished = true; lock.unlock()
    }

    /// No allocation between SuspendThread and ResumeThread.
    private func capture(_ context: UnsafeMutablePointer<CONTEXT>) {
        let slot = samples + sampleCount * Self.slotBytes
        context.pointee = CONTEXT()
        context.pointee.ContextFlags = 0x0010_000B  // CONTEXT_FULL (AMD64)
        guard SuspendThread(mainThread) != DWORD.max else { return }
        if GetThreadContext(mainThread, context) {
            let rsp = UInt(context.pointee.Rsp)
            let n = rsp < stackHigh ? min(UInt(Self.stackBytes), stackHigh - rsp) : 0
            if n > 0, let source = UnsafeRawPointer(bitPattern: rsp) { (slot + 16).copyMemory(from: source, byteCount: Int(n)) }
            slot.storeBytes(of: UInt64(context.pointee.Rip), as: UInt64.self)
            slot.storeBytes(of: UInt64(n), toByteOffset: 8, as: UInt64.self)
            sampleCount += 1
        }
        _ = ResumeThread(mainThread)
    }

    private func report() -> (longestMs: Int, detail: String) {
        let durations = stalls.map { Int(($0.end - $0.start).rounded()) }
        guard let longest = stalls.max(by: { $0.end - $0.start < $1.end - $1.start }) else {
            return (longestMs: 0, detail: "no main-thread stall over \(Int(Self.thresholdMs)) ms between launch and a settled store")
        }
        let symbols = Symbolizer()
        var frames: [String: Int] = [:]
        var leaves: [String: Int] = [:]
        for i in longest.first..<longest.last {
            let slot = samples + i * Self.slotBytes
            let leaf = symbols.name(UInt(slot.load(as: UInt64.self)))
            leaves[leaf, default: 0] += 1
            var seen: Set<String> = [leaf]
            let n = Int(slot.load(fromByteOffset: 8, as: UInt64.self))
            var offset = 0
            var found = 0
            while offset + 8 <= n, found < 40 {  // return addresses into code, nearest frames first (a heuristic scan)
                let value = UInt((slot + 16).loadUnaligned(fromByteOffset: offset, as: UInt64.self))
                offset += 8
                guard symbols.isCode(value) else { continue }
                found += 1
                seen.insert(symbols.name(value))
            }
            for frame in seen { frames[frame, default: 0] += 1 }
        }
        func top(_ counts: [String: Int], _ k: Int) -> String {
            counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(k)
                .map { "\($0.value)x \($0.key)" }.joined(separator: " | ")
        }
        let start = Int((longest.start - startedAt).rounded())
        return (longestMs: durations.max() ?? 0, detail: "stalls_over_\(Int(Self.thresholdMs))ms=\(stalls.count) ms=\(durations) longest=\(durations.max() ?? 0) ms at +\(start) ms "
            + "samples=\(longest.last - longest.first) leaf=[\(top(leaves, 4))] frames=[\(top(frames, 24))]")
    }
}

/// dbghelp names for addresses: `module!symbol+0xoffset`, or `module+0xoffset` without symbols.
private final class Symbolizer {
    private typealias SetOptions = @convention(c) (UInt32) -> UInt32
    private typealias Initialize = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt16>?, Int32) -> Int32
    private typealias FromAddress = @convention(c) (UnsafeMutableRawPointer?, UInt64, UnsafeMutablePointer<UInt64>?,
                                                    UnsafeMutableRawPointer?) -> Int32
    private static let maxName = 1024
    private let fromAddress: FromAddress?
    private let process = GetCurrentProcess()
    private let info = UnsafeMutableRawPointer.allocate(byteCount: 88 + 2 * maxName, alignment: 8)  // SYMBOL_INFOW
    private var names: [UInt: String] = [:]
    private var codePages: [UInt: Bool] = [:]

    init() {
        if let setOptions = WinDynamic.symbol("dbghelp.dll", "SymSetOptions", as: SetOptions.self),
           let initialize = WinDynamic.symbol("dbghelp.dll", "SymInitializeW", as: Initialize.self) {
            _ = setOptions(0x2 | 0x4 | 0x200 | 0x8_0000)  // UNDNAME | DEFERRED_LOADS | FAIL_CRITICAL_ERRORS | NO_PROMPTS
            fromAddress = initialize(process, nil, 1) != 0
                ? WinDynamic.symbol("dbghelp.dll", "SymFromAddrW", as: FromAddress.self) : nil
        } else {
            fromAddress = nil
        }
    }

    deinit { info.deallocate() }

    /// Executable memory of a loaded image (a candidate return address).
    func isCode(_ address: UInt) -> Bool {
        let page = address >> 12
        if let known = codePages[page] { return known }
        var mbi = MEMORY_BASIC_INFORMATION()
        let ok = VirtualQuery(UnsafeRawPointer(bitPattern: address), &mbi, SIZE_T(MemoryLayout<MEMORY_BASIC_INFORMATION>.size)) != 0
            && mbi.State == 0x1000 /* MEM_COMMIT */ && mbi.Type == 0x100_0000 /* MEM_IMAGE */ && mbi.Protect & 0xF0 != 0
        codePages[page] = ok
        return ok
    }

    func name(_ address: UInt) -> String {
        if let known = names[address] { return known }
        var text = winModuleOffset(address)
        if let fromAddress {
            info.initializeMemory(as: UInt8.self, repeating: 0, count: 88)
            info.storeBytes(of: UInt32(88), as: UInt32.self)  // SizeOfStruct
            info.storeBytes(of: UInt32(Self.maxName), toByteOffset: 80, as: UInt32.self)  // MaxNameLen
            var displacement: UInt64 = 0
            if fromAddress(process, UInt64(address), &displacement, info) != 0 {
                let length = min(Int(info.load(fromByteOffset: 76, as: UInt32.self)), Self.maxName)  // NameLen
                let chars = UnsafeBufferPointer(start: (info + 84).assumingMemoryBound(to: UInt16.self), count: length)
                text = (winModule(address)?.name ?? "?") + "!" + String(decoding: chars, as: UTF16.self)
                    + "+0x" + String(displacement, radix: 16)
            }
        }
        names[address] = text
        return text
    }
}
#endif
