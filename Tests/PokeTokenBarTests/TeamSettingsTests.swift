import XCTest
@testable import PokeTokenBar

@MainActor
final class TeamSettingsTests: XCTestCase {
    private var suites: [String] = []

    private func freshDefaults() -> UserDefaults {
        let name = UUID().uuidString
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    override func tearDown() {
        for s in suites { UserDefaults().removePersistentDomain(forName: s) }
        suites = []
        super.tearDown()
    }

    func testDefaultsAreOffAndNotReady() {
        let s = TeamSettings(defaults: freshDefaults())
        XCTAssertFalse(s.isEnabled); XCTAssertFalse(s.isReady)
        XCTAssertTrue(s.visitsEnabled); XCTAssertTrue(s.notificationsEnabled)
        XCTAssertNil(s.code); XCTAssertEqual(s.nickname, "")
    }

    func testMemberIDIsStableAcrossInstances() {
        let d = freshDefaults()
        XCTAssertEqual(TeamSettings(defaults: d).memberID, TeamSettings(defaults: d).memberID)
        XCTAssertNotEqual(TeamSettings(defaults: freshDefaults()).memberID, TeamSettings(defaults: d).memberID)
    }

    func testNicknameValidation() {
        XCTAssertEqual(TeamSettings.validNickname("  민수 "), "민수")
        XCTAssertNil(TeamSettings.validNickname("   "))
        XCTAssertNil(TeamSettings.validNickname(String(repeating: "가", count: 13)))
        XCTAssertEqual(TeamSettings.validNickname(String(repeating: "가", count: 12)), String(repeating: "가", count: 12))
        XCTAssertEqual(TeamSettings.validNickname("🐣🐣"), "🐣🐣")
        XCTAssertNil(TeamSettings.validNickname("a\nb"))
    }

    func testPersistsAndIsReady() {
        let d = freshDefaults()
        var rng = SeededRNG(seed: 3)
        let code = TeamCode.generate(using: &rng)
        let s = TeamSettings(defaults: d)
        s.code = code; s.nickname = "민수"; s.isEnabled = true
        s.visitsEnabled = false; s.notificationsEnabled = false
        XCTAssertTrue(s.isReady)
        let t = TeamSettings(defaults: d)
        XCTAssertEqual(t.code, code); XCTAssertEqual(t.nickname, "민수")
        XCTAssertTrue(t.isEnabled); XCTAssertFalse(t.visitsEnabled); XCTAssertFalse(t.notificationsEnabled)
    }

    func testLeaveTeamKeepsIdentity() {
        let d = freshDefaults()
        var rng = SeededRNG(seed: 3)
        let s = TeamSettings(defaults: d)
        s.code = TeamCode.generate(using: &rng); s.nickname = "민수"; s.isEnabled = true
        let id = s.memberID
        s.leaveTeam()
        XCTAssertNil(s.code); XCTAssertFalse(s.isEnabled)
        XCTAssertEqual(s.memberID, id); XCTAssertEqual(s.nickname, "민수")
        XCTAssertNil(TeamSettings(defaults: d).code)
    }
}
