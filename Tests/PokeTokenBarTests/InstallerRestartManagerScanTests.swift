import XCTest

/// Mechanical guard (defect log, "lost runner in the update jobs"): Setup runs no Restart Manager pass. With
/// `CloseApplications=yes`, a Setup that met a running or just-closed PokeTokenBar took the whole GitHub-hosted VM down in about
/// 2% of such upgrades; with it off, none in over 400. `CloseRunningApp` in the script's [Code] closes the app itself (WM_CLOSE,
/// then it waits for the single-instance mutex), so the pass had nothing to do.
final class InstallerRestartManagerScanTests: XCTestCase {
    func testSetupRunsNoRestartManagerPass() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("installer/PokeTokenBar.iss"), encoding: .utf8)
        let directives = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix(";") && $0.lowercased().hasPrefix("closeapplications") }
        XCTAssertEqual(directives, ["CloseApplications=no"], "installer/PokeTokenBar.iss: keep Inno's Restart Manager pass off (see the defect log)")
    }
}
