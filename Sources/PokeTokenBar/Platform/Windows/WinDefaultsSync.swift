#if os(Windows)
import Foundation
import WinSDK

/// A `UserDefaults` that schedules a save after every write. On Windows `UserDefaults` writes its plist only on
/// `synchronize()`; nothing is saved on `TerminateProcess`, on a normal `exit(0)`, or by any timer (F2). The app
/// passes this into every shared init that takes `defaults:`. `suiteName` nil is the same domain as `.standard`.
/// The typed setters (`set(_: Bool, forKey:)` …) reach `set(_:forKey:)` in corelibs (G-i, pinned by
/// `WindowsShellTests.testSyncingDefaultsSeesTypedSetters`).
final class WinSyncingDefaults: UserDefaults, @unchecked Sendable {
    override init?(suiteName suitename: String?) {
        super.init(suiteName: suitename)
        if suitename != nil { WinDefaultsSync.register(self) }
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        super.set(value, forKey: defaultName)
        WinDefaultsSync.noteWrite()
    }

    override func removeObject(forKey defaultName: String) {
        super.removeObject(forKey: defaultName)
        WinDefaultsSync.noteWrite()
    }
}

/// When settings reach the disk (D4): about 2 s after a write (`WinSyncingDefaults`), every 30 s as a safety net for
/// code that writes `.standard` directly, right after the stores are built, and on every exit (`WindowsApp.exit`).
/// A sync without changes does not touch the file (F2).
@MainActor enum WinDefaultsSync {
    static let debounce: TimeInterval = 2, safetyInterval: TimeInterval = 30

    private static var debounceTimer: Timer?
    private static var safetyTimer: Timer?
    private(set) static var flushes = 0
    private(set) static var debounceFires = 0
    private(set) static var safetyFires = 0
    nonisolated private static let state = SyncState()

    /// A debounced save is armed and has not run yet.
    static var isSyncPending: Bool { debounceTimer != nil }

    /// How many writes `WinSyncingDefaults` has reported (tests).
    nonisolated static var writeNotes: Int { state.notes }

    static func start() {
        guard safetyTimer == nil else { return }
        let timer = Timer(fire: Date(timeIntervalSinceNow: safetyInterval), interval: safetyInterval, repeats: true) { _ in
            MainActor.assumeIsolated {
                safetyFires += 1
                flushNow()
            }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        safetyTimer = timer
    }

    /// Any thread. The first write arms one save `debounce` seconds later; writes until then ride along, so no write
    /// waits longer than that however often they come.
    nonisolated static func noteWrite() {
        state.noteWrite()
        DispatchQueue.main.async { MainActor.assumeIsolated { armDebounce() } }
    }

    static func flushNow() {
        flushes += 1
        _ = UserDefaults.standard.synchronize()
        for suite in state.suites { _ = suite.synchronize() }
    }

    nonisolated fileprivate static func register(_ suite: UserDefaults) { state.register(suite) }

    private static func armDebounce() {
        guard debounceTimer == nil else { return }
        let timer = Timer(fire: Date(timeIntervalSinceNow: debounce), interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated {
                debounceTimer = nil
                debounceFires += 1
                flushNow()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        debounceTimer = timer
    }

    /// Where CoreFoundation writes the standard domain: `<GetProfilesDirectoryW>\<GetUserNameW>\AppData\Local\
    /// <ProcessInfo.processName>.plist`, and the process name keeps `.exe` (F2). It is built from the user *name*,
    /// not the profile path, so it can miss the real profile (R9; the selftest's `defaults.location`).
    nonisolated static func expectedPlistURL() -> URL {
        let folder = (profilesDirectory() ?? "C:\\Users") + "\\" + (userName() ?? "") + "\\AppData\\Local"
        return URL(fileURLWithPath: folder, isDirectory: true)
            .appendingPathComponent(ProcessInfo.processInfo.processName + ".plist")
    }

    /// `FOLDERID_LocalAppData`, from the shell (not Foundation).
    nonisolated static func localAppDataFolder() -> URL? {
        var id = GUID(Data1: 0xF1B3_2785, Data2: 0x6FBA, Data3: 0x4FCF,
                      Data4: (0x9D, 0x55, 0x7B, 0x8E, 0x7F, 0x15, 0x70, 0x91))
        var path: PWSTR?
        let hr = SHGetKnownFolderPath(&id, 0, nil, &path)
        defer { CoTaskMemFree(path) }
        guard hr >= 0, let path else { return nil }
        return URL(fileURLWithPath: String(decodingCString: path, as: UTF16.self), isDirectory: true)
    }

    nonisolated private static func profilesDirectory() -> String? {
        typealias Fn = @convention(c) (UnsafeMutablePointer<UInt16>?, UnsafeMutablePointer<DWORD>?) -> Int32
        guard let getProfiles = WinDynamic.symbol("userenv.dll", "GetProfilesDirectoryW", as: Fn.self) else { return nil }
        var size: DWORD = 1024
        var buffer = [UInt16](repeating: 0, count: Int(size))
        guard getProfiles(&buffer, &size) != 0 else { return nil }
        return String(decodingCString: buffer, as: UTF16.self)
    }

    nonisolated private static func userName() -> String? {
        var size: DWORD = 257
        var buffer = [UInt16](repeating: 0, count: Int(size))
        guard GetUserNameW(&buffer, &size) else { return nil }
        return String(decodingCString: buffer, as: UTF16.self)
    }
}

/// Write counter and the extra suites to flush; touched from any thread.
private final class SyncState: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var registered: [UserDefaults] = []

    var notes: Int { lock.lock(); defer { lock.unlock() }; return count }
    var suites: [UserDefaults] { lock.lock(); defer { lock.unlock() }; return registered }
    func noteWrite() { lock.lock(); count += 1; lock.unlock() }
    func register(_ suite: UserDefaults) { lock.lock(); registered.append(suite); lock.unlock() }
}
#endif
