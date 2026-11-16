import XCTest
@testable import PokeTokenBar

/// The Advanced group's and the tracked account's rules (stage 7 Task 14), shared so both systems check them: the Mac's
/// predicates read from `SettingsView.sessionKeyRows`, `accountSessionKeyRows`, `advancedGroup`, `additionalAccountsRow` and
/// `trackedAccountRow`, with the Mac's or the Windows wording per platform (D13).
final class SettingsModelAdvancedTests: XCTestCase {
    private let windows = PopoverPlatformFacts.windows(regionLocale: Locale(identifier: "en_US"), regionCalendar: Calendar(identifier: .gregorian))
    private let l = L(.en)

    private func input(_ edit: (inout SettingsModel.AdvancedInput) -> Void = { _ in }) -> SettingsModel.AdvancedInput {
        var s = SettingsModel.AdvancedInput()
        edit(&s)
        return s
    }

    func testWithoutAKeyTheMacAndWindowsShowTheirOwnWords() {
        let mac = SettingsModel.advanced(input(), facts: .mac)
        XCTAssertEqual(mac.sessionKey, SettingsModel.KeyRows(
            label: l.sessionKeyLabel, badge: nil, detail: l.sessionKeyHint, placeholder: "sk-ant-sid…", isValidating: false, saveBlocked: false,
            showsDelete: false, organizations: [], selectedOrganization: nil, error: nil, storageNote: nil))
        XCTAssertTrue(mac.keychainToggle)
        XCTAssertEqual([mac.refreshLabel, mac.refreshHint, mac.additionalHint], [l.refreshLimitToken, l.onlyOnPress, l.additionalClaudeAccountsHint])
        XCTAssertTrue(mac.refreshEnabled)
        XCTAssertNil(mac.detected)
        XCTAssertNil(mac.accountsStorageNote)
        let win = SettingsModel.advanced(input(), facts: windows)
        XCTAssertEqual(win.sessionKey.detail, l.winSessionKeyHint)
        XCTAssertFalse(win.keychainToggle, "no Keychain switch on Windows")
        XCTAssertEqual([win.refreshLabel, win.refreshHint, win.additionalHint], [l.winRefreshLimitToken, l.winOnlyOnPress, l.winAdditionalClaudeAccountsHint])
    }

    func testASavedKeyShowsItsBadgeDotsDeleteAndTheStorageNote() {
        let saved = input { $0.sessionKeyConfigured = true }
        let mac = SettingsModel.advanced(saved, facts: .mac).sessionKey
        XCTAssertEqual(mac.badge, .saved)
        XCTAssertEqual(mac.placeholder, "••••••••", "the key is never shown again")
        XCTAssertTrue(mac.showsDelete)
        XCTAssertEqual(mac.storageNote, l.sessionKeyStorageNote)
        XCTAssertEqual(SettingsModel.advanced(saved, facts: windows).sessionKey.storageNote, l.winSessionKeyStorageNote)
        // An error takes the note's place (`if let sessionKeyError … else if store.sessionKeyConfigured`).
        let failed = SettingsModel.advanced(input { $0.sessionKeyConfigured = true; $0.sessionKeyError = "boom" }, facts: windows).sessionKey
        XCTAssertEqual(failed.error, "boom")
        XCTAssertNil(failed.storageNote)
        // Refused by the server: expired, not "saved".
        XCTAssertEqual(SettingsModel.advanced(input { $0.sessionKeyConfigured = true; $0.sessionKeyExpired = true }, facts: windows).sessionKey.badge, .expired)
        // An error without a saved key (a bad paste): the error, no note, no badge.
        let bad = SettingsModel.advanced(input { $0.sessionKeyError = "bad" }, facts: windows).sessionKey
        XCTAssertEqual([bad.error, bad.storageNote], ["bad", nil])
        XCTAssertNil(bad.badge)
    }

    func testTheOrganisationPickerShowsOnlyWithSeveral() {
        let one = SettingsModel.advanced(input { $0.organizations = [.init(id: "a", name: "A")]; $0.selectedOrganizationID = "a" }, facts: windows).sessionKey
        XCTAssertFalse(one.showsOrganizations)
        let two = SettingsModel.advanced(input {
            $0.organizations = [.init(id: "a", name: "A"), .init(id: "b", name: "B")]
            $0.selectedOrganizationID = "b"
        }, facts: windows).sessionKey
        XCTAssertTrue(two.showsOrganizations)
        XCTAssertEqual(two.selectedOrganization, 1)
        XCTAssertNil(SettingsModel.advanced(input { $0.organizations = [.init(id: "a", name: "A"), .init(id: "b", name: "B")] }, facts: windows)
            .sessionKey.selectedOrganization, "none chosen yet")
    }

    func testTheValidatingKeyShowsItsSpinner() {
        let k = SettingsModel.advanced(input { $0.isValidatingSessionKey = true }, facts: windows).sessionKey
        XCTAssertTrue(k.isValidating)
        XCTAssertFalse(k.saveBlocked)
    }

    func testEachAdditionalFolderHasItsOwnKeyRows() {
        let work = "/Users/example/.claude-work", side = "/Users/example/.claude-side"
        let rows = SettingsModel.advanced(input {
            $0.additionalRoots = [work, side]
            $0.accountTitles = [work: "work@example.com"]
            $0.accountKeyPaths = [work]
            $0.accountKeyExpired = []
            $0.accountErrors = [side: "nope"]
            $0.validatingAccountPath = side
        }, facts: windows)
        XCTAssertEqual(rows.sessionKey.detail, l.winSessionKeyHint + " " + l.sessionKeyPerAccountNote, "the default key says it is the default account's")
        XCTAssertEqual(rows.accounts.map(\.path), [work, side])
        let w = rows.accounts[0].rows, s = rows.accounts[1].rows
        XCTAssertEqual(w.label, l.accountSessionKeyLabel("work@example.com"))
        XCTAssertEqual(w.detail, PlatformCompat.abbreviatingWithTilde(work), "the folder tells two logins of one email apart")
        XCTAssertEqual(w.badge, .saved)
        XCTAssertTrue(w.showsDelete)
        XCTAssertTrue(w.saveBlocked, "another folder's key is being checked")
        XCTAssertFalse(w.isValidating)
        XCTAssertEqual(s.label, l.accountSessionKeyLabel(PlatformCompat.abbreviatingWithTilde(side)), "before its limits load: the folder")
        XCTAssertNil(s.detail, "the title is the folder: not twice")
        XCTAssertTrue(s.isValidating)
        XCTAssertEqual(s.error, "nope")
        XCTAssertFalse(s.showsOrganizations, "no picker per account")
        XCTAssertNil(s.storageNote)
        let expired = SettingsModel.advanced(input { $0.additionalRoots = [work]; $0.accountKeyPaths = [work]; $0.accountKeyExpired = [work] }, facts: windows)
        XCTAssertEqual(expired.accounts[0].rows.badge, .expired)
    }

    /// `!accountSessionKeyPaths.isEmpty, !sessionKeyConfigured || sessionKeyError != nil`: each side of the `||` alone.
    func testTheAccountsStorageNoteShowsOnceWhenTheDefaultKeyDoesNotShowIt() {
        let work = "/w"
        func note(_ edit: (inout SettingsModel.AdvancedInput) -> Void) -> String? {
            SettingsModel.advanced(input { $0.additionalRoots = [work]; edit(&$0) }, facts: windows).accountsStorageNote
        }
        XCTAssertNil(note { _ in }, "no account key")
        XCTAssertEqual(note { $0.accountKeyPaths = [work] }, l.winSessionKeyStorageNote, "an account key, no default key")
        XCTAssertNil(note { $0.accountKeyPaths = [work]; $0.sessionKeyConfigured = true }, "the default key shows it already")
        XCTAssertEqual(note { $0.accountKeyPaths = [work]; $0.sessionKeyConfigured = true; $0.sessionKeyError = "x" }, l.winSessionKeyStorageNote,
                       "the default key shows its error instead")
    }

    /// `.disabled(store.disableKeychainAccess || store.isRefreshingLimitToken)`: each side alone, and Windows has no switch.
    func testTheReloadButtonIsOffWhileItRunsAndWithTheKeychainOffOnlyOnTheMac() {
        XCTAssertFalse(SettingsModel.advanced(input { $0.disableKeychainAccess = true }, facts: .mac).refreshEnabled)
        XCTAssertTrue(SettingsModel.advanced(input { $0.disableKeychainAccess = true }, facts: windows).refreshEnabled,
                      "a stored Keychain switch means nothing on Windows")
        let running = SettingsModel.advanced(input { $0.isRefreshingLimitToken = true }, facts: windows)
        XCTAssertFalse(running.refreshEnabled)
        XCTAssertTrue(running.refreshInProgress)
        XCTAssertEqual(SettingsModel.advanced(input { $0.limitTokenRefreshMessage = "m" }, facts: windows).refreshMessage, "m")
    }

    func testTheDetectedFoldersAndTheCounts() {
        let rows = SettingsModel.advanced(input { $0.detectedConfigDirs = ["/a/.claude-x", "/b/.claude-y"] }, facts: windows)
        XCTAssertEqual(rows.detected, l.additionalClaudeAccountsDetected(["/a/.claude-x", "/b/.claude-y"].map(PlatformCompat.abbreviatingWithTilde).joined(separator: ", ")))
        XCTAssertNil(SettingsModel.additionalFound(draft: " \n ", count: 3, l: l), "shown only while the field holds text")
        XCTAssertEqual(SettingsModel.additionalFound(draft: "~/x", count: 1, l: l), l.additionalClaudeAccountsFound(1))
        XCTAssertNil(SettingsModel.scanMatches(draft: "", count: 0, l: l))
        XCTAssertEqual(SettingsModel.scanMatches(draft: "~/logs", count: 0, l: l), l.customScanRootsMatches(0), "zero is shown, as on the Mac")
        XCTAssertEqual(SettingsModel.scanCountDelay, 0.25, "the Mac's 250 ms")
    }

    func testTheTrackedAccountPickerFollowsTheMacsRow() {
        let one = [(id: "default", title: "me@example.com", isDefault: true)]
        XCTAssertNil(SettingsModel.trackedAccount(accounts: one, mode: .automatic, facts: windows, l: l), "one account: no row")
        let two = one + [(id: "abc123", title: "work@example.com", isDefault: false)]
        let picker = SettingsModel.trackedAccount(accounts: two, mode: .account("abc123"), facts: windows, l: l)
        XCTAssertEqual(picker?.titles, [l.trackedAccountAutomatic, l.trackedAccountHighest, "me@example.com", "work@example.com"])
        XCTAssertEqual(picker?.modes, [.automatic, .highest, .defaultAccount, .account("abc123")])
        XCTAssertEqual(picker?.selected, 3)
        XCTAssertEqual(picker?.hint, l.winTrackedAccountHint)
        XCTAssertEqual(SettingsModel.trackedAccount(accounts: two, mode: .account("gone"), facts: windows, l: l)?.selected, 0,
                       "a pinned account that is gone shows automatic")
        XCTAssertEqual(SettingsModel.trackedAccount(accounts: two, mode: .highest, facts: windows, l: l)?.selected, 1)
        XCTAssertEqual(SettingsModel.trackedAccount(accounts: two, mode: .defaultAccount, facts: .mac, l: l)?.selected, 2)
        XCTAssertEqual(SettingsModel.trackedAccount(accounts: two, mode: .automatic, facts: .mac, l: l)?.hint, l.trackedAccountHint)
    }

    // MARK: the Windows strings (D13)

    private var winStrings: [(String, (L) -> String)] {
        [("winSessionKeyHint", { $0.winSessionKeyHint }), ("winSessionKeyStorageNote", { $0.winSessionKeyStorageNote }),
         ("winRefreshLimitToken", { $0.winRefreshLimitToken }), ("winOnlyOnPress", { $0.winOnlyOnPress }),
         ("winAdditionalClaudeAccountsHint", { $0.winAdditionalClaudeAccountsHint }), ("winTrackedAccountHint", { $0.winTrackedAccountHint })]
    }

    func testTheNewWindowsStringsNameNoMacThingsInAnyLanguage() {
        let forbidden = ["Keychain", "키체인", "macOS", "Finder", "~/Library", "Mac ", "Mac의", "Mac の", "メニューバー", "menu bar", "barre des menus",
                         "barra de menús", "barra de menus", "Menüleiste", "строке меню", "Связк", "메뉴바", "not encrypted", "암호화 아님", "暗号化なし"]
        for language in AppLanguage.allCases {
            let l = L(language)
            for (name, text) in winStrings {
                let value = text(l)
                XCTAssertFalse(value.isEmpty, "\(name) \(language)")
                for word in forbidden { XCTAssertFalse(value.contains(word), "\(name) \(language): \(word) in \(value)") }
            }
            XCTAssertTrue(l.winSessionKeyHint.contains("claude.ai → sessionKey"), "the steps to the cookie stay: \(language)")
            XCTAssertTrue(l.winOnlyOnPress.contains("~/.claude/.credentials.json"), "\(language)")
        }
    }

    func testTheNewWindowsStringsAreTranslated() {
        for (name, text) in winStrings {
            XCTAssertEqual(Set(AppLanguage.allCases.map { text(L($0)) }).count, AppLanguage.allCases.count, "\(name): a language repeats another's text")
        }
    }
}
