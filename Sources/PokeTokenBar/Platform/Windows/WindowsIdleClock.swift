#if os(Windows)
import Foundation
import WinSDK

/// True once, for the first caller: "log this failure once".
final class WinOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func first() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let was = done
        done = true
        return !was
    }
}

/// Seconds since the last keyboard or mouse input of this session (`GetLastInputInfo`). Reads one value per call;
/// nothing runs in between, so it costs no wakeups. A failed read logs once and reports 0 (active), the stub's value.
struct WindowsIdleClock: IdleClock {
    private static let failureLogged = WinOnce()

    func secondsSinceLastInput() -> TimeInterval {
        var info = LASTINPUTINFO()
        info.cbSize = UINT(MemoryLayout<LASTINPUTINFO>.size)
        guard GetLastInputInfo(&info) else {
            if Self.failureLogged.first() { AppLog.write("idle clock unavailable: GetLastInputInfo failed (\(GetLastError())); reporting 0") }
            return 0
        }
        return Self.seconds(lastInputTick: info.dwTime, nowTick: GetTickCount())
    }

    /// Both ticks are 32-bit milliseconds since boot and wrap every 49.7 days; wrapping subtraction survives that.
    /// A last-input tick that is a little ahead of now (the two reads are not atomic) shows up as a difference over
    /// half the range and counts as "just now".
    static func seconds(lastInputTick: UInt32, nowTick: UInt32) -> TimeInterval {
        let elapsed = nowTick &- lastInputTick
        return elapsed > UInt32.max / 2 ? 0 : TimeInterval(elapsed) / 1000
    }
}
#endif
