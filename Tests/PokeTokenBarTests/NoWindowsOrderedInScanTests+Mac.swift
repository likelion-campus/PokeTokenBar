import Foundation
import XCTest

/// No test file orders a window onto the window server or activates the app, except through the env-gated helper.
/// The Plaza files have their own stricter scan (`PlazaNoWindowsOrderedInScanTests`); this one covers every OTHER test file.
final class NoWindowsOrderedInScanTests: XCTestCase {
    /// file -> why it may contain an ordering call. Each is env-gated (`PTB_LIVE_WINDOW_TESTS` / `PTB_PLAZA_LIVE_WINDOW`).
    private static let allowed: [String: String] = [
        "LiveWindowTestSupport.swift": "the gated helper: orders in only under PTB_LIVE_WINDOW_TESTS, off-screen, never key",
        "NoWindowsOrderedInScanTests+Mac.swift": "this scan names the patterns",
        "PlazaNoWindowsOrderedInScanTests+Mac.swift": "the Plaza scan names the patterns",
        "PlazaWindowRig+Mac.swift": "Plaza live rig, under `if live` (PTB_PLAZA_LIVE_WINDOW)",
        "PlazaLiveWindowTests.swift": "Plaza live-window checklist (PTB_PLAZA_LIVE_WINDOW)",
    ]
    private static let patterns = ["orderFront(", "orderFrontRegardless(", "makeKeyAndOrderFront(", "orderBack(", "orderIn(", "showWindow(",
                                   "NSApp.activate(", ".activate(ignoringOtherApps", "NSApplication.shared.activate("]

    func testNoTestFileOutsideTheAllowListOrdersAWindowIn() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)).compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 100)
        var offenders: [String] = []
        for file in files where Self.allowed[file.lastPathComponent] == nil {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") && Self.patterns.contains(where: { line.contains($0) }) {
                offenders.append("\(file.lastPathComponent):\(n + 1)")
            }
        }
        XCTAssertEqual(offenders, [], "these tests order a window in or activate the app; call window.orderInForTest() (PTB_LIVE_WINDOW_TESTS) instead")
        // The helper itself stays off-screen and non-key.
        let helper = try String(contentsOf: root.appendingPathComponent("LiveWindowTestSupport.swift"), encoding: .utf8)
        XCTAssertTrue(helper.contains("guard Self.liveWindowTestsEnabled"))
        XCTAssertFalse(helper.contains("makeKey"))
    }
}
