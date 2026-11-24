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
    var teamCreateNamePlaceholder: String { "새 팀 이름" }
    var teamNameInvalid: String { "팀 이름은 1~12자로 입력해 주세요" }
    var teamNameSharedCaption: String { "바꾸면 팀원 모두의 팀 이름이 바뀌어요" }
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
    var teamSeason: String { "광장 계절" }
    func teamSeasonName(_ choice: PlazaSeasonChoice) -> String {
        switch choice {
        case .auto: "달력 따라 자동"
        case .spring: "봄"
        case .summer: "여름"
        case .autumn: "가을"
        case .winter: "겨울"
        }
    }
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
    /// 팀이 준비된 기기가 사용량을 회사 대시보드로 보낸다는 안내. 보낸 적이 없으면 그렇게 말한다.
    func teamUsageReportCaption(lastSent: Date?) -> String {
        guard let date = lastSent else { return "회사 대시보드로 보내는 중 · 아직 안 보냄" }
        return "회사 대시보드로 보내는 중 · \(teamScheduleDate(date))"
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
    var plazaFortuneHint: String { "스페이스바를 눌러 포춘쿠키 깨기" }
    var plazaFortuneAgainHint: String { "스페이스바를 눌러 쪽지 다시 보기" }
    func plazaFortuneAction(_ action: String) -> String { "행운의 행동 · \(action)" }
    var plazaFortuneLines: [String] { [
        "막힌 문제는 산책이 풀어 줘요",
        "오늘 한 질문이 내일을 줄여요",
        "작게 나눈 일이 먼저 끝나요",
        "물 한 잔이 좋은 생각을 불러요",
        "오늘은 천천히 가도 괜찮아요",
        "뜻밖의 칭찬이 찾아올 거예요",
        "잠깐 쉬면 답이 보일 거예요",
        "오늘의 실수는 내일의 요령이에요",
        "먼저 건넨 인사가 복이 돼요",
        "좋은 소식이 오후에 도착해요",
        "미뤄 둔 일이 의외로 쉬워요",
        "오늘은 운이 조금 더 좋아요",
        "도움을 청하면 길이 열려요",
        "어제보다 한 걸음이면 충분해요",
        "웃을 일이 한 번은 꼭 생겨요",
        "정리한 책상에 여유가 생겨요",
        "오늘 배운 것이 오래 남아요",
        "누군가 당신 덕에 편해졌어요",
        "점심이 평소보다 맛있을 거예요",
        "엉뚱한 생각이 정답일 수 있어요",
        "한 번 더 읽으면 답이 있어요",
        "끝이 안 보여도 줄고 있어요",
        "오늘은 저장을 잊지 않을 거예요",
        "기지개 한 번에 기분이 풀려요",
        "작은 친절이 크게 돌아와요",
        "오늘 회의는 일찍 끝날 거예요",
        "버그는 생각보다 가까이 있어요",
        "좋은 이름이 문득 떠오를 거예요",
        "창밖을 보면 눈이 편해져요",
        "오늘의 커피는 유난히 향긋해요",
        "급할수록 한 박자 쉬어 가요",
        "묻는 사람이 가장 빨리 배워요",
        "지금 하는 일이 누군가를 도와요",
        "잘하고 있어요, 정말이에요",
        "오늘은 퇴근길이 가벼울 거예요",
        "고민은 말하면 반으로 줄어요",
        "한 줄 메모가 내일을 살려요",
        "오래 찾던 답이 곧 나타나요",
        "천천히 해도 늦지 않았어요",
        "오늘 만난 사람이 귀인이에요",
        "간식 하나가 오후를 바꿔요",
        "처음 생각이 맞았을 거예요",
        "고마운 마음을 전해 보세요",
        "오늘은 뭘 해도 순조로워요",
        "쉬는 것도 일의 일부예요",
        "어려운 일은 이미 지나갔어요",
        "좋은 질문이 좋은 답을 불러요",
        "깊은 숨 한 번이 힘이 돼요",
        "기다리던 답장이 올 거예요",
        "당신의 꼼꼼함이 빛을 봐요",
        "오늘은 새로운 것을 발견해요",
        "한 걸음 물러서면 다 보여요",
        "지운 줄이 글을 좋게 해요",
        "함께 하면 절반만 힘들어요",
        "오늘 저녁은 푹 쉴 수 있어요",
        "느낌이 좋으면 그 길이 맞아요",
        "사소한 정리가 큰 힘이 돼요",
        "곧 좋은 아이디어가 와요",
        "오늘 건넨 말이 힘이 됐어요",
        "마음 가는 대로 해도 좋아요",
        "어깨를 펴면 기분도 펴져요",
        "오늘은 걱정이 비껴 가요",
        "다시 해 보면 이번엔 돼요",
        "남긴 기록이 나중에 웃게 해요",
        "조용한 응원이 곁에 있어요",
        "서두르지 않아도 닿을 거예요",
        "반가운 연락이 올 거예요",
        "눈을 감고 열까지 세어 봐요",
        "한 가지만 해도 잘한 날이에요",
        "오늘 고른 길이 지름길이에요",
        "모르는 건 물어도 괜찮아요",
        "오늘은 실수도 귀엽게 넘어가요",
        "좋아하는 노래가 힘을 줘요",
        "내일의 나에게 선물을 남겨요",
        "작은 성공을 꼭 축하하세요",
        "오늘 본 하늘이 유난히 예뻐요",
        "마무리가 깔끔하게 될 거예요",
        "꾸준함이 결국 이겨요",
        "좋은 하루는 이미 시작됐어요",
        "수고했다는 말을 듣게 돼요",
        "온천에 담근 발이 생각을 데워요",
        "모닥불 곁에 좋은 이야기가 모여요",
        "큰 나무 아래에 답이 떨어져요",
        "풀숲에서 뜻밖의 것을 만나요",
        "광장 한 바퀴가 머리를 맑게 해요",
        "오늘 광장에서 반가운 얼굴을 봐요",
        "불꽃 한 발이 기분을 띄워 줘요",
        "소식판에 좋은 소식이 붙어요",
        "함께 찍은 사진이 오래 남아요",
        "춤추는 사람 곁에 웃음이 모여요",
        "연못가에서 마음이 잔잔해져요",
        "쉼터에서 숨 고르기 좋은 날이에요",
        "오늘은 파트너가 유난히 신나 보여요",
        "알에서 좋은 소식이 깨어나요",
        "먼저 흔든 손에 인사가 돌아와요",
        "나란히 걸으면 길이 짧아져요",
        "오늘의 도감에 한 줄이 늘어요",
        "작은 점프가 큰 웃음이 돼요",
        "광장의 누군가 당신을 기다려요",
        "가판대 쿠키는 내일도 있어요",
        "오늘의 커밋은 깔끔하게 들어가요",
        "리뷰에서 좋은 말을 듣게 돼요",
        "테스트가 한 번에 초록불이에요",
        "토큰을 아낀 만큼 여유가 생겨요",
        "질문을 줄이면 답이 또렷해져요",
        "오늘의 빌드는 한 번에 통과해요",
        "지운 코드만큼 마음이 가벼워요",
        "로그 한 줄에 실마리가 있어요",
        "오늘은 충돌 없이 합쳐질 거예요",
        "좋은 프롬프트가 떠오를 거예요",
        "미뤄 둔 리팩터링이 술술 풀려요",
        "오류 메시지가 오늘은 친절해요",
        "문서 한 줄이 동료를 구해요",
        "작은 PR이 빨리 머지돼요",
        "오늘 고친 버그는 돌아오지 않아요",
        "변수 이름이 한 번에 정해져요",
        "배포 버튼이 오늘은 가벼워요",
        "주석 한 줄이 미래를 도와요",
        "캐시를 비우면 길이 보여요",
        "검색 첫 줄에 답이 있을 거예요",
        "맥락을 잘 주면 답도 잘 와요",
        "한 번에 하나씩이 가장 빨라요",
        "오늘은 한도가 넉넉하게 느껴져요",
        "꼼꼼한 리뷰에 고맙다는 말이 와요",
        "실험해 본 것이 정답이 돼요",
        "되돌리기 버튼이 든든한 날이에요",
        "오래된 할 일 하나가 사라져요",
        "자동화한 만큼 저녁이 길어져요",
        "오늘 읽은 코드가 스승이 돼요",
        "막힌 곳은 설명하다가 풀려요",
        "첫 줄을 쓰면 나머지가 따라와요",
        "십 분만 해 보면 계속하게 돼요",
        "오늘 정한 우선순위가 맞아요",
        "거절 한 번이 하루를 지켜 줘요",
        "메일 답장이 금방 끝날 거예요",
        "알림을 끄면 집중이 찾아와요",
        "아침에 끝낸 일이 오후를 살려요",
        "목록에서 하나를 지우는 날이에요",
        "오늘의 계획은 절반만 해도 좋아요",
        "마감은 생각보다 넉넉해요",
        "미리 확인한 덕에 시간을 아껴요",
        "회의에서 좋은 의견을 내게 돼요",
        "메모해 둔 것이 오늘 쓰여요",
        "덜어 낸 만큼 또렷해져요",
        "익숙한 일에서 새 길을 찾아요",
        "오늘의 집중은 오래 이어져요",
        "작은 습관이 큰 차이를 만들어요",
        "미리 해 둔 일이 고마운 날이에요",
        "가장 쉬운 일부터 해도 좋아요",
        "오늘은 일이 손에 잘 붙어요",
        "끝낸 일을 세어 보면 꽤 많아요",
        "초안은 엉성해도 충분해요",
        "정시에 끝내는 기분을 맛봐요",
        "한 번 정리하면 오래 편해요",
        "오늘의 선택에 후회가 없어요",
        "목을 돌리면 생각도 돌아가요",
        "햇볕 오 분이 기운을 채워요",
        "오늘 밤은 깊이 잘 수 있어요",
        "따뜻한 차 한 잔이 위로가 돼요",
        "계단 한 층이 머리를 깨워요",
        "먼 곳을 보면 생각이 넓어져요",
        "천천히 먹은 밥이 힘이 돼요",
        "자리에서 일어나면 답이 와요",
        "손목을 풀면 손이 가벼워져요",
        "오늘은 몸이 가볍게 느껴져요",
        "오늘 저녁 메뉴가 마음에 들어요",
        "바람 한 줄기가 기분을 바꿔요",
        "손을 씻으면 마음도 개운해요",
        "낮잠 같은 여유가 찾아와요",
        "일찍 잠들면 내일이 쉬워져요",
        "고맙다는 말이 두 배로 돌아와요",
        "오늘 들은 농담이 오래 웃겨요",
        "옆자리에서 좋은 힌트가 와요",
        "안부를 물으면 반가워할 거예요",
        "칭찬은 아끼지 않아도 좋아요",
        "같이 먹는 밥이 더 맛있어요",
        "오늘은 말이 잘 통하는 날이에요",
        "누군가 당신의 일을 알아봐요",
        "도와준 일이 좋은 인연이 돼요",
        "솔직한 한마디가 일을 풀어요",
        "잘 들어 주면 답이 들려요",
        "이름을 불러 주면 반가워해요",
        "함께 웃으면 일이 가벼워져요",
        "믿고 맡기면 더 잘 돌아와요",
        "오늘 당신은 좋은 동료예요",
        "작은 행운이 주머니에 들어와요",
        "신호등이 오늘은 내 편이에요",
        "잃어버린 것이 제자리에 있어요",
        "우연히 들은 말이 힌트가 돼요",
        "오늘은 줄이 금방 줄어들어요",
        "기대하지 않은 선물이 와요",
        "좋은 예감이 그대로 맞아요",
        "하고 싶던 말을 하게 돼요",
        "오늘의 날씨가 기분에 맞아요",
        "새로 시작하기 좋은 날이에요",
        "망설이던 일에 용기가 나요",
        "오늘은 나에게 너그러워도 돼요",
        "지나고 보면 잘한 선택이에요",
        "내일은 오늘보다 한결 쉬워요",
        "지금 이 순간도 충분히 좋아요",
        // 201번째부터는 두 줄 운세다. \n 이 쪽지의 줄바꿈이다.
        "광장 한 바퀴를 돌고 오면\n막힌 생각이 먼저 풀려 있어요",
        "모닥불 앞에 잠깐 앉아 보세요\n급한 마음이 먼저 식어요",
        "오늘 광장에서 마주친 팀원이\n좋은 소식을 들고 와요",
        "연못에 한 번 뛰어들고 나면\n머릿속이 맑게 개어요",
        "큰 나무 아래에서 쉬어 가세요\n좋은 생각은 그늘에서 자라요",
        "풀숲을 헤치고 걷다 보면\n뜻밖의 것이 발밑에 있어요",
        "오늘 건넨 인사 하나가\n광장을 한 뼘 더 따뜻하게 해요",
        "쉼터에 먼저 와 있는 팀원이\n오늘의 좋은 말동무예요",
        "광장에 발자국을 남긴 만큼\n오늘 하루가 가벼워져요",
        "잠깐 멈춰 서서 둘러보세요\n놓친 풍경이 거기 있어요",
        "가판대까지 걸어온 걸음이\n오늘의 첫 번째 행운이에요",
        "포켓몬이 먼저 신이 나 있어요\n오늘은 그 기분을 따라가 보세요",
        "광장에서 웃은 횟수만큼\n오후 일이 술술 풀려요",
        "오늘은 혼자 걷지 않아도 돼요\n곁에 설 팀원이 곧 와요",
        "물가에 서서 숨을 고르면\n다음 할 일이 또렷해져요",
        "오래 미룬 리팩터링이\n오늘은 생각보다 쉽게 끝나요",
        "에러 메시지를 끝까지 읽으면\n답이 그 안에 적혀 있어요",
        "오늘 쓴 테스트 하나가\n다음 달의 나를 구해 줘요",
        "프롬프트를 한 줄 더 다듬으면\n결과가 두 배로 좋아져요",
        "작은 커밋을 여러 번 쌓으면\n큰 변경도 무섭지 않아요",
        "버그는 생각보다 가까이 있어요\n오늘은 금방 잡혀요",
        "문서를 한 번 더 읽은 사람이\n오늘 가장 빨리 끝내요",
        "지우는 코드가 많은 날이\n가장 잘한 날이에요",
        "이름을 잘 지은 변수 하나가\n주석 열 줄을 대신해요",
        "오늘 올린 PR에는\n기분 좋은 승인이 달려요",
        "로그 한 줄을 더 남겨 두면\n내일의 수수께끼가 사라져요",
        "막힐 땐 문제를 소리 내 말해요\n말하는 사이에 답이 나와요",
        "에이전트에게 맡긴 일이\n오늘은 한 번에 맞게 돌아와요",
        "토큰을 아낀 만큼\n생각할 여유가 넉넉해져요",
        "빌드가 도는 동안 쉬어도 돼요\n초록불은 기다리면 와요",
        "어제 포기한 그 문제가\n오늘은 다른 얼굴로 풀려요",
        "가장 단순한 방법부터 해 보세요\n오늘은 그게 정답이에요",
        "리뷰에 남긴 다정한 한마디가\n팀의 코드를 바꿔요",
        "복잡해 보이는 일도\n첫 줄을 쓰면 반은 끝나요",
        "오늘 배운 단축키 하나가\n일 년의 시간을 아껴 줘요",
        "되돌릴 수 있게 해 둔 일은\n마음 놓고 시도해도 돼요",
        "다시 재현되는 버그는\n이미 반쯤 고친 버그예요",
        "맥락을 잘 건넨 질문에는\n좋은 답이 돌아와요",
        "오늘의 배포는 조용히 지나가요\n조용한 배포가 최고예요",
        "낯선 코드도 오늘은\n천천히 읽으면 친절해져요",
        "가장 하기 싫은 일을 먼저 하면\n남은 하루가 선물이 돼요",
        "할 일을 세 개로 줄여 보세요\n세 개는 오늘 다 끝나요",
        "완벽한 시작을 기다리지 마세요\n엉성한 첫걸음이 길을 내요",
        "오늘 거절한 일 하나가\n중요한 일의 자리를 만들어요",
        "십 분만 해 보자는 마음이\n한 시간의 몰입을 불러요",
        "메모해 둔 작은 생각이\n다음 주에 큰 도움이 돼요",
        "회의가 일찍 끝나는 날이에요\n남은 시간은 온전히 내 것이에요",
        "어제보다 한 걸음만 가도\n충분히 잘하고 있는 거예요",
        "급한 일과 중요한 일이\n오늘은 같은 방향을 가리켜요",
        "정리한 책상 위에서\n새 아이디어가 자리를 잡아요",
        "모르는 것을 모른다고 말하면\n배움이 가장 빨리 와요",
        "오늘 끝낸 작은 일들이\n모여서 큰 그림이 돼요",
        "한 번에 하나씩만 해 보세요\n그게 오늘 가장 빠른 길이에요",
        "마감은 생각보다 넉넉해요\n차분하게 가도 닿아요",
        "처음 든 생각을 적어 두세요\n돌아보면 그게 맞았어요",
        "집중이 잘 되는 시간이 와요\n그때 가장 어려운 일을 꺼내요",
        "도움을 청하는 한마디가\n반나절을 아껴 줘요",
        "오늘 미리 해 둔 준비가\n내일 아침을 여유롭게 해요",
        "잘 쉰 사람이 잘 끝내요\n오늘은 제때 퇴근하는 날이에요",
        "계획이 조금 틀어져도 괜찮아요\n돌아간 길에 더 좋은 게 있어요",
        "자리에서 일어나 기지개를 켜면\n굳은 생각도 같이 펴져요",
        "점심을 천천히 먹은 날은\n오후가 길게 느껴지지 않아요",
        "창밖을 한 번 바라보세요\n눈이 쉬면 마음도 쉬어요",
        "깊게 세 번 숨을 쉬고 나면\n같은 일이 다르게 보여요",
        "오늘 밤은 일찍 잠들어 보세요\n내일의 내가 고마워해요",
        "따뜻한 차 한 잔을 들고 오면\n어려운 일도 순해져요",
        "어깨에 힘을 빼고 앉으면\n손끝이 더 가볍게 움직여요",
        "잠깐 눈을 붙이는 휴식이\n오후 전체를 살려요",
        "계단으로 한 층만 걸어 보세요\n몸이 깨면 머리도 깨요",
        "쉬는 것도 일의 한 부분이에요\n오늘은 마음껏 쉬어 가요",
        "좋아하는 노래 한 곡이\n오늘의 속도를 맞춰 줘요",
        "물을 자주 마신 날에는\n저녁까지 기운이 남아요",
        "화면에서 눈을 떼는 일 분이\n다음 한 시간을 맑게 해요",
        "오늘은 나에게 너그러운 날이에요\n작은 실수는 웃고 넘겨요",
        "간식 하나를 나눠 먹으면\n기운도 기분도 두 배가 돼요",
        "고맙다는 말을 먼저 건네면\n더 큰 고마움이 돌아와요",
        "오늘 들어 준 이야기 하나가\n누군가의 하루를 바꿔요",
        "옆자리의 조용한 팀원이\n오늘 가장 좋은 답을 알아요",
        "먼저 건넨 안부 인사가\n오래 가는 인연을 만들어요",
        "함께 고민한 문제는\n절반의 시간에 풀려요",
        "오늘 받은 도움은 잊지 마세요\n곧 갚을 기회가 와요",
        "칭찬을 아끼지 않는 날에는\n나에게도 칭찬이 쌓여요",
        "다른 생각을 가진 사람이\n오늘 가장 좋은 스승이에요",
        "웃으며 시작한 대화는\n좋은 결론으로 끝나요",
        "팀원의 작은 성공을 축하하면\n팀 전체가 한 뼘 자라요",
        "오래 연락 못 한 사람에게서\n반가운 소식이 와요",
        "나눈 지식은 줄지 않아요\n알려 준 만큼 더 알게 돼요",
        "믿고 맡긴 일은\n기대보다 잘 되어 돌아와요",
        "오늘의 점심 메뉴 선택이\n모두를 행복하게 해요",
        "누군가 내 이름을 떠올리며\n고마워하고 있어요",
        "기대하지 않은 곳에서\n오늘의 가장 좋은 일이 생겨요",
        "오늘 놓친 것은 아쉬워 마세요\n더 잘 맞는 것이 오고 있어요",
        "작은 행운이 줄지어 와요\n첫 번째는 이미 도착했어요",
        "오늘 고른 길이 맞는 길이에요\n망설이지 말고 걸어가요",
        "우연히 본 한 문장이\n오래 찾던 답이 돼요",
        "좋은 소식은 느리게 와요\n그래도 오늘 안에 도착해요",
        "오늘은 타이밍이 내 편이에요\n미루던 말을 꺼내 보세요",
        "심은 줄도 몰랐던 씨앗이\n오늘 조용히 싹을 틔워요",
        "문 하나가 닫힌 자리에서\n더 넓은 창이 열려요",
        "오늘 하루의 끝에는\n웃으며 돌아볼 일이 남아요",
    ] }
    var plazaFortuneActions: [String] { [
        "온천 들르기",
        "팀원에게 인사",
        "불꽃 한 발",
        "큰 나무 흔들기",
        "모닥불 옆에 앉기",
        "춤 한 곡",
        "연못에 풍덩",
        "풀숲에 숨기",
        "단체 사진",
        "점프 세 번",
        "하트 보내기",
        "광장 한 바퀴",
    ] }
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
    func plazaCampfireToggle(isLit: Bool) -> String { isLit ? "불 끄기" : "불 켜기" }
    func plazaMemberHint(nickname: String) -> String { "스페이스바를 눌러 \(nickname)에게 말 걸기" }
    /// While I am disguised as a teammate: who, and the time left (rounded up, never below 0:00).
    func plazaMimicHint(nickname: String, seconds: TimeInterval) -> String {
        let left = max(0, Int(seconds.rounded(.up)))
        return "\(KoreanParticle.direction.attach(to: nickname)) 변신 중 · \(left / 60):\(String(format: "%02d", left % 60))"
    }
    var plazaDivingHint: String { "잠수 중 · 물가 팀원을 바라보고 C로 끌어들이기" }
    func plazaPullHint(nickname: String) -> String { "C를 눌러 \(nickname) 물속으로 끌어들이기" }
    var plazaIceHint: String { "얼음 위예요 · Z로 얼음 깨기" }
    var plazaHiddenHint: String { "풀숲에 숨었어요 · 팀원이 옆에 오면 Z로 놀래키기" }
    func plazaStartleHint(nickname: String) -> String { "Z를 눌러 \(nickname) 놀래키기" }
    var plazaStartleManyHint: String { "Z를 눌러 옆에 있는 팀원 놀래키기" }
    var plazaMenuGreet: String { "인사하기" }
    var plazaMenuTackle: String { "몸통박치기" }
    var plazaMenuDrag: String { "끌어당기기" }
    var plazaJump: String { "점프 · 물놀이" }
    var plazaShortcutsTitle: String { "단축키" }
    func plazaShortcutThrow(_ season: PlazaSeason) -> String {
        switch season {
        case .spring: "꽃잎 뭉치"
        case .summer: "물풍선"
        case .autumn: "낙엽 뭉치"
        case .winter: "눈뭉치"
        }
    }
    var plazaShortcutArrows: String { "방향키" }
    var plazaShortcutWalk: String { "걷기" }
    var plazaShortcutRun: String { "달리기" }
    var plazaShortcutTalk: String { "말 걸기" }
    var plazaShortcutChat: String { "한마디" }
    var plazaShortcutEmotes: String { "말풍선" }
    var plazaShortcutZoom: String { "확대·축소" }
    var plazaShortcutFirework: String { "불꽃놀이" }
    var plazaShortcutDance: String { "춤" }
    var plazaShortcutPray: String { "기도(알)" }
    /// 기도한 직후 잠깐 보이는 횟수.
    func plazaPrayedHint(prayers: Int) -> String { "기도 \(prayers)번" }
    /// 오늘 셀 기도를 다 했을 때. 알일 때의 안내 줄이 이것으로 바뀐다.
    func plazaPrayDoneHint(prayers: Int) -> String { "오늘 기도는 다 했어요 (하루 \(PokemonBalance.prayersPerDay)번) · 기도 \(prayers)번" }
    /// 알일 때 위쪽 안내 줄. 아직 기도한 적이 없으면 방법만 보인다.
    func plazaPrayHint(prayers: Int) -> String {
        prayers > 0 ? "A를 눌러 기도하기 · 기도 \(prayers)번" : "A를 눌러 기도하기"
    }
    /// 광장에서 주운 아이템. 조사까지 붙인 목적어 꼴이다.
    func plazaItemObject(_ kind: ItemKind) -> String {
        switch kind {
        case .rareCandy: "이상한 사탕을"
        case .mint: "민트를"
        case .shinyCharm: "이로치 부적을"
        }
    }
    func plazaPickedUp(_ kind: ItemKind) -> String { "\(plazaItemObject(kind)) 주웠어요! 가방에 넣었어요" }
    /// 나무 세 번째 때림에서 떨어진 아이템을 가방에 넣었다(받은 것이라 주울 것이 남지 않으니 "주웠어요" 대신).
    func plazaTreeDropped(_ kind: ItemKind) -> String {
        let subject = switch kind {
        case .rareCandy: "이상한 사탕이"
        case .mint: "민트가"
        case .shinyCharm: "이로치 부적이"
        }
        return "나무에서 \(subject) 떨어졌어요! 가방에 넣었어요"
    }
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
    // 미니게임. 처음 하는 사람이 카드만 보고 바로 할 수 있게, 규칙은 세 줄로 초대 카드에 늘 같이 보인다.
    var plazaShortcutGame: String { "미니게임" }
    /// 안내판은 가장 작은 창에 꼭 맞는 줄 수라서, 미니게임 줄을 넣으며 사진 모드(P)와 단체 사진(G)을 한 줄로 합쳤다.
    var plazaShortcutPhotos: String { "사진 · 단체" }
    var plazaGameMenuTitle: String { "미니게임" }
    func plazaGameName(_ kind: PlazaGameKind) -> String {
        switch kind {
        case .bomb: "폭탄 돌리기"
        }
    }
    var plazaGameUnknownName: String { "새 미니게임" }
    func plazaGameRules(_ kind: PlazaGameKind) -> [String] {
        switch kind {
        case .bomb: ["폭탄을 들면 C(치기)나 V(던지기)로 넘겨요", "터질 때 들고 있으면 탈락!", "마지막 한 명이 이겨요 · 한 판 1~3분"]
        }
    }
    func plazaGameMenuRow(_ kind: PlazaGameKind) -> String { "\(plazaGameName(kind)) 열기" }
    var plazaGameMenuBusy: String { "지금 다른 판이 열려 있어요" }
    func plazaGameMenuWait(seconds: Int) -> String { "\(seconds)초 뒤에 판을 열 수 있어요" }
    var plazaGameMenuEgg: String { "알은 걸을 수 없어 판을 열 수 없어요" }
    var plazaGameMenuHowTo: String { "판을 열면 30초 동안 참가할 팀원을 모아요" }
    func plazaGameCardTitle(host: String?, game: String) -> String { host.map { "\($0)님의 \(game)" } ?? "내가 연 \(game)" }
    func plazaGameRecruiting(players: Int, seconds: Int) -> String { "참가 \(players)명 · \(seconds)초 뒤 시작" }
    func plazaGameNeedsTwo(seconds: Int) -> String { "두 명부터 시작돼요 · \(seconds)초 남음" }
    var plazaGameJoined: String { "참가했어요!" }
    var plazaGameEggNote: String { "알은 걸을 수 없어 구경만 해요" }
    var plazaGameUpdateNote: String { "앱을 업데이트하면 참가할 수 있어요" }
    /// 참가자 이름 줄. 셋까지 이름을 적고 나머지는 수로 줄인다.
    func plazaGamePlayers(_ names: [String]) -> String {
        let shown = names.prefix(3).joined(separator: ", ")
        return names.count > 3 ? "참가: \(shown) 외 \(names.count - 3)명" : "참가: \(shown)"
    }
    var plazaGameButtonJoin: String { "Y 참가" }
    var plazaGameButtonDecline: String { "N 안 함" }
    var plazaGameButtonLeave: String { "N 빠지기" }
    var plazaGameButtonStart: String { "M 바로 시작" }
    var plazaGameButtonCancel: String { "N 취소" }
    var plazaGameButtonClose: String { "N 닫기" }
    var plazaGameGo: String { "시작!" }
    var plazaGameNextBomb: String { "다음 폭탄!" }
    func plazaGameOut(nickname: String?) -> String { nickname.map { "\($0) 탈락!" } ?? "탈락!" }
    func plazaGameWin(nickname: String?) -> String { nickname.map { "\($0) 승리!" } ?? "승리!" }
    var plazaGameHoldHint: String { "💣 폭탄! C로 치거나 V로 맞혀 넘기세요" }
    func plazaGameNoReturnHint(nickname: String) -> String { "💣 \(nickname)님에겐 잠깐 뒤에 돌려줄 수 있어요" }
    var plazaGameWaterHint: String { "💣 물에서는 던질 수 없어요 · 뭍으로 나가 C나 V로 넘기세요" }
    var plazaGameScatterHint: String { "곧 폭탄이 나와요 · 서로 흩어지세요" }
    func plazaGameRunHint(nickname: String) -> String { "\(nickname)님이 폭탄을 들었어요 · 도망치세요!" }
    func plazaGameOutHint(left: Int) -> String { "탈락 · 남은 \(left)명을 구경해요" }
    var plazaGameNoDive: String { "미니게임 중에는 잠수할 수 없어요" }
    func plazaGameStartedBanner(game: String, players: Int) -> String { "\(game) 시작 · \(players)명" }
    func plazaGameOutBanner(nickname: String) -> String { "💥 \(nickname)님 탈락!" }
    func plazaGameWinBanner(nickname: String, game: String) -> String { "🏆 \(nickname)님이 \(game)에서 이겼어요!" }
    func plazaGameOverBanner(game: String) -> String { "\(game) 판이 끝났어요" }
    /// `closed`: 판을 연 사람이 접었다. 아니면 모집이 끝났는데 참가자가 모자랐다.
    func plazaGameCancelledBanner(game: String, closed: Bool) -> String {
        closed ? "\(game) 판이 취소됐어요" : "참가자가 모자라 \(game) 판이 취소됐어요"
    }
    func plazaGameLeftBanner(nickname: String) -> String { "\(nickname)님이 판에서 나갔어요" }
    var plazaGameLostConnectionBanner: String { "팀원과 연결이 끊겨 판에서 빠졌어요" }
    func teamGameInviteNotice(nickname: String, game: String) -> String { "💣 \(nickname)님이 \(game) 판을 열었어요. 광장에서 Y를 눌러 참가하세요" }
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
    var plazaActivityTime: String { "접속시간" }
    var plazaActivityIceBreaks: String { "얼음 깬 횟수" }
    var plazaActivityFireworks: String { "폭죽" }
    var plazaActivityTackles: String { "몸통박치기" }
    var plazaActivitySnowballHits: String { "던져서 맞힌 횟수" }
    var plazaActivityGreetings: String { "인사" }
    var plazaActivityPickups: String { "주운 아이템" }
    var plazaActivityNone: String { "기록 없음" }
    var plazaCardActivityTitle: String { "오늘 광장" }
    func plazaActivityDuration(hours: Int, minutes: Int) -> String { hours > 0 ? "\(hours)시간 \(minutes)분" : "\(minutes)분" }
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
        case .pray: "기도"
        case .drag: "끌어당기기"
        case .treeShake: "나무 흔들기"
        case .fortune: "포춘쿠키"
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
