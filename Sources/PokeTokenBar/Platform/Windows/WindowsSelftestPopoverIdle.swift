#if os(Windows)
import Foundation
import WinSDK

// Stage 7: what wakes the selftest process with nothing of ours open. The main thread wakes between 0 and 16 times in a 6 s window
// after the tab pages' checks, and it was not attributed: the store's refresh, the tray's and the shell's callbacks, the selftest's own
// sampler. Each phase now counts the wakes by source with `WakeTrace` (messages removed by the pump as `0x113@Class`, timer ids, the
// app's own clocks, page applies and layouts) and prints the sources, so the numbers name what woke.
//
// `popover.idleAttribution` fails only on what is attributable to a page the checks opened and left behind: a live kit control or scroll
// area, a modal pump or its timer, a caret or the focus in an edit, a popover or animation clock that fired, or a stack layout or page
// apply (nothing of ours is open to lay out or apply). The count alone never fails it; it is reported with its sources.

@MainActor enum WindowsSelftestPopoverIdle {
    static let names = ["popover.idleAttribution"]
    private struct Phase { var label: String; var cs: Int; var detail: String; var leftovers: [String] }
    private static var phases: [Phase] = []
    private static let seconds = 6.0

    private static func diff<K: Hashable>(_ a: [K: Int], _ b: [K: Int]) -> [K: Int] {
        var out: [K: Int] = [:]
        for (k, v) in b { let d = v - (a[k] ?? 0); if d > 0 { out[k] = d } }
        return out
    }

    private static func top<K>(_ d: [K: Int], _ name: (K) -> String) -> String {
        d.sorted { $0.value != $1.value ? $0.value > $1.value : name($0.key) < name($1.key) }.prefix(8).map { "\(name($0.key)):\($0.value)" }.joined(separator: ",")
    }

    static func probe(_ label: String) async {
        WakeTrace.enable()   // counting starts with the first probe: the diffs below are per phase
        _ = await WindowsSelftest.waitUntil(timeout: 0.5) { false }
        var info = GUITHREADINFO()
        info.cbSize = DWORD(MemoryLayout<GUITHREADINFO>.size)
        _ = GetGUIThreadInfo(WindowsApp.mainThreadID, &info)
        let focusClass = info.hwndFocus.map { WinKit.className($0) } ?? "-"
        let state = "caret=\(info.hwndCaret != nil ? "yes" : "-") focus=\(focusClass) active=\(info.hwndActive != nil ? "yes" : "-") "
            + "controls=\(WinControl.liveCount) areas=\(WinScrollArea.liveCount) pump=\(WinModalPump.depth)\(WinModalPump.timerLive ? "+timer" : "")"
        let before = WakeTrace.counts()
        let loops0 = WinMainLoop.iterations
        guard let sample = await IdleSampler.measure(seconds: seconds, mainThread: WindowsApp.mainThreadID) else {
            phases.append(Phase(label: label, cs: -1, detail: "measurement failed", leftovers: ["no measurement"]))
            return
        }
        let after = WakeTrace.counts()
        let messages = diff(before.messages, after.messages), timers = diff(before.timers, after.timers), sources = diff(before.sources, after.sources)
        var leftovers: [String] = []
        if WinControl.liveCount != 0 { leftovers.append("\(WinControl.liveCount) live kit controls") }
        if WinScrollArea.liveCount != 0 { leftovers.append("\(WinScrollArea.liveCount) live scroll areas") }
        if WinModalPump.depth != 0 || WinModalPump.timerLive { leftovers.append("the modal pump") }
        if info.hwndCaret != nil { leftovers.append("a caret window") }
        if focusClass == "Edit" { leftovers.append("the focus is in an edit") }
        for name in ["popoverClock", "animationClock", "stackLayout", "homeApply", "companionApply", "activityApply"] where sources[name] != nil {
            leftovers.append("\(name) x\(sources[name] ?? 0)")
        }
        let detail = "main_thread_cs=\(sample.mainContextSwitches) in \(Int(seconds)) s, loops=\(WinMainLoop.iterations - loops0), "
            + "messages=[\(top(messages) { $0 })], timer ids=[\(top(timers) { "id\($0)" })], sources=[\(top(sources) { $0 })], busy=[\(sample.busy)], \(state)"
        phases.append(Phase(label: label, cs: sample.mainContextSwitches, detail: detail, leftovers: leftovers))
    }

    static func report(_ r: WindowsSelftest.Recorder) {
        guard !phases.isEmpty else { r.add("popover.idleAttribution", false, "no probe ran"); return }
        let bad = phases.filter { !$0.leftovers.isEmpty }
        r.add("popover.idleAttribution", bad.isEmpty,
              phases.map { "[\($0.label)] \($0.detail)" }.joined(separator: " | ")
              + (bad.isEmpty ? "" : " | LEFTOVERS: " + bad.map { "\($0.label): \($0.leftovers.joined(separator: ", "))" }.joined(separator: "; ")))
    }
}
#endif
