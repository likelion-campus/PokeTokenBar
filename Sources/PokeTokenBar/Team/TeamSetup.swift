import Foundation

/// The team section's rules (stage 7, Task 1), moved verbatim out of the Mac's `TeamSettingsSection` so the Windows
/// settings page applies the same ones. The Mac view calls them; `TeamSettingsTests` (the view) and `TeamSetupTests`
/// (these, on both systems) pin the behaviour.
enum TeamSetup {
    enum JoinResult: Equatable { case invalid, openPlaza, needsNickname }

    /// Stores a valid draft and returns nil (nothing left to edit). An invalid draft keeps the stored name and
    /// stays as it is, so the message stays up until the field is fixed.
    @MainActor static func committedDraft(_ draft: String?, into team: TeamSettings) -> String? {
        guard let draft else { return nil }
        return team.commitNickname(draft) ? nil : draft
    }

    /// 코드가 맞으면 그 팀에 들어간다. 팀이 바로 준비되면 광장을 열고, 닉네임이 없으면 닉네임을 정할 때까지 미룬다.
    @MainActor static func join(_ draft: String, into team: TeamSettings) -> JoinResult {
        guard let parsed = TeamCode(parsing: draft) else { return .invalid }
        team.code = parsed
        return team.isReady ? .openPlaza : .needsNickname
    }

    /// "PTB-ABCDE-…" 중 앞 한 묶음만 보이게 나머지를 가린다.
    static func masked(_ code: TeamCode) -> String {
        let parts = code.display.split(separator: "-").map(String.init)
        return parts.enumerated().map { $0.offset <= 1 ? $0.element : String(repeating: "•", count: $0.element.count) }
            .joined(separator: "-")
    }
}
