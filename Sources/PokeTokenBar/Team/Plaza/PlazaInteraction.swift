import Foundation
import Observation

enum PlazaInteractionTarget: Equatable { case board, campfire, member(String) }

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
        if map.tile(at: ahead) == .campfire { return .init(target: .campfire, facing: facing) }
        for tile in [ahead, from] {
            if let id = PlazaTargeting.member(on: tile, members: members) { return .init(target: .member(id), facing: facing) }
        }
        let sides = PlazaTargeting.otherSides(facing)
        if let d = sides.first(where: { map.tile(at: PlazaWalker.offset(from, $0)) == .board }) {
            return .init(target: .board, facing: d)
        }
        if let d = sides.first(where: { map.tile(at: PlazaWalker.offset(from, $0)) == .campfire }) {
            return .init(target: .campfire, facing: d)
        }
        for d in sides {
            if let id = PlazaTargeting.member(on: PlazaWalker.offset(from, d), members: members) {
                return .init(target: .member(id), facing: d)
            }
        }
        return nil
    }
}

/// 카드의 광장 캐릭터 옆에 붙는 표시.
enum PlazaCardBadge: Equatable { case shiny, rarity(Rarity) }

enum PlazaCardState: Equatable {
    case loading(TeamMemberState)
    case loaded(TeamMemberState, TeamMemberProfile)
    case failed(TeamMemberState)

    /// 카드 주인. 도감을 받는 중에도 안다.
    var member: TeamMemberState {
        switch self {
        case .loading(let m), .loaded(let m, _), .failed(let m): m
        }
    }

    /// 광장 캐릭터의 이름. 알이면 "알", 이름을 모르면 nil.
    var characterName: String? {
        let c = member.character
        return c.speciesName ?? (c.speciesID == nil ? L(.ko).plazaEggName : nil)
    }

    /// 이로치, 그리고 일반이 아닌 희귀도. 희귀도는 도감을 받은 뒤에야 안다(광장 캐릭터 값에는 없다).
    var characterBadges: [PlazaCardBadge] {
        let c = member.character
        var badges: [PlazaCardBadge] = c.isShiny ? [.shiny] : []
        if case .loaded(_, let profile) = self, let id = c.speciesID,
           let rarity = profile.dex.first(where: { $0.speciesID == id })?.rarity, rarity != .common {
            badges.append(.rarity(rarity))
        }
        return badges
    }

    /// 지금 데리고 다니는 포켓몬이 광장 캐릭터와 다를 때만 값이 있다.
    var differingCurrent: TeamMonSummary? {
        guard case .loaded(let state, let profile) = self else { return nil }
        let c = profile.current, a = state.character
        return (c.speciesID == a.speciesID && c.isShiny == a.isShiny && c.form == a.form) ? nil : c
    }
}

/// 팀원 옆에서 스페이스로 여는 메뉴의 항목. 위에서부터 이 순서다.
enum PlazaMemberAction: CaseIterable, Equatable {
    /// 하트나 폭죽을 나와 그 팀원 머리 위에 함께 띄운다.
    case greet
    /// 그 팀원에게 뛰어들어 한 칸 밀어낸다.
    case tackle
    /// 그 팀원 옆에 붙어 계속 따라다닌다(기차놀이).
    case follow
    /// 그 팀원의 도감 카드를 연다.
    case viewCard
}

/// 팀원 메뉴. 고른 항목은 방향키로 옮기고, 끝에서 넘어가면 반대쪽 끝으로 간다.
struct PlazaMemberMenu: Equatable {
    let memberID: String
    let nickname: String
    var nameColor: UInt32?
    /// 이름 아래에 금색으로 그리는 한 줄. 집중 중인 팀원에게만 있다.
    var status: String?
    var selection: PlazaMemberAction = .greet
    /// 보이는 줄. 알은 걸을 수 없어 따라가기가 빠진다.
    var actions: [PlazaMemberAction] = PlazaMemberAction.allCases

    mutating func move(by step: Int) {
        let all = actions
        let i = all.firstIndex(of: selection) ?? 0
        selection = all[((i + step) % all.count + all.count) % all.count]
    }
}

/// 모닥불 메뉴. `minutes`가 비면 빈 자리가 없다는 안내만 보인다. `selection`은 `minutes`의 순번이다.
struct PlazaCampfireMenu: Equatable {
    let isJoin: Bool
    let minutes: [Int]
    var selection: Int

    mutating func move(by step: Int) {
        guard !minutes.isEmpty else { return }
        selection = ((selection + step) % minutes.count + minutes.count) % minutes.count
    }
}

enum PlazaOverlayContent: Equatable { case none, card(PlazaCardState), board, memberMenu(PlazaMemberMenu), campfireMenu(PlazaCampfireMenu) }

/// 판이 열린 동안 장면이 넘기는 키. 판마다 쓰는 키가 다르다.
enum PlazaOverlayKey: Equatable { case up, down, space, enter, escape }

/// 광장 위에 뜨는 판의 내용. 그리는 쪽(`PlazaOverlayView`)은 이 값만 본다.
@MainActor @Observable
final class PlazaOverlayModel {
    var content: PlazaOverlayContent = .none
    var banner: String?
    /// 단체 사진 카운트다운. 배너와 따로 위쪽에 띄운다.
    var countdown: String?
    /// 스페이스로 말을 걸 수 있을 때 위쪽에 띄우는 안내.
    var hint: String?
}
