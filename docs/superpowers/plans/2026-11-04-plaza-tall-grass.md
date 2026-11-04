# 광장 풀숲 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 광장 지도 여덟 곳에 RedVoxel 풀숲을 깔고, 풀숲에 선 포켓몬은 숨기고(이름표는 남김), 움직임에 따라 풀을 흔든다.

**Architecture:** 규칙(9칸 선택, 가려진 정도, 흔들림 신호·변위, 이름표 높이)은 SpriteKit 없는 순수 타입 `PlazaTallGrass`에 둔다.
그림 자르기는 `PlazaTallGrassArt`(CoreGraphics)가 맡는다. 풀숲 칸은 기존 지도 이미지에 굽는다. 앞 띠·흔들림 겹침 그림·잎 조각은
새 SpriteKit 노드 `PlazaTallGrassLayer`가 맡는다. `PlazaScene`은 걸음 시작을 감지해 신호를 보내고, 가려진 정도를 `PlazaActor`에 넘긴다.
기념사진은 `PlazaPhotoRenderer`에 앞 띠와 투명도를 더한다. 팀원끼리 주고받는 메시지는 바꾸지 않는다.

**Tech Stack:** Swift 6, SpriteKit, CoreGraphics, CryptoKit(파일 해시 테스트), XCTest.

**Spec:** `docs/superpowers/specs/2026-11-04-plaza-tall-grass-design.md` (배치 미리보기 `…-layout.png`)

## Global Constraints

- 작업 공간은 워크트리 `.worktrees/tall-grass`(브랜치 `feat/plaza-tall-grass`, `origin/main` 기준)다. 메인 체크아웃은 다른 세션이 쓰므로 건드리지 않는다.
- `feat/plaza-campfire`(다른 세션)와 `PlazaMap`·`PlazaMapData`·`PlazaScene`·`PlazaPhotoRenderer`·`PlazaWindowController`·`TEAM.md`, 지도·사진·아이템·타일 테스트가 겹친다.
  그 브랜치가 먼저 `main`에 들어가면 PR 전에 `origin/main`으로 리베이스하고 충돌을 푼다. 모닥불 칸 `F`는 지나갈 수 없고, 아이템 후보에서는 풀밭처럼 센다.
- 이 브랜치에서 작업한다. 커밋 메시지와 PR은 영어 Conventional Commits(`feat(team): …`)로 쓴다.
- `TeamWire`/네트워크 메시지는 바꾸지 않는다. 숨었는지는 각 화면이 위치만 보고 정한다.
- 풀숲 그림은 `Sources/PokeTokenBar/Resources/Plaza/plaza-tallgrass.png` 하나다. OpenGameArt 원본 `tilemap.png`(208×144)를 바이트 그대로 넣는다.
  SHA-256 `d8b02d00acf54d3daf21c33e1cd7873ba6d82b3aa949989258e5d785885319fd`. 파일을 고치지 않고, 칸은 실행 중에 자른다.
- 쓰는 칸은 시트 열 0–2 × 행 6–8 의 9칸 조각뿐이다. 앞 띠는 시트 행 9–15, 출렁이는 윗부분은 시트 행 0–6이다.
- 새 풀 그림을 코드로 그리지 않는다. 잎 조각만 예외이고, 색은 `#99E550`, `#6ABE30`, 테두리 `#222034`만 쓴다.
- 아이템 후보 칸 목록(`PlazaItems.candidates(in:)`)은 순서까지 바뀌지 않는다. 풀숲은 `.`과 `f` 칸만 바꾼다.
- 고정값: 가려진 정도 보간(걸음 진행률), 점프 드러남 7 월드px, 숨은 이름표 높이는 발 위 30 월드px, 내 포켓몬 최소 불투명도 0.4,
  움찔 간격 1.7초, 출발 칸 흔들림 지연 0.05초, 잎 3개·0.55초.
- 흔들림 길이와 변위(시트 픽셀): 출렁(센) 0.3초 `[+s, −s, 0]` 0.1초씩, 출렁(약) 0.2초 `[+s, 0]`, 들썩(센) 0.15초 위로 1, 들썩(약) 0.1초 위로 1.
- 흔들림·잎은 이름 있는 상한, `dt` 구동, 노드 재사용으로 만든다. 타이머(`Timer`, `DispatchQueue.asyncAfter`)는 쓰지 않는다(defect-log 에너지 장).
- 광장은 세이브를 쓰지 않는다. 팀 UI 문구 규칙(한국어, `TeamLocalization.swift`)은 그대로다. 이 기능은 새 UI 문구가 없다.

## Review Focus

- **Shift로 달려 풀숲을 가로지를 때**(0.075초/칸): 흔들림이 겹쳐도 상한을 넘지 않고, 끝난 겹침 그림이 남지 않는다. → Task 5 `testRunningAcrossGrassStaysUnderTheCaps`
- **팀원이 한 번에 멀리 옮겨져 풀숲에 들어갈 때**(대기열 초과나 잠에서 깬 뒤 `snap`): 걸음 없이 바로 숨고, 흔들림은 없다. → Task 6 `testATeammateSnappedIntoGrassHidesWithoutARustle`
- **흔들리는 중에 배경 숨기기를 켤 때**: 겹침 그림과 잎이 하나도 남지 않고, 다시 끄면 띠가 깨끗이 돌아온다. → Task 5 `testHidingDropsEverything`
- **알(둥지)인 팀원이 몸통박치기로 풀숲에 밀려 들어갈 때**: 알, 그림자, 둥지 앞 테두리가 모두 숨는다. → Task 6 `testAnEggInTheGrassHidesWithItsNest`
- **배율 1·3, 1배 화면에서**: 숨은 이름표가 풀숲 칸 바로 위에 붙어 있다. → Task 6 `testTheHiddenNameSitsOnTheGrassAtEveryZoom`

---

### Task 1: 에셋, 리소스 로딩, 출처

**Files:**
- Create: `Sources/PokeTokenBar/Resources/Plaza/plaza-tallgrass.png`
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaResources.swift`, `Sources/PokeTokenBar/Resources/Plaza/CREDITS.md`
- Test: `Tests/PokeTokenBarTests/PlazaResourcesTests.swift`

**Interfaces:**
- Produces: `PlazaResources.tallGrassSheet() -> CGImage?`, `PlazaResources.tallGrassSheet(in bundle: Bundle?) -> CGImage?` (`tileSheet`과 같은 방식, 리소스 이름 `plaza-tallgrass`)

- [ ] **Step 0: 워크트리에서 설계 문서를 커밋한다** (워크트리와 브랜치는 이미 있다)

```bash
cd .worktrees/tall-grass
git add docs/superpowers/specs/2026-11-04-plaza-tall-grass-design.md docs/superpowers/specs/2026-11-04-plaza-tall-grass-layout.png docs/superpowers/plans/2026-11-04-plaza-tall-grass.md
git commit -m "docs(team): add the plaza tall grass design and plan"
```

- [ ] **Step 1: 원본을 받아 해시를 확인한다**

```bash
curl -sL -o Sources/PokeTokenBar/Resources/Plaza/plaza-tallgrass.png https://opengameart.org/sites/default/files/tilemap_0.png
shasum -a 256 Sources/PokeTokenBar/Resources/Plaza/plaza-tallgrass.png
```
Expected: `d8b02d00acf54d3daf21c33e1cd7873ba6d82b3aa949989258e5d785885319fd`. 다르면 멈추고 보고한다.

- [ ] **Step 2: 실패하는 테스트를 쓴다** (`PlazaResourcesTests`)
  - `testTallGrassSheetLoads`: `PlazaResources.tallGrassSheet()` 가 nil이 아니고 208×144다.
  - `testTallGrassSheetIsTheUnmodifiedOriginal`: 번들의 `plaza-tallgrass.png` 바이트의 CryptoKit SHA-256 hex가 위 값과 같다. 라이선스 "변경 없음" 표기를 지키는 가드다.
  - `testCreditsNameTheTallGrassLicense`: 번들의 `CREDITS.md` 에 `RedVoxel`, `CC-BY-SA 3.0`, `https://creativecommons.org/licenses/by-sa/3.0/`,
    `https://opengameart.org/content/pokemon-inspired-16x16-tiles`, `unmodified` 가 모두 들어 있다.
  - `testMissingBundleReturnsNilInsteadOfCrashing` 에 `XCTAssertNil(PlazaResources.tallGrassSheet(in: nil))` 를 더한다.

- [ ] **Step 3: 실패를 확인한다** — `swift test --filter PlazaResourcesTests` → `tallGrassSheet` 가 없어서 컴파일이 실패한다.

- [ ] **Step 4: `tallGrassSheet` 를 구현하고 `CREDITS.md` 끝에 아래를 그대로 붙인다**

```markdown
## Tall grass (plaza-tallgrass.png)
- "Pokemon inspired 16x16 tiles" (`tilemap.png`, unmodified) by RedVoxel
- License: CC-BY-SA 3.0 (https://creativecommons.org/licenses/by-sa/3.0/). This file is not under the app's MIT license.
- Copyright notice: https://red-voxel.itch.io/ - RedVoxel
- Source: https://opengameart.org/content/pokemon-inspired-16x16-tiles
```

- [ ] **Step 5: 통과를 확인한다** — `swift test --filter PlazaResourcesTests` → PASS
- [ ] **Step 6: 커밋한다** — `feat(team): bundle the RedVoxel tall grass tiles with credits`

---

### Task 2: 풀숲 칸과 지도 배치

**Files:**
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaMap.swift`, `Sources/PokeTokenBar/Team/Plaza/PlazaMapData.swift`, `Tests/PokeTokenBarTests/PlazaMapTests.swift`
- Create: `Tests/PokeTokenBarTests/PlazaTallGrassMapTests.swift`

**Interfaces:**
- Produces: `PlazaTile.tallGrass` (`rawValue` `"g"`, `isWalkable == true`)

- [ ] **Step 1: 실패하는 테스트를 쓴다** (`PlazaTallGrassMapTests`. 바꾸기 전 지도는 `git show $(git merge-base HEAD origin/main):Sources/PokeTokenBar/Team/Plaza/PlazaMapData.swift` 의
  32줄을 `legacyRows` 상수로 그대로 옮긴다. 리베이스로 모닥불이 들어오면 `legacyRows` 도 그 지도로 다시 옮긴다)
  - `testTallGrassIsWalkable`: `PlazaTile(rawValue: "g") == .tallGrass`, `.tallGrass.isWalkable`.
  - `testOnlyOpenGroundBecameGrass`: 모든 칸에서, 새 지도가 `g`이면 `legacyRows`는 `.` 또는 `f`이고, 그 밖의 칸은 두 지도가 같다.
  - `testItemCandidatesMatchTheMapBeforeTallGrass`: `PlazaItems.candidates(in: try PlazaMap(rows: legacyRows)) == PlazaItems.candidates(in: PlazaMapData.map)` (순서 포함). 지금 값은 1,062칸이다.
  - `testPatchesAreSolidRectanglesAtLeastTwoByTwo`: `g` 의 4방향 연결 덩어리마다 경계 상자를 꽉 채우고, 너비·높이가 2 이상이다. 덩어리는 8개다.
  - `testPatchesKeepApartAndClearOfBushesShelterAndBoard`: 서로 다른 덩어리의 칸 사이 체비셰프 거리 > 1, 덤불(`b`)과 > 1, 쉼터(`S`)·팻말(`N`)과 > 2.
    모닥불 칸 `F` 가 지도에 있으면(리베이스 뒤) 그것과도 > 2이고, 모닥불 자리 (36–37, 23–24)는 지금 지도에서도 2칸 안에 `g` 가 없다.
  - `testPatchesCoverAboutATenthOfTheOpenGround`: 안쪽(x 3..<45, y 3..<29) 1,092칸 중 `g` 비율이 0.05 이상 0.12 이하다. 지금 값은 111칸이다.
  - `PlazaMapTests.testOnlySimpleKinds` 의 허용 집합에 `"g"` 를 더한다(꽃 범위 30…50은 그대로 통과).

- [ ] **Step 2: 실패를 확인한다** — `swift test --filter "PlazaTallGrassMapTests|PlazaMapTests"` → `.tallGrass` 가 없어서 컴파일이 실패한다.
- [ ] **Step 3: `PlazaTile` 에 `case tallGrass = "g"` 를 지나갈 수 있는 쪽에 더하고, `PlazaMapData.rows` 를 설계 문서 부록 A의 32줄로 바꾼다.** 주석의 문자 설명에 `g`를 더한다.
- [ ] **Step 4: 통과를 확인한다** — `swift test --filter "PlazaTallGrassMapTests|PlazaMapTests|PlazaItemsTests|PlazaPathfinderTests"` → PASS
- [ ] **Step 5: 커밋한다** — `feat(team): add tall grass patches to the plaza map`

---

### Task 3: 풀숲 규칙과 걸음 진행률

**Files:**
- Create: `Sources/PokeTokenBar/Team/Plaza/PlazaTallGrass.swift`, `Tests/PokeTokenBarTests/PlazaTallGrassTests.swift`
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaWalker.swift`, `Sources/PokeTokenBar/Team/Plaza/PlazaRemoteMotion.swift`, `scripts/test-gate.sh` (`LOGIC_CORE`에 `PlazaTallGrass.swift`)

**Interfaces:**
- Produces:
```swift
struct PlazaStep: Equatable, Sendable { let from: TilePoint; let to: TilePoint; let progress: Double }
// PlazaWalker, PlazaRemoteMotion: 걷는 중이면 지금 걸음, 서 있으면 nil
var currentStep: PlazaStep? { get }

struct PlazaTallGrassSlice: Hashable, Sendable { let col: Int; let row: Int }   // 0...2, 시트 칸 (col, 6 + row)
enum PlazaRustleKind: Equatable, Sendable { case sway(Int) /* +1 오른쪽, −1 왼쪽 */; case bounce }
struct PlazaRustleCue: Equatable, Sendable { let tile: TilePoint; let kind: PlazaRustleKind; let strong: Bool; let delay: TimeInterval }

enum PlazaTallGrass {
    static let sheetRowOffset = 6, frontFromRow = 9, swayRows = 7, leavesPerRustle = 3
    static let revealLift: CGFloat = 7, hiddenPlateLift: CGFloat = 30, myMinimumOpacity: CGFloat = 0.4
    static let twitchInterval: TimeInterval = 1.7, leaveDelay: TimeInterval = 0.05, leafLife: TimeInterval = 0.55
    static func slice(at p: TilePoint, isGrass: (TilePoint) -> Bool) -> PlazaTallGrassSlice
    static func concealment(tile: TilePoint, step: PlazaStep?, jumpLift: CGFloat, isGrass: (TilePoint) -> Bool) -> CGFloat
    static func opacity(concealment: CGFloat, isMe: Bool) -> CGFloat
    /// 장면 y(위로). 이름표 바닥을 둘 높이.
    static func plateBaseY(spriteTopY: CGFloat, footSceneY: CGFloat, concealment: CGFloat) -> CGFloat
    static func cues(from: TilePoint, to: TilePoint, isGrass: (TilePoint) -> Bool) -> [PlazaRustleCue]
    static func duration(_ kind: PlazaRustleKind, strong: Bool) -> TimeInterval
    /// 시트 픽셀. dy −1 = 위로. 끝났으면 nil.
    static func offset(_ kind: PlazaRustleKind, strong: Bool, elapsed: TimeInterval) -> (dx: Int, dy: Int)?
}
```

- [ ] **Step 1: 실패하는 테스트를 쓴다** (`PlazaTallGrassTests`. 풀숲은 테스트 안의 `Set<TilePoint>`로 준다)
  - `testSliceFollowsNeighbours`: 3×3 덩어리의 왼쪽 위 칸 → `(0,0)`, 위 가운데 → `(1,0)`, 가운데 → `(1,1)`, 오른쪽 아래 → `(2,2)`.
    2×2의 네 칸은 모서리 네 개다. 2×4의 왼쪽 열 둘째 칸은 `(0,1)` 이다.
  - `testConcealmentStandingInsideAndOutside`: 걸음이 없을 때 풀숲 칸 → 1, 밖 → 0.
  - `testConcealmentBlendsAcrossAStep`: 밖→풀숲 진행률 0.25 → 0.25, 풀숲→밖 0.25 → 0.75, 풀숲→풀숲 → 1, 밖→밖 → 0.
  - `testAJumpRevealsAndLandingHidesAgain`: 풀숲에서 lift 0 → 1, 3.5 → 0.5, 7 → 0, 14 → 0.
  - `testMyOpacityNeverDropsBelowFortyPercent`: `opacity(concealment: 1, isMe: true) == 0.4`, `opacity(concealment: 1, isMe: false) == 0`,
    `opacity(concealment: 0.3, isMe: false) == 0.7`, `opacity(concealment: 0.3, isMe: true) == 0.7` (정확도 1e-9).
  - `testThePlateDropsToJustAboveTheGrass`: spriteTop 200, footSceneY 100에서 가려진 정도 0 → 200, 0.25 → 165, 0.5 → 130, 1 → 130.
  - `testHorizontalStepsSwayTheWayTheyGo`: (4,6)→(5,6), 풀숲 {(5,6),(6,6)} → `[cue((5,6), .sway(1), strong, 0)]`.
    (6,6)→(5,6) → `[cue((5,6), .sway(-1), true, 0), cue((6,6), .sway(-1), false, 0.05)]`.
  - `testVerticalStepsBounce`: 위로 풀숲에 들어감 → `.bounce` 센 신호 하나. 풀숲에서 아래로 나감 → 출발 칸 `.bounce` 약한 신호 하나, 지연 0.05.
  - `testNoCuesOutsideGrass`: 밖→밖 → `[]`.
  - `testSwayAndBounceOffsets`: 출렁 센(s=1) 0.05→(1,0), 0.15→(−1,0), 0.25→(0,0), 0.31→nil. 출렁 약 0.05→(1,0), 0.15→(0,0), 0.21→nil.
    들썩 센 0.1→(0,−1), 0.16→nil. 들썩 약 0.05→(0,−1), 0.11→nil. `duration` 값은 0.3, 0.2, 0.15, 0.1이다.
  - `testWalkerAndRemoteMotionExposeTheirStep`: 걷기 — `press(.right)` 뒤 `advance(by: 0.075)` → `currentStep == PlazaStep(from: p, to: p+x, progress: 0.5)`, 다 가면 nil.
    팀원 — `moveTo(p+x)` 뒤 `advance(by: 0.075)` → 같은 값.
- [ ] **Step 2: 실패를 확인한다** — `swift test --filter PlazaTallGrassTests` → 컴파일 실패
- [ ] **Step 3: 구현한다.** `currentStep` 은 두 타입 모두 기존 `stepFrom`/`stepElapsed`/`stepLength`로 만든다(`progress = min(1, stepElapsed / stepLength)`).
  `concealment` 는 `(1−p)·g(from) + p·g(to)`(걸음이 없으면 `g(tile)`)에 lift가 있으면 `max(0, 1 − lift / revealLift)`를 곱한다.
  `plateBaseY` 는 `spriteTop + (footSceneY + hiddenPlateLift − spriteTop) · min(1, concealment · 2)` 이다.
- [ ] **Step 4: 통과를 확인한다** — `swift test --filter "PlazaTallGrassTests|PlazaWalkerTests|PlazaRemoteMotionTests"` → PASS
- [ ] **Step 5: 커밋한다** — `feat(team): add tall grass hiding and rustle rules`

---

### Task 4: 풀숲 그림 자르기와 지도 굽기

**Files:**
- Create: `Sources/PokeTokenBar/Team/Plaza/PlazaTallGrassArt.swift`, `Tests/PokeTokenBarTests/PlazaTallGrassArtTests.swift`
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaTileArt.swift`, `Sources/PokeTokenBar/Team/Plaza/PlazaWindowController.swift:82-92`, `Tests/PokeTokenBarTests/PlazaTileArtTests.swift`, `scripts/test-gate.sh` (`PlazaTallGrassArt.swift`)

**Interfaces:**
- Consumes: `PlazaResources.tallGrassSheet()`, `PlazaTallGrassSlice`, `PlazaTallGrass.slice/frontFromRow/swayRows/sheetRowOffset`
- Produces:
```swift
struct PlazaTallGrassArt: @unchecked Sendable {
    init?(sheet: CGImage)                                // 208×144가 아니면 nil
    static func load() -> PlazaTallGrassArt?             // PlazaResources.tallGrassSheet().flatMap(init)
    func tile(_ s: PlazaTallGrassSlice) -> CGImage       // 16×16 시트 픽셀
    func front(_ s: PlazaTallGrassSlice) -> CGImage      // 16×16, 행 0..<frontFromRow 투명
    func top(_ s: PlazaTallGrassSlice) -> CGImage        // 16×16, 행 swayRows..<16 투명
    let leaves: [CGImage]                                // 두 장, 각 4×4 시트 픽셀
}
static func mapImage(_ map: PlazaMap, sheet: CGImage, tallGrass: PlazaTallGrassArt? = nil) -> CGImage   // PlazaTileArt
```
잎 두 장은 아래 2×2 무늬(`l` `#99E550`, `m` `#6ABE30`, `.` 투명)에 칠한 칸을 4방향으로 1픽셀 `#222034` 테두리로 감싼 4×4 그림이다.
A = `["ll", "lm"]`, B = `["l.", "mm"]`.

- [ ] **Step 1: 실패하는 테스트를 쓴다**
  - `testInitRejectsAnotherSheet`: 16×16 그림 → nil. `PlazaTallGrassArt.load()` → nil 아님.
  - `testEachSliceIsItsSheetCell`: 9칸 모두 `tile(s)` 의 RGBA 바이트가 시트의 `(s.col·16, (6+s.row)·16, 16, 16)` 영역과 같다.
  - `testFrontKeepsOnlyTheLowBand`: `front` 의 행 0–8은 알파 0, 행 9–15는 `tile` 과 같다. `testTopKeepsOnlySwayRows` 는 행 0–6만 남는다.
  - `testLeavesUseOnlyThePackGreens`: 잎의 불투명 픽셀 색이 {`#99E550`, `#6ABE30`, `#222034`} 안에 있다.
  - `PlazaTileArtTests.testTallGrassIsBakedOnlyWithTheArt`: `smallMap("g")` 를 `tallGrass: art`로 구우면 (2,0) 칸이 `smallMap(".")` 와 다르다.
    `tallGrass: nil` 이면 (2,0) 칸이 `smallMap(".")` 와 같다(그림을 못 읽으면 풀밭).
- [ ] **Step 2: 실패를 확인한다** — `swift test --filter "PlazaTallGrassArtTests|PlazaTileArtTests"` → 컴파일 실패
- [ ] **Step 3: 구현한다.** `mapImage` 는 `.tallGrass` 칸에 잔디를 깐 뒤, `PlazaTallGrass.slice(at:isGrass:)` 로 고른 칸 그림을 2배(보간 없음)로 겹친다.
  기존 `Canvas.plot` 방식을 쓰도록 슬라이스용 `SheetPixels` 를 만든다. 창 컨트롤러는 `PlazaTallGrassArt.load()` 를 프로세스당 한 번 읽는다
  (`cachedMapImage` 옆에 `private static var cachedTallGrass: PlazaTallGrassArt??`). 그 값을 `mapImage` 에 넘기고, Task 6에서 장면에도 넘긴다.
- [ ] **Step 4: 통과를 확인한다** — `swift test --filter "PlazaTallGrassArtTests|PlazaTileArtTests|PlazaPhotoTests"` → PASS
- [ ] **Step 5: 커밋한다** — `feat(team): bake tall grass into the plaza map image`

---

### Task 5: 풀숲 레이어 (앞 띠, 흔들림, 잎)

**Files:**
- Create: `Sources/PokeTokenBar/Team/Plaza/PlazaTallGrassLayer.swift`, `Tests/PokeTokenBarTests/PlazaTallGrassLayerTests.swift`

**Interfaces:**
- Consumes: `PlazaTallGrassArt`, `PlazaTallGrass`, `PlazaRustleCue`, `PlazaMap`
- Produces:
```swift
@MainActor final class PlazaTallGrassLayer: SKNode {
    static let maxRustles = 24, maxLeaves = 36
    init(map: PlazaMap, art: PlazaTallGrassArt)
    func isGrass(_ p: TilePoint) -> Bool            // 숨김 상태면 늘 false
    func rustle(_ cue: PlazaRustleCue)              // 풀숲 칸이 아니면 무시, cue.delay 뒤 시작
    func update(dt: TimeInterval)
    func setHidden(_ hidden: Bool)                  // 띠·겹침·잎을 숨기고 진행 중인 흔들림과 잎을 버린다
    // 테스트용
    var activeRustles: [(tile: TilePoint, kind: PlazaRustleKind, strong: Bool)] { get }
    var leafCount: Int { get }
    var bandCount: Int { get }
    func bandZ(at p: TilePoint) -> CGFloat?
    func bandOffset(at p: TilePoint) -> CGPoint?    // 월드 px, 장면 좌표(y 위로)
    func overlayOffset(at p: TilePoint) -> CGPoint? // 흔들리는 겹침 그림의 월드 px 변위, 없으면 nil
}
```
배치 규칙:
- **앞 띠:** 풀숲 칸마다 노드 하나를 둔다. `anchorPoint .zero`, 위치 `(x·32, worldHeight − (y+1)·32)`, 크기 32×32, 텍스처 `art.front(slice)`(`.nearest`),
  z는 `1 + (y·32 + 31) / worldHeight` 이다.
- **겹침 그림:** 노드 풀에서 꺼내 쓴다. z 0.05(지도 위, 그림자 0.5 아래)이고, 출렁이면 `art.top`, 들썩이면 `art.tile` 을 쓴다.
  변위는 `offset` 의 (dx, dy) × 2 월드px이고 장면 y는 −dy다. 들썩일 때는 그 칸 띠도 같은 만큼 옮긴다.
  한 칸에 새 흔들림이 오면 진행 중인 것을 바꾼다. 상한을 넘으면 가장 오래된 것을 끝낸다.
- **잎:** 센 신호마다 `leavesPerRustle` 개를 만든다. 시작점은 칸 가운데, 칸 위에서 0.3칸 아래다.
  속도 vx `[-10, 9, 1]`(출렁이면 각 +12·s), vy `[-30, -34, -42]` 월드px/수명이고, 위치는 `start + v·k + (0, 40·k²)`(k = 경과/수명, y는 아래로)다.
  위치는 2 월드px 격자에 맞추고, z는 2.5, 크기는 8×8 월드px다. 상한을 넘으면 새 잎은 만들지 않는다.

- [ ] **Step 1: 실패하는 테스트를 쓴다** (`PlazaMapData.map` 과 `PlazaTallGrassArt.load()`. A 덩어리 왼쪽 위는 (5,5))
  - `testOneBandPerGrassTileBetweenItsRowAndTheNext`: `bandCount == 111`. `bandZ(at: (6,6))` 가 `1 + (6·32+28)/H` 보다 크고 `1 + (7·32+28)/H` 보다 작다.
  - `testSwayLeansTheTipsThenSpringsBack`: `.sway(1)` 센 신호 → 0.05초 `overlayOffset == (2,0)`, 0.15초 `(-2,0)`, 0.25초 `(0,0)`, 0.35초 nil, `activeRustles` 빔. 띠는 늘 `(0,0)`.
  - `testBounceLiftsTheTileAndItsBand`: `.bounce` 센 → 0.05초 `overlayOffset == (0,2)`, `bandOffset == (0,2)`. 0.2초 뒤 nil과 `(0,0)`.
  - `testDelayedCueStartsLater`: 지연 0.05 → 0.03초엔 비활성, 0.06초엔 활성.
  - `testAStrongRustleThrowsThreeLeavesThatSettle`: 센 신호 뒤 `leafCount == 3`, 0.6초 뒤 0. 약한 신호는 0.
  - `testRunningAcrossGrassStaysUnderTheCaps`: 서로 다른 풀숲 칸 40곳에 0.075초 간격으로 센 신호를 넣는다. 매 update마다
    `activeRustles.count <= maxRustles`, `leafCount <= maxLeaves`이고, 1초 뒤 모두 0이며 모든 `overlayOffset` 이 nil이다.
  - `testHidingDropsEverything`: 흔들림 중 `setHidden(true)` → `activeRustles` 빔, `leafCount == 0`, `isGrass((6,6)) == false`, 띠 노드가 숨는다.
    `setHidden(false)` → 띠가 다시 보이고 `bandOffset == (0,0)`, 겹침 없음.
  - `testCuesOffTheGrassAreIgnored`: 풀숲 아닌 칸 신호 → 아무것도 없다.
- [ ] **Step 2: 실패를 확인한다** — `swift test --filter PlazaTallGrassLayerTests` → 컴파일 실패
- [ ] **Step 3: 구현한다** — 위 배치 규칙대로. 시간은 `update(dt:)` 로만 흐른다.
- [ ] **Step 4: 통과를 확인한다** — `swift test --filter PlazaTallGrassLayerTests` → PASS
- [ ] **Step 5: 커밋한다** — `feat(team): add a tall grass layer with rustles and leaves`

---

### Task 6: 장면에 숨기·흔들기 연결

**Files:**
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaActor.swift`, `Sources/PokeTokenBar/Team/Plaza/PlazaScene.swift`, `Sources/PokeTokenBar/Team/Plaza/PlazaWindowController.swift:285-288`, `TEAM.md`
- Create: `Tests/PokeTokenBarTests/PlazaTallGrassSceneTests.swift`

**Interfaces:**
- Consumes: Task 3–5의 모든 것
- Produces:
```swift
// PlazaActor
func place(foot: CGPoint, pose: PlazaSpriteChoice, in context: PlazaActorContext, concealment: CGFloat = 0, isMe: Bool = false)
private(set) var concealment: CGFloat          // 마지막 place 값. 기념사진이 쓴다
private(set) var isMeForConcealment: Bool
var characterOpacity: CGFloat { get }          // 테스트용
var nestFrontOpacity: CGFloat { get }          // 테스트용
// PlazaScene
init(map: PlazaMap, mapImage: CGImage, start: TilePoint, zoom: Int, nickname: String, tallGrass: PlazaTallGrassArt? = nil)
var tallGrassLayer: PlazaTallGrassLayer? { get }
var myOpacity: CGFloat { get }
func memberOpacity(_ id: String) -> CGFloat?
func memberNestFrontOpacity(_ id: String) -> CGFloat?
```
장면이 할 일:
- `tallGrass` 가 있으면 레이어를 만들어 자식으로 둔다. `setBackgroundHidden` 은 `layer.setHidden` 을 부른다.
  "풀숲인가"는 `tallGrassLayer?.isGrass(p) ?? false` 다(그림이 없거나 배경이 숨으면 아무도 숨지 않는다).
- `layout()` 에서 나와 팀원마다 `PlazaTallGrass.concealment(tile:step:jumpLift:isGrass:)` 를 구해 `place(…, concealment:, isMe:)` 로 넘긴다.
  배우는 그림·그림자·둥지 앞 테두리 알파를 `PlazaTallGrass.opacity` 로 맞춘다. 이름표 바닥은
  `plateBaseY(spriteTopY: top, footSceneY: worldHeight − foot.y, concealment:)` 를 기존 `platePosition(…topY:)` 에 넘긴다.
- `update` 에서 `advanceAnimation` 뒤 `advanceTallGrass(by: dt)` 를 돈다.
  - 나(`walker.currentStep`)와 팀원(`motion.currentStep`)마다 지난번 `(from, to)` 와 다르면 `PlazaTallGrass.cues` 를 레이어로 보낸다. 걸음 없이 칸이 바뀌는 `snap` 은 신호가 없다.
  - 가려진 정도가 1이고, 걸음이 없고, lift가 0인 배우마다 시간을 쌓는다. `twitchInterval` 마다 그 칸에 `.sway(±1)` 약한 신호를 번갈아 보낸다.
    조건이 깨지면 0으로 돌린다.
  - `layer.update(dt:)`.
- `playJump`: 기존 착지 먼지와 같은 `run(.sequence([.wait(jumpDuration), .run{…}]))` 에서, 그 배우의 칸이 풀숲이면 `.bounce` 약한 신호를 보낸다.
- `playSparkle`: 그 배우의 가려진 정도가 0.5 넘으면 origin y를 `worldHeight − foot.y + hiddenPlateLift` 로 한다.
- `PlazaWindowController.prepareScene` 은 Task 4의 `cachedTallGrass` 를 `tallGrass:` 로 넘긴다.

- [ ] **Step 1: 실패하는 테스트를 쓴다** (`PlazaTallGrassSceneTests`. 진짜 지도와 `PlazaTallGrassArt.load()`, `PlazaCollisionTests`처럼 800×600 장면과 1/30초 `step` 헬퍼를 쓴다.
  A 덩어리는 x 5–11, y 5–8. 팀원 그림은 4×4 `CGImage` 로 만든 `PlazaCharacterFrames` 를 `setMemberFrames` 로 준다)
  - `testATeammateInTheGrassIsHiddenButTheirNameStays`: 팀원 (7,6) → `memberOpacity == 0`, 이름판 보임. 같은 팀원을 (7,10)으로 옮기면 → 1이고, `memberNamePlateTop` 이 숨었을 때보다 위다.
  - `testIWalkInAndFadeToFortyPercent`: 나 (4,6)에서 오른쪽 한 칸 → 걸음 중간 `myOpacity` 가 (0.4, 1) 사이이고, 다 걸은 뒤 0.4.
  - `testStepsIntoGrassRustleTheWayIGo`: (4,6)에서 오른쪽 → 첫 프레임 뒤 `activeRustles` 에 `((5,6), .sway(1), true)`.
    (5,9)에서 위 → `((5,8), .bounce, true)`.
  - `testAStillHiddenTeammateTwitches`: 팀원 (7,6)에서 1.8초 지나는 동안 그 칸 `.sway` 약한 흔들림이 한 번 이상 보인다. 걷는 동안에는 움찔이 없다.
  - `testAJumpInGrassPopsOutThenLandsWithABounce`: 나 (6,6). `playJump(memberID: nil)` 뒤 0.18초에 `myOpacity == 1`, 0.4초에 0.4.
    착지 즈음 `activeRustles` 에 `((6,6), .bounce, false)`.
  - `testHidingTheBackgroundShowsEveryone`: 팀원 (7,6), `setBackgroundHidden(true)` → `memberOpacity == 1`, `activeRustles` 빔.
  - `testWithoutTheArtNobodyHides`: `tallGrass: nil` 장면 → 팀원 (7,6) `memberOpacity == 1`, `tallGrassLayer == nil`.
  - `testATeammateSnappedIntoGrassHidesWithoutARustle`: 팀원 (20,20) → `applyMembers` 로 (7,6)(거리 > 1, `snap`) → `memberOpacity == 0`, `activeRustles` 빔.
  - `testAnEggInTheGrassHidesWithItsNest`: `isEgg = true` 그림인 팀원 (7,6) → `memberOpacity == 0`, `memberNestFrontOpacity == 0`.
  - `testTheHiddenNameSitsOnTheGrassAtEveryZoom`: 배율 1·3 × `backingOverride` 1·2마다, 숨은 팀원 이름판이 같은 팀원이 보일 때보다
    `(그림 높이 − 30) × 배율` 만큼(1포인트 안) 아래에 있다.
  - `testAHiddenTeammatesSparkleBurstsAtTheirName`: 팀원 (7,6), `playSparkle(memberID:)` → `sparkleCenter.y` 가 `worldHeight − foot.y + 30` 근처(±1)다.
- [ ] **Step 2: 실패를 확인한다** — `swift test --filter PlazaTallGrassSceneTests` → 컴파일 실패
- [ ] **Step 3: 구현한다** — 위 "장면이 할 일" 그대로.
- [ ] **Step 4: 통과를 확인한다** — `swift test --filter "PlazaTallGrass|PlazaCharacterTests|PlazaCollisionTests|PlazaMembersTests|PlazaEmoteTests|PlazaChatTests"` → PASS
- [ ] **Step 5: `TEAM.md` 를 고친다**
  - 조작법 표의 "광장 아이템" 행 아래에 다음 행을 넣는다.
    `| 풀숲 | 광장 군데군데에 풀숲이 있습니다. 걸어 들어가면 포켓몬과 그림자가 사라지고 이름표만 풀숲 위에 남습니다. 움직이면 지나가는 칸의 풀이 흔들립니다. 좌우로 가면 풀끝이 그쪽으로 출렁이고, 위아래로 가면 들썩입니다. 가만히 있어도 가끔 움찔합니다. 풀숲에서 점프(Z)하면 잠깐 몸이 드러납니다. 내 포켓몬은 내 화면에서만 반투명하게 보입니다. 숨어 있어도 말 걸기, 인사, 몸통박치기, 따라가기는 그대로 되고, 작은 지도의 점도 그대로 보입니다. 배경을 숨기면 풀숲도 사라지고 아무도 숨지 않습니다 |`
  - "알려진 한계" 끝에 `- v2.5.613 이하를 쓰는 팀원의 광장에는 풀숲이 없어서, 그 팀원 화면에서는 아무도 숨지 않습니다.` 를 더한다.
  - "출처"에 `- 풀숲 그림: RedVoxel, "Pokemon inspired 16x16 tiles" (CC-BY-SA 3.0, 변경 없이 사용)` 를 더한다.
- [ ] **Step 6: 커밋한다** — `feat(team): hide Pokémon in tall grass and rustle it as they move`

---

### Task 7: 기념사진의 풀숲과 숨은 팀원

**Files:**
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaPhotoRenderer.swift`, `Sources/PokeTokenBar/Team/Plaza/PlazaActor.swift` (`photoActor`), `Sources/PokeTokenBar/Team/Plaza/PlazaScene.swift` (`photoInput`), `Sources/PokeTokenBar/Team/Plaza/PlazaTallGrassLayer.swift`
- Test: `Tests/PokeTokenBarTests/PlazaPhotoTests.swift`

**Interfaces:**
- Consumes: `PlazaActor.concealment/isMeForConcealment`, `PlazaTallGrass.opacity/hiddenPlateLift`, `PlazaTallGrassLayer`
- Produces:
```swift
// PlazaPhotoActor 에 추가
var opacity: CGFloat = 1                 // 그림·그림자·둥지 앞 테두리
var plateBaseY: CGFloat? = nil           // 월드 y(아래로), 이름표 바닥. nil이면 지금처럼 머리 위
struct PlazaPhotoBand { let image: CGImage; let origin: CGPoint; let size: CGSize; let sortY: CGFloat }   // 월드, y 아래로
// PlazaPhotoInput 에 추가
var bands: [PlazaPhotoBand] = []
// PlazaTallGrassLayer
func photoBands(in visible: CGRect) -> [PlazaPhotoBand]    // visible은 월드(y 아래로), 겹치는 칸의 지금 띠(변위 포함)
```
순서 규칙: 그림자·아이템 다음에, 배우(키 `foot.y`)와 띠(키 `sortY = y·32 + 31`)를 함께 키 순서로 그린다. 같은 키면 배우가 먼저다.
`photoActor` 는 가려진 정도가 0보다 크면 `opacity = PlazaTallGrass.opacity(…)` 이고, 이름표 바닥은
`foot.y − (spriteHeight·scale − (spriteHeight·scale − hiddenPlateLift)·min(1, c·2))`(화면 규칙과 같은 높이)다. 숨은 팀원 말풍선도 그 이름표 위에 얹는다.

- [ ] **Step 1: 실패하는 테스트를 쓴다**
  - `testABandCoversTheFeetOfAnActorInItsTile`: 단색 배우 발이 띠 칸 안에 있으면, 발 바로 위에서 띠가 불투명한 픽셀은 띠 색이다.
  - `testABandStaysBehindAnActorInTheRowBelow`: 배우 발이 띠 아래 칸에 있으면 겹치는 픽셀이 배우 색이다.
  - `testAHiddenActorLeavesOnlyItsPlate`: `opacity 0`, `plateBaseY` 지정 → 그림 픽셀이 없고, 이름표 바닥이 `plateBaseY` 에(±1 사진 픽셀) 있다.
  - `testOpacityBlendsTheSprite`: `opacity 0.4` → 그림 픽셀이 바탕과 섞인다(순수 그림 색도 바탕 색도 아니다).
  - `testPhotoInputCarriesBandsAndConcealment`: 그림이 있는 장면에서 팀원 (7,6) → `photoInput()` 의 그 배우 `opacity == 0`, `bands` 비어 있지 않음.
    `setBackgroundHidden(true)` → `bands` 빔, `opacity == 1`.
- [ ] **Step 2: 실패를 확인한다** — `swift test --filter PlazaPhotoTests` → 컴파일 실패
- [ ] **Step 3: 구현한다** — 투명도는 `context.setAlpha` 로 그림·그림자·앞 테두리에만 준다. 이름표와 말풍선은 늘 불투명하다.
- [ ] **Step 4: 통과를 확인한다** — `swift test --filter "PlazaPhotoTests|PlazaGroupPhotoTests"` → PASS
- [ ] **Step 5: 커밋한다** — `feat(team): show tall grass and hidden members in plaza photos`

---

### Task 8: 전체 검증과 PR

**Files:** 없음(검증). PR 본문은 저장소 규칙을 따른다.

- [ ] **Step 1: 게이트** — `./scripts/test-gate.sh` → 전체 통과, 커버리지 임계값 통과
- [ ] **Step 2: 빈 분기 확인** — 새 조건 분기마다 `xcrun llvm-cov show <bin> -instr-profile=<profdata> Sources/PokeTokenBar/Team/Plaza/PlazaTallGrass.swift --show-regions`
  (`PlazaTallGrassLayer.swift`, `PlazaTallGrassArt.swift`, 바뀐 `PlazaScene`·`PlazaActor`·`PlazaPhotoRenderer` 구간도)에 `^0` 가 없다. 있으면 그 분기 테스트를 더한다.
- [ ] **Step 3: 두 인스턴스 실제 확인** — 창을 띄우면 포커스를 빼앗으므로 사용자에게 손을 떼 달라고 먼저 요청한 뒤 한다.
  `scripts/plaza-dev.sh 1` 과 `scripts/plaza-dev.sh 2` 를 터미널 두 개로 띄운다.
  한쪽이 풀숲에 들어가면 다른 쪽에서 사라지는지, 흔들림 방향, 숨은 이름표 높이, 내 반투명, 배경 숨기기, 사진(P)을 본다. 창을 닫으면 흔들림이 멈추는지도 확인한다.
- [ ] **Step 4: PR** — `.agents/skills/prepare-pr/SKILL.md` 를 따른다. 제목은 `feat(team): hide in tall grass on the plaza` 이다.
  UI 변경 이미지(개발 인스턴스 캡처, gist)를 넣고, 본문에 RedVoxel CC-BY-SA 3.0 출처 줄을 넣는다.
