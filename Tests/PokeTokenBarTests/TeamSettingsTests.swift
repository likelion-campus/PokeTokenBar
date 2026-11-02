import SwiftUI
import XCTest
@testable import PokeTokenBar

@MainActor
final class TeamSettingsTests: XCTestCase {
    nonisolated(unsafe) private var suites: [String] = []

    private func freshDefaults() -> UserDefaults {
        let name = UUID().uuidString
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    // MARK: - 저장한 팀

    private func code(_ seed: UInt64) -> TeamCode {
        var rng = SeededRNG(seed: seed)
        return TeamCode.generate(using: &rng)
    }

    func testEveryJoinedTeamIsSavedOnceWithANumberedName() {
        let team = TeamSettings(defaults: freshDefaults())
        let a = code(1), b = code(2)
        team.code = a
        team.code = b
        team.code = a
        XCTAssertEqual(team.savedTeams.map(\.code), [a.normalized, b.normalized])
        XCTAssertEqual(team.savedTeams.map(\.name), ["팀 1", "팀 2"])
        XCTAssertEqual(team.currentTeam?.code, a.normalized)
    }

    func testTheCodeOfAnEarlierVersionBecomesASavedTeam() {
        let d = freshDefaults()
        d.set(code(3).normalized, forKey: "team.code")
        let team = TeamSettings(defaults: d)
        XCTAssertEqual(team.savedTeams.map(\.code), [code(3).normalized])
    }

    func testSwitchingAndSteppingOutKeepEveryTeam() {
        let team = TeamSettings(defaults: freshDefaults())
        team.isEnabled = true
        team.code = code(1); team.code = code(2)
        team.switchTo(team.savedTeams[0])
        XCTAssertEqual(team.code, code(1))
        team.stepOut()
        XCTAssertNil(team.code)
        XCTAssertTrue(team.isEnabled, "stepping out leaves the team feature on")
        XCTAssertEqual(team.savedTeams.count, 2)
    }

    func testLeavingRemovesOnlyTheCurrentTeam() {
        let team = TeamSettings(defaults: freshDefaults())
        team.code = code(1); team.code = code(2)
        team.leaveTeam()
        XCTAssertEqual(team.savedTeams.map(\.code), [code(1).normalized])
        XCTAssertNil(team.code)
    }

    func testRenamingFollowsTheNicknameRulesAndIsKept() {
        let d = freshDefaults()
        let team = TeamSettings(defaults: d)
        XCTAssertFalse(team.renameCurrentTeam("개발팀"), "no current team")
        team.code = code(1)
        XCTAssertTrue(team.renameCurrentTeam("  개발팀 "))
        XCTAssertFalse(team.renameCurrentTeam(""))
        XCTAssertFalse(team.renameCurrentTeam(String(repeating: "가", count: 13)))
        XCTAssertEqual(team.currentTeam?.name, "개발팀")
        XCTAssertEqual(TeamSettings(defaults: d).savedTeams.map(\.name), ["개발팀"])
    }

    func testBrokenSavedEntriesAreDropped() throws {
        let d = freshDefaults()
        let entries = [TeamSettings.SavedTeam(code: "NOT-A-CODE", name: "x"), TeamSettings.SavedTeam(code: code(4).normalized, name: "y")]
        d.set(try JSONEncoder().encode(entries), forKey: "team.saved")
        XCTAssertEqual(TeamSettings(defaults: d).savedTeams.map(\.name), ["y"])
    }

    override func tearDown() {
        for s in suites { UserDefaults().removePersistentDomain(forName: s) }
        suites = []
        super.tearDown()
    }

    func testDefaultsAreOffAndNotReady() {
        let s = TeamSettings(defaults: freshDefaults())
        XCTAssertFalse(s.isEnabled); XCTAssertFalse(s.isReady)
        XCTAssertTrue(s.notificationsEnabled)
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

    /// A zero-width-joiner chain is one Character of any byte length, so the Character count is no size bound.
    func testNicknameIsBoundedBySizeNotCharacterCount() {
        func chain(_ links: Int) -> String { "👨" + String(repeating: "\u{200D}👨", count: links) }
        XCTAssertEqual(chain(1_000).count, 1, "precondition: the whole chain is a single Character")
        XCTAssertNil(TeamSettings.validNickname(chain(1_000)))
        XCTAssertNil(TeamSettings.validNickname(chain(46)), "326 bytes")
        XCTAssertNotNil(TeamSettings.validNickname(chain(45)), "319 bytes")
        XCTAssertNil(TeamSettings.validNickname(String(repeating: "a", count: 321)))
    }

    func testPersistsAndIsReady() {
        let d = freshDefaults()
        var rng = SeededRNG(seed: 3)
        let code = TeamCode.generate(using: &rng)
        let s = TeamSettings(defaults: d)
        s.code = code; s.nickname = "민수"; s.isEnabled = true
        s.notificationsEnabled = false
        XCTAssertTrue(s.isReady)
        let t = TeamSettings(defaults: d)
        XCTAssertEqual(t.code, code); XCTAssertEqual(t.nickname, "민수")
        XCTAssertTrue(t.isEnabled); XCTAssertFalse(t.notificationsEnabled)
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

    func testSuiteNameIsNilForDefaultDirectoryAndStableHashOtherwise() {
        let def = URL(fileURLWithPath: "/tmp/ptb-default", isDirectory: true)
        XCTAssertNil(TeamSettings.suiteName(for: def, defaultDirectory: def))
        let dev = URL(fileURLWithPath: "/tmp/ptb-dev/../ptb-dev2", isDirectory: true)
        let a = TeamSettings.suiteName(for: dev, defaultDirectory: def)
        XCTAssertEqual(a, TeamSettings.suiteName(for: URL(fileURLWithPath: "/tmp/ptb-dev2"), defaultDirectory: def))
        XCTAssertTrue(a?.hasPrefix("ptb.team.") == true)
        XCTAssertEqual(a?.count, "ptb.team.".count + 12)
        XCTAssertNotEqual(a, TeamSettings.suiteName(for: URL(fileURLWithPath: "/tmp/other"), defaultDirectory: def))
    }

    func testDraftCommitStoresAValidNameAndKeepsAnInvalidOne() {
        let suite = "ptb.test.team.draft.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let team = TeamSettings(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertNil(TeamSettingsSection.committedDraft(nil, into: team))
        XCTAssertEqual(TeamSettingsSection.committedDraft("", into: team), "")
        XCTAssertEqual(team.nickname, "")
        XCTAssertNil(TeamSettingsSection.committedDraft(" 다람 ", into: team))
        XCTAssertEqual(team.nickname, "다람")
        let tooLong = String(repeating: "가", count: 13)
        XCTAssertEqual(TeamSettingsSection.committedDraft(tooLong, into: team), tooLong)
        XCTAssertEqual(team.nickname, "다람", "an invalid draft never replaces the stored name")
    }

    /// The masked code is wider than its row in the popover; wrapping it broke the row into two uneven lines.
    func testJoinedCodeStaysOnOneLineInThePopover() {
        let team = TeamSettings(defaults: freshDefaults())
        team.isEnabled = true
        team.nickname = "다람"
        var rng = SystemRandomNumberGenerator()
        team.code = TeamCode.generate(using: &rng)
        func height(width: CGFloat) -> CGFloat {
            NSHostingView(rootView: TeamSettingsSection().environment(team).frame(width: width)).fittingSize.height
        }
        XCTAssertEqual(height(width: PopoverMetrics.width - 24), height(width: 1000))
    }
}
