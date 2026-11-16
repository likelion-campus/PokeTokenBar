import Foundation

/// What the Windows Settings page decides before it draws anything (stage 7 Task 6): which Mac groups exist on this
/// platform (D12), which rows the team section shows for which state, and the schedule caption. Pure values and rules, so
/// both systems test them; the page (`WinSettingsPage`) only turns them into controls. The Mac's `SettingsView` and
/// `TeamSettingsSection` are upstream/fork-owned SwiftUI and keep their own bodies; the rules here are read from them.
enum SettingsModel {
    /// Which of the Mac's Settings parts this platform shows (D12). The Mac facts show every one of them.
    struct Visibility: Equatable {
        /// "Menu bar" group: the tray icon shows no text (P17), so Windows has no such group.
        var menuBarGroup: Bool
        /// "Disable Keychain access" (Advanced): there is no Keychain on Windows.
        var keychainToggle: Bool
        /// The floating pet group and "Animation quality" (the pet's and the menu bar sprite's): until the pet exists on
        /// Windows a switch for it would do nothing (P16).
        var floatingPetGroup: Bool
        var animationQuality: Bool
    }

    static func visibility(_ facts: PopoverPlatformFacts) -> Visibility {
        Visibility(menuBarGroup: facts.hasKeychain, keychainToggle: facts.hasKeychain,
                   floatingPetGroup: facts.floatingPetAvailable, animationQuality: facts.floatingPetAvailable)
    }

    /// Core time's pickers (`TeamSettingsSection.scheduleRows`): start 1...22, end start+1...23.
    static let coreStarts = 1...22
    static func coreEnds(start: Int) -> ClosedRange<Int> { (start + 1)...23 }

    /// The team section for one state of `TeamSettings` (the Mac's `TeamSettingsSection.body`, row by row). Holds the
    /// masked code only: the code itself never enters a model that a log line or a test failure could print.
    struct TeamRows: Equatable {
        struct Saved: Equatable {
            var name: String
            /// The team the code belongs to (the switch menu disables it).
            var isCurrent: Bool
            /// What `TeamSettings.switchTo` is called with, found again in `savedTeams` (a team code: never shown).
            var key: String
        }
        var isEnabled: Bool
        /// The masked code, nil without one: "create" and "join" show instead of "copy" and "leave".
        var maskedCode: String?
        var teamName: String
        var saved: [Saved]
        /// The nickname in the field (the draft, else the stored one) is not valid: the red line under it.
        var nicknameInvalid: Bool
        var notificationsEnabled: Bool
        /// Core time and season rows, only inside a team.
        var showsSchedule: Bool
        var coreStart: Int
        var coreEnd: Int
        var season: PlazaSeasonChoice
        var scheduleCaption: String
        /// A teammate runs a version this one cannot talk to (`TeamSession.hasIncompatiblePeer`).
        var incompatiblePeer: Bool

        /// Everything below the switch shows only while the team is on.
        var showsDetails: Bool { isEnabled }
        var hasCode: Bool { maskedCode != nil }
    }

    @MainActor
    static func team(_ team: TeamSettings, nicknameDraft: String?, incompatiblePeer: Bool, l: L = L(.ko)) -> TeamRows {
        let current = team.code?.normalized
        let core = team.schedule?.coreTime ?? .standard
        return TeamRows(
            isEnabled: team.isEnabled,
            maskedCode: team.code.map(TeamSetup.masked),
            teamName: team.currentTeam?.name ?? "",
            saved: team.savedTeams.map { TeamRows.Saved(name: $0.name, isCurrent: $0.code == current, key: $0.code) },
            nicknameInvalid: TeamSettings.validNickname(nicknameDraft ?? team.nickname) == nil,
            notificationsEnabled: team.notificationsEnabled,
            showsSchedule: team.code != nil,
            coreStart: core.start,
            coreEnd: core.end,
            season: team.schedule?.season ?? .winter,
            scheduleCaption: scheduleCaption(team.schedule, l: l),
            incompatiblePeer: incompatiblePeer)
    }

    /// "Applies to every teammate · changed by X on date", or the default line (`TeamSettingsSection.scheduleCaption`).
    @MainActor static func scheduleCaption(_ schedule: PlazaSchedule?, l: L = L(.ko)) -> String {
        guard let s = schedule, let name = TeamSettings.validNickname(s.changedByName) else {
            return l.teamScheduleDefaultCaption
        }
        return l.teamScheduleChangedCaption(name: name, when: l.teamScheduleDate(s.changedAt))
    }
}

// --- stage 7 Task 14: the Advanced group and the tracked account (begin) ---
extension SettingsModel {
    /// What the Advanced group reads from the store (`SettingsView.advancedGroup`, `sessionKeyRows`, `accountSessionKeyRows`,
    /// `additionalAccountsRow`). Holds no key: the store exposes none (`sessionKeyConfigured` is whether one is saved).
    struct AdvancedInput: Equatable {
        var language: AppLanguage = .en
        var sessionKeyConfigured = false
        var sessionKeyExpired = false
        var sessionKeyError: String?
        var isValidatingSessionKey = false
        var organizations: [Organization] = []
        var selectedOrganizationID: String?
        /// `additionalClaudeConfigRoots`: one key row each.
        var additionalRoots: [String] = []
        /// Per root path: the account's tab title and whether its key expired, once its limits loaded (`claudeAccounts`).
        var accountTitles: [String: String] = [:]
        var accountKeyExpired: Set<String> = []
        var accountKeyPaths: Set<String> = []
        var accountErrors: [String: String] = [:]
        var validatingAccountPath: String?
        var isRefreshingLimitToken = false
        var limitTokenRefreshMessage: String?
        var disableKeychainAccess = false
        var detectedConfigDirs: [String] = []
    }

    struct Organization: Equatable {
        var id: String
        var name: String
    }

    /// The label's badge: orange "expired" (the server refused the saved key), else green "saved".
    enum KeyBadge: Equatable { case expired, saved }

    /// One key: its label row, the masked field, Save (a spinner while it is checked), Delete, the error or the storage note.
    struct KeyRows: Equatable {
        var label: String
        var badge: KeyBadge?
        /// The hint under the label (the default key) or the folder (an account's key, when its title is not the folder).
        var detail: String?
        /// The field's grey text: dots when a key is saved (its value is never shown again), else the key's start.
        var placeholder: String
        /// The key is being checked: Save shows its spinner and is off.
        var isValidating: Bool
        /// Another key is being checked: Save is off (the Mac checks one account at a time).
        var saveBlocked: Bool
        var showsDelete: Bool
        /// Shown when there are several (the automatic choice can pick the wrong one): names, and the chosen one's index.
        var organizations: [Organization]
        var selectedOrganization: Int?
        var error: String?
        var storageNote: String?

        var showsOrganizations: Bool { organizations.count > 1 }
    }

    /// An additional Claude folder's own key.
    struct AccountKey: Equatable {
        var path: String
        var rows: KeyRows
    }

    struct AdvancedRows: Equatable {
        var sessionKey: KeyRows
        /// One per additional Claude folder.
        var accounts: [AccountKey]
        /// The storage note once, under the accounts, when the default key does not show it.
        var accountsStorageNote: String?
        /// "Disable Keychain access": only where there is a Keychain.
        var keychainToggle: Bool
        var refreshLabel: String
        var refreshHint: String
        var refreshInProgress: Bool
        var refreshEnabled: Bool
        var refreshMessage: String?
        var additionalHint: String
        var detected: String?
    }

    /// The Mac's field placeholders (`SecureField(store.sessionKeyConfigured ? "••••••••" : "sk-ant-sid…", …)`).
    static let savedKeyPlaceholder = "••••••••"
    static let newKeyPlaceholder = "sk-ant-sid…"

    /// The Advanced group's rows, the Mac's predicates read from `SettingsView`; the facts choose the Mac's or the Windows
    /// wording (D13) and the Keychain switch.
    static func advanced(_ s: AdvancedInput, facts: PopoverPlatformFacts) -> AdvancedRows {
        let l = L(s.language)
        let mac = facts.hasKeychain
        let note = mac ? l.sessionKeyStorageNote : l.winSessionKeyStorageNote
        let hint = mac ? l.sessionKeyHint : l.winSessionKeyHint
        let orgIndex = s.organizations.firstIndex { $0.id == s.selectedOrganizationID }
        let key = KeyRows(
            label: l.sessionKeyLabel,
            badge: s.sessionKeyExpired ? .expired : (s.sessionKeyConfigured ? .saved : nil),
            detail: s.additionalRoots.isEmpty ? hint : hint + " " + l.sessionKeyPerAccountNote,
            placeholder: s.sessionKeyConfigured ? savedKeyPlaceholder : newKeyPlaceholder,
            isValidating: s.isValidatingSessionKey, saveBlocked: false, showsDelete: s.sessionKeyConfigured,
            organizations: s.organizations, selectedOrganization: orgIndex,
            error: s.sessionKeyError, storageNote: s.sessionKeyError == nil && s.sessionKeyConfigured ? note : nil)
        let accounts = s.additionalRoots.map { path -> AccountKey in
            let folder = PlatformCompat.abbreviatingWithTilde(path)
            let title = s.accountTitles[path] ?? folder
            let configured = s.accountKeyPaths.contains(path)
            return AccountKey(path: path, rows: KeyRows(
                label: l.accountSessionKeyLabel(title),
                badge: s.accountKeyExpired.contains(path) ? .expired : (configured ? .saved : nil),
                detail: title != folder ? folder : nil,
                placeholder: configured ? savedKeyPlaceholder : newKeyPlaceholder,
                isValidating: s.validatingAccountPath == path, saveBlocked: s.validatingAccountPath != nil, showsDelete: configured,
                organizations: [], selectedOrganization: nil, error: s.accountErrors[path], storageNote: nil))
        }
        let showsAccountsNote = !s.accountKeyPaths.isEmpty && (!s.sessionKeyConfigured || s.sessionKeyError != nil)
        return AdvancedRows(
            sessionKey: key, accounts: accounts, accountsStorageNote: showsAccountsNote ? note : nil,
            keychainToggle: visibility(facts).keychainToggle,
            refreshLabel: mac ? l.refreshLimitToken : l.winRefreshLimitToken,
            refreshHint: mac ? l.onlyOnPress : l.winOnlyOnPress,
            refreshInProgress: s.isRefreshingLimitToken,
            refreshEnabled: !(mac && s.disableKeychainAccess) && !s.isRefreshingLimitToken,
            refreshMessage: s.limitTokenRefreshMessage,
            additionalHint: mac ? l.additionalClaudeAccountsHint : l.winAdditionalClaudeAccountsHint,
            detected: s.detectedConfigDirs.isEmpty ? nil
                : l.additionalClaudeAccountsDetected(s.detectedConfigDirs.map(PlatformCompat.abbreviatingWithTilde).joined(separator: ", ")))
    }

    /// `language`: the page's (the companion's, as the Mac's `companion.l`); the store's by default.
    @MainActor static func advancedInput(_ store: UsageStore, language: AppLanguage? = nil) -> AdvancedInput {
        let accounts = store.claudeAccounts
        var titles: [String: String] = [:], expired: Set<String> = []
        for path in store.additionalClaudeConfigRoots {
            let id = ClaudeAccountRoots.pathKey(for: URL(fileURLWithPath: path))
            guard let account = accounts.first(where: { $0.id == id }) else { continue }
            titles[path] = account.title
            if account.sessionKeyExpired { expired.insert(path) }
        }
        var errors: [String: String] = [:]
        for path in store.additionalClaudeConfigRoots { errors[path] = store.accountSessionKeyError(for: path) }
        return AdvancedInput(
            language: language ?? store.localizationLanguage, sessionKeyConfigured: store.sessionKeyConfigured, sessionKeyExpired: store.sessionKeyExpired,
            sessionKeyError: store.sessionKeyError, isValidatingSessionKey: store.isValidatingSessionKey,
            organizations: store.sessionKeyOrganizations.map { Organization(id: $0.id, name: $0.name) },
            selectedOrganizationID: store.sessionKeySelectedOrgID, additionalRoots: store.additionalClaudeConfigRoots,
            accountTitles: titles, accountKeyExpired: expired, accountKeyPaths: store.accountSessionKeyPaths, accountErrors: errors,
            validatingAccountPath: store.validatingAccountSessionKeyPath, isRefreshingLimitToken: store.isRefreshingLimitToken,
            limitTokenRefreshMessage: store.limitTokenRefreshMessage, disableKeychainAccess: store.disableKeychainAccess,
            detectedConfigDirs: store.detectedClaudeConfigDirs)
    }

    /// "Found N" under the additional-folders field, while it holds text (`additionalAccountsRow`).
    static func additionalFound(draft: String, count: Int, l: L) -> String? {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : l.additionalClaudeAccountsFound(count)
    }

    /// "Scans N extra folder(s) now" under the scan-folders field, while it holds text (`advancedGroup`).
    static func scanMatches(draft: String, count: Int, l: L) -> String? {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : l.customScanRootsMatches(count)
    }

    /// The Mac's 250 ms before it counts the scan folders (`scheduleCustomScanMatchCount`).
    static let scanCountDelay: TimeInterval = 0.25

    /// The tracked-account picker (`SettingsView.trackedAccountRow`), shown with two accounts or more: automatic, highest, then
    /// every account (the default one as `.defaultAccount`).
    struct TrackedAccount: Equatable {
        var titles: [String]
        var modes: [ClaudeTrackedAccountMode]
        var selected: Int
        var hint: String
    }

    static func trackedAccount(accounts: [(id: String, title: String, isDefault: Bool)], mode: ClaudeTrackedAccountMode,
                               facts: PopoverPlatformFacts, l: L) -> TrackedAccount? {
        guard accounts.count > 1 else { return nil }
        let modes: [ClaudeTrackedAccountMode] = [.automatic, .highest]
            + accounts.map { $0.isDefault ? .defaultAccount : .account($0.id) }
        // A pinned account that is gone falls back to automatic (`UsageStore.trackedAccount`): the picker shows that.
        let shown = modes.dropFirst(2).contains(mode) || mode == .highest ? mode : .automatic
        return TrackedAccount(titles: [l.trackedAccountAutomatic, l.trackedAccountHighest] + accounts.map(\.title), modes: modes,
                              selected: modes.firstIndex(of: shown) ?? 0,
                              hint: facts.hasKeychain ? l.trackedAccountHint : l.winTrackedAccountHint)
    }

    @MainActor static func trackedAccount(_ store: UsageStore, facts: PopoverPlatformFacts, language: AppLanguage? = nil) -> TrackedAccount? {
        trackedAccount(accounts: store.claudeAccounts.map { ($0.id, $0.title, $0.isDefault) }, mode: store.claudeTrackedAccountMode,
                       facts: facts, l: L(language ?? store.localizationLanguage))
    }
}
// --- stage 7 Task 14 (end) ---
