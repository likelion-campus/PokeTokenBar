#if os(Windows)
import XCTest
@testable import PokeTokenBar

/// Foundation on Windows: the search paths and bundle answers shared code relies on (F1, F3).
final class WindowsFoundationTests: XCTestCase {
    func testLibraryDirectoryIsUnmappedOnWindows() {
        XCTAssertEqual(FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).count, 0)
    }

    func testLogsDirectoryIsUnderLocalAppData() throws {
        let dir = PlatformCompat.logsDirectory()
        let local = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("AppData/Local/PokeTokenBar/Logs")
        XCTAssertTrue(WinPath.sameFile(dir, local), "\(dir.path) vs \(local.path)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let probe = dir.appendingPathComponent("ptb-write-probe-\(UUID().uuidString).tmp")
        try Data("x".utf8).write(to: probe)
        XCTAssertTrue(FileManager.default.fileExists(atPath: probe.path))
        try FileManager.default.removeItem(at: probe)
    }

    func testPackagedLayoutNeedsTheVersionFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(WindowsInstall.isPackagedLayout(executableDirectory: dir))
        let file = dir.appendingPathComponent(WindowsInstall.versionFileName)
        try Data().write(to: file)
        XCTAssertFalse(WindowsInstall.isPackagedLayout(executableDirectory: dir))
        try Data("2.5.613\n".utf8).write(to: file)
        XCTAssertTrue(WindowsInstall.isPackagedLayout(executableDirectory: dir))
    }

    func testNativePathUsesBackslashes() {
        let url = URL(fileURLWithPath: "C:/Users/x/AppData/Local/PokeTokenBar/")
        let native = WinPath.native(url)
        XCTAssertFalse(native.contains("/"))
        XCTAssertFalse(native.hasSuffix("\\"))
        XCTAssertTrue(native.hasSuffix("\\PokeTokenBar"))
        XCTAssertTrue(WinPath.sameFile(url, URL(fileURLWithPath: "c:\\users\\X\\appdata\\local\\poketokenbar")))
    }
}
#endif
