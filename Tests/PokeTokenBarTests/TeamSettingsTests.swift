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
