import SwiftUI
import XCTest
@testable import PokeTokenBar

@MainActor
final class TeamSettingsTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = UUID().uuidString
        return TestDefaults.make(suite: name)
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
        s.changeSchedule(coreStart: 8, coreEnd: 20, season: .spring, now: now)
        XCTAssertEqual(s.schedule?.changedAt, now)
        XCTAssertEqual(s.schedule?.changedBy, s.memberID)
        XCTAssertEqual(s.schedule?.changedByName, "Ash")
        XCTAssertEqual(s.schedule?.season, .spring)
        for (input, expected) in [((16, 10), (16, 17)), ((0, 30), (1, 23)), ((23, 23), (22, 23)), ((22, 5), (22, 23))] {
            s.changeSchedule(coreStart: input.0, coreEnd: input.1, season: .winter, now: now)
            XCTAssertEqual(s.schedule?.coreStart, expected.0)
            XCTAssertEqual(s.schedule?.coreEnd, expected.1)
        }
    }

    func testChangeScheduleBeatsAStoredStampAheadOfThisClock() {
        let s = TeamSettings(defaults: freshDefaults())
        s.code = code(1)
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(s.adoptSchedule(schedule(1_300, start: 7), now: now))
        s.changeSchedule(coreStart: 11, coreEnd: 15, season: .winter, now: now)
        XCTAssertEqual(s.schedule?.coreStart, 11)
        XCTAssertGreaterThan(s.schedule!.changedAt, Date(timeIntervalSince1970: 1_300))
    }

    func testReselectingTheCurrentValueDoesNotRestamp() {
        let s = TeamSettings(defaults: freshDefaults())
        s.code = code(1)
        s.changeSchedule(coreStart: PlazaCoreTime.standard.start, coreEnd: PlazaCoreTime.standard.end, season: .winter, now: Date(timeIntervalSince1970: 1))
        XCTAssertNil(s.schedule, "the default is not a change")
        s.changeSchedule(coreStart: 8, coreEnd: 20, season: .autumn, now: Date(timeIntervalSince1970: 2))
        s.changeSchedule(coreStart: 8, coreEnd: 20, season: .autumn, now: Date(timeIntervalSince1970: 3))
        XCTAssertEqual(s.schedule?.changedAt, Date(timeIntervalSince1970: 2))
    }

    func testChangedByNameIsEmptyWhenTheNicknameIsInvalid() {
        let s = TeamSettings(defaults: freshDefaults())
        s.code = code(1)
        s.nickname = "  "
        s.changeSchedule(coreStart: 8, coreEnd: 20, season: .autumn, now: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(s.schedule?.changedByName, "")
    }

    func testChangeScheduleWithoutTeamDoesNothing() {
        let s = TeamSettings(defaults: freshDefaults())
        s.changeSchedule(coreStart: 9, coreEnd: 18, season: .winter, now: Date())
        XCTAssertNil(s.schedule)
    }

    func testScheduleIsPersistedPerTeam() {
        let d = freshDefaults()
        let s = TeamSettings(defaults: d)
        s.code = code(1)
        s.changeSchedule(coreStart: 9, coreEnd: 18, season: .autumn, now: Date(timeIntervalSince1970: 5))
        XCTAssertEqual(TeamSettings(defaults: d).schedule?.coreStart, 9)
        s.code = code(2)
        XCTAssertNil(s.schedule)
        s.changeSchedule(coreStart: 11, coreEnd: 12, season: .winter, now: Date(timeIntervalSince1970: 6))
        s.code = code(1)
        XCTAssertEqual(s.schedule?.coreStart, 9)
        s.code = code(2)
        XCTAssertEqual(s.schedule?.coreStart, 11)
    }

    /// 피어가 보낸 문자열은 저장되어 이후 모든 presence 에 실린다. 닉네임 상한을 넘으면 받지 않는다.
    func testAdoptScheduleRejectsOversizedPeerStrings() {
        let s = TeamSettings(defaults: freshDefaults())
        s.code = code(1)
        let now = Date(timeIntervalSince1970: 10_000)
        var base = schedule(10_000)
        func tried(_ edit: (inout PlazaSchedule) -> Void) -> Bool {
            var c = base
            edit(&c)
            return s.adoptSchedule(c, now: now)
        }
        XCTAssertFalse(tried { $0.changedByName = String(repeating: "가", count: 300_000) })   // ~900 KB
        XCTAssertFalse(tried { $0.changedByName = "열두글자를넘는아주긴이름입니다" })
        XCTAssertFalse(tried { $0.changedBy = String(repeating: "x", count: 65) })
        XCTAssertFalse(tried { $0.seasonPeriod = String(repeating: "x", count: 17) })
        XCTAssertNil(s.schedule)
        base.changedByName = ""
        XCTAssertTrue(s.adoptSchedule(base, now: now), "an unnamed change is fine")
    }

    func testChangeScheduleAfterAdoptingAnUnknownPeriodIsNotDropped() {
        let s = TeamSettings(defaults: freshDefaults())
        s.code = code(1)
        var later = schedule(100)
        later.seasonPeriod = "quarter"
        XCTAssertTrue(s.adoptSchedule(later, now: Date(timeIntervalSince1970: 200)))
        s.changeSchedule(coreStart: 9, coreEnd: 18, season: .winter, now: Date(timeIntervalSince1970: 150))
        XCTAssertEqual(s.schedule?.seasonPeriod, "winter")
        XCTAssertGreaterThan(s.schedule?.changedAt ?? .distantPast, later.changedAt)
    }

    func testLeaveTeamForgetsItsSchedule() {
        let d = freshDefaults()
        let s = TeamSettings(defaults: d)
        s.code = code(1)
        s.changeSchedule(coreStart: 9, coreEnd: 18, season: .autumn, now: Date(timeIntervalSince1970: 5))
        s.leaveTeam()
        s.code = code(1)
        XCTAssertNil(s.schedule)
        XCTAssertNil(TeamSettings(defaults: d).schedule)
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
        XCTAssertFalse(s.adoptSchedule(schedule(10_700, start: 16, end: 10), now: Date(timeIntervalSince1970: 10_500)))   // newer, so only the range check can reject it
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
        XCTAssertFalse(team.renameCurrentTeam("개발팀", now: Date()), "no current team")
        team.code = code(1)
        XCTAssertTrue(team.renameCurrentTeam("  개발팀 ", now: Date()))
        XCTAssertFalse(team.renameCurrentTeam("", now: Date()))
        XCTAssertFalse(team.renameCurrentTeam(String(repeating: "가", count: 13), now: Date()))
        XCTAssertEqual(team.currentTeam?.name, "개발팀")
        XCTAssertEqual(TeamSettings(defaults: d).savedTeams.map(\.name), ["개발팀"])
    }

    func testBrokenSavedEntriesAreDropped() throws {
        let d = freshDefaults()
        let entries = [TeamSettings.SavedTeam(code: "NOT-A-CODE", name: "x"), TeamSettings.SavedTeam(code: code(4).normalized, name: "y")]
        d.set(try JSONEncoder().encode(entries), forKey: "team.saved")
        XCTAssertEqual(TeamSettings(defaults: d).savedTeams.map(\.name), ["y"])
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
        let team = TeamSettings(defaults: TestDefaults.make(suite: suite))
        XCTAssertNil(TeamSetup.committedDraft(nil, into: team))
        XCTAssertEqual(TeamSetup.committedDraft("", into: team), "")
        XCTAssertEqual(team.nickname, "")
        XCTAssertNil(TeamSetup.committedDraft(" 다람 ", into: team))
        XCTAssertEqual(team.nickname, "다람")
        let tooLong = String(repeating: "가", count: 13)
        XCTAssertEqual(TeamSetup.committedDraft(tooLong, into: team), tooLong)
        XCTAssertEqual(team.nickname, "다람", "an invalid draft never replaces the stored name")
    }

    /// Joining with a code opens the plaza at once, or as soon as a nickname is set.
    func testJoinOpensThePlazaWhenTheTeamIsReady() {
        let team = TeamSettings(defaults: freshDefaults())
        team.isEnabled = true
        var rng = SystemRandomNumberGenerator()
        let code = TeamCode.generate(using: &rng)
        XCTAssertEqual(TeamSetup.join("PTB-nope", into: team), .invalid)
        XCTAssertNil(team.code)
        XCTAssertEqual(TeamSetup.join(code.display, into: team), .needsNickname)
        XCTAssertEqual(team.code, code)
        team.stepOut()
        team.nickname = "다람"
        XCTAssertEqual(TeamSetup.join(" \(code.display) ", into: team), .openPlaza)
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

    // MARK: - 팀 이름 동기화

    private func stamp(_ name: String = "디자인", _ at: TimeInterval, by: String = "m") -> TeamNameStamp {
        TeamNameStamp(name: name, changedAt: Date(timeIntervalSince1970: at), changedBy: by)
    }

    func testCreateTeamNamesAndStampsTheTeam() {
        let s = TeamSettings(defaults: freshDefaults())
        let now = Date(timeIntervalSince1970: 500)
        XCTAssertTrue(s.createTeam(code: code(1), named: "  개발팀 ", now: now))
        XCTAssertEqual(s.code, code(1))
        XCTAssertEqual(s.currentTeam?.name, "개발팀")
        XCTAssertEqual(s.teamNameStamp, TeamNameStamp(name: "개발팀", changedAt: now, changedBy: s.memberID))
    }

    func testCreateTeamRejectsAnInvalidNameAndChangesNothing() {
        let s = TeamSettings(defaults: freshDefaults())
        for bad in ["", "   ", String(repeating: "가", count: 13), "가\n나"] {
            XCTAssertFalse(s.createTeam(code: code(1), named: bad, now: Date()), bad)
        }
        XCTAssertNil(s.code)
        XCTAssertTrue(s.savedTeams.isEmpty)
    }

    func testJoiningLeavesTheDefaultNameUnstamped() {
        let s = TeamSettings(defaults: freshDefaults())
        s.code = code(1)
        XCTAssertEqual(s.currentTeam?.name, "팀 1")
        XCTAssertNil(s.teamNameStamp)
    }

    func testRenameStampsOnlyARealChange() {
        let s = TeamSettings(defaults: freshDefaults())
        s.code = code(1)
        XCTAssertTrue(s.renameCurrentTeam("개발팀", now: Date(timeIntervalSince1970: 10)))
        XCTAssertEqual(s.teamNameStamp, stamp("개발팀", 10, by: s.memberID))
        XCTAssertTrue(s.renameCurrentTeam(" 개발팀 ", now: Date(timeIntervalSince1970: 20)))
        XCTAssertEqual(s.teamNameStamp?.changedAt, Date(timeIntervalSince1970: 10), "the same name keeps its stamp")
        XCTAssertFalse(s.renameCurrentTeam("", now: Date(timeIntervalSince1970: 30)))
        XCTAssertEqual(s.teamNameStamp?.changedAt, Date(timeIntervalSince1970: 10))
    }

    func testRenameBeatsAStoredStampAheadOfThisClock() {
        let s = TeamSettings(defaults: freshDefaults())
        s.code = code(1)
        XCTAssertTrue(s.adoptTeamName(stamp("디자인", 1_300), now: Date(timeIntervalSince1970: 1_000)))
        XCTAssertTrue(s.renameCurrentTeam("개발팀", now: Date(timeIntervalSince1970: 1_000)))
        XCTAssertEqual(s.currentTeam?.name, "개발팀")
        XCTAssertGreaterThan(s.teamNameStamp!.changedAt, Date(timeIntervalSince1970: 1_300))
    }

    func testAdoptTeamNameLastWriterWins() {
        let s = TeamSettings(defaults: freshDefaults())
        s.code = code(1)
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(s.adoptTeamName(stamp("가", 100, by: "b"), now: now))
        XCTAssertEqual(s.currentTeam?.name, "가")
        XCTAssertFalse(s.adoptTeamName(stamp("나", 99, by: "z"), now: now))      // older
        XCTAssertFalse(s.adoptTeamName(stamp("나", 100, by: "a"), now: now))     // tie, lesser id
        XCTAssertFalse(s.adoptTeamName(stamp("가", 100, by: "b"), now: now))     // identical
        XCTAssertTrue(s.adoptTeamName(stamp("다", 100, by: "c"), now: now))      // tie, greater id
        XCTAssertEqual(s.currentTeam?.name, "다")
        XCTAssertTrue(s.adoptTeamName(stamp("라", 101, by: "a"), now: now))      // newer
        XCTAssertEqual(s.currentTeam?.name, "라")
    }

    func testAdoptTeamNameRejectsWhatIsNotAValidName() {
        let s = TeamSettings(defaults: freshDefaults())
        s.code = code(1)
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(s.adoptTeamName(stamp("디자인", 10_601), now: Date(timeIntervalSince1970: 10_000)), "more than 600 s ahead")
        XCTAssertFalse(s.adoptTeamName(stamp(" 디자인", 10), now: now), "untrimmed")
        XCTAssertFalse(s.adoptTeamName(stamp("디자인 ", 10), now: now), "untrimmed")
        XCTAssertFalse(s.adoptTeamName(stamp(String(repeating: "가", count: 13), 10), now: now))
        XCTAssertFalse(s.adoptTeamName(stamp("", 10), now: now))
        XCTAssertFalse(s.adoptTeamName(stamp("디자인", 10, by: String(repeating: "x", count: 65)), now: now))
        XCTAssertNil(s.teamNameStamp)
        XCTAssertEqual(s.currentTeam?.name, "팀 1")
        XCTAssertTrue(s.adoptTeamName(stamp("디자인", 1_600, by: String(repeating: "x", count: 64)), now: now), "600 s and 64 bytes are fine")
    }

    func testAdoptTeamNameWithoutATeamOrAnEntryDoesNothing() {
        let s = TeamSettings(defaults: freshDefaults())
        XCTAssertFalse(s.adoptTeamName(stamp("디자인", 10), now: Date(timeIntervalSince1970: 100)))
        s.code = code(1)
        s.leaveTeam()
        XCTAssertFalse(s.adoptTeamName(stamp("디자인", 10), now: Date(timeIntervalSince1970: 100)))
        XCTAssertTrue(s.savedTeams.isEmpty)
    }

    func testAnOldSavedTeamReadsAndTheStampPersists() throws {
        let d = freshDefaults()
        let old = #"[{"code":"\#(code(1).normalized)","name":"팀 1"}]"#
        d.set(Data(old.utf8), forKey: "team.saved")
        let s = TeamSettings(defaults: d)
        XCTAssertEqual(s.savedTeams.map(\.name), ["팀 1"])
        s.code = code(1)
        XCTAssertTrue(s.renameCurrentTeam("개발팀", now: Date(timeIntervalSince1970: 10)))
        XCTAssertEqual(TeamSettings(defaults: d).savedTeams.first?.nameChangedAt, Date(timeIntervalSince1970: 10))
        XCTAssertEqual(TeamSettings(defaults: d).savedTeams.first?.nameChangedBy, s.memberID)
    }

    func testMigrationStampsOnlyRenamedNamesOnceAndLosesToANewerName() throws {
        let d = freshDefaults()
        let saved = [TeamSettings.SavedTeam(code: code(1).normalized, name: "개발팀"),
                     TeamSettings.SavedTeam(code: code(2).normalized, name: "팀 7")]
        d.set(try JSONEncoder().encode(saved), forKey: "team.saved")
        d.set("me", forKey: "team.memberID")
        let s = TeamSettings(defaults: d)
        let epoch = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(s.savedTeams[0].nameChangedAt, epoch)
        XCTAssertEqual(s.savedTeams[0].nameChangedBy, "me")
        XCTAssertNil(s.savedTeams[1].nameChangedAt, "a default name stays unstamped")
        // 두 번째 켜기: 도장이 이미 있으면 그대로.
        s.code = code(1)
        XCTAssertTrue(s.adoptTeamName(stamp("디자인", 5), now: Date(timeIntervalSince1970: 100)))
        let again = TeamSettings(defaults: d)
        XCTAssertEqual(again.savedTeams[0].nameChangedAt, Date(timeIntervalSince1970: 5))
        XCTAssertEqual(again.savedTeams[0].name, "디자인")
    }

    /// The migration's default-name rule is the sheet's `^팀 [0-9]+$`: anything else was a rename and is stamped.
    func testMigrationDefaultNameRuleMatchesTheSheetsPattern() throws {
        let names = ["팀 A", "팀 1a", "팀 -1", "팀 \u{0661}", "팀 12"]
        let d = freshDefaults()
        let saved = names.enumerated().map { TeamSettings.SavedTeam(code: code(UInt64($0.offset + 1)).normalized, name: $0.element) }
        d.set(try JSONEncoder().encode(saved), forKey: "team.saved")
        let s = TeamSettings(defaults: d)
        XCTAssertEqual(s.savedTeams.map { $0.nameChangedAt != nil }, [true, true, true, true, false])
    }

    /// Typed into the team-name field but not submitted, then the team is left, and a new one is made: the half-typed name
    /// must not come back and rename the new team (for everyone).
    func testAHalfTypedTeamNameDoesNotRenameTheNextTeam() throws {
        let team = TeamSettings(defaults: freshDefaults())
        team.isEnabled = true
        team.nickname = "다람"
        team.code = code(1)
        let host = NSHostingView(rootView: TeamSettingsSection().environment(team).frame(width: 360))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let l = L(.ko)
        let nameField = try field(placeholder: l.teamName, in: host)
        XCTAssertTrue(window.makeFirstResponder(nameField))
        let editor = try XCTUnwrap(nameField.currentEditor() as? NSTextView)
        editor.insertText("미완성", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        team.stepOut()   // what "다른 팀 만들기·참여" does; the view must notice the code change itself
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()
        try submit("디자인", in: try field(placeholder: l.teamCreateNamePlaceholder, in: host), window: window)
        XCTAssertEqual(team.currentTeam?.name, "디자인")
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(try field(placeholder: l.teamName, in: host).stringValue, "디자인", "the field shows the new team's name")
        window.contentView = nil   // the field disappears and commits
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(team.currentTeam?.name, "디자인")
    }

    // MARK: - 코드 복사는 클립보드 관리자·유니버설 클립보드를 피한다

    /// 일반 pasteboard 가 아니라 이름 붙은 개인 pasteboard 만 쓴다. 코드는 눈에 띄는 가짜다.
    func testCopiedTeamCodeIsConcealedFromClipboardManagers() {
        let board = NSPasteboard(name: NSPasteboard.Name("ptb.test." + UUID().uuidString))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("an older clipboard text", forType: .string)

        TeamCodePasteboard.write("FAKE-FAKE-FAKE-FAKE", to: board)

        XCTAssertEqual(board.string(forType: .string), "FAKE-FAKE-FAKE-FAKE")
        let types = board.types ?? []
        XCTAssertTrue(types.contains(TeamCodePasteboard.concealedType), "password managers' marker: \(types)")
        XCTAssertTrue(types.contains(TeamCodePasteboard.transientType), "auto-expiry marker: \(types)")
        XCTAssertEqual(TeamCodePasteboard.concealedType.rawValue, "org.nspasteboard.ConcealedType")
        XCTAssertEqual(TeamCodePasteboard.transientType.rawValue, "org.nspasteboard.TransientType")
        // The old contents are gone, not merged into the new item.
        XCTAssertEqual(board.pasteboardItems?.count, 1)
    }
}
