import Foundation
import XCTest

/// No Plaza test puts a window on the window server or activates the app by default: only the env-gated tests may (`PTB_PLAZA_LIVE_WINDOW`).
/// Every Plaza test file is scanned for ordering a window in; the allow-list is the gated files.
final class PlazaNoWindowsOrderedInScanTests: XCTestCase {
    /// Gated by `PTB_PLAZA_LIVE_WINDOW`: the live-window checklist and the live rig (its `orderFront` is under `if live`).
    private static let allowed: Set<String> = ["PlazaLiveWindowTests.swift", "PlazaWindowRig+Mac.swift", "PlazaNoWindowsOrderedInScanTests+Mac.swift"]
    private static let patterns = ["orderFront(", "orderFrontRegardless(", "makeKeyAndOrderFront(", "orderIn(", "NSApp.activate(", ".activate(ignoringOtherApps", "NSApplication.shared.activate("]

    func testNoPlazaTestFileOutsideTheAllowListOrdersAWindowIn() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)).compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 100)
        var offenders: [String] = []
        for file in files where file.lastPathComponent.hasPrefix("Plaza") && !Self.allowed.contains(file.lastPathComponent) {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") && Self.patterns.contains(where: { line.contains($0) }) {
                offenders.append("\(file.lastPathComponent):\(n + 1)")
            }
        }
        XCTAssertEqual(offenders, [], "these Plaza tests order a window in or activate the app; gate them with PTB_PLAZA_LIVE_WINDOW and add them to the allow-list")
        // The allow-listed rig only orders a window in under `live`.
        let rig = try String(contentsOf: root.appendingPathComponent("PlazaWindowRig+Mac.swift"), encoding: .utf8)
        let orderLine = try XCTUnwrap(rig.split(separator: "\n").firstIndex { $0.contains("window.orderFront(nil)") })
        let before = rig.split(separator: "\n").prefix(orderLine).suffix(3).joined(separator: "\n")
        XCTAssertTrue(before.contains("if live"), "the rig's orderFront is inside `if live`")
    }
}
