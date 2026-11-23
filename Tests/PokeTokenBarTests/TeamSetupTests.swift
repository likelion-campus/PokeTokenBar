import XCTest
@testable import PokeTokenBar

/// The team section's rules, moved from `TeamSettingsSection` to shared `TeamSetup` (stage 7, Task 1), on both systems.
@MainActor
final class TeamSetupTests: XCTestCase {
    private func team() -> TeamSettings {
        TeamSettings(defaults: TestDefaults.make(suite: "ptb.test.teamsetup.\(UUID().uuidString)"))
    }

    func testDraftCommitStoresAValidNameAndKeepsAnInvalidOne() async {
        let team = team()
        XCTAssertNil(TeamSetup.committedDraft(nil, into: team))
        XCTAssertEqual(TeamSetup.committedDraft("", into: team), "")
        XCTAssertEqual(team.nickname, "")
        XCTAssertNil(TeamSetup.committedDraft(" 다람 ", into: team))
        XCTAssertEqual(team.nickname, "다람")
        let tooLong = String(repeating: "가", count: 13)
        XCTAssertEqual(TeamSetup.committedDraft(tooLong, into: team), tooLong)
        XCTAssertEqual(team.nickname, "다람", "an invalid draft never replaces the stored name")
    }

    func testJoinOpensThePlazaWhenTheTeamIsReady() async {
        let team = team()
        team.isEnabled = true
        var rng = SystemRandomNumberGenerator()
        let code = TeamCode.generate(using: &rng)
        XCTAssertEqual(TeamSetup.join("PTB-nope", into: team), .invalid)
        XCTAssertNil(team.code)
        XCTAssertEqual(TeamSetup.join(code.display, into: team), .needsNickname)
        XCTAssertEqual(team.code, code)
        team.stepOut()
        team.nickname = "다람"
        XCTAssertEqual(TeamSetup.join(" \(code.display) ", into: team), .openPlaza, "a pasted code with spaces still joins")
        XCTAssertTrue(team.isReady)
    }

    /// The old private `TeamSettingsSection.masked`, copied verbatim as the oracle.
    private func oldMasked(_ code: TeamCode) -> String {
        let parts = code.display.split(separator: "-").map(String.init)
        return parts.enumerated().map { $0.offset <= 1 ? $0.element : String(repeating: "•", count: $0.element.count) }
            .joined(separator: "-")
    }

    func testMaskedTextIsTheOldViewsOnFiftyCodes() async {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<50 {
            let code = TeamCode.generate(using: &rng)
            XCTAssertEqual(TeamSetup.masked(code), oldMasked(code), code.display)
            XCTAssertTrue(TeamSetup.masked(code).hasPrefix(code.display.split(separator: "-").prefix(2).joined(separator: "-")))
            XCTAssertTrue(TeamSetup.masked(code).contains("•"), "everything after the first group is hidden")
        }
    }

    func testCreateMakesANamedTeamAndRejectsAnInvalidName() async {
        let team = team()
        let now = Date(timeIntervalSince1970: 700)
        XCTAssertFalse(TeamSetup.create("", into: team, now: now))
        XCTAssertFalse(TeamSetup.create(String(repeating: "가", count: 13), into: team, now: now))
        XCTAssertNil(team.code)
        XCTAssertTrue(TeamSetup.create(" 개발팀 ", into: team, now: now))
        XCTAssertNotNil(team.code)
        XCTAssertEqual(team.currentTeam?.name, "개발팀")
        XCTAssertEqual(team.teamNameStamp?.changedAt, now)
    }
}
