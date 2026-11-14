import XCTest
@testable import PokeTokenBar

final class SettingsPlistGuardTests: XCTestCase {
    private var dir: URL!
    private var plist: URL!
    private var logs: [String] = []

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        plist = dir.appendingPathComponent("Settings.plist")
        logs = []
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func plistData(_ value: String) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ["k": value, "team.memberID": "M-\(value)"], format: .xml, options: 0)
    }

    private func value() throws -> String? {
        let d = try Data(contentsOf: plist)
        return (try PropertyListSerialization.propertyList(from: d, options: [], format: nil) as? [String: Any])?["k"] as? String
    }

    private func restore() -> SettingsPlistGuard.Outcome {
        SettingsPlistGuard.restoreIfNeeded(plist: plist) { self.logs.append($0) }
    }

    func testTruncatedPlistComesBackFromTheBackup() throws {
        let good = try plistData("saved")
        try good.write(to: SettingsPlistGuard.backupURL(for: plist))
        try good.prefix(good.count / 2).write(to: plist)
        XCTAssertEqual(restore(), .restored)
        XCTAssertEqual(try value(), "saved")
        XCTAssertEqual(logs.count, 1)
    }

    func testGarbageAndEmptyPlistsComeBack() throws {
        try plistData("saved").write(to: SettingsPlistGuard.backupURL(for: plist))
        for bad in [Data("garbage \u{0}".utf8), Data(), Data("<plist><array/></plist>".utf8)] {
            try bad.write(to: plist)
            XCTAssertEqual(restore(), .restored)
            XCTAssertEqual(try value(), "saved")
        }
    }

    func testMissingPlistComesBackFromTheBackup() throws {
        try plistData("saved").write(to: SettingsPlistGuard.backupURL(for: plist))
        XCTAssertEqual(restore(), .restored)
        XCTAssertEqual(try value(), "saved")
    }

    func testBadPlistWithoutABackupStartsCleanAndLogs() throws {
        try Data("garbage".utf8).write(to: plist)
        XCTAssertEqual(restore(), .startsClean)
        XCTAssertEqual(logs.count, 1)
        try Data("garbage".utf8).write(to: SettingsPlistGuard.backupURL(for: plist))
        XCTAssertEqual(restore(), .startsClean, "a bad backup is not restored either")
    }

    func testFirstRunHasNothingToDo() {
        XCTAssertEqual(restore(), .nothing)
        XCTAssertEqual(logs, [])
    }

    func testAGoodPlistIsNeverOverwrittenByAnOlderBackup() throws {
        try plistData("old").write(to: SettingsPlistGuard.backupURL(for: plist))
        try plistData("new").write(to: plist)
        XCTAssertEqual(restore(), .untouched)
        XCTAssertEqual(try value(), "new")
    }

    func testBackUpOnlyWhatParses() throws {
        try plistData("v1").write(to: plist)
        XCTAssertTrue(SettingsPlistGuard.backUpIfValid(plist: plist))
        try Data("torn".utf8).write(to: plist)
        XCTAssertFalse(SettingsPlistGuard.backUpIfValid(plist: plist))
        let kept = try Data(contentsOf: SettingsPlistGuard.backupURL(for: plist))
        XCTAssertTrue(SettingsPlistGuard.parses(kept), "a torn plist must not replace the good backup")
        XCTAssertEqual(try PropertyListSerialization.propertyList(from: kept, options: [], format: nil) as? [String: String],
                       ["k": "v1", "team.memberID": "M-v1"])
    }
}
