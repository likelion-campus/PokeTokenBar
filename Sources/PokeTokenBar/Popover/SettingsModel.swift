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
