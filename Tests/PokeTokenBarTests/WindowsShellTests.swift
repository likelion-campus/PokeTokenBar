#if os(Windows)
import XCTest
@testable import PokeTokenBar

/// The Windows app shell's pure parts. The loop, the hook and the exits are checked inside the shipped loop by
/// `--selftest` (`windows-app` workflow), because XCTest drives the run loop its own way.
@MainActor
final class WindowsShellTests: XCTestCase {
    private let defaultFolder = URL(fileURLWithPath: "C:/Users/x/AppData/Local/PokeTokenBar", isDirectory: true)

    func testMutexNameIsFixedForTheDefaultStateFolder() async {
        // The installer closes the running app through this exact name (AppMutex).
        XCTAssertEqual(WinSingleInstance.mutexName(stateDirectory: defaultFolder, defaultDirectory: defaultFolder),
                       "Local\\PokeTokenBar-Team")
    }

    func testMutexNameDiffersPerStateFolder() async {
        let one = URL(fileURLWithPath: "D:/qa/one", isDirectory: true)
        let two = URL(fileURLWithPath: "D:/qa/two", isDirectory: true)
        let a = WinSingleInstance.mutexName(stateDirectory: one, defaultDirectory: defaultFolder)
        let b = WinSingleInstance.mutexName(stateDirectory: two, defaultDirectory: defaultFolder)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a, WinSingleInstance.mutexName(stateDirectory: one, defaultDirectory: defaultFolder), "stable")
        let prefix = "Local\\PokeTokenBar-Team-"
        XCTAssertTrue(a.hasPrefix(prefix), a)
        let suffix = String(a.dropFirst(prefix.count))
        XCTAssertFalse(suffix.isEmpty)
        XCTAssertTrue(suffix.allSatisfy(\.isHexDigit), "a mutex name holds no backslash after its namespace: \(a)")
        // Same folder, same hash as the team settings suite, so one QA instance owns both.
        XCTAssertEqual(TeamSettings.suiteName(for: one, defaultDirectory: defaultFolder), "ptb.team." + suffix)
    }

    /// G-i: every typed setter reaches the override that schedules the save.
    func testSyncingDefaultsSeesTypedSetters() async {
        let defaults = WinSyncingDefaults()
        let key = "ptb.test.windowsShell.typedSetter"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        func noted(_ label: String, _ write: () -> Void) {
            let before = WinDefaultsSync.writeNotes
            write()
            XCTAssertGreaterThan(WinDefaultsSync.writeNotes, before, label)
        }
        noted("set(Bool)") { defaults.set(true, forKey: key) }
        XCTAssertEqual(UserDefaults.standard.object(forKey: key) as? Bool, true, "suiteName nil is the standard domain")
        noted("set(Int)") { defaults.set(1, forKey: key) }
        noted("set(Double)") { defaults.set(2.0, forKey: key) }
        noted("set(String as Any?)") { defaults.set("s", forKey: key) }
        noted("set(Float)") { defaults.set(Float(3), forKey: key) }
        noted("set(URL)") { defaults.set(URL(fileURLWithPath: "C:/x"), forKey: key) }
        noted("removeObject") { defaults.removeObject(forKey: key) }
        XCTAssertNil(UserDefaults.standard.object(forKey: key))
    }
}
#endif
