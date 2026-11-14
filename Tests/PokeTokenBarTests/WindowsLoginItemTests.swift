#if os(Windows)
import XCTest
@testable import PokeTokenBar

/// Registry round trips under a scratch key `HKCU\Software\PokeTokenBarTests\<uuid>`, deleted in `tearDown` (also
/// after a failed test). The real Run key is only ever READ here (`testFirstRunLeavesLaunchAtLoginOff`).
@MainActor
final class WindowsLoginItemTests: XCTestCase {
    private var root = ""
    private var runKey: String { root + #"\Run"# }
    private var approvedKey: String { root + #"\Approved"# }
    private let command = #""C:\Program Files\PokeTokenBar\PokeTokenBar.exe" --autostart"#

    override func setUp() async throws {
        root = #"Software\PokeTokenBarTests\"# + UUID().uuidString
    }

    override func tearDown() async throws {
        WinRegistry.deleteTree(root)
    }

    private func item(command: String? = nil) -> WindowsLoginItem {
        WindowsLoginItem(runKey: runKey, approvedKey: approvedKey, valueName: "PokeTokenBar", command: command ?? self.command)
    }

    private func stored(_ name: String = "PokeTokenBar") -> String? {
        if case .value(let v) = WinRegistry.string(runKey, name) { return v }
        return nil
    }

    func testEnableWritesTheQuotedCommand() async {
        let login = item()
        XCTAssertEqual(login.state, .off, "nothing written yet")
        XCTAssertTrue(login.setEnabled(true))
        XCTAssertEqual(stored(), command, "the exe path is quoted and --autostart follows it")
        XCTAssertEqual(login.state, .on)
    }

    func testDisableRemovesOnlyOurValue() async {
        XCTAssertEqual(WinRegistry.setString(runKey, "SomethingElse", #""C:\other.exe""#), 0)
        let login = item()
        XCTAssertTrue(login.setEnabled(true))
        XCTAssertTrue(login.setEnabled(false))
        XCTAssertNil(stored(), "ours is gone")
        XCTAssertEqual(stored("SomethingElse"), #""C:\other.exe""#, "a neighbour is untouched")
        XCTAssertEqual(WinRegistry.valueNames(runKey), ["SomethingElse"])
        XCTAssertEqual(login.state, .off)
        XCTAssertTrue(login.setEnabled(false), "removing what is not there is still 'off'")
    }

    func testDisabledInTaskManagerIsReported() async {
        let login = item()
        XCTAssertTrue(login.setEnabled(true))
        XCTAssertEqual(WinRegistry.setBytes(approvedKey, "PokeTokenBar", [0x03, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]), 0)
        XCTAssertEqual(login.state, .disabledByUser)
        XCTAssertEqual(WinRegistry.setBytes(approvedKey, "PokeTokenBar", [0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]), 0)
        XCTAssertEqual(login.state, .on, "0x02 is Task Manager's 'enabled'")
        XCTAssertEqual(WinRegistry.setBytes(approvedKey, "PokeTokenBar", [0x03, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]), 0)
        XCTAssertTrue(login.setEnabled(false))
        XCTAssertTrue(login.setEnabled(true))
        XCTAssertEqual(login.state, .on, "turning it off cleared our own 'disabled' leftover")
    }

    func testFirstRunLeavesLaunchAtLoginOff() async {
        // Reading never writes: not the scratch key, and not the real Run key (compared before and after).
        let before = WinRegistry.valueNames(WindowsLoginItem.defaultRunKey)
        _ = WindowsLoginItem().state
        _ = item().state
        XCTAssertEqual(WinRegistry.valueNames(WindowsLoginItem.defaultRunKey), before)
        XCTAssertTrue(WinRegistry.valueNames(runKey).isEmpty)
        XCTAssertNil(stored())
        XCTAssertEqual(item().state, .off)
    }

    func testAMovedAppReadsOffAndOnlyTheToggleRepairsIt() async {
        let old = item(command: #""D:\old folder\PokeTokenBar.exe" --autostart"#)
        XCTAssertTrue(old.setEnabled(true))
        let moved = item()
        XCTAssertEqual(moved.state, .off, "the value names another exe")
        XCTAssertEqual(stored(), #""D:\old folder\PokeTokenBar.exe" --autostart"#, "reading did not repair it")
        XCTAssertTrue(moved.setEnabled(true))
        XCTAssertEqual(stored(), command)
        XCTAssertEqual(moved.state, .on)
    }

    func testAFailedWriteIsReportedAndNeverShowsOn() async {
        let broken = WindowsLoginItem(runKey: #"Software\PokeTokenBarTests\"# + String(repeating: "x", count: 300),
                                      approvedKey: approvedKey, valueName: "PokeTokenBar", command: command)
        XCTAssertFalse(broken.setEnabled(true))
        XCTAssertNotEqual(broken.state, .on)
        WinRegistry.deleteTree(#"Software\PokeTokenBarTests\"# + String(repeating: "x", count: 300))
    }

    func testTheDefaultCommandQuotesTheRunningExecutable() async {
        let exe = WindowsLoginItem.currentExecutablePath()
        XCTAssertTrue(exe.lowercased().hasSuffix(".exe"), exe)
        XCTAssertEqual(WindowsLoginItem.defaultCommand, "\"\(exe)\" --autostart")
        XCTAssertEqual(WindowsLoginItem.defaultRunKey, #"Software\Microsoft\Windows\CurrentVersion\Run"#, "per-user Run key, never a machine-wide one")
    }

    func testCommandsCompareIgnoringCase() async {
        XCTAssertTrue(WindowsLoginItem.sameCommand(#""C:\A\PokeTokenBar.exe" --autostart"#, #""c:\a\POKETOKENBAR.EXE" --autostart"#))
        XCTAssertFalse(WindowsLoginItem.sameCommand(#""C:\A\PokeTokenBar.exe" --autostart"#, #""C:\B\PokeTokenBar.exe" --autostart"#))
    }
}
#endif
