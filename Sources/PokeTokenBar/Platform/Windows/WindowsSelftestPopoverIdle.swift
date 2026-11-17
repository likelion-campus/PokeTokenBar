#if os(Windows)
import Foundation
import WinSDK

// Stage 7 (parity branch): where the extra idle wakes come from. After the tab pages' checks (Collection, Shop and Bag, tabs) the main
// thread was seen waking about twice a second in every later idle window. This measures the main thread's context switches in a
// quiet window BEFORE those groups and after each of them (nothing of ours open, the popover closed), with the GUI thread's caret,
// focus and active window, so one run names the group that leaves something running. `popover.idleAttribution` fails when a probe
// after a group is more than a few wakes above the first probe.

@MainActor enum WindowsSelftestPopoverIdle {
    static let names = ["popover.idleAttribution"]
    private static var probes: [(label: String, cs: Int, detail: String)] = []
    private static let seconds = 6.0

    static func probe(_ label: String) async {
        _ = await WindowsSelftest.waitUntil(timeout: 0.5) { false }
        var info = GUITHREADINFO()
        info.cbSize = DWORD(MemoryLayout<GUITHREADINFO>.size)
        _ = GetGUIThreadInfo(WindowsApp.mainThreadID, &info)
        let state = "caret=\(info.hwndCaret.map { String(Int(bitPattern: $0), radix: 16) } ?? "-") focus=\(info.hwndFocus.map { String(Int(bitPattern: $0), radix: 16) } ?? "-") "
            + "active=\(info.hwndActive.map { String(Int(bitPattern: $0), radix: 16) } ?? "-") controls=\(WinControl.liveCount) areas=\(WinScrollArea.liveCount) pump=\(WinModalPump.depth)"
        guard let sample = await IdleSampler.measure(seconds: seconds, mainThread: WindowsApp.mainThreadID) else {
            probes.append((label, -1, "measurement failed"))
            return
        }
        probes.append((label, sample.mainContextSwitches, "main_thread_cs=\(sample.mainContextSwitches) in \(Int(seconds)) s, busy=[\(sample.busy)], \(state)"))
    }

    static func report(_ r: WindowsSelftest.Recorder) {
        guard let first = probes.first, first.cs >= 0 else { r.add("popover.idleAttribution", false, "no baseline probe: \(probes)"); return }
        let bad = probes.dropFirst().filter { $0.cs < 0 || $0.cs > first.cs + 6 }.map(\.label)
        r.add("popover.idleAttribution", bad.isEmpty,
              probes.map { "[\($0.label)] \($0.detail)" }.joined(separator: " | ") + (bad.isEmpty ? "" : " | ELEVATED AFTER: " + bad.joined(separator: ", ")))
    }
}
#endif
