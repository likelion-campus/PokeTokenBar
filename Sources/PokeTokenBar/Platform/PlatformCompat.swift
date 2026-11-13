import Foundation
#if os(Windows)
import WinSDK
#endif

/// The Security framework's status code type; `LimitsError.keychainUnavailable` carries one on every OS.
#if !canImport(Darwin)
typealias OSStatus = Int32
/// Security framework codes `UsageStore.isKeychainPromptDeclined` compares against.
let errSecUserCanceled: OSStatus = -128
let errSecAuthFailed: OSStatus = -25293
#endif

#if os(Windows)
/// swift-corelibs Foundation has no CGVector. Same shape as Core Graphics', for the plaza's particle math.
struct CGVector: Equatable, Sendable {
    var dx: CGFloat
    var dy: CGFloat
    init() { dx = 0; dy = 0 }
    init(dx: CGFloat, dy: CGFloat) { self.dx = dx; self.dy = dy }
    static let zero = CGVector()
}

/// There is no autorelease pool on Windows; run the body.
@inline(__always)
func autoreleasepool<Result>(invoking body: () throws -> Result) rethrows -> Result { try body() }
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

    /// Sets (or, with nil, removes) a process environment variable. Tests use it for `PTB_STATE_DIR`.
    static func setEnvironment(_ name: String, _ value: String?) {
        #if os(Windows)
        name.withCString(encodedAs: UTF16.self) { n in
            if let value {
                value.withCString(encodedAs: UTF16.self) { _ = SetEnvironmentVariableW(n, $0) }
            } else {
                _ = SetEnvironmentVariableW(n, nil)
            }
        }
        #else
        if let value { setenv(name, value, 1) } else { unsetenv(name) }
        #endif
    }

    /// A path that names a location without a base directory. The Mac and other POSIX systems: a leading `/`.
    /// Windows also takes a drive path (`C:\x`, `C:/x`) and a UNC path.
    static func isAbsolutePath(_ path: String) -> Bool {
        #if os(Windows)
        if path.hasPrefix("/") || path.hasPrefix("\\") { return true }
        let u = Array(path.unicodeScalars)
        return u.count >= 3 && Character(u[0]).isLetter && u[1] == ":" && (u[2] == "/" || u[2] == "\\")
        #else
        return path.hasPrefix("/")
        #endif
    }

    /// `~` and `~/...` replaced by the home directory. The Mac: `NSString.expandingTildeInPath`, unchanged.
    static func expandingTilde(_ path: String) -> String {
        #if os(Windows)
        if path == "~" { return NSHomeDirectory() }
        for sep in ["/", "\\"] where path.hasPrefix("~" + sep) { return NSHomeDirectory() + "/" + path.dropFirst(2) }
        return path
        #else
        return NSString(string: path).expandingTildeInPath
        #endif
    }

    /// Splits an absolute path into the base `CustomScanRoots` starts from and the rest (slash-separated).
    /// POSIX: base "" (the root) and the whole path, untouched. Windows: backslashes become slashes, and the
    /// drive (`C:`) is the base.
    static func splitRoot(_ absolute: String) -> (base: String, rest: String) {
        #if os(Windows)
        let slashed = absolute.replacingOccurrences(of: "\\", with: "/")
        let u = Array(slashed)
        if u.count >= 2, u[1] == ":" { return (String(u[0...1]), String(u.dropFirst(2))) }
        return ("", slashed)
        #else
        return ("", absolute)
        #endif
    }

    /// The path to list for a base built by `splitRoot` plus segments: "" is the root, and a bare Windows drive
    /// needs its trailing slash (`C:` alone means the drive's current directory).
    static func listablePath(_ base: String) -> String {
        #if os(Windows)
        if base.isEmpty { return "/" }
        return base.count == 2 && base.hasSuffix(":") ? base + "/" : base
        #else
        return base.isEmpty ? "/" : base
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
    /// Whether `beginActivity` returns a token on this system.
    static var holdsActivities: Bool {
        #if os(Windows)
        return false
        #else
        return true
        #endif
    }

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

    /// `fnmatch(pattern, name, 0) == 0` for one path segment. The Mac and other POSIX systems call fnmatch itself;
    /// Windows has no fnmatch and uses `globMatch`.
    static func matchesGlob(_ pattern: String, _ name: String) -> Bool {
        #if os(Windows)
        return globMatch(pattern, name)
        #else
        return fnmatch(pattern, name, 0) == 0
        #endif
    }

    /// Shell-style matching without the C library: `*` (any run, dots included), `?`, `[set]`, `[!set]` / `[^set]`,
    /// ranges `a-z`, and `\x` for a literal. Compiled on every OS so a Mac test can hold it to `fnmatch`.
    static func globMatch(_ pattern: String, _ name: String) -> Bool {
        let p = Array(pattern.unicodeScalars), n = Array(name.unicodeScalars)

        /// Whether `c` is in the set opening at `p[open]` (a `[`), and the index after its `]`; nil when unclosed.
        func bracket(_ open: Int, _ c: Unicode.Scalar) -> (matched: Bool, next: Int)? {
            var i = open + 1
            var negate = false
            if i < p.count, p[i] == "!" || p[i] == "^" { negate = true; i += 1 }
            var matched = false
            var first = true
            while i < p.count {
                if p[i] == "]" && !first { return (matched != negate, i + 1) }
                first = false
                var lo = p[i]
                if lo == "\\", i + 1 < p.count { i += 1; lo = p[i] }
                if i + 2 < p.count, p[i + 1] == "-", p[i + 2] != "]" {
                    var hi = p[i + 2]
                    var skip = 3
                    if hi == "\\", i + 3 < p.count { hi = p[i + 3]; skip = 4 }
                    if lo.value <= c.value && c.value <= hi.value { matched = true }
                    i += skip
                } else {
                    if lo == c { matched = true }
                    i += 1
                }
            }
            return nil
        }

        var pi = 0, ni = 0
        var starP = -1, starN = 0
        while ni < n.count {
            if pi < p.count {
                switch p[pi] {
                case "*":
                    starP = pi; starN = ni; pi += 1
                    continue
                case "?":
                    pi += 1; ni += 1
                    continue
                case "[":
                    // An unclosed `[` matches nothing, as in fnmatch.
                    if let (matched, next) = bracket(pi, n[ni]), matched { pi = next; ni += 1; continue }
                case "\\":
                    if pi + 1 < p.count {
                        if p[pi + 1] == n[ni] { pi += 2; ni += 1; continue }
                    } else if n[ni] == "\\" {
                        pi += 1; ni += 1; continue
                    }
                default:
                    if p[pi] == n[ni] { pi += 1; ni += 1; continue }
                }
            }
            guard starP >= 0 else { return false }
            starN += 1; ni = starN; pi = starP + 1
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}
