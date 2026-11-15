import XCTest

/// Mechanical guard: `URLProtocol.registerClass` is process-wide (every later suite's `URLSession.shared` request goes
/// through it), so a registration that is never undone fails other suites only in the full run. A file that registers
/// must also unregister, either in the same file or via `addTeardownBlock`.
final class NetworkProtocolScanTests: XCTestCase {
    func testEveryURLProtocolRegistrationIsUndoneInItsFile() throws {
        let register = "URLProtocol." + "registerClass(", unregister = "URLProtocol." + "unregisterClass("
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var offenders: [String] = []
        let files = try XCTUnwrap(FileManager.default.enumerator(at: testsDir, includingPropertiesForKeys: nil))
        for case let url as URL in files where url.pathExtension == "swift" && url.lastPathComponent != "NetworkProtocolScanTests.swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains(register), !text.contains(unregister) { offenders.append(url.lastPathComponent) }
        }
        XCTAssertEqual(offenders, [], "unregister in the same file (defer / tearDown / addTeardownBlock)")
    }
}
