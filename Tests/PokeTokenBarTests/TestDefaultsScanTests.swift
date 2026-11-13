import XCTest

/// Mechanical guard: raw suite creation leaks plist files into `~/Library/Preferences` (see
/// `TestDefaults`). Only `TestDefaults.swift` may call the initializer or `removePersistentDomain` (that
/// call re-creates an empty plist), and only the pool's own tests may build a private pool.
final class TestDefaultsScanTests: XCTestCase {
    func testNoTestCreatesASuiteOutsideTheHelper() throws {
        let needles = ["UserDefaults(" + "suiteName:", "removePersistent" + "Domain(", "TestDefaults(" + "prefix:", "PooledDefaults(" + "suiteName:"]
        let allowedPool = "TestDefaultsPoolTests.swift"
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var offenders: [String] = []
        let files = try XCTUnwrap(FileManager.default.enumerator(at: testsDir, includingPropertiesForKeys: nil))
        for case let url as URL in files where url.pathExtension == "swift" && url.lastPathComponent != "TestDefaults.swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for needle in needles where text.contains(needle) {
                if needle.hasPrefix("TestDefaults(") && url.lastPathComponent == allowedPool { continue }
                offenders.append("\(url.lastPathComponent): \(needle)")
            }
        }
        XCTAssertEqual(offenders, [], "use TestDefaults.make(suite:) and never touch the domain yourself; see TestDefaults")
    }
}
