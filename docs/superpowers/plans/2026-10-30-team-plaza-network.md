# 팀 광장 2부 (네트워크와 팀원 기능) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 같은 팀 코드를 가진 팀원의 포켓몬이 한 광장에 모이고, 말풍선·카드·소식판·기념사진·알림으로 교감할 수 있게 한 뒤, 첫 팀 릴리스를 낸다.

**Architecture:** 전송(`BonjourTeamTransport`) 위에 조율자(`TeamSession`)를 두고, 세션은 가짜 전송으로 테스트한다. `TeamRuntime`이 앱 쪽 입력(`CompanionStore`, `TeamSettings`)과 세션을 잇고, `AppDelegate`는 런타임을 만들어 넘기기만 한다. 광장 화면은 1부의 단일 캐릭터를 `PlazaActor` 묶음으로 나눠 여러 마리를 그린다. 움직임, 표적 찾기, 사진 합성은 순수 값 타입이라 창 없이 테스트한다.

**Tech Stack:** Swift 6, Network.framework, CryptoKit, SpriteKit, SwiftUI(오버레이), CoreGraphics, UserNotifications, XCTest.

**Spec:** `docs/superpowers/specs/2026-10-30-team-plaza-design.md`

**범위:** 스펙 5.2(배지, 나머지 키), 5.4(팀원 캐릭터), 5.5, 5.6, 5.7, 5.8, 5.9, 5.10, 5.11(팀원 칸), 6장, 7장. **이 계획에 없는 것:** 교환, 짧은 글 말풍선, 화면 띠(2차, 11장). 1부 코드는 `docs/superpowers/plans/2026-10-30-team-plaza-solo.md`로 만들었다.

## Global Constraints

- 팀 기능은 기본 꺼짐. `TeamSettings.isReady`가 아니면 광고, 탐색, 연결을 하지 않는다.
- **팀에 보내는 정보에 토큰, 비용, 한도, 성장 진행률, Mac 이름, 호스트 이름, Mac 계정명을 넣지 않는다.** Bonjour 광고의 인스턴스 이름은 무작위이고 TXT 레코드는 쓰지 않는다.
- **접속 기록을 남기지 않는다.** 받은 위치와 접속 시각을 저장하거나 `AppLog`에 쓰지 않는다. `AppLog`에는 닉네임, 멤버 ID, 칸 좌표, 호스트 이름을 쓰지 않는다. 말풍선은 저장하거나 다시 전달하지 않는다.
- 광장은 세이브(`CompanionState`, `companion-state.json`)를 읽기만 한다. 소식은 `team-feed.json`에 둔다.
- 팀 UI 문구는 한국어만 쓰고 전부 `Sources/PokeTokenBar/Team/TeamLocalization.swift`의 `extension L`에 둔다. `Team/`의 다른 파일과 `UI/`에는 한글 문자열 리터럴을 두지 않는다.
- 모든 SwiftUI `View` 구조체는 선언 바로 윗줄에 `@MainActor`를 둔다(`SwiftUIIsolationTests`).
- `ProcessInfo.processInfo.environment[`를 허용 목록 밖에서 읽지 않는다(`UsageEnvironmentTests`). 상태 폴더는 `AppStatePaths.directory()`로 얻는다.
- 팀 코드는 `Sources/PokeTokenBar/Team/`, 광장 코드는 `Sources/PokeTokenBar/Team/Plaza/`, 팀 SwiftUI는 `Sources/PokeTokenBar/Team/UI/`에 둔다. 기존 파일 수정은 각 Task가 적은 연결 지점만 한다.
- 도트는 뭉개지지 않아야 한다: 텍스처는 `.nearest`, 배율은 정수(1–3, 기본 2), 노드의 왼쪽·아래 모서리를 기기 픽셀에 맞춘다(`PlazaPixelSnap`).
- 광장 창을 닫으면 그리기를 완전히 멈춘다. 닫힌 동안은 그림을 받거나 텍스처를 만들지 않는다.
- 광장 창은 사용자가 열 때만 뜬다. 소식이 와도 저절로 열리거나 앞으로 나오지 않는다.
- 소리를 내지 않는다. 팀 알림의 `content.sound`는 nil이다.
- `UNUserNotificationCenter`는 번들 없이 부르면 앱이 죽는다. `AppEnv.isBundledApp`을 먼저 확인한다.
- 개발 중에는 `scripts/build-app.sh`를 실행하지 않는다(`/Applications`의 앱을 덮어쓴다). 확인은 `swift build`, `swift test --filter …`, `bash scripts/plaza-dev.sh`로 한다.
- 전체 `swift test`와 `scripts/test-gate.sh`는 샌드박스 안에서 멈춘다. 구현자는 전체를 돌리지 않는다. 테스트는 NSWindow나 SKView를 만들지 않는다. 루프백 테스트가 샌드박스에 막히면 그 필터만 샌드박스 밖에서 돌린다.
- 작업마다 규칙 검사 테스트 15개를 함께 돌린다. 아래 명령의 `<규칙 검사 15개>`는 이 목록이다:
  `AppLogTests|AntigravityUsageTests|CredentialSwitchCacheTests|CustomScanRootsTests|LanguageSurfaceRegressionTests|LimitPaceTests|KiroUsageTests|LiveCredentialCallGateTests|LocalizationColumnTests|LocalizedUILiteralTests|PopoverNavigationTests|ScrollerLaneTests|SwiftUIIsolationTests|TeamLocalizationTests|UsageEnvironmentTests`
- 커밋 메시지는 영어로 쓰고 끝에 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`를 붙인다.

## 이 계획이 정한 값 (스펙의 구현자 재량)

| 항목 | 값 |
|---|---|
| 하트비트(내 상태를 다시 보냄) | 10초 |
| 끊김 판정(아무 메시지도 안 옴) | 30초 |
| 재연결 점검 주기 | 15초 |
| TLS 핸드셰이크 제한 | 10초 |
| 핸드셰이크 실패 뒤 재시도 금지 | 60초 |
| 인벤토리 다시 맞추기 | 5분 |
| 소식·반응을 나눠 보내는 묶음 | 100개 |
| 말풍선 표시 | 2.5초, 연타 제한 0.3초 |
| 카드 받기 제한 | 5초 |
| 알림 묶음 창 | 30초 |
| 쉼터 어슬렁거림 | 4–10초마다 옆 칸으로 |
| 키 (keyCode) | 말풍선 1–5 = 18, 19, 20, 21, 23 / 스페이스 49 / 사진 P = 35 |
| 팀원끼리 충돌 | 없음. 서로 지나간다 |
| 연결 구조 | 모두 서로 직접 연결. 같은 멤버와 연결이 둘이면 하나만 남긴다 |

## Review Focus

1. **다른 팀으로 옮김:** 팀 코드를 바꾸거나 팀을 나가면 이전 팀 소식을 새 팀에 동기화하면 안 된다. → Task 4 `testChangingTeamCodeClearsFeed`, `testLeavingTeamClearsFeed`.
2. **인사 없이 사라진 팀원:** 노트북을 덮거나 와이파이가 끊기면 연결 종료 신호가 안 온다. 30초 안에 광장에서 빠지고, 돌아오면 소식이 중복 없이 채워져야 한다. → Task 4 `testSilentPeerIsDroppedAfterTimeout`, `testReconnectResyncsWithoutDuplicates`.
3. **연결 쌍 중복과 재연결 폭주:** 양쪽이 동시에 연결하거나 한쪽이 재시작해 죽은 연결이 남아도, 연결은 하나로 수렴하고 닫고 다시 여는 일이 반복되면 안 된다. → Task 3 `testCoveredEndpointIsNotRedialedUntilKeptConnectionEnds`, Task 4 `testNewerConnectionReplacesStaleOne`.
4. **광장이 닫힌 동안:** 팀원이 돌아다녀도 그림을 받거나 장면을 만들지 않는다. 다시 열면 지금 상태로 보인다. → Task 8 `testClosedPlazaLoadsNoSprites`, `testReopenShowsCurrentMembers`.
5. **한글 입력 상태:** 한글 입력기에서 P는 `ㅔ`로 들어온다. 키는 `characters`가 아니라 `keyCode`로 판정한다. → Task 9 `testEmoteKeysWorkWithHangulInput`, Task 12 `testPhotoKeyWorksWithHangulInput`.

---

### Task 1: 메시지 형식 확장

**Files:**
- Modify: `Sources/PokeTokenBar/Team/TeamModels.swift`, `Sources/PokeTokenBar/Team/TeamWire.swift`, `Sources/PokeTokenBar/Team/Plaza/PlazaWalker.swift:4`
- Test: `Tests/PokeTokenBarTests/TeamWireTests.swift`

**Interfaces:**
- Produces:
  - `enum PlazaDirection: String, CaseIterable, Codable, Sendable`
  - `TeamMonSummary`에 `var gender: PokemonGender?` 추가
  - `struct TeamPresence: Codable, Equatable, Sendable`: `nickname: String`, `character: TeamMonSummary`, `inPlaza: Bool`, `tile: TilePoint?`, `facing: PlazaDirection?`, `isWalking: Bool`. 시각 필드는 두지 않는다.
  - `enum TeamEmoteKind: String, Codable, CaseIterable, Sendable { case heart, lol, party, exclaim, question }`, `var notifiesTarget: Bool`(heart, lol, party만 true)
  - `struct TeamEmote: Codable, Equatable, Sendable`: `kind`, `targetMemberID: String?`
  - `TeamMessage`에 `.presence(TeamPresence)`, `.emote(TeamEmote)` 추가
  - `TeamWire.protocolVersion`은 1 그대로다. 아직 배포 전이라 호환을 지킬 대상이 없다(스펙 4장).
- `TeamHello.current`는 광장 캐릭터를 뜻한다. 주석으로 밝힌다.

- [ ] **Step 1: 실패하는 테스트 작성**

  ```swift
  func testPresenceRoundTrip() { /* presence 인코딩 → FrameDecoder → 같은 값 */ }
  func testEmoteRoundTrip() { /* target 있음/없음 둘 다 */ }
  func testNotifyingEmotesAreOnlyHeartLolParty() { /* exclaim, question은 false */ }
  func testPresenceJSONHasOnlyPlazaFields() {
      // JSON 키 집합이 정확히 nickname, character, inPlaza, tile, facing, isWalking
  }
  func testWireJSONCarriesNoUsageOrHostWords() {
      // 모든 메시지 종류를 인코딩해 소문자로 바꾼 뒤 token, cost, usage, limit, progress, host가 없음
  }
  ```

- [ ] **Step 2: 실패 확인** — Run: `swift test --filter TeamWireTests` / Expected: FAIL(컴파일 오류)
- [ ] **Step 3: 구현** — 위 Interfaces대로 추가한다. 다른 파일에서 `TeamMonSummary(...)`를 부르는 곳은 `gender`를 넘긴다.
- [ ] **Step 4: 통과 확인** — Run: `swift test --filter 'TeamWireTests|TeamEventTests|PlazaWalkerTests|<규칙 검사 15개>'` / Expected: PASS
- [ ] **Step 5: Commit** — `feat(team): add presence and emote messages`

### Task 2: 소식 저장소 — 반응 안 읽음과 초기화

**Files:**
- Modify: `Sources/PokeTokenBar/Team/TeamFeedStore.swift`
- Test: `Tests/PokeTokenBarTests/TeamFeedStoreTests.swift`

**Interfaces:**
- Produces:
  - 반응에 `receivedAt`을 저장한다(`StoredReaction`). 파일 `version`은 그대로다. 배포 전이라 옛 파일은 기존 `.corrupt` 경로로 치워도 된다.
  - `unreadCount`: 남이 쓴 소식 중 `receivedAt > lastReadAt` + **내 소식에 남이 단 반응** 중 `receivedAt > lastReadAt`
  - `func reset()`: 소식, 반응, 읽음 표시를 모두 지우고 저장한다

- [ ] **Step 1: 실패하는 테스트 작성**

  ```swift
  func testReactionOnMyEventCountsAsUnread() { /* 내 소식 + 남의 반응 → unreadCount 1 */ }
  func testReactionOnOthersEventDoesNotCount() { /* 남의 소식(읽음 처리됨) + 다른 사람 반응 → 0 */ }
  func testMyOwnReactionDoesNotCount() { /* 내 소식 + 내 반응 → 0 */ }
  func testMarkAllReadClearsEventsAndReactions() { /* → 0, 이후 새 반응 → 1 */ }
  func testUnreadReactionSurvivesReload() { /* 다시 불러와도 1 */ }
  func testResetClearsEverythingAndPersists() { /* reset 후 새 스토어에서 events, reactionIDs 모두 비어 있음 */ }
  ```

- [ ] **Step 2: 실패 확인** — Run: `swift test --filter TeamFeedStoreTests` / Expected: FAIL
- [ ] **Step 3: 구현**
- [ ] **Step 4: 통과 확인** — Run: `swift test --filter 'TeamFeedStoreTests|<규칙 검사 15개>'` / Expected: PASS
- [ ] **Step 5: Commit** — `feat(team): count reactions on my news as unread`

### Task 3: Bonjour + TLS-PSK 전송 계층

**Files:**
- Create: `Sources/PokeTokenBar/Team/TeamDialPlanner.swift`, `Sources/PokeTokenBar/Team/TeamTransport.swift`
- Test: `Tests/PokeTokenBarTests/TeamDialPlannerTests.swift`, `Tests/PokeTokenBarTests/TeamTransportTests.swift`
- Modify: `scripts/test-gate.sh` (`LOGIC_CORE`에 `TeamDialPlanner.swift` 추가)

**Interfaces:**
- Consumes: `TeamCode.pskKey`, `TeamCode.pskIdentity`, `TeamMessage`, `TeamWire`
- Produces:
  - `typealias TeamPeerID = String`: 연결마다 새 UUID. 멤버 ID가 아니다.
  - `@MainActor protocol TeamTransporting: AnyObject`
    - `var onPeerConnected: ((TeamPeerID, _ initiatedByMe: Bool) -> Void)? { get set }`
    - `var onPeerDisconnected: ((TeamPeerID) -> Void)? { get set }`
    - `var onMessage: ((TeamPeerID, TeamMessage) -> Void)? { get set }`
    - `func start(code: TeamCode)`, `func stop()`, `func send(_ m: TeamMessage, to peer: TeamPeerID)`
    - `func disconnect(_ peer: TeamPeerID, coveredBy kept: TeamPeerID?)`: `kept`가 있으면 그 연결이 살아 있는 동안 같은 엔드포인트로 다시 연결하지 않는다
  - `struct TeamDialPlanner` (순수, 네트워크 없음)
    - `mutating func discovered(_ name: String)`, `mutating func lost(_ name: String)`
    - `mutating func dialStarted(_ name: String, peer: TeamPeerID)`
    - `mutating func connectionEnded(peer: TeamPeerID, handshakeFailed: Bool, now: Date)`
    - `mutating func cover(peer: TeamPeerID, by kept: TeamPeerID)`
    - `func dueDials(now: Date) -> [String]`: 찾았고, 진행 중인 연결이 없고, 덮이지 않았고, 재시도 금지가 끝난 이름
  - `@MainActor final class BonjourTeamTransport: TeamTransporting`
    - `static let serviceType = "_ptbteam._tcp"`
    - `static func parameters(code: TeamCode) -> NWParameters`: `scripts/team-probe.swift`의 `makeParameters`와 같은 암호군(`TLS_PSK_WITH_AES_128_GCM_SHA256`), TLS 1.2 상한. `includePeerToPeer = false`.
    - `init(advertise: Bool = true)`: 테스트는 false로 만들고 `connect(to:)`로 직접 붙는다
    - `func connect(to endpoint: NWEndpoint)`, `var listenerPort: NWEndpoint.Port?`
- 동작:
  - 큐는 `.main`이고 콜백은 `MainActor.assumeIsolated`로 넘어온다. 오가는 양이 적다.
  - 시작마다 인스턴스 이름을 `"ptb-"` + 무작위 16진수 12자로 만든다. 자기 이름은 탐색 결과에서 뺀다.
  - `onPeerConnected`는 `.ready`(TLS가 끝난 뒤)에 한 번만 부른다.
  - 발신 연결의 `.waiting`은 재시도를 기다리지 말고 실패로 본다: 취소하고 `handshakeFailed: true`로 알린다. 다른 팀 코드의 Mac에 붙으면 여기로 온다. `.ready` 전에 10초가 지나도 같다.
  - 받은 데이터는 `FrameDecoder`로 풀고 `WireError`가 나면 그 연결을 끊는다.
  - 15초마다, 그리고 새 엔드포인트를 찾을 때마다 `dueDials`를 연결한다.
  - `stop()` 뒤에는 콜백이 오지 않는다(세대 번호로 막는다).
  - `NSWorkspace.willSleepNotification`에 `stop`, `didWakeNotification`에 `start`. `NetworkReachabilityMonitor.onReconnected`에 재시작(`@Sendable`이므로 `Task { @MainActor in … }`로 넘어온다). `NWListener`가 실패하면 5초 뒤 재시작.

- [ ] **Step 1: 실패하는 테스트 작성**

  ```swift
  // TeamDialPlannerTests
  func testDiscoveredEndpointIsDialedOnce() { /* discovered → dueDials [a] → dialStarted → [] */ }
  func testEndedConnectionIsRedialed() { /* connectionEnded(false) → dueDials [a] */ }
  func testFailedHandshakeWaitsCooldown() { /* 59초 → [], 60초 → [a] */ }
  func testCoveredEndpointIsNotRedialedUntilKeptConnectionEnds() {
      // a로 건 p1이 끝나고 cover(p1, by: p2) → []. p2가 끝나면 → [a]
  }
  func testCoverOrderDoesNotMatter() { /* cover 뒤 connectionEnded(p1)여도 [] */ }
  func testLostEndpointIsNotDialed() { /* lost → [] */ }

  // TeamTransportTests (루프백, Bonjour 안 씀. CI에서도 돈다)
  func testSameCodePeersExchangeMessagesOverLoopback() async throws { /* 양방향, 5초 제한. b는 initiatedByMe true, a는 false */ }
  func testDifferentCodeNeverDeliversMessages() async throws { /* 3초 안에 onPeerConnected·onMessage 없음 */ }
  func testMalformedFrameDisconnects() async throws { /* 같은 PSK의 NWConnection으로 쓰레기를 보내면 a.onPeerDisconnected */ }
  func testStopSilencesCallbacks() async throws { /* stop 뒤 onMessage 0회 */ }
  ```

- [ ] **Step 2: 실패 확인** — Run: `swift test --filter 'TeamDialPlannerTests|TeamTransportTests'` / Expected: FAIL
- [ ] **Step 3: 구현**
- [ ] **Step 4: 통과 확인** — Run: `swift test --filter 'TeamDialPlannerTests|TeamTransportTests|<규칙 검사 15개>'` / Expected: PASS
- [ ] **Step 5: Commit** — `feat(team): add Bonjour transport with team-code TLS-PSK`

### Task 4: TeamSession 조율자

**Files:**
- Create: `Sources/PokeTokenBar/Team/TeamSession.swift`
- Create (테스트 타깃): `Tests/PokeTokenBarTests/FakeTeamTransport.swift`
- Test: `Tests/PokeTokenBarTests/TeamSessionTests.swift`
- Modify: `scripts/test-gate.sh` (`LOGIC_CORE`에 `TeamSession.swift` 추가)

**Interfaces:**
- Consumes: Task 1–3
- Produces:
  - `struct TeamMemberState: Equatable, Sendable`: `memberID`, `nickname`, `character: TeamMonSummary`, `inPlaza`, `tile: TilePoint?`, `facing: PlazaDirection?`, `isWalking`
  - `@MainActor @Observable final class TeamSession`
    - `init(settings: TeamSettings, feed: TeamFeedStore, transport: TeamTransporting, profileProvider: @escaping () -> TeamMemberProfile, clock: @escaping () -> Date = Date.init)`
    - `private(set) var members: [String: TeamMemberState]`: 나를 뺀, 연결된 팀원만
    - `private(set) var hasIncompatiblePeer: Bool`, `var hasOnlinePeers: Bool`
    - `var onBigEvent: ((TeamEvent) -> Void)?`: `live`, 처음 받음, `isBig`, `occurredAt != nil`. 내 소식도 부른다
    - `var onReactionToMine: ((TeamReaction, TeamEvent) -> Void)?`: `live`, 처음 받음
    - `var onEmote: ((_ memberID: String, TeamEmote) -> Void)?`
    - `func applySettings()`, `func tick()`
    - `func updateCharacter(_ c: TeamMonSummary)`: 바뀌면 바로 모두에게 보낸다
    - `func updatePlazaPosition(inPlaza: Bool, tile: TilePoint?, facing: PlazaDirection?, isWalking: Bool)`: 바뀌면 바로 보낸다
    - `func publish(_ e: CompanionTeamEvent)`, `func react(to eventID: String, kind: TeamReactionKind)`
    - `func sendEmote(_ kind: TeamEmoteKind, target: String?)`
    - `func requestProfile(memberID: String, timeout: Duration = .seconds(5)) async -> TeamMemberProfile?`
  - 테스트용 `FakeTransportHub`: 여러 `FakeTeamTransport`를 메모리에서 잇는다. 연결, 조용히 끊기(상대는 모름), 끊기를 테스트가 직접 일으킨다. `disconnect` 호출을 기록한다.
- 메시지 규칙:
  - **연결:** 연결 표에 넣고 `hello`를 보낸다. `hello` 전에 온 다른 메시지는 무시한다.
  - **`hello` 수신:**
    - 버전이 다르면 `hasIncompatiblePeer = true`로 두고 끊는다. 멤버 ID가 내 것이면 끊는다.
    - 같은 멤버의 연결이 둘 이상이면 **멤버 ID가 작은 쪽이 시작한 연결 중 가장 새것**을 남기고, 그런 연결이 없으면 가장 새것을 남긴다. 나머지는 `disconnect(_, coveredBy: 남긴 것)`. 양쪽이 같은 결론을 낸다.
    - 남긴 연결에 `inventory`와 `presence`를 보낸다.
  - **`presence` 수신:** 멤버 상태를 바꾼다. 닉네임은 `TeamSettings.validNickname`을 통과할 때만 바꾼다.
  - **`inventory` 수신:** 상대에게 없는 소식과 반응을 `live: false`로 100개씩 나눠 보낸다.
  - **`events`/`reactions` 수신:** `feed.insert`가 true인 항목만 콜백 대상이다. 다시 전달하지 않는다. 모두 직접 연결이고 5분마다 인벤토리를 맞춘다.
  - **`emote` 수신:** `onEmote`만 부른다.
  - **`profileRequest` 수신:** `.profile(profileProvider())`로 답한다. **`profile` 수신:** 기다리는 요청에 넘긴다. 저장하지 않는다.
  - **연결 해제:** 그 멤버의 연결이 하나도 안 남으면 `members`에서 지운다. 기다리던 카드 요청은 nil로 끝낸다. 같은 연결의 해제가 두 번 와도 괜찮아야 한다.
  - **`tick()`:** 30초 동안 아무것도 안 온 연결을 끊는다. 10초 동안 보낸 게 없으면 `presence`를 보낸다. 5분마다 `inventory`를 보낸다.
  - **`applySettings()`:**
    - 준비되면 시작, 아니면 멈추고 멤버를 비운다.
    - 코드가 다른 값으로 바뀌거나 nil이 되면 `feed.reset()` 후 재시작한다. 켜기만 끈 경우에는 소식을 지우지 않는다. 앱을 켤 때의 코드를 기준으로 삼아 시작 때는 지우지 않는다.
    - 닉네임이 바뀌면 `presence`를 보낸다.
  - **`publish`:** 준비 안 됐으면 무시. `TeamEventFactory.make(…, hasOnlinePeers:)` → `feed.insert` → 모두에게 `.events([e], live: true)`, 그리고 조건이 맞으면 `onBigEvent`.
  - **`react`:** `feed.insert`가 true일 때만 모두에게 보낸다.

- [ ] **Step 1: 실패하는 테스트 작성**

  ```swift
  func testHelloThenInventorySyncFillsMissingEvents() { /* A에 소식 2개, B 빔 → 연결 → B.feed 2개, B.onBigEvent 0회 */ }
  func testLivePublishReachesOthersOnce() { /* A.publish(hatch) → B.onBigEvent 1회, A.onBigEvent 1회 */ }
  func testDuplicateEventFromTwoPeersFiresOnce() { /* live와 동기화로 두 번 받아도 B.onBigEvent 1회, feed 1행 */ }
  func testEvolveFiresNoBigEvent() { /* onBigEvent 0, feed 1 */ }
  func testOfflinePublishIsDayOnlyAndSyncedLaterQuietly() { /* 팀원 없이 publish → occurredAt nil → 연결 후 B.feed 1, 콜백 0 */ }
  func testReactionToMyEventCallsBackOnce() { /* B.react → A.onReactionToMine 1회, C.feed 반응 1 */ }
  func testReactionWhileAuthorOfflineArrivesLaterQuietly() { /* 재연결 후 A.feed 반응 1, 콜백 0 */ }
  func testReconnectResyncsWithoutDuplicates() { /* 끊긴 동안 A가 2개 publish → 재연결 → B.feed 정확히 +2 */ }
  func testProtocolMismatchMarksIncompatibleAndDisconnects() { … }
  func testOwnMemberIDIsDisconnected() { … }
  func testDuplicateConnectionsKeepOneAndBothSidesAgree() { /* 양쪽 동시 연결 → 양쪽이 같은 연결을 남김, members 1 */ }
  func testNewerConnectionReplacesStaleOne() { /* 재시작 흉내: 죽은 연결 + 새 연결 → 새것을 남기고 옛것은 coveredBy */ }
  func testOnlyConnectionIsKeptEvenIfNotPreferred() { /* 멤버 ID가 큰 쪽이 건 연결 하나뿐 → 끊지 않음 */ }
  func testSilentPeerIsDroppedAfterTimeout() { /* 시계를 29초 → 남음, 31초 → members에서 사라짐 */ }
  func testHeartbeatSendsPresence() { /* 시계 11초 뒤 tick → presence 1회. 9초면 0회 */ }
  func testCharacterChangeIsSentImmediately() { /* updateCharacter → B.members[A].character가 tick 없이 바뀜 */ }
  func testSameCharacterIsNotResent() { … }
  func testPositionChangeReachesOthers() { … }
  func testLeavingPlazaMarksAway() { /* inPlaza false, tile nil */ }
  func testDisconnectRemovesMember() { … }
  func testEmoteIsNeitherStoredNorForwarded() { /* A→B 전송, B.feed 변화 없음, C는 B를 통해 받지 않음 */ }
  func testProfileRoundTrip() async { /* B.requestProfile(A) == A.profileProvider() */ }
  func testProfileTimesOut() async { /* 응답 없음, timeout 50ms → nil */ }
  func testProfileRequestEndsWhenMemberLeaves() async { /* nil */ }
  func testDisabledSessionPublishesNothing() { … }
  func testChangingTeamCodeClearsFeed() { /* 코드 교체 → feed 비고 transport 재시작 */ }
  func testLeavingTeamClearsFeed() { /* leaveTeam → feed 빔 */ }
  func testTurningOffKeepsFeed() { /* isEnabled false → feed 유지, 멤버 빔 */ }
  func testLaunchDoesNotClearFeed() { /* 코드가 이미 있는 채로 시작 → 유지 */ }
  func testNicknameFromPeerIsValidated() { /* 13자 닉네임 presence → 이전 닉네임 유지 */ }
  ```

- [ ] **Step 2: 실패 확인** — Run: `swift test --filter TeamSessionTests` / Expected: FAIL
- [ ] **Step 3: 구현**
- [ ] **Step 4: 통과 확인** — Run: `swift test --filter 'TeamSessionTests|TeamFeedStoreTests|<규칙 검사 15개>'` / Expected: PASS
- [ ] **Step 5: Commit** — `feat(team): add team session sync and presence`

### Task 5: 프로필, 런타임, 앱 연결

**Files:**
- Create: `Sources/PokeTokenBar/Team/TeamProfileBuilder.swift`, `Sources/PokeTokenBar/Team/TeamRuntime.swift`
- Modify: `Sources/PokeTokenBar/PokeTokenBarApp.swift`(런타임 생성, `.environment`), `Sources/PokeTokenBar/Team/UI/TeamSettingsSection.swift`(다른 버전 안내), `Sources/PokeTokenBar/Team/TeamLocalization.swift`, `Sources/PokeTokenBar/Team/Plaza/PlazaRoster.swift`, `scripts/test-gate.sh`
- Test: `Tests/PokeTokenBarTests/TeamProfileBuilderTests.swift`, `Tests/PokeTokenBarTests/TeamRuntimeTests.swift`

**Interfaces:**
- Consumes: `TeamSession`, `CompanionStore.onTeamEvent`, `CompanionStore.representativeSubject`, `PlazaRoster.myEntry(companion:teamSettings:)`
- Produces:
  - `enum TeamProfileBuilder`: `static func profile(memberID: String, nickname: String, state: CompanionState, dexSpecies: [CompanionStore.DexSpecies], speciesName: (Int) -> String?) -> TeamMemberProfile`
    - `current`: `state.active`가 없으면 알(speciesID nil), 있으면 `active.currentID`와 `active.displaysShiny`. 위장 메타몽은 위장 종이 그대로 나간다.
    - `dex`: `dexSpecies`를 옮긴다(`id`, `form`, `name`, `rarity`, `isShiny → hasShiny`, `hasNormal`). 진행률이나 사용량 필드는 없다.
  - `PlazaRoster.character(entry: PlazaRosterEntry, subject: CompanionStore.RepresentativeSubject) -> TeamMonSummary`: 이름과 성별은 내 칸과 같은 규칙을 쓴다
  - `@MainActor final class TeamRuntime`
    - `init(settings: TeamSettings, companion: CompanionStore, transport: TeamTransporting = BonjourTeamTransport())`
    - `let feed: TeamFeedStore`, `let session: TeamSession`
    - `weak var plaza: PlazaWindowController?`
    - `func start()`
  - `start()`가 하는 일:
    - `companion.onTeamEvent`를 `session.publish`에 잇는다
    - 설정(`isEnabled`, `code`, `nickname`) 관찰 → `session.applySettings()`. 준비되지 않게 되면 `plaza?.closeIfOpen()`(1부 이월 항목).
    - 캐릭터 입력 관찰 → `session.updateCharacter`. 먼저 다시 등록하고 일한다(`observePlaza`와 같은 패턴).
    - 5초 주기 `session.tick()`
    - 준비된 동안 `ProcessInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason:)`를 쥔다. App Nap으로 하트비트가 늦어 팀원 화면에서 사라지는 일을 막는다. 잠자기는 막지 않는다. 기존 패턴은 `UsageStore.swift:935`.
  - `PlazaWindowController.closeIfOpen()`: 창이 있으면 `performClose`
  - `L.teamIncompatiblePeer`: "다른 버전을 쓰는 팀원이 있어요. 모두 최신 버전으로 업데이트해 주세요"
- `AppDelegate`에서 런타임을 만들고 `plaza` 생성 뒤 `runtime.plaza = plaza`, `runtime.start()`를 부른다. 설정 화면이 `session`을 읽도록 `.environment`를 하나 더한다. 이 밖의 로직을 `AppDelegate`에 넣지 않는다.

- [ ] **Step 1: 실패하는 테스트 작성**

  ```swift
  // TeamProfileBuilderTests
  func testEggProfileHasNoSpecies() { … }
  func testDisguisedDittoShowsDisguiseWithoutShiny() { … }
  func testProfileJSONHasNoUsageNumbers() { /* Task 1과 같은 금지어 */ }

  // TeamRuntimeTests (FakeTeamTransport)
  func testCompanionEventIsPublished() { /* onTeamEvent 호출 → transport로 .events 전송 */ }
  func testRepresentativeChangeSendsPresenceImmediately() { /* 대표 종 변경 → tick 없이 presence, character 반영 */ }
  func testSettingsChangeRestartsTransport() { /* 코드 교체 → stop 후 start */ }
  func testNotReadyClosesPlaza() { … }
  ```

- [ ] **Step 2: 실패 확인** — Run: `swift test --filter 'TeamProfileBuilderTests|TeamRuntimeTests'` / Expected: FAIL
- [ ] **Step 3: 구현.** `LOGIC_CORE`에 `TeamProfileBuilder.swift`, `TeamRuntime.swift`를 더한다.
- [ ] **Step 4: 통과 확인** — Run: `swift test --filter 'TeamProfileBuilderTests|TeamRuntimeTests|TeamSessionTests|StatusItemMenuTests|<규칙 검사 15개>'`, `swift build` / Expected: PASS
- [ ] **Step 5: Commit** — `feat(team): wire the team session into the app`

### Task 6: 캐릭터 노드 묶음 분리 (동작 변화 없음)

**Files:**
- Create: `Sources/PokeTokenBar/Team/Plaza/PlazaActor.swift`
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaScene.swift`
- Test: 기존 Plaza 테스트 그대로

**Interfaces:**
- Consumes: `PlazaPixelSnap`(1부 마무리에서 만든 도우미), `PlazaGroundShadow`, `PlazaNamePlate`, `PlazaPose`
- Produces:
  - `@MainActor final class PlazaActor`
    - `init(name: String, color: CGColor)`
    - `func attach(world: SKNode, camera: SKCameraNode)`, `func detach()`
    - `func setFrames(_ f: PlazaCharacterFrames)`, `func setName(_ name: String, color: CGColor)`
    - `func animate(by dt: TimeInterval, useBack: Bool)`
    - `func place(foot: CGPoint, pose: PlazaSpriteChoice, in context: PlazaActorContext)`
    - `struct PlazaActorContext`: `worldHeight`, `cameraPosition`, `zoom`, `backing`, `viewport`
  - 겹침 순서: 그림자 `zPosition` 0.5, 그림 `1 + footY / worldHeight`(화면 아래쪽이 앞), 이름표 10
- `PlazaScene`에서 그림, 그림자, 이름표, 프레임 순환, 텍스처 캐시를 옮긴다. 내 캐릭터는 `PlazaActor` 하나다. 기존 테스트용 값(`groundShadowSize`, `characterX`, `characterY`, `namePlatePosition`, `isNamePlateVisible`, `backingOverride` 등)은 장면에 남겨 내 캐릭터로 위임한다.

- [ ] **Step 1: 기준 확인** — Run: `swift test --filter 'Plaza|<규칙 검사 15개>'` / Expected: PASS(옮기기 전 개수를 적어 둔다)
- [ ] **Step 2: 옮기기.** 함께 `PlazaWindowController.mapImage`를 정적 캐시로 옮긴다. 지금은 `prepareScene`을 부르는 테스트마다 지도를 약 1초씩 다시 그려 `PlazaWindowTests`만 30초가 걸린다. 앱에서는 지도가 하나라 동작이 같다.
- [ ] **Step 3: 통과 확인** — 같은 명령으로 같은 개수가 통과한다. 테스트 파일은 고치지 않는다.
- [ ] **Step 4: Commit** — `refactor(plaza): extract PlazaActor from the scene`

### Task 7: 팀원 움직임과 표적 (순수 로직)

**Files:**
- Create: `Sources/PokeTokenBar/Team/Plaza/PlazaRemoteMotion.swift`, `Sources/PokeTokenBar/Team/Plaza/PlazaShelterWanderer.swift`, `Sources/PokeTokenBar/Team/Plaza/PlazaTargeting.swift`
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaWalker.swift`(칸 이동 계산 공개), `Sources/PokeTokenBar/Team/Plaza/PlazaNameColor.swift`(FNV 해시 공개), `scripts/test-gate.sh`
- Test: `Tests/PokeTokenBarTests/PlazaRemoteMotionTests.swift`, `Tests/PokeTokenBarTests/PlazaTargetingTests.swift`

**Interfaces:**
- Produces:
  - `struct PlazaRemoteMotion: Sendable`
    - `init(tile: TilePoint, facing: PlazaDirection)`
    - `private(set) var tile: TilePoint`: 도착할 칸
    - `var facing: PlazaDirection`, `var senderIsWalking: Bool`, `var isWalking: Bool`(한 칸을 가는 중이거나 대기 칸이 있거나 `senderIsWalking`)
    - `var footPoint: CGPoint`: `PlazaWalker.footPoint`와 같은 공식
    - `mutating func moveTo(_ t: TilePoint)`: 옆 칸이면 대기열에 넣는다. 옆 칸이 아니거나 대기열이 3칸을 넘으면 바로 옮긴다
    - `mutating func snap(to t: TilePoint)`, `mutating func advance(by dt: TimeInterval)`: 한 칸에 `PlazaWalker.stepDuration`
  - `struct PlazaShelterWanderer: Sendable`
    - `init(memberID: String, shelter: [TilePoint])`: 첫 칸과 난수 씨앗은 멤버 ID의 FNV 해시로 정한다(Swift `hashValue` 금지)
    - `private(set) var tile: TilePoint`
    - `mutating func advance(by dt: TimeInterval) -> TilePoint?`: 4–10초마다 옆의 쉼터 칸으로 옮기고 그 칸을 돌려준다. 옆에 쉼터 칸이 없으면 그대로 있는다
  - `enum PlazaTargeting`
    - `static func facingTile(from: TilePoint, facing: PlazaDirection) -> TilePoint`
    - `static func member(from: TilePoint, facing: PlazaDirection, members: [String: TilePoint]) -> String?`: 바라보는 칸을 먼저, 없으면 같은 칸. 여럿이면 ID가 작은 쪽.

- [ ] **Step 1: 실패하는 테스트 작성**

  ```swift
  func testAdjacentMoveTakesOneStep() { /* 0.1초 뒤 중간, 0.2초 뒤 도착, 이후 isWalking false */ }
  func testQueuedMovesPlayInOrder() { /* 대각선으로 가로지르지 않는다 */ }
  func testDistantMoveSnaps() { /* 2칸 이상 떨어진 칸은 즉시 */ }
  func testLongQueueCatchesUp() { /* 4칸째가 들어오면 그 칸으로 즉시 */ }
  func testWandererStartsAtSameTileOnEveryMac() { /* 같은 ID → 같은 첫 칸 */ }
  func testWandererStaysInShelter() { /* 긴 시간 advance → 항상 쉼터 칸, 옆 칸으로만 */ }
  func testWandererWithOneShelterTileStays() { … }
  func testTargetPrefersFacingTile() { … }
  func testTargetFallsBackToSameTile() { … }
  func testTargetIsNilWhenNobodyNear() { … }
  ```

- [ ] **Step 2: 실패 확인** — Run: `swift test --filter 'PlazaRemoteMotionTests|PlazaTargetingTests'` / Expected: FAIL
- [ ] **Step 3: 구현.** 세 파일을 `LOGIC_CORE`에 더한다.
- [ ] **Step 4: 통과 확인** — Run: `swift test --filter 'PlazaRemoteMotionTests|PlazaTargetingTests|PlazaWalkerTests|PlazaNameColorTests|<규칙 검사 15개>'` / Expected: PASS
- [ ] **Step 5: Commit** — `feat(plaza): add remote motion, shelter wandering and targeting`

### Task 8: 광장에 팀원 표시와 참여자 목록 (사용자 확인)

**Files:**
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaScene.swift`, `Sources/PokeTokenBar/Team/Plaza/PlazaWindowController.swift`, `Sources/PokeTokenBar/Team/Plaza/PlazaRoster.swift`, `Sources/PokeTokenBar/Team/UI/PlazaRosterView.swift`, `Sources/PokeTokenBar/Team/TeamLocalization.swift`, `Sources/PokeTokenBar/PokeTokenBarApp.swift`(`session` 넘기기), `scripts/plaza-dev.sh`
- Test: `Tests/PokeTokenBarTests/PlazaMembersTests.swift`, `Tests/PokeTokenBarTests/PlazaRosterTests.swift`

**Interfaces:**
- Consumes: `TeamSession.members`, `PlazaActor`, `PlazaRemoteMotion`, `PlazaShelterWanderer`, `PlazaCharacterLoader`, `PlazaNameColor`
- Produces:
  - `struct PlazaSceneMember: Equatable, Sendable`: `memberID`, `nickname`, `isAway`, `tile: TilePoint?`, `facing: PlazaDirection`, `isWalking`
  - `PlazaScene`:
    - `func applyMembers(_ members: [PlazaSceneMember])`: 없는 멤버의 액터를 지우고 새 멤버의 액터를 만든다
    - `func setMemberFrames(_ memberID: String, _ frames: PlazaCharacterFrames)`
    - `var onLocalPositionChange: ((TilePoint, PlazaDirection, Bool) -> Void)?`: `update`에서 칸, 방향, 걷는 중 여부가 바뀔 때만 부른다
    - `var memberTiles: [String: TilePoint]`: 내 화면에 보이는 자리(자리 비운 팀원 포함). 표적 찾기에 쓴다
    - 테스트용 `func memberFoot(_ id: String) -> CGPoint?`, `func memberName(_ id: String) -> String?`
  - `PlazaWindowController`:
    - `init`에 `session: TeamSession? = nil` 추가
    - `prepareScene`에서 `session.updatePlazaPosition(inPlaza: true, …)`와 멤버 관찰을 시작한다. `handleClose`에서 `inPlaza: false`로 보내고 관찰을 끝낸다(세대 번호).
    - 멤버의 캐릭터가 바뀌면 그 멤버만 `loader.frames(for:)`로 다시 받는다. 멤버별 세대 번호로 낡은 결과를 버린다.
  - `PlazaRoster.entries(me: PlazaRosterEntry?, members: [TeamMemberState]) -> [PlazaRosterEntry]`: 정렬은 기존 `sorted`
  - `PlazaRoster.capacity(forHeight: CGFloat) -> Int`, `PlazaRoster.visible(_ entries: [PlazaRosterEntry], capacity: Int) -> (shown: [PlazaRosterEntry], hidden: Int)`: 넘치면 마지막 칸 자리를 "외 N명" 줄로 쓴다. 목록은 입력을 받지 않아 스크롤할 수 없다. 정렬상 잘리는 쪽은 자리 비운 팀원이다.
  - `PlazaRosterModel.capacity`: `windowDidResize`에서 정한다
  - `L.plazaAwaySuffix`("zZ"), `L.plazaRosterMore(_ n: Int)`("외 \(n)명")
- 동작:
  - 자리 비운 팀원은 `PlazaShelterWanderer`의 칸으로 움직이고 이름 뒤에 " zZ"를 붙인다. 접속 중과 자리 비움이 바뀔 때는 `snap`으로 바로 옮긴다(스펙 5.5 재량).
  - 받은 칸이 지도 밖이거나 걸을 수 없으면 쉼터 칸을 쓴다. 다른 버전의 지도나 잘못된 값 때문에 나무 위에 서지 않게 한다.
  - 이름 색은 `PlazaNameColor.color(forMemberID:)`, 이름표와 그림자는 내 캐릭터와 같다.
  - 팀원과 부딪히지 않는다. 내 이동의 `canEnter`에 팀원을 넣지 않는다.
  - 창이 가려져 장면이 멈춘 동안에도 `applyMembers`는 값만 받는다. 다시 그릴 때 `moveTo`의 "대기열 초과면 바로 옮김"으로 따라잡는다.
- `scripts/plaza-dev.sh [2]`: 인자 2를 주면 상태 폴더를 `ptb-plaza-dev-2`로 쓴다. `swift run` 대신 `swift build` 후 `.build/debug/PokeTokenBar`를 실행해 두 개를 동시에 띄울 수 있게 한다. 세이브는 두 폴더 모두 실제 세이브에서 복사한다.

- [ ] **Step 1: 실패하는 테스트 작성**

  ```swift
  // PlazaMembersTests (FakeTransportHub로 세션 두 개를 잇고, prepareScene으로 창 없이)
  func testOnlineMemberAppearsAtTheirTile() { … }
  func testMemberMovesWhenPresenceChanges() { /* advance 후 foot이 새 칸 */ }
  func testAwayMemberStandsInShelterWithZzName() { … }
  func testMemberBecomingOnlineSnapsToTheirTile() { … }
  func testDisconnectedMemberDisappears() { /* 액터와 목록 칸 모두 */ }
  func testInvalidRemoteTileFallsBackToShelter() { /* 나무 칸, 지도 밖 */ }
  func testLowerMemberDrawsInFront() { /* y가 큰 쪽 zPosition이 크다 */ }
  func testMyWalkIsNotBlockedByMembers() { /* 팀원이 선 칸으로 걸어 들어갈 수 있다 */ }
  func testMemberNameUsesMemberColor() { … }
  func testCharacterChangeReloadsOnlyThatMember() { /* 가짜 fetcher 호출 수 */ }
  func testStaleMemberSpriteLoadIsDiscarded() { /* 느린 로드 뒤 새 캐릭터가 이긴다 */ }
  func testOpeningSendsPositionAndClosingSendsAway() { /* 상대 세션의 members로 확인 */ }
  func testClosedPlazaLoadsNoSprites() { /* 창 닫힘 + 팀원 이동·캐릭터 변경 → 가짜 fetcher 호출 0 */ }
  func testReopenShowsCurrentMembers() { /* 닫힌 동안 온 멤버가 다시 열면 보인다 */ }

  // PlazaRosterTests
  func testEntriesSortMeOnlineAway() { … }
  func testAwayEntryHasAwayPresence() { … }
  func testCapacityFitsHeight() { /* 슬롯 44, 간격 4, 헤더 포함 */ }
  func testOverflowShowsMoreRowAndHidesAwayMembers() { /* 10명, capacity 5 → shown 4, hidden 6 */ }
  ```

- [ ] **Step 2: 실패 확인** — Run: `swift test --filter 'PlazaMembersTests|PlazaRosterTests'` / Expected: FAIL
- [ ] **Step 3: 구현**
- [ ] **Step 4: 통과 확인** — Run: `swift test --filter 'Plaza|Team|StatusItemMenuTests|<규칙 검사 15개>'`, `swift build` / Expected: PASS
- [ ] **Step 5: Commit** — `feat(plaza): show teammates on the map and in the roster`
- [ ] **Step 6: 사용자 확인 (사람 필요).** 진행 기록에 남기고 터미널 두 개로 `bash scripts/plaza-dev.sh`, `bash scripts/plaza-dev.sh 2`를 띄운다. 같은 팀 코드를 넣고 다른 닉네임을 쓴다. 사용자가 확인한다: 서로 보이는지, 움직임이 자연스러운지, 창을 닫으면 쉼터로 가서 "zZ"가 붙는지, 목록이 어떻게 보이는지. 의견을 반영한 뒤 다음으로 넘어간다.

### Task 9: 감정 말풍선

**Files:**
- Create: `Sources/PokeTokenBar/Team/Plaza/PlazaEmoteArt.swift`
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaActor.swift`, `PlazaScene.swift`, `PlazaWindowController.swift`, `Sources/PokeTokenBar/Team/TeamRuntime.swift`
- Test: `Tests/PokeTokenBarTests/PlazaEmoteTests.swift`

**Interfaces:**
- Consumes: `PlazaTargeting.member`, `TeamSession.sendEmote`, `TeamSession.onEmote`
- Produces:
  - `enum PlazaEmoteArt`: `static func image(_ kind: TeamEmoteKind, scale: CGFloat) -> CGImage`. 흰 말풍선에 어두운 테두리와 꼬리. ♥ 와 🎉는 코드로 찍은 도트 격자, ㅋㅋ, !, ?는 갈무리 글꼴. 이모지 글꼴을 쓰지 않는다. 한글 "ㅋㅋ"는 `L.plazaEmoteLol`에 둔다.
  - `PlazaActor.showEmote(_ kind: TeamEmoteKind)`: 이름표 위, 카메라 공간, 2.5초. 새 말풍선이 옛것을 바꾼다.
  - `PlazaScene`: `var onEmoteKey: ((TeamEmoteKind) -> Void)?`, `func showEmote(memberID: String?, kind: TeamEmoteKind)`(nil이면 나)
  - `PlazaWindowController`:
    - 키를 받으면 0.3초 제한(`clock` 주입)을 본다. 내 캐릭터에 바로 띄운다. ♥, ㅋㅋ, 🎉면 `PlazaTargeting.member(…, scene.memberTiles)`로 표적을 찾아 `session.sendEmote`로 보낸다. !, ?는 표적 없이 보낸다.
    - `func showEmote(memberID: String, kind: TeamEmoteKind)`: 런타임이 부른다. 창이 닫혀 있으면 아무것도 안 한다.
  - `TeamRuntime`: `session.onEmote` → `plaza?.showEmote`. 알림은 Task 13에서 더한다.
- 키 1–5의 순서는 ♥, ㅋㅋ, 🎉, !, ?이고 `keyCode`로 판정한다.

- [ ] **Step 1: 실패하는 테스트 작성**

  ```swift
  func testEmoteKeysWorkWithHangulInput() { /* keyCode 18, characters "1" 아닌 값이어도 heart */ }
  func testEachEmoteHasArt() { /* 다섯 종류 모두 이미지, 배율 2면 크기 2배 */ }
  func testHeartAtFacingMemberTargetsThem() { /* 상대 세션 onEmote의 target == 상대 ID */ }
  func testHeartAtAwayMemberTargetsThem() { /* 내 화면의 쉼터 자리를 마주 보면 그 팀원이 표적 */ }
  func testHeartWithNobodyNearHasNoTarget() { … }
  func testExclaimNeverTargets() { /* 옆에 있어도 nil */ }
  func testKeyMashIsLimited() { /* 0.1초 간격 3번 → 1회 전송 */ }
  func testReceivedEmoteShowsOverThatMember() { … }
  func testEmoteExpires() { /* 2.5초 뒤 숨김 */ }
  func testEggCanStillEmote() { … }
  ```

- [ ] **Step 2: 실패 확인** — Run: `swift test --filter PlazaEmoteTests` / Expected: FAIL
- [ ] **Step 3: 구현**
- [ ] **Step 4: 통과 확인** — Run: `swift test --filter 'Plaza|Team|<규칙 검사 15개>'` / Expected: PASS
- [ ] **Step 5: Commit** — `feat(plaza): add emote bubbles`

### Task 10: 말 걸기와 팀원 카드

**Files:**
- Create: `Sources/PokeTokenBar/Team/UI/PlazaOverlayView.swift`, `Sources/PokeTokenBar/Team/UI/PlazaCardView.swift`, `Sources/PokeTokenBar/Team/Plaza/PlazaInteraction.swift`
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaScene.swift`, `PlazaWindowController.swift`, `Sources/PokeTokenBar/Team/TeamLocalization.swift`
- Test: `Tests/PokeTokenBarTests/PlazaCardTests.swift`

**Interfaces:**
- Consumes: `TeamSession.requestProfile`, `TeamSession.members`, `PlazaTargeting`, `PlazaIconLoader`
- Produces:
  - `enum PlazaInteraction`: `static func target(from: TilePoint, facing: PlazaDirection, map: PlazaMap, members: [String: TilePoint]) -> PlazaInteractionTarget?`, `enum PlazaInteractionTarget: Equatable { case board, member(String) }`. 바라보는 칸이 소식판이면 `.board`를 먼저 고른다.
  - `@MainActor @Observable final class PlazaOverlayModel`: `var content: PlazaOverlayContent`, `var banner: String?`
  - `enum PlazaOverlayContent: Equatable { case none, card(PlazaCardState), board }`
  - `enum PlazaCardState: Equatable { case loading(TeamMemberState), loaded(TeamMemberState, TeamMemberProfile), failed(TeamMemberState) }`
  - `PlazaScene`:
    - `var onInteractKey: (() -> Void)?`, `var onCloseOverlay: (() -> Void)?`
    - `var isOverlayOpen: Bool`: true면 방향키, 말풍선, 사진 키를 무시하고 눌린 키를 놓는다. Esc와 스페이스는 `onCloseOverlay`만 부른다. Cmd+W는 그대로 창을 닫는다.
  - `PlazaWindowController`:
    - 스페이스 → 대상 찾기 → 카드면 `.loading` → `await requestProfile` → `.loaded` 또는 `.failed`. 세대 번호로 닫힌 뒤 도착한 결과를 버린다.
    - 오버레이 호스팅 뷰는 목록 위에 둔다. `acceptsFirstResponder`는 false로 두어 SKView가 첫 응답자를 유지한다. 마우스(스크롤, 버튼)만 받는다. 닫을 때 `makeFirstResponder(skView)`를 부른다.
- 카드 내용:
  - 닉네임(이름 색), 광장 캐릭터. `profile.current`가 캐릭터와 다르면 둘 다 보여 준다.
  - 도감 격자: 아이콘(`LazyVGrid`, 칸마다 `.task`로 받음), 이로치는 ★, 툴팁에 이름. 읽기 전용, 스크롤 가능.
  - **보유 수, 진행률, 희귀도 합계 같은 숫자를 넣지 않는다.** 경쟁 안티골이다.
  - 받는 동안과 실패 문구는 `L.plazaCardLoading`, `L.plazaCardFailed`.
  - 모양은 참여자 목록과 같은 청록 판, 창 가운데.

- [ ] **Step 1: 실패하는 테스트 작성**

  ```swift
  func testBoardWinsOverMember() { … }
  func testFacingNothingOpensNothing() { /* 스페이스 → content none */ }
  func testSpaceOnMemberLoadsProfile() async { /* loading → loaded */ }
  func testProfileTimeoutShowsFailure() async { … }
  func testResultAfterCloseIsDiscarded() async { /* 닫은 뒤 도착 → none 유지 */ }
  func testEscClosesOverlayNotWindow() { /* onCloseRequest 0회, content none */ }
  func testArrowsBlockedWhileOverlayOpen() { /* 칸 그대로 */ }
  func testHeldKeyReleasedWhenOverlayOpens() { … }
  func testCmdWStillClosesWindow() { … }
  func testAwayMemberCanBeTalkedTo() { … }
  ```

- [ ] **Step 2: 실패 확인** — Run: `swift test --filter PlazaCardTests` / Expected: FAIL
- [ ] **Step 3: 구현**
- [ ] **Step 4: 통과 확인** — Run: `swift test --filter 'Plaza|Team|<규칙 검사 15개>'` / Expected: PASS
- [ ] **Step 5: Commit** — `feat(plaza): open a teammate card by talking to their Pokémon`

### Task 11: 소식판, 연출, 안 읽음 배지

**Files:**
- Create: `Sources/PokeTokenBar/Team/UI/PlazaBoardView.swift`
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaScene.swift`, `PlazaActor.swift`, `PlazaWindowController.swift`, `Sources/PokeTokenBar/Team/UI/PlazaOverlayView.swift`, `Sources/PokeTokenBar/Team/TeamRuntime.swift`, `Sources/PokeTokenBar/Team/TeamLocalization.swift`, `Sources/PokeTokenBar/UI/StatusItemMenu.swift`, `Sources/PokeTokenBar/UI/PopoverView.swift`, `Sources/PokeTokenBar/PokeTokenBarApp.swift`
- Test: `Tests/PokeTokenBarTests/PlazaBoardTests.swift`, `Tests/PokeTokenBarTests/StatusItemMenuTests.swift`

**Interfaces:**
- Consumes: `TeamFeedStore`, `TeamSession.react`, `TeamSession.onBigEvent`, `TeamEvent`
- Produces:
  - `L.teamEventText(_ e: TeamEvent) -> String`. 조사는 기존 `KoreanParticle`을 쓴다. 이 문구를 소식판, 안내, 알림이 함께 쓴다.
    - 부화: "민수의 알에서 이로치 깨봉이가 나왔어요!"(이로치일 때만 "이로치 ")
    - 메타몽 공개: "민수의 포켓몬은 사실 메타몽이었어요!"
    - 졸업: "민수의 깨봉이가 졸업했어요!"
    - 진화: "민수의 깨봉이가 딱충이로 진화했어요"
  - `PlazaBoardView`: `feed.events` 순서대로(새 소식이 위). 줄마다 문구, 날짜(`occurredAt`이 있으면 시각까지), 이로치 강조, 달린 반응(닉네임별 ♥, ㅋㅋ, 🎉), 반응 버튼 3개. 큰 소식은 굵게.
  - 소식판을 열 때와 닫을 때 `feed.markAllRead()`
  - `PlazaScene.setBoardMarker(visible: Bool)`: 소식판 위 `!` 말풍선(`PlazaEmoteArt`)
  - `PlazaScene.playSparkle(memberID: String?)`: 그 캐릭터 위에 별 조각 몇 개가 1초쯤 퍼진다
  - `PlazaWindowController`:
    - `func showBanner(_ text: String)`: 창이 있으면 `overlayModel.banner`에 넣고 4초 뒤 지운다
    - `func showBigEvent(_ e: TeamEvent)`: 창이 있으면 `playSparkle` + `showBanner(L.teamEventText(e))`
    - 지켜보는 `feed.unreadCount`로 소식판 표시를 켜고 끈다
  - `TeamRuntime`: `session.onBigEvent` → `plaza?.showBigEvent`
  - `StatusItemMenu.entries(…, plazaUnread: Int)`: 0보다 크면 `"광장 열기… (3)"`. 지도 버튼에도 같은 수의 작은 빨간 원을 단다(`.environment(runtime.feed)`).
- 진화는 연출하지 않는다. 지난 소식(`live: false`)은 연출하지 않는다(세션이 이미 거른다).
- `TeamReactionKind.comment`는 그대로 두고 UI에 내지 않는다. 받으면 줄에 그리지 않는다.

- [ ] **Step 1: 실패하는 테스트 작성**

  ```swift
  func testEventTextPerKind() { /* 네 종류, 이로치, 받침 유무 조사 */ }
  func testEventTextHasNoUsageNumbers() { … }
  func testOpeningBoardMarksRead() { /* unreadCount 0, 표시 꺼짐 */ }
  func testNewNewsLightsBoardMarker() { … }
  func testReactionButtonSendsOnce() { /* 두 번 눌러도 상대 feed 1개 */ }
  func testBigEventSparklesAndShowsBanner() { … }
  func testMyBigEventSparklesOnMe() { … }
  func testBigEventWithClosedPlazaDoesNothing() { … }
  func testBannerClearsAfterDelay() { … }

  // StatusItemMenuTests
  func testPlazaEntryShowsUnreadCount() { /* 0이면 숫자 없음, 3이면 (3) */ }
  ```

- [ ] **Step 2: 실패 확인** — Run: `swift test --filter 'PlazaBoardTests|StatusItemMenuTests'` / Expected: FAIL
- [ ] **Step 3: 구현**
- [ ] **Step 4: 통과 확인** — Run: `swift test --filter 'Plaza|Team|StatusItemMenuTests|<규칙 검사 15개>'`, `swift build` / Expected: PASS
- [ ] **Step 5: Commit** — `feat(plaza): add the news board, big-news effects and unread badge`

### Task 12: 기념사진

**Files:**
- Create: `Sources/PokeTokenBar/Team/Plaza/PlazaPhotoRenderer.swift`
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaScene.swift`, `PlazaActor.swift`, `PlazaWindowController.swift`, `scripts/test-gate.sh`
- Test: `Tests/PokeTokenBarTests/PlazaPhotoTests.swift`

**Interfaces:**
- Produces:
  - `struct PlazaPhotoActor`: `image: CGImage`, `flipped: Bool`, `foot: CGPoint`, `scale: CGFloat`, `shadow: CGImage?`, `shadowRect: CGRect`, `plate: CGImage?`, `bubble: CGImage?`
  - `struct PlazaPhotoInput`: `mapImage: CGImage`, `visibleRect: CGRect`(월드), `pixelsPerWorld: Int`, `actors: [PlazaPhotoActor]`
  - `enum PlazaPhotoRenderer`: `static func render(_ input: PlazaPhotoInput) -> CGImage?`, `static func png(_ image: CGImage) -> Data?`
  - `PlazaScene`: `func photoInput() -> PlazaPhotoInput?`, `var onPhotoKey: (() -> Void)?`, `func playShutterFlash()`
  - `PlazaWindowController`: P → 합성 → `NSPasteboard.general`에 PNG → `playShutterFlash`
- **SKView 캡처를 쓰지 않는다.** CoreGraphics로 지도와 캐릭터를 직접 합성한다. 창 없이 테스트할 수 있고 정수 배율을 보장한다.
- `pixelsPerWorld = zoom × 2`로 찍는다. 1.5배 포켓몬도 도트 하나가 `3 × zoom` 픽셀로 떨어진다. `interpolationQuality = .none`.
- 이름표와 말풍선은 화면 배율과 상관없이 배율 2로 새로 만들어 넣는다.
- 그리는 순서: 지도, 모든 그림자, 발이 위쪽인 캐릭터부터, 이름표와 말풍선. 참여자 목록은 넣지 않는다.
- 파일로 저장하지 않는다.

- [ ] **Step 1: 실패하는 테스트 작성**

  ```swift
  func testPhotoKeyWorksWithHangulInput() { /* keyCode 35, characters "ㅔ" → onPhotoKey */ }
  func testPhotoSizeMatchesViewportAtIntegerScale() { … }
  func testTilesStayCrisp() { /* 타일 경계에서 색이 섞인 픽셀이 없다 */ }
  func testSpritePixelsAreWholeBlocks() { /* 홀수 폭 스프라이트의 열 폭이 전부 3×zoom */ }
  func testLowerActorDrawsOnTop() { … }
  func testNamePlateDrawnAboveOthers() { … }
  func testFlippedActorIsMirrored() { … }
  func testPNGHeaderIsValid() { … }
  ```

- [ ] **Step 2: 실패 확인** — Run: `swift test --filter PlazaPhotoTests` / Expected: FAIL
- [ ] **Step 3: 구현.** `PlazaPhotoRenderer.swift`를 `LOGIC_CORE`에 더한다.
- [ ] **Step 4: 통과 확인** — Run: `swift test --filter 'Plaza|<규칙 검사 15개>'` / Expected: PASS
- [ ] **Step 5: Commit** — `feat(plaza): copy a group photo to the clipboard`

### Task 13: 알림 (사용자 확인)

**Files:**
- Create: `Sources/PokeTokenBar/Team/TeamNotifications.swift`
- Modify: `Sources/PokeTokenBar/Team/TeamRuntime.swift`, `Sources/PokeTokenBar/Team/TeamLocalization.swift`, `Sources/PokeTokenBar/Team/Plaza/PlazaWindowController.swift`, `Sources/PokeTokenBar/PokeTokenBarApp.swift`, `scripts/test-gate.sh`
- Test: `Tests/PokeTokenBarTests/TeamNotificationsTests.swift`

**Interfaces:**
- Consumes: `TeamSession.onBigEvent`, `onReactionToMine`, `onEmote`, `TeamSettings.notificationsEnabled`, `L.teamEventText`
- Produces:
  - `struct TeamNotificationBatcher` (순수): `init(window: TimeInterval = 30)`, `mutating func offer(_ item: TeamNotice, now: Date) -> TeamNotice?`(창이 비었으면 바로 내보내고 창을 연다), `mutating func flush(now: Date) -> [TeamNotice]`(창이 끝났으면 쌓인 것을 돌려주고 비운다)
  - `L.teamNoticeSummary(first: String, others: Int) -> String`: "민수 외 2명이 반응했어요". `TeamNotifier`가 `flush` 결과를 알림 하나로 만든다
  - `struct TeamNotice`: `fromNickname: String`, `text: String`
  - `@MainActor protocol TeamNotificationPosting`: `func post(id: String, title: String, body: String)`
  - `struct LiveTeamNotificationPoster: TeamNotificationPosting`: `sound`는 nil, `threadIdentifier = "team"`
  - `@MainActor final class TeamNotifier`
    - `init(settings: TeamSettings, poster: TeamNotificationPosting, isPlazaFrontmost: @escaping () -> Bool, showInPlaza: @escaping (String) -> Void, clock: @escaping () -> Date = Date.init)`. `showInPlaza`는 `PlazaWindowController.showBanner`다
    - `func bigEvent(_ e: TeamEvent)`: 내 소식이면 무시
    - `func reactionToMine(_ r: TeamReaction, _ e: TeamEvent)`, `func emoteToMe(from: TeamMemberState, kind: TeamEmoteKind)`
    - 광장이 앞에 있으면 `showInPlaza`(말풍선과 반짝임은 이미 보이므로 반응 안내만)로 보내고 알림을 보내지 않는다. 팀 알림이 꺼져 있으면 아무것도 안 한다.
  - `final class TeamNotificationDelegate: NSObject, UNUserNotificationCenterDelegate`
    - `didReceive`: `threadIdentifier == "team"`이면 `onOpenPlaza`
    - `willPresent`: 팀이면 `[.banner]`, 아니면 `[]`. 기존 알림의 동작(앱이 앞이면 안 보임)을 그대로 둔다.
  - `PlazaWindowController.isFrontmost`: `NSApp.isActive && window?.isKeyWindow == true`
  - `TeamRuntime`: `onEmote`에서 대상이 나이고 `kind.notifiesTarget`이면 `emoteToMe`. 묶음 창은 `tick` 주기에 비운다.
- 번들 앱에서만 `LiveTeamNotificationPoster`와 delegate를 쓴다. 권한은 팀이 준비됐고 알림이 켜져 있을 때 한 번 `requestAuthorization(options: [.alert])`로 묻는다.
- 동기화로 늦게 온 반응은 세션이 콜백을 부르지 않아 알림이 가지 않는다. 소식판 안 읽음으로만 보인다(Task 2).
- 알림 액션은 만들지 않는다(스펙 재량).

- [ ] **Step 1: 실패하는 테스트 작성**

  ```swift
  func testFirstNoticePostsImmediately() { … }
  func testNoticesInWindowAreBatched() { /* 3개 → 1개 즉시, 30초 뒤 "외 1명" 묶음 1개 */ }
  func testBatchFlushWithNothingPendingPostsNothing() { … }
  func testOthersBigEventPosts() { … }
  func testMyBigEventDoesNotPost() { … }
  func testEvolveNeverReachesNotifier() { /* 세션의 onBigEvent가 부르지 않음 */ }
  func testNotificationsOffPostsNothing() { … }
  func testFrontmostPlazaShowsInsideInstead() { … }
  func testEmoteToSomeoneElseDoesNotPost() { … }
  func testNonNotifyingEmoteDoesNotPost() { … }
  func testNoticeTextHasNoUsageNumbers() { … }
  ```

- [ ] **Step 2: 실패 확인** — Run: `swift test --filter TeamNotificationsTests` / Expected: FAIL
- [ ] **Step 3: 구현.** `TeamNotifications.swift`를 `LOGIC_CORE`에 더한다.
- [ ] **Step 4: 통과 확인** — Run: `swift test --filter 'Plaza|Team|StatusItemMenuTests|<규칙 검사 15개>'`, `swift build` / Expected: PASS
- [ ] **Step 5: Commit** — `feat(team): add team notifications`
- [ ] **Step 6: 사용자 확인 (사람 필요).** Task 8처럼 개발 앱 두 개로 말풍선, 카드, 소식판, 반응, 사진을 써 본다. 개발 실행에서는 macOS 알림이 뜨지 않으므로 알림은 Task 15에서 확인한다.

### Task 14: 팀 릴리스 스크립트와 안내문

**Files:**
- Create: `scripts/team-release.sh`, `TEAM.md`
- Test: `Tests/PokeTokenBarTests/TeamReleaseScriptTests.swift`

**Interfaces:**
- Produces: `./scripts/team-release.sh <notes-file>`. 원작의 `scripts/release.sh`는 건드리지 않는다.
  - 버전은 `build-app.sh`의 `VERSION`을 읽는다. 첫 릴리스 `2.5.601`이 이미 적혀 있다. 그 태그가 이미 있으면 멈춘다.
  - `main` 브랜치이고, 변경 사항이 없고, `origin/main`과 같을 때만 진행한다. **이 스크립트는 푸시하지 않는다.** 버전 범프와 병합은 PR로 한다.
  - 서명 신원 `PokeTokenBar Local`이 없으면 `scripts/create-signing-cert.sh`를 안내하고 멈춘다. 자동으로 만들지 않는다.
  - 인증서 leaf를 `TEAM_EXPECTED_LEAF`와 비교한다. 비어 있으면(첫 릴리스) 현재 leaf를 출력하고 스크립트에 적으라고 안내한 뒤 멈춘다. 다르면 멈춘다.
  - `export PTB_REQUIRE_STABLE_SIGN=1` 후 `build-app.sh`로 빌드한다. 이 스크립트는 `/Applications`에도 설치한다.
  - `ditto`로 zip을 만들고 universal 바이너리인지 검사한 뒤 `gh release create "v$VERSION" <zip> --repo likelion-campus/PokeTokenBar --target main --notes-file <notes>`.
  - 랜딩, Homebrew 탭, Pages 단계는 없다.
  - `Core/UpdateChecker.swift`가 기대하는 자산 이름에 zip 이름을 맞춘다. 구현할 때 읽어서 확인한다.
- `TEAM.md`(한국어):
  - 설치와 갈아타기: 세이브 내보내기 → `brew uninstall --cask poke-token-bar`(`--zap` 금지) → 릴리스 zip 설치 → 첫 실행 때 Keychain·로컬 네트워크 허용
  - 팀 만들기와 참여
  - 조작법: 방향키, 1–5 말풍선, 스페이스 말 걸기·소식판, P 사진, +/− 배율, Esc 닫기
  - 무엇이 팀에 보이고 무엇이 안 보이는지(토큰, 비용, 진행률은 안 보임. 광장에 들어와 있는지는 보임)
  - 알려진 한계: 그 소식을 가진 사람이 모두 꺼져 있으면 늦게 도착, 팀 알림을 끄면 자리 비운 사이 받은 말풍선은 알 수 없음
  - 연결 문제 진단: `scripts/team-probe.swift`, 시스템 설정의 로컬 네트워크 권한과 방화벽
  - 그림·글꼴 출처: ArMM1998(CC0), 갈무리(OFL), PokéAPI 그림

- [ ] **Step 1: 실패하는 테스트 작성**

  ```swift
  func testTeamReleaseTargetsForkOnly() throws {
      // --repo likelion-campus/PokeTokenBar 포함, chattymin/ 와 homebrew-tap 없음, PTB_REQUIRE_STABLE_SIGN=1 포함
  }
  func testTeamReleaseNeverPushes() throws { /* "git push" 없음 */ }
  func testTeamGuideCreditsAssets() throws { /* TEAM.md에 ArMM1998, 갈무리 */ }
  ```

- [ ] **Step 2: 실패 확인** — Run: `swift test --filter TeamReleaseScriptTests` / Expected: FAIL
- [ ] **Step 3: 구현.** 이 Task에서는 스크립트를 실행하지 않는다.
- [ ] **Step 4: 통과 확인** — Run: `swift test --filter 'TeamReleaseScriptTests|<규칙 검사 15개>' && bash -n scripts/team-release.sh` / Expected: PASS, 문법 오류 없음
- [ ] **Step 5: Commit** — `chore(team): add team release script and install guide`

### Task 15: 전체 확인과 첫 팀 릴리스 (사람 필요)

**Files:**
- Modify: `scripts/team-release.sh` (`TEAM_EXPECTED_LEAF` 기록)

이 Task의 Step 2 이후는 하나하나 실행 직전에 사용자에게 확인한다. 공개 저장소에 올라가거나 사용자 키체인을 바꾸는 일이다.

- [ ] **Step 1: 전체 테스트** — Run(샌드박스 밖): `swift build && ./scripts/test-gate.sh` / Expected: 통과
- [ ] **Step 2: 브랜치 푸시와 PR (사용자 확인).** `prepare-pr` 스킬을 쓴다. 영어 제목과 본문, 화면 변경 이미지 필수. 대상은 `likelion-campus/PokeTokenBar`의 `main`이고 원작 저장소가 아니다. 이때 조직 체크리스트(팀 권한, main 룰셋과 `lat` 체크, 슬랙 구독)를 적용할지 함께 묻는다.
- [ ] **Step 3: 서명 인증서 (사용자 확인).** Run: `./scripts/create-signing-cert.sh` → `./scripts/team-release.sh <notes>`(첫 실행은 leaf 출력 후 멈춤). leaf를 `TEAM_EXPECTED_LEAF`에 적어 커밋한다. 다시 만들면 팀원 모두에게 Keychain 창이 뜨므로 다시 만들지 않는다.
- [ ] **Step 4: 첫 릴리스 (사용자 확인).** 버전과 노트 요약을 보여 주고 확인받는다. 노트는 `docs/reference/release-notes-template.md` 형식이다. Run: `./scripts/team-release.sh <notes>` / Expected: `v2.5.601` 릴리스와 zip이 생긴다.
- [ ] **Step 5: 사무실에서 Mac 두 대로 끝까지 확인.** 사용자와 팀원 한 명이 `TEAM.md`대로 설치한다.
  - [ ] 기존 도감, 포켓몬, 가방이 그대로 이어진다
  - [ ] 같은 코드로 서로 광장에 보인다. **양쪽 방향 연결**을 모두 확인한다(한쪽만 켠 뒤 다른 쪽을 켜고, 순서를 바꿔 다시)
  - [ ] 움직임이 실시간으로 보인다. 창을 닫으면 쉼터로 가고 "zZ"가 붙는다
  - [ ] 말풍선이 보이고, 마주 보고 ♥를 띄우면 상대가 자리 비움일 때 알림이 간다
  - [ ] 알림을 누르면 광장이 열린다. 소리가 나지 않는다
  - [ ] 부화하면 상대 화면에 반짝임과 안내가 뜨고 소식판에 쌓인다
  - [ ] 대표 포켓몬을 바꾸면 상대 화면의 그림이 바로 바뀐다
  - [ ] 카드에서 도감이 보인다. 숫자가 없다
  - [ ] 사진을 메신저에 붙여 넣을 수 있다
  - [ ] 노트북을 덮으면 상대 화면에서 빠지고, 열면 다시 연결되고 그 사이 소식이 채워진다
  - [ ] 다른 팀 코드의 Mac에는 아무것도 보이지 않는다
  - [ ] 인앱 업데이트 확인이 `likelion-campus` 릴리스를 본다
  - [ ] 1배 외장 모니터와 Retina 양쪽에서 이름이 또렷하다
  - [ ] 광장을 연 채 `pmset displaysleepnow`로 화면을 끈 뒤 `top`으로 CPU를 본다. 계속 그리면 화면 잠자기에 멈추는 훅을 더한다(1부 최종 검토의 미확인 항목)
- [ ] **Step 6: Commit** — `chore(team): pin team signing certificate leaf`
