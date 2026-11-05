# 광장 연못 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 광장 오른쪽 가운데에 L자 연못을 두고, Z 하나로 물가 점프(작은 물보라)·첨벙·헤엄·잠수·떠오름을 하며 근처 팀원을 적시는 물놀이를 만든다.

**Architecture:** 판정과 수치는 SpriteKit 없는 `PlazaPond`(순수)에 둔다. 연못·물가 그림은 지금 시트에서 지도 이미지에 굽고,
물보라·물결·거품은 새 `PlazaPondLayer`(풀숲 레이어와 같은 방식)가 맡는다. 헤엄은 칸 종류로 정하고, 잠수와 진화 단계는
`TeamPresence` 선택 필드로 주고받는다. 장면은 걸음·점프·잠수 변화를 보고 물보라와 젖음을 각 화면에서 똑같이 계산한다.

**Tech Stack:** Swift 6, SpriteKit, CoreGraphics, XCTest.

**Spec:** `docs/superpowers/specs/2026-11-05-plaza-pond-design.md` (배치 미리보기 `…-layout.png`)

## Global Constraints

- 작업 공간은 워크트리 `.worktrees/pond`(브랜치 `feat/plaza-pond`, 기준 `origin/main` 1cc0340)다. 메인 체크아웃은 건드리지 않는다. bare `git stash` 금지.
- 커밋 메시지·PR은 영어 Conventional Commits(`feat(team): …`), 커밋 끝에 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- 새 그림 파일·라이선스 없음. 연못·물가·연잎은 `plaza-tiles.png` 칸만 쓴다(물 (3,7), 물가 13칸, 연잎 (2,0)·(4,0)–(5,0)).
  코드로 만드는 것은 물보라 방울·물결 고리·거품·헤엄 물결 고리뿐이다. 색은 `#1E7CB8`, `#2996DB`, `#5AAEE4`, `#FFFFFF`, `#165C88`만 쓴다.
- 수치: 헤엄 걸음 0.25초(물속 달리기 없음), 첨벙 걸음 0.36초(= `PlazaActor.jumpDuration`), 헤엄 중 보이는 몫 45%(최소 월드 10px),
  잠수 6초·물 타입 15초, 젖음 2초, 거품 0.4초마다, 잠수 흐려짐 0.2초. 큰 물보라 젖음 반경 = 진화 단계(1–3, `TeamEmote.pushTiles`와 같은 범위),
  작은 물보라 반경 1.
- 방향키·달리기·팀원에게 걸어가기·따라가기·몸통박치기로 밀리기로는 물에 들어가지 않는다. 물에 들어가는 길은 첨벙(Z)뿐이다.
- 메시지: `TeamPresence`에 `isDiving: Bool?`(참일 때만), `evolutionStage: Int?`(1보다 클 때만)를 더한다. `.jump` 이모트는 바꾸지 않는다.
  물속 Z(잠수·떠오름)는 `.jump`를 보내지 않는다.
- 물보라·방울·고리·거품은 이름 있는 상한, `dt` 구동, 재사용 노드로 만든다. 타이머는 쓰지 않는다(defect-log 에너지 장).
- 아이템은 지금처럼 `itemLayoutMap`과 `PlazaItems.isShown`을 쓴다. 고정 배치(`itemLayoutRows`)는 바꾸지 않는다.
- 팀 UI 문구는 한국어로 `TeamLocalization.swift`에 둔다.

## Review Focus

- **물가에서 Z를 연타하거나 물속 칸에 누가 있을 때:** 두 번 첨벙하거나 사람이 있는 칸으로 뛰어들지 않는다. 그럴 땐 물가 점프가 된다. → Task 7 `testPlungeIsBlockedBySwimmerAndRepeatedZ`
- **연못이 없는 v2.5.617 팀원이 연못 칸으로 걸어 들어올 때:** 쉼터로 튀지 않고 헤엄치는 것으로 보인다. 그 팀원의 몸통박치기에 물속의 나는 밀리지 않는다. → Task 4 `testOldVersionTeammateOnWaterSwimsAndCannotPushMe`
- **잠수 중에 광장을 닫거나 연결이 끊길 때:** 팀원 화면에 잠수 상태가 남지 않고, 다시 열면 쉼터에서 시작한다. → Task 7 `testClosingThePlazaWhileDivingClearsIt`
- **물에 뛰어든 팀원을 따라가던 중일 때:** 따라가기가 멈추고, 나는 물가에 남는다. → Task 4 `testFollowingSomeoneWhoPlungesStopsAtTheShore`
- **잠수 중에 배경 숨기기를 켰다 끌 때:** 켜면 모두 보이고 입자가 사라진다. 끄면 숨김이 돌아온다. → Task 6 `testBackgroundHiddenShowsDiversAndRestores`

---

### Task 1: 연못 규칙 (순수)

**Files:**
- Create: `Sources/PokeTokenBar/Team/Plaza/PlazaPond.swift`, `Tests/PokeTokenBarTests/PlazaPondTests.swift`
- Modify: `scripts/test-gate.sh` (`LOGIC_CORE`에 `PlazaPond.swift`)

**Interfaces:**
- Produces:
```swift
enum PlazaPondAction: Equatable, Sendable { case jump, shoreJump, plunge(PlazaDirection), dive, surface }
enum PlazaPondShore: Equatable, Sendable { case notShore, cell(col: Int, row: Int), unsupported }
enum PlazaPond {
    static let swimStepDuration: TimeInterval = 0.25, plungeStepDuration: TimeInterval = 0.36
    static let swimVisibleFraction: CGFloat = 0.45, swimMinVisible: CGFloat = 10
    static let diveLimit: TimeInterval = 6, waterTypeDiveLimit: TimeInterval = 15
    static let wetDuration: TimeInterval = 2, bubbleInterval: TimeInterval = 0.4, diveFade: TimeInterval = 0.2
    /// 물 칸 그림은 늘 (3,7). 땅 칸의 물가 그림(5.1 표).
    static func shore(at p: TilePoint, isWater: (TilePoint) -> Bool) -> PlazaPondShore
    static func action(tile: TilePoint, facing: PlazaDirection, isDiving: Bool, canMove: Bool,
                       isWater: (TilePoint) -> Bool, isFree: (TilePoint) -> Bool) -> PlazaPondAction
    /// 작은 물보라 지점: 바라보는 쪽이 물이면 그 칸, 아니면 북·동·남·서 순서로 첫 물 칸. 물 이웃이 없으면 nil.
    static func shoreSplashTile(tile: TilePoint, facing: PlazaDirection, isWater: (TilePoint) -> Bool) -> TilePoint?
    static func splashRadius(stage: Int) -> Int                       // 1...3로 자름
    static func diveLimit(types: [String]?) -> TimeInterval            // "water"가 있으면 15, 아니면 6
    /// 젖는 대상: 땅에 선 배우 중 물보라 칸과 체비셰프 거리 ≤ radius, 일으킨 사람 제외. id nil = 나.
    static func wetTargets(splash: TilePoint, radius: Int, splasher: String?,
                           actors: [(id: String?, tile: TilePoint)], isWater: (TilePoint) -> Bool) -> [String?]
    static func swimSink(spriteHeight h: CGFloat) -> CGFloat           // h − max(min(10, h), h·0.45)
    /// 한 걸음 시간: 땅→물 0.36, 물→물 0.25, 물→땅 0.15, 땅→땅 running ? 0.075 : 0.15
    static func stepDuration(from: TilePoint, to: TilePoint, running: Bool, isWater: (TilePoint) -> Bool) -> TimeInterval
    /// 걸어가기 목표: 물속 팀원에게 가장 가까운(맨해튼) 물 칸 중 상하좌우에 땅이 있는 칸. 없으면 nil.
    static func nearestEdgeWater(to target: TilePoint, isWater: (TilePoint) -> Bool, isLand: (TilePoint) -> Bool) -> TilePoint?
}
```
`action` 판정: 물속이면 `isDiving ? .surface : .dive`. 땅에서 `canMove`이고 바라보는 칸이 물이면서 `isFree`면 `.plunge(facing)`.
그 밖에 상하좌우 이웃에 물이 있으면 `.shoreJump`, 없으면 `.jump`.

- [ ] **Step 1: 실패하는 테스트를 쓴다** (`PlazaPondTests`. 물은 테스트 안의 `Set<TilePoint>`)
  - `testShoreCellsFollowTheWaterSide`: 물 (5..7, 5..6) 기준으로 확인한다.
    - 물 북쪽 땅 (6,4) → `.cell(3,6)`, 남쪽 (6,7) → `.cell(3,8)`, 서쪽 (4,5) → `.cell(2,7)`, 동쪽 (8,5) → `.cell(4,7)`.
    - 대각선만 물인 (4,4) → `.cell(2,6)`, (8,4) → `.cell(4,6)`, (4,7) → `.cell(2,8)`, (8,7) → `.cell(4,8)`.
    - 안쪽 모서리 네 칸은 L자 물로 확인한다: 남+동 → `(3,10)`, 남+서 → `(2,10)`, 북+동 → `(3,9)`, 북+서 → `(2,9)`.
    - 물과 떨어진 칸 → `.notShore`. 남북 양쪽이 물인 칸 → `.unsupported`. 대각선 두 칸만 물인 칸 → `.unsupported`.
  - `testZMeansPlungeShoreJumpJumpDiveSurface`: 물을 바라보고 빈 칸 → `.plunge(.right)`, 물을 바라보지만 칸이 찼음 → `.shoreJump`,
    `canMove == false`(알·집중) → `.shoreJump`, 물과 떨어짐 → `.jump`, 물속 → `.dive`, 물속 잠수 중 → `.surface`.
  - `testShoreSplashPrefersTheFacedWater`: 바라보는 쪽이 물이면 그 칸, 아니면 북·동·남·서 순서로 첫 물 칸, 없으면 nil.
  - `testWetTargetsAreLandActorsInRangeButNotTheSplasher`: 반경 2에서 거리 2인 땅 배우는 들어가고, 거리 3·물속 배우·일으킨 사람은 빠진다. 나(id nil)도 대상이 될 수 있다.
  - `testNumbers`: `splashRadius(0) == 1`, `(2) == 2`, `(5) == 3`; `diveLimit(types: ["water","flying"]) == 15`, `(["fire"]) == 6`, `(nil) == 6`;
    `swimSink(72) == 72 − 32.4`, `swimSink(8) == 0`, `swimSink(20) == 10`; `plungeStepDuration == 0.36`.
  - `testStepDurationsByTileKind`: 땅→물 0.36, 물→물 0.25(달려도 0.25), 물→땅 0.15, 땅→땅 0.15 / 달리면 0.075.
  - `testNearestEdgeWaterForAWalkTarget`: 가운데 물 칸이 목표면 가장 가까운 테두리 물 칸, 모두 물이 아니면 nil.
- [ ] **Step 2: 실패를 확인한다** — `swift test --filter PlazaPondTests` → 컴파일 실패
- [ ] **Step 3: `PlazaPond.swift`를 위 시그니처대로 구현하고 `test-gate.sh`에 더한다**
- [ ] **Step 4: 통과를 확인한다** — `swift test --filter PlazaPondTests` → PASS
- [ ] **Step 5: 커밋한다** — `feat(team): add plaza pond rules`

---

### Task 2: 연못 칸, 지도, 그림 굽기

**Files:**
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaMap.swift`, `PlazaMapData.swift`, `PlazaTileArt.swift`, `Tests/PokeTokenBarTests/PlazaMapTests.swift`, `PlazaTileArtTests.swift`
- Create: `Tests/PokeTokenBarTests/PlazaPondMapTests.swift`

**Interfaces:**
- Consumes: `PlazaPond.shore(at:isWater:)`
- Produces: `PlazaTile.pond`(`"w"`, `isWalkable == false`), `PlazaMap.isWater(_ p: TilePoint) -> Bool`(지도 밖은 false)

- [ ] **Step 1: 실패하는 테스트를 쓴다** (`PlazaPondMapTests`. `legacyRows`는 `git show 1cc0340:Sources/PokeTokenBar/Team/Plaza/PlazaMapData.swift`의 `rows` 32줄을 그대로 옮긴다)
  - `testPondIsBlockedWater`: `PlazaTile(rawValue: "w") == .pond`, `!PlazaTile.pond.isWalkable`, `map.isWater((32,17))`, `!map.isWater((31,17))`.
  - `testPondMatchesTheSpec`: 물 칸 집합이 정확히 x 32–37 × y 17–19와 x 35–37 × y 15–16(24칸)이다.
  - `testOnlyOpenGroundChanged`: `w`는 legacy에서 `.`/`f`다. 그 밖의 칸은 두 지도가 같다. 물가 칸(물의 8방향 이웃) 26칸도 legacy에서 `.`/`f`다.
  - `testEveryShoreTileIsDrawable`: 모든 땅 칸의 `PlazaPond.shore`가 `.unsupported`가 아니다.
  - `testPondKeepsItsDistance`: 물+물가 영역과 덤불(`b`)은 체비셰프 ≥ 2, `S`/`N`/`F`와는 ≥ 3, `g`와는 ≥ 2.
  - `testItemsOnThePondAreHidden`: `PlazaItems.openTiles(in: map)`에 물 칸이 없다. `itemLayoutRows`는 바뀌지 않았다(1cc0340과 같다).
  - `PlazaMapTests.testOnlySimpleKinds`의 허용 집합에 `"w"`를 더한다.
  - `PlazaTileArtTests.testPondAndShoreAreBaked`: 작은 지도(물 2×2와 둘레)를 굽는다.
    - 물 칸 픽셀이 시트 (3,7)의 2배와 같다.
    - 물 북쪽 땅 칸이 (3,6)을 잔디 위에 겹친 것과 같다.
    - 물가 칸에 꽃(`f`)이 있어도 꽃이 그려지지 않는다.
- [ ] **Step 2: 실패를 확인한다** — `swift test --filter "PlazaPondMapTests|PlazaMapTests|PlazaTileArtTests"` → 컴파일 실패
- [ ] **Step 3: 구현한다**
  - `case pond = "w"`를 막힌 쪽에 더한다. `PlazaMapData.rows`를 설계 부록 A로 바꾼다(`itemLayoutRows`는 그대로).
  - `mapImage`: 물 칸은 (3,7)로, 물가 땅 칸은 잔디 위에 `PlazaPond.shore` 칸을 2배로 굽는다. 물가 칸의 꽃은 건너뛴다.
  - 연잎은 (33,18)에 (2,0) 한 칸, (35,15)–(36,15)에 (4,0)–(5,0) 두 칸을 굽는다.
- [ ] **Step 4: 통과를 확인한다** — `swift test --filter "PlazaPondMapTests|PlazaMapTests|PlazaTileArtTests|PlazaItemsTests|PlazaTallGrassMapTests|PlazaCampfire"` → PASS
- [ ] **Step 5: 커밋한다** — `feat(team): add the plaza pond to the map`

---

### Task 3: 잠수·진화 단계 주고받기

**Files:**
- Modify: `Sources/PokeTokenBar/Team/TeamWire.swift`(`TeamPresence`), `TeamSession.swift`, `TeamRuntime.swift:44-46`, `Sources/PokeTokenBar/Team/Plaza/PlazaScene.swift`(`PlazaSceneMember`), `PlazaWindowController.swift:1006-1012`
- Test: `Tests/PokeTokenBarTests/TeamWireTests.swift`, `TeamSessionTests.swift`

**Interfaces:**
- Produces:
```swift
// TeamPresence: var isDiving: Bool?  (참일 때만)  ·  var evolutionStage: Int?  (1보다 클 때만)
// TeamSession 멤버 모델: var isDiving = false  ·  var evolutionStage = 1   (받을 때 TeamEmote.pushTiles로 1...3)
// TeamSession
init(..., evolutionStage: @escaping () -> Int = { 1 }, clock: ...)
func updateDiving(_ diving: Bool)          // 바뀔 때만 presence 방송
// PlazaSceneMember: var isDiving = false  ·  var evolutionStage = 1
```
`TeamRuntime`은 `evolutionStage: { companion.representativeEvolutionStage }`를 넘긴다. 창 컨트롤러는 두 필드를 `PlazaSceneMember`로 옮긴다.

- [ ] **Step 1: 실패하는 테스트를 쓴다**
  - `TeamWireTests.testPondFieldsAreOptionalAndOmitted`: 잠수 아님·단계 1이면 JSON에 두 키가 없다. 두 키가 없는 옛 JSON도 디코드된다.
  - `TeamSessionTests.testPresenceCarriesDivingAndStage`: 단계 3을 주는 세션 → 방송된 presence의 `evolutionStage == 3`.
    `updateDiving(true)` 두 번 → 방송은 한 번이고 `isDiving == true`. 받은 쪽 멤버는 `isDiving == true`, `evolutionStage == 3`.
    받은 단계 7 → 3, 없음 → 1.
- [ ] **Step 2: 실패를 확인한다** — `swift test --filter "TeamWireTests|TeamSessionTests"` → 컴파일 실패
- [ ] **Step 3: 구현한다** (`focusEndsAt`·`updateFocus(endsAt:)`와 같은 방식)
- [ ] **Step 4: 통과를 확인한다** — `swift test --filter "TeamWireTests|TeamSessionTests|TeamRuntimeTests|PlazaMembersTests"` → PASS
- [ ] **Step 5: 커밋한다** — `feat(team): share diving and evolution stage in presence`

---

### Task 4: 물속 움직임 규칙

**Files:**
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaWalker.swift`, `PlazaRemoteMotion.swift`, `PlazaScene.swift`(update의 `walker.advance`, `pushMe`, `resolvedTile`, `walk(toMember:)`, `advanceWalkToMember`, 팀원 `advance`)
- Create: `Tests/PokeTokenBarTests/PlazaPondMotionTests.swift`

**Interfaces:**
- Consumes: `PlazaPond.stepDuration/nearestEdgeWater`, `PlazaMap.isWater`
- Produces:
```swift
// PlazaWalker
mutating func plunge(_ d: PlazaDirection)          // 다음 advance에서 canEnter와 상관없이 d로 한 칸, 0.36초. 누른 키보다 먼저.
mutating func advance(by dt: TimeInterval, canEnter: (TilePoint) -> Bool,
                      stepDuration: ((TilePoint, TilePoint, Bool) -> TimeInterval)? = nil)  // nil이면 지금 규칙
// PlazaRemoteMotion
mutating func advance(by dt: TimeInterval, stepDuration: ((TilePoint, TilePoint, Bool) -> TimeInterval)? = nil)
// PlazaScene
var isMeInWater: Bool { get }
func memberIsInWater(_ id: String) -> Bool?
```
장면 규칙:
- 내가 물속이면 물 칸과 걸을 수 있는 땅 칸에 들어갈 수 있다. 땅이면 지금처럼 걸을 수 있는 칸만 들어간다.
- 걸음 시간은 `PlazaPond.stepDuration`이다. 물속에서는 `wantsToRun`을 무시한다.
- 팀원 칸이 물이면 쉼터로 보내지 않는다(`resolvedTile`).
- 내가 물속이면 `pushMe`는 아무것도 하지 않는다(별은 지금처럼).
- `walk(toMember:)`: 내가 물속이면 false다. 상대가 물속이고 옆에 빈 땅이 없으면 `nearestEdgeWater` 옆까지 간다.
- 따라가는 팀원의 칸이 물이 되면 따라가기를 멈춘다.

- [ ] **Step 1: 실패하는 테스트를 쓴다** (`PlazaPondMotionTests`. 진짜 지도. 물가 (31,18)·(32,16), 물 (32,18))
  - `testArrowKeysNeverEnterTheWater`: (31,18)에서 오른쪽을 1초 누른다 → 칸이 그대로이고 오른쪽을 본다. Shift를 눌러도 같다.
  - `testPlungeEntersWaterInOneJumpStep`: (31,18)에서 `plunge(.right)` → 0.36초 뒤 (32,18). 그 전 0.2초에는 아직 걸음 중이다.
  - `testSwimmingStepsTakeAQuarterSecondAndClimbOut`: 물속에서 오른쪽 → 0.25초에 한 칸, Shift도 0.25다. 왼쪽으로 땅에 나오는 걸음은 0.15초다.
  - `testOldVersionTeammateOnWaterSwimsAndCannotPushMe`: 팀원 칸 (33,18) → `memberTiles`에 (33,18)이 그대로 있다(쉼터 아님).
    나는 물속에서 `pushMe(.left, tiles: 2)`를 받아도 그 자리다.
  - `testFollowingSomeoneWhoPlungesStopsAtTheShore`: (30,18)의 팀원을 따라가다 그 팀원 칸이 (32,18)(물)이 된다 → `followingMember == nil`이고 나는 땅이다.
  - `testWalkingToASwimmer`: 물 가운데 팀원 (34,18)에게 걸어가기 → 테두리 물 칸 옆 땅에 도착한다. 내가 물속이면 `walk(toMember:)`가 false다.
  - `PlazaWalkerTests`/`PlazaRemoteMotionTests`에 `stepDuration` 닫힘 사용과 `plunge` 단위 테스트를 더한다.
- [ ] **Step 2: 실패를 확인한다** — `swift test --filter PlazaPondMotionTests` → 컴파일 실패
- [ ] **Step 3: 구현한다**
- [ ] **Step 4: 통과를 확인한다** — `swift test --filter "PlazaPondMotionTests|PlazaWalkerTests|PlazaRemoteMotionTests|PlazaCollisionTests|PlazaMembersTests|PlazaCampfire"` → PASS
- [ ] **Step 5: 커밋한다** — `feat(team): swim in the plaza pond and keep land moves out of it`

---

### Task 5: 물보라·물결·거품 레이어

**Files:**
- Create: `Sources/PokeTokenBar/Team/Plaza/PlazaPondArt.swift`, `PlazaPondLayer.swift`, `Tests/PokeTokenBarTests/PlazaPondLayerTests.swift`
- Modify: `scripts/test-gate.sh` (`PlazaPondArt.swift`)

**Interfaces:**
- Produces:
```swift
enum PlazaPondArt {                         // 색은 Global Constraints의 다섯 가지만
    static func droplet() -> CGImage          // 2×2 시트 픽셀
    static func ring(radius: Int) -> CGImage  // 타원 테두리(가로:세로 = 2:1)
    static func bubble() -> CGImage           // 3×3
    static func swimRing() -> CGImage         // 헤엄 물높이 고리, 가로 12 시트 픽셀
    static func wetImage(scale: CGFloat) -> CGImage   // "💧" 이모지를 12pt로
}
@MainActor final class PlazaPondLayer: SKNode {
    static let maxDroplets = 48, maxRings = 12, maxBubbles = 24
    func splash(at tile: TilePoint, big: Bool, delay: TimeInterval = 0)   // 작은: 방울 4·고리 1, 큰: 방울 10·고리 2(두 번째 0.12초 뒤)
    func bubble(at tile: TilePoint)
    func update(dt: TimeInterval)
    func setHidden(_ hidden: Bool)            // 모두 버리고 숨긴다. 숨김 중 호출은 무시한다.
    var dropletCount: Int { get }; var ringCount: Int { get }; var bubbleCount: Int { get }
}
```
움직임:
- 방울: 수명 0.5초, 위로 튀고 중력으로 떨어진다. z 2.5.
- 고리: 수명 0.6초, 반지름이 월드 4px에서 14px로 커지며 흐려진다. z 0.06.
- 거품: 수명 0.6초, 위로 10px 오르며 흐려진다. z 0.07.

위치는 칸 가운데, 2 월드px 격자에 맞춘다.

- [ ] **Step 1: 실패하는 테스트를 쓴다**
  - `testArtUsesOnlyPondColours`: `droplet/ring/bubble/swimRing`의 불투명 픽셀 색이 다섯 가지 안에 있다.
  - `testSmallAndBigSplash`: 작은 물보라 → 방울 4·고리 1이고, 0.6초 뒤 0. 큰 물보라 → 방울 10·고리 1이었다가 0.12초 뒤 고리 2.
  - `testDelayedSplashStartsLater`: `delay: 0.36` → 0.3초엔 0, 0.4초엔 방울 10.
  - `testBubblesRiseAndFade`: `bubble` 3번 → 3이고 0.7초 뒤 0.
  - `testCapsHoldUnderABurst`: 큰 물보라 20번 → 매 update `dropletCount <= 48`, `ringCount <= 12`. 1초 뒤 모두 0.
  - `testHidingDropsEverything`: 입자가 있을 때 `setHidden(true)` → 모두 0. 숨김 중 `splash`는 무시하고, `setHidden(false)` 뒤 다시 된다.
  - `testNodesAreReused`: 같은 물보라를 두 번(사이에 1초) → 자식 노드 수가 늘지 않는다.
- [ ] **Step 2: 실패를 확인한다** — `swift test --filter PlazaPondLayerTests` → 컴파일 실패
- [ ] **Step 3: 구현한다** (`PlazaTallGrassLayer`와 같은 구조)
- [ ] **Step 4: 통과를 확인한다** — `swift test --filter "PlazaPondLayerTests|PlazaTallGrassLayerTests"` → PASS
- [ ] **Step 5: 커밋한다** — `feat(team): add pond splashes, ripples and bubbles`

---

### Task 6: 헤엄과 잠수 모습

**Files:**
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaActor.swift`, `PlazaScene.swift`, `PlazaWindowController.swift`(`PlazaScene(…)` 생성에 `pondVisuals:`)
- Create: `Tests/PokeTokenBarTests/PlazaPondSceneTests.swift`

**Interfaces:**
- Consumes: Task 1–5
- Produces:
```swift
// PlazaActor
func place(foot:pose:in:concealment:isMe:swimSink: CGFloat = 0)   // swimSink > 0: 아래를 잘라 윗부분만, 그림자 숨김, 물높이 고리 보임
var visibleSpriteHeight: CGFloat { get }; var isSwimRingVisible: Bool { get }; var shadowOpacity: CGFloat { get }(있으면 그대로)
// PlazaScene
init(..., tallGrass: PlazaTallGrassArt? = nil, pondVisuals: Bool = false)
private(set) var isDiving: Bool
var diveLimit: TimeInterval            // 기본 PlazaPond.diveLimit, 창 컨트롤러가 타입으로 바꾼다
var onDivingChange: ((Bool) -> Void)?  // 시간 끝, 물 밖으로 나감, 광장 닫힘으로 잠수가 끝날 때
func setDiving(_ on: Bool)             // 물속에서만 켠다
var pondLayer: PlazaPondLayer? { get }
var myVisibleHeight: CGFloat { get }; func memberVisibleHeight(_ id: String) -> CGFloat?
func memberIsDiving(_ id: String) -> Bool?
```
규칙:
- 헤엄: 그 배우의 칸이 물이고, `pondVisuals`이며 배경이 보일 때 `swimSink = PlazaPond.swimSink(spriteHeight:)`.
- 잠수 가려진 정도: 0.2초에 걸쳐 0→1. 풀숲 가려진 정도와 `max`로 합쳐 지금의 `concealment`에 넣는다.
  불투명도·이름표 내리기·내 40%는 풀숲 규칙 그대로다.
- 내 잠수는 장면 `dt`로 재고 `diveLimit`이 지나면 끈다. 물 밖으로 나가는 걸음에서도 끈다. 둘 다 `onDivingChange(false)`를 부른다.
- 팀원 잠수는 `PlazaSceneMember.isDiving`을 따른다.
- 배경 숨기기나 `pondVisuals == false`면 잘림·잠수 숨김·레이어를 끈다. 상태(물속 위치·잠수 여부)는 그대로다.

- [ ] **Step 1: 실패하는 테스트를 쓴다** (`PlazaPondSceneTests`. 진짜 지도, `pondVisuals: true`, 32×48 프레임)
  - `testSwimmersShowOnlyTheirTop`: 물속 팀원 → `memberVisibleHeight ≈ 72 × 0.45`, 고리 보임, 그림자 0. 땅으로 나오면 72.
  - `testDivingHidesAndTimesOut`: 물속에서 `setDiving(true)` → 0.3초 뒤 `myOpacity == 0.4`, 이름표 내려옴.
    `diveLimit = 6`에서 6.1초 뒤 `isDiving == false`이고 `onDivingChange(false)`가 한 번 불린다.
  - `testWaterTypeDivesLonger`: `diveLimit = 15` → 6.1초엔 아직 잠수, 15.1초엔 끝.
  - `testLeavingTheWaterEndsTheDive`: 잠수 중 땅 쪽으로 걸음 → `isDiving == false`, 콜백 한 번.
  - `testTeammateDivingFollowsPresence`: `isDiving: true`인 물속 팀원 → `memberOpacity == 0`. 거짓으로 바꾸면 → 1.
  - `testBackgroundHiddenShowsDiversAndRestores`: 잠수 중 배경 숨기기 → 불투명도 1, 레이어 비어 있음. 다시 끄면 0.4.
  - `testWithoutPondVisualsNothingIsCut`: `pondVisuals: false` → 물속에서도 보이는 높이 72, 잠수해도 불투명도 1.
- [ ] **Step 2: 실패를 확인한다** — `swift test --filter PlazaPondSceneTests` → 컴파일 실패
- [ ] **Step 3: 구현한다.** 창 컨트롤러는 타일 시트를 읽었을 때 `pondVisuals: true`로 장면을 만든다.
- [ ] **Step 4: 통과를 확인한다** — `swift test --filter "PlazaPondSceneTests|PlazaTallGrassSceneTests|PlazaCharacterTests|PlazaCampfire"` → PASS
- [ ] **Step 5: 커밋한다** — `feat(team): show swimmers and divers in the plaza pond`

---

### Task 7: Z 연결, 물보라와 젖음

**Files:**
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaScene.swift`, `PlazaActor.swift`, `PlazaWindowController.swift`(`handleJumpKey`, `tackle`, 멤버 메뉴, 장면 준비·닫기),
  `Sources/PokeTokenBar/PokeTokenBarApp.swift`(타입 조회 주입), `Sources/PokeTokenBar/Team/TeamLocalization.swift`, `TEAM.md`
- Test: `Tests/PokeTokenBarTests/PlazaPondSceneTests.swift`, `PlazaWindowTests.swift`

**Interfaces:**
- Consumes: Task 1–6
- Produces:
```swift
// PlazaScene
func pondAction(canMove: Bool) -> PlazaPondAction
func plunge(_ d: PlazaDirection)              // walker.plunge + playJump(memberID: nil)
var myEvolutionStage: Int                     // 기본 1
// PlazaActor
func showWet()                                // 💧 2초. 말풍선 자리와 별개의 노드
var isWet: Bool { get }
// PlazaWindowController init에 추가
pokemonTypes: @escaping (Int) async -> [String]? = { _ in nil }
```
장면(배우마다 풀숲 `GrassWatch`처럼 연못 기록을 둔다):
- 땅→물 걸음이 시작되면 그 걸음 시간 뒤 도착 칸에 큰 물보라를 낸다. 반경은 그 배우의 단계다(나는 `myEvolutionStage`, 팀원은 `PlazaSceneMember.evolutionStage`).
- 물속 잠수가 꺼지면(내 Z·시간 끝·팀원 필드) 그 칸에 큰 물보라를 낸다. 물 밖으로 나가며 꺼질 때는 내지 않는다.
- 땅에서 점프 착지(lift > 0 → 0) 때 `shoreSplashTile`이 있으면 작은 물보라(반경 1)를 낸다.
- 물보라마다 `PlazaPond.wetTargets`로 젖는 배우를 골라 `showWet()`한다. 잠수 중이면 0.4초마다 그 칸에 `bubble`.
- 배경 숨기기나 `pondVisuals == false`면 입자와 💧를 내지 않는다.

창 컨트롤러:
- `handleJumpKey`(0.36초 간격은 그대로)는 `pondAction(canMove: scene.canWalk && !isFocusing)`로 나눈다.
  - `.jump`/`.shoreJump`: 지금처럼 `playJump` + `.jump`
  - `.plunge(d)`: `scene.plunge(d)` + `.jump`
  - `.dive`/`.surface`: `scene.setDiving` + `session.updateDiving`(`.jump` 없음)
- `scene.onDivingChange`는 `session.updateDiving`으로 잇는다. 광장을 닫을 때 잠수 중이면 끈다.
- 내 종이 바뀔 때마다 `pokemonTypes(speciesID)`로 `scene.diveLimit = PlazaPond.diveLimit(types:)`를 정하고, `scene.myEvolutionStage = evolutionStage()`로 맞춘다.
  `PokeTokenBarApp`은 `{ try? await pokeAPI.pokemonDetails(speciesID: $0).types }`를 넘긴다.
- 몸통박치기: 나나 상대 칸이 물이면 `tackle`은 아무것도 하지 않는다. 멤버 메뉴에서 `.tackle`을 뺀다(집중 규칙 옆).
- 단축키 안내 Z 문구: `plazaJump`를 `"점프 · 물놀이"`로 바꾼다.
- `TEAM.md` 조작법 표의 Z 행 뒤에 아래 행을 넣는다.
  `| 연못 | 오른쪽 가운데에 연못이 있습니다. 방향키로는 물에 들어가지 않습니다. 물가에서 Z를 누르면 물보라가 튀고, 물 쪽을 바라보고 Z를 누르면 첨벙 뛰어듭니다. 물속에서는 머리만 보이고 방향키로 헤엄치며(조금 느립니다) 땅 쪽으로 가면 나옵니다. 물속에서 Z를 누르면 잠수해 거품만 보이고 이름표만 물 위에 남으며, 다시 Z를 누르거나 6초(물 타입 포켓몬은 15초)가 지나면 첨벙 떠오릅니다. 첨벙 뛰어들거나 떠오르면 진화 단계만큼(1~3칸) 둘레 물가에 있는 팀원이 젖어 💧가 잠깐 뜹니다. 물속에서는 몸통박치기를 하지도 받지도 않고, 물에 들어간 팀원은 따라갈 수 없습니다 |`
  "알려진 한계"에는 `- v2.5.617 이하를 쓰는 팀원의 광장에는 연못이 없어서, 그 팀원 화면에서는 헤엄치거나 잠수하는 팀원이 풀밭에 서 있는 것으로 보입니다.`를 더한다.

- [ ] **Step 1: 실패하는 테스트를 쓴다**
  - `PlazaPondSceneTests`:
    - `testPlungeSplashesBigAndWetsByStage`: 단계 3인 내가 (31,18)에서 첨벙한다. 0.4초 안에 큰 물보라가 나고, 둘레 3칸 안 땅의 팀원은 `isWet`, 4칸 밖은 아니다.
    - `testShoreJumpSplashesSmall`: (31,18)에서 아래를 보고 점프 → 착지 때 방울 4, 거리 1 팀원만 젖는다.
    - `testSurfacingSplashesButLeavingTheWaterDoesNot`: 잠수→Z 떠오름 → 큰 물보라. 잠수 중 땅으로 나감 → 없음.
    - `testTeammateSurfacingSplashesWithTheirStage`: 팀원 필드 `isDiving` true→false, `evolutionStage: 2` → 반경 2로 젖음.
    - `testDiversBlowBubbles`: 잠수 1초 → 거품 2개 이상.
    - `testWetDoesNotClearAChatBubble`: 한마디가 떠 있는 팀원이 젖어도 `shownChat`이 그대로다.
    - `testPlungeIsBlockedBySwimmerAndRepeatedZ`: 바라보는 물 칸에 팀원 → `pondAction == .shoreJump`. 첨벙 걸음 중 다시 `pondAction` → 물속 판정(`.dive`)이 아니라 걸음이 끝나야 바뀌고, 0.36초 간격으로 두 번째 첨벙이 없다.
  - `PlazaWindowTests`:
    - `testZRoutesToPlungeDiveAndSurface`: 가짜 세션으로 확인한다. 첨벙은 `.jump`를 한 번 보낸다. 잠수와 떠오름은 `updateDiving(true/false)`만 부르고 `.jump`는 없다.
    - `testClosingThePlazaWhileDivingClearsIt`: 잠수 중 창을 닫으면 `updateDiving(false)`를 부른다.
    - `testNoTackleInWater`: 내가 물속이면 C를 눌러도 몸통박치기를 보내지 않는다. 물속 팀원의 메뉴에 몸통박치기가 없다.
    - `testWaterTypeSetsTheDiveLimit`: `pokemonTypes`가 `["water"]`를 주면 `scene.diveLimit == 15`이다.
- [ ] **Step 2: 실패를 확인한다** — `swift test --filter "PlazaPondSceneTests|PlazaWindowTests"` → 실패
- [ ] **Step 3: 구현한다**
- [ ] **Step 4: 통과를 확인한다** — `swift test --filter "PlazaPond|PlazaWindowTests|PlazaTallGrassSceneTests|PlazaEmoteTests|PlazaChatTests|PlazaCampfire|TeamLocalizationTests"` → PASS
- [ ] **Step 5: 커밋한다** — `feat(team): splash, plunge and dive with Z in the plaza pond`

---

### Task 8: 기념사진의 헤엄·잠수

**Files:**
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaPhotoRenderer.swift`, `PlazaActor.swift`(`photoActor`)
- Test: `Tests/PokeTokenBarTests/PlazaPhotoTests.swift`

**Interfaces:**
- Produces: `PlazaPhotoActor.sink: CGFloat = 0`. 월드 px만큼 그림을 아래로 내려 그리고, 발 선 아래는 자른다. `sink > 0`이면 그림자를 그리지 않는다.
  `photoActor`는 마지막 `place`의 `swimSink`를 채운다. 잠수는 이미 있는 `opacity`·`plateBaseY`로 나온다.
- [ ] **Step 1: 실패하는 테스트를 쓴다**
  - `testASwimmerShowsOnlyTheTop`: `sink 39.6`인 72px 단색 배우 → 발 선 아래에 배우 색이 없다. 발 선 위 보이는 높이가 32.4(±1, 사진 배율 반영)다. 그림자 색이 없다.
  - `testPhotoInputCarriesSwimAndDive`: 물속 팀원 → 그 배우 `sink > 0`. 잠수 팀원 → `opacity == 0`, `plateBaseY != nil`.
- [ ] **Step 2: 실패 확인** — `swift test --filter PlazaPhotoTests` → 실패
- [ ] **Step 3: 구현한다**
- [ ] **Step 4: 통과 확인** — `swift test --filter "PlazaPhotoTests|PlazaGroupPhotoTests|PlazaCampfire"` → PASS
- [ ] **Step 5: 커밋한다** — `feat(team): show swimmers and divers in plaza photos`

---

### Task 9: 전체 검증과 PR

- [ ] **Step 1:** `./scripts/test-gate.sh` → 통과, 커버리지 임계값 통과
- [ ] **Step 2:** 새 파일(`PlazaPond*.swift`)과 바뀐 `PlazaScene`·`PlazaActor`·`PlazaWalker`·`PlazaRemoteMotion`·`PlazaPhotoRenderer`·`TeamSession` 구간을
  `xcrun llvm-cov show … --show-regions`로 보고, 브랜치가 더한 줄의 `^0`를 확인한다. 도달할 수 있는 분기는 테스트를 더하고, 도달할 수 없으면 판단을 기록한다.
- [ ] **Step 3:** 화면 밖 `SKRenderer` 렌더(창·활성화·키 입력 없음, 임시 env-gated XCTest, 커밋 안 함)를 만든다.
  - 물가 점프 → 첨벙 → 헤엄 → 잠수 → 떠오름 GIF와 숫자 점검
  - 전후 지도
  - 사진(P)

  사용자가 눈으로 확인한다.
- [ ] **Step 4:** `origin/main`이 움직였으면 머지하고, TEAM.md 버전 문구를 확인한다. `.agents/skills/prepare-pr/SKILL.md`로 PR을 만든다.
  제목은 `feat(team): play in a plaza pond`, 이미지는 gist `r23-`에 올린다.
