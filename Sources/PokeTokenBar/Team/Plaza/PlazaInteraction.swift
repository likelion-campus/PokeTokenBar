import Foundation
import Observation

enum PlazaInteractionTarget: Equatable { case board, member(String) }

/// 스페이스로 말을 걸 대상과, 말을 걸 때 돌아설 방향.
struct PlazaInteractionHit: Equatable {
    let target: PlazaInteractionTarget
    let facing: PlazaDirection
}

/// 스페이스로 말을 걸 대상을 찾는 규칙. SpriteKit과 무관한 순수 함수다.
enum PlazaInteraction {
    /// 바로 옆이면 바라보지 않아도 말을 건다. 순서: 바라보는 소식판, 바라보는 칸의 팀원, 같은 칸의 팀원,
    /// 옆 칸의 소식판, 옆 칸의 팀원. 쉼터가 소식판을 둘러싸 자리 비움 팀원이 늘 옆을 지나므로 옆이면 판이 먼저다.
    static func target(from: TilePoint, facing: PlazaDirection, map: PlazaMap,
                       members: [String: TilePoint]) -> PlazaInteractionHit? {
        let ahead = PlazaTargeting.facingTile(from: from, facing: facing)
        if map.tile(at: ahead) == .board { return .init(target: .board, facing: facing) }
        for tile in [ahead, from] {
            if let id = PlazaTargeting.member(on: tile, members: members) { return .init(target: .member(id), facing: facing) }
        }
        let sides = PlazaTargeting.otherSides(facing)
        if let d = sides.first(where: { map.tile(at: PlazaWalker.offset(from, $0)) == .board }) {
            return .init(target: .board, facing: d)
        }
        for d in sides {
            if let id = PlazaTargeting.member(on: PlazaWalker.offset(from, d), members: members) {
                return .init(target: .member(id), facing: d)
            }
        }
        return nil
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
    /// 스페이스로 말을 걸 수 있을 때 위쪽에 띄우는 안내.
    var hint: String?
}
