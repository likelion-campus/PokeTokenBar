import Foundation
#if os(Windows)
import WinSDK
#endif

/// Small OS differences that shared code needs. This directory is the one place body-level `#if os(...)` is allowed.
/// On macOS every function is the exact call the call site used before it moved here.
enum PlatformCompat {
    /// Makes both zlib functions report "unavailable", as on Windows. Tests only.
    nonisolated(unsafe) static var zlibDisabledForTesting = false

    /// Ends a process that ignored a polite terminate.
    static func forceKill(pid: Int32) {
        #if os(Windows)
        guard let handle = OpenProcess(DWORD(PROCESS_TERMINATE), false, DWORD(pid)) else { return }
        TerminateProcess(handle, 1)
        CloseHandle(handle)
        #else
        kill(pid, SIGKILL)
        #endif
    }

    static func abbreviatingWithTilde(_ path: String) -> String {
        #if os(Windows)
        let home = NSHomeDirectory()
        if path == home { return "~" }
        for sep in ["/", "\\"] where path.hasPrefix(home + sep) {
            return "~" + sep + path.dropFirst(home.count + 1)
        }
        return path
        #else
        return (path as NSString).abbreviatingWithTildeInPath
        #endif
    }

    /// nil when zlib is unavailable (Windows); callers store the bytes as they are.
    static func zlibCompressed(_ data: Data) -> Data? {
        #if os(Windows)
        return nil
        #else
        if zlibDisabledForTesting { return nil }
        return try? (data as NSData).compressed(using: .zlib) as Data
        #endif
    }

    /// nil when zlib is unavailable or `data` is not zlib.
    static func zlibDecompressed(_ data: Data) -> Data? {
        #if os(Windows)
        return nil
        #else
        if zlibDisabledForTesting { return nil }
        return try? (data as NSData).decompressed(using: .zlib) as Data
        #endif
    }

    /// Keeps the app from being throttled while a refresh runs (App Nap). Idle system sleep stays allowed.
    /// nil on Windows.
    static func beginActivity(reason: String) -> AnyObject? {
        #if os(Windows)
        return nil
        #else
        return ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: reason)
        #endif
    }

    static func endActivity(_ token: AnyObject?) {
        #if !os(Windows)
        guard let token = token as? NSObjectProtocol else { return }
        ProcessInfo.processInfo.endActivity(token)
        #endif
    }
}
