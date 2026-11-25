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
        "오래 바라던 일이 곧 이루어져요",
        "귀한 인연이 가까이 와 있어요",
        "좋은 기회가 문을 두드려요",
        "뜻밖의 곳에서 도움이 와요",
        "오늘은 천천히 가도 괜찮아요",
        "뜻밖의 칭찬이 찾아올 거예요",
        "오랜 고민이 스르르 풀려요",
        "당신의 노력이 곧 열매를 맺어요",
        "멀리서 좋은 소식이 오고 있어요",
        "새로운 길이 눈앞에 열려요",
        "마음먹은 일이 뜻대로 풀려요",
        "행운이 당신 쪽으로 오고 있어요",
        "머지않아 큰 박수를 받게 돼요",
        "당신의 진심이 곧 전해져요",
        "좋은 변화가 이미 시작됐어요",
        "오늘 밤 좋은 꿈을 꾸게 돼요",
        "즐거운 여행이 당신을 기다려요",
        "기쁜 초대를 받게 될 거예요",
        "좋은 사람이 당신 곁에 머물러요",
        "기분 좋은 우연이 찾아와요",
        "당신의 때가 다가오고 있어요",
        "따뜻한 말 한마디를 듣게 돼요",
        "꿈꾸던 일에 한 걸음 다가서요",
        "작은 기적이 오늘 일어나요",
        "작은 친절이 크게 돌아와요",
        "당신 편이 한 명 더 생겨요",
        "귀한 손님이 찾아올 거예요",
        "마음 맞는 벗을 만나게 돼요",
        "행운의 여신이 당신에게 미소 지어요",
        "복이 제 발로 찾아오는 날이에요",
        "근심은 줄고 웃음은 늘어요",
        "길한 기운이 당신을 감싸요",
        "호박이 넝쿨째 굴러들어와요",
        "꿩 먹고 알 먹는 일이 생겨요",
        "누이 좋고 매부 좋은 일이 생겨요",
        "경사가 겹치는 날이에요",
        "만사가 술술 풀리는 날이에요",
        "동쪽에서 귀인이 찾아와요",
        "남쪽에서 기쁜 소식이 날아와요",
        "지갑이 두둑해질 운이에요",
        "횡재수가 있는 날이에요",
        "설레는 일이 곧 찾아와요",
        "고마운 마음을 전해 보세요",
        "누군가 당신을 좋게 보고 있어요",
        "몸도 마음도 가뿐한 날이에요",
        "웃음소리가 끊이지 않는 날이에요",
        "손대는 것마다 잘 풀려요",
        "올해 가장 크게 웃을 날이 와요",
        "오래 간직할 순간이 찾아와요",
        "고대하던 날이 성큼 다가와요",
        "이름 석 자가 좋게 알려져요",
        "근사한 제안을 받게 될 거예요",
        "웃으며 손뼉 칠 일이 생겨요",
        "발 닿는 곳마다 꽃길이에요",
        "돼지꿈 같은 행운이 찾아와요",
        "잔칫날 같은 하루가 와요",
        "묵혀 둔 행운을 꺼내 쓰는 날이에요",
        "오늘의 운세는 대길이에요",
        "오래 찾던 것을 가까이에서 찾아요",
        "마음 가는 대로 해도 좋아요",
        "맛있는 것을 대접받는 날이에요",
        "한턱낼 만큼 좋은 일이 생겨요",
        "어깨춤이 절로 나는 날이에요",
        "입꼬리가 내려올 틈이 없어요",
        "조용한 응원이 곁에 있어요",
        "콧노래가 나오는 하루예요",
        "반가운 연락이 올 거예요",
        "좋은 사람과 좋은 시간을 보내요",
        "오래 남을 사진을 찍게 돼요",
        "당신은 곁에 두고 싶은 사람이에요",
        "당신의 미소가 주변을 밝혀요",
        "당신은 생각보다 훨씬 강해요",
        "당신의 따뜻함을 모두가 알아요",
        "당신은 많은 사람에게 사랑받아요",
        "당신은 누군가의 자랑이에요",
        "당신의 용기가 길을 열어요",
        "당신은 믿음직한 사람이에요",
        "답은 이미 당신 안에 있어요",
        "당신의 친절은 잊히지 않아요",
        "당신은 복을 나누는 사람이에요",
        "당신의 진가가 곧 드러나요",
        "당신을 믿는 사람이 많아요",
        "당신의 말에는 온기가 있어요",
        "당신은 누군가의 좋은 기억이에요",
        "당신 덕분에 웃는 사람이 있어요",
        "따뜻한 눈길이 당신을 향해요",
        "사람을 끄는 매력이 있어요",
        "어디에 있어도 당신은 빛나요",
        "눈빛에 총기가 가득해요",
        "인복이 많은 사람이에요",
        "말 한마디에 덕이 묻어나요",
        "당신은 크게 될 사람이에요",
        "볼수록 정이 가는 사람이에요",
        "얼굴에 좋은 기운이 가득해요",
        "당신의 안목은 틀리는 법이 없어요",
        "나란히 걸으면 길이 짧아져요",
        "하늘이 아끼는 사람이에요",
        "오늘의 주인공은 당신이에요",
        "당신 곁에서는 시간이 빨리 가요",
        "당신이 오면 분위기가 살아나요",
        "당신 손을 거치면 뭐든 좋아져요",
        "천 리 길도 한 걸음부터예요",
        "웃으면 복이 와요",
        "고생 끝에 낙이 와요",
        "뜻이 있는 곳에 길이 있어요",
        "시작이 반이에요",
        "급할수록 돌아가요",
        "하늘은 스스로 돕는 자를 도와요",
        "가는 말이 고와야 오는 말이 고와요",
        "티끌 모아 태산이에요",
        "비 온 뒤에 땅이 굳어요",
        "지성이면 감천이에요",
        "백지장도 맞들면 나아요",
        "공든 탑은 무너지지 않아요",
        "말 한마디로 천 냥 빚을 갚아요",
        "낙숫물이 댓돌을 뚫어요",
        "뿌리 깊은 나무는 흔들리지 않아요",
        "금강산도 식후경이에요",
        "될성부른 나무는 떡잎부터 알아봐요",
        "정들면 어디나 고향이에요",
        "아는 것이 힘이에요",
        "한 번 웃으면 한 번 젊어져요",
        "두드리는 문은 열려요",
        "느릿느릿 걸어도 황소걸음이에요",
        "꿈은 이루어져요",
        "좋은 벗은 천금보다 귀해요",
        "큰 나무도 작은 씨앗이었어요",
        "감사하는 마음에 복이 깃들어요",
        "배움에는 늦은 때가 없어요",
        "멀리 가려면 함께 가요",
        "바람이 불어야 연이 높이 날아요",
        "주는 기쁨이 받는 기쁨보다 커요",
        "작은 기쁨이 모여 큰 행복이 돼요",
        "열린 마음에 좋은 일이 들어와요",
        "강물은 돌을 만나도 길을 찾아요",
        "사랑은 표현할수록 깊어져요",
        "겨울이 깊을수록 봄이 가까워요",
        "자신을 믿어도 좋은 날이에요",
        "오늘의 직감을 믿어 보세요",
        "보고 싶은 사람에게 연락해 보세요",
        "좋은 것은 좋다고 말해 주세요",
        "행운을 만나면 꼭 나눠 주세요",
        "오늘의 인연을 소중히 하세요",
        "지금이 바로 나설 때예요",
        "깜짝 놀랄 만큼 좋은 일이 와요",
        "행운이 어깨를 톡톡 두드려요",
        "달력에 동그라미 칠 날이 생겨요",
        "기쁜 일로 전화기가 바빠져요",
        "당신의 목소리는 사람을 편하게 해요",
        "마음씨가 고와 복을 받아요",
        "굴러온 복은 꼭 붙잡으세요",
        "애정운이 활짝 피는 날이에요",
        "사람이 따르는 운이 들어와요",
        "운수대통의 기운이 감돌아요",
        "오늘은 유난히 운이 좋아요",
        "좋은 징조가 눈앞에 나타나요",
        "뜻을 함께할 사람을 만나요",
        "길에서 행운을 줍는 날이에요",
        "붉은색이 행운을 부르는 날이에요",
        "두 손 가득 좋은 것을 들게 돼요",
        "좋은 사람들 속에서 크게 웃어요",
        "마음에 쏙 드는 것을 만나요",
        "생각지 못한 덤이 따라와요",
        "뭘 골라도 당첨인 날이에요",
        "가위바위보도 이기는 날이에요",
        "좋은 벗이 좋은 소식을 들고 와요",
        "행운이 당신 이름을 외우고 있어요",
        "행운이 길을 잃지 않고 찾아와요",
        "배꼽 잡고 웃을 일이 생겨요",
        "좋은 사람이 먼저 손을 내밀어요",
        "주사위를 던지면 좋은 숫자가 나와요",
        "무지개를 보게 될 운이에요",
        "행운의 열쇠는 당신 손에 있어요",
        "오늘은 무엇을 심어도 잘 자라요",
        "당신의 별이 유난히 밝은 날이에요",
        "잔잔한 기쁨이 하루를 채워요",
        "오늘은 말이 잘 통하는 날이에요",
        "좋은 것만 눈에 들어오는 날이에요",
        "누구를 만나도 반가운 날이에요",
        "행운이 당신 뒤를 졸졸 따라다녀요",
        "마음이 봄날처럼 포근해져요",
        "반짝이는 생각이 떠오르는 날이에요",
        "손금에 좋은 길이 나 있어요",
        "당신은 운을 타고난 사람이에요",
        "당신의 한마디에 힘이 실려요",
        "작은 행운이 주머니에 들어와요",
        "아이와 동물이 따르는 사람이에요",
        "당신이 지나간 자리는 따뜻해요",
        "당신 이름에는 좋은 기운이 있어요",
        "당신의 인사는 하루를 환하게 해요",
        "기대하지 않은 선물이 와요",
        "좋은 예감이 그대로 맞아요",
        "하고 싶던 말을 하게 돼요",
        "인내는 쓰지만 그 열매는 달아요",
        "새로 시작하기 좋은 날이에요",
        "망설이던 일에 용기가 나요",
        "날마다 좋은 날이에요",
        "지나고 보면 잘한 선택이에요",
        "끝이 좋으면 다 좋아요",
        "지금 이 순간도 충분히 좋아요",
        // 201번째부터는 두 줄 운세다. \n 이 쪽지의 줄바꿈이다.
        "기대하지 않은 곳에서\n오늘 가장 좋은 일이 생겨요",
        "지금 걷는 길 끝에는\n바라던 풍경이 기다려요",
        "우연히 스친 만남이\n오래가는 인연이 돼요",
        "좋은 일은 늦는 법이 없어요\n꼭 맞는 때에 도착해요",
        "당신이 걱정하는 그 일은\n생각보다 훨씬 잘 풀려요",
        "행운은 준비된 사람을 찾아요\n당신은 이미 준비됐어요",
        "올해가 가기 전에\n소원 하나가 꼭 이루어져요",
        "멀리 돌아온 것 같아도\n그것이 가장 빠른 길이었어요",
        "낯선 곳에서 만난 사람이\n뜻밖의 행운을 건네줘요",
        "오늘 밤 하늘의 별 하나는\n당신의 소원을 듣고 있어요",
        "조금 늦게 피는 꽃이\n더 오래 향기로워요",
        "당신이 건넨 따뜻한 말은\n오래도록 누군가를 지켜 줘요",
        "한 걸음 내디딜 용기만 있으면\n나머지 길은 저절로 열려요",
        "당신은 스스로 아는 것보다\n훨씬 더 많은 것을 해냈어요",
        "큰 행복은 요란하지 않아요\n조용히 곁에 와 앉아요",
        "오늘 누군가는\n당신을 만난 것을 고마워해요",
        "바라는 것을 또렷이 그려 보세요\n그린 만큼 가까워져요",
        "당신의 정직함은\n어디서나 믿음으로 돌아와요",
        "가장 좋은 날은\n아직 달력에 남아 있어요",
        "새 친구 한 명이\n당신의 세상을 넓혀 줘요",
        "오늘 내미는 손을\n누군가 꼭 잡아 줄 거예요",
        "당신이 가는 곳마다\n좋은 사람들이 모여들어요",
        "한 번 더 해 보려는 마음이\n당신을 끝까지 데려다줘요",
        "잃어버린 줄 알았던 기회가\n다른 모습으로 돌아와요",
        "기쁜 일은 혼자 오지 않아요\n좋은 일 하나가 더 따라와요",
        "좋은 벗과 나눈 시간은\n세월이 지나도 빛나요",
        "당신의 다정함은\n돌고 돌아 당신에게 와요",
        "오늘의 작은 용기가\n내일의 큰 자랑이 돼요",
        "기다림이 길었던 만큼\n기쁨도 오래 머물러요",
        "당신의 눈이 머문 곳에\n오늘의 행운이 숨어 있어요",
        "당신이 아끼는 사람들도\n당신을 그만큼 아껴요",
        "조용히 쌓아 온 것들이\n어느 날 한꺼번에 빛나요",
        "당신이 믿어 준 사람이\n그 믿음에 꼭 답해요",
        "오늘 품은 고운 마음이\n하루를 곱게 물들여요",
        "잠시 구름이 끼어도\n당신의 하늘은 곧 개어요",
        "사랑받고 있다는 사실을\n오늘 다시 알게 돼요",
        "좋은 날을 기다리지 마세요\n오늘이 바로 그날이에요",
        "작은 것에 기뻐하는 당신에게\n더 큰 기쁨이 찾아와요",
        "오랜 친구와 웃게 될 거예요\n옛이야기가 새 힘이 돼요",
        "꿈은 달아나지 않아요\n당신이 다가가는 만큼 가까워져요",
        "오늘은 받는 날이에요\n건네는 호의를 기쁘게 받으세요",
        "올해의 당신은\n작년의 당신이 바라던 사람이에요",
        "좋은 소문이 당신을 앞질러 가요\n가는 곳마다 환영받아요",
        "당신이 고른 사람들은\n당신을 실망시키지 않아요",
        "이 쪽지를 읽은 순간부터\n운이 좋아지기 시작했어요",
        "행운이 당신을 찾고 있어요\n크게 손을 흔들어 주세요",
        "행운은 수줍음이 많아요\n먼저 웃어 주면 다가와요",
        "좋은 일이 오는 중이에요\n늦는 건 선물을 고르느라 그래요",
        "귀가 가렵다면\n누가 당신을 칭찬하는 중이에요",
        "고기는 씹어야 맛이고\n말은 해야 맛이에요",
        "옷은 새 옷이 좋고\n사람은 옛사람이 좋아요",
        "기쁨은 나누면 두 배가 되고\n걱정은 나누면 반이 돼요",
        "까치가 우는 아침에는\n반가운 손님이 찾아와요",
        "당신의 행운은 지금\n신발 끈을 묶고 있어요",
        "돈이 들어올 운이에요\n들어온 김에 좋은 데 쓰세요",
        "사랑은 가까운 곳에 있어요\n고개만 돌리면 보여요",
        "설레는 만남이 다가와요\n평소보다 조금 더 웃어 두세요",
        "열 사람보다\n당신의 마음이 답을 더 잘 알아요",
        "복은 기다리는 것이 아니라\n짓는 것이에요",
        "세상에서 가장 좋은 약은\n좋은 사람과 웃는 시간이에요",
        "행운의 숫자는\n오늘 처음 눈에 띄는 숫자예요",
        "오늘의 귀인은\n당신에게 먼저 웃어 주는 사람이에요",
        "가만히 있어도 복이 오는 날이에요\n그래도 한 번 웃어 주세요",
        "곧 축하받을 일이 생겨요\n축하는 넉넉히 받아 두세요",
        "당신이 심은 나무 그늘에서\n훗날 여러 사람이 쉬어요",
        "만날 사람은 꼭 만나게 돼요\n좋은 인연이 오고 있어요",
        "당신의 한 해는\n끝으로 갈수록 좋아져요",
        "지금 하려는 그 일은\n하늘이 돕는 일이에요",
        "김칫국을 마셔도 좋아요\n떡 줄 사람이 오고 있어요",
        "한 사람의 진심 어린 응원이\n당신에게 닿는 날이에요",
        "소원은 말하는 순간부터\n이루어질 준비를 해요",
        "운명은 용기 있는 사람 편이에요\n오늘은 당신 편이에요",
        "착한 일을 쌓은 집에는\n반드시 기쁜 일이 찾아와요",
        "내일 걱정은 내일에 맡기고\n오늘의 기쁨은 오늘 누려요",
        "가장 큰 행운은\n좋은 사람을 곁에 두는 일이에요",
        "오늘 입은 옷이\n행운을 부르는 옷이에요",
        "큰돈보다 귀한 것이\n곧 당신 손에 들어와요",
        "돈보다 사람이 남는 해예요\n둘 다 남으면 더 좋고요",
        "당신 차례가 오고 있어요\n줄은 생각보다 짧아요",
        "복 받을 일을 했으니\n복 받을 일만 남았어요",
        "웃을 준비를 해 두세요\n재미있는 일이 오고 있어요",
        "오늘의 행운은 왼쪽 주머니에\n내일의 행운은 오른쪽에 있어요",
        "좋은 일은 예고 없이 와요\n그래서 더 반가운 법이에요",
        "먼저 인사하는 사람에게\n복이 먼저 인사해요",
        "이 쿠키의 운세는 진짜예요\n쿠키가 직접 보증해요",
        "오래 연락 못 한 사람에게서\n반가운 소식이 와요",
        "이 쿠키는 딱 한 사람을 위해\n오늘 구워졌어요",
        "쿠키는 부서져도 괜찮아요\n행운은 통째로 남았어요",
        "좋은 일이 생기려는지\n괜히 기분이 좋아지는 날이에요",
        "오늘 받는 인사 가운데 하나는\n행운이 건네는 인사예요",
        "길모퉁이를 돌면\n반가운 얼굴이 기다리고 있어요",
        "바람이 등을 밀어 주는 날이에요\n어디로 가든 수월해요",
        "작은 행운이 줄지어 와요\n첫 번째는 이미 도착했어요",
        "먼 훗날 오늘을 떠올리며\n참 좋은 날이었다고 말해요",
        "우연히 본 한 문장이\n오래 찾던 답이 돼요",
        "행운에게도 취향이 있어요\n당신 같은 사람을 좋아해요",
        "좋은 사람을 알아보는 눈은\n좋은 사람에게만 있어요",
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
        case .spring: "분홍 꽃"
        case .summer: "풍선"
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
    var plazaShortcutDanceFirework: String { "춤 · 불꽃" }
    var plazaShortcutPray: String { "기도(알)" }
    /// 오늘의 기도 부화를 이미 썼을 때 알의 안내 줄 앞에 붙는 말. 기도 자체는 그대로 된다.
    var plazaPrayerHatchUsedHint: String { "오늘은 기도로 이미 부화시켰어요 · 내일 다시 기도로 부화할 수 있어요" }
    /// 기도한 직후 잠깐 보이는 횟수.
    func plazaPrayedHint(prayers: Int, hatchUsed: Bool = false) -> String {
        hatchUsed ? plazaPrayerHatchUsedHint + " · 기도 \(prayers)번" : "기도 \(prayers)번"
    }
    /// 알일 때 위쪽 안내 줄. 아직 기도한 적이 없으면 방법만 보인다.
    func plazaPrayHint(prayers: Int, hatchUsed: Bool = false) -> String {
        let how = hatchUsed ? "A를 눌러 기도하기 · " + plazaPrayerHatchUsedHint : "A를 눌러 기도하기"
        return prayers > 0 ? how + " · 기도 \(prayers)번" : how
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
        case .draw: "그림 퀴즈"
        case .berry: "열매 다섯"
        }
    }
    var plazaGameUnknownName: String { "새 미니게임" }
    func plazaGameRules(_ kind: PlazaGameKind) -> [String] {
        switch kind {
        case .bomb: ["폭탄은 몸통박치기(C)로 넘길 수 있어요", "터질 때 들고 있으면 탈락!", "마지막 한 명이 이겨요 · 한 판 1~3분"]
        case .draw: ["돌아가며 한 명씩 제시어를 정해 그림으로 그려요", "나머지는 한마디(Enter)로 맞혀요 · 맞히면 +10점, 그린 사람 +5점", "그림에 글자·숫자로 정답을 쓰면 반칙! · 한 판 5~12분"]
        case .berry: ["같은 열매가 딱 5개면 스페이스로 종을 쳐요", "가장 빨리 치면 +1, 잘못 치면 −1이고 1초 쉬어요", "먼저 5점이면 우승 · 한 판 1~2분"]
        }
    }
    func plazaGameMenuRow(_ kind: PlazaGameKind) -> String { "\(plazaGameName(kind)) 열기" }
    var plazaGameMenuBusy: String { "지금 다른 판이 열려 있어요" }
    func plazaGameMenuWait(seconds: Int) -> String { "\(seconds)초 뒤에 판을 열 수 있어요" }
    var plazaGameMenuEgg: String { "알은 걸을 수 없어 판을 열 수 없어요" }
    var plazaGameMenuHowTo: String { "판을 열면 30초 동안 참가할 팀원을 모아요" }
    // Berry five's table: the head, the rule, the bell's stand-in word, the wrong-bell marks and the VoiceOver label of a seat.
    var plazaBerryHead: String { "열매 다섯 · 먼저 5점" }
    var plazaBerryRule: String { "같은 열매가 딱 5개면 스페이스!" }
    var plazaBerryBellFallback: String { "종" }
    var plazaBerryWrongMark: String { "✕" }
    var plazaBerryWrongRest: String { "1초 쉬기" }
    var plazaBerryBellMark: String { "🔔" }
    func plazaBerrySeatLabel(name: String, score: Int) -> String { "\(name) \(score)점" }
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
    // The drawing quiz panel: its tool buttons, the word's label and the pen colours' names (VoiceOver reads them).
    var plazaDrawToolThinPen: String { "가는 펜" }
    var plazaDrawToolThickPen: String { "굵은 펜" }
    var plazaDrawToolEraser: String { "지우개" }
    var plazaDrawToolClear: String { "모두 지우기" }
    var plazaDrawWord: String { "제시어" }
    func plazaDrawColorName(_ index: Int) -> String {
        ["", "검정", "빨강", "주황", "노랑", "초록", "파랑", "보라", "갈색"][min(max(index, 0), 8)]
    }
    // The drawing quiz while it runs. Every line is read on its own by a first-time player, so each says what to do or what happened.
    /// The board's head line. The drawer's own board names no drawer (it is me).
    func plazaDrawHead(turn: Int, of total: Int, drawer: String?) -> String {
        "차례 \(turn)/\(total) · " + (drawer.map { "그리는 사람 \($0)" } ?? "내가 그려요")
    }
    func plazaDrawTime(seconds: Int) -> String { "⏱ \(seconds)" }
    func plazaDrawMyEntry(seconds: Int) -> String { "내 차례! 아래에 제시어를 쓰고 Enter · \(seconds)초" }
    func plazaDrawOtherEntry(nickname: String, seconds: Int) -> String { "\(nickname)님이 제시어를 정하고 있어요 · \(seconds)초" }
    var plazaDrawMyDrawing: String { "글자 없이 그림으로만 그리세요" }
    var plazaDrawOtherDrawing: String { "Enter로 정답을 말해요" }
    func plazaDrawHintLater(seconds: Int) -> String { "힌트는 \(seconds)초가 남으면 나와요" }
    func plazaDrawHintLetters(_ count: Int) -> String { "힌트 " + String(repeating: "□", count: count) + " · \(count)글자" }
    func plazaDrawHintInitials(_ initials: String) -> String { "힌트 \(initials)" }
    func plazaDrawResultSolved(word: String, solver: String) -> String { "정답은 \(word) · \(solver)님이 맞혔어요" }
    func plazaDrawResultPoints(solver: String, solverPoints: Int, drawer: String, drawerPoints: Int) -> String {
        "\(solver) +\(solverPoints)점 · \(drawer) +\(drawerPoints)점"
    }
    func plazaDrawResultTimeout(word: String) -> String { "정답은 \(word) · 아무도 못 맞혔어요" }
    var plazaDrawResultNoPoints: String { "이번 차례는 점수가 없어요" }
    var plazaDrawResultUnknown: String { "이번 차례는 건너뛰었어요" }
    /// Over the empty canvas between turns; `nickname` nil is me.
    func plazaDrawNext(nickname: String?, seconds: Int) -> String {
        nickname.map { "다음은 \($0)님 차례 · \(seconds)초" } ?? "다음은 내 차례 · \(seconds)초"
    }
    /// The name line while the quiz runs. A teammate who is not playing is told what is going on; a player sees the scores only.
    func plazaDrawStatus(scores: [(name: String, score: Int)], watching: Bool) -> String {
        let list = scores.map { "\($0.name) \($0.score)" }.joined(separator: " · ")
        return watching ? "그림 퀴즈 진행 중 · \(list)" : list
    }
    var plazaDrawRankingTitle: String { "그림 퀴즈 결과" }
    func plazaDrawRankLine(rank: Int, name: String, score: Int, tied: Bool) -> String { "\(tied ? "공동 " : "")\(rank)등 \(name) \(score)점" }
    func plazaDrawRecruiting(players: Int, seconds: Int) -> String { "참가 \(players)/\(PlazaDraw.maxPlayers)명 · \(seconds)초 뒤 시작" }
    var plazaDrawFull: String { "자리가 찼어요" }
    var plazaDrawWordInvalid: String { "제시어는 글자나 숫자 1~12자로 써 주세요" }
    var plazaDrawOwnWordBlocked: String { "제시어가 들어 있는 말은 보낼 수 없어요" }
    var plazaDrawRight: String { "정답!" }
    /// What everyone but the solver reads when a turn is solved.
    func plazaDrawRightBy(nickname: String) -> String { "\(nickname)님 정답!" }
    var plazaDrawTimeUp: String { "시간 초과" }
    var plazaGameButtonCancel: String { "N 취소" }
    var plazaGameButtonClose: String { "N 닫기" }
    var plazaGameGo: String { "시작!" }
    var plazaGameNextBomb: String { "다음 폭탄!" }
    func plazaGameOut(nickname: String?) -> String { nickname.map { "\($0) 탈락!" } ?? "탈락!" }
    func plazaGameWin(nickname: String?) -> String { nickname.map { "\($0) 승리!" } ?? "승리!" }
    var plazaGameHoldHint: String { "💣 폭탄! 몸통박치기(C)로 넘기세요" }
    func plazaGameNoReturnHint(nickname: String) -> String { "💣 \(nickname)님에겐 잠깐 뒤에 돌려줄 수 있어요" }
    /// 판이 도는 동안 안내 줄 아래에 늘 보이는 명단. 폭탄을 든 사람 이름 앞에는 💣가 붙는다.
    func plazaGameStatus(alive: [String], out: [String], holder: String?) -> String {
        let names = alive.map { $0 == holder ? "💣\($0)" : $0 }.joined(separator: " · ")
        let left = "남은 \(alive.count)명 \(names)"
        return out.isEmpty ? left : "\(left)  |  탈락 \(out.joined(separator: " · "))"
    }
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
    var plazaDrawWordPlaceholder: String { "제시어 (12자까지)" }
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
    /// The background toggle's label is its current mode: it cycles shown, UI hidden, background hidden, both hidden.
    var plazaModeShown: String { "모두 표시" }
    var plazaModeUIHidden: String { "UI 숨기기" }
    var plazaModeBackgroundHidden: String { "배경 숨기기" }
    var plazaModeBothHidden: String { "UI·배경 숨기기" }
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
