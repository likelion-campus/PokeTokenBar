import Foundation
#if os(Windows)
import WinSDK
#endif

/// The Security framework's status code type; `LimitsError.keychainUnavailable` carries one on every OS.
#if !canImport(Darwin)
typealias OSStatus = Int32
/// `UpdateChecker.launchDetachedUpgrade` (Mac-only at run time, compiled everywhere) names it.
typealias pid_t = Int32
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

    /// Whether this process is the installed app (the single gate for logging, persistence and live limits).
    /// Mac: `Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")`, computed per call.
    /// Windows: `bundleIdentifier` is always nil there, so the installed layout (a version file next to the exe) decides.
    static var isBundledApp: Bool {
        #if os(Windows)
        return windowsPackagedLayout
        #else
        return Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
        #endif
    }

    #if os(Windows)
    private static let windowsPackagedLayout = WindowsInstall.isPackagedLayout
    #endif

    /// The folder `AppLog` writes to. Mac: `~/Library/Logs`. Windows has no Library folder (the search path
    /// returns nothing and `[0]` traps), so it is `%LOCALAPPDATA%\PokeTokenBar\Logs`.
    static func logsDirectory() -> URL {
        #if os(Windows)
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PokeTokenBar").appendingPathComponent("Logs")
        #else
        return FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs")
        #endif
    }

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

    /// Separates the entries of a PATH-style list: `:` on the Mac and other POSIX systems, `;` on Windows.
    static var pathListSeparator: Character {
        #if os(Windows)
        return ";"
        #else
        return ":"
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

// MARK: - Tool directories and launching (stage 4, Task 4)

extension PlatformCompat {
    /// The environment key that holds the search path. Mac: "PATH". Windows: the key already in `env` that equals
    /// "PATH" ignoring case ("Path" in practice, since the process environment is case-insensitive), else "Path".
    static func pathVariableKey(in env: [String: String]) -> String {
        #if os(Windows)
        return env.keys.first { $0.caseInsensitiveCompare("PATH") == .orderedSame } ?? "Path"
        #else
        return "PATH"
        #endif
    }

    /// The names `path` may be launched under. Mac: `[path]`. Windows: `path` + each launchable PATHEXT extension
    /// (`.exe` first; `.cmd`, `.bat`, `.com` in PATHEXT order, or that order when PATHEXT is unset). A bare name is
    /// not a candidate: npm also writes an extensionless shell script next to its `.cmd` shim.
    static func executableCandidates(_ path: String) -> [String] {
        let environment = ProcessInfo.processInfo.environment
        return executableCandidates(path, pathExt: environment["PATHEXT"])
    }

    static func executableCandidates(_ path: String, pathExt: String?) -> [String] {
        #if os(Windows)
        let launchable = [".cmd", ".bat", ".com"]
        var extensions = [".exe"]
        let listed = (pathExt ?? "").split(separator: ";").map { $0.lowercased() }.filter(launchable.contains)
        for e in (listed.isEmpty ? launchable : listed) where !extensions.contains(e) { extensions.append(e) }
        return extensions.map { path + $0 }
        #else
        return [path]
        #endif
    }

    /// Mac: `posix`, unchanged. Windows: the package-manager and version-manager folders whose base variable is set.
    static func toolDirectories(posix: [String]) -> [String] {
        toolDirectories(posix: posix, environment: ProcessInfo.processInfo.environment)
    }

    static func toolDirectories(posix: [String], environment: [String: String]) -> [String] {
        #if os(Windows)
        func value(_ name: String) -> String? {
            environment.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }.map(\.value).flatMap { $0.isEmpty ? nil : $0 }
        }
        var out: [String] = []
        func add(_ base: String?, _ rest: String) { if let base { out.append(base + "\\" + rest) } }
        add(value("APPDATA"), "npm")                              // npm global prefix
        if let pnpm = value("PNPM_HOME") { out.append(pnpm) }     // pnpm's documented home (`pnpm setup`)
        add(value("LOCALAPPDATA"), "Microsoft\\WinGet\\Links")    // winget portable links
        add(value("USERPROFILE"), "scoop\\shims")
        add(value("USERPROFILE"), ".bun\\bin")
        add(value("LOCALAPPDATA"), "Volta\\bin")                  // volta: data_local_dir/Volta, shims in bin/
        add(value("LOCALAPPDATA"), "mise\\shims")                 // mise: %LOCALAPPDATA%\\mise data dir, shims/
        if let nvm = value("NVM_SYMLINK") { out.append(nvm) }     // nvm-windows' active-version link
        add(value("USERPROFILE"), ".local\\bin")
        return out
        #else
        return posix
        #endif
    }

    /// Where per-user application data lives. Mac: `home/Library/Application Support`. Windows: `home/AppData/Roaming`
    /// (`%APPDATA%`, which Electron apps such as Claude Desktop and Cursor use for their user data).
    static func userApplicationSupport(home: URL) -> URL {
        #if os(Windows)
        return home.appendingPathComponent("AppData/Roaming")
        #else
        return home.appendingPathComponent("Library/Application Support")
        #endif
    }

    /// The Claude Desktop session folders under its application-data folder. Mac: both, as before. Windows: none, because
    /// the folder names inside `%APPDATA%\\Claude` are not documented anywhere checkable, so no root is guessed.
    static func claudeDesktopSessionStores(_ stores: [String]) -> [String] {
        #if os(Windows)
        return []
        #else
        return stores
        #endif
    }

    /// Mac: nil (the Mac keeps its login-shell lookup). Windows: the first launchable candidate in the Path entries.
    static func searchProcessPath(_ binary: String, environment: [String: String]) -> String? {
        #if os(Windows)
        guard let list = environment[pathVariableKey(in: environment)] else { return nil }
        for entry in list.split(separator: ";") {
            let dir = entry.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            if dir.isEmpty { continue }
            for candidate in executableCandidates(dir + "\\" + binary, pathExt: environment["PATHEXT"])
            where isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
        #else
        return nil
        #endif
    }

    /// True when `arg` can pass through cmd.exe unchanged: none of `& | < > ^ % !` and no newline (F19). A tool that
    /// resolves to a `.cmd`/`.bat` shim is launched only with arguments that pass this.
    static func isBatchSafe(_ arg: String) -> Bool {
        !arg.contains { "&|<>^%!\n\r".contains($0) }
    }

    /// Ends `process`. Mac: `process.terminate()`, verbatim. Windows: also its descendants, because terminating an npm
    /// `.cmd` shim leaves the program it started running (measured on the CI runner, F19). Descendants come from one
    /// Toolhelp snapshot taken before anything is killed; they are ended first, then the process itself.
    static func terminate(_ process: Process) {
        #if os(Windows)
        var children: [DWORD: [DWORD]] = [:]
        let snapshot = CreateToolhelp32Snapshot(DWORD(TH32CS_SNAPPROCESS), 0)
        if snapshot != INVALID_HANDLE_VALUE {
            var entry = PROCESSENTRY32W()
            entry.dwSize = DWORD(MemoryLayout<PROCESSENTRY32W>.size)
            if Process32FirstW(snapshot, &entry) {
                repeat { children[entry.th32ParentProcessID, default: []].append(entry.th32ProcessID) }
                while Process32NextW(snapshot, &entry)
            }
            CloseHandle(snapshot)
        }
        var descendants: [DWORD] = []
        var pending = [DWORD(process.processIdentifier)]
        while let pid = pending.popLast() {
            for child in children[pid] ?? [] where !descendants.contains(child) {
                descendants.append(child)
                pending.append(child)
            }
        }
        for pid in descendants.reversed() { forceKill(pid: Int32(pid)) }
        #endif
        process.terminate()
    }

    /// Whether `path` is an existing launchable file. Mac: `FileManager.isExecutableFile`, verbatim. On Windows that
    /// call looks only at the extension (it answers true for a `.cmd` or `.exe` that does not exist; CI run 43581978271),
    /// so the file must also exist and not be a folder.
    static func isExecutableFile(atPath path: String) -> Bool {
        #if os(Windows)
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
        #else
        return FileManager.default.isExecutableFile(atPath: path)
        #endif
    }
}
