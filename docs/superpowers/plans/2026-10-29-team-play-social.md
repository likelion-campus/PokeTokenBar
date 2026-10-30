# 팀 놀이 1부 (소식·반응·구경) Implementation Plan

> **대체됨 (2026-10-30):** 이 계획으로는 Task 1–6까지만 진행했다. 설계가
> [팀 광장 설계](../specs/2026-10-30-team-plaza-design.md)로 바뀌어 Task 7–15는 새 계획으로 대체된다.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 같은 와이파이의 팀원끼리 서버 없이 포켓몬 소식을 주고받고, 반응하고, 서로의 도감을 구경하는
기능을 팀용 포크에 넣고 첫 팀 릴리스까지 낸다.

**Architecture:** 팀 기능은 `Sources/PokeTokenBar/Team/`에 모은다. Bonjour(`_ptbteam._tcp`)로 팀원을
찾고, 팀 코드에서 유도한 TLS-PSK로 연결한다. 메시지는 길이 접두 JSON 프레임으로 주고받는다.
`TeamSession`이 소식 발행, 동기화(인벤토리 교환), 반응, 프로필 요청을 조율한다. 기존 파일에는 연결
지점만 둔다: `CompanionStore` 이벤트 훅, 팝오버 탭, 설정 섹션, 플로팅 펫 위치, 앱 배선.

**Tech Stack:** Swift 6, SwiftUI/AppKit, Network.framework (NWListener/NWBrowser/NWConnection),
CryptoKit, UserNotifications, XCTest.

**Spec:** `docs/superpowers/specs/2026-10-29-team-play-design.md`

**범위:** 스펙의 4.1~4.5, 5장, 6장, 8장. **4.6 포켓몬 교환은 이 계획에 없다.** 교환은 이 계획의
연결 계층 위에 얹는다. 그래서 Task 1의 연결 확인 결과와 실제 `TeamSession` 인터페이스를 보고 나서
2부 계획(`docs/superpowers/plans/…-team-play-trade.md`)으로 따로 쓴다.

## Global Constraints

- 팀 기능은 기본 꺼짐. 꺼져 있으면 광고도, 연결도, 이벤트 생성도 하지 않는다.
- 팀에 나가는 어떤 메시지·화면에도 토큰·비용·한도·성장 진행률 숫자를 담지 않는다.
- Bonjour 서비스 타입은 `_ptbteam._tcp`이다. 인스턴스 이름은 실행마다 무작위로 만들고, 닉네임·팀·기기
  이름을 넣지 않는다.
- 팀 코드는 앱이 만든 128비트 무작위 값이다. 오가는 내용은 팀 코드에서 유도한 PSK로 TLS 암호화한다.
- 팀원이 한 명도 연결돼 있지 않을 때 생긴 소식은 날짜만 싣는다(`occurredAt == nil`). 놀러 오기·알림
  없이 팀 탭에만 쌓인다.
- 번들 ID `io.github.chattymin.poketokenbar`와 세이브 경로(`AppStatePaths`)를 바꾸지 않는다.
- 팀 데이터는 `team-feed.json`으로 세이브(`companion-state.json`)와 분리한다.
- 팀 UI 문구는 한국어만 쓰고 전부 `Sources/PokeTokenBar/Team/TeamLocalization.swift`의 `extension L`에
  둔다. 뷰 파일에 한글 문자열 리터럴을 두지 않는다(`LocalizedUILiteralTests` 취지).
- 팀 코드는 `Sources/PokeTokenBar/Team/`(뷰는 `Team/UI/`)에 둔다. 기존 파일 수정은 각 Task가 명시한
  연결 지점만 한다.
- 커밋 메시지는 영어로 쓴다(저장소 `CLAUDE.md`).
- 개발 중에는 `scripts/build-app.sh`를 실행하지 않는다. 이 스크립트는 `/Applications`의 앱을 덮어쓴다.
  확인은 `swift build`, `swift test`, `PTB_STATE_DIR=<임시폴더> swift run PokeTokenBar`로 한다.
- 팀 버전 번호는 `MAJOR.MINOR.(원작PATCH×100+팀빌드번호)`이다. 첫 릴리스는 `2.5.601`이다.
  (`UpdateChecker.normalizedReleaseVersion`이 세 자리 숫자 버전만 받는다.)

## Review Focus

1. **잠자기·와이파이 전환 후 재연결:** 노트북을 덮었다 열거나 집↔사무실을 오가도 팀원이 자동으로 다시
   보이고, 소식이 중복 없이 채워져야 한다. → Task 8 `testReconnectResyncsWithoutDuplicates`.
2. **같은 소식이 여러 경로로 도착:** 라이브 전송과 동기화 응답, 여러 팀원의 동기화 응답으로 같은 소식이
   여러 번 와도 피드 행·놀러 오기·말풍선은 한 번만이어야 한다. → Task 8
   `testDuplicateEventFromTwoPeersVisitsOnce`.
3. **Mac 사이 시계 차이:** 한 팀원의 시계가 틀려도 놀러 오기 여부가 흔들리면 안 되고, 미래 시각은
   "방금"으로 보여야 한다. → 놀러 오기는 시각이 아니라 `live` 플래그로 판단(Task 6, 8). 표시는 Task 10
   `testRelativeLabelClampsFutureToJustNow`.
4. **망가진 `team-feed.json`:** 팀 파일이 깨져도 앱이 뜨고, 세이브는 건드리지 않고, 피드는 빈 상태로
   시작해야 한다. → Task 5 `testCorruptFileStartsEmptyAndKeepsBackup`.
5. **버전이 다른 팀원:** 프로토콜 버전이 다른 팀원이 있어도 크래시나 무한 재연결 없이 "다른 버전"으로
   표시돼야 한다. → Task 8 `testProtocolMismatchMarksIncompatibleAndDisconnects`.

---

### Task 1: 사무실 와이파이 연결 확인 (중단 게이트)

**Files:**
- Create: `scripts/team-probe.swift`

**Interfaces:**
- Produces: `swift scripts/team-probe.swift serve <code>` / `swift scripts/team-probe.swift browse <code>`.
  이 스크립트는 나중에 팀원 연결 문제를 진단할 때도 쓴다.

- [ ] **Step 1: 프로브 스크립트 작성**

  Network.framework와 CryptoKit만 쓰는 단일 파일 스크립트다. 앱 코드에 의존하지 않는다.
  - `serve <code>`: 무작위 인스턴스 이름으로 `_ptbteam._tcp`를 광고하는 `NWListener`를 띄운다.
    받은 줄을 출력하고 `pong <받은 줄>`로 응답한다.
  - `browse <code>`: `NWBrowser`로 찾은 각 엔드포인트에 연결하고, 3초마다 `ping <호스트명> <시각>`을
    보내고 응답을 출력한다.
  - 둘 다 Task 3·7과 같은 TLS-PSK 설정을 쓴다. 키는 `HMAC-SHA256(key: utf8(code), data:
    "poketokenbar.team.psk.v1")`, 아이덴티티는 `"ptb-team-v1"`, 암호군은
    `TLS_PSK_WITH_AES_128_GCM_SHA256`, TLS 최대 1.2다.
  - 이 단계의 `<code>`는 아무 문자열이나 된다.

- [ ] **Step 2: 같은 Mac에서 동작 확인**

  Run (터미널 두 개): `swift scripts/team-probe.swift serve test1` /
  `swift scripts/team-probe.swift browse test1`
  Expected: browse 쪽에 `pong ping …`이 3초 간격으로 찍힌다. browse 코드를 `test2`로 바꾸면 TLS 실패가
  로그에 찍히고 `pong`이 오지 않는다.

- [ ] **Step 3: 사무실 와이파이에서 Mac 두 대로 확인 (사람 필요)**

  사용자와 팀원 한 명이 각자 Mac에서 Step 2를 하나씩 실행한다. macOS가 터미널의 "로컬 네트워크" 접근을
  물으면 허용한다.
  Expected: 양쪽에 `pong`이 오간다.

- [ ] **Step 4: 게이트 판단**

  - 통과하면 결과(날짜, 서브넷, 성공 여부)를 스펙 3장 "와이파이 확인 결과"에 한 줄 추가하고 Task 2로
    간다.
  - **실패하면 여기서 멈춘다.** 탐색 실패인지, 연결 실패인지, TLS 실패인지 로그와 함께 사용자에게
    보고한다.

- [ ] **Step 5: Commit**

  ```bash
  git add scripts/team-probe.swift docs/superpowers/specs/2026-10-29-team-play-design.md
  git commit -m "chore(team): add LAN probe script and record office Wi-Fi result"
  ```

### Task 2: 포크 배포 기반 (업데이트 확인 대상·Info.plist·버전)

**Files:**
- Modify: `Sources/PokeTokenBar/Core/UpdateChecker.swift` (`init` 기본 repo, `apply`의 brew 분기)
- Modify: `scripts/build-app.sh` (`VERSION`, Info.plist)
- Test: `Tests/PokeTokenBarTests/UpdateCheckerTests.swift`

**Interfaces:**
- Produces: `UpdateChecker.releaseRepo: String` (static), `UpdateChecker.allowsBrewUpgrade: Bool` (static)

- [ ] **Step 1: 실패하는 테스트 작성**

  ```swift
  func testTeamForkChecksItsOwnReleases() {
      XCTAssertEqual(UpdateChecker.releaseRepo, "likelion-campus/PokeTokenBar")
  }
  func testTeamForkNeverRunsBrewUpgrade() {
      // brew cask(원작 탭)로 업그레이드하면 팀 기능이 사라진다.
      XCTAssertFalse(UpdateChecker.allowsBrewUpgrade)
  }
  func testBuildScriptDeclaresLocalNetworkUsage() throws {
      let script = try String(contentsOf: repoRoot.appendingPathComponent("scripts/build-app.sh"), encoding: .utf8)
      XCTAssertTrue(script.contains("<key>NSLocalNetworkUsageDescription</key>"))
      XCTAssertTrue(script.contains("<string>_ptbteam._tcp</string>"))
      XCTAssertTrue(script.contains("VERSION=\"2.5.601\""))
  }
  ```

  `repoRoot`는 `LocalizedUILiteralTests`처럼 `#filePath`에서 세 단계 올라가 구한다.

- [ ] **Step 2: 실패 확인**

  Run: `swift test --filter UpdateCheckerTests`
  Expected: 위 세 테스트가 FAIL(심볼 없음, 문자열 없음).

- [ ] **Step 3: 구현**

  - `static let releaseRepo = "likelion-campus/PokeTokenBar"`을 추가하고, `init`의 기본 `fetchLatest`가 이
    값을 쓰게 한다.
  - `static let allowsBrewUpgrade = false`을 추가하고, `apply`에서 `brewCaskPath()`를 보기 전에 이 값을 먼저
    본다. false면 릴리스 페이지를 연다. brew 관련 코드와 그 테스트는 지우지 않는다(원작 병합 충돌 최소화).
  - `build-app.sh`에서 `VERSION="2.5.601"`로 바꾸고, Info.plist에 다음을 추가한다.
    - `NSLocalNetworkUsageDescription`: `같은 와이파이의 팀원과 포켓몬 소식을 주고받기 위해 필요해요.`
    - `NSBonjourServices`: 배열 `[_ptbteam._tcp]`

- [ ] **Step 4: 통과 확인**

  Run: `swift test --filter UpdateCheckerTests`
  Expected: PASS(기존 테스트 포함)

- [ ] **Step 5: Commit**

  ```bash
  git add Sources/PokeTokenBar/Core/UpdateChecker.swift scripts/build-app.sh Tests/PokeTokenBarTests/UpdateCheckerTests.swift
  git commit -m "chore(team): point updates at the team fork and declare local network use"
  ```

### Task 3: 팀 코드와 팀 설정

**Files:**
- Create: `Sources/PokeTokenBar/Team/TeamCode.swift`
- Create: `Sources/PokeTokenBar/Team/TeamSettings.swift`
- Test: `Tests/PokeTokenBarTests/TeamCodeTests.swift`, `Tests/PokeTokenBarTests/TeamSettingsTests.swift`

**Interfaces:**
- Produces:
  - `struct TeamCode: Equatable, Sendable`
    - `let normalized: String`: 26자, RFC 4648 base32 대문자
    - `var display: String`: `"PTB-ABCDE-FGHIJ-KLMNO-PQRST-UVWXYZ"`, 5-5-5-5-6 그룹
    - `static func generate<R: RandomNumberGenerator>(using rng: inout R) -> TeamCode`: 128비트, 마지막
      2비트 패딩은 0
    - `init?(parsing input: String)`: 앞뒤 공백 제거, 대소문자 무시, `PTB-` 접두·`-`·공백 허용, base32 26자가
      아니면 nil
    - `var pskKey: SymmetricKey`: `HMAC<SHA256>(key: utf8(normalized), data: "poketokenbar.team.psk.v1")`
    - `static let pskIdentity = Data("ptb-team-v1".utf8)`
  - `@MainActor @Observable final class TeamSettings`
    - `init(defaults: UserDefaults = TeamSettings.defaultStore())`
    - `isEnabled: Bool` ("team.enabled", 기본 false)
    - `code: TeamCode?` ("team.code")
    - `nickname: String` ("team.nickname", 기본 "")
    - `visitsEnabled: Bool` ("team.visits", 기본 true)
    - `notificationsEnabled: Bool` ("team.notifications", 기본 true)
    - `let memberID: String` ("team.memberID", 처음 접근 시 UUID 생성 후 저장)
    - `var isReady: Bool { isEnabled && code != nil && Self.validNickname(nickname) != nil }`
    - `static func validNickname(_ raw: String) -> String?`: 공백 정리 후 1~12 `Character`, 개행 없음
    - `static func defaultStore() -> UserDefaults`: `PTB_STATE_DIR`이 있으면 그 경로 해시를 붙인 suite를
      쓴다(한 Mac에서 두 인스턴스로 테스트하기 위함). 없으면 `.standard`
    - `func leaveTeam()`: code=nil, isEnabled=false. memberID와 nickname은 유지

- [ ] **Step 1: 실패하는 테스트 작성**

  ```swift
  func testGeneratedCodeRoundTripsThroughDisplayForm() {
      var rng = SeededRNG(seed: 7)   // 기존 테스트의 결정적 RNG가 있으면 그것을 쓴다
      let code = TeamCode.generate(using: &rng)
      XCTAssertEqual(code.normalized.count, 26)
      XCTAssertTrue(code.display.hasPrefix("PTB-"))
      XCTAssertEqual(TeamCode(parsing: code.display), code)
      XCTAssertEqual(TeamCode(parsing: "  " + code.normalized.lowercased() + "\n"), code)
  }
  func testParsingRejectsShortOrNonBase32() {
      XCTAssertNil(TeamCode(parsing: "PTB-ABCDE"))
      XCTAssertNil(TeamCode(parsing: String(repeating: "1", count: 26)))   // 1은 base32 아님
  }
  func testSameCodeSameKeyDifferentCodeDifferentKey() { /* pskKey 바이트 비교 */ }

  func testDefaultsAreOffAndNotReady() {
      let s = TeamSettings(defaults: freshDefaults())
      XCTAssertFalse(s.isEnabled); XCTAssertFalse(s.isReady); XCTAssertTrue(s.visitsEnabled)
  }
  func testMemberIDIsStableAcrossInstances() { /* 같은 defaults로 두 번 생성 → 같은 memberID */ }
  func testNicknameValidation() {
      XCTAssertEqual(TeamSettings.validNickname("  민수 "), "민수")
      XCTAssertNil(TeamSettings.validNickname("   "))
      XCTAssertNil(TeamSettings.validNickname(String(repeating: "가", count: 13)))
      XCTAssertEqual(TeamSettings.validNickname("🐣🐣"), "🐣🐣")
      XCTAssertNil(TeamSettings.validNickname("a\nb"))
  }
  func testLeaveTeamKeepsIdentity() { /* leaveTeam 후 code nil, isEnabled false, memberID·nickname 유지 */ }
  ```

- [ ] **Step 2: 실패 확인**

  Run: `swift test --filter 'TeamCodeTests|TeamSettingsTests'`
  Expected: FAIL(타입 없음)

- [ ] **Step 3: 구현**

  위 Interfaces대로 구현한다.

- [ ] **Step 4: 통과 확인**

  Run: `swift test --filter 'TeamCodeTests|TeamSettingsTests'`
  Expected: PASS

- [ ] **Step 5: Commit**

  ```bash
  git add Sources/PokeTokenBar/Team/TeamCode.swift Sources/PokeTokenBar/Team/TeamSettings.swift Tests/PokeTokenBarTests/TeamCodeTests.swift Tests/PokeTokenBarTests/TeamSettingsTests.swift
  git commit -m "feat(team): add team code and team settings"
  ```

### Task 4: 팀 모델과 CompanionStore 이벤트 훅

**Files:**
- Create: `Sources/PokeTokenBar/Team/TeamModels.swift`
- Create: `Sources/PokeTokenBar/Team/TeamEventFactory.swift`
- Modify: `Sources/PokeTokenBar/Core/CompanionStore.swift`. `notifyCompanionEvent`를 부르는 네 곳(진화
  ~956, 졸업 ~1043, 부화 ~1683, 메타몽 공개 ~1740) 바로 옆에 훅 호출을 넣는다.
- Test: `Tests/PokeTokenBarTests/TeamEventTests.swift`

**Interfaces:**
- Produces (`TeamModels.swift`, 전부 `Codable, Equatable, Sendable`):
  - `enum TeamEventKind: String { case hatch, evolve, graduate, dittoReveal }`, `var isBig: Bool { self != .evolve }`
  - `struct TeamEvent: Identifiable`
    - 식별·작성자: `id: String`, `authorID: String`, `authorNickname: String`, `kind: TeamEventKind`
    - 종: `speciesID: Int`, `fromSpeciesID: Int?`, `speciesName: String`, `fromSpeciesName: String?`
    - 개체: `form: PokemonForm?`, `isShiny: Bool`, `nature: PokemonNature?`, `rarity: Rarity`
    - 시각: `day: String`("yyyy-MM-dd", 로컬), `occurredAt: Date?`(nil이면 날짜만)
  - `enum TeamReactionKind: String { case cute, lol, congrats, comment }`
  - `struct TeamReaction: Identifiable`
    - `id`, `eventID`, `authorID`, `authorNickname: String`
    - `kind: TeamReactionKind`, `text: String?`, `createdAt: Date`
    - `static let maxCommentLength = 40`
  - `struct TeamMonSummary { speciesID: Int?; isShiny: Bool; form: PokemonForm?; speciesName: String? }`
    (speciesID nil = 알)
  - `struct TeamDexSpecies { speciesID: Int; form: PokemonForm?; name: String; rarity: Rarity; hasShiny: Bool; hasNormal: Bool }`
  - `struct TeamMemberProfile { memberID: String; nickname: String; current: TeamMonSummary; dex: [TeamDexSpecies] }`
  - `struct CompanionTeamEvent: Equatable, Sendable`: 위 `TeamEvent`의 종·개체 필드만 가진다. 작성자, id, 시각은
    없다.
- Produces (`TeamEventFactory.swift`):
  `enum TeamEventFactory { static func make(_ e: CompanionTeamEvent, authorID: String, nickname: String, now: Date, hasOnlinePeers: Bool, calendar: Calendar = .current, id: String = UUID().uuidString) -> TeamEvent }`
  - `day`는 `now`의 로컬 날짜다.
  - `occurredAt = hasOnlinePeers ? now : nil`
- Produces (`CompanionStore`): `var onTeamEvent: ((CompanionTeamEvent) -> Void)?`

  각 지점에서 넘기는 값:

  | 지점 | `speciesID` | `fromSpeciesID` | `isShiny` |
  |---|---|---|---|
  | 부화 | `line.baseID` | nil | `showShiny` (위장 중이면 false) |
  | 진화 | `next.speciesID` | `a.currentID` | `a.displaysShiny` |
  | 졸업 | `finalID` | nil | `a.displaysShiny` |
  | 메타몽 공개 | 132 | 위장 종 | `shiny` |

  이름은 그 자리에서 이미 계산한 `name`/`newName`/`disguiseName`을 쓴다. 폼, 성격, 희귀도는 그 개체 값이다.

- [ ] **Step 1: 실패하는 테스트 작성**

  ```swift
  func testFactoryUsesExactTimeOnlyWhenPeersOnline() {
      let e = TeamEventFactory.make(sample, authorID: "m1", nickname: "민수", now: noonOct29, hasOnlinePeers: true)
      XCTAssertEqual(e.occurredAt, noonOct29); XCTAssertEqual(e.day, "2026-10-29")
      let off = TeamEventFactory.make(sample, authorID: "m1", nickname: "민수", now: noonOct29, hasOnlinePeers: false)
      XCTAssertNil(off.occurredAt); XCTAssertEqual(off.day, "2026-10-29")
  }
  func testEncodedEventCarriesNoUsageNumbers() throws {
      let json = String(decoding: try JSONEncoder().encode(TeamEventFactory.make(sample, …)), as: UTF8.self)
      for banned in ["token", "Token", "cost", "usage", "limit", "progress", "usedAt"] {
          XCTAssertFalse(json.contains(banned), banned)
      }
  }
  func testHatchHookFiresOnceWithBaseSpecies() async { /* 기존 CompanionTests의 부화 픽스처로 hatch → 받은 이벤트 1개, kind .hatch, speciesID == 부화 base */ }
  func testDisguisedDittoHatchHidesShiny() async { /* 위장 메타몽 부화 → isShiny false, speciesID == 위장 종 */ }
  func testEvolveAndGraduateHooksFire() { /* applyUsage로 진화·졸업 → kinds [.evolve, .graduate], evolve의 fromSpeciesID == 진화 전 종, graduate의 fromSpeciesID == nil */ }
  func testDittoRevealHookReportsDisguise() async { /* 리빌 → speciesID 132, fromSpeciesID 위장 종 */ }
  ```

  CompanionStore 테스트는 `CompanionTests.swift`, `DittoTests.swift`의 기존 가짜 provider와 임시
  `fileURL` 구성을 그대로 쓴다.

- [ ] **Step 2: 실패 확인**

  Run: `swift test --filter TeamEventTests`
  Expected: FAIL

- [ ] **Step 3: 구현**

  모델, 팩토리, 훅을 구현한다. 훅은 `notifyCompanionEvent`와 달리 `AppEnv.isBundledApp`이나 알림 설정에
  묶지 않는다. 훅을 받은 뒤 보낼지는 `TeamSession`이 정한다.

- [ ] **Step 4: 통과 확인**

  Run: `swift test --filter 'TeamEventTests|CompanionTests|DittoTests'`
  Expected: PASS

- [ ] **Step 5: Commit**

  ```bash
  git add Sources/PokeTokenBar/Team/TeamModels.swift Sources/PokeTokenBar/Team/TeamEventFactory.swift Sources/PokeTokenBar/Core/CompanionStore.swift Tests/PokeTokenBarTests/TeamEventTests.swift
  git commit -m "feat(team): emit companion events for the team feed"
  ```

### Task 5: 팀 피드 저장소

**Files:**
- Create: `Sources/PokeTokenBar/Team/TeamFeedStore.swift`
- Test: `Tests/PokeTokenBarTests/TeamFeedStoreTests.swift`

**Interfaces:**
- Consumes: `TeamEvent`, `TeamReaction` (Task 4)
- Produces: `@MainActor @Observable final class TeamFeedStore`
  - 생성: `init(fileURL: URL = AppStatePaths.directory().appendingPathComponent("team-feed.json"), myMemberID: String, clock: @escaping () -> Date = Date.init, calendar: Calendar = .current)`
  - 상태:
    - `private(set) var events: [TeamEvent]`: 최신순. 정렬 키는 `occurredAt ?? startOfDay(day)`
    - `func reactions(for eventID: String) -> [TeamReaction]`: 오래된 순
  - 삽입과 동기화:
    - `@discardableResult func insert(_ e: TeamEvent) -> Bool`: 같은 id면 false
    - `@discardableResult func insert(_ r: TeamReaction) -> Bool`
      - 같은 id면 false
      - comment가 아닌 반응은 같은 (authorID, eventID, kind)가 이미 있으면 false
      - comment는 `text`를 앞뒤 공백 정리 후 1~40자가 아니면 false
    - `var eventIDs: Set<String>`, `var reactionIDs: Set<String>`
    - `func events(notIn: Set<String>) -> [TeamEvent]`, `func reactions(notIn: Set<String>) -> [TeamReaction]`
  - 읽음 표시:
    - `var unreadCount: Int`: 내가 쓰지 않은 소식 중 `receivedAt > lastReadAt`인 수
    - `func markAllRead()`
  - 정리:
    - `func prune()`: `day`가 오늘 기준 7일보다 오래된 소식과 300개를 넘는 오래된 소식을 지운다. 지워진 소식의
      반응도 지운다.
    - `static let retentionDays = 7`, `static let maxEvents = 300`
  - 저장:
    - 각 변경 후 원자적으로 저장한다(`Data.write(options: .atomic)`).
    - 형식은 `{ "version": 1, "events": [{event, receivedAt}], "reactions": [...], "lastReadAt": … }`
    - 파일이 깨졌으면 `team-feed.json.corrupt`로 옮기고 빈 상태로 시작한다.

- [ ] **Step 1: 실패하는 테스트 작성**

  ```swift
  func testDuplicateEventIsIgnored() { XCTAssertTrue(store.insert(e1)); XCTAssertFalse(store.insert(e1)); XCTAssertEqual(store.events.count, 1) }
  func testPresetReactionOncePerAuthorButCommentsMany() { /* cute 두 번 → 두 번째 false. comment 두 개 → 둘 다 true */ }
  func testCommentLengthLimit() { /* 41자 false, "  " false, 40자 true */ }
  func testOrderingPutsDayOnlyAtStartOfItsDay() { /* 어제 exact 23:00, 오늘 dayOnly, 오늘 exact 09:00 → [오늘09, 오늘dayOnly, 어제23] */ }
  func testUnreadCountsOnlyOthersAfterMarkRead() { /* 내 소식은 unread 아님, markAllRead 후 0, 새 소식 1 */ }
  func testPruneDropsOldEventsAndTheirReactions() { /* 8일 전 소식 + 그 반응 → prune 후 사라짐 */ }
  func testPersistsAcrossInstances() { /* 같은 fileURL로 새 인스턴스 → events·reactions·unread 동일 */ }
  func testCorruptFileStartsEmptyAndKeepsBackup() throws {
      try Data("{not json".utf8).write(to: url)
      let s = TeamFeedStore(fileURL: url, myMemberID: "me")
      XCTAssertTrue(s.events.isEmpty)
      XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + ".corrupt"))
  }
  ```

- [ ] **Step 2: 실패 확인**

  Run: `swift test --filter TeamFeedStoreTests`
  Expected: FAIL

- [ ] **Step 3: 구현**

  위 Interfaces대로 구현한다.

- [ ] **Step 4: 통과 확인**

  Run: `swift test --filter TeamFeedStoreTests`
  Expected: PASS

- [ ] **Step 5: Commit**

  ```bash
  git add Sources/PokeTokenBar/Team/TeamFeedStore.swift Tests/PokeTokenBarTests/TeamFeedStoreTests.swift
  git commit -m "feat(team): add persistent team feed store"
  ```

### Task 6: 메시지 형식과 프레이밍

**Files:**
- Create: `Sources/PokeTokenBar/Team/TeamWire.swift`
- Test: `Tests/PokeTokenBarTests/TeamWireTests.swift`

**Interfaces:**
- Produces:
  - `struct TeamHello: Codable, Equatable, Sendable { memberID: String; nickname: String; protocolVersion: Int; current: TeamMonSummary }`
  - `enum TeamMessage: Codable, Equatable, Sendable`
    - `case hello(TeamHello)`
    - `case inventory(eventIDs: [String], reactionIDs: [String])`
    - `case events([TeamEvent], live: Bool)`
    - `case reactions([TeamReaction], live: Bool)`
    - `case profileRequest`
    - `case profile(TeamMemberProfile)`
  - `enum TeamWire`
    - `static let protocolVersion = 1`, `static let maxFrameBytes = 1_048_576`
    - `static func encode(_ m: TeamMessage) throws -> Data`: 4바이트 빅엔디언 길이 + JSON
    - `struct FrameDecoder { mutating func append(_ chunk: Data) throws -> [TeamMessage] }`
    - `enum WireError: Error { case frameTooLarge, malformed }`
  - `live`의 의미: 방금 생긴 일이면 true(발행·반응 직후 전송), 동기화 응답이면 false. 놀러 오기와 말풍선은
    `live`만 보고 판단하고 시각은 보지 않는다(시계 차이 대비).

- [ ] **Step 1: 실패하는 테스트 작성**

  ```swift
  func testRoundTripEveryCase() throws { /* 각 case encode → FrameDecoder.append → 동일 */ }
  func testDecoderHandlesSplitAndCoalescedChunks() throws { /* 두 프레임을 붙여 1바이트씩 append → 메시지 2개 */ }
  func testOversizedFrameThrows() { /* 길이 헤더 maxFrameBytes+1 → frameTooLarge */ }
  func testGarbageJSONThrowsMalformed() { /* 올바른 길이 + 깨진 JSON → malformed */ }
  ```

- [ ] **Step 2: 실패 확인**

  Run: `swift test --filter TeamWireTests`
  Expected: FAIL

- [ ] **Step 3: 구현**

  위 Interfaces대로 구현한다.

- [ ] **Step 4: 통과 확인**

  Run: `swift test --filter TeamWireTests`
  Expected: PASS

- [ ] **Step 5: Commit**

  ```bash
  git add Sources/PokeTokenBar/Team/TeamWire.swift Tests/PokeTokenBarTests/TeamWireTests.swift
  git commit -m "feat(team): add team wire messages and framing"
  ```

### Task 7: Bonjour + TLS-PSK 전송 계층

**Files:**
- Create: `Sources/PokeTokenBar/Team/TeamTransport.swift`
- Test: `Tests/PokeTokenBarTests/TeamTransportTests.swift` (루프백 통합 테스트)

**Interfaces:**
- Consumes: `TeamCode` (Task 3), `TeamMessage`, `TeamWire` (Task 6)
- Produces:
  - `typealias TeamPeerID = String`: 연결마다 새 UUID. 멤버 ID가 아니다.
  - `protocol TeamTransporting: AnyObject`
    - 콜백 3개(`{ get set }`, 모두 메인 액터에서 호출):
      - `onPeerConnected: ((TeamPeerID) -> Void)?`
      - `onPeerDisconnected: ((TeamPeerID) -> Void)?`
      - `onMessage: ((TeamPeerID, TeamMessage) -> Void)?`
    - `func start(code: TeamCode)`, `func stop()`
    - `func send(_ m: TeamMessage, to peer: TeamPeerID)`, `func disconnect(_ peer: TeamPeerID)`
  - `final class BonjourTeamTransport: TeamTransporting`
    - `static let serviceType = "_ptbteam._tcp"`
    - `static func parameters(code: TeamCode) -> NWParameters`: Task 1과 같은 PSK, 아이덴티티, 암호군, TLS 1.2
    - `init(advertise: Bool = true)`: 테스트는 false로 만들고 아래 `connect`로 직접 붙는다
    - `func connect(to endpoint: NWEndpoint)`: 내부와 테스트에서 쓴다
    - `var listenerPort: NWEndpoint.Port?`: 테스트용
    - 동작:
      - 실행마다 무작위 인스턴스 이름으로 광고한다.
      - 자기 리스너를 제외하고, 찾은 엔드포인트마다 연결한다.
      - TLS 실패한 엔드포인트는 60초 동안 다시 시도하지 않는다.
      - 와이파이가 바뀌면 재시작한다(`NWPathMonitor` 또는 기존 `NetworkReachabilityMonitor.onReconnected`).
      - 받은 데이터는 `FrameDecoder`로 풀고, `WireError`가 나면 그 연결을 끊는다.

- [ ] **Step 1: 실패하는 테스트 작성**

  ```swift
  func testSameCodePeersExchangeMessagesOverLoopback() async throws {
      let a = BonjourTeamTransport(advertise: false), b = BonjourTeamTransport(advertise: false)
      a.start(code: code); b.start(code: code)
      let port = try await waitFor { a.listenerPort }
      b.connect(to: .hostPort(host: "127.0.0.1", port: port))
      // b → a 로 .profileRequest 전송, a.onMessage 수신 확인 (5초 타임아웃)
  }
  func testDifferentCodeNeverDeliversMessages() async throws { /* b는 다른 코드 → 3초 안에 onMessage 없음, onPeerConnected 없음 */ }
  ```

- [ ] **Step 2: 실패 확인**

  Run: `swift test --filter TeamTransportTests`
  Expected: FAIL

- [ ] **Step 3: 구현**

  위 Interfaces대로 구현한다. 발신 연결과 수신 연결 모두 `onPeerConnected`는 TLS 핸드셰이크가 끝난 뒤
  (`.ready`) 한 번만 부른다.

- [ ] **Step 4: 통과 확인**

  Run: `swift test --filter TeamTransportTests`
  Expected: PASS. CI(`macos-15`)에서도 돌아야 한다. 루프백 직접 연결이라 Bonjour에 의존하지 않는다.

- [ ] **Step 5: Commit**

  ```bash
  git add Sources/PokeTokenBar/Team/TeamTransport.swift Tests/PokeTokenBarTests/TeamTransportTests.swift
  git commit -m "feat(team): add Bonjour transport with team-code TLS-PSK"
  ```

### Task 8: TeamSession 조율자와 프로필 생성

**Files:**
- Create: `Sources/PokeTokenBar/Team/TeamSession.swift`
- Create: `Sources/PokeTokenBar/Team/TeamProfileBuilder.swift`
- Test: `Tests/PokeTokenBarTests/TeamSessionTests.swift`, `Tests/PokeTokenBarTests/TeamProfileBuilderTests.swift`

**Interfaces:**
- Consumes: Task 3~7 전부
- Produces:
  - `struct TeamMemberState: Equatable`
    - `memberID`, `nickname: String`, `current: TeamMonSummary`
    - `isOnline: Bool`, `isIncompatible: Bool`
    - `profile: TeamMemberProfile?`, `profileReceivedAt: Date?`
  - `@MainActor @Observable final class TeamSession`
    - 생성: `init(settings: TeamSettings, feed: TeamFeedStore, transport: TeamTransporting, profileProvider: @escaping () -> TeamMemberProfile, clock: @escaping () -> Date = Date.init)`
    - 상태:
      - `private(set) var members: [String: TeamMemberState]` (memberID 키, 나는 제외)
      - `var hasOnlinePeers: Bool`
    - 콜백:
      - `var onVisit: ((TeamEvent) -> Void)?`: 남이 쓴 큰 소식, `live`, `occurredAt != nil`, 처음 받았을 때만
      - `var onReactionToMine: ((TeamReaction, TeamEvent) -> Void)?`: 내 소식에 달린 반응, `live`, 처음
        받았을 때만
    - 동작:
      - `func applySettings()`
        - `isReady`면 `transport.start(code:)`, 아니면 `stop()`과 멤버 초기화
        - 코드가 바뀌면 재시작
      - `func publish(_ e: CompanionTeamEvent)`
        - `isReady`가 아니면 무시
        - `TeamEventFactory.make(…, hasOnlinePeers:)` → `feed.insert` → 연결된 모든 피어에
          `.events([e], live: true)`
        - 내 멤버 상태의 `current`도 갱신한다
      - `func react(to eventID: String, kind: TeamReactionKind, text: String?)`: `feed.insert`가 true일 때만
        `.reactions([r], live: true)`를 브로드캐스트한다
      - `func requestProfile(memberID: String)`
    - 메시지 처리 규칙:
      - **연결:** `hello`를 보낸다.
      - **`hello` 수신:**
        - `protocolVersion`이 다르면 `isIncompatible = true`로 두고 끊는다.
        - memberID가 내 것이면 끊는다.
        - 같은 memberID로 연결이 두 개면 memberID가 작은 쪽이 시작한 연결만 남긴다.
        - 남긴 연결에는 `inventory`를 보낸다.
      - **`inventory` 수신:** 상대에게 없는 소식과 반응을 `live: false`로 보낸다.
      - **`events`/`reactions` 수신:** `feed.insert`가 true인 항목만 콜백 대상이다.
      - **소식을 받으면 그 멤버의 `current`를 갱신한다:** hatch·evolve·dittoReveal이면 그 종, graduate면 알.
      - **연결 해제:** 그 멤버에 남은 연결이 없으면 `isOnline = false`
  - `enum TeamProfileBuilder`
    - `static func profile(memberID: String, nickname: String, state: CompanionState, dexSpecies: [CompanionStore.DexSpecies], speciesName: (Int) -> String?) -> TeamMemberProfile`
    - `current`:
      - `state.active`가 없으면 알(speciesID nil)
      - 있으면 `active.currentID`와 `active.displaysShiny`. 위장 메타몽은 위장 종이 그대로 나간다.
    - `dex`: `dexSpecies`를 그대로 옮긴다(`id`, `form`, `name`, `rarity`, `isShiny → hasShiny`, `hasNormal`).
    - 진행률이나 사용량 필드는 만들지 않는다.

  테스트용 `FakeTransportHub`(테스트 타깃)는 여러 `FakeTeamTransport`를 메모리 안에서 서로 잇는다. 연결,
  끊기, 메시지 전달을 수동으로 흘려보낼 수 있어야 한다.

- [ ] **Step 1: 실패하는 테스트 작성**

  ```swift
  func testHelloThenInventorySyncFillsMissingEvents() { /* A에 소식 2개, B 빈 상태 → 연결 → B.feed.events.count == 2, B.onVisit 호출 0 (live:false) */ }
  func testLivePublishVisitsOthersOnce() { /* A.publish(hatch) → B.onVisit 1회, A.onVisit 0회 */ }
  func testDuplicateEventFromTwoPeersVisitsOnce() { /* A가 live로 보낸 소식을 C의 sync 응답으로 다시 받음 → B.onVisit 1회, B.feed 1행 */ }
  func testEvolveDoesNotVisit() { /* live evolve → onVisit 0, feed 1 */ }
  func testOfflinePublishIsDayOnlyAndSyncedLaterWithoutVisit() { /* 피어 없이 publish → occurredAt nil → 나중에 연결 → B.feed 1, onVisit 0 */ }
  func testReactionToMyEventCallsBackOnceAndReachesEveryone() { /* B.react(cute) → A.onReactionToMine 1회, C.feed.reactions 1 */ }
  func testReconnectResyncsWithoutDuplicates() { /* 연결 → 끊김(isOnline false) → 끊긴 동안 A가 2개 publish → 재연결 → B.feed 정확히 +2, 중복 0 */ }
  func testProtocolMismatchMarksIncompatibleAndDisconnects() { /* protocolVersion 2 hello → isIncompatible true, transport.disconnect 호출 */ }
  func testDuplicateConnectionsKeepOne() { /* 양방향 동시 연결 → 남은 연결 1, members 1 */ }
  func testDisabledSessionPublishesNothing() { /* isEnabled false → publish 후 feed 0, 전송 0 */ }
  func testProfileRequestRoundTrip() { /* B.requestProfile(A) → B.members[A].profile == A.profileProvider() */ }

  // TeamProfileBuilderTests
  func testEggProfileHasNoSpecies() { … }
  func testDisguisedDittoShowsDisguiseWithoutShiny() { … }
  func testProfileJSONHasNoUsageNumbers() { /* Task 4의 금지어 목록 동일 */ }
  ```

- [ ] **Step 2: 실패 확인**

  Run: `swift test --filter 'TeamSessionTests|TeamProfileBuilderTests'`
  Expected: FAIL

- [ ] **Step 3: 구현**

  위 Interfaces대로 구현한다.

- [ ] **Step 4: 통과 확인**

  Run: `swift test --filter 'TeamSessionTests|TeamProfileBuilderTests'`
  Expected: PASS

- [ ] **Step 5: 커버리지 게이트에 순수 로직 추가**

  `scripts/test-gate.sh`의 `LOGIC_CORE`에 다음을 추가한다: `Team/TeamCode.swift`,
  `Team/TeamEventFactory.swift`, `Team/TeamFeedStore.swift`, `Team/TeamWire.swift`,
  `Team/TeamSession.swift`, `Team/TeamProfileBuilder.swift`.
  Run: `./scripts/test-gate.sh`
  Expected: 게이트 통과(기준 75%)

- [ ] **Step 6: Commit**

  ```bash
  git add Sources/PokeTokenBar/Team/TeamSession.swift Sources/PokeTokenBar/Team/TeamProfileBuilder.swift Tests/PokeTokenBarTests/TeamSessionTests.swift Tests/PokeTokenBarTests/TeamProfileBuilderTests.swift scripts/test-gate.sh
  git commit -m "feat(team): add team session sync and profile builder"
  ```

### Task 9: 팀 문구와 설정 섹션, 앱 배선

**Files:**
- Create: `Sources/PokeTokenBar/Team/TeamLocalization.swift`
- Create: `Sources/PokeTokenBar/Team/UI/TeamSettingsSection.swift`
- Modify: `Sources/PokeTokenBar/UI/SettingsView.swift` (알림 섹션 바로 위에 `TeamSettingsSection` 한 줄)
- Modify: `Sources/PokeTokenBar/PokeTokenBarApp.swift` (`applicationDidFinishLaunching`)
- Test: `Tests/PokeTokenBarTests/TeamLocalizationTests.swift`

**Interfaces:**
- Consumes: `TeamSettings`, `TeamCode` (Task 3), `TeamSession` (Task 8)
- Produces:
  - `extension L`: 이 계획의 모든 팀 문구. 이 Task에서는 설정 섹션 문구, 이후 Task에서 필요한 문구를 같은
    파일에 더한다. 모두 한국어 고정 문자열이고 `t(...)`를 쓰지 않는다.
  - 앱 배선:
    - `TeamSettings`, `TeamFeedStore`, `BonjourTeamTransport`, `TeamSession`을 만든다.
    - `companion.onTeamEvent = { session.publish($0) }`
    - `profileProvider`는 `TeamProfileBuilder.profile(…, state: companion.state, dexSpecies: companion.dexSpecies, …)`
    - `session.applySettings()`
    - `TeamSession`과 `TeamFeedStore`는 팝오버 환경(`.environment(...)`)에 넣는다.
- 설정 섹션 동작:
  - "팀 기능 켜기" 토글
  - 코드가 없을 때: "팀 만들기"(코드 생성 + 복사 버튼 표시), "코드로 참여"(붙여 넣기 필드, 잘못된 코드면
    인라인 오류)
  - 코드가 있을 때: 마스킹된 코드, 복사, "팀 나가기"
  - 닉네임 필드: `validNickname`이 nil이면 인라인 오류를 보이고 `isReady`가 false로 남는다.
  - 놀러 오기 토글, 팀 알림 토글
  - 설정이 바뀔 때마다 `session.applySettings()`를 부른다.
  - 개발용: `AppEnv.isBundledApp`이 false(`swift run`)일 때만 "테스트 부화 보내기"와 "테스트 진화 보내기"
    버튼이 보인다. 버튼은 무작위 Gen 1~5 종으로 만든 `CompanionTeamEvent`를 `session.publish`에 넘긴다.
    Task 10~12의 수동 확인이 이 버튼을 쓴다. 문구는 영어 고정이라 한글 리터럴 검사에 걸리지 않는다.

- [ ] **Step 1: 실패하는 테스트 작성**

  ```swift
  func testTeamUIFilesHaveNoHangulLiterals() throws {
      // LocalizedUILiteralTests.hasHangulStringLiteral 과 같은 검사를 Sources/PokeTokenBar/Team/UI 에 적용
  }
  ```

  검사 함수를 재사용할 수 있게 `LocalizedUILiteralTests`의 `hasHangulStringLiteral`을 `static`
  internal로 바꾼다. 이 파일의 다른 동작은 바꾸지 않는다.

- [ ] **Step 2: 실패 확인**

  Run: `swift test --filter TeamLocalizationTests`
  Expected: FAIL(`Team/UI` 폴더가 없어 enumerator nil)

- [ ] **Step 3: 구현**

  문구, 설정 섹션, 앱 배선을 구현한다.

- [ ] **Step 4: 통과 확인과 수동 확인**

  Run: `swift test --filter 'TeamLocalizationTests|LocalizedUILiteralTests'`
  Expected: PASS

  Run: `PTB_STATE_DIR=$(mktemp -d) swift run PokeTokenBar`
  Expected:
  - 설정 → 팀 섹션에서 "팀 만들기"를 누르면 `PTB-…` 코드가 보인다.
  - 닉네임을 비우면 오류가 보이고, 채우면 사라진다.
  - `dns-sd -B _ptbteam._tcp local`에 무작위 이름 하나가 보인다.
  - 팀 기능을 끄면 그 이름이 사라진다.

- [ ] **Step 5: Commit**

  ```bash
  git add Sources/PokeTokenBar/Team/TeamLocalization.swift Sources/PokeTokenBar/Team/UI/TeamSettingsSection.swift Sources/PokeTokenBar/UI/SettingsView.swift Sources/PokeTokenBar/PokeTokenBarApp.swift Tests/PokeTokenBarTests/TeamLocalizationTests.swift Tests/PokeTokenBarTests/LocalizedUILiteralTests.swift
  git commit -m "feat(team): add team settings section and wire the team session"
  ```

### Task 10: 팀 탭 (피드·멤버·반응·한마디)

**Files:**
- Create: `Sources/PokeTokenBar/Team/UI/TeamTabView.swift`
- Create: `Sources/PokeTokenBar/Team/TeamTimeLabel.swift`
- Modify: `Sources/PokeTokenBar/UI/PopoverView.swift`
  - `PopoverTab`에 `.team` 추가
  - `Picker`에 탭 추가. 라벨은 `l.teamTabTitle(unread:)`
  - 본문 분기에 `TeamTabView` 추가. 다른 탭과 같은 고정 높이 520
- Test: `Tests/PokeTokenBarTests/TeamTimeLabelTests.swift`

**Interfaces:**
- Consumes: `TeamSession`, `TeamFeedStore` (환경), `SpriteLoader.image(speciesID:animated:shiny:form:)`
- Produces: `enum TeamTimeLabel { static func text(for e: TeamEvent, now: Date, calendar: Calendar = .current, l: L) -> String }`
  - `occurredAt`이 있을 때:
    - 1분 미만이거나 미래면 "방금"
    - 60분 미만이면 "N분 전"
    - 같은 날이면 "오늘 HH:mm"
  - `occurredAt`이 nil일 때(`day`만 있을 때):
    - 오늘이면 "오늘", 어제면 "어제"
    - 그 외에는 "M/d"
- 화면 구성(시안 B):
  - 위에 멤버 줄(스프라이트, 닉네임, 온라인 점, 다른 버전이면 회색과 툴팁). 누르면 Task 11의 카드
  - 아래에 소식 목록. 각 행:
    - 스프라이트, 문구, 시간 라벨
    - 반응 칩(종류별 수)과 최근 한마디 2개
    - 🥹 🤣 🎉 💬 버튼. 💬는 인라인 입력(40자)을 연다.
  - 팀 기능이 꺼져 있거나 `isReady`가 아니면 설정으로 가는 안내만 보인다.
  - 탭이 보이는 동안 `feed.markAllRead()`

- [ ] **Step 1: 실패하는 테스트 작성**

  ```swift
  func testRelativeLabels() { /* 30초 전 "방금", 32분 전 "32분 전", 3시간 전 같은 날 "오늘 09:12" */ }
  func testRelativeLabelClampsFutureToJustNow() { /* occurredAt = now + 10분 → "방금" */ }
  func testDayOnlyLabels() { /* 오늘 "오늘", 어제 "어제", 10/27 "10/27" */ }
  ```

- [ ] **Step 2: 실패 확인**

  Run: `swift test --filter TeamTimeLabelTests`
  Expected: FAIL

- [ ] **Step 3: 구현**

  `TeamTimeLabel`과 `TeamTabView`를 구현하고 `PopoverView`에 연결한다.

- [ ] **Step 4: 통과 확인과 수동 확인**

  Run: `swift test --filter 'TeamTimeLabelTests|TeamLocalizationTests|LocalizedUILiteralTests'`
  Expected: PASS

  수동 확인: 한 Mac에서 `PTB_STATE_DIR`이 다른 인스턴스 두 개를 띄운다.
  - Run: `PTB_STATE_DIR=/tmp/ptb-a swift run PokeTokenBar`
  - Run: `PTB_STATE_DIR=/tmp/ptb-b swift run PokeTokenBar` (같은 팀 코드, 다른 닉네임)
  - 한쪽에서 설정의 "테스트 부화 보내기"(Task 9)를 누른다.
  - Expected: 다른 쪽 팀 탭에 소식이 뜬다. 반응을 누르면 양쪽 피드에 칩 수가 오른다. 안 읽은 수가 탭
    라벨에 보이고, 탭을 열면 0이 된다.

- [ ] **Step 5: Commit**

  ```bash
  git add Sources/PokeTokenBar/Team/UI/TeamTabView.swift Sources/PokeTokenBar/Team/TeamTimeLabel.swift Sources/PokeTokenBar/UI/PopoverView.swift Sources/PokeTokenBar/Team/TeamLocalization.swift Tests/PokeTokenBarTests/TeamTimeLabelTests.swift
  git commit -m "feat(team): add team tab with feed, members and reactions"
  ```

### Task 11: 팀원 카드

**Files:**
- Create: `Sources/PokeTokenBar/Team/UI/TeamMemberCardView.swift`
- Modify: `Sources/PokeTokenBar/Team/UI/TeamTabView.swift` (멤버를 누르면 카드 표시)

**Interfaces:**
- Consumes: `TeamSession.requestProfile(memberID:)`, `TeamMemberState.profile`/`profileReceivedAt`
- 카드를 열 때 `requestProfile`을 부른다. 보여 주는 것:
  - 현재 포켓몬
  - 도감 그리드(4열, 이로치 ✨ 표시, 폼 이름)
  - 종 수
- 멤버가 오프라인이면 마지막 프로필과 "N분 전 기준"을 보여 준다. 프로필이 없으면 "온라인일 때 볼 수
  있어요"를 보여 준다.
- 진행률, 토큰, 비용 표시는 없다.
- 교환 버튼은 두지 않는다(2부).

- [ ] **Step 1: 구현**

  기존 도감 셀(`CompanionView.swift`의 `DexSpeciesCell`)을 그대로 재사용하기 어렵다. `DexSpecies` 대신
  `TeamDexSpecies`를 받는 작은 셀을 만든다.

- [ ] **Step 2: 확인**

  Run: `swift build && swift test --filter 'TeamLocalizationTests|LocalizedUILiteralTests'`
  Expected: 빌드 성공, PASS

  수동 확인(Task 10의 두 인스턴스): 멤버를 누르면 상대 도감이 보인다. 상대 인스턴스를 끄고 다시 누르면
  "N분 전 기준"이 보인다.

- [ ] **Step 3: Commit**

  ```bash
  git add Sources/PokeTokenBar/Team/UI/TeamMemberCardView.swift Sources/PokeTokenBar/Team/UI/TeamTabView.swift Sources/PokeTokenBar/Team/TeamLocalization.swift
  git commit -m "feat(team): add teammate card with read-only Pokédex"
  ```

### Task 12: 놀러 오는 포켓몬과 반응 말풍선

**Files:**
- Create: `Sources/PokeTokenBar/Team/VisitQueue.swift`
- Create: `Sources/PokeTokenBar/Team/PresentationGuard.swift`
- Create: `Sources/PokeTokenBar/Team/UI/VisitorPanelController.swift`
- Modify: `Sources/PokeTokenBar/UI/FloatingPetPanel.swift` (`var petScreenFrame: NSRect?` 공개 읽기 전용,
  패널이 보일 때만 값)
- Modify: `Sources/PokeTokenBar/PokeTokenBarApp.swift` (`session.onVisit`, `session.onReactionToMine` 연결)
- Test: `Tests/PokeTokenBarTests/VisitQueueTests.swift`

**Interfaces:**
- Consumes: `TeamSession.onVisit`, `onReactionToMine`, `react(to:kind:text:)`, `TeamSettings.visitsEnabled`
- Produces:
  - `struct VisitQueue`
    - `init(maxAge: TimeInterval = 30 * 60)`
    - `mutating func enqueue(_ e: TeamEvent, at: Date)`
    - `mutating func next(now: Date, presenting: Bool) -> TeamEvent?`
      - 발표 중이면 nil
      - `maxAge`보다 오래 기다린 항목은 버린다(피드에는 이미 있다)
      - 들어온 순서대로 하나씩 꺼낸다
  - `struct ReactionBatcher`
    - `init(window: TimeInterval = 5, maxLines: Int = 3)`
    - `mutating func add(_ r: TeamReaction, at: Date)`
    - `mutating func flush(now: Date) -> (lines: [TeamReaction], overflow: Int)?`: 창이 지나면 묶음 반환
  - `protocol PresentationGuarding { func isPresenting() -> Bool }`
  - `struct SystemPresentationGuard: PresentationGuarding`: 최선 노력. 다음 중 하나면 true다.
    - 메인 화면을 꽉 채우는 레이어 0 창이 있다(`CGWindowListCopyWindowInfo`).
    - 맨 앞 앱이 화상회의 앱이다: `us.zoom.xos`, `com.microsoft.teams2`, `com.microsoft.teams`,
      `com.cisco.webexmeetingsapp`, `com.apple.FaceTime`.
    - 집중 모드: `INFocusStatusCenter`는 권한 문제로 쓰지 않는다. 대신 이때 놀러 오기가 나타날 수 있다는
      한계를 Task 14의 TEAM.md에 적는다.
  - `final class VisitorPanelController`: 앱이 한 개를 갖는다. 메인 액터에서 15초마다, 큐가 비어 있지 않을
    때만 `next`를 묻는다.
    - **놀러 오기:**
      - 테두리 없는 `.floating` 패널이다. 내 펫 패널(`petScreenFrame`) 왼쪽으로 화면 가장자리에서 1.2초 동안
        걸어 들어온다.
      - 말풍선에는 "{닉네임}의 {소식 문구}"와 🥹 🤣 🎉 💬 버튼이 있다. 💬는 40자 입력을 연다.
      - 반응하면 2초 뒤에, 반응하지 않으면 12초 뒤에 걸어 나간다.
    - **반응 말풍선:** 내 펫 위 별도 패널에 `ReactionBatcher` 묶음을 "{닉네임}: {이모지} {문구}"로 보인다.
      넘친 수는 "외 N개"로 붙이고, 6초 뒤 사라진다.
    - **놀러 오기를 보이지 않는 경우:**
      - `visitsEnabled`가 false이거나 `petScreenFrame`이 nil(펫 꺼짐)이면 놀러 오기와 반응 말풍선을 띄우지
        않는다.
      - 그때 받은 소식과 반응은 Task 13의 알림 경로로 넘긴다.

- [ ] **Step 1: 실패하는 테스트 작성**

  ```swift
  func testQueueReleasesInOrderOneAtATime() { … }
  func testQueueHoldsWhilePresentingThenReleases() { /* presenting true → nil, false → 첫 항목 */ }
  func testQueueDropsItemsOlderThanMaxAge() { /* 31분 기다린 항목 → nil, 큐 비움 */ }
  func testBatcherGroupsWithinWindowAndCountsOverflow() { /* 5초 안 반응 5개 → lines 3, overflow 2 */ }
  func testBatcherWaitsUntilWindowPasses() { /* 2초 뒤 flush → nil */ }
  ```

- [ ] **Step 2: 실패 확인**

  Run: `swift test --filter VisitQueueTests`
  Expected: FAIL

- [ ] **Step 3: 구현**

  위 Interfaces대로 구현한다. 패널 설정은 `FloatingPetController.makePanel()`과 같은 값을 쓴다
  (`.floating`, `.canJoinAllSpaces`, `.fullScreenAuxiliary`, `nonactivatingPanel`).

- [ ] **Step 4: 통과 확인과 수동 확인**

  Run: `swift test --filter VisitQueueTests`
  Expected: PASS

  수동 확인(두 인스턴스, 둘 다 플로팅 펫 켬):
  - B에서 "테스트 부화 보내기"를 누르면 A 화면에 B의 포켓몬이 걸어 들어온다.
  - "테스트 진화 보내기"는 놀러 오지 않고 팀 탭에만 쌓인다.
  - A가 🤣를 누르면 B의 펫 위에 "A닉네임: 🤣 이게 뭐야"가 뜬다.
  - Keynote나 QuickTime이 전체 화면일 때 테스트 부화를 보내면 놀러 오지 않다가, 전체 화면을 끄면 온다.

- [ ] **Step 5: Commit**

  ```bash
  git add Sources/PokeTokenBar/Team/VisitQueue.swift Sources/PokeTokenBar/Team/PresentationGuard.swift Sources/PokeTokenBar/Team/UI/VisitorPanelController.swift Sources/PokeTokenBar/UI/FloatingPetPanel.swift Sources/PokeTokenBar/PokeTokenBarApp.swift Sources/PokeTokenBar/Team/TeamLocalization.swift Tests/PokeTokenBarTests/VisitQueueTests.swift
  git commit -m "feat(team): add visiting Pokémon and reaction bubbles"
  ```

### Task 13: 알림 배너 경로

**Files:**
- Create: `Sources/PokeTokenBar/Team/TeamNotifications.swift`
- Modify: `Sources/PokeTokenBar/PokeTokenBarApp.swift` (알림 센터 delegate 설정, 카테고리 등록)
- Test: `Tests/PokeTokenBarTests/TeamNotificationsTests.swift`

**Interfaces:**
- Consumes: `TeamSession.react(to:kind:text:)`, `TeamSettings.notificationsEnabled`, Task 12의 넘김 경로
- Produces:
  - `enum TeamNotifications`
    - `static let eventCategory = "team.event"`, `static let reactionCategory = "team.reaction"`
    - `static func categories(l: L) -> Set<UNNotificationCategory>`
      - event 카테고리 액션: `team.react.cute`, `team.react.lol`, `team.react.congrats`, 그리고
        `UNTextInputNotificationAction` `team.react.comment`
    - `static func eventContent(_ e: TeamEvent, l: L) -> UNMutableNotificationContent`: `userInfo["eventID"]`
    - `static func reactionContent(_ r: TeamReaction, on e: TeamEvent, l: L) -> UNMutableNotificationContent`
    - `static func reaction(fromActionIdentifier id: String, text: String?) -> (TeamReactionKind, String?)?`
  - `final class TeamNotificationDelegate: NSObject, UNUserNotificationCenterDelegate`
    - `didReceive`: 액션을 `session.react`로 넘긴다.
    - `willPresent`: 팀 카테고리면 `[.banner, .sound]`, 아니면 `[]`를 돌려 기존 동작(앞에 있을 때 안 보임)을
      유지한다.
  - 알림은 `AppEnv.isBundledApp`이고 `notificationsEnabled`일 때만 보낸다. 지난 소식(`live == false`)은
    알리지 않는다. `onVisit`가 이미 그 조건을 걸러 준다.

- [ ] **Step 1: 실패하는 테스트 작성**

  ```swift
  func testEventCategoryHasThreeReactionsAndTextInput() { … }
  func testActionIdentifierMapsToReaction() {
      XCTAssertEqual(TeamNotifications.reaction(fromActionIdentifier: "team.react.lol", text: nil)?.0, .lol)
      XCTAssertEqual(TeamNotifications.reaction(fromActionIdentifier: "team.react.comment", text: "ㅋㅋ")?.1, "ㅋㅋ")
      XCTAssertNil(TeamNotifications.reaction(fromActionIdentifier: UNNotificationDefaultActionIdentifier, text: nil))
  }
  func testEventContentCarriesEventIDAndNoUsageNumbers() { … }
  ```

- [ ] **Step 2: 실패 확인**

  Run: `swift test --filter TeamNotificationsTests`
  Expected: FAIL

- [ ] **Step 3: 구현**

  위 Interfaces대로 구현한다.

- [ ] **Step 4: 통과 확인**

  Run: `swift test --filter TeamNotificationsTests`
  Expected: PASS

  번들 앱에서만 알림이 뜬다. 실제 동작은 Task 15에서 확인한다.

- [ ] **Step 5: Commit**

  ```bash
  git add Sources/PokeTokenBar/Team/TeamNotifications.swift Sources/PokeTokenBar/PokeTokenBarApp.swift Sources/PokeTokenBar/Team/TeamLocalization.swift Tests/PokeTokenBarTests/TeamNotificationsTests.swift
  git commit -m "feat(team): add team notification banners with quick reactions"
  ```

### Task 14: 팀 릴리스 스크립트와 설치 안내

**Files:**
- Create: `scripts/team-release.sh`
- Create: `TEAM.md`
- Test: `Tests/PokeTokenBarTests/TeamReleaseScriptTests.swift`

**Interfaces:**
- Produces: `./scripts/team-release.sh <version> <notes-file>`
  - `<version>`이 세 자리 숫자 형식이 아니거나 현재 `build-app.sh`의 `VERSION`보다 크지 않으면 실패한다.
  - 서명 신원 `PokeTokenBar Local`이 없으면 `scripts/create-signing-cert.sh`를 안내하고 멈춘다. 자동으로
    만들지 않는다.
  - 인증서 leaf를 `TEAM_EXPECTED_LEAF`와 비교한다. 비어 있으면(첫 릴리스) 현재 leaf를 출력하고 스크립트에
    적으라고 안내한 뒤 멈춘다. 다르면 멈춘다.
  - `export PTB_REQUIRE_STABLE_SIGN=1` 후 `build-app.sh`로 빌드한다. 이 스크립트는 `/Applications`에도
    설치한다. 실행하는 사람(사용자)이 의도한 것이다.
  - 나머지 순서:
    1. `ditto`로 zip을 만든다.
    2. universal 바이너리인지 검사한다.
    3. 버전 범프를 커밋하고 `git push origin main`
    4. `gh release create "v$VERSION" build/PokeTokenBar.zip --repo likelion-campus/PokeTokenBar`
  - README, 랜딩, Homebrew 탭, Pages 단계는 없다.
- `TEAM.md`(한국어) 내용:
  - 설치와 갈아타기: 세이브 내보내기 → `brew uninstall --cask poke-token-bar`(`--zap` 금지) → 릴리스 zip
    설치 → 첫 실행 시 Keychain·로컬 네트워크 허용
  - 팀 만들기/참여
  - 알려진 한계: 집중 모드 감지 없음, 모두 오프라인이면 늦게 도착, 사용자 복원은 보호 안 함
  - 연결 문제 진단: `scripts/team-probe.swift`

- [ ] **Step 1: 실패하는 테스트 작성**

  ```swift
  func testTeamReleaseTargetsForkOnly() throws {
      let s = try String(contentsOf: repoRoot.appendingPathComponent("scripts/team-release.sh"), encoding: .utf8)
      XCTAssertTrue(s.contains("--repo likelion-campus/PokeTokenBar"))
      XCTAssertFalse(s.contains("chattymin/"))
      XCTAssertFalse(s.contains("homebrew-tap"))
      XCTAssertTrue(s.contains("PTB_REQUIRE_STABLE_SIGN=1"))
  }
  ```

- [ ] **Step 2: 실패 확인**

  Run: `swift test --filter TeamReleaseScriptTests`
  Expected: FAIL

- [ ] **Step 3: 구현**

  스크립트와 `TEAM.md`를 작성한다. 이 Task에서는 스크립트를 실행하지 않는다.

- [ ] **Step 4: 통과 확인**

  Run: `swift test --filter TeamReleaseScriptTests && bash -n scripts/team-release.sh`
  Expected: PASS, 문법 오류 없음

- [ ] **Step 5: Commit**

  ```bash
  git add scripts/team-release.sh TEAM.md Tests/PokeTokenBarTests/TeamReleaseScriptTests.swift
  git commit -m "chore(team): add team release script and install guide"
  ```

### Task 15: 전체 확인과 첫 팀 릴리스 (사람 필요)

**Files:**
- Modify: `scripts/team-release.sh` (`TEAM_EXPECTED_LEAF` 기록)

- [ ] **Step 1: 전체 테스트**

  Run: `swift build && ./scripts/test-gate.sh`
  Expected: 통과

- [ ] **Step 2: 사용자 확인 후 서명 인증서 생성**

  **실행 전 사용자에게 확인한다.** 사용자 키체인에 인증서를 만드는 작업이다.
  Run: `./scripts/create-signing-cert.sh` → `./scripts/team-release.sh 2.5.601 <notes>`(첫 실행은 leaf 출력
  후 멈춤)
  출력된 leaf를 `TEAM_EXPECTED_LEAF`에 적고 커밋한다.

- [ ] **Step 3: 사용자 확인 후 첫 릴리스**

  **실행 전 사용자에게 버전과 노트 요약을 보여 주고 확인받는다.** 공개 저장소에 릴리스가 생긴다.
  Run: `./scripts/team-release.sh 2.5.601 <notes>`
  Expected: `likelion-campus/PokeTokenBar`에 `v2.5.601` 릴리스와 zip이 생긴다.

- [ ] **Step 4: 사무실에서 Mac 두 대로 끝까지 확인 (사람 필요)**

  사용자와 팀원 한 명이 `TEAM.md`대로 설치한다. 체크리스트:
  - [ ] 기존 도감·포켓몬·가방이 그대로 이어진다.
  - [ ] 같은 코드로 서로 멤버 줄에 보인다.
  - [ ] 부화하면 상대에게 놀러 온다(펫 켬).
  - [ ] 펫을 끈 쪽은 알림 배너를 받는다.
  - [ ] 배너와 놀러 오기에서 반응이 상대 펫 말풍선으로 간다.
  - [ ] 팀원 카드에서 도감이 보인다.
  - [ ] 한쪽 노트북을 덮었다 열면 다시 연결되고, 그 사이 소식이 채워진다.
  - [ ] 다른 팀 코드를 쓰는 Mac에는 아무것도 보이지 않는다.
  - [ ] 인앱 업데이트 확인이 `likelion-campus` 릴리스를 본다.

- [ ] **Step 5: Commit**

  ```bash
  git add scripts/team-release.sh
  git commit -m "chore(team): pin team signing certificate leaf"
  ```
