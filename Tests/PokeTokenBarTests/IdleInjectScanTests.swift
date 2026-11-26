import XCTest

/// The selftest's idle fault injections (`PTB_SELFTEST_INJECT`) must be unreachable on a person's PC and in a release: read only under
/// `--selftest` and only on the runner, and forced empty by every workflow job that sets them when `release_sha` is set.
final class IdleInjectScanTests: XCTestCase {
    func testTheSwitchIsReadOnlyOnTheRunnerUnderSelftest() throws {
        let url = SharedSources.sourcesRoot.appendingPathComponent("Platform/Windows/WindowsSelftestIdleInject.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        let read = try XCTUnwrap(text.range(of: "PTB_SELFTEST_INJECT\"]"))
        let head = String(text[..<read.lowerBound])
        XCTAssertTrue(head.contains("guard WindowsSelftest.onCI, CommandLine.arguments.contains(\"--selftest\") else { return nil }"),
                      "the injection switch must be guarded by onCI and --selftest before it is read")
        for other in SharedSources.allSwiftFiles(root: SharedSources.sourcesRoot) where other.lastPathComponent != "WindowsSelftestIdleInject.swift" {
            XCTAssertFalse(try String(contentsOf: other, encoding: .utf8).contains("PTB_SELFTEST_INJECT"), "\(other.lastPathComponent) reads the injection switch")
        }
    }

    func testReleaseModeForcesTheInjectionOff() throws {
        let text = try String(contentsOf: SharedSources.repoRoot.appendingPathComponent(".github/workflows/windows-app.yml"), encoding: .utf8)
        let lines = text.components(separatedBy: "\n").filter { $0.contains("PTB_SELFTEST_INJECT:") }
        XCTAssertEqual(lines.count, 2, "the bundle and the installed selftest step each set it")
        for line in lines {
            XCTAssertTrue(line.contains("inputs.release_sha == '' && inputs.idle_inject || ''"), "not forced empty in release mode: \(line)")
        }
        XCTAssertEqual(text.components(separatedBy: "PTB_SELFTEST_IDLE_LOOP: ${{ inputs.release_sha == '' && inputs.idle_loop || '0' }}").count - 1, 2)
    }
}
