import Foundation
import Observation

/// 목록의 상태. 접속: 앱이 켜져 있고 입력이 있다(광장을 닫았어도). 자리비움: 한동안 입력이 없다.
/// 잠: 연결이 끊겼다(Mac이 잠들었거나 앱을 껐다). 잠은 이 앱을 켜 둔 동안 본 팀원만 메모리에 남는다.
/// 집중: 모닥불 옆에서 집중 중이다. 잠보다 약하고 자리비움보다 강하며, 정렬과 색은 접속과 같다.
enum PlazaPresence: Sendable { case online, idle, asleep, focus }

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
    var nature: PokemonNature? = nil   // 이름표 위에 쓴다. 목록에는 보이지 않는다
    var activity: PlazaActivity? = nil // 칸에 마우스를 올리면 보인다. 오늘 기록이 아니거나 이전 버전 팀원이면 nil(기록 없음)
}

/// 목록 판의 크기. 장면 카메라가 가려진 폭을 알아야 해서 한 곳에 둔다.
enum PlazaRosterMetrics {
    static let width: CGFloat = 232
    static let margin: CGFloat = 14
    static var coveredWidth: CGFloat { width + margin }
    /// 판 안쪽 여백(위아래 각각), 머리줄 높이, 머리줄과 첫 칸 사이, 칸 높이와 간격.
    static let padding: CGFloat = 10
    static let headerHeight: CGFloat = 20
    static let listTopPadding: CGFloat = 6
    static let slotHeight: CGFloat = 44
    static let slotSpacing: CGFloat = 4
    /// 펼친 칸 아래 오늘 한 일의 줄 높이와 줄 간격, 위 여백, 아래 여백.
    static let activityRowHeight: CGFloat = 14
    static let activityRowGap: CGFloat = 1
    static let activityTopPadding: CGFloat = 0
    static let activityBottomPadding: CGFloat = 8
    /// 줄이 `rows`개(기록이 없으면 0개이고 한 줄)일 때 칸이 아래로 늘어나는 높이.
    static func activityHeight(rows: Int) -> CGFloat {
        let n = CGFloat(max(rows, 1))
        return activityTopPadding + n * activityRowHeight + (n - 1) * activityRowGap + activityBottomPadding
    }
    /// 한 페이지의 최대 칸 수. 포켓몬 게임의 파티가 여섯 마리인 데서 왔다.
    static let pageSize = 6
    /// 머리줄 < > 단추의 누르는 영역(한 변).
    static let pagerHitSize: CGFloat = 24
    /// 창 아래에서 비워 두는 높이: 아래 여백 16, 작은 지도 136, 사이 6, 시계 24, 시계와 띄우는 6.
    /// 작은 지도와 시계가 목록 위에 그려지므로 목록은 이 위에서 끝난다.
    static let bottomClearance: CGFloat = 188
}

/// 화면이 지켜보는 목록. 창이 닫혀도 모델만 남고 그리기는 멈춘다.
@MainActor @Observable final class PlazaRosterModel {
    var entries: [PlazaRosterEntry] = []
    /// 창이 가려지거나 최소화되면 false — 목록 아이콘의 통통 튐을 멈춘다.
    var isAnimating = true
    /// 한 페이지의 칸 수. 창 크기가 바뀔 때 정한다.
    var capacity = PlazaRosterMetrics.pageSize
    /// 보고 있는 페이지(0부터). 인원이 줄어 없어진 페이지면 그릴 때 마지막 페이지로 본다.
    var page = 0
    /// 마우스가 올라와 아래로 펼쳐진 칸의 팀원 ID.
    var hoveredID: String?
    /// 목록 칸들이 쓸 수 있는 가장 큰 높이. 작은 지도와 시계 위에서 끝나게 창 크기가 바뀔 때 정한다.
    var maxListHeight: CGFloat = .infinity

    /// 마우스가 칸에 들어오거나 나갔다. 다른 칸으로 옮겨 간 뒤 늦게 오는 나감은 새 칸을 접지 않는다.
    func hover(_ id: String, inside: Bool) {
        if inside { hoveredID = id } else if hoveredID == id { hoveredID = nil }
    }

    /// 보이는 페이지에서 앞이나 뒤로 넘긴다. 끝에서는 그대로다.
    func turnPage(by delta: Int) {
        hoveredID = nil
        let now = PlazaRoster.page(entries, index: page, size: capacity)
        page = min(max(now.index + delta, 0), now.count - 1)
    }
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
            eggName: L(.ko).plazaEggName, nature: companion.representativeNature)
    }

    /// 팀에 보내는 내 캐릭터. 이름과 성별은 내 칸과 같고, 알이면 종·이름·폼이 비어 있다.
    static func character(entry: PlazaRosterEntry, subject: CompanionStore.RepresentativeSubject) -> TeamMonSummary {
        guard entry.speciesID != nil else {
            return TeamMonSummary(speciesID: nil, isShiny: false, form: nil, speciesName: nil, gender: nil)
        }
        return TeamMonSummary(speciesID: entry.speciesID, isShiny: entry.isShiny, form: subject.form,
                              speciesName: entry.speciesName, gender: entry.gender, nature: entry.nature)
    }

    /// 내 칸, 연결된 팀원, 끊긴 팀원(잠)을 합쳐 정렬한다. 광장을 열었는지는 상태와 상관없다.
    /// 집중은 끝 시각이 지금보다 뒤일 때만이다(받을 때만 걸러지므로 여기서 다시 견준다).
    static func entries(me: PlazaRosterEntry?, meIsIdle: Bool = false, meIsFocusing: Bool = false, myActivity: PlazaActivity? = nil,
                        members: [TeamMemberState], asleep: [TeamMemberState] = [], now: Date = Date()) -> [PlazaRosterEntry] {
        let today = PlazaActivity.dayKey(now)
        func entry(_ m: TeamMemberState, _ presence: PlazaPresence) -> PlazaRosterEntry {
            PlazaRosterEntry(id: m.memberID, nickname: m.nickname, speciesID: m.character.speciesID,
                             speciesName: m.character.speciesName ?? (m.character.speciesID == nil ? L(.ko).plazaEggName : ""),
                             gender: m.character.gender, isShiny: m.character.isShiny, presence: presence, isMe: false,
                             nature: m.character.nature, activity: m.activity?.shown(on: today))
        }
        let connected = Set(members.map(\.memberID))
        let mine = me.map { e in
            PlazaRosterEntry(id: e.id, nickname: e.nickname, speciesID: e.speciesID, speciesName: e.speciesName,
                             gender: e.gender, isShiny: e.isShiny, presence: meIsFocusing ? .focus : (meIsIdle ? .idle : .online), isMe: true,
                             nature: e.nature, activity: myActivity?.shown(on: today))
        }
        let others = members.map { m in
            entry(m, m.focusEndsAt.map { $0 > now } == true ? .focus : (m.isIdle ? .idle : .online))
        }
            + asleep.filter { !connected.contains($0.memberID) }.map { entry($0, .asleep) }
        return sorted((mine.map { [$0] } ?? []) + others)
    }

    /// 창 높이(포인트)에서 시계 위까지 들어가는 칸 수. 많아도 한 페이지(여섯 칸)까지다.
    static func capacity(forHeight height: CGFloat) -> Int {
        let m = PlazaRosterMetrics.self
        let available = height - m.margin - m.bottomClearance - 2 * m.padding - m.headerHeight - m.listTopPadding
        let slots = Int(((available + m.slotSpacing) / (m.slotHeight + m.slotSpacing)).rounded(.down))
        return min(m.pageSize, max(1, slots))
    }

    /// 창 높이(포인트)에서 칸들이 쓸 수 있는 높이. 판 안쪽 여백, 머리줄과 그 아래 간격을 뺀 값이다.
    static func maxListHeight(forHeight height: CGFloat) -> CGFloat {
        let m = PlazaRosterMetrics.self
        return max(0, height - m.margin - m.bottomClearance - 2 * m.padding - m.headerHeight - m.listTopPadding)
    }

    /// 보이는 칸들을 쌓은 높이와, 마우스를 올려 펼친 칸의 아랫줄이 `maxHeight` 안에 들어오도록 목록을 위로 밀 거리.
    /// 펼친 칸 아래 칸들은 잘려도 괜찮지만 그 칸의 줄은 작은 지도에 가려지면 안 된다.
    static func listLayout(_ shown: [PlazaRosterEntry], hovered: String?, maxHeight: CGFloat) -> (height: CGFloat, scroll: CGFloat) {
        let m = PlazaRosterMetrics.self
        var y: CGFloat = 0, hoveredBottom: CGFloat = 0
        for (i, e) in shown.enumerated() {
            if i > 0 { y += m.slotSpacing }
            y += m.slotHeight
            if e.id == hovered { y += m.activityHeight(rows: PlazaActivity.rows(e.activity).count); hoveredBottom = y }
        }
        return (min(y, maxHeight), max(0, hoveredBottom - maxHeight))
    }

    /// 정렬된 목록을 `size`칸씩 나눈 한 페이지. 없어진 페이지를 달라고 하면 마지막 페이지를 준다.
    static func page(_ entries: [PlazaRosterEntry], index: Int, size: Int) -> (shown: [PlazaRosterEntry], index: Int, count: Int) {
        let count = max(0, entries.count - 1) / size + 1
        let index = min(index, count - 1)
        return (Array(entries.dropFirst(index * size).prefix(size)), index, count)
    }

    /// 나 → 접속(집중 포함) → 자리비움 → 잠, 같은 무리 안에서는 닉네임 순.
    static func sorted(_ entries: [PlazaRosterEntry]) -> [PlazaRosterEntry] {
        func rank(_ e: PlazaRosterEntry) -> Int {
            if e.isMe { return 0 }
            switch e.presence {
            case .online, .focus: return 1
            case .idle: return 2
            case .asleep: return 3
            }
        }
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
                        pinnedName: String?, eggName: String, nature: PokemonNature? = nil) -> PlazaRosterEntry {
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
                                gender: gender, isShiny: subject.isShiny, presence: .online, isMe: true, nature: nature)
    }
}
