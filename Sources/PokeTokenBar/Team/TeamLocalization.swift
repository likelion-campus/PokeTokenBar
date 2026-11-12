import Foundation

/// 팀 UI 문구 — 한국어 고정. 팀 기능은 한국어만 지원하므로 `t(...)` 를 쓰지 않는다.
/// Team 쪽 한글 문자열 리터럴은 이 파일에만 둔다 (TeamLocalizationTests 가 검사).
extension L {
    var teamSectionTitle: String { "팀" }
    /// 이름 앞에 붙여 읽는 성격. 본가 이름("의젓")은 뒤에 이름이 오면 어색해 꾸미는 말로 바꾼다.
    func plazaNatureTitle(_ nature: PokemonNature) -> String {
        switch nature {
        case .hardy: "노력하는"
        case .lonely: "외로운"
        case .brave: "용감한"
        case .adamant: "고집스러운"
        case .naughty: "개구쟁이"
        case .bold: "대담한"
        case .docile: "온순한"
        case .relaxed: "무사태평한"
        case .impish: "장난꾸러기"
        case .lax: "촐랑대는"
        case .timid: "겁쟁이"
        case .hasty: "성급한"
        case .serious: "성실한"
        case .jolly: "명랑한"
        case .naive: "천진난만한"
        case .modest: "조심스러운"
        case .mild: "의젓한"
        case .quiet: "냉정한"
        case .bashful: "수줍은"
        case .rash: "덜렁대는"
        case .calm: "차분한"
        case .gentle: "얌전한"
        case .sassy: "건방진"
        case .careful: "신중한"
        case .quirky: "변덕스러운"
        }
    }
    var teamEnable: String { "팀 기능 켜기" }
    var teamCreate: String { "팀 만들기" }
    var teamJoin: String { "코드로 참여" }
    var teamCodePlaceholder: String { "팀 코드 붙여 넣기" }
    var teamCodeInvalid: String { "팀 코드가 올바르지 않아요" }
    var teamCopyCode: String { "코드 복사" }
    var teamLeave: String { "팀 나가기" }
    var teamName: String { "팀 이름" }
    var teamSwitch: String { "팀 바꾸기" }
    var teamStepOut: String { "다른 팀 만들기·참여" }
    var teamSaved: String { "저장한 팀" }
    var teamEnterSaved: String { "들어가기" }
    func teamDefaultName(_ n: Int) -> String { "팀 \(n)" }
    var teamNickname: String { "닉네임" }
    var teamNicknameInvalid: String { "닉네임은 1~12자로 입력해 주세요" }
    var teamNotifications: String { "팀 알림" }
    var teamCoreTime: String { "코어타임" }
    func teamHour(_ h: Int) -> String { "\(h)시" }
    /// "11월 5일 14:02" — 사용자의 달력과 시간대로.
    func teamScheduleDate(_ date: Date, calendar: Calendar = .current) -> String {
        Self.scheduleDateLock.lock()
        defer { Self.scheduleDateLock.unlock() }
        if Self.scheduleDateFormatter.calendar != calendar {
            Self.scheduleDateFormatter.calendar = calendar
            Self.scheduleDateFormatter.timeZone = calendar.timeZone
        }
        return Self.scheduleDateFormatter.string(from: date)
    }
    /// 설정 화면이 그려질 때마다 만들지 않도록 하나만 둔다. 달력이 바뀐 때만 다시 맞춘다.
    private static let scheduleDateLock = NSLock()
    nonisolated(unsafe) private static let scheduleDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M월 d일 HH:mm"
        return f
    }()
    var teamScheduleDefaultCaption: String { "모든 팀원에게 같이 적용돼요 · 앞뒤 1시간은 노을이 져요" }
    func teamScheduleChangedCaption(name: String, when: String) -> String {
        "모든 팀원에게 같이 적용돼요 · \(name)님이 \(when)에 바꿨어요"
    }
    var teamIncompatiblePeer: String { "다른 버전을 쓰는 팀원이 있어요. 모두 최신 버전으로 업데이트해 주세요" }
    var plazaOpen: String { "광장 열기" }
    var plazaWindowTitle: String { "팀 광장" }
    var plazaDittoName: String { "메타몽" }
    func plazaDecoyFound(nickname: String) -> String { "\(nickname)님이 메타몽을 찾았어요!" }
    func plazaMimicFound(finder: String, owner: String) -> String { "\(finder)님이 \(owner)의 메타몽을 찾았어요!" }
    /// 창 제목. 저장한 팀 이름이 있으면 함께 보인다.
    func plazaWindowTitle(teamName: String?) -> String { teamName.map { "\(plazaWindowTitle) · \($0)" } ?? plazaWindowTitle }
    var plazaBoardHint: String { "스페이스바를 눌러 소식판 보기" }
    var plazaCampfireLightHint: String { "스페이스바를 눌러 모닥불 피우기" }
    /// 집중 남은 시간. 1분 미만도 "1분"으로 올림해 보인다.
    func plazaFocusRemaining(seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded(.up)))
        guard minutes >= 60 else { return "\(minutes)분 남음" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h)시간 남음" : "\(h)시간 \(m)분 남음"
    }
    /// 집중 중인 팀원 메뉴의 상태 줄.
    func plazaFocusStatus(seconds: TimeInterval) -> String { "🔥 집중 중 · " + plazaFocusRemaining(seconds: seconds) }
    func plazaFocusDuration(minutes: Int) -> String { minutes % 60 == 0 ? "\(minutes / 60)시간" : "\(minutes)분" }
    var plazaCampfireJoinHint: String { "스페이스바를 눌러 같이 집중하기" }
    /// 앉아 있는 동안의 안내. `remaining`은 `plazaFocusRemaining`의 결과.
    func plazaFocusHint(remaining: String) -> String { "🔥 \(remaining) · 방향키로 일어나기" }
    func plazaCampfireMenuTitle(isJoin: Bool) -> String { isJoin ? "같이 집중하기" : "모닥불" }
    func plazaCampfireRow(minutes: Int) -> String { "\(plazaFocusDuration(minutes: minutes)) 집중" }
    var plazaCampfireFull: String { "자리가 없어요" }
    func plazaMemberHint(nickname: String) -> String { "스페이스바를 눌러 \(nickname)에게 말 걸기" }
    /// While I am disguised as a teammate: who, and the time left (rounded up, never below 0:00).
    func plazaMimicHint(nickname: String, seconds: TimeInterval) -> String {
        let left = max(0, Int(seconds.rounded(.up)))
        return "\(KoreanParticle.direction.attach(to: nickname)) 변신 중 · \(left / 60):\(String(format: "%02d", left % 60))"
    }
    var plazaDivingHint: String { "잠수 중 · 물가에 선 팀원 밑에서 C로 끌어들이기" }
    func plazaPullHint(nickname: String) -> String { "C를 눌러 \(nickname) 물속으로 끌어들이기" }
    var plazaHiddenHint: String { "풀숲에 숨었어요 · 팀원이 옆에 오면 Z로 놀래키기" }
    func plazaStartleHint(nickname: String) -> String { "Z를 눌러 \(nickname) 놀래키기" }
    var plazaStartleManyHint: String { "Z를 눌러 옆에 있는 팀원 놀래키기" }
    var plazaMenuGreet: String { "인사하기" }
    var plazaMenuTackle: String { "몸통박치기" }
    var plazaJump: String { "점프 · 물놀이" }
    var plazaShortcutsTitle: String { "단축키" }
    var plazaShortcutSnowball: String { "눈뭉치" }
    var plazaShortcutArrows: String { "방향키" }
    var plazaShortcutWalk: String { "걷기" }
    var plazaShortcutRun: String { "달리기" }
    var plazaShortcutTalk: String { "말 걸기" }
    var plazaShortcutChat: String { "한마디" }
    var plazaShortcutEmotes: String { "말풍선" }
    var plazaShortcutPhoto: String { "사진 모드" }
    var plazaShortcutZoom: String { "확대·축소" }
    var plazaShortcutGroupPhoto: String { "단체 사진" }
    var plazaShortcutFirework: String { "불꽃놀이" }
    var plazaShortcutDance: String { "춤" }
    /// 광장에서 주운 아이템. 조사까지 붙인 목적어 꼴이다.
    func plazaItemObject(_ kind: ItemKind) -> String {
        switch kind {
        case .rareCandy: "이상한 사탕을"
        case .mint: "민트를"
        case .shinyCharm: "이로치 부적을"
        }
    }
    func plazaPickedUp(_ kind: ItemKind) -> String { "\(plazaItemObject(kind)) 주웠어요! 가방에 넣었어요" }
    func plazaMemberPickedUp(nickname: String, kind: ItemKind) -> String { "\(nickname)님이 \(plazaItemObject(kind)) 주웠어요" }
    /// 이름을 아직 모르는 팀원.
    var plazaGroupPhotoSomeone: String { "팀원" }
    /// 단체 사진 카운트다운. joined는 사진 모드인지, frontmost는 광장 창이 맨 앞인지다. 0에 사진이 클립보드에 들어가는 건 둘 다일 때뿐이라,
    /// 사진 모드인데 창이 뒤에 있으면 찍히지 않는다고 알린다. 내가 시작했으면 이름 없이, 팀원이 시작했으면 이름과 함께 알려 준다.
    func plazaGroupPhotoCountdown(starter: String?, seconds: Int, joined: Bool, frontmost: Bool) -> String {
        let head = starter.map { "\($0)님의 단체 사진 \(seconds) · " } ?? "단체 사진 \(seconds) · "
        guard joined else { return head + "P를 누르면 함께 찍어요" }
        guard frontmost else { return head + "광장 창을 앞에 두면 함께 찍혀요" }
        return head + (starter == nil ? "모두 모여요!" : "함께 찍는 중")
    }
    var plazaPhotoGuide: String { "📷 사진 모드 · 방향키 이동 · Shift 빠르게 · −/+ 확대 · Space 찍기 · G 단체 사진 · Esc 나가기" }
    var plazaPhotoCopied: String { "사진을 클립보드에 담았어요 · ⌘V로 붙여 넣기" }
    var plazaMenuFollow: String { "따라가기" }
    func plazaFollowHint(nickname: String) -> String { "\(nickname) 따라가는 중 · 방향키로 멈추기" }
    var plazaMenuViewCard: String { "포켓몬 보기" }
    var plazaRosterTitle: String { "팀원" }
    var plazaStatusOnline: String { "접속" }
    var plazaStatusFocus: String { "🔥집중" }
    var plazaStatusIdle: String { "자리비움" }
    var plazaStatusAsleep: String { "잠" }
    func plazaRosterCount(online: Int, total: Int) -> String { "접속 \(online) / \(total)" }
    var plazaEggName: String { "알" }
    var plazaAwaySuffix: String { "zZ" }
    var plazaChatPlaceholder: String { "한마디 (Enter 전송, Tab 확성기, Esc 취소)" }
    var plazaLoudPlaceholder: String { "📢 확성기: 광장 밖 팀원도 알림 (Tab 끄기)" }
    var plazaLoudTooSoon: String { "확성기는 1분에 한 번만 쓸 수 있어요" }
    var plazaChatEmoji: String { "이모지" }
    var plazaChatLogTitle: String { "대화 기록" }
    var plazaRosterWalkHint: String { "누르면 이 팀원에게 걸어가요" }
    var plazaChatLogExpand: String { "펼치기 ▴" }
    var plazaChatLogCollapse: String { "접기 ▾" }
    func teamMegaphoneNotice(nickname: String, text: String) -> String { "📢 \(nickname): \(text)" }
    var plazaBackgroundHide: String { "배경 숨기기" }
    var plazaBackgroundShow: String { "배경 보이기" }
    var plazaNameColor: String { "이름 색" }
    func plazaClock(phase: PlazaDaylight.Phase, time: String) -> String {
        let name = switch phase {
        case .dawn: "아침"
        case .day: "낮"
        case .dusk: "저녁"
        case .night: "밤"
        }
        return "\(name) \(time)"
    }
    func plazaNameColorChoice(_ n: Int) -> String { "이름 색 \(n)" }
    var plazaEmoteLol: String { "ㅋㅋ" }
    var plazaEmoteDance: String { "♪" }
    var plazaCardLoading: String { "불러오는 중…" }
    /// 카드 맨 위. 누구의 카드인지 보인다.
    func plazaCardTitle(nickname: String) -> String { "\(nickname)의 포켓몬" }
    var plazaCardShiny: String { "★ 이로치" }
    var plazaCardFailed: String { "도감을 받지 못했어요" }
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

    func plazaFocusDoneLine(minutes: Int) -> String { "🔥 \(plazaFocusDuration(minutes: minutes)) 집중 끝!" }
    func plazaFocusEarlyLine(minutes: Int) -> String { "집중을 마쳤어요 · \(minutes)분" }
    /// 집중 중 모아 둔 알림 요약. 0인 항목은 뺀다. 모은 게 없으면 nil.
    func plazaFocusSummary(_ t: TeamFocusTally) -> String? {
        let parts = [("♥", t.hearts), ("ㅋㅋ", t.lols), ("🎉", t.parties), ("반응", t.reactions), ("소식", t.news)]
            .filter { $0.1 > 0 }.map { "\($0.0) \($0.1)" }
        return parts.isEmpty ? nil : "그동안 " + parts.joined(separator: " · ")
    }

    /// 팀 알림. 제목과 본문에 사용량 수치는 넣지 않는다.
    var teamNoticeTitle: String { "팀 광장" }
    func teamReactionNotice(nickname: String) -> String { "\(KoreanParticle.subject.attach(to: nickname)) 내 소식에 반응했어요" }
    func teamEmoteNotice(nickname: String, kind: TeamEmoteKind) -> String {
        "\(KoreanParticle.subject.attach(to: nickname)) 내 포켓몬에게 \(teamEmoteLabel(kind))"
    }
    /// 말풍선의 글자 표기. 반응 버튼과 같은 글자를 쓴다.
    func teamEmoteLabel(_ kind: TeamEmoteKind) -> String {
        switch kind {
        case .heart: teamReactionLabel(.cute)
        case .lol: plazaEmoteLol
        case .party: teamReactionLabel(.congrats)
        case .exclaim: "!"
        case .question: "?"
        case .tackle: "💥"
        case .jump: "점프"
        case .groupPhoto: "단체 사진"
        case .pickup: "아이템"
        case .firework: "불꽃놀이"
        case .decoyFound: "찾았다"
        case .decoyJump: "점프"
        case .pull: "끌어들이기"
        case .snowball: "눈뭉치"
        case .decoyTackle: "💥"
        case .mimicTackle: "💥"
        case .mimicFound: "찾았다"
        case .dance: "춤"
        }
    }
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
