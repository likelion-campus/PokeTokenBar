import XCTest

/// Mechanical guard: raw suite creation leaks plist files into `~/Library/Preferences` (see
/// `TestDefaults`). Only `TestDefaults.swift` may call the initializer.
final class TestDefaultsScanTests: XCTestCase {
    func testNoTestCreatesASuiteOutsideTheHelper() throws {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let needle = "UserDefaults(" + "suiteName:"
        var offenders: [String] = []
        let files = try XCTUnwrap(FileManager.default.enumerator(at: testsDir, includingPropertiesForKeys: nil))
        for case let url as URL in files where url.pathExtension == "swift" && url.lastPathComponent != "TestDefaults.swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains(needle) { offenders.append(url.lastPathComponent) }
        }
        XCTAssertEqual(offenders, [], "use TestDefaults.make(suite:) so the suite's plist is deleted after the test")
    }
}
