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
        XCTAssertEqual(SettingsPlistGuard.backUp(plist: plist), .written)
        try Data("torn".utf8).write(to: plist)
        XCTAssertEqual(SettingsPlistGuard.backUp(plist: plist), .invalid)
        let kept = try Data(contentsOf: SettingsPlistGuard.backupURL(for: plist))
        XCTAssertTrue(SettingsPlistGuard.parses(kept), "a torn plist must not replace the good backup")
        XCTAssertEqual(try PropertyListSerialization.propertyList(from: kept, options: [], format: nil) as? [String: String],
                       ["k": "v1", "team.memberID": "M-v1"])
    }

    // MARK: a good backup is never replaced by lost settings

    private func plist(_ dict: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }

    private func backupMemberID() throws -> String? {
        let d = try Data(contentsOf: SettingsPlistGuard.backupURL(for: plist))
        return (try PropertyListSerialization.propertyList(from: d, options: [], format: nil) as? [String: Any])?["team.memberID"] as? String
    }

    func testBackupRefusesANewMemberIDAndKeepsTheOldBackup() throws {
        try plist(["team.memberID": "A", "k": "good"]).write(to: SettingsPlistGuard.backupURL(for: plist))
        try plist(["team.memberID": "B"]).write(to: plist)  // CF fell back to empty, the app minted a new id
        guard case .refused = SettingsPlistGuard.backUp(plist: plist) else { return XCTFail("a different memberID replaced the backup") }
        XCTAssertEqual(try backupMemberID(), "A")
        try plist(["k": "no id at all"]).write(to: plist)
        guard case .refused = SettingsPlistGuard.backUp(plist: plist) else { return XCTFail("a plist without memberID replaced the backup") }
        XCTAssertEqual(try backupMemberID(), "A")
    }

    func testBackupFollowsSettingsThatKeepTheMemberID() throws {
        try plist(["team.memberID": "A", "k": "old"]).write(to: SettingsPlistGuard.backupURL(for: plist))
        try plist(["team.memberID": "A", "k": "new"]).write(to: plist)
        XCTAssertEqual(SettingsPlistGuard.backUp(plist: plist), .written)
        XCTAssertEqual(try backupMemberID(), "A")
    }

    func testFirstBackupAndABackupWithoutAnIDAreAccepted() throws {
        try plist(["team.memberID": "A"]).write(to: plist)
        XCTAssertEqual(SettingsPlistGuard.backUp(plist: plist), .written)
        try plist(["k": "v"]).write(to: SettingsPlistGuard.backupURL(for: plist))
        try plist(["team.memberID": "B"]).write(to: plist)
        XCTAssertEqual(SettingsPlistGuard.backUp(plist: plist), .written, "an old backup that never had an id is not protected")
    }

    func testOnlyAGoodLaunchAllowsBackups() {
        typealias O = SettingsPlistGuard.Outcome
        XCTAssertEqual([O.untouched, .restored, .nothing].map(\.allowsBackups), [true, true, true])
        XCTAssertEqual([O.startsClean, .restoreFailed, .leftAlone].map(\.allowsBackups), [false, false, false])
    }

    /// Exists but cannot be read (a directory stands in for a sharing violation): not "missing", never restored over.
    func testAnUnreadablePlistIsLeftAloneEvenWithABackup() throws {
        try plist(["team.memberID": "A"]).write(to: SettingsPlistGuard.backupURL(for: plist))
        try FileManager.default.createDirectory(at: plist, withIntermediateDirectories: false)
        XCTAssertEqual(restore(), .leftAlone)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: plist.path, isDirectory: &isDir) && isDir.boolValue)
        XCTAssertEqual(logs.count, 1)
    }

    /// The exact sequence: the launch could not restore, the session then writes a new id.
    func testSequenceFailedLaunchThenANewIDLeavesTheGoodBackup() throws {
        #if os(Windows)
        throw XCTSkip("POSIX permission bits do not make a file unreadable on Windows")
        #endif
        try plist(["team.memberID": "A", "k": "good"]).write(to: SettingsPlistGuard.backupURL(for: plist))
        try Data("garbage".utf8).write(to: plist)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: SettingsPlistGuard.backupURL(for: plist).path)
        let outcome = restore()   // the backup cannot be read: no usable backup
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: SettingsPlistGuard.backupURL(for: plist).path)
        XCTAssertFalse(outcome.allowsBackups)
        try plist(["team.memberID": "B"]).write(to: plist)
        guard case .refused = SettingsPlistGuard.backUp(plist: plist) else { return XCTFail("backup replaced") }
        XCTAssertEqual(try backupMemberID(), "A")
    }
}
