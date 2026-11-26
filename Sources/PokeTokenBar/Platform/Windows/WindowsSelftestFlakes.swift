#if os(Windows)
import Foundation
import WinSDK

/// Support for the three formerly flaky selftest checks (`plaza.hover` / `plaza.cover`, `plaza.close`, `modalPump.idle`):
/// the held plaza tick, a typed handle table, a main-thread wake timeline, and the in-process repeat loops
/// (`PTB_SELFTEST_FLAKE_LOOP=N`, set by `windows-app.yml -f flake_loop=N`; 0 or unset = no loop). Each loop prints its
/// per-iteration values so a pass is a distribution, not one sample.

extension WindowsSelftest {
    /// The app being selftested (set by the checks that need its counters outside a function that is handed `app`).
    @MainActor static weak var selftestApp: WindowsAppDelegate?

    /// A plaza open/close cycle that leaks, leaks every time; background work (a TLS stack and its threads starting when the update
    /// or usage check first runs, a lazily started pool worker) lands in some cycles only (6 of 49 steps in run 43797111060, +1..+26
    /// handles each, all Threads/Events/WaitCompletionPackets/EtwRegistrations of NEW threads). So: leaking = EVERY step grew.
    static func handleLeak(counts: [Int]) -> Bool {
        let steps = zip(counts.dropFirst(), counts).map { $0 - $1 }
        return steps.count >= 3 && steps.allSatisfy { $0 > 0 }
    }
}

enum FlakeLoop {
    static var count: Int { Int(ProcessInfo.processInfo.environment["PTB_SELFTEST_FLAKE_LOOP"] ?? "") ?? 0 }
}

/// Holds the selftest plaza controller's 1 s focus tick (`PlazaWindowController.focusTickSleep`, the one seam that exists):
/// while held, the tick that would call `refreshRoster` waits after its sleep, so the selftest is the only writer of the
/// roster fixture. Released, it runs at once.
final class PlazaTickGate: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    func hold() { lock.lock(); held = true; lock.unlock() }
    func release() { lock.lock(); held = false; lock.unlock() }
    var isHeld: Bool { lock.lock(); defer { lock.unlock() }; return held }
    @MainActor func sleep(_ d: Duration) async {
        try? await Task.sleep(for: d)
        while isHeld, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(25)) }
    }
}

let plazaTickGate = PlazaTickGate()

// MARK: - a typed table of this process's handles

enum WinHandleTable {
    struct Snapshot {
        /// handle value -> "Type detail"
        var byValue: [UInt: String] = [:]
        var count: Int { byValue.count }
        var types: [String: Int] {
            var out: [String: Int] = [:]
            for v in byValue.values { out[String(v.prefix { $0 != " " }), default: 0] += 1 }
            return out
        }
    }

    private typealias NtQuery = @convention(c) (UInt32, UnsafeMutableRawPointer?, UInt32, UnsafeMutablePointer<UInt32>?) -> Int32
    private typealias NtQueryObject = @convention(c) (UnsafeMutableRawPointer?, UInt32, UnsafeMutableRawPointer?, UInt32, UnsafeMutablePointer<UInt32>?) -> Int32

    private static func text(_ buffer: UnsafeMutableRawPointer, unicodeStringAt offset: Int) -> String {
        let length = Int(buffer.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
        guard length > 0, let p = buffer.loadUnaligned(fromByteOffset: offset + 8, as: UnsafeMutableRawPointer?.self) else { return "" }
        return String(decoding: UnsafeBufferPointer(start: p.assumingMemoryBound(to: UInt16.self), count: length / 2), as: UTF16.self)
    }

    /// Every handle of this process by type (SystemExtendedHandleInformation + NtQueryObject), with the identity of the kinds that
    /// can be named without blocking: threads (id), files (path of a disk file; pipe / char otherwise), registry keys and other
    /// named kernel objects.
    static func snapshot() -> Snapshot? {
        guard let query = WinDynamic.symbol("ntdll.dll", "NtQuerySystemInformation", as: NtQuery.self),
              let object = WinDynamic.symbol("ntdll.dll", "NtQueryObject", as: NtQueryObject.self) else { return nil }
        var size: UInt32 = 1 << 20
        let me = UInt(GetCurrentProcessId())
        var snap = Snapshot()
        var typeNames: [UInt16: String] = [:]
        let scratch = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 16)
        defer { scratch.deallocate() }
        while true {
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
            defer { buffer.deallocate() }
            var needed: UInt32 = 0
            let status = query(64 /* SystemExtendedHandleInformation */, buffer, size, &needed)
            if status == Int32(bitPattern: 0xC000_0004) {
                size = max(size * 2, needed + 65_536)
                continue
            }
            guard status >= 0 else { return nil }
            let n = Int(buffer.loadUnaligned(fromByteOffset: 0, as: UInt.self))
            for i in 0..<n {
                let base = 16 + i * 40
                guard buffer.loadUnaligned(fromByteOffset: base + 8, as: UInt.self) == me else { continue }
                let value = buffer.loadUnaligned(fromByteOffset: base + 16, as: UInt.self)
                let typeIndex = buffer.loadUnaligned(fromByteOffset: base + 30, as: UInt16.self)
                guard let h = UnsafeMutableRawPointer(bitPattern: value) else { continue }
                var type = typeNames[typeIndex]
                if type == nil {
                    var ret: UInt32 = 0
                    if object(h, 2 /* ObjectTypeInformation */, scratch, 4096, &ret) >= 0 {
                        type = text(scratch, unicodeStringAt: 0)
                        typeNames[typeIndex] = type
                    }
                }
                let t = (type ?? "?").replacingOccurrences(of: " ", with: "_")
                var detail = ""
                switch t {
                case "Thread": detail = "#\(GetThreadId(h))"
                case "File":
                    switch GetFileType(h) {
                    case 1:
                        var path = [UInt16](repeating: 0, count: 520)
                        let len = GetFinalPathNameByHandleW(h, &path, DWORD(path.count), 0)
                        detail = len > 0 && Int(len) < path.count ? String(decoding: path.prefix(Int(len)), as: UTF16.self) : "disk(?)"
                    case 2: detail = "char"
                    case 3: detail = "pipe"
                    default: detail = "?"
                    }
                case "Key", "Event", "Mutant", "Section", "Semaphore", "Directory", "Timer", "Job":
                    var ret: UInt32 = 0
                    if object(h, 1 /* ObjectNameInformation */, scratch, 4096, &ret) >= 0 { detail = text(scratch, unicodeStringAt: 0) }
                default: break
                }
                snap.byValue[value] = detail.isEmpty ? t : "\(t) \(detail)"
            }
            break
        }
        return snap
    }

    /// "+17 [Event x3, Thread#4120 start=... x1, ...] -0 []" between two snapshots (handle values that appeared / vanished).
    static func diff(_ a: Snapshot, _ b: Snapshot, limit: Int = 14) -> String {
        func group(_ keys: [UInt], in s: Snapshot) -> String {
            var counts: [String: Int] = [:]
            for k in keys {
                var label = s.byValue[k] ?? "?"
                if label.hasPrefix("Thread #"), let tid = UInt32(label.dropFirst(8)) { label = "Thread#\(tid) " + IdleSampler.label(tid) }
                counts[label, default: 0] += 1
            }
            let parts = counts.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }.prefix(limit).map { "\($0.key) x\($0.value)" }
            return "[" + parts.joined(separator: ", ") + (counts.count > limit ? ", ..." : "") + "]"
        }
        let added = b.byValue.keys.filter { a.byValue[$0] == nil }, gone = a.byValue.keys.filter { b.byValue[$0] == nil }
        return "+\(added.count) \(group(added, in: b)) -\(gone.count) \(group(gone, in: a))"
    }

    static func typesText(_ s: Snapshot) -> String {
        s.types.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    }
}

// MARK: - the main thread's wakes over a window

enum IdleTimeline {
    struct Result: Sendable {
        let mainFound: Bool
        let mainContextSwitches: Int
        let mainCycles: UInt64
        /// "2.3s+3" = the main thread switched 3 times in the 100 ms sample that ended 2.3 s into the window.
        let wakes: String
        /// The same samples as numbers (`IdleBurstAttribution` matches them with what arrived).
        var samples: [IdleBurstAttribution.Wake] = []
    }

    /// Same reading as `IdleSampler.measure` (thread-of-its-own, snapshots at the edges) plus a snapshot every 100 ms for the timeline.
    static func measure(seconds: Double, mainThread: DWORD) async -> Result? {
        await withCheckedContinuation { continuation in
            Thread {
                guard let first = IdleSampler.snapshot() else { continuation.resume(returning: nil); return }
                let main = UInt32(mainThread)
                var last = first
                var wakes: [String] = []
                var samples: [IdleBurstAttribution.Wake] = []
                let start = Date()
                while Date().timeIntervalSince(start) < seconds {
                    Thread.sleep(forTimeInterval: 0.1)
                    guard let now = IdleSampler.snapshot() else { continuation.resume(returning: nil); return }
                    if let a = last.contextSwitches[main], let b = now.contextSwitches[main], b > a {
                        let t = Date().timeIntervalSince(start)
                        wakes.append(String(format: "%.1fs+%d", t, Int(b) - Int(a)))
                        samples.append(IdleBurstAttribution.Wake(t: t, cs: Int(b) - Int(a)))
                    }
                    last = now
                }
                let found = last.contextSwitches[main] != nil
                let cs = found ? Int(last.contextSwitches[main]!) - Int(first.contextSwitches[main] ?? 0) : -1
                let cycles = (last.cycles[main] ?? 0) &- (first.cycles[main] ?? 0)
                continuation.resume(returning: Result(mainFound: found, mainContextSwitches: cs, mainCycles: cycles, wakes: wakes.joined(separator: " "),
                                                      samples: samples))
            }.start()
        }
    }
}

extension WindowsSelftest {
    private static func fmt(_ values: [Int]) -> String { "[" + values.map(String.init).joined(separator: ",") + "]" }
    private static func histogram(_ values: [Int]) -> String {
        Dictionary(grouping: values, by: { $0 }).sorted { $0.key < $1.key }.map { "\($0.key)x\($0.value.count)" }.joined(separator: " ")
    }

    // MARK: A: plaza.hover / plaza.cover

    /// N iterations of the real hover and cover checks per phase. Phases: `gated` (the fixed setup: one writer), `fault` (3 iterations
    /// with the behaviour broken: every one must FAIL), `legacy` (the old setup: tick running + a 40 ms keeper re-writing the fixture).
    @MainActor static func flakeLoopPanels(
        _ r: Recorder, _ c: PlazaWindowController, _ roster: PlazaRosterModel, _ fixture: [PlazaRosterEntry],
        cover: (Bool) async -> (ok: Bool, line: String, pixels: Int, intact: Bool),
        hover: (Bool, Bool) async -> (ok: Bool, line: String, tools: Int, intact: Bool),
        dpi: (UInt32, Bool) async -> (ok: Bool, toolsOK: Bool, renders: Int, intact: Bool),
        dpiBack: () async -> Void
    ) async {
        let n = FlakeLoop.count
        typealias DpiRow = (ok: Bool, toolsOK: Bool, renders: Int, intact: Bool)
        func summary(_ name: String, _ phase: String, hovers: [(ok: Bool, tools: Int, intact: Bool)], covers: [(ok: Bool, pixels: Int, intact: Bool)], dpis: [DpiRow], expectFail: Bool) {
            let hoverOK = hovers.filter(\.ok).count, coverOK = covers.filter(\.ok).count, dpiOK = dpis.filter(\.ok).count
            let judged = expectFail ? (hoverOK == 0 && coverOK == 0 && dpiOK == 0) : (hoverOK == hovers.count && coverOK == covers.count && dpiOK == dpis.count)
            r.add(name, judged || name.hasSuffix(".legacy"),
                  "\(phase): N=\(hovers.count) hover pass \(hoverOK)/\(hovers.count) tools \(histogram(hovers.map(\.tools))) roster-not-fixture at read \(hovers.filter { !$0.intact }.count); "
                    + "cover pass \(coverOK)/\(covers.count) roster pixels \(histogram(covers.map(\.pixels))) roster-not-fixture \(covers.filter { !$0.intact }.count)"
                    + "; dpi pass \(dpiOK)/\(dpis.count) renders \(histogram(dpis.map(\.renders))) tool-rects-wrong \(dpis.filter { !$0.toolsOK }.count) roster-not-fixture \(dpis.filter { !$0.intact }.count)"
                    + (name.hasSuffix(".legacy") ? " (informational: the old setup)" : expectFail ? " (every iteration must fail)" : "")
                    + "; hover per iteration \(hovers.map { $0.ok ? "ok(\($0.tools))" : "FAIL(\($0.tools))" }.joined(separator: ","))"
                    + "; cover per iteration \(covers.map { $0.ok ? "ok" : "FAIL" }.joined(separator: ","))")
        }
        func run(_ phase: String, iterations: Int, fault: Bool) async -> ([(ok: Bool, tools: Int, intact: Bool)], [(ok: Bool, pixels: Int, intact: Bool)], [DpiRow]) {
            var hovers: [(ok: Bool, tools: Int, intact: Bool)] = [], covers: [(ok: Bool, pixels: Int, intact: Bool)] = [], dpis: [DpiRow] = []
            for i in 0..<iterations {
                let h = await hover(fault, false)
                hovers.append((h.ok, h.tools, h.intact))
                let cv = await cover(fault)
                covers.append((cv.ok, cv.pixels, cv.intact))
                dpis.append(await dpi(i % 2 == 0 ? 120 : 144, fault))
                await dpiBack()
            }
            return (hovers, covers, dpis)
        }
        let gated = await run("gated", iterations: n, fault: false)
        summary("flake.panels.gated", "gated (held tick, one writer)", hovers: gated.0, covers: gated.1, dpis: gated.2, expectFail: false)
        let faulty = await run("fault", iterations: 3, fault: true)
        summary("flake.panels.fault", "fault (roster emptied / card not opened)", hovers: faulty.0, covers: faulty.1, dpis: faulty.2, expectFail: true)

        plazaTickGate.release()   // the old setup: the tick runs, a keeper writes the fixture back every 40 ms
        let keeper = Task { @MainActor in
            while !Task.isCancelled {
                if roster.entries != fixture { roster.entries = fixture }
                try? await Task.sleep(for: .milliseconds(40))
            }
        }
        let legacy = await run("legacy", iterations: min(n, 30), fault: false)
        keeper.cancel()
        plazaTickGate.hold()
        summary("flake.panels.legacy", "legacy (tick + 40 ms keeper)", hovers: legacy.0, covers: legacy.1, dpis: legacy.2, expectFail: false)
    }

    // MARK: B: plaza.close handles

    /// N open/close cycles of the plaza window with a typed handle diff per cycle; prints counts and what each change was.
    @MainActor static func flakeLoopClose(_ r: Recorder, _ c: PlazaWindowController, _ shell: WinPlazaWindow) async {
        let n = FlakeLoop.count
        guard var previous = WinHandleTable.snapshot() else { r.add("flake.close", false, "handle table unavailable"); return }
        let start = previous
        var counts: [Int] = [], notes: [String] = [], firstPresented = 0
        for i in 0..<n {
            c.show()
            if await waitUntil(timeout: 3, { shell.stats.presents >= 1 }) { firstPresented += 1 }
            shell.requestClose()
            _ = await waitUntil(timeout: 0.5) { false }
            guard let now = WinHandleTable.snapshot() else { continue }
            counts.append(now.count)
            if now.count != previous.count || notes.count < 2 || i == n - 1 {
                if notes.count < 12 { notes.append("cycle \(i + 1): \(previous.count) -> \(now.count): \(WinHandleTable.diff(previous, now))") }
            }
            previous = now
        }
        let deltas = zip(counts.dropFirst(), counts).map { $0 - $1 }
        let windows = counts.count >= 8 ? (0...(counts.count - 8)).filter { handleLeak(counts: Array(counts[$0..<($0 + 8)])) }.count : 0
        r.add("flake.close", windows == 0,
              "N=\(n) open/close cycles, leak verdicts over every 8-cycle window: \(windows) leaking, presented \(firstPresented)/\(n); handle count per cycle \(fmt(counts)); step deltas histogram \(histogram(deltas)); "
                + "first -> last \(counts.first ?? 0) -> \(counts.last ?? 0); start types \(WinHandleTable.typesText(start)); end types \(WinHandleTable.typesText(previous)); "
                + "start -> end \(WinHandleTable.diff(start, previous)); changes: " + notes.joined(separator: " | "))
    }

    // MARK: C: modalPump.idle

    /// N more 10 s windows in the same post-menu state, each judged with the check's own budget; prints cs, budget and the known wakes of each.
    @MainActor static func flakeLoopModal(_ r: Recorder, _ app: WindowsAppDelegate) async {
        let n = FlakeLoop.count
        var cs: [Int] = [], over = 0, rows: [String] = [], withFire: [Int] = [], without: [Int] = []
        for i in 0..<n {
            guard let w = await modalIdleWindow(app, settle: i == 0) else { continue }
            cs.append(w.cs)
            if !w.wakesOK || !w.verdict.ok { over += 1 }
            if w.legacyBudget > 3 { withFire.append(w.cs) } else { without.append(w.cs) }
            rows.append("#\(i + 1) cs=\(w.cs)/\(w.budget) (legacy \(w.legacyBudget)) \(w.detail.components(separatedBy: "; ")[1])")
        }
        r.add("flake.modalIdle", over == 0,
              "N=\(cs.count) windows of 10 s, over budget \(over); main cs histogram \(histogram(cs)); windows with a known timer wake or refresh \(withFire.count) cs \(histogram(withFire)); "
                + "windows without \(without.count) cs \(histogram(without)); " + rows.joined(separator: " | "))
    }
}
#endif
