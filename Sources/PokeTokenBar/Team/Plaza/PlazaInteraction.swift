import Foundation
import Observation

enum PlazaInteractionTarget: Equatable { case board, member(String) }

/// 스페이스로 말을 걸 대상을 찾는 규칙. SpriteKit과 무관한 순수 함수다.
enum PlazaInteraction {
    /// 바라보는 칸이 소식판이면 판이 먼저, 아니면 `PlazaTargeting`이 고른 팀원.
    static func target(from: TilePoint, facing: PlazaDirection, map: PlazaMap,
                       members: [String: TilePoint]) -> PlazaInteractionTarget? {
        if map.tile(at: PlazaTargeting.facingTile(from: from, facing: facing)) == .board { return .board }
        return PlazaTargeting.member(from: from, facing: facing, members: members).map { .member($0) }
    }
}

enum PlazaCardState: Equatable {
    case loading(TeamMemberState)
    case loaded(TeamMemberState, TeamMemberProfile)
    case failed(TeamMemberState)

    /// 지금 데리고 다니는 포켓몬이 광장 캐릭터와 다를 때만 값이 있다.
    var differingCurrent: TeamMonSummary? {
        guard case .loaded(let state, let profile) = self else { return nil }
        let c = profile.current, a = state.character
        return (c.speciesID == a.speciesID && c.isShiny == a.isShiny && c.form == a.form) ? nil : c
    }
}

enum PlazaOverlayContent: Equatable { case none, card(PlazaCardState), board }

/// 광장 위에 뜨는 판의 내용. 그리는 쪽(`PlazaOverlayView`)은 이 값만 본다.
@MainActor @Observable
final class PlazaOverlayModel {
    var content: PlazaOverlayContent = .none
    var banner: String?
}
