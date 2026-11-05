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

    func testNameColorIsKeptOnThisMac() {
        let d = freshDefaults()
        let s = TeamSettings(defaults: d)
        XCTAssertNil(s.nameColor)
        s.nameColor = 0xFF9ECF
        XCTAssertEqual(TeamSettings(defaults: d).nameColor, 0xFF9ECF)
        s.nameColor = nil
        XCTAssertNil(TeamSettings(defaults: d).nameColor)
    }

    // MARK: - 광장 일정

    private func schedule(_ at: TimeInterval, by: String = "m", start: Int = 9, end: Int = 18) -> PlazaSchedule {
        PlazaSchedule(coreStart: start, coreEnd: end, seasonPeriod: "week", changedAt: Date(timeIntervalSince1970: at),
                      changedBy: by, changedByName: "N")
    }

    func testChangeScheduleStampsAndClamps() {
        let s = TeamSettings(defaults: freshDefaults())
        s.nickname = "Ash"
        s.code = code(1)
        let now = Date(timeIntervalSince1970: 1_000)
        s.changeSchedule(coreStart: 8, coreEnd: 20, period: .month, now: now)
        XCTAssertEqual(s.schedule?.changedAt, now)
        XCTAssertEqual(s.schedule?.changedBy, s.memberID)
        XCTAssertEqual(s.schedule?.changedByName, "Ash")
        XCTAssertEqual(s.schedule?.period, .month)
        for (input, expected) in [((16, 10), (16, 17)), ((0, 30), (1, 23)), ((23, 23), (22, 23)), ((22, 5), (22, 23))] {
            s.changeSchedule(coreStart: input.0, coreEnd: input.1, period: .day, now: now)
            XCTAssertEqual(s.schedule?.coreStart, expected.0)
            XCTAssertEqual(s.schedule?.coreEnd, expected.1)
        }
    }

    func testChangeScheduleWithoutTeamDoesNothing() {
        let s = TeamSettings(defaults: freshDefaults())
        s.changeSchedule(coreStart: 9, coreEnd: 18, period: .day, now: Date())
        XCTAssertNil(s.schedule)
    }

    func testScheduleIsPersistedPerTeam() {
        let d = freshDefaults()
        let s = TeamSettings(defaults: d)
        s.code = code(1)
        s.changeSchedule(coreStart: 9, coreEnd: 18, period: .week, now: Date(timeIntervalSince1970: 5))
        XCTAssertEqual(TeamSettings(defaults: d).schedule?.coreStart, 9)
        s.code = code(2)
        XCTAssertNil(s.schedule)
        s.changeSchedule(coreStart: 11, coreEnd: 12, period: .day, now: Date(timeIntervalSince1970: 6))
        s.code = code(1)
        XCTAssertEqual(s.schedule?.coreStart, 9)
        s.code = code(2)
        XCTAssertEqual(s.schedule?.coreStart, 11)
    }

    func testAdoptScheduleLastWriterWins() {
        let s = TeamSettings(defaults: freshDefaults())
        s.code = code(1)
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertTrue(s.adoptSchedule(schedule(100, by: "b"), now: now))
        XCTAssertFalse(s.adoptSchedule(schedule(99, by: "z"), now: now))        // older
        XCTAssertFalse(s.adoptSchedule(schedule(100, by: "a"), now: now))       // tie, lesser id
        XCTAssertFalse(s.adoptSchedule(schedule(100, by: "b"), now: now))       // identical
        XCTAssertTrue(s.adoptSchedule(schedule(100, by: "c", start: 7), now: now))   // tie, greater id
        XCTAssertEqual(s.schedule?.coreStart, 7)
        XCTAssertTrue(s.adoptSchedule(schedule(101, by: "a"), now: now))        // newer
    }

    func testAdoptScheduleRejectsFarFutureAndInvalidRange() {
        let s = TeamSettings(defaults: freshDefaults())
        s.code = code(1)
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertFalse(s.adoptSchedule(schedule(10_601), now: now))
        XCTAssertTrue(s.adoptSchedule(schedule(10_600), now: now))
        XCTAssertFalse(s.adoptSchedule(schedule(10_599, start: 16, end: 10), now: now))
        XCTAssertFalse(s.adoptSchedule(schedule(20_000, start: 0, end: 5), now: Date(timeIntervalSince1970: 30_000)))
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

    /// Joining with a code opens the plaza at once, or as soon as a nickname is set.
    func testJoinOpensThePlazaWhenTheTeamIsReady() {
        let team = TeamSettings(defaults: freshDefaults())
        team.isEnabled = true
        var rng = SystemRandomNumberGenerator()
        let code = TeamCode.generate(using: &rng)
        XCTAssertEqual(TeamSettingsSection.join("PTB-nope", into: team), .invalid)
        XCTAssertNil(team.code)
        XCTAssertEqual(TeamSettingsSection.join(code.display, into: team), .needsNickname)
        XCTAssertEqual(team.code, code)
        team.stepOut()
        team.nickname = "다람"
        XCTAssertEqual(TeamSettingsSection.join(" \(code.display) ", into: team), .openPlaza)
        XCTAssertTrue(team.isReady)
    }

    /// The settings section reaches the popover's open-plaza action: Enter in the code field opens the plaza when
    /// the team is ready, and otherwise as soon as a valid nickname is entered.
    func testJoiningFromTheSectionOpensThePlaza() throws {
        for hasNickname in [true, false] {
            let team = TeamSettings(defaults: freshDefaults())
            team.isEnabled = true
            if hasNickname { team.nickname = "다람" }
            let nav = PopoverNavigation()
            var opened = 0
            nav.onOpenPlaza = { opened += 1 }
            let host = NSHostingView(rootView: TeamSettingsSection().environment(team).environment(nav).frame(width: 360))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 400), styleMask: [.titled],
                                  backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            var rng = SystemRandomNumberGenerator()
            let code = TeamCode.generate(using: &rng)
            try submit(code.display, in: try field(placeholder: L(.ko).teamCodePlaceholder, in: host), window: window)
            XCTAssertEqual(team.code, code)
            XCTAssertEqual(opened, hasNickname ? 1 : 0, "nickname set: \(hasNickname)")
            guard !hasNickname else { continue }
            host.layoutSubtreeIfNeeded()
            try submit("다람", in: try field(placeholder: L(.ko).teamNickname, in: host), window: window)
            XCTAssertTrue(team.isReady)
            XCTAssertEqual(opened, 1, "the nickname completes the join")
        }
    }

    private func field(placeholder: String, in view: NSView) throws -> NSTextField {
        func find(_ v: NSView) -> NSTextField? {
            if let f = v as? NSTextField, f.isEditable, f.placeholderString == placeholder || f.placeholderAttributedString?.string == placeholder { return f }
            return v.subviews.lazy.compactMap(find).first
        }
        return try XCTUnwrap(find(view), "no field \(placeholder)")
    }

    private func submit(_ text: String, in field: NSTextField, window: NSWindow) throws {
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.insertText(text, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        editor.insertNewline(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
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
