# 팀 광장 1부 (혼자 돌아다니는 광장) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 팀 설정을 마친 사용자가 메뉴바에서 "광장 열기"를 누르면 도트 광장 창이 뜨고, 지금 키우는(플로팅
펫에 보이는) 포켓몬을 방향키로 움직여 넓은 지도를 돌아다닐 수 있게 한다. 이 계획은 사용자가 직접 걸어 보고
느낌을 확인하는 지점에서 끝난다.

**Architecture:** 광장 코드는 `Sources/PokeTokenBar/Team/Plaza/`에 둔다. 지도·이동·방향별 그림·카메라는
SpriteKit에 의존하지 않는 순수 Swift 값 타입으로 만들어 테스트한다. `PlazaScene`(SpriteKit)은 그 값들을 화면에
옮기기만 한다. 타일은 리소스 없이 코드로 그린다(`PlazaTileArt`). 포켓몬 그림은 기존 `SpriteStore`/
`SpriteLoader`에 뒷모습 옵션을 더해 받아 온다. 네트워크는 이 계획에 없다.

**Tech Stack:** Swift 6, SpriteKit, AppKit, SwiftUI(설정 섹션·팝오버 버튼), CoreGraphics, XCTest.

**Spec:** `docs/superpowers/specs/2026-10-30-team-plaza-design.md`

**범위:** 스펙 5.1(팀 설정), 5.2(광장 창, 방향키·배율 키), 5.3(지도), 5.4(캐릭터·그림·크기·이동·내 이름표),
5.5 중 "지난 자리에서 시작"과 마지막 위치 저장, 9장 1–2번. 5.2의 안 읽음 배지는 소식판과 함께 2부에서 한다. **이 계획에 없는 것:** 팀원 표시(5.5),
말풍선(5.6), 말 걸기(5.7), 소식판(5.8), 기념사진(5.9), 알림(5.10), 네트워크(6장), 릴리스(7장). 이것들은
Task 10의 사용자 확인과 Mac 두 대 연결 확인 결과를 보고 2부 계획으로 쓴다. 2부는 이 계획의 지도 좌표,
`PlazaWalker`, `PlazaScene` 위에 얹는다.

## Global Constraints

- 팀 기능은 기본 꺼짐. 광장 메뉴와 버튼은 `TeamSettings.isReady`일 때만 보인다.
- 광장은 세이브(`CompanionState`, `companion-state.json`)를 읽기만 하고 쓰지 않는다. 광장 설정(배율, 마지막
  위치)은 `TeamSettings.defaultStore()` UserDefaults에 둔다.
- 팀 UI 문구는 한국어만 쓰고 전부 `Sources/PokeTokenBar/Team/TeamLocalization.swift`의 `extension L`에 둔다.
  `Sources/PokeTokenBar/Team/`의 다른 파일과 `Sources/PokeTokenBar/UI/`에는 한글 문자열 리터럴을 두지 않는다.
- 팀 코드는 `Sources/PokeTokenBar/Team/`, 광장 코드는 `Sources/PokeTokenBar/Team/Plaza/`에 둔다. 기존 파일
  수정은 각 Task가 명시한 연결 지점만 한다.
- 그래픽은 SpriteKit, AppKit, CoreGraphics만 쓴다. 새 패키지 의존성을 넣지 않는다. 실제 포켓몬 게임의 타일을
  베끼지 않는다. (Task 1–10: 리소스 번들 없이 코드로 그린 타일. **보강 Task 11부터는** 스펙 개정에 따라 CC0
  타일셋과 갈무리 글꼴을 SwiftPM 리소스로 넣는다.)
- 도트는 뭉개지지 않아야 한다: 텍스처는 `filteringMode = .nearest`, 배율은 정수(화면 포인트 ÷ 월드 픽셀),
  노드 위치는 기기 픽셀 단위로 맞춘다.
- 광장 창을 닫으면 그리기를 완전히 멈춘다(장면 해제).
- 수치(사용자 확인 전 기본값): 타일 32 월드 픽셀, 월드 픽셀 1 = 포켓몬 그림 픽셀 1, 지도 48×32칸, 한 칸
  이동 0.25초, 배율 1–3(기본 2).
- 방향별 그림: 아래 = 앞모습, 위 = 뒷모습, 왼쪽 = 앞모습, 오른쪽 = 앞모습 좌우 반전, 걸을 때 통통 튐.
- 광장 캐릭터는 `companion.representativeSubject`(플로팅 펫과 같은 대상)를 따른다. `speciesID == nil`이면 알이다.
- 개발 중에는 `scripts/build-app.sh`를 실행하지 않는다(`/Applications`의 앱을 덮어쓴다). 확인은 `swift build`,
  관련 테스트 필터를 건 `swift test --filter …`, `PTB_STATE_DIR=<임시폴더> swift run PokeTokenBar`로 한다.
  이 환경에서는 전체 `swift test`가 원작 코드에서도 순서에 따라 멈추므로, 구현자는 자기 Task와 이웃 테스트만
  돌린다. NSWindow를 만드는 테스트도 이 환경에서 멈출 수 있어서, 창을 만들지 않고 테스트할 수 있게 설계한다.
- 커밋 메시지는 영어로 쓴다(저장소 `CLAUDE.md`). 각 커밋 끝에 공동 작성자 줄을 붙인다:
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`

## Review Focus

1. **창이 포커스를 잃었는데 키가 눌린 채로 남음:** 방향키를 누른 채 다른 앱으로 넘어가면 keyUp이 오지 않는다.
   포켓몬이 끝없이 걸으면 안 된다. → Task 4 `testReleaseAllStopsAfterCurrentStep`, Task 8
   `testResignKeyReleasesHeldKeys`.
2. **광장을 연 채로 캐릭터가 바뀜:** 알이 부화하거나 진화하거나 대표 포켓몬을 바꾸면 창을 다시 열지 않아도
   그림이 바뀌어야 한다. → Task 8 `testRefreshCharacterLoadsCurrentSubject`.
3. **저장된 마지막 위치가 쓸 수 없음:** 지도가 바뀌어 저장된 칸이 지도 밖이거나 나무·연못이면 쉼터에서 시작해야
   한다. → Task 8 `testInvalidSavedTileFallsBackToSpawn`.
4. **그림을 못 받음:** 오프라인이거나 뒷모습이 없거나 6세대 이후라 움직이는 그림이 없어도 캐릭터가 사라지면 안
   된다. → Task 5 `testMissingBackFallsBackToFront`, `testAllFetchesFailUsesPlaceholder`.
5. **창 크기·배율·디스플레이 변경:** 창을 지도보다 크게 늘리거나, 배율을 바꾸거나, Retina와 일반 모니터 사이로
   옮겨도 카메라가 지도 밖을 비추지 않고 도트가 또렷해야 한다. → Task 6 `testViewportLargerThanMapCentersMap`,
   `testOriginSnapsToDevicePixels`.

---

### Task 1: 뒷모습 그림 받기

**Files:**
- Modify: `Sources/PokeTokenBar/UI/SpriteLoader.swift` (`SpriteStore.cacheKey`, `spriteURL`, `data(speciesID:…)`,
  `SpriteLoader.cachedFrames`, `animationFrames`, `image(speciesID:…)`에 `back` 매개변수 추가)
- Test: `Tests/PokeTokenBarTests/SpriteBackURLTests.swift`

**Interfaces:**
- Produces (모두 `back: Bool = false` 기본값이라 기존 호출부는 그대로다):
  - `SpriteStore.cacheKey(speciesID:animated:shiny:form:back:) -> String`
  - `SpriteStore.spriteURL(speciesID:animated:shiny:form:back:) -> URL`
  - `SpriteStore.data(speciesID:animated:shiny:form:back:) async -> Data?`
  - `SpriteLoader.animationFrames(speciesID:shiny:store:form:back:) async -> [(image: NSImage, delay: TimeInterval)]`
  - `SpriteLoader.image(speciesID:animated:shiny:form:back:…) async -> NSImage?` (기존 시그니처에 `back` 추가)
- 경로 규칙(PokéAPI에서 200 응답 확인함): `[versions/generation-v/black-white/animated/]` + `[back/]` + `[shiny/]` +
  이름 + 확장자. 예: `…/animated/back/shiny/25.gif`, `back/shiny/25.png`, `back/906.png`, `back/10006.png`.
- 캐시 키: 앞모습 키는 지금과 **글자 하나까지 같아야 한다**(이미 받아 둔 캐시를 버리지 않도록). 뒷모습은 `-` 뒤에
  `b`를 붙인다: `25-a` → `25-ba`, `25-sha` → `25-bsha`.

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
final class SpriteBackURLTests: XCTestCase {
    private let base = "https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon"

    func testBackURLs() {
        XCTAssertEqual(SpriteStore.spriteURL(speciesID: 25, animated: true, shiny: true, back: true).absoluteString,
                       "\(base)/versions/generation-v/black-white/animated/back/shiny/25.gif")
        XCTAssertEqual(SpriteStore.spriteURL(speciesID: 25, animated: false, shiny: true, back: true).absoluteString,
                       "\(base)/back/shiny/25.png")
        XCTAssertEqual(SpriteStore.spriteURL(speciesID: 906, animated: false, shiny: false, back: true).absoluteString,
                       "\(base)/back/906.png")
    }

    func testFrontKeysUnchangedAndBackKeysDistinct() {
        XCTAssertEqual(SpriteStore.cacheKey(speciesID: 25, animated: true, shiny: false), "25-a")
        XCTAssertEqual(SpriteStore.cacheKey(speciesID: 25, animated: true, shiny: true), "25-sha")
        XCTAssertEqual(SpriteStore.cacheKey(speciesID: 25, animated: true, shiny: false, back: true), "25-ba")
        XCTAssertEqual(SpriteStore.cacheKey(speciesID: 25, animated: false, shiny: true, back: true), "25-bshs")
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter SpriteBackURLTests`
Expected: FAIL (컴파일 오류: `back` 인자 없음)

- [ ] **Step 3: `back` 매개변수를 위 함수들에 끝까지 전달하도록 구현한다**

`data(…)`의 `hasAnimatedSprite` 검사는 뒷모습에도 같은 종 목록을 쓴다. 받기 실패는 지금처럼 `nil`/빈 배열이다.

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter 'SpriteBackURLTests|SpriteAnimation|SpriteLoader|SpriteStore'`
Expected: PASS (기존 스프라이트 테스트 포함)

- [ ] **Step 5: Commit**

```bash
git add Sources/PokeTokenBar/UI/SpriteLoader.swift Tests/PokeTokenBarTests/SpriteBackURLTests.swift
git commit -m "feat(plaza): load back-facing sprites"
```

### Task 2: 팀 문구와 설정 섹션

**Files:**
- Create: `Sources/PokeTokenBar/Team/TeamLocalization.swift`
- Create: `Sources/PokeTokenBar/Team/UI/TeamSettingsSection.swift`
- Modify: `Sources/PokeTokenBar/PokeTokenBarApp.swift` (`TeamSettings` 하나 생성, `buildPopoverContent`의 환경에 추가)
- Modify: `Sources/PokeTokenBar/UI/PopoverView.swift` (`SettingsView`에 환경을 명시적으로 넘기는 곳이 있으면 `TeamSettings`도 넘김)
- Modify: `Sources/PokeTokenBar/Team/TeamSettings.swift` (`visitsEnabled`와 `team.visits` 제거)
- Modify: `Tests/PokeTokenBarTests/TeamSettingsTests.swift` (`visitsEnabled` 단언 제거)
- Modify: `Sources/PokeTokenBar/UI/SettingsView.swift` (알림 섹션 바로 위에 `TeamSettingsSection` 한 줄)
- Modify: `Tests/PokeTokenBarTests/LocalizedUILiteralTests.swift` (`hasHangulStringLiteral`을 `static` internal로만 바꿈)
- Test: `Tests/PokeTokenBarTests/TeamLocalizationTests.swift`

**Interfaces:**
- Consumes: `TeamSettings`, `TeamCode` (기존)
- Produces: `extension L`의 아래 속성. 모두 한국어 고정 문자열이고 `t(...)`를 쓰지 않는다.

| 키 | 문구 |
|---|---|
| `teamSectionTitle` | 팀 |
| `teamEnable` | 팀 기능 켜기 |
| `teamCreate` | 팀 만들기 |
| `teamJoin` | 코드로 참여 |
| `teamCodePlaceholder` | 팀 코드 붙여 넣기 |
| `teamCodeInvalid` | 팀 코드가 올바르지 않아요 |
| `teamCopyCode` | 코드 복사 |
| `teamLeave` | 팀 나가기 |
| `teamNickname` | 닉네임 |
| `teamNicknameInvalid` | 닉네임은 1~12자로 입력해 주세요 |
| `teamNotifications` | 팀 알림 |
| `plazaOpen` | 광장 열기 |
| `plazaWindowTitle` | 팀 광장 |

- 설정 섹션 동작:
  - "팀 기능 켜기" 토글
  - 코드가 없을 때: "팀 만들기"(코드 생성), "코드로 참여"(붙여 넣기 필드, `TeamCode(parsing:)`이 nil이면 인라인 오류)
  - 코드가 있을 때: 일부를 가린 코드, "코드 복사", "팀 나가기"(`leaveTeam()`)
  - 닉네임 필드: `validNickname`이 nil이면 인라인 오류
  - 팀 알림 토글
- `TeamSettings`는 이 Task에서 `AppDelegate`에 하나만 만들고 팝오버 환경으로 넘긴다. 섹션은
  `@Environment(TeamSettings.self)`로 읽는다. 환경에 없으면 SwiftUI가 실행 중에 멈추므로, 설정 화면이 실제로
  뜨는지 Step 4의 `swift build`와 함께 확인한다.

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
final class TeamLocalizationTests: XCTestCase {
    func testTeamSourcesHaveNoHangulLiterals() throws {
        // Sources/PokeTokenBar/Team 아래 모든 .swift(TeamLocalization.swift 제외)에
        // LocalizedUILiteralTests.hasHangulStringLiteral을 적용 → 위반 0
    }

    func testPlazaStrings() {
        let l = L(.ko)
        XCTAssertEqual(l.plazaOpen, "광장 열기"); XCTAssertEqual(l.plazaWindowTitle, "팀 광장")
    }
}
```


- [ ] **Step 2: 실패 확인**

Run: `swift test --filter TeamLocalizationTests`
Expected: FAIL

- [ ] **Step 3: 문구, 설정 섹션, `visitsEnabled` 제거 구현**

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter 'TeamLocalizationTests|LocalizedUILiteralTests|TeamSettingsTests'`
Expected: PASS

Run: `swift build`
Expected: 성공

- [ ] **Step 5: Commit**

```bash
git add Sources/PokeTokenBar/Team/TeamLocalization.swift Sources/PokeTokenBar/Team/UI/TeamSettingsSection.swift Sources/PokeTokenBar/Team/TeamSettings.swift Sources/PokeTokenBar/UI/SettingsView.swift Sources/PokeTokenBar/UI/PopoverView.swift Sources/PokeTokenBar/PokeTokenBarApp.swift Tests/PokeTokenBarTests/TeamLocalizationTests.swift Tests/PokeTokenBarTests/LocalizedUILiteralTests.swift Tests/PokeTokenBarTests/TeamSettingsTests.swift
git commit -m "feat(team): add team settings section and Korean team strings"
```

### Task 3: 광장 지도 모델과 지도 데이터

**Files:**
- Create: `Sources/PokeTokenBar/Team/Plaza/PlazaMap.swift`
- Create: `Sources/PokeTokenBar/Team/Plaza/PlazaMapData.swift`
- Test: `Tests/PokeTokenBarTests/PlazaMapTests.swift`

**Interfaces:**
- Produces:

```swift
struct TilePoint: Hashable, Codable, Sendable { var x: Int; var y: Int }   // y는 아래로 증가

enum PlazaTile: Character, Sendable {
    case grass = ".", tallGrass = ",", flowers = "f", path = "P", shelter = "S"   // 지나갈 수 있음
    case water = "W", tree = "T", rock = "b", fence = "F", board = "N"           // 지나갈 수 없음
    var isWalkable: Bool { get }
}

enum PlazaMapError: Error, Equatable { case empty, ragged(row: Int), unknown(Character), missingBoard, missingShelter }

struct PlazaMap: Sendable {
    static let tileSize = 32                       // 월드 픽셀
    let width: Int, height: Int
    init(rows: [String]) throws(PlazaMapError)
    func tile(at p: TilePoint) -> PlazaTile        // 지도 밖은 .tree
    func isWalkable(_ p: TilePoint) -> Bool
    var shelterTiles: [TilePoint] { get }          // 행 우선 순서
    var boardTile: TilePoint { get }               // 첫 번째 "N"
    var spawn: TilePoint { get }                   // 쉼터 칸들의 무게중심에 가장 가까운 쉼터 칸(동률이면 행 우선 첫 칸)
    var pixelSize: CGSize { get }                  // width*32 × height*32
}

enum PlazaMapData {
    static let rows: [String]                      // 48열 × 32행
    static let map: PlazaMap                       // try! PlazaMap(rows: rows)
}
```

- 지도 내용은 구현자가 짠다. 조건: 가장자리는 모두 지나갈 수 없음(나무 위주), 가운데쯤 쉼터(`S`) 12칸 이상, 쉼터
  가까이 소식판(`N`) 1칸, 연못·꽃밭·풀숲·길이 한 곳 이상씩, 큰 포켓몬이 지나갈 만한 넓은 길과 몇 군데 좁은 길.

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
final class PlazaMapTests: XCTestCase {
    let map = PlazaMapData.map

    func testSizeIs48By32() {
        XCTAssertEqual(map.width, 48); XCTAssertEqual(map.height, 32)
        XCTAssertEqual(map.pixelSize, CGSize(width: 48 * 32, height: 32 * 32))
    }

    func testBorderIsNotWalkable() {
        for x in 0..<map.width { XCTAssertFalse(map.isWalkable(.init(x: x, y: 0))); XCTAssertFalse(map.isWalkable(.init(x: x, y: map.height - 1))) }
        for y in 0..<map.height { XCTAssertFalse(map.isWalkable(.init(x: 0, y: y))); XCTAssertFalse(map.isWalkable(.init(x: map.width - 1, y: y))) }
    }

    func testEveryWalkableTileIsReachableFromSpawn() {
        // spawn에서 4방향 flood fill한 칸 수 == 지나갈 수 있는 칸 전체 수
    }

    func testShelterBoardAndSpawn() {
        XCTAssertGreaterThanOrEqual(map.shelterTiles.count, 12)
        XCTAssertEqual(map.tile(at: map.spawn), .shelter)
        let below = TilePoint(x: map.boardTile.x, y: map.boardTile.y + 1)
        XCTAssertTrue(map.isWalkable(below), "소식판은 아래 칸에서 위를 보고 말을 건다(2부)")
    }

    func testHasEachArea() {
        // rows 전체에 W, f, ",", P가 하나 이상
    }

    func testRejectsBadRows() {
        XCTAssertThrowsError(try PlazaMap(rows: ["TTT", "TT"]))
        XCTAssertThrowsError(try PlazaMap(rows: ["TTT", "TXT", "TTT"]))
        XCTAssertThrowsError(try PlazaMap(rows: ["TTT", "TST", "TTT"]))   // 소식판 없음
    }

    func testOutsideIsTree() {
        XCTAssertEqual(map.tile(at: .init(x: -1, y: 5)), .tree)
        XCTAssertFalse(map.isWalkable(.init(x: map.width, y: 5)))
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter PlazaMapTests`
Expected: FAIL (타입 없음)

- [ ] **Step 3: `PlazaMap`과 `PlazaMapData` 구현**

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter PlazaMapTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/PokeTokenBar/Team/Plaza/PlazaMap.swift Sources/PokeTokenBar/Team/Plaza/PlazaMapData.swift Tests/PokeTokenBarTests/PlazaMapTests.swift
git commit -m "feat(plaza): add plaza tile map and the team plaza layout"
```

### Task 4: 한 칸씩 걷기

**Files:**
- Create: `Sources/PokeTokenBar/Team/Plaza/PlazaWalker.swift`
- Test: `Tests/PokeTokenBarTests/PlazaWalkerTests.swift`

**Interfaces:**
- Consumes: `TilePoint`, `PlazaMap.tileSize` (Task 3)
- Produces:

```swift
enum PlazaDirection: CaseIterable, Sendable { case up, down, left, right }

struct PlazaWalker: Sendable {
    static let stepDuration: TimeInterval = 0.25
    private(set) var tile: TilePoint          // 걷는 중이면 도착할 칸
    private(set) var facing: PlazaDirection
    var isWalking: Bool { get }
    init(tile: TilePoint, facing: PlazaDirection = .down)
    mutating func press(_ d: PlazaDirection)
    mutating func release(_ d: PlazaDirection)
    mutating func releaseAll()
    mutating func advance(by dt: TimeInterval, canEnter: (TilePoint) -> Bool)
    var footPoint: CGPoint { get }            // 월드 픽셀(y 아래로), 칸 가로 가운데·세로 0.875 지점, 걷는 중이면 보간
}
```

- 동작:
  - 누른 키는 순서대로 쌓이고, 마지막에 누른 키가 이긴다.
  - 짧게 탭해서 같은 프레임 안에 떼어도 한 칸은 간다(`press`가 탭을 기억하고 다음 `advance`가 쓴다).
  - 가려는 칸에 못 들어가면 그 방향으로 돌아서기만 한다.
  - 한 칸을 가는 도중에는 멈추지 않는다. 도착했을 때 눌린 키가 있으면 바로 다음 칸으로 이어 간다(남는 시간은
    다음 칸에 이어 쓴다).
  - `canEnter`는 도착할 칸에만 묻는다.

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
final class PlazaWalkerTests: XCTestCase {
    private let open: (TilePoint) -> Bool = { _ in true }
    private func run(_ w: inout PlazaWalker, _ seconds: Double, canEnter: (TilePoint) -> Bool = { _ in true }) {
        var t = 0.0; while t < seconds - 1e-9 { w.advance(by: 1.0 / 60, canEnter: canEnter); t += 1.0 / 60 }
    }

    func testTapMovesExactlyOneTile() {
        var w = PlazaWalker(tile: .init(x: 5, y: 5))
        w.press(.right); w.release(.right)
        run(&w, 0.5)
        XCTAssertEqual(w.tile, .init(x: 6, y: 5)); XCTAssertFalse(w.isWalking); XCTAssertEqual(w.facing, .right)
    }

    func testHoldKeepsWalking() {
        var w = PlazaWalker(tile: .init(x: 5, y: 5))
        w.press(.down); run(&w, 1.0)
        XCTAssertEqual(w.tile.y, 9); XCTAssertTrue(w.isWalking)
    }

    func testBlockedTurnsWithoutMoving() {
        var w = PlazaWalker(tile: .init(x: 5, y: 5))
        w.press(.left); w.release(.left)
        run(&w, 0.5, canEnter: { _ in false })
        XCTAssertEqual(w.tile, .init(x: 5, y: 5)); XCTAssertEqual(w.facing, .left)
    }

    func testLastPressedDirectionWins() {
        var w = PlazaWalker(tile: .init(x: 5, y: 5))
        w.press(.right); run(&w, 0.1); w.press(.up); run(&w, 0.4)
        XCTAssertEqual(w.tile, .init(x: 6, y: 4))
    }

    func testReleaseMidStepFinishesStep() {
        var w = PlazaWalker(tile: .init(x: 5, y: 5))
        w.press(.right); run(&w, 0.1); w.release(.right); run(&w, 0.5)
        XCTAssertEqual(w.tile, .init(x: 6, y: 5)); XCTAssertFalse(w.isWalking)
    }

    func testReleaseAllStopsAfterCurrentStep() {
        var w = PlazaWalker(tile: .init(x: 5, y: 5))
        w.press(.right); w.press(.down); run(&w, 0.1); w.releaseAll(); run(&w, 1.0)
        XCTAssertFalse(w.isWalking)
        XCTAssertEqual(abs(w.tile.x - 5) + abs(w.tile.y - 5), 1)
    }

    func testFootPointInterpolatesHalfway() {
        var w = PlazaWalker(tile: .init(x: 5, y: 5))
        w.press(.right); run(&w, 0.125)
        XCTAssertEqual(w.footPoint.x, (5.5 + 0.5) * 32, accuracy: 1.0)
        XCTAssertEqual(w.footPoint.y, 5.875 * 32, accuracy: 0.001)
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter PlazaWalkerTests`
Expected: FAIL (타입 없음)

- [ ] **Step 3: `PlazaWalker` 구현**

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter PlazaWalkerTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/PokeTokenBar/Team/Plaza/PlazaWalker.swift Tests/PokeTokenBarTests/PlazaWalkerTests.swift
git commit -m "feat(plaza): add tile-by-tile walking"
```

### Task 5: 방향별 그림 고르기와 캐릭터 그림 준비

**Files:**
- Create: `Sources/PokeTokenBar/Team/Plaza/PlazaPose.swift`
- Create: `Sources/PokeTokenBar/Team/Plaza/PlazaCharacterLoader.swift`
- Test: `Tests/PokeTokenBarTests/PlazaCharacterTests.swift`

**Interfaces:**
- Consumes: `PlazaDirection` (Task 4), Task 1의 `back` 옵션, `CompanionStore.RepresentativeSubject`,
  `PokemonAssets.hasAnimatedSprite(speciesID:)`, `SpriteLoader.eggImage()`
- Produces:

```swift
struct PlazaSpriteChoice: Equatable, Sendable { let useBack: Bool; let flipped: Bool; let bob: Int }
enum PlazaPose {
    /// 아래 = 앞, 위 = 뒤, 왼쪽 = 앞, 오른쪽 = 앞 반전. 걸을 때 bob은 0과 2를 1/8초마다 번갈아, 멈추면 0.
    static func choice(facing: PlazaDirection, isWalking: Bool, clock: TimeInterval) -> PlazaSpriteChoice
}

struct PlazaFrame: @unchecked Sendable { let image: CGImage; let delay: TimeInterval }
struct PlazaCharacterFrames: Sendable { let front: [PlazaFrame]; let back: [PlazaFrame] }   // 둘 다 비어 있지 않다

protocol PlazaSpriteFetching: Sendable {
    func animated(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> [(image: NSImage, delay: TimeInterval)]
    func still(speciesID: Int, shiny: Bool, form: PokemonForm?, back: Bool) async -> NSImage?
    func egg() async -> NSImage?
}
struct LivePlazaSpriteFetcher: PlazaSpriteFetching { }   // SpriteLoader에 위임

@MainActor final class PlazaCharacterLoader {
    init(fetcher: PlazaSpriteFetching = LivePlazaSpriteFetcher())
    func frames(for subject: CompanionStore.RepresentativeSubject) async -> PlazaCharacterFrames
}

enum PlazaSpriteCrop {
    /// 모든 프레임의 불투명 픽셀을 합친 경계로 똑같이 잘라 발 위치가 프레임마다 흔들리지 않게 한다.
    static func trimmed(_ frames: [CGImage]) -> [CGImage]
}
```

- 대체 순서(한 방향 안에서): 움직이는 그림(종이 `hasAnimatedSprite`일 때) → 정지 그림. 이로치를 못 받으면 같은
  순서로 일반 색을 시도한다. 뒷모습을 끝내 못 받으면 앞모습을 그대로 쓴다. 앞모습까지 못 받으면 코드로 그린
  작은 자리표시 그림(예: 회색 동그라미)을 쓴다. 알(`speciesID == nil`)은 앞뒤 모두 알 그림이다.
- 정지 그림(96×96, 아래 여백 있음)과 GIF 프레임 모두 `PlazaSpriteCrop.trimmed`로 자른다.

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
final class PlazaCharacterTests: XCTestCase {
    func testPoseMapping() {
        XCTAssertEqual(PlazaPose.choice(facing: .down, isWalking: false, clock: 0), .init(useBack: false, flipped: false, bob: 0))
        XCTAssertEqual(PlazaPose.choice(facing: .up, isWalking: false, clock: 0), .init(useBack: true, flipped: false, bob: 0))
        XCTAssertEqual(PlazaPose.choice(facing: .left, isWalking: false, clock: 0), .init(useBack: false, flipped: false, bob: 0))
        XCTAssertEqual(PlazaPose.choice(facing: .right, isWalking: false, clock: 0), .init(useBack: false, flipped: true, bob: 0))
    }

    func testBobAlternatesOnlyWhileWalking() {
        let bobs = Set(stride(from: 0.0, to: 1.0, by: 0.05).map { PlazaPose.choice(facing: .down, isWalking: true, clock: $0).bob })
        XCTAssertEqual(bobs, [0, 2])
        XCTAssertEqual(PlazaPose.choice(facing: .down, isWalking: false, clock: 0.13).bob, 0)
    }

    func testTrimUsesUnionBounds() {
        // 10×10 투명 이미지 두 장: A는 (2,2)에, B는 (6,7)에 불투명 픽셀 → 둘 다 5×6으로 잘린다
    }

    func testMissingBackFallsBackToFront() async {
        // FakeFetcher: 앞 정지 그림만 있음 → frames.back의 첫 이미지 == frames.front의 첫 이미지
    }

    func testAnimatedMissingUsesStill() async {
        // hasAnimatedSprite가 참인 종(예: 25)이라도 animated가 빈 배열이면 still을 쓴다
    }

    func testAllFetchesFailUsesPlaceholder() async {
        // FakeFetcher가 전부 실패 → front·back 모두 비어 있지 않고 이미지 크기 > 0
    }

    func testEggUsesEggImageBothSides() async {
        // subject.speciesID == nil → egg()만 호출되고 front·back 모두 그 그림
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter PlazaCharacterTests`
Expected: FAIL (타입 없음)

- [ ] **Step 3: `PlazaPose`, `PlazaSpriteCrop`, `PlazaCharacterLoader`, `LivePlazaSpriteFetcher` 구현**

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter PlazaCharacterTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/PokeTokenBar/Team/Plaza/PlazaPose.swift Sources/PokeTokenBar/Team/Plaza/PlazaCharacterLoader.swift Tests/PokeTokenBarTests/PlazaCharacterTests.swift
git commit -m "feat(plaza): pick sprites by direction and load character frames"
```

### Task 6: 카메라와 배율

**Files:**
- Create: `Sources/PokeTokenBar/Team/Plaza/PlazaCamera.swift`
- Test: `Tests/PokeTokenBarTests/PlazaCameraTests.swift`

**Interfaces:**
- Produces:

```swift
enum PlazaCamera {
    static let zoomRange = 1...3
    static let defaultZoom = 2
    static func clampedZoom(_ z: Int) -> Int
    /// 보이는 영역(월드 픽셀, y 아래로). 크기 = 뷰포트 포인트 ÷ zoom.
    /// 지도보다 작은 축은 focus를 가운데 두되 지도 밖이 보이지 않게 [0, world - size]로 자른다.
    /// 지도보다 큰 축은 지도를 가운데 둔다(origin = (world - size) / 2, 음수 가능).
    /// origin은 기기 픽셀 한 칸(1 / (zoom × backingScale) 월드 픽셀) 단위로 반올림한다.
    static func visibleRect(focus: CGPoint, viewport: CGSize, zoom: Int, backingScale: CGFloat, world: CGSize) -> CGRect
}
```

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
final class PlazaCameraTests: XCTestCase {
    let world = CGSize(width: 1536, height: 1024)

    func testCentersOnFocus() {
        let r = PlazaCamera.visibleRect(focus: .init(x: 768, y: 512), viewport: .init(width: 960, height: 640), zoom: 2, backingScale: 2, world: world)
        XCTAssertEqual(r, CGRect(x: 528, y: 352, width: 480, height: 320))
    }

    func testClampsAtEdges() {
        let tl = PlazaCamera.visibleRect(focus: .init(x: 10, y: 10), viewport: .init(width: 960, height: 640), zoom: 2, backingScale: 2, world: world)
        XCTAssertEqual(tl.origin, .zero)
        let br = PlazaCamera.visibleRect(focus: .init(x: 1530, y: 1020), viewport: .init(width: 960, height: 640), zoom: 2, backingScale: 2, world: world)
        XCTAssertEqual(br.maxX, 1536); XCTAssertEqual(br.maxY, 1024)
    }

    func testViewportLargerThanMapCentersMap() {
        let r = PlazaCamera.visibleRect(focus: .init(x: 0, y: 0), viewport: .init(width: 4000, height: 3000), zoom: 1, backingScale: 1, world: world)
        XCTAssertEqual(r.midX, 768, accuracy: 0.5); XCTAssertEqual(r.midY, 512, accuracy: 0.5)
    }

    func testOriginSnapsToDevicePixels() {
        for scale in [1.0, 2.0] { for zoom in 1...3 {
            let r = PlazaCamera.visibleRect(focus: .init(x: 700.3, y: 500.77), viewport: .init(width: 801, height: 601), zoom: zoom, backingScale: scale, world: world)
            let step = 1.0 / (Double(zoom) * scale)
            XCTAssertEqual((r.minX / step).rounded(), r.minX / step, accuracy: 1e-6)
            XCTAssertEqual((r.minY / step).rounded(), r.minY / step, accuracy: 1e-6)
        } }
    }

    func testZoomClamp() {
        XCTAssertEqual(PlazaCamera.clampedZoom(0), 1); XCTAssertEqual(PlazaCamera.clampedZoom(9), 3)
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter PlazaCameraTests`
Expected: FAIL (타입 없음)

- [ ] **Step 3: `PlazaCamera` 구현**

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter PlazaCameraTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/PokeTokenBar/Team/Plaza/PlazaCamera.swift Tests/PokeTokenBarTests/PlazaCameraTests.swift
git commit -m "feat(plaza): add pixel-snapped camera and zoom"
```

### Task 7: 타일 그림

**Files:**
- Create: `Sources/PokeTokenBar/Team/Plaza/PlazaTileArt.swift`
- Test: `Tests/PokeTokenBarTests/PlazaTileArtTests.swift`

**Interfaces:**
- Consumes: `PlazaMap`, `PlazaTile`, `TilePoint` (Task 3)
- Produces:

```swift
enum PlazaTileArt {
    /// 32×32. 같은 (tile, 위치, 이웃)이면 항상 같은 픽셀(위치로 시드를 만든 결정적 난수).
    static func tileImage(at p: TilePoint, in map: PlazaMap) -> CGImage
    /// 지도 전체를 한 장으로(width*32 × height*32). 광장을 열 때 한 번 만든다.
    static func mapImage(_ map: PlazaMap) -> CGImage
}
```

- 그림 방향: 옛 휴대용 게임기 시절 느낌의 원본 도트. 팔레트는 직접 정한다. 길과 연못은 이웃 칸이 다르면 그 변에
  테두리를 그린다. 나무는 둥근 수관·그림자·줄기, 쉼터는 나무 바닥판, 소식판은 기둥 위 나무판, 풀숲은 위로 뻗은
  풀잎, 꽃밭은 작은 꽃 몇 송이, 바위와 울타리도 그린다. 물결 애니메이션은 넣지 않아도 된다.
- 대화에서 쓴 비교 화면의 16픽셀 타일 코드(아래 경로)를 참고해도 된다. 32픽셀로 다시 그려야 한다.
  `plaza-sprite-compare.html` (세션 임시 폴더의 파일, 저장소에는 없다)
  (없으면 무시한다)

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
final class PlazaTileArtTests: XCTestCase {
    func testMapImageSize() {
        let img = PlazaTileArt.mapImage(PlazaMapData.map)
        XCTAssertEqual(img.width, 48 * 32); XCTAssertEqual(img.height, 32 * 32)
    }

    func testDeterministic() {
        let map = PlazaMapData.map, p = map.spawn
        XCTAssertEqual(pixels(PlazaTileArt.tileImage(at: p, in: map)), pixels(PlazaTileArt.tileImage(at: p, in: map)))
    }

    func testPathEdgeDiffersFromInterior() {
        // 3×3 작은 지도: 가운데 P, 왼쪽 ".", 나머지 P → 가운데 칸의 왼쪽 끝 열 색 ≠ 가운데 열 색
    }

    func testEveryTileKindIsOpaque() {
        // 각 PlazaTile 종류가 들어간 작은 지도를 만들고, 각 칸 이미지의 모든 픽셀 알파가 255
    }

    /// RGBA8 비트맵 컨텍스트에 그려 실제 바이트를 반환한다. 빈 배열을 돌려주면 testDeterministic이
    /// 아무것도 검사하지 않으므로, 길이가 width × height × 4인지도 단언한다.
    private func pixels(_ image: CGImage) -> [UInt8]
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter PlazaTileArtTests`
Expected: FAIL (타입 없음)

- [ ] **Step 3: `PlazaTileArt` 구현**

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter PlazaTileArtTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/PokeTokenBar/Team/Plaza/PlazaTileArt.swift Tests/PokeTokenBarTests/PlazaTileArtTests.swift
git commit -m "feat(plaza): draw original pixel tiles in code"
```

### Task 8: 광장 장면과 창

**Files:**
- Create: `Sources/PokeTokenBar/Team/Plaza/PlazaPreferences.swift`
- Create: `Sources/PokeTokenBar/Team/Plaza/PlazaScene.swift`
- Create: `Sources/PokeTokenBar/Team/Plaza/PlazaWindowController.swift`
- Test: `Tests/PokeTokenBarTests/PlazaWindowTests.swift`

**Interfaces:**
- Consumes: Task 1, 3–7 전부, `TeamSettings.defaultStore()`, `L.plazaWindowTitle` (Task 2)
- Produces:

```swift
@MainActor final class PlazaPreferences {
    init(defaults: UserDefaults = TeamSettings.defaultStore())
    var zoom: Int { get set }                              // "team.plaza.zoom", 기본 PlazaCamera.defaultZoom, 저장 시 clamp
    func lastTile(validIn map: PlazaMap) -> TilePoint      // "team.plaza.lastTile"; 없거나 지도 밖·못 가는 칸이면 map.spawn
    func saveLastTile(_ p: TilePoint)
}

@MainActor final class PlazaScene: SKScene {
    init(map: PlazaMap, mapImage: CGImage, start: TilePoint, zoom: Int, nickname: String)
    private(set) var walker: PlazaWalker
    var zoom: Int { get set }
    var onZoomChange: ((Int) -> Void)?
    func setCharacter(_ frames: PlazaCharacterFrames)
    func setNickname(_ name: String)
    func handleKeyDown(keyCode: UInt16, characters: String?, isRepeat: Bool)   // keyDown(with:)가 여기로 넘긴다
    func handleKeyUp(keyCode: UInt16)
    func releaseAllKeys()
}

@MainActor final class PlazaWindowController: NSObject, NSWindowDelegate {
    init(map: PlazaMap = PlazaMapData.map,
         preferences: PlazaPreferences,
         loader: PlazaCharacterLoader,
         nickname: @escaping () -> String,
         subject: @escaping () -> CompanionStore.RepresentativeSubject)
    func show()                       // 창이 없으면 만들고, NSApp.activate 후 앞으로. 이미 열려 있으면 앞으로만.
    func prepareScene()               // 창 없이 장면만 만든다(show가 내부에서 쓰고, 테스트도 쓴다)
    func refreshCharacter() async     // 지금 subject로 그림을 다시 받아 장면에 넣는다. 장면이 없으면 아무것도 안 한다.
    func handleClose()                // 마지막 칸 저장, 장면 멈춤·해제, 창 내용 해제. windowWillClose가 부른다.
    func handleResignKey()            // 눌린 키 모두 떼기. windowDidResignKey가 부른다.
    private(set) var scene: PlazaScene?   // 닫혀 있으면 nil
}
```

- 장면:
  - 지도 한 장(`mapImage`)을 바닥에 깔고, 캐릭터 노드 하나, 카메라 노드, 이름표를 둔다. 모든 텍스처는
    `.nearest`.
  - 캐릭터: `PlazaPose.choice`로 앞/뒤/반전/통통을 고른다. 그림 아래 가운데를 `walker.footPoint`에 맞춘다. 프레임은
    각 프레임의 delay대로 돈다.
  - 카메라: 매 프레임 `PlazaCamera.visibleRect(focus: walker.footPoint, …)`로 위치를 정한다. SpriteKit 좌표는
    y가 위로 증가하므로 변환한다. 노드 위치도 기기 픽셀 단위로 맞춘다.
  - 이름표: 닉네임. 배율이 바뀌어도 또렷해야 한다. 방법은 구현자 재량(예: 카메라 자식 HUD 층에 화면 단위로 그림).
  - 키: 방향키(keyCode 123 왼쪽, 124 오른쪽, 125 아래, 126 위)는 반복 이벤트를 무시하고 `walker.press/release`,
    `-`는 배율 내리기, `=`/`+`는 올리기. 배율이 바뀌면 `onZoomChange`.
  - 이동 가능 판정은 `map.isWalkable`.
- 창:
  - 제목 `L.plazaWindowTitle`, 처음 크기 960×640 포인트, 최소 480×320, 크기 조절 가능, 일반 창 레벨.
  - `SKView`에 장면을 띄운다. 앱이 `.accessory`라서 열 때 `NSApp.activate(ignoringOtherApps: true)`가 있어야 키
    입력을 받는다.
  - 닫으면 `handleClose()`: 장면 해제 후 `scene == nil`. 다시 열면 저장된 칸에서 시작한다.
  - 배율 변경은 `preferences.zoom`에 저장한다.

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
@MainActor final class PlazaWindowTests: XCTestCase {
    private func defaults() -> UserDefaults { let d = UserDefaults(suiteName: "plaza.test.\(UUID())")!; return d }

    func testInvalidSavedTileFallsBackToSpawn() {
        let p = PlazaPreferences(defaults: defaults()), map = PlazaMapData.map
        XCTAssertEqual(p.lastTile(validIn: map), map.spawn)
        p.saveLastTile(.init(x: 0, y: 0)); XCTAssertEqual(p.lastTile(validIn: map), map.spawn)
        p.saveLastTile(.init(x: 999, y: 3)); XCTAssertEqual(p.lastTile(validIn: map), map.spawn)
        let ok = map.shelterTiles.last!; p.saveLastTile(ok); XCTAssertEqual(p.lastTile(validIn: map), ok)
    }

    func testZoomIsClampedAndPersisted() {
        let d = defaults(); let p = PlazaPreferences(defaults: d)
        XCTAssertEqual(p.zoom, 2); p.zoom = 7
        XCTAssertEqual(PlazaPreferences(defaults: d).zoom, 3)
    }

    func testClosingReleasesSceneAndSavesTile() {
        // prepareScene() → 오른쪽 키 탭 → scene.update 몇 번(또는 walker 직접 advance) → handleClose()
        // → scene == nil, 새 PlazaPreferences(같은 defaults).lastTile == 걸어간 칸
    }

    func testResignKeyReleasesHeldKeys() {
        // prepareScene() → handleKeyDown(124) → handleResignKey() → 1초 진행 → 한 칸만 이동하고 멈춤
    }

    func testRefreshCharacterLoadsCurrentSubject() async {
        // FakeFetcher로 만든 loader, subject를 바꿔 가며 refreshCharacter() → fetcher가 받은 speciesID가 최신 subject
    }

    func testArrowRepeatIsIgnored() {
        // handleKeyDown(124, isRepeat: true)만 보내면 press가 일어나지 않는다
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter PlazaWindowTests`
Expected: FAIL (타입 없음)

- [ ] **Step 3: `PlazaPreferences`, `PlazaScene`, `PlazaWindowController` 구현**

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter 'PlazaWindowTests|PlazaWalkerTests|PlazaCameraTests'`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/PokeTokenBar/Team/Plaza/PlazaPreferences.swift Sources/PokeTokenBar/Team/Plaza/PlazaScene.swift Sources/PokeTokenBar/Team/Plaza/PlazaWindowController.swift Tests/PokeTokenBarTests/PlazaWindowTests.swift
git commit -m "feat(plaza): add plaza scene and window"
```

### Task 9: 광장 열기 연결

**Files:**
- Modify: `Sources/PokeTokenBar/UI/StatusItemMenu.swift` (`Action.openPlaza`, `entries(…, plazaAvailable:)`)
- Modify: `Sources/PokeTokenBar/UI/PopoverView.swift` (탭 선택 줄 옆이나 위에 "광장 열기" 버튼, `isReady`일 때만)
- Modify: `Sources/PokeTokenBar/UI/PopoverView.swift`의 `PopoverNavigation` (`var onOpenPlaza: (() -> Void)?`)
- Modify: `Sources/PokeTokenBar/PokeTokenBarApp.swift` (`PlazaPreferences`·`PlazaWindowController` 생성, Task 2의
  `TeamSettings` 사용, 메뉴 동작, 대표 포켓몬 변경 시 `refreshCharacter`)
- Modify: `Tests/PokeTokenBarTests/StatusItemMenuTests.swift`

**Interfaces:**
- Consumes: `PlazaWindowController` (Task 8), `TeamSettings.isReady`, `L.plazaOpen` (Task 2)
- Produces:
  - `StatusItemMenu.Action.openPlaza`, `StatusItemMenu.entries(l:todayTokens:todayCost:floatingPetEnabled:plazaAvailable:)`.
    `plazaAvailable`이면 도감 항목 다음에 `Entry(title: l.plazaOpen + "…", keyEquivalent: "p", action: .openPlaza)`.
  - 앱: `openPlaza()`는 팝오버를 닫고 `plaza.show()`를 부른다. 메뉴의 `.openPlaza`와 팝오버 버튼이 이걸 쓴다.
  - 대표 포켓몬 변경 감지: `companion.representativeSubject`가 바뀌면 광장이 열려 있을 때 `refreshCharacter()`.
    관찰 방법(`withObservationTracking` 재등록 등)은 구현자 재량.
  - 닉네임 변경도 열린 광장의 이름표에 반영한다(`setNickname`).

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
func testPlazaEntryOnlyWhenAvailable() {
    let l = L(.ko)
    let off = StatusItemMenu.entries(l: l, todayTokens: 0, todayCost: nil, floatingPetEnabled: false, plazaAvailable: false)
    XCTAssertFalse(off.contains { $0?.action == .openPlaza })
    let on = StatusItemMenu.entries(l: l, todayTokens: 0, todayCost: nil, floatingPetEnabled: false, plazaAvailable: true)
    let i = on.firstIndex { $0?.action == .openPlaza }!
    XCTAssertEqual(on[i - 1]?.action, .openDex)
}
```

기존 `StatusItemMenuTests`의 `entries` 호출에는 `plazaAvailable: false`를 더한다.

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter StatusItemMenuTests`
Expected: FAIL

- [ ] **Step 3: 메뉴, 팝오버 버튼, 앱 배선 구현**

- [ ] **Step 4: 통과 확인과 빌드**

Run: `swift test --filter 'StatusItemMenuTests|Plaza|TeamLocalizationTests'`
Expected: PASS

Run: `swift build`
Expected: 경고 없이 성공(기존 경고 수보다 늘지 않음)

- [ ] **Step 5: Commit**

```bash
git add Sources/PokeTokenBar/UI/StatusItemMenu.swift Sources/PokeTokenBar/UI/PopoverView.swift Sources/PokeTokenBar/PokeTokenBarApp.swift Tests/PokeTokenBarTests/StatusItemMenuTests.swift
git commit -m "feat(plaza): open the team plaza from the menu bar"
```

### Task 10: 개발 실행 스크립트, 확인, 사용자 확인 지점

**Files:**
- Create: `scripts/plaza-dev.sh`
- Modify: `scripts/test-gate.sh` (`LOGIC_CORE`에 팀·광장 로직 파일 추가)

**Interfaces:**
- Produces: `scripts/plaza-dev.sh` — 실제 세이브를 건드리지 않고 개발 빌드로 광장을 써 보는 스크립트.
  - `$TMPDIR/ptb-plaza-dev`를 만들고, `~/Library/Application Support/PokeTokenBar/companion-state.json`과
    `sprites/` 폴더를 **복사**한다(원본은 읽기만). 이미 있으면 세이브만 다시 복사한다.
  - `PTB_STATE_DIR`를 그 폴더로 두고 `swift run PokeTokenBar`를 실행한다.
  - 시작할 때 안내를 출력한다: 메뉴바에 아이콘이 하나 더 생긴다, 설치된 앱은 그대로 둬도 된다, 개발 앱의 팀 설정은
    따로 저장된다, 설정 → 팀에서 켜기·팀 만들기·닉네임 입력 후 "광장 열기".
- `LOGIC_CORE` 추가(전체 경로):
  `Sources/PokeTokenBar/Team/TeamCode.swift`, `TeamSettings.swift`, `TeamModels.swift`, `TeamEventFactory.swift`,
  `TeamFeedStore.swift`, `TeamWire.swift`, `Sources/PokeTokenBar/Team/Plaza/PlazaMap.swift`, `PlazaWalker.swift`,
  `PlazaPose.swift`, `PlazaCamera.swift`, `PlazaCharacterLoader.swift`, `PlazaPreferences.swift`

- [ ] **Step 1: 스크립트 작성과 문법 확인**

Run: `bash -n scripts/plaza-dev.sh`
Expected: 출력 없음

- [ ] **Step 2: 관련 테스트 전부 확인**

Run: `swift test --filter 'Plaza|Team|SpriteBackURLTests|StatusItemMenuTests|LocalizedUILiteralTests'`
Expected: PASS

- [ ] **Step 3: 개발 빌드 실행 확인**

Run: `PTB_STATE_DIR=$(mktemp -d) swift run PokeTokenBar` 를 백그라운드로 띄우고 10초 뒤 프로세스가 살아 있는지 본 뒤 종료한다.
Expected: 크래시 없이 떠 있다.

- [ ] **Step 4: Commit**

```bash
git add scripts/plaza-dev.sh scripts/test-gate.sh
git commit -m "chore(plaza): add plaza dev runner and gate team logic coverage"
```

- [ ] **Step 5: 사용자 확인 (중단 지점, 스펙 9장 2번)**

사용자에게 `bash scripts/plaza-dev.sh`로 직접 걸어 보게 하고 다음을 묻는다: 타일 크기와 포켓몬 크기 비율, 기본
배율, 걷는 속도, 타일 그림 느낌, 지도 넓이. 여기서 멈춘다. 받은 의견은 이 계획의 수치(Global Constraints)를
고치는 작은 Task로 반영하고, 그 뒤에 2부 계획(팀원 표시, 말풍선, 말 걸기, 소식판, 기념사진, 알림, 네트워크,
릴리스)을 쓴다. 2부는 Mac 두 대 연결 확인(`scripts/team-probe.swift`) 결과가 있어야 시작한다.

---

## 보강: 사용자 확인 결과 반영 (2026-10-30)

사용자가 Task 10의 개발 빌드로 광장을 걸어 본 뒤 두 가지를 요청했다. 하나는 코드로 그린 지도가 엉성하니 포켓몬
게임처럼 밝고 단순한 풀밭으로 바꾸는 것이다. 다른 하나는 오른쪽에 게임 파티 화면 같은 참여자 목록을 두는 것이다.
스펙이 개정됐다(5.3, 5.4, 5.11, 5.12, 3장, 7장). 대화에서 확정한 시안은 "단순한 풀밭 광장 시안"(30×20칸)이고,
아래 수치와 좌표는 그 시안에서 그대로 가져왔다.

**보강 Global Constraints** (위 Global Constraints에 더한다):
- 타일셋: ArMM1998 "Zelda-like tilesets and sprites"의 `gfx/Overworld.png`(640×576, 16픽셀 칸)를 바꾸지 않고 그대로
  넣는다. 원본은 https://opengameart.org/sites/default/files/gfx_3.zip (175 KB, CC0)이다. 칸 좌표 `(열, 행)`은 16픽셀
  단위이고, 그림 1픽셀을 월드 2픽셀로 키운다(타일 한 칸 = 32 월드 픽셀, 지금과 같다).
- 글꼴: 갈무리 `Galmuri11.ttf`와 라이선스(`ofl.md` → `Galmuri-OFL.txt`)를 함께 넣는다. 원본은
  https://cdn.jsdelivr.net/npm/galmuri@2.40.3/dist/Galmuri11.ttf 와 https://cdn.jsdelivr.net/npm/galmuri@2.40.3/ofl.md 이다.
- 리소스는 `Sources/PokeTokenBar/Resources/Plaza/`에 두고 SwiftPM 리소스로 묶는다. 앱 코드는 `Bundle.module`을
  `PlazaResources` 한 곳에서만 쓴다.
- 레벨, HP, 진행률 같은 숫자는 목록 어디에도 넣지 않는다.
- 모든 Task의 집중 테스트 필터에 저장소 전체를 검사하는 테스트 `UsageEnvironmentTests|LocalizedUILiteralTests|TeamLocalizationTests`를
  항상 넣는다. 지난번 최종 검토에서 이 검사 테스트를 놓쳐 결함이 늦게 드러났다.

### Task 11: 리소스 번들 (타일셋, 글꼴, 출처)

**Files:**
- Create: `Sources/PokeTokenBar/Resources/Plaza/plaza-tiles.png` (= `gfx/Overworld.png`, 바이트 그대로)
- Create: `Sources/PokeTokenBar/Resources/Plaza/Galmuri11.ttf`, `Sources/PokeTokenBar/Resources/Plaza/Galmuri-OFL.txt`
- Create: `Sources/PokeTokenBar/Resources/Plaza/CREDITS.md` (타일셋: ArMM1998, CC0, 원본 주소 / 글꼴: Galmuri, SIL OFL 1.1, 원본 주소)
- Create: `Sources/PokeTokenBar/Team/Plaza/PlazaResources.swift`
- Modify: `Package.swift` (executableTarget에 `resources: [.copy("Resources/Plaza")]`)
- Modify: `scripts/build-app.sh` (첫 슬라이스의 `--show-bin-path` 아래 `PokeTokenBar_PokeTokenBar.bundle`을 `$APP/Contents/Resources/`로 복사, 없으면 실패)
- Test: `Tests/PokeTokenBarTests/PlazaResourcesTests.swift`

**Interfaces:**
- Produces:

```swift
enum PlazaResources {
    static func tileSheet() -> CGImage?          // plaza-tiles.png, 640×576
    @discardableResult static func registerFonts() -> Bool   // CTFontManagerRegisterFontsForURL(.process), 여러 번 불러도 안전
    static let fontName: String                  // Galmuri11의 PostScript 이름(파일에서 확인해 고정)
    static func font(size: CGFloat) -> NSFont    // 등록 실패 시 monospacedSystemFont 로 대체
}
```

- SwiftPM이 만든 `Bundle.module`은 번들을 못 찾으면 앱을 죽인다(`fatalError`). 그래서 `PlazaResources`는
  `Bundle.main.resourceURL`, `Bundle.main.bundleURL` 아래의 `PokeTokenBar_PokeTokenBar.bundle`을 먼저 찾는다.
  `Bundle.module`은 테스트와 `swift run`에서만 닿는 마지막 후보로 둔다. 리소스를 못 찾으면 `nil`이나 대체 글꼴을
  돌려줄 뿐, 광장을 열다가 죽지 않는다. 이 동작은 테스트로 고정한다(번들 경로를 주입할 수 있게 만든다).

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
final class PlazaResourcesTests: XCTestCase {
    func testTileSheetLoads() throws {
        let sheet = try XCTUnwrap(PlazaResources.tileSheet())
        XCTAssertEqual(sheet.width, 640); XCTAssertEqual(sheet.height, 576)
    }
    func testFontRegistersAndResolves() {
        XCTAssertTrue(PlazaResources.registerFonts())
        XCTAssertNotNil(NSFont(name: PlazaResources.fontName, size: 11))
        XCTAssertEqual(PlazaResources.font(size: 11).fontName, PlazaResources.fontName)
    }
    func testBuildScriptCopiesResourceBundle() throws {
        // scripts/build-app.sh 에 "PokeTokenBar_PokeTokenBar.bundle" 과 "Contents/Resources" 복사 줄이 있다
    }
    func testLicenseAndCreditsShipWithResources() {
        // Bundle(PlazaResources 경유)에서 Galmuri-OFL.txt, CREDITS.md 를 찾을 수 있다
    }
    func testMissingBundleReturnsNilInsteadOfCrashing() {
        // 존재하지 않는 경로를 주입하면 tileSheet() == nil, font(size:) 는 대체 글꼴
    }
}
```

- [ ] **Step 2: 실패 확인** — Run: `swift test --filter PlazaResourcesTests` → FAIL
- [ ] **Step 3: 파일 받기, 리소스·스크립트·`PlazaResources` 구현**
- [ ] **Step 4: 통과 확인** — Run: `swift test --filter 'PlazaResourcesTests|UsageEnvironmentTests|LocalizedUILiteralTests|TeamLocalizationTests'` 와 `swift build` → PASS
- [ ] **Step 5: Commit** — `feat(plaza): bundle the plaza tileset and pixel font as resources`

### Task 12: 타일셋으로 그리기와 새 풀밭 지도

**Files:**
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaMap.swift` (타일 종류 정리)
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaMapData.swift` (새 지도)
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaTileArt.swift` (코드 그림 → 타일셋 조합)
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaWindowController.swift` (지도 그림 만들 때 `PlazaResources.tileSheet()` 사용)
- Modify: `Tests/PokeTokenBarTests/PlazaMapTests.swift`, `Tests/PokeTokenBarTests/PlazaTileArtTests.swift`

**Interfaces:**
- `PlazaTile`는 다음만 남긴다. `grass "."`, `flowers "f"`, `shelter "S"`는 지나갈 수 있고, `tree "T"`, `bush "b"`, `board "N"`는
  지나갈 수 없다. `tallGrass`, `path`, `water`, `fence`, `rock`은 지운다. `PlazaMapError`, `spawn`, `shelterTiles`,
  `boardTile`의 규칙은 그대로다.
- `PlazaTileArt.mapImage(_ map: PlazaMap, sheet: CGImage) -> CGImage` (크기는 지금처럼 `width*32 × height*32`).
  `tileImage(at:in:)`는 지운다. 시트가 없을 때를 위한 대체 그림(단색 잔디)은 컨트롤러가 정한다.
- 그리는 규칙 (칸 좌표는 시트의 `(열, 행)`, 모두 2배로 그린다):
  - 바닥: 모든 칸에 잔디를 깐다. 위치로 시드를 만든 결정적 난수로 `(0,9) (1,9) (0,10) (1,10) (5,9) (8,9) (5,10) (8,10)` 중 하나를 고른다.
  - `f`: 잔디 위에 꽃 장식 `(0,8) (1,8) (2,12) (3,11) (3,12)` 중 하나를 위치 기반으로 고른다.
  - `b`: 잔디 위에 작은 덤불 `(2,14)`를 그린다.
  - `T`: 잔디 위에 2×2 둥근 나무 `(5,16)`을 엇갈린 격자로 덮는다(짝수 행과 홀수 행이 한 칸씩 어긋난다). 위쪽 나무부터
    그려 아래 나무가 위를 덮는다. `T` 칸이 맨눈에 빈 잔디로 보이면 안 된다.
  - `N`: 지도에 정확히 2×2 덩어리로 있다. 2×3 나무 게시판 `(6,6)`을 그 덩어리의 왼쪽 아래에 맞춰 그린다(그림이 한 칸 위로 솟는다).
- 새 지도 (`PlazaMapData`, 48×32):
  - 가장자리 3칸은 `T`다. 안쪽은 탁 트인 `.`이다.
  - 꽃 `f` 30~50칸과 덤불 `b` 6~10칸을 흩어 둔다. 덤불끼리 붙이지 않는다.
  - 가운데쯤 `N` 2×2 하나를 두고, 그 둘레 열린 잔디 12칸 이상을 `S`로 둔다. `spawn`은 `S` 위다.
  - 모든 지나갈 수 있는 칸이 서로 이어진다.

- [ ] **Step 1: 실패하는 테스트 작성/고치기**

```swift
// PlazaMapTests
func testBorderIsThreeTilesOfTrees() { /* x<3, y<3, x>=45, y>=29 인 칸이 모두 .tree */ }
func testOnlySimpleKinds() { /* 모든 칸이 . f S T b N 중 하나, f 30~50칸, b 6~10칸 */ }
func testBoardIsOneTwoByTwoBlock() { /* N 칸이 정확히 4개이고 2×2, 바로 아래 행 두 칸이 지나갈 수 있음 */ }
// 기존: 크기 48×32, 가장자리 막힘, spawn에서 전부 도달, 쉼터 12칸 이상, spawn이 쉼터 — 유지
// PlazaTileArtTests (시트는 PlazaResources.tileSheet())
func testMapImageSize() { /* 1536×1024 */ }
func testDeterministic() { /* 같은 입력 두 번 → 같은 바이트, 길이 = w*h*4 */ }
func testFlowerCellDiffersFromPlainGrassAndTreeCellIsNotGrass() {
    // 3×3 작은 지도로: f 칸 픽셀 ≠ 같은 잔디 변형의 . 칸 픽셀, T 칸 가운데 픽셀 색이 잔디 변형 8종의 같은 위치 색 어느 것과도 다름
}
func testArtIsUpscaledTwiceWithoutSmoothing() { /* 출력의 (0,0)과 (1,1) 픽셀이 같다(2×2 블록 단위) */ }
```

- [ ] **Step 2: 실패 확인** — Run: `swift test --filter 'PlazaMapTests|PlazaTileArtTests'` → FAIL
- [ ] **Step 3: 구현**
- [ ] **Step 4: 통과 확인** — Run: `swift test --filter 'Plaza|UsageEnvironmentTests|LocalizedUILiteralTests|TeamLocalizationTests'` → PASS
- [ ] **Step 5: Commit** — `feat(plaza): draw the plaza from the CC0 tileset and lay out a simple meadow`

### Task 13: 이름판과 도트 글꼴

**Files:**
- Create: `Sources/PokeTokenBar/Team/Plaza/PlazaNamePlate.swift`
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaScene.swift` (이름 라벨·외곽선 노드를 이름판 텍스처로 교체)
- Test: `Tests/PokeTokenBarTests/PlazaNamePlateTests.swift`

**Interfaces:**
- `enum PlazaNamePlate { static func image(text: String, isMe: Bool, scale: CGFloat) -> CGImage }`
  - 흰 바탕 `#F8F8F0`, 테두리 2pt, 모서리 4pt, 글자 `#303848`, 글꼴은 `PlazaResources.font(size: 11)`, 안쪽 여백 좌우 5pt·상하 3pt.
  - 테두리 색: 나는 `#D04848`, 나머지는 `#586078`. 아래로 2pt 짙은 그림자.
  - `scale`은 기기 픽셀 배율이다. 텍스처는 그 배율로 만들어 카메라 HUD 층에 화면 단위로 붙인다(지금처럼 또렷하게).
- 장면은 닉네임이나 배율이 바뀔 때만 이름판을 다시 만든다(매 프레임 금지).

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
func testPlateGrowsWithTextAndScale() { /* "나" < "도토리도토리", scale 2 의 폭 = scale 1 의 2배(±2px) */ }
func testMeAndOthersUseDifferentBorderColor() { /* 왼쪽 가장자리 가운데 픽셀 색이 isMe 에 따라 다르다 */ }
```

- [ ] **Step 2–4:** `swift test --filter 'PlazaNamePlateTests|PlazaWindowTests|UsageEnvironmentTests|LocalizedUILiteralTests|TeamLocalizationTests'`
- [ ] **Step 5: Commit** — `feat(plaza): pixel-font name plates`

### Task 14: 참여자 목록 (오른쪽, 파티 화면 느낌)

**Files:**
- Create: `Sources/PokeTokenBar/Team/Plaza/PlazaRoster.swift` (모델·정렬·만들기)
- Create: `Sources/PokeTokenBar/Team/Plaza/PlazaIconLoader.swift` (PokéAPI 7세대 박스 아이콘 받기·캐시)
- Create: `Sources/PokeTokenBar/Team/UI/PlazaRosterView.swift` (SwiftUI)
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaWindowController.swift` (SKView 위 오른쪽에 `NSHostingView` 얹기, 내 정보 갱신)
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaCamera.swift` (목록에 가린 폭을 고려한 초점)
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaScene.swift` (초점에 가린 폭 반영)
- Modify: `Sources/PokeTokenBar/Team/TeamLocalization.swift` (`plazaRosterTitle` "팀원", `plazaStatusOnline` "접속", `plazaStatusAway` "잠", `plazaRosterCount(online:total:)` "접속 N / M", `plazaEggName` "알")
- Modify: `Sources/PokeTokenBar/PokeTokenBarApp.swift` (컨트롤러에 내 목록 정보 제공 클로저 연결, 바뀔 때 갱신)
- Test: `Tests/PokeTokenBarTests/PlazaRosterTests.swift`, `Tests/PokeTokenBarTests/PlazaCameraTests.swift`

**Interfaces:**

```swift
enum PlazaPresence: Sendable { case online, away }
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
enum PlazaRoster {
    /// 나 → 접속 중 → 자리 비움, 같은 무리 안에서는 닉네임 순.
    static func sorted(_ entries: [PlazaRosterEntry]) -> [PlazaRosterEntry]
    /// 내 칸: 대표 포켓몬을 고르지 않았으면 키우는 포켓몬(이름 = companion.displayName, 성별 = 키우는 개체의 성별),
    /// 골랐으면 그 종(이름 = 도감 종 이름, 성별 nil), 알이면 speciesID nil·이름 L.plazaEggName·성별 nil.
    static func myEntry(memberID: String, nickname: String, subject: CompanionStore.RepresentativeSubject,
                        followsRaised: Bool, raisedName: String, raisedGender: PokemonGender?,
                        pinnedName: String?, eggName: String) -> PlazaRosterEntry
}
enum PlazaIconLoader {
    static func url(speciesID: Int) -> URL   // .../sprites/pokemon/versions/generation-vii/icons/{id}.png
    static func icon(speciesID: Int) async -> NSImage?   // SpriteStore 캐시 폴더에 "icon-<id>.png"로 캐시
}
extension PlazaCamera {
    /// 오른쪽 rightInset 포인트가 가려질 때, 내 포켓몬이 보이는 영역 가운데 오도록 초점을 오른쪽으로 민다.
    static func focus(for foot: CGPoint, rightInset: CGFloat, zoom: Int) -> CGPoint   // x + (rightInset / zoom) / 2
}
```

- 화면 (시안 "단순한 풀밭 광장 시안"의 오른쪽 목록과 같게):
  - 판: 폭 232pt, 오른쪽 위 14pt 안쪽. 135° 줄무늬 `#2D7F87`/`#2A7880`(6pt), 테두리 3pt `#1D4F55`, 안쪽 선 2pt `#5FB7BD`, 모서리 10pt.
  - 왼쪽 위 탭 "팀원"(흰 바탕 `#F8F8F0`, 글자 `#2D4048`)과 오른쪽 위 "접속 N / M"을 둔다.
  - 칸: 높이 44pt, 모서리 왼쪽 22pt·오른쪽 8pt, 위아래 반씩 두 색. 보통 `#7CC8E8`/`#5FB0D8`(테두리 `#23464C`),
    나 `#F8B878`/`#F09858`(테두리 `#8A4A28`), 자리 비움 `#A8B0C0`/`#9098A8`(테두리 `#4A5060`). 안쪽 흰 선 2pt.
  - 아이콘은 40×30이고, 접속 중이면 0.5초마다 2pt씩 위아래로 튄다. 이름 옆에 성별 ♂ `#A8D8FF`, ♀ `#FFB0C8`, 이로치 ★ `#FFE060`.
  - 배지: "접속" `#48B860`, "잠" `#9070B8`. 글꼴은 모두 `PlazaResources.font`다.
- 1부에서는 목록에 나만 있다(`presence = .online`). 2부가 팀원을 채운다.
- 장면 초점은 `PlazaCamera.focus(for: walker.footPoint, rightInset: 232 + 14, zoom:)`를 거쳐 `visibleRect`에 넣는다.

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
func testSortOrderMeOnlineAway() { /* 나, 접속(가나다), 자리 비움(가나다) 순 */ }
func testMyEntryFollowsRaisedPinnedAndEgg() { /* 세 경우의 speciesID/이름/성별 규칙 */ }
func testIconURL() { XCTAssertEqual(PlazaIconLoader.url(speciesID: 25).absoluteString,
    "https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon/versions/generation-vii/icons/25.png") }
func testFocusShiftsByHalfTheCoveredWidthInWorldUnits() { /* rightInset 246, zoom 2 → x + 61.5 */ }
func testRosterStrings() { /* L(.ko).plazaRosterCount(online: 3, total: 5) == "접속 3 / 5" 등 */ }
```

- [ ] **Step 2–4:** `swift test --filter 'PlazaRosterTests|PlazaCameraTests|PlazaWindowTests|UsageEnvironmentTests|LocalizedUILiteralTests|TeamLocalizationTests'`, `swift build --build-tests`
- [ ] **Step 5: Commit** — `feat(plaza): party-style roster on the right`

### Task 15: 확인과 두 번째 사용자 확인

- [ ] **Step 1:** 관련 테스트 전부: `swift test --filter 'Plaza|Team|SpriteBackURLTests|StatusItemMenuTests|UsageEnvironmentTests|LocalizedUILiteralTests'`
- [ ] **Step 2:** `scripts/test-gate.sh`는 컨트롤러가 샌드박스 밖에서 돌린다(전체 통과, 커버리지 75% 이상). `LOGIC_CORE`에 `PlazaRoster.swift`, `PlazaNamePlate.swift`를 더한다.
- [ ] **Step 3:** 개발 빌드 스모크 실행(10초 이상 살아 있음).
- [ ] **Step 4: Commit** — `chore(plaza): gate roster and name plate logic`
- [ ] **Step 5: 사용자 확인 (중단 지점)** — `bash scripts/plaza-dev.sh`로 새 지도, 이름판, 오른쪽 목록을 확인받는다. 여기서 멈춘다.
