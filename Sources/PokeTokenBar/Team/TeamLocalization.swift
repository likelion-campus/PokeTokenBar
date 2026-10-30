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
    var plazaOpen: String { "광장 열기" }
    var plazaWindowTitle: String { "팀 광장" }
}
