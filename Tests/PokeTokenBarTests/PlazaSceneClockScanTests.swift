import XCTest

/// Mechanical guard: a plaza scene built in a test must have its clock pinned to a fixed date.
///
/// `PlazaScene.now` defaults to `Date()`. A bare scene therefore takes four things from the wall clock: the item of the
/// current 20-minute slot (a child of `root`, the `itemTile`, items in the photo), the daylight tint, the season when it
/// follows the calendar, and the snow day with the frozen ponds. A test that never sets `now` is green or red depending
/// on when it runs: `PlazaSteamLayerTests.testThePoolIsMadeOnceAndNeverGrows` failed once on CI because the slot item
/// left the ground at 09:40:00 UTC in the middle of its loop (see docs/reference/defect-log.md).
///
/// What this checks, honestly: a TEXT scan. Every line that constructs `PlazaScene(` in a test file must be followed,
/// within `window` lines, by `pinPlazaClock(` or an assignment to `.now`. It does not prove the pin is the right
/// instant, nor that a later reassignment keeps it; it catches the case that bit us, a scene nobody pinned at all.
/// The allowlist is empty; an entry would need a reason next to it.
final class PlazaSceneClockScanTests: XCTestCase {
    private static let window = 14
    private static let allowlist: [String: String] = [:]

    func testEveryPlazaSceneBuiltByATestPinsItsClock() throws {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var offenders: [String] = []
        let files = try XCTUnwrap(FileManager.default.enumerator(at: testsDir, includingPropertiesForKeys: nil))
        for case let url as URL in files where url.pathExtension == "swift" {
            let name = url.lastPathComponent
            guard name != "PlazaSceneClockScanTests.swift", Self.allowlist[name] == nil else { continue }
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            for (i, line) in lines.enumerated() where Self.constructsAScene(line) {
                let tail = lines[i..<min(lines.count, i + Self.window)]
                if !tail.contains(where: { $0.contains("pinPlazaClock(") || $0.contains(".now = ") }) {
                    offenders.append("\(name):\(i + 1)")
                }
            }
        }
        XCTAssertEqual(offenders, [], "pin the scene's clock with pinPlazaClock(_:) (a fixed date): the wall clock changes the slot item, the tint, the season and the snow")
    }

    private static func constructsAScene(_ line: String) -> Bool {
        let code = line.trimmingCharacters(in: .whitespaces)
        return code.contains("PlazaScene(") && !code.hasPrefix("//")
    }
}
