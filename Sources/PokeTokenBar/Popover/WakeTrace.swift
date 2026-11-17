import Foundation

/// Where an idle process's main-thread wakes come from (the idle gate's attribution). Off unless the gate sets `PTB_WAKE_TRACE=1`:
/// then every message the Windows pump removes is counted by id (`WinMessageHook`; posted and timer messages, sent ones never wake
/// the loop) and the app's own sources count themselves by name (clock fires, page applies, layouts). `snapshot` is one log line;
/// the gate reads two of them (at the window's start and at exit) and prints the difference per source. A wake that is neither a
/// counted message nor a counted source is a main-queue block or a CoreFoundation timer. Main thread only; no effect when off.
enum WakeTrace {
    nonisolated(unsafe) static let enabled: Bool = ProcessInfo.processInfo.environment["PTB_WAKE_TRACE"] == "1"
    nonisolated(unsafe) private static var messages: [UInt32: Int] = [:]
    nonisolated(unsafe) private static var timers: [Int: Int] = [:]
    nonisolated(unsafe) private static var sources: [String: Int] = [:]

    /// A message the pump removed; `timerID` is the `wParam` of a timer message.
    static func message(_ id: UInt32, wParam: Int) {
        guard enabled else { return }
        messages[id, default: 0] += 1
        if id == 0x0113 /* WM_TIMER */ || id == 0x0118 /* WM_SYSTIMER: the caret */ { timers[wParam, default: 0] += 1 }
    }

    /// One of the app's own wake sources fired.
    static func count(_ source: String) {
        guard enabled else { return }
        sources[source, default: 0] += 1
    }

    /// `wake trace <label>: loops=… messages_total=… messages=0x113:5,… timers=id:n,… sources=name:n,…` (biggest first, at most 12 each).
    static func snapshot(_ label: String, loops: Int) -> String {
        func top<K>(_ d: [K: Int], _ fmt: (K) -> String) -> String {
            d.sorted { $0.value != $1.value ? $0.value > $1.value : fmt($0.key) < fmt($1.key) }.prefix(12).map { "\(fmt($0.key)):\($0.value)" }.joined(separator: ",")
        }
        let total = messages.values.reduce(0, +)
        return "wake trace \(label): loops=\(loops) messages_total=\(total) messages=\(top(messages) { "0x" + String($0, radix: 16) }) "
            + "timers=\(top(timers) { "id\($0)" }) sources=\(top(sources) { $0 })"
    }
}
