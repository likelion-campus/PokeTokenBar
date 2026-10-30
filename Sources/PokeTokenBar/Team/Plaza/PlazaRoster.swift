import Foundation
import Observation

enum PlazaPresence: Sendable { case online, away }

/// 참여자 목록의 한 칸. 레벨·HP·진행률 같은 수치는 일부러 담지 않는다.
struct PlazaRosterEntry: Equatable, Identifiable, Sendable {
    let id: String               // 멤버 ID (1부에서는 TeamSettings.memberID)
    let nickname: String
    let speciesID: Int?          // nil = 알
    let speciesName: String
    let gender: PokemonGender?   // 모르면 nil(기호 없음)
    let isShiny: Bool
    let presence: PlazaPresence
    let isMe: Bool
}

/// 목록 판의 크기. 장면 카메라가 가려진 폭을 알아야 해서 한 곳에 둔다.
enum PlazaRosterMetrics {
    static let width: CGFloat = 232
    static let margin: CGFloat = 14
    static var coveredWidth: CGFloat { width + margin }
}

/// 화면이 지켜보는 목록. 창이 닫혀도 모델만 남고 그리기는 멈춘다.
@MainActor @Observable final class PlazaRosterModel {
    var entries: [PlazaRosterEntry] = []
    /// 창이 가려지거나 최소화되면 false — 목록 아이콘의 통통 튐을 멈춘다.
    var isAnimating = true
}

enum PlazaRoster {
    /// 앱의 저장소와 설정에서 내 칸을 만든다. 고른 대표 종의 이름은 폼을 반영한 도감 종 이름이다.
    @MainActor static func myEntry(companion: CompanionStore, teamSettings: TeamSettings) -> PlazaRosterEntry {
        let followsRaised = companion.representativeSpeciesID == nil
        return myEntry(
            memberID: teamSettings.memberID,
            nickname: TeamSettings.validNickname(teamSettings.nickname) ?? "",
            subject: companion.representativeSubject, followsRaised: followsRaised,
            raisedName: companion.displayName, raisedGender: companion.state.active?.profile?.gender,
            pinnedName: followsRaised ? nil : companion.representativeDexSpecies?.name,
            eggName: L(.ko).plazaEggName)
    }

    /// 나 → 접속 중 → 자리 비움, 같은 무리 안에서는 닉네임 순.
    static func sorted(_ entries: [PlazaRosterEntry]) -> [PlazaRosterEntry] {
        func rank(_ e: PlazaRosterEntry) -> Int { e.isMe ? 0 : (e.presence == .online ? 1 : 2) }
        return entries.sorted {
            let (a, b) = (rank($0), rank($1))
            if a != b { return a < b }
            if $0.nickname != $1.nickname { return $0.nickname < $1.nickname }
            return $0.id < $1.id
        }
    }

    /// 내 칸: 대표 포켓몬을 고르지 않았으면 키우는 포켓몬(이름 = companion.displayName, 성별 = 키우는 개체의 성별),
    /// 골랐으면 그 종(이름 = 도감 종 이름, 성별 nil), 알이면 speciesID nil·이름 L.plazaEggName·성별 nil.
    static func myEntry(memberID: String, nickname: String, subject: CompanionStore.RepresentativeSubject,
                        followsRaised: Bool, raisedName: String, raisedGender: PokemonGender?,
                        pinnedName: String?, eggName: String) -> PlazaRosterEntry {
        let name: String
        let gender: PokemonGender?
        if subject.speciesID == nil {
            name = eggName; gender = nil
        } else if followsRaised {
            name = raisedName; gender = raisedGender
        } else {
            name = pinnedName ?? raisedName; gender = nil
        }
        return PlazaRosterEntry(id: memberID, nickname: nickname, speciesID: subject.speciesID, speciesName: name,
                                gender: gender, isShiny: subject.isShiny, presence: .online, isMe: true)
    }
}
