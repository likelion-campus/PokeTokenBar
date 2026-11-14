#if os(Windows)
import Foundation
import FoundationNetworking
import WinSDK

/// `--selftest-waker-hunt <out.json> [window seconds]`: attributes the two ~1 Hz threads seen at idle since Task 5 (a Windows
/// thread-pool worker and a libdispatch root-queue thread). libdispatch on Windows services every dispatch timer through a
/// thread-pool timer (`CreateThreadpoolTimer`, event_windows.c), which hands the fire to a dispatch worker, so the pair
/// means "some dispatch timer fires about once a second". The helper starts from a clean process (main loop only) and
/// changes one thing at a time, measuring each state's idle window by cycles and context switches:
///   bare        nothing started                                  -> are the wakers ours, libdispatch's or the sampler's?
///   own-session one GET on a fresh ephemeral URLSession, then idle  -> does a cached libcurl connection wake the process?
///   invalidated the same session `invalidateAndCancel()`ed          -> does closing the session stop it?
///   shared      one GET on `URLSession.shared`, then idle           -> the sessions the app really uses (cannot be invalidated)
/// After a window that shows wakers, their stacks are sampled: the thread's cycle counter is polled and, as soon as it moves,
/// the thread is suspended just long enough to copy its instruction pointer and stack top (no allocation in between), then
/// symbolized with dbghelp as the main-thread stall probe does. Diagnostics only: nothing here runs in the shipped app.
enum WindowsSelftestWakers {
    private struct Phase: Codable { let phase: String; let detail: String }

    @MainActor static func run(_ args: [String]) -> Never {
        guard let out = args.first else { WindowsApp.exit(2, .helper) }
        let seconds = args.count > 1 ? Double(args[1]) ?? 30 : 30
        _ = WinMainLoop.prepare()
        Task { @MainActor in
            var phases: [Phase] = []
            func note(_ phase: String, _ detail: String) {
                phases.append(Phase(phase: phase, detail: detail))
                AppLog.write("waker-hunt \(phase): \(detail)")
            }
            // After a window with wakers: their stacks, when the window showed any.
            func window(_ name: String) async {
                guard let s = await IdleSampler.measure(seconds: seconds, mainThread: WindowsApp.mainThreadID) else {
                    note(name, "measurement failed"); return
                }
                let others = s.active.filter { $0.tid != UInt32(WindowsApp.mainThreadID) }
                let wakers = others.filter { Double($0.cs) >= seconds * 0.5 }
                let total = others.reduce(0) { $0 + $1.cs }
                note(name, "\(Int(seconds)) s: main_cs=\(s.mainContextSwitches) other_threads_cs_total=\(total) "
                     + "wakers(>=0.5 Hz)=\(wakers.count) process_cycles=\(s.processCycles) threads=\(s.threadCount) busy=[\(s.busy)]")
                if !wakers.isEmpty {
                    note(name + ".stacks", await StackSampler.sample(tids: wakers.map(\.tid), seconds: 40))
                }
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await window("bare")

            let session = URLSession(configuration: .ephemeral)
            let get = await fetch(session, "https://api.github.com/zen")
            note("own-session.request", get)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await window("own-session")

            session.invalidateAndCancel()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await window("invalidated")

            note("shared.request", await fetch(URLSession.shared, "https://api.github.com/zen"))
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await window("shared")

            // Report only (Task 12): how long the main thread waits in Foundation's settings sync right after a write.
            let defaults = WinDefaultsSync.makeAppDefaults()  // the selftest's own suite, never the user's plist
            var syncMs: [Double] = []
            for i in 0..<12 {
                defaults.set("v\(i)", forKey: "ptb.hunt.key")
                let t0 = WindowsSelftest.nowMs()
                WinDefaultsSync.flushNow()
                syncMs.append(WindowsSelftest.nowMs() - t0)
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            defaults.removeObject(forKey: "ptb.hunt.key")
            WinDefaultsSync.flushNow()
            let sorted = syncMs.sorted()
            note("settings-sync", "main-thread flushNow() after a write, 12 runs, ms: min=\(String(format: "%.1f", sorted[0])) "
                 + "median=\(String(format: "%.1f", sorted[6])) max=\(String(format: "%.1f", sorted[11])) all=\(syncMs.map { String(format: "%.1f", $0) })")

            if let data = try? JSONEncoder().encode(phases) { try? data.write(to: URL(fileURLWithPath: out)) }
            WindowsApp.exit(0, .helper)
        }
        WinMainLoop.run(.cfRunLoopWithMessages) { false }
        WindowsApp.exit(0, .helper)
    }

    private static func fetch(_ session: URLSession, _ url: String) async -> String {
        var request = URLRequest(url: URL(string: url)!)
        request.timeoutInterval = 15
        request.setValue("PokeTokenBar-selftest", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            return "HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1) \(data.count) bytes"
        } catch {
            return "failed: \(error)"
        }
    }
}

/// Polls the given threads' cycle counters and copies their stacks when one moves (it just ran, or still runs).
private final class StackSampler: @unchecked Sendable {
    private static let stackBytes = 8 * 1024
    private static let slotBytes = 16 + stackBytes
    private static let maxPerThread = 150

    private struct Target {
        let tid: UInt32
        let handle: HANDLE
        var last: UInt64
        var count = 0
    }

    private typealias Cycles = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt64>?) -> Int32

    static func sample(tids: [UInt32], seconds: Double) async -> String {
        await withCheckedContinuation { continuation in
            Thread { continuation.resume(returning: run(tids, seconds)) }.start()
        }
    }

    private static func run(_ tids: [UInt32], _ seconds: Double) -> String {
        guard let queryCycles = WinDynamic.symbol("kernel32.dll", "QueryThreadCycleTime", as: Cycles.self) else { return "QueryThreadCycleTime unavailable" }
        var targets: [Target] = []
        for tid in tids {
            // SUSPEND_RESUME | GET_CONTEXT | QUERY_INFORMATION | QUERY_LIMITED_INFORMATION
            guard let h = OpenThread(0x0002 | 0x0008 | 0x0040 | 0x0800, false, tid) else { continue }
            var c: UInt64 = 0
            _ = queryCycles(h, &c)
            targets.append(Target(tid: tid, handle: h, last: c))
        }
        if targets.isEmpty { return "no waker thread could be opened" }
        let slots = UnsafeMutableRawPointer.allocate(byteCount: targets.count * maxPerThread * slotBytes, alignment: 16)
        defer { slots.deallocate() }
        let context = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<CONTEXT>.size, alignment: 64)
            .bindMemory(to: CONTEXT.self, capacity: 1)
        context.initialize(to: CONTEXT())
        defer { context.deallocate() }
        var polls = 0
        let end = WindowsSelftest.nowMs() + seconds * 1000
        while WindowsSelftest.nowMs() < end {
            for i in targets.indices {
                var c: UInt64 = 0
                guard queryCycles(targets[i].handle, &c) != 0, c != targets[i].last else { continue }
                targets[i].last = c
                guard targets[i].count < maxPerThread else { continue }
                let slot = slots + (i * maxPerThread + targets[i].count) * slotBytes
                context.pointee = CONTEXT()
                context.pointee.ContextFlags = 0x0010_000B  // CONTEXT_FULL (AMD64)
                guard SuspendThread(targets[i].handle) != DWORD.max else { continue }
                if GetThreadContext(targets[i].handle, context) {
                    let rsp = UInt(context.pointee.Rsp)
                    var mbi = MEMORY_BASIC_INFORMATION()
                    var n = 0
                    // Copy only committed, readable stack memory: up to the end of the region holding RSP.
                    if VirtualQuery(UnsafeRawPointer(bitPattern: rsp), &mbi, SIZE_T(MemoryLayout<MEMORY_BASIC_INFORMATION>.size)) != 0,
                       mbi.State == 0x1000 {
                        let regionEnd = UInt(bitPattern: mbi.BaseAddress) + UInt(mbi.RegionSize)
                        n = Int(min(UInt(stackBytes), regionEnd > rsp ? regionEnd - rsp : 0))
                    }
                    if n > 0, let source = UnsafeRawPointer(bitPattern: rsp) { (slot + 16).copyMemory(from: source, byteCount: n) }
                    slot.storeBytes(of: UInt64(context.pointee.Rip), as: UInt64.self)
                    slot.storeBytes(of: UInt64(n), toByteOffset: 8, as: UInt64.self)
                    targets[i].count += 1
                }
                _ = ResumeThread(targets[i].handle)
            }
            polls += 1
            Sleep(0)
        }
        defer { for t in targets { _ = CloseHandle(t.handle) } }
        return report(targets.map { ($0.tid, $0.count) }, slots, polls, seconds)
    }

    private static func report(_ targets: [(tid: UInt32, count: Int)], _ slots: UnsafeMutableRawPointer, _ polls: Int, _ seconds: Double) -> String {
        let symbols = Symbolizer()
        var lines: [String] = ["\(Int(seconds)) s, \(polls) polls"]
        for (i, target) in targets.enumerated() {
            var chains: [String: Int] = [:]
            var leaves: [String: Int] = [:]
            for k in 0..<target.count {
                let slot = slots + (i * maxPerThread + k) * slotBytes
                let leaf = symbols.name(UInt(slot.load(as: UInt64.self)))
                leaves[leaf, default: 0] += 1
                var frames = [leaf]
                let n = Int(slot.load(fromByteOffset: 8, as: UInt64.self))
                var offset = 0
                while offset + 8 <= n, frames.count < 12 {  // return addresses into code, nearest frames first (a heuristic scan)
                    let value = UInt((slot + 16).loadUnaligned(fromByteOffset: offset, as: UInt64.self))
                    offset += 8
                    if symbols.isCode(value) { frames.append(symbols.name(value)) }
                }
                chains[frames.joined(separator: " < "), default: 0] += 1
            }
            func top(_ counts: [String: Int], _ k: Int) -> String {
                counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(k)
                    .map { "\($0.value)x \($0.key)" }.joined(separator: " || ")
            }
            lines.append("thread \(target.tid) \(IdleSampler.label(target.tid)): samples=\(target.count) leaves=[\(top(leaves, 5))] chains=[\(top(chains, 4))]")
        }
        return lines.joined(separator: "\n")
    }
}
#endif
