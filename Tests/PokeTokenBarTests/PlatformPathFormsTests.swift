import XCTest
@testable import PokeTokenBar

/// The roots of the path forms a Windows user types into Settings (stage 7 Task 14, P19): `PlatformCompat.windowsSplitRoot` and
/// `windowsListablePath` are pure, so both systems check them; `WindowsScanRootPathTests` takes the same forms through the
/// real Windows file system.
final class PlatformPathFormsTests: XCTestCase {
    private func split(_ path: String) -> [String] {
        let r = PlatformCompat.windowsSplitRoot(path)
        return [r.base, r.rest]
    }

    func testEveryWindowsPathFormGetsItsRoot() {
        XCTAssertEqual(split(#"C:\Users\me\logs"#), ["C:", "/Users/me/logs"])
        XCTAssertEqual(split(#"C:/Users/me\logs/"#), ["C:", "/Users/me/logs/"], "mixed separators and a trailing one")
        XCTAssertEqual(split(#"C:\"#), ["C:", "/"], "a drive root")
        XCTAssertEqual(split("D:"), ["D:", ""])
        XCTAssertEqual(split(#"C:\with space\한글 폴더"#), ["C:", "/with space/한글 폴더"])
        XCTAssertEqual(split(#"\\server\share\logs\x"#), ["//server/share", "/logs/x"], "a UNC path: the share is the root")
        XCTAssertEqual(split("//server/share"), ["//server/share", ""])
        XCTAssertEqual(split(#"\\server\share\"#), ["//server/share", "/"])
        XCTAssertEqual(split(#"\\localhost\C$\Users\a b"#), ["//localhost/C$", "/Users/a b"], "an administrative share")
        XCTAssertEqual(split(#"\\server\share\logs\proj-*"#), ["//server/share", "/logs/proj-*"])
        XCTAssertEqual(split(#"\\?\C:\x"#), ["C:", "/x"], "the verbatim prefix of a drive path")
        XCTAssertEqual(split(#"\\?\UNC\server\share\x"#), ["//server/share", "/x"], "the verbatim prefix of a UNC path")
        XCTAssertEqual(split(#"\\.\C:\x"#), ["C:", "/x"])
        XCTAssertEqual(split(#"\\server"#), ["", "//server"], "a server without a share is no root")
        XCTAssertEqual(split(#"\rooted\x"#), ["", "/rooted/x"], "rooted on the current drive, as before")
        XCTAssertEqual(split("/posix/style"), ["", "/posix/style"])
    }

    func testTheListablePathOfEachRoot() {
        XCTAssertEqual(PlatformCompat.windowsListablePath(""), "/")
        XCTAssertEqual(PlatformCompat.windowsListablePath("C:"), "C:/", "a bare drive means its current folder")
        XCTAssertEqual(PlatformCompat.windowsListablePath("//server/share"), "//server/share/", "a share's root is found with its slash")
        XCTAssertEqual(PlatformCompat.windowsListablePath("//server/share/logs"), "//server/share/logs")
        XCTAssertEqual(PlatformCompat.windowsListablePath("C:/logs"), "C:/logs")
    }

    /// The defect itself (P19): the split before the fix gave a UNC path no root, so `CustomScanRoots.expand` joined its parts
    /// under the current drive's root: `\\server\share\x` was looked for as `\server\share\x`.
    func testTheOldSplitLookedForAUNCPathOnTheCurrentDrive() {
        func before(_ absolute: String) -> (base: String, rest: String) {   // the Windows branch of `splitRoot` until stage 7 Task 14, verbatim
            let slashed = absolute.replacingOccurrences(of: "\\", with: "/")
            let u = Array(slashed)
            if u.count >= 2, u[1] == ":" { return (String(u[0...1]), String(u.dropFirst(2))) }
            return ("", slashed)
        }
        func joined(_ s: (base: String, rest: String)) -> String {   // how `expand` builds the path from the split
            s.rest.split(separator: "/").map(String.init).reduce(s.base) { $0 + "/" + $1 }
        }
        XCTAssertEqual(joined(before(#"\\server\share\x"#)), "/server/share/x")
        XCTAssertEqual(joined(PlatformCompat.windowsSplitRoot(#"\\server\share\x"#)), "//server/share/x")
        XCTAssertEqual(joined(before(#"C:\x"#)), joined(PlatformCompat.windowsSplitRoot(#"C:\x"#)), "drive paths are split as before")
    }

    func testAUNCPathIsStandardizedWithItsShare() {
        XCTAssertTrue(PlatformCompat.isWindowsUNC("//server/share/x"))
        XCTAssertTrue(PlatformCompat.isWindowsUNC(#"\\server\share"#))
        XCTAssertFalse(PlatformCompat.isWindowsUNC("C:/x"))
        XCTAssertFalse(PlatformCompat.isWindowsUNC("/x"))
        XCTAssertFalse(PlatformCompat.isWindowsUNC("///x"))
        XCTAssertFalse(PlatformCompat.isWindowsUNC(#"\\?\C:\x"#), "a device path is not a share")
        XCTAssertEqual(PlatformCompat.windowsStandardizedUNC("//server/share/a/./b/../c/"), "//server/share/a/c")
        XCTAssertEqual(PlatformCompat.windowsStandardizedUNC(#"\\server\share\logs\"#), "//server/share/logs")
        XCTAssertEqual(PlatformCompat.windowsStandardizedUNC("//server/share/../../x"), "//server/share/x", "never above the share")
        XCTAssertEqual(PlatformCompat.windowsStandardizedUNC("//server/share"), "//server/share")
        XCTAssertEqual(PlatformCompat.windowsStandardizedUNC("//server/share/한글 폴더/a b"), "//server/share/한글 폴더/a b")
    }

    #if !os(Windows)
    /// Mac pins: the two path seams of Task 14 are the expressions their four call sites had (Core's `normalizedRoots`,
    /// `CustomScanRoots.normalizedPath`, `LocalAsideUsageReader.databases`, `ClaudeAccountRoots.roots`).
    func testTheMacPathSeamsAreTheOldExpressions() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-path-seams-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("real/inner")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("link"), withDestinationURL: dir.appendingPathComponent("real"))
        for url in [dir.appendingPathComponent("link/inner"), dir.appendingPathComponent("real/./inner/../inner/"), dir.appendingPathComponent("missing/x"),
                    URL(fileURLWithPath: "//server/share/x")] {
            XCTAssertEqual(PlatformCompat.resolvedFileURL(url), url.resolvingSymlinksInPath().standardizedFileURL, url.path)
        }
        XCTAssertEqual(PlatformCompat.resolvedFileURL(dir.appendingPathComponent("link/inner")).path, real.resolvingSymlinksInPath().path, "links resolved")
        for path in [dir.path + "/real/./inner/..", dir.path + "/link", "/tmp/../x", "//server/share/x"] {
            XCTAssertEqual(PlatformCompat.standardizedDirectoryURL(path), URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL, path)
        }
    }
    #endif
}
