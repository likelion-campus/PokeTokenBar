import Foundation

/// 팀 UI 문구 — 한국어 고정. 팀 기능은 한국어만 지원하므로 `t(...)` 를 쓰지 않는다.
/// Team 쪽 한글 문자열 리터럴은 이 파일에만 둔다 (TeamLocalizationTests 가 검사).
extension L {
    var teamSectionTitle: String { "팀" }
    var teamEnable: String { "팀 기능 켜기" }
    var teamCreate: String { "팀 만들기" }
    var teamJoin: String { "코드로 참여" }
    var teamCodePlaceholder: String { "팀 코드 붙여 넣기" }
    var teamCodeInvalid: String { "팀 코드가 올바르지 않아요" }
    var teamCopyCode: String { "코드 복사" }
    var teamLeave: String { "팀 나가기" }
    var teamNickname: String { "닉네임" }
    var teamNicknameInvalid: String { "닉네임은 1~12자로 입력해 주세요" }
    var teamNotifications: String { "팀 알림" }
    var teamIncompatiblePeer: String { "다른 버전을 쓰는 팀원이 있어요. 모두 최신 버전으로 업데이트해 주세요" }
    var plazaOpen: String { "광장 열기" }
    var plazaWindowTitle: String { "팀 광장" }
    var plazaRosterTitle: String { "팀원" }
    var plazaStatusOnline: String { "접속" }
    var plazaStatusAway: String { "잠" }
    func plazaRosterCount(online: Int, total: Int) -> String { "접속 \(online) / \(total)" }
    var plazaEggName: String { "알" }
    var plazaAwaySuffix: String { "zZ" }
    var plazaEmoteLol: String { "ㅋㅋ" }
    var plazaCardLoading: String { "불러오는 중…" }
    var plazaCardFailed: String { "도감을 받지 못했어요" }
    func plazaRosterMore(_ n: Int) -> String { "외 \(n)명" }
    var plazaBoardTitle: String { "소식판" }
    var plazaBoardEmpty: String { "아직 소식이 없어요" }
    var plazaBoardShinyPrefix: String { "이로치 " }

    /// 소식판, 안내, 알림이 함께 쓰는 한 줄. 수치는 넣지 않는다.
    func teamEventText(_ e: TeamEvent) -> String {
        let nick = e.authorNickname
        switch e.kind {
        case .hatch:
            let name = (e.isShiny ? plazaBoardShinyPrefix : "") + KoreanParticle.subject.attach(to: e.speciesName)
            return "\(nick)의 알에서 \(name) 나왔어요!"
        case .dittoReveal:
            return "\(nick)의 포켓몬은 사실 메타몽이었어요!"
        case .graduate:
            return "\(nick)의 \(KoreanParticle.subject.attach(to: e.speciesName)) 졸업했어요!"
        case .evolve:
            let from = KoreanParticle.subject.attach(to: e.fromSpeciesName ?? e.speciesName)
            return "\(nick)의 \(from) \(KoreanParticle.direction.attach(to: e.speciesName)) 진화했어요"
        }
    }

    /// 팀 알림. 제목과 본문에 사용량 수치는 넣지 않는다.
    var teamNoticeTitle: String { "팀 광장" }
    func teamReactionNotice(nickname: String) -> String { "\(KoreanParticle.subject.attach(to: nickname)) 내 소식에 반응했어요" }
    func teamEmoteNotice(nickname: String) -> String { "\(KoreanParticle.subject.attach(to: nickname)) 말풍선을 보냈어요" }
    /// `others`는 첫 사람을 뺀 서로 다른 닉네임 수. 0이면 한 사람이다.
    func teamNoticeSummary(first: String, others: Int) -> String {
        others > 0 ? "\(first) 외 \(others)명이 반응했어요" : "\(KoreanParticle.subject.attach(to: first)) 반응했어요"
    }

    /// 소식 날짜. 시각을 모르면 날짜만.
    func teamBoardDate(month: Int, day: Int, time: String?) -> String {
        time.map { "\(month)월 \(day)일 \($0)" } ?? "\(month)월 \(day)일"
    }

    /// 소식에 달린 반응과 반응 버튼의 글자. 댓글은 화면에 내지 않는다.
    func teamReactionLabel(_ kind: TeamReactionKind) -> String {
        switch kind {
        case .cute: "♥"
        case .lol: plazaEmoteLol
        case .congrats: "🎉"
        case .comment: ""
        }
    }
}
