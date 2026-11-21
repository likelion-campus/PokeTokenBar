import XCTest
@testable import PokeTokenBar

/// The Windows Settings page's rules (stage 7 Task 6), shared so both systems check them: which Mac groups exist per
/// platform (D12), the team section's rows for each state of `TeamSettings`, the schedule caption, and the Windows
/// wording that replaces Mac-only strings (D13, P14).
@MainActor
final class SettingsModelTests: XCTestCase {
    private func team() -> TeamSettings {
        TeamSettings(defaults: TestDefaults.make(suite: "ptb.test.settingsmodel.\(UUID().uuidString)"))
    }

    private func code() -> TeamCode {
        var rng = SystemRandomNumberGenerator()
        return TeamCode.generate(using: &rng)
    }

    func testTheMacFactsShowEveryGroupAndTheWindowsFactsHideThePlatformOnes() async {
        let mac = SettingsModel.visibility(.mac)
        XCTAssertEqual(mac, SettingsModel.Visibility(menuBarGroup: true, keychainToggle: true, floatingPetGroup: true, animationQuality: true))
        let windows = SettingsModel.visibility(.windows(regionLocale: Locale(identifier: "en_US"), regionCalendar: Calendar(identifier: .gregorian)))
        XCTAssertEqual(windows, SettingsModel.Visibility(menuBarGroup: false, keychainToggle: false, floatingPetGroup: true, animationQuality: true),
                       "the floating pet exists on Windows (stage 7 Task 22)")
    }

    /// Each gate alone: a Keychain without a pet and a pet without a Keychain (an `A || B` of facts must not hide behind one flag).
    func testEachFactGatesOnlyItsOwnRows() async {
        var facts = PopoverPlatformFacts.windows(regionLocale: Locale(identifier: "en_US"), regionCalendar: Calendar(identifier: .gregorian))
        facts.floatingPetAvailable = false   // stage 7 Task 22: Windows has the pet now; each gate alone
        facts.hasKeychain = true
        XCTAssertEqual(SettingsModel.visibility(facts), SettingsModel.Visibility(menuBarGroup: true, keychainToggle: true, floatingPetGroup: false, animationQuality: false))
        facts.hasKeychain = false
        facts.floatingPetAvailable = true
        XCTAssertEqual(SettingsModel.visibility(facts), SettingsModel.Visibility(menuBarGroup: false, keychainToggle: false, floatingPetGroup: true, animationQuality: true))
    }

    func testTheTeamSectionWithTheTeamOffShowsOnlyTheSwitch() async {
        let rows = SettingsModel.team(team(), nicknameDraft: nil, incompatiblePeer: true)
        XCTAssertFalse(rows.isEnabled)
        XCTAssertFalse(rows.showsDetails)
        XCTAssertFalse(rows.hasCode)
    }

    func testTheTeamSectionWithoutACodeOffersCreateAndJoinAndTheSavedTeams() async {
        let team = team()
        team.isEnabled = true
        let first = code(), second = code()
        team.code = first
        team.code = second   // both are saved ("팀 1", "팀 2")
        team.stepOut()
        let rows = SettingsModel.team(team, nicknameDraft: nil, incompatiblePeer: false)
        XCTAssertTrue(rows.showsDetails)
        XCTAssertFalse(rows.hasCode)
        XCTAssertNil(rows.maskedCode)
        XCTAssertEqual(rows.saved.map(\.name), ["팀 1", "팀 2"])
        XCTAssertEqual(rows.saved.map(\.isCurrent), [false, false], "stepped out: no team is current")
        XCTAssertFalse(rows.showsSchedule)
    }

    func testTheTeamSectionInATeamMasksTheCodeAndShowsTheScheduleRows() async {
        let team = team()
        team.isEnabled = true
        let mine = code()
        team.code = mine
        team.nickname = "다람"
        let rows = SettingsModel.team(team, nicknameDraft: nil, incompatiblePeer: false)
        XCTAssertEqual(rows.maskedCode, TeamSetup.masked(mine))
        XCTAssertFalse(rows.maskedCode?.contains(mine.display) ?? true, "the code is masked")
        XCTAssertEqual(rows.teamName, "팀 1")
        XCTAssertEqual(rows.saved.map(\.isCurrent), [true], "the team I am in is the one the switch menu disables")
        XCTAssertTrue(rows.showsSchedule)
        XCTAssertEqual(rows.coreStart, PlazaCoreTime.standard.start)
        XCTAssertEqual(rows.coreEnd, PlazaCoreTime.standard.end)
        XCTAssertEqual(rows.season, .winter)
        XCTAssertEqual(rows.scheduleCaption, L(.ko).teamScheduleDefaultCaption)
        XCTAssertFalse(rows.nicknameInvalid)
        XCTAssertFalse(rows.incompatiblePeer)
        XCTAssertTrue(SettingsModel.team(team, nicknameDraft: nil, incompatiblePeer: true).incompatiblePeer)
    }

    func testTheNicknameErrorFollowsTheDraftThenTheStoredName() async {
        let team = team()
        team.isEnabled = true
        XCTAssertTrue(SettingsModel.team(team, nicknameDraft: nil, incompatiblePeer: false).nicknameInvalid, "no nickname yet")
        team.nickname = "다람"
        XCTAssertFalse(SettingsModel.team(team, nicknameDraft: nil, incompatiblePeer: false).nicknameInvalid)
        XCTAssertTrue(SettingsModel.team(team, nicknameDraft: String(repeating: "가", count: 13), incompatiblePeer: false).nicknameInvalid)
        XCTAssertTrue(SettingsModel.team(team, nicknameDraft: "   ", incompatiblePeer: false).nicknameInvalid)
        XCTAssertFalse(SettingsModel.team(team, nicknameDraft: "마이", incompatiblePeer: false).nicknameInvalid, "the draft wins over the stored name")
    }

    func testTheCoreTimePickersRanges() async {
        XCTAssertEqual(SettingsModel.coreStarts, 1...22)
        XCTAssertEqual(SettingsModel.coreEnds(start: 1), 2...23)
        XCTAssertEqual(SettingsModel.coreEnds(start: 22), 23...23)
    }

    func testTheScheduleCaptionNamesWhoChangedItAndWhen() async {
        let l = L(.ko)
        XCTAssertEqual(SettingsModel.scheduleCaption(nil), l.teamScheduleDefaultCaption)
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        var s = PlazaSchedule(coreStart: 9, coreEnd: 18, seasonPeriod: "winter", changedAt: at, changedBy: "m1", changedByName: "다람")
        XCTAssertEqual(SettingsModel.scheduleCaption(s), l.teamScheduleChangedCaption(name: "다람", when: l.teamScheduleDate(at)))
        s.changedByName = String(repeating: "가", count: 13)   // not a valid name: the default line
        XCTAssertEqual(SettingsModel.scheduleCaption(s), l.teamScheduleDefaultCaption)
    }

    func testTheUsageReportCaptionSaysNotYetBeforeTheFirstSend() async {
        XCTAssertEqual(SettingsModel.usageReportCaption(lastSent: nil),
                       "회사 대시보드로 보내는 중 · 아직 안 보냄")
    }

    func testTheUsageReportCaptionShowsTheLastSendTime() async {
        let l = L(.ko)
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(SettingsModel.usageReportCaption(lastSent: at),
                       "회사 대시보드로 보내는 중 · \(l.teamScheduleDate(at))")
    }

    func testTheReportLineFollowsTheScheduleCaptionOnlyWhileTheTeamIsReady() async {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(SettingsModel.teamCaptionLines(schedule: "S", isReady: false, lastSent: at), ["S"])
        XCTAssertEqual(SettingsModel.teamCaptionLines(schedule: "S", isReady: true, lastSent: at),
                       ["S", SettingsModel.usageReportCaption(lastSent: at)])
        XCTAssertEqual(SettingsModel.teamCaptionLines(schedule: "S", isReady: true, lastSent: nil),
                       ["S", SettingsModel.usageReportCaption(lastSent: nil)])
    }

    // MARK: Windows wording (D13, P14)

    /// P14: with no sign-in file a user refresh ends in "no Keychain item" on Windows; the store words it as the missing
    /// credential, never as "try again shortly", and a missing item is not a declined prompt.
    func testAMissingCredentialIsWordedAsOneInEveryLanguage() async {
        let missing = LimitsError.keychainUnavailable(errSecItemNotFound)
        XCTAssertFalse(UsageStore.isKeychainPromptDeclined(missing))
        for language in AppLanguage.allCases {
            let l = L(language)
            XCTAssertEqual(UsageStore.friendlyLimitError(missing, l), l.limitRefreshNoCredential, "\(language)")
            XCTAssertNotEqual(l.limitRefreshNoCredential, l.limitRefreshGeneric, "\(language)")
        }
    }

    func testTheWindowsStringsNameNoMacThingsInAnyLanguage() async {
        let forbidden = ["Keychain", "키체인", "macOS", "Finder", "~/Library", "Mac ", "メニューバー", "menu bar", "barre des menus", "barra de menús",
                         "Menüleiste", "строке меню", "Связк"]
        for language in AppLanguage.allCases {
            let l = L(language)
            let texts = [l.winBackViewHint, l.winExplorerButton, l.winClaudeCredentialHelpTitle, l.winClaudeCredentialHelpBody,
                         l.winClaudeCredentialHelpTooltip, l.winReportMailBody(version: "2.5.0", os: "Version 10.0")]
            for text in texts {
                XCTAssertFalse(text.isEmpty, "\(language)")
                for word in forbidden { XCTAssertFalse(text.contains(word), "\(language): \(word) in \(text)") }
            }
            let body = l.winReportMailBody(version: "2.5.0", os: "Version 10.0")
            XCTAssertTrue(body.contains("Windows: Version 10.0"), "\(language)")
            XCTAssertTrue(body.contains(#"%LOCALAPPDATA%\PokeTokenBar\Logs\PokeTokenBar.log"#), "\(language)")
            XCTAssertTrue(body.contains("v2.5.0"), "\(language)")
        }
    }

    /// Every Windows string differs by language where the Mac's does (a copied English line in another language is a
    /// missing translation).
    func testTheWindowsStringsAreTranslated() async {
        func all(_ f: (L) -> String) -> Set<String> { Set(AppLanguage.allCases.map { f(L($0)) }) }
        XCTAssertEqual(all(\.winBackViewHint).count, 8)
        XCTAssertEqual(all(\.winClaudeCredentialHelpTitle).count, 8)
        XCTAssertEqual(all(\.winClaudeCredentialHelpBody).count, 8)
        XCTAssertEqual(all(\.winClaudeCredentialHelpTooltip).count, 8)
        XCTAssertEqual(all { $0.winReportMailBody(version: "1", os: "x") }.count, 8)
    }

    /// The report mail's Windows body is the Mac's with only the OS label and the log path changed.
    func testTheReportMailBodyDiffersFromTheMacsOnlyInTheOSLineAndTheLogPath() async {
        for language in AppLanguage.allCases {
            let l = L(language)
            let mac = l.reportMailBody(version: "2.5.0", os: "Version 10.0").split(separator: "\n", omittingEmptySubsequences: false)
            let win = l.winReportMailBody(version: "2.5.0", os: "Version 10.0").split(separator: "\n", omittingEmptySubsequences: false)
            XCTAssertEqual(mac.count, win.count, "\(language)")
            let differing = zip(mac, win).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
            XCTAssertEqual(differing, [mac.count - 2, mac.count - 1], "\(language): only the macOS line and the log line change")
        }
    }
}
