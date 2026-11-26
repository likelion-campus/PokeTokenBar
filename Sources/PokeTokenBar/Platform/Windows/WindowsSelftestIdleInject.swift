#if os(Windows)
import Foundation
import WinSDK

/// Selftest-only fault injections for the idle windows, and the counter's own self-check. Both exist to prove that the judging of the idle
/// windows (`IdleWakeJudge`, printed beside today's verdict) still fails what it is for.
///
/// `PTB_SELFTEST_INJECT=<name>` comes from the workflow input `idle_inject`, which `windows-app.yml` forces to '' in release mode. It is
/// read only under `--selftest` and only on the runner (`WindowsSelftest.onCI`), so a person's `--selftest` never reaches an injection.
/// Every injection stays inside this process: a timer, a main-queue block, a sleeping thread. None changes a system-wide setting or makes
/// a request.
enum IdleInject {
    static let names = ["hidden-timer", "blocking-waits", "mainqueue-loop", "poll-waits", "no-wake-observer"]

    /// The injection asked for; nil when none, off the runner or outside `--selftest`.
    static var name: String? {
        guard WindowsSelftest.onCI, CommandLine.arguments.contains("--selftest") else { return nil }
        let value = (ProcessInfo.processInfo.environment["PTB_SELFTEST_INJECT"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// What one judged window is armed with (main thread only; the blocks check `stopped`).
    final class Armed: @unchecked Sendable {
        fileprivate var timer: Timer?
        fileprivate var task: Task<Void, Never>?
        fileprivate var stopped = false
        func disarm() {
            stopped = true
            timer?.invalidate()
            task?.cancel()
        }
    }

    /// Arms the injection (if any applies to this kind of window: `idle`, `team`, `modal`, `kit`) right before the window is measured.
    @MainActor static func arm(_ kind: String) -> Armed {
        let armed = Armed()
        switch name {
        case "hidden-timer":
            // An unnamed 1 s repeating timer on the main run loop: nothing counts it. (`Timer(fire:interval:repeats:)`, never the interval initializer.)
            let timer = Timer(fire: Date(timeIntervalSinceNow: 1), interval: 1, repeats: true) { _ in }
            RunLoop.main.add(timer, forMode: .default)
            armed.timer = timer
        case "mainqueue-loop":
            armed.task = Task { @MainActor in
                while !Task.isCancelled { try? await Task.sleep(nanoseconds: 100_000_000) }
            }
        case "blocking-waits" where kind == "idle":
            // One main-queue block that waits 50 times on an event a worker sets every ~2 ms: ~50 switches, one wake.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { if !armed.stopped { blockingWaits(50) } }
        case "poll-waits" where kind == "idle":
            // 300 short sleeps inside one block: ~300 switches, one wake.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                for _ in 0..<300 where !armed.stopped { Thread.sleep(forTimeInterval: 0.015) }
            }
        default:
            break
        }
        return armed
    }

    /// Blocks the calling thread `count` times on an event a worker thread sets every ~2 ms.
    static func blockingWaits(_ count: Int) {
        let event = DispatchSemaphore(value: 0)
        Thread {
            for _ in 0..<count {
                Thread.sleep(forTimeInterval: 0.002)
                event.signal()
            }
        }.start()
        for _ in 0..<count { event.wait() }
    }
}

/// Ticks of the counter check's own timer (main thread only).
private final class WakeTally: @unchecked Sendable {
    var fires = 0
}

extension WindowsSelftest {
    /// Runs first in a selftest; the injection, if one is set, is recorded as a check of its own so that a run's log says what it ran.
    @MainActor static func installWakeCounter(_ r: Recorder) {
        if let name = IdleInject.name {
            r.add("idle.inject", IdleInject.names.contains(name), "PTB_SELFTEST_INJECT=\(name) (runner only; valid: \(IdleInject.names.joined(separator: ", ")))")
        }
        if IdleInject.name != "no-wake-observer" { WinRunLoopWakes.install() }
    }

    /// Judged on every run, about 3 s: the run-loop wake counter really counts wakes. A 0.25 s timer runs for 2.6 s: the count must rise by
    /// at least the fires minus one while the loop passes stay at 2 or fewer (a timer fire is a wake but no pass). Then one main-queue block
    /// waits 50 times on an event: ~50 context switches, but the count rises by 3 at most. A counter that is missing, counts nothing, counts
    /// polls or counts switches fails here instead of passing R3 of the shadow judge with 0 wakes.
    @MainActor static func wakeCounterCheck(_ r: Recorder, _ app: WindowsAppDelegate) async {
        guard WinRunLoopWakes.count != nil else {
            r.add("idle.wakeCounter", false, "no wake observer installed (WinRunLoopWakes.count is nil)")
            return
        }
        let main = UInt32(WindowsApp.mainThreadID)
        var attempts: [String] = []
        var timerOK = false
        for attempt in 1...3 where !timerOK {
            // A store refresh or a settings write in the window adds passes: wait for a quiet state, and try again when it still landed.
            _ = await waitStable(timeout: 30, quiet: 2) { !app.store.isRefreshing && !WinDefaultsSync.isSyncPending }
            let refreshes0 = app.refreshCount
            let w0 = WinRunLoopWakes.count ?? 0, p0 = WinMainLoop.iterations
            let tally = WakeTally()
            let timer = Timer(fire: Date(timeIntervalSinceNow: 0.25), interval: 0.25, repeats: true) { _ in tally.fires += 1 }
            RunLoop.main.add(timer, forMode: .default)
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            timer.invalidate()
            let dw = (WinRunLoopWakes.count ?? 0) - w0, dp = WinMainLoop.iterations - p0
            let refreshed = IdleBurstAttribution.refreshesInWindow(countBefore: refreshes0, countAfter: app.refreshCount, runningAtEnd: app.store.isRefreshing)
            timerOK = dw >= tally.fires - 1 && tally.fires >= 5 && dp <= 2
            attempts.append("#\(attempt) timer fires=\(tally.fires) wakes=+\(dw) passes=+\(dp) refreshes=\(refreshed)")
        }
        let waitsStart = IdleSampler.snapshot()?.contextSwitches[main]
        let wakes0 = WinRunLoopWakes.count ?? 0
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                IdleInject.blockingWaits(50)
                done.resume()
            }
        }
        let waitsWakes = (WinRunLoopWakes.count ?? 0) - wakes0
        let waitsCS = waitsStart.flatMap { a in IdleSampler.snapshot()?.contextSwitches[main].map { Int($0) - Int(a) } }
        let waitsOK = waitsWakes <= 3 && (waitsCS ?? 0) >= 10
        r.add("idle.wakeCounter", timerOK && waitsOK,
              "\(attempts.joined(separator: "; ")) (pass: wakes >= fires - 1, fires >= 5, passes <= 2); "
                + "50 waits in one main-queue block: wakes=+\(waitsWakes) (<= 3) main_thread_cs=\(waitsCS.map { "+\($0)" } ?? "unavailable") (>= 10)")
    }
}
#endif
