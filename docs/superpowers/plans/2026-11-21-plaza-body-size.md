# Plaza Body Size (PR 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Plaza hits use each Pokémon's body size. A big Pokémon is easier to hit and reaches farther. Tackles, Space, X, C, the hint line, the emote keys and throws all check body tiles instead of one foot tile. Every Mac uses the size class each member sends, so screens running the new version always agree. When everyone is class 1, every result is the same as today. Push distance stays the evolution stage.

**Architecture:**
- **Pure rules** go in `PlazaBodySize.swift`, a new SpriteKit-free file like `PlazaPond` and `PlazaPullUnder`:
  - `enum PlazaBodySize`: the two thresholds, the (w, h) table, the class from a picture, the receive clamp and the wire omission. Every value the user tunes is here.
  - `struct PlazaBody { foot, size }`, with `covers(_:)` and `touches(_:)`.
- **The rule functions take bodies.** `PlazaTargeting` (finder steps 1–4 and `turn`), `PlazaInteraction.target` and `PlazaSnowball.aim`/`hitTile` take `PlazaBody` values.
  - The one-tile signatures are removed, so the compiler lists every call site. That is half of the sweep.
  - Existing tests keep compiling through class-1 shorthands in the test target. Their assertions then pin today's behaviour on the new code.
- **One place measures my size:** the shared `PlazaWindowController.loadCharacter`. It is the only path by which my shown picture arrives: first load, retry after the grey placeholder, a representative change or evolution, and a disguise starting or ending.
  - `PlazaBodySize.size(of: frames)` sets the controller's `myBodySize`. That value goes to `scene.myBodySize` and to `session.updateBodySize`.
- **Windows measures the same way.**
  - It runs the same shared controller, `PlazaCharacterLoader` and `PlazaSpriteCrop.trimmed`. `WindowsApp.swift:393` calls `plaza.refreshCharacter()` exactly as `PokeTokenBarApp.swift:225` does.
  - Its fetcher (`PlazaStoreSpriteFetcher`) decodes GIFs with `PlazaGIFDecoder`. The Mac's `SpriteLoader.animationFrames` decodes them with ImageIO (`GIFDecoder`, `SpriteAnimation.swift`), with no frame dropping on that path.
  - `PlazaGIFDecoderParityTests+Mac` checks the two decoders give the same bytes: `testSyntheticGIFsDecodeLikeImageIO` on fixtures, and `testEveryCachedSpriteDecodesLikeImageIO` on this Mac's sprite cache (it skips in CI). So the same sprite gives the same trimmed box and the same class.
  - Consistency between screens does not depend on this. No Mac or PC ever measures another member's picture.
- **Wire:** presence gets `@LossyOptional var bodySize: Int?`.
  - It is left out at 1, and `TeamSession` clamps it to 1...3 on receipt.
  - `protocolVersion` stays 1. There is no new emote.
- **The scene holds every key's size:** members from presence, the plaza Ditto from `PlazaDittoShown`, and me from the controller.
  - Bodies come from one place, `body(of:)` and `bodies(_:)`. So the hint, the menus and the keys cannot read different tables (defect-log "예약된 비멤버 장면 키…", which hit the "대상 표가 둘" problem).
- **The turn and push rule is one function**, `PlazaTargeting.turn(from:to:facing:)`. Spec 6.3 gives the same rule twice (돌아서기 and 미는 방향):
  - an adjacent foot gives that direction;
  - otherwise the axis with the larger difference;
  - on a tie, the given facing.

  Turning uses it with my facing. Receiving a tackle uses it with the sender's presence facing. For class 1 it equals today's adjacency rule and today's fallbacks.
- **No render change, no new key, no per-frame work.** Render scenes build members with the default class 1 and never run the measuring hook. At class 1 every rule is plain equality, so captures stay byte-identical.

**Tech Stack:** Swift 6, the shared plaza node tree (SpriteKit on the Mac, Direct2D on Windows), XCTest, `FakeTransportHub` loopback sessions, `PlazaHeadlessShell` controllers (no window).

**Spec:** `docs/superpowers/specs/2026-11-21-plaza-seasons-and-interactions-design.md` (Korean). It is binding. This plan implements section 6, with the shared rules in 3.1 and 3.3, R5, the network row in 10, the per-PR duties in 11 and the constants in 13. Read R5 first.

## Conflicts with the spec

Each ruling below changes what gets built. For class 1, every ruling gives exactly today's result.

1. **Where the receiver draws a hit (spec 6.4 does not say).**
   - Today `showSnowball` flies the ball to the target's foot tile (`PlazaWindowController.swift:1216`). A hit one row above the foot would fly diagonally and land off the body.
   - **Ruling:** when `hitTile` hits, the shot ends on that tile, which is the tile the thrower's `aim` ended on. Otherwise it ends on the foot, as today.
   - The dodge check ("내 몸 칸이 끝 칸을 덮는지") then compares like with like on both Macs.
2. **The tackler's own lunge (spec 6.3 gives only the receiver's push direction).**
   - Today `tackle` (`:1082`) lunges toward an adjacent foot, or else along my facing.
   - **Ruling:** the tackler lunges by the receiver's rule: `touches ? turn(me → target, facing: my facing) : my facing`. Every screen running the new version draws the same direction.
3. **A Ditto teammate's tackle (`showMimicTackle`, `:1133–1141`; spec silent).** The sender now finds targets by body.
   - **Ruling:** the reveal check and its direction use the same touch and turn rules as `showTackle`.
   - Otherwise a big Ditto teammate's tackle on a disguised me would show the star and never find me.
4. **The plaza Ditto's bounce (`PlazaDittoBrain.bouncePath`, `PlazaDittoBrain.swift:206`) needs an adjacent tackler.**
   - **Ruling:** unchanged. 6.5 keeps the plaza Ditto's own rules, and the brain would need sizes in `PlazaDittoWorld`.
   - Consequence: a big member who tackles the Ditto form from two tiles away always gets copied, or nothing happens when they can't be copied. They never see it bounce. Report this with the PR.
5. **Re-sending on evolution (6.1) needs the plaza window.** `loadCharacter` returns early without a scene. So an evolution while the plaza is closed is measured only when the plaza opens. The same holds for a disguise that `handleClose` clears.
   - **Ruling:** keep the last sent size. The controller seeds each new scene with it (`prepareScene`) and measures again on open.
   - A closed plaza is never pushed (`showTackle` needs a scene). A stale size only changes whom others pick at the shelter, and it does so the same way on every Mac running the new version.
6. **The emote keys 1–3 (♥ ㅋㅋ 🎉) find their target with the same `PlazaTargeting.member` call (`:464`).** The spec lists Space, X, C and the hint.
   - **Ruling:** the emote keys use the body rule too. 6.3 says all of these use "이 하나" (this one finder), and keeping a tile copy for the keys would create a second finder.
7. **Test placement.**
   - 6.7 names `PlazaTackleReachTests` for the receive side, but that suite tests evolution stages through `CompanionStore` and has no plaza fixture.
   - **Ruling:**
     - The pure touch and direction rules go in `PlazaTackleReachTests`.
     - The controller's receive side goes in the new `PlazaBodySizeControllerTests`.
     - The copy's size goes in `PlazaDittoControllerTests`.
     - The Ditto teammate's reveal goes in `PlazaMimicControllerTests`.
     - The other-screens star goes in `PlazaSnowballSceneTests`.
     - "변장은 보이는 모습" (a disguise sends the shown look's size; 6.7 lists it under `PlazaBodySizeTests`) needs the controller, so it is a `PlazaBodySizeControllerTests` case.
8. **"렌더는 바뀌지 않는다(`--check` 통과)" (6.7: the renders don't change).** This is true of PR 2. But the committed reference on this branch is still the one from before PR 1, because PR 1's Task 6 hasn't run yet.
   - **Ruling:** PR 2 adds and changes no scene. Until PR 1's reference reaches this branch, `--check` must list exactly PR 1's stale stems and no others. After that it must print "current".

Found and **not** changed. Each of these is a one-tile rule left as it is under 6.5 or its spirit. List them in the PR:
- The Ditto copy's prank (`PlazaDittoBrain.strike` `:272`, `PlazaDitto.copyTarget` `PlazaDitto.swift:41`, `playDecoyTackle` `PlazaWindowController.swift:1629`).
- The tall-grass startle (`PlazaStartle.startles`, `PlazaStartle.swift:10`). It is a jump next to tall grass, not a hit.
- Walk-to and follow arrival (`PlazaScene.swift:1275`, `:1287`). This is pathfinding.
- 물귀신 (the underwater pull) target finding (`PlazaPullUnder.swift:42`).
- Walking collision (`occupiedTiles`) and the splash/wet radius.

## Global Constraints

**Workspace**
- Work only in `.worktrees/plaza-body-size` on `feat/plaza-body-size`. Never touch the main checkout.
- The branch is stacked on `feat/plaza-season-art` (PR 1, not merged). When PR 1 lands, merge `origin/main` into this branch. Do not rebase.
- Never use a bare `git stash`.
- Pass `--repo likelion-campus/PokeTokenBar` to every `gh` command.

**Machine**
- One `swift build`/`swift test` at a time. `pgrep -x swift-build; pgrep -x swift-test; pgrep -x xctest` must print nothing first.
- Run filtered suites only (`swift test --filter …`).
- Never open a window, activate the app or steal focus. Never set `PTB_LIVE_WINDOW_TESTS=1`.
- Renders are offscreen only: `SKRenderer` into a Metal texture. The scripts need the GPU, not a window or focus.
- Render scratch directories live outside the repo (`$S` = `<your session scratchpad>/body-size`).

**Shared code**
- Everything changed under `Sources/PokeTokenBar/Team/` is shared with Windows: no Apple-only import, no `#if os`.
- New tests go into existing shared files, except the `+Mac` files already listed in `Tests/PokeTokenBarTests/mac-only.txt`. The new test files `PlazaBodySizeTests.swift`, `PlazaBodySizeControllerTests.swift` and `PlazaTileRuleOracle.swift` are shared. Do not list them in `mac-only.txt`, and do not put the oracle under `Legacy/`, which is Mac-only.
- A test method on the main actor is `async` (`SharedSourcesScanTests`).

**Wire (spec 3.3)**
- `TeamWire.protocolVersion` stays 1. There is one new presence field, `bodySize` in `@LossyOptional`, and no new emote kind.
- Receivers clamp. `TeamWireTests` pins the key, and `TeamHostilePeerTests` sends what an honest app never sends.

**Expected red test**
- `PlazaCrossRenderCompareMacTests/testCommittedReferenceTreesAreCurrent` fails with PR 1's stale list until PR 1's reference refresh reaches this branch. PR 2 must not add a stem to it.
- Every other filtered suite named in a task must pass at that task's commit.

**Defect protocol**
- PR 2 is a feature, not a defect fix.
- Each new guard gets one injection run that must fail (named in its task).
- One `--show-regions` pass covers the new branches (Task 4, Step 8).

**Language**
- Commits are English Conventional Commits. Each ends with the line `Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>`.
- `TEAM.md` text is Korean in its current tone.
- New code comments follow the surrounding file. These plaza files comment in Korean; `TeamWire`/`TeamSession` doc comments are English.

## Pinned values

```swift
// PlazaBodySize — the one place to tune (spec 13: 설계자 판단·미확인; the user tunes these hands-on)
static let classes = 1...3
static let class2From: CGFloat = 80      // s = long side of the cropped front frame × PlazaActor.characterScale (1.5), world px
static let class3From: CGFloat = 120     // s < 80 → 1, 80 ≤ s < 120 → 2, s ≥ 120 → 3
static let spans: [(w: Int, h: Int)] = [(0, 0), (1, 1), (1, 2)]   // class 1, 2, 3
static func size(longSide s: CGFloat) -> Int
static func size(of frames: PlazaCharacterFrames) -> Int?   // nil: isEgg or isPlaceholder; front frames only
static func clamped(_ received: Int?) -> Int                // nil and below 1 → 1, above 3 → 3 (like TeamEmote.pushTiles)
static func sent(_ size: Int) -> Int?                       // nil at 1
static func span(_ size: Int) -> (w: Int, h: Int)           // spans[clamped(size) - 1]

struct PlazaBody: Equatable, Sendable { var foot: TilePoint; var size: Int }
//   covers(t):  foot.x − w ≤ t.x ≤ foot.x + w  and  foot.y − h ≤ t.y ≤ foot.y   (up and sideways, never below the foot)
//   touches(o): some tile of self equals or is 4-adjacent to some tile of o (symmetric; diagonal tiles do not touch)

// PlazaTargeting (Space, X, C, the hint, the emote keys)
static func member(me: PlazaBody, facing: PlazaDirection, members: [String: PlazaBody]) -> String?   // memberAhead ?? memberAround
static func memberAhead(me:facing:members:) -> String?    // 1. covers the faced tile  2. covers my foot tile
static func memberAround(me:facing:members:) -> String?   // 3. covers a side tile (otherSides order)  4. any other that touches me:
                                                          //    smallest foot Manhattan distance, then smaller ID
// several covering one tile → smaller ID (as member(on:) today)
static func turn(from: TilePoint, to: TilePoint, facing: PlazaDirection) -> PlazaDirection
//   4-adjacent → PlazaPathfinder.direction; else sign of the larger |dx|/|dy|; equal (same tile, true diagonal) → facing

// PlazaInteraction.target(me:facing:map:members:) order: faced board, faced campfire, memberAhead, side board, side campfire,
//   memberAround. A member hit's facing is turn(me.foot → member.foot, facing).

// PlazaSnowball
static func aim(from: TilePoint, facing: PlazaDirection, bodies: [String: PlazaBody], map: PlazaMap) -> PlazaSnowballShot?
//   1...range (10) tiles ahead, stops before blocksBall, the first tile some body covers is .actor(min covering ID, that tile)
static func hitTile(thrower: TilePoint, target: PlazaBody, direction: PlazaDirection) -> TilePoint?
//   horizontal: thrower.y within foot.y − h ... foot.y; the nearest body column at or past one tile ahead, 1...reach (11) ahead
//   vertical:   thrower.x within foot.x − w ... foot.x + w; the nearest body row the same way. The thrower's class never matters.

// Wire: presence key "bodySize", omitted at 1; received → PlazaBodySize.clamped; missing or unreadable → 1.
```

Spec 6.1 cache examples (s → class): Pikachu 75 → 1, Bulbasaur 57 → 1, Snorlax 112 → 2, Gengar 112 → 2, Dragonite 123 → 3, Gyarados 153 → 3, Wailord 154 → 3.

Test coordinates use open ground of the real map (`PlazaMapData.map`, rows at b93f25e2):
- row 11 and row 12 are open from x 3 to 44 (row 13 has the left pond at x 5–14);
- column 17 is open from y 3 to 13;
- the existing snowball rows and columns (row 12 from (10,12); column 10 over the pond) stay as they are.

Throw-agreement tests use a synthetic open map, `try PlazaMap(rows: ["NS" + String(repeating: ".", count: 38)] + Array(repeating: String(repeating: ".", count: 40), count: 29))`. Its board is at (0,0) and its shelter at (1,0).

## Sweep: one-tile judgements in shared code (at b93f25e2)

`grep -rnE "isAdjacent\(|PlazaTargeting\.member\(|PlazaInteraction\.target\(|PlazaSnowball\.(aim|hits)\(|== shot\.endTile|standing == tile" Sources/PokeTokenBar` lists 30 lines. Each one is ruled on below.

| Site | Today | PR 2 | Source of the change |
|---|---|---|---|
| `PlazaTargeting.member` (`PlazaTargeting.swift:13`) | foot tiles | bodies, steps 1–4 | spec 6.3 |
| `PlazaInteraction.target` member part (`PlazaInteraction.swift:21–35`) | foot tiles | bodies, boards first as today | spec 6.3 |
| `PlazaScene.refreshInteractionTarget` (`PlazaScene.swift:933`) → the hint | | bodies | spec 6.3 "안내 줄" |
| `handleInteractKey` Space (`PlazaWindowController.swift:940`) | | bodies | spec 6.3 |
| `faceNearbyMember` X and C (`:642`), its turn (`:644`) | adjacency turn | bodies + `turn` | spec 6.3 |
| `handleEmoteKey` 1–3 target (`:464`) | | bodies | sweep, ruling 6 |
| `tackle` lunge (`:1082`) | adjacency | touch + `turn` | sweep, ruling 2 |
| `showTackle` direction and push (`:1120`, `:1125`) | adjacency | touch + `turn` | spec 6.3 |
| `showMimicTackle` direction and reveal (`:1137`, `:1140`) | adjacency | touch + `turn` | sweep, ruling 3 |
| `handleSnowballKey` aim (`:1169`) | | bodies | spec 6.4 |
| `handleSnowballKey` landing: hit record and Ditto (`:1181`, `:1185`) | `== endTile` | body covers | sweep |
| `showSnowball` hit (`:1222`) and end tile (`:1216`) | `hits` | `hitTile` | spec 6.4, ruling 1 |
| `showSnowball` dodge (`:1228`) | `walker.tile == endTile` | my body covers | spec 6.4 |
| `showSnowball` Ditto landing (`:1231`) | `dittoTile == endTile` | Ditto body covers | sweep |
| `showSnowball` miss path (`:1217`) | `aim(targets: [:])` | `aim(bodies: [:])` | signature |
| `PlazaScene.playSnowball` star (`:1497–1499`) | `standing == tile` | body covers | spec 6.4 |
| `playDecoyTackle` (`:1629`), `PlazaDitto.copyTarget` (`PlazaDitto.swift:41`), brain `:206`, `:272` | adjacency | unchanged | 6.5, ruling 4 |
| `PlazaStartle.startles` (`PlazaStartle.swift:10`), walk-to (`PlazaScene.swift:1275`, `:1287`), `PlazaPullUnder` (`:42`), `PlazaPathfinder` | adjacency | unchanged | 6.5 |

No Windows-only file calls any of these (`Sources/PokeTokenBar/Platform/Windows` has no match). The Windows selftests build `PlazaSceneMember` without `bodySize` and get class 1.

## Review Focus

1. **A call site left on one tile.** The old signatures are gone, so the build lists every caller. Task 4 Step 7 greps for what remains, and a controller test pins each changed site.
2. **The thrower's Mac and the target's Mac disagree.** Two tests cover this:
   - `testTheReceiverAgreesWithTheThrowersAim` checks random classes, with `aim`'s end tile equal to `hitTile`;
   - `testTheFoundMemberAlwaysTouchesMe` plus `testTouchingIsSymmetric` show that a tackle the finder allows is a tackle the receiver accepts.
3. **Class 1 is not exactly today.** The randomized comparisons against verbatim copies of today's rules cover this (`PlazaTileRuleOracle.swift`). They stay in the tests.
4. **A hostile size.** `0`, `-1`, `4`, `999`, `"3"` and `true` are clamped or dropped, the rest of the frame applies, and a claimed class 3 reaches at most two tiles farther (Task 1).
5. **The Ditto scene key.** A copy has the copied member's size, and the Ditto form is 1. It flows through `PlazaDittoShown` into the same `bodies(_:)` the hint and the keys read (Task 2).
6. **Another member's picture never decides anything.** A teammate whose sprite is huge on my Mac is still class 1 until they send a size (`testATeammatesSizeIsWhatTheySentNeverTheirPictureHere`).

---

### Task 1: Size classes, body tiles and the presence field

**Files:**
- Create: `Sources/PokeTokenBar/Team/Plaza/PlazaBodySize.swift`
- Modify:
  - `Sources/PokeTokenBar/Team/TeamWire.swift:52-53`: add the field after `activity`, so the memberwise init keeps its order.
  - `Sources/PokeTokenBar/Team/TeamSession.swift`:
    - `:25-26`: `TeamMemberState.bodySize`;
    - `:136`: the stored value;
    - after `:305`: `updateBodySize`;
    - `:417`: the receive clamp;
    - `:528-537`: `makePresence`.
- Test:
  - Create: `Tests/PokeTokenBarTests/PlazaBodySizeTests.swift`
  - Modify:
    - `Tests/PokeTokenBarTests/TeamWireTests.swift`: `:89-107` and new tests after `:576`;
    - `Tests/PokeTokenBarTests/TeamHostilePeerTests.swift`: under `// MARK: - Sizes`.

**Interfaces:**
- Produces:
  - `enum PlazaBodySize` and `struct PlazaBody`, exactly as in Pinned values.
  - `TeamPresence`: `@LossyOptional var bodySize: Int?`. Its doc comment says: left out at 1, a receiver keeps it within 1...3, unreadable values become nil, earlier versions ignore it.
  - `TeamMemberState.bodySize: Int = 1`.
  - `TeamSession.updateBodySize(_ size: Int)`. It stores `PlazaBodySize.sent(size)`, broadcasts only on a change, and `makePresence` sends the stored value.

- [ ] **Step 1: Write the failing tests.**
  - `PlazaBodySizeTests` (new):
    - `testTheTunablesAreTheSpecsStartingValues`:
      - `class2From == 80` and `class3From == 120`;
      - `spans.map { [$0.w, $0.h] } == [[0, 0], [1, 1], [1, 2]]`;
      - `classes == 1...3`.
      - When the user tunes a value, this test and the coordinate tests that use it change together.
    - `testTheClassBoundariesAreEightyAndOneTwentyWorldPixels`:
      - `[79, 79.99, 80, 119, 119.99, 120].map(PlazaBodySize.size(longSide:)) == [1, 1, 2, 2, 2, 3]`;
      - the spec's examples: `[75, 57, 112, 112, 123, 153, 154]` map to `[1, 1, 2, 2, 3, 3, 3]`.
    - `testTheClassIsTheCroppedFrontsLongSideTimesOneAndAHalf`: build `PlazaCharacterFrames` from `PlazaTestImages.solid`. Front (w×h):
      - 53×10 → 1 (79.5);
      - 54×10 → 2;
      - 10×54 → 2;
      - 79×40 → 2 (118.5);
      - 80×40 → 3;
      - a 50×40 front with a 120×120 back → 1 (the back is ignored).
    - `testAnEggOrThePlaceholderHasNoClass`: an 80×80 front with `isEgg: true` → nil, and with `isPlaceholder: true` → nil.
    - `testReceivedSizesStayWithinOneToThreeAndOneIsNotSent`:
      - `[nil, 0, -1, 1, 2, 3, 4, 999].map(PlazaBodySize.clamped) == [1, 1, 1, 1, 2, 3, 3, 3]`;
      - `[1, 2, 3].map(PlazaBodySize.sent) == [nil, 2, 3]`.
    - `testABodyGrowsUpAndSidewaysButNeverBelowTheFoot`. The covered tiles of `PlazaBody(foot: (5,5), size: c)` within x 0–10, y 0–10 are:
      - class 1: `{(5,5)}`;
      - class 2: x 4–6 × y 4–5 (6 tiles);
      - class 3: x 4–6 × y 3–5 (9 tiles).
      - No class covers (5,6).
    - `testBodiesTouchWhenTwoTilesMeetOrSitSideBySide`:
      - class 1 at (5,5) against class 1 at (5,5), (6,5), (6,6), (7,5) → true, true, false, false;
      - class 3 at (5,5) against class 3 at (5,8), (5,9), (5,2), (5,1) → true, false, true, false. Class-3 pairs touch three tiles apart, both ways (R5);
      - class 2 at (6,6) against class 1 at (5,5) → true (a diagonal foot).
    - `testTouchingIsSymmetric`: `PlazaSplitMix64(seed: 0xB0D1)`, 5,000 random pairs, offsets ±5, classes 1–3: `a.touches(b) == b.touches(a)`.
  - `TeamWireTests`:
    - In `testEveryOptionalFieldSurvivesARoundTrip`, add `full.bodySize = 3`.
    - `testBodySizeIsOptionalOnTheWire`:
      - the plain presence JSON has no `"bodySize"`;
      - presences with `bodySize` 2 and 3 round-trip, and their JSON contains `"bodySize":2` / `"bodySize":3`;
      - earlier JSON (the `testPondFieldsAreOptionalAndOmitted` frame) decodes to `bodySize == nil`.
    - `testUnreadableBodySizeDropsOnlyTheSize`: the `testUnreadableMimicDropsOnlyTheMimic` frame with `"bodySize":"3"`, then with `"bodySize":true`. Each gives `p.bodySize == nil`, nickname `"Ash"` and tile (3,4).
  - `TeamHostilePeerTests`:
    - `testAbsurdBodySizesAreKeptInRangeAndTheFrameLives`:
      - send raw presence JSON in the `testAMalformedCampfireSwitchIsDropped` shape, with `"bodySize":` followed by `0`, `-1`, `4`, `999`, `"3"`, `true`;
      - `session.members["hostile"]?.bodySize` is `[1, 1, 3, 3, 1, 1]` in that order;
      - the tile is (7,8) each time.
    - `testAClaimedClassThreeReachesAtMostTwoTilesFarther`. A presence with `bodySize = 999` gives `let c = session.members["hostile"]!.bodySize`, which is 3. With `PlazaBody(foot:size: c)` against `PlazaBody(foot: (5,5), size: 1)`:
      - (5,8) touches and (5,9) doesn't: two tiles farther from below;
      - (7,5) touches and (8,5) doesn't: one tile farther sideways;
      - (5,3) doesn't: nothing farther from above.
- [ ] **Step 2: Run** `swift test --filter 'PlazaBodySizeTests|TeamWireTests|TeamHostilePeerTests'`. Expected: the build fails (`cannot find 'PlazaBodySize' in scope`, `value of type 'TeamPresence' has no member 'bodySize'`).
- [ ] **Step 3: Implement** the Pinned values, the field, the clamp (`member.bodySize = PlazaBodySize.clamped(presence.bodySize)`) and `updateBodySize`.
  - Comment the constants block with "조정용 상수 (명세 13, 설계자 판단·미확인)".
- [ ] **Step 4: Run** Step 2's filter. Expected: PASS.
- [ ] **Step 5: Injection.** Make `clamped` return `max(n ?? 1, 1)` (no upper bound) and run `--filter TeamHostilePeerTests/testAbsurdBodySizesAreKeptInRangeAndTheFrameLives`. Expected: FAIL (`4`, `999` kept). Revert, then run. Expected: PASS.
- [ ] **Step 6: Run** `scripts/shared-check.sh`. Expected: it builds.
- [ ] **Step 7: Commit** `feat(team): add plaza body size classes and carry them in presence`.

### Task 2: My size is measured and sent, and every scene knows everyone's size

**Files:**
- Modify `Sources/PokeTokenBar/Team/Plaza/PlazaScene.swift`:
  - `:7-26`: `PlazaSceneMember.bodySize`, after `nature`;
  - `:202-221`: `Remote.bodySize`;
  - `:612-660`: `applyMembers` copies it;
  - `:663-702`: `applyDitto` copies it;
  - near `:345`: `myBodySize`;
  - after `:2162`: `myBody`, `body(of:)`, `bodies(_:)`;
  - `:2351-2361`: `PlazaDittoShown.bodySize`.
- Modify `Sources/PokeTokenBar/Team/Plaza/PlazaWindowController.swift`:
  - `:75-80`: `DittoLook.bodySize`, so a size change re-applies the copy;
  - `:378`: `prepareScene` seeds `s.myBodySize`;
  - `:1719-1743`: `showDitto` sets the copy's size;
  - `:1959-1966`: `applyMembersToScene` passes `bodySize: $0.bodySize`;
  - `:2039-2042`: `loadCharacter` measures and sends.
- Test:
  - Create: `Tests/PokeTokenBarTests/PlazaBodySizeControllerTests.swift`
  - Modify: `Tests/PokeTokenBarTests/PlazaDittoControllerTests.swift`, after `:455`.

**Interfaces:**
- Consumes from Task 1: `PlazaBodySize.size(of:)`, `PlazaBody`, `TeamSession.updateBodySize`, `TeamMemberState.bodySize`.
- Produces:
  - `PlazaSceneMember.bodySize: Int = 1` and `PlazaDittoShown.bodySize: Int = 1`.
  - On `PlazaScene`:
    - `var myBodySize: Int = 1`. Its `didSet` calls `refreshInteractionTarget()` on a change.
    - `var myBody: PlazaBody` (walker tile + `myBodySize`).
    - `func body(of id: String?) -> PlazaBody?`: nil means me; a remote is its motion tile + its size; an unknown ID gives nil.
    - `func bodies(_ tiles: [String: TilePoint]) -> [String: PlazaBody]`: each key's tile with that remote's size, 1 when unknown.
    - `memberTiles`, `targetTiles`, `interactionTiles` and `snowballTargets` stay as they are.
  - On `PlazaWindowController`:
    - `private(set) var myBodySize = 1`.
    - In `loadCharacter`, right after `scene.setCharacter(frames)`: `myBodySize = PlazaBodySize.size(of: frames) ?? 1`, then `scene.myBodySize = myBodySize`, then `session?.updateBodySize(myBodySize)`.
  - In `showDitto`, the copy's size:
    - `decoyOf == memberID()` → `myBodySize`;
    - a member → `members[id]?.bodySize ?? 1`;
    - the Ditto form → 1.

- [ ] **Step 1: Write the failing tests.**
  - `PlazaBodySizeControllerTests` (new, shared). Copy `node`, `controller`, `settle`, `run` and `place` from `PlazaSnowballControllerTests`, with these changes:
    - the controller gets `loader: PlazaCharacterLoader(fetcher: SizedFetcher(...))`;
    - `subject` is a mutable box, so a test can change species and call `await c.refreshCharacter()`.
    - `SizedFetcher` returns `PlazaImage(bitmap: PlazaTestImages.solid(width:height:_))` per species for `still`, both front and back, so there is no back retry. `animated` returns `[]`, and the egg is 80×80. Sizes:
      - 25 Pikachu 50×40 → 1;
      - 143 Snorlax 75×60 → 2;
      - 130 Gyarados 102×90 → 3;
      - 132 Ditto 40×40 → 1.
    - The tests:
    - `testMySizeIsSentWhenMyPictureArrivesAndAgainWhenItChanges`:
      - species 130, `c.prepareScene()`, connect, `await c.refreshCharacter()`, settle;
      - `c.myBodySize == 3` and `c.scene?.myBody.size == 3`;
      - the last `.presence` in `me.transport.sent` has `bodySize == 3`, and `b.session.members[me.id]?.bodySize == 3`;
      - then species 25 (evolution or a representative change), refresh, settle: 1, the last presence has `bodySize == nil`, and b sees 1;
      - then 143: 2.
    - `testAPlaceholderOrAnEggSendsNoSize`:
      - the `EmptyFetcher` placeholder gives `myBodySize == 1` and no `bodySize` in the last presence;
      - an egg subject (`speciesID: nil`) with the 80×80 egg also gives 1.
    - `testMyDisguiseSendsTheSizeOfTheLookIShow`:
      - me species 132 (Ditto), b species 130 in the plaza beside me;
      - press C (keyCode 8), settle, refresh: `c.mimicking == b.id`, `c.myBodySize == 3`, and the last presence has `bodySize == 3`;
      - C again releases me: 1.
    - `testATeammatesSizeIsWhatTheySentNeverTheirPictureHere`:
      - b is species 130, so my fetcher draws them 102×90, but b has sent nothing: `c.scene?.body(of: b.id)?.size == 1`;
      - after `b.session.updateBodySize(2)` and a settle: 2.
    - `testANewSceneStartsFromMyLastSize`: measure 3, `c.handleClose()`, `c.prepareScene()`: `c.scene?.myBodySize == 3` before any refresh (ruling 5).
  - `PlazaDittoControllerTests.testTheCopyHasTheCopiedMembersSize`, using `copyScene()`:
    - `m.session.updateBodySize(3)`, settle, `c.advanceDitto(now: Date())`: `scene.body(of: key)?.size == 3`;
    - `updateBodySize(1)`, the same steps: 1;
    - then `c.showDecoyFound(from: m.id, copied: m.id)` turns it back into the Ditto form: 1.
- [ ] **Step 2: Run** `swift test --filter 'PlazaBodySizeControllerTests|PlazaDittoControllerTests/testTheCopyHasTheCopiedMembersSize'`. Expected: the build fails (`myBodySize`, `myBody`, `body(of:)` undefined).
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `swift test --filter 'PlazaBodySizeControllerTests|PlazaDittoControllerTests|PlazaMimicControllerTests|PlazaSnowballControllerTests|PlazaWindowShellTests'`. Expected: PASS.
- [ ] **Step 5: Injection.**
  - Drop `bodySize:` from `applyMembersToScene` and run `--filter PlazaBodySizeControllerTests/testATeammatesSizeIsWhatTheySentNeverTheirPictureHere`. Expected: FAIL. Revert.
  - Measure `await loader.frames(for: subject())` (my own look) instead of the shown frames. Expected: `testMyDisguiseSendsTheSizeOfTheLookIShow` FAILs. Revert.
- [ ] **Step 6: Run** `scripts/shared-check.sh`. Expected: it builds.
- [ ] **Step 7: Commit** `feat(team): send my plaza body size and give every scene everyone's size`.

### Task 3: Reach by body for Space, X, C, the hint, the emote keys and tackles

**Files:**
- Modify:
  - `Sources/PokeTokenBar/Team/Plaza/PlazaTargeting.swift` (the whole file);
  - `Sources/PokeTokenBar/Team/Plaza/PlazaInteraction.swift:13-38`;
  - `Sources/PokeTokenBar/Team/Plaza/PlazaScene.swift:932-937`;
  - `Sources/PokeTokenBar/Team/Plaza/PlazaWindowController.swift`:
    - `:456-467` (emote keys);
    - `:638-646` (`faceNearbyMember`);
    - `:938-941` (Space);
    - `:1071-1083` (`tackle`);
    - `:1114-1129` (`showTackle`);
    - `:1133-1141` (`showMimicTackle`).
- Create: `Tests/PokeTokenBarTests/PlazaTileRuleOracle.swift`
- Test:
  - `Tests/PokeTokenBarTests/PlazaTargetingTests.swift`
  - `Tests/PokeTokenBarTests/PlazaTackleReachTests.swift`
  - `Tests/PokeTokenBarTests/PlazaBodySizeControllerTests.swift`
  - `Tests/PokeTokenBarTests/PlazaMimicControllerTests.swift`, after `:821`
  - `PlazaCardTests.swift` stays untouched and compiles through the shorthands.

**Interfaces:**
- Consumes:
  - from Task 1: `PlazaBody.covers`, `PlazaBody.touches`;
  - from Task 2: `scene.myBody`, `body(of:)`, `bodies(_:)`.
- Produces:
  - `PlazaTargeting.member(me:facing:members:)`, `memberAhead(me:facing:members:)`, `memberAround(me:facing:members:)` and `turn(from:to:facing:)`, as in Pinned values.
  - `PlazaTargeting.member(from:facing:members:)` is removed. `facingTile`, `otherSides` and `member(on:members:)` (still used by `PlazaPullUnder`) stay.
  - `PlazaInteraction.target(me:facing:map:members:)`. The `from:` form is removed.
  - Test-only, in `PlazaTileRuleOracle.swift`:
    - header: "Verbatim copies of the one-tile rules at b93f25e2 (before PR 2), renamed. The class-1 oracle. Shared, so the Windows test job compares too. Do not edit.";
    - `enum LegacyPlazaTargeting`: the whole of today's `PlazaTargeting.swift`;
    - `enum LegacyPlazaInteraction`: today's `target`, with `PlazaTargeting.` replaced by `LegacyPlazaTargeting.`;
    - `enum LegacyPlazaTackle`: `pushes(from:to:)` is today's `PlazaPathfinder.isAdjacent(from, to) || from == to`, and `direction(from:to:fallback:)` is today's `:1120-1121` expression;
    - `// MARK: - Class-1 shorthands for the tile-era tests`:
      - `extension PlazaBody { static func ones(_ tiles: [String: TilePoint]) -> [String: PlazaBody] }`;
      - `PlazaTargeting.member(from:facing:members: [String: TilePoint])`;
      - `PlazaInteraction.target(from:facing:map:members: [String: TilePoint])`, both on class-1 bodies.
- Call sites:
  - **The scene's** `refreshInteractionTarget` uses `PlazaInteraction.target(me: myBody, facing:, map:, members: bodies(interactionTiles))`.
  - **Emote keys:** `member(me: scene.myBody, facing:, members: scene.bodies(targetTiles))`.
  - **`faceNearbyMember`:** the same call, then `scene.face(PlazaTargeting.turn(from: me, to: tile, facing: scene.walker.facing))`.
  - **Space:** `PlazaInteraction.target(me: scene.myBody, …, members: scene.bodies(scene.interactionTiles))`.
  - **`tackle`:** lunge as in ruling 2.
  - **`showTackle`:**
    - sender body = `memberTiles[sender]` with `scene.body(of: sender)?.size`;
    - target body = mine, the Ditto's or the member's, from `scene.body(of:)`;
    - `touching = sender.touches(target)`;
    - `direction = touching ? turn(from:to:facing: members[sender]?.facing ?? .down) : members[sender]?.facing ?? .down`;
    - `guard isMe, touching`.
  - **`showMimicTackle`:** the same touch and direction; reveal when `isMe, myMimic != nil, touching`.

- [ ] **Step 1: Write the oracle file and the failing tests.**
  - `PlazaTargetingTests`:
    - `testEveryTileRuleIsUnchangedWhenEveryoneIsClassOne`. `PlazaSplitMix64(seed: 0x2B0D)`, 20,000 rounds. Each round:
      - me on a random walkable tile of `PlazaMapData.map`, a random facing;
      - 0–5 members with IDs from `a…f` within ±2 of me (so shared tiles and ID ties occur);
      - `PlazaTargeting.member(me: PlazaBody(foot: me, size: 1), facing:, members: .ones(m)) == LegacyPlazaTargeting.member(from:facing:members:)`;
      - `PlazaInteraction.target(me:…) == LegacyPlazaInteraction.target(from:…)` on the real map, both target and facing;
      - for a random pair within ±3 and every fallback: `PlazaBody(...,1).touches(PlazaBody(...,1)) == LegacyPlazaTackle.pushes`, and `(touching ? turn : fallback) == LegacyPlazaTackle.direction`.
    - `testTheFoundMemberAlwaysTouchesMe`: random classes 1–3, the same layout generator. Whenever `member(me:…)` returns an ID, that body touches `me`.
    - Me at (5,5) in each case below:
      - `testABigMemberCoveringOnlyTheFacedTileIsFound` (step 1 alone). Facing right, `a` class 2 at (7,6) (covers (6,5), not (5,5)) and `b` class 1 at (5,4): `"a"`. `turn((5,5)→(7,6), .right) == .right`.
      - `testABigMemberCoveringMyTileComesBeforeASide` (step 2 alone). Facing up, `a` class 3 at (5,7) and `b` class 1 at (4,5): `"a"`. `turn((5,5)→(5,7), .up) == .down`.
      - `testABigMemberCoveringOnlyASideIsFound` (step 3 alone). Facing up, `a` class 2 at (3,6) (covers (4,5)): `"a"`. `turn == .left`.
      - `testOnlyTouchingFindsTheNearestFootThenTheSmallerID` (step 4 alone):
        - me class 3, facing down;
        - `z` (5,2), `m` (3,4) and `a` (7,3), all class 1, touch me but cover none of my five tiles. The foot distances are 3, 3 and 4;
        - result `"m"`, and `turn((5,5)→(3,4), .down) == .left`;
        - with me class 1 instead, nil.
      - `testAFacedMemberBeatsOneThatOnlyTouches`: me class 3, facing up, `z` (5,4) and `a` (5,2), both class 1: `"z"`.
      - `testBigBodiesReachDiagonallyAndTwoTilesOut`: me class 1.
        - `d` class 2 at (6,6) → found; class 1 there → nil, as today.
        - `t` class 3 at (5,8) → found; at (5,9) → nil.
    - `testTurningFacesAnAdjacentFootElseTheLongerAxisElseStays`. From (5,5):
      - to (6,5) → `.right`;
      - to (5,2) → `.up`;
      - to (7,6) → `.right`;
      - to (6,6) with facing `.left` → `.left` (a tie);
      - to (5,5) with `.up` → `.up`.
    - `testTheBoardStillComesFirst`. With `b = map.boardTile` and `left = (b.x − 1, b.y + 1)`, facing down:
      - a class 2 member at (left.x − 2, left.y + 1) covers only my left side, and the result is `.board` facing `.right`;
      - a class 3 member at (left.x + 1, left.y + 3) covers the faced tile, and the result is `.member("m")` facing `.down`.
  - `PlazaTackleReachTests` (pure; the existing evolution tests stay):
    - `testATackleReachesAsFarAsTheBodiesTouch`. Each branch alone:
      - the sender's body only: a class 3 sender at (5,8) reaches class 1 at (5,5), and at (5,9) it doesn't;
      - my body only: a class 1 sender at (5,2) reaches class 3 at (5,5), and at (5,1) it doesn't.
    - `testEveryOldReachStillReaches` (spec 6.6: an earlier-version tackler still pushes). For all class pairs and offsets ±4: `LegacyPlazaTackle.pushes(from:to:)` implies `touches`.
    - `testThePushGoesFromTheTacklerElseAlongTheLongerAxisElseTheirFacing`. `turn(from: sender, to: me, facing: senderFacing)`:
      - (5,6)→(5,5) → `.up`;
      - (5,8)→(5,5) → `.up`;
      - (7,6)→(5,5) → `.left`;
      - (6,6)→(5,5) with `.down` → `.down`;
      - the same tile with `.right` → `.right`.
  - `PlazaBodySizeControllerTests`:
    - `testABigTacklerPushesMeFromThreeBelowButNotFour`:
      - me class 1 at (17,9); b class 3 (`updateBodySize(3)`) placed at (17,12);
      - `c.showTackle(from: b.id, on: me.id, tiles: 1)`, run 1 s: I am at (17,8);
      - fresh world with b at (17,13): I stay at (17,9), and `scene.impactsShown` went up by 1.
    - `testMyBigBodyIsTackledFromThreeAbove`: me species 130 (class 3) at (17,12), b class 1 at (17,9). `showTackle` pushes me to (17,13).
    - `testTheHintSpaceXAndCAllPickTheBigReach`:
      - me species 130 at (17,12) facing down; b class 1 at (17,9) (step 4 alone);
      - `c.hint == L(.ko).plazaMemberHint(nickname: "가")`;
      - Space (49) opens `.memberMenu` for b and I face `.up`;
      - Esc, then X (7): `b.received.emotes` gets a shared greeting (`isShared == true`) with `targetMemberID == b.id`;
      - C (8): `b.received.emotes` gets `.tackle` with `targetMemberID == b.id`.
    - `testATeammatesNewSizeMovesTheHintWithoutAStep`:
      - me class 1 at (17,9) facing up, b class 1 at (17,12): no member hint;
      - `b.session.updateBodySize(3)`, settle: `c.hint == plazaMemberHint(nickname: "가")`, and nobody moved.
  - `PlazaMimicControllerTests.testABigDittosTackleFindsMeFromTwoTilesBeside`. Use `disguisedWorld()`, where I am disguised at `row(10)` (y 3). Then, as `testADittosTackleRevealsADisguisedMe` does, join a Ditto teammate `a` (`Self.ditto`) that sends `updateBodySize(3)`:
    - at `row(8)`, its body x 7–9 is beside my tile. `w.c.showMimicTackle(from: a.id, on: w.me.id)`, then run 1 s: `w.c.mimicking == nil`, and the first `.mimicFound` targets `a.id`;
    - at `row(7)`: still disguised, and no `.mimicFound` is sent.
- [ ] **Step 2: Run** `swift test --filter 'PlazaTargetingTests|PlazaTackleReachTests|PlazaBodySizeControllerTests'`. Expected: the build fails (`member(me:facing:members:)`, `turn` and `target(me:…)` are undefined).
- [ ] **Step 3: Implement** the finder, `turn`, `PlazaInteraction.target(me:…)` and the call sites above.
  - The doc comments say the order and that class 1 is today's rule.
- [ ] **Step 4: Run** `swift test --filter 'PlazaTargetingTests|PlazaTackleReachTests|PlazaCardTests|PlazaBodySizeControllerTests|PlazaMimicControllerTests|PlazaEmoteTests|PlazaFocusTests|PlazaDittoControllerTests|PlazaWindowShellTests|PlazaPullUnderTests|PlazaTackleWaterTests'`. Expected: PASS, including every `PlazaCardTests` assertion unchanged.
- [ ] **Step 5: Injection.**
  - In `memberAhead`, look at my tile before the faced tile and run `--filter PlazaTargetingTests/testEveryTileRuleIsUnchangedWhenEveryoneIsClassOne`. Expected: FAIL (spec 6.7: "순서를 바꾸면 실패", the test fails when the order changes). Revert.
  - In `showTackle`, keep the old `isAdjacent(from, to) || from == to` guard and run `--filter PlazaBodySizeControllerTests/testABigTacklerPushesMeFromThreeBelowButNotFour`. Expected: FAIL. Revert.
  - Drop step 4 from `memberAround`. Expected: `testOnlyTouchingFindsTheNearestFootThenTheSmallerID` FAILs. Revert, then run Step 4's filter. Expected: PASS.
- [ ] **Step 6: Run** `scripts/shared-check.sh`. Expected: it builds.
- [ ] **Step 7: Commit** `feat(team): reach plaza teammates by body size for Space, X, C and tackles`.

### Task 4: Throws by body

**Files:**
- Modify:
  - `Sources/PokeTokenBar/Team/Plaza/PlazaSnowball.swift:39-67`: `aim` and `hits` → `hitTile`;
  - `Sources/PokeTokenBar/Team/Plaza/PlazaWindowController.swift:1166-1235`: V and `showSnowball`;
  - `Sources/PokeTokenBar/Team/Plaza/PlazaScene.swift:1493-1503`: the star.
- Modify: `Tests/PokeTokenBarTests/PlazaTileRuleOracle.swift`. Append the following:
  - `enum LegacyPlazaSnowball`, today's `aim` and `hits` verbatim;
  - shorthands `PlazaSnowball.aim(from:facing:targets: [String: TilePoint], map:)` and `PlazaSnowball.hits(thrower:target: TilePoint, direction:) -> Bool`, on class 1. The distinct labels `targets:` and `hits` keep `targets: [:]` unambiguous.
- Test:
  - `Tests/PokeTokenBarTests/PlazaSnowballTests.swift`
  - `Tests/PokeTokenBarTests/PlazaSnowballSceneTests.swift`, after `:122`
  - `Tests/PokeTokenBarTests/PlazaBodySizeControllerTests.swift`

**Interfaces:**
- Consumes: from Tasks 1–3, `PlazaBody`, `scene.body(of:)`, `bodies(_:)` and the oracle file.
- Produces:
  - `PlazaSnowball.aim(from:facing:bodies:map:)` and `PlazaSnowball.hitTile(thrower:target:direction:) -> TilePoint?`, as in Pinned values.
  - `hits` is removed. `range`, `reach` and every flight constant stay.
- Call sites:
  - **V:** `aim(…, bodies: scene.bodies(scene.snowballTargets), …)`. On landing:
    - `scene.body(of: target)?.covers(shot.endTile) == true` records `.snowballHit`;
    - the Ditto check uses `scene.body(of: PlazaDitto.sceneKey)` in the same way.
  - **`showSnowball`:**
    - `resolved` becomes a body;
    - `let entry = resolved.flatMap { hitTile(thrower: from, target: $0.body, direction:) }`;
    - the shot ends at `entry ?? resolved foot` (ruling 1);
    - `hit = entry != nil`;
    - the miss path is `aim(…, bodies: [:], …)`;
    - on landing, me: `scene.myBody.covers(shot.endTile)`; the Ditto: its body covers.
  - **The scene star:** `body(of: id)?.covers(tile) == true`.

- [ ] **Step 1: Write the failing tests.**
  - `PlazaSnowballTests`:
    - `testEveryThrowIsUnchangedWhenEveryoneIsClassOne`. `PlazaSplitMix64(seed: 0x5B0A)`, 20,000 rounds on `PlazaMapData.map`:
      - from a random walkable tile, a random facing, 0–4 targets (`a…e`) within one row/column of the line and up to 12 tiles ahead;
      - `aim(…, bodies: .ones(t), …) == LegacyPlazaSnowball.aim(…, targets: t, …)`;
      - random thrower/target within ±13 for each direction: `(hitTile(…, PlazaBody(foot: t, size: 1), …) != nil) == LegacyPlazaSnowball.hits(…)`, and a hit returns `t`.
    - `testABigBodyOneRowOffTheLineIsHitAndASmallOneIsMissed`. From (10,12) facing right:
      - `g` class 3 at (16,13) → `.actor("g", (15,12))`, frames 5;
      - class 2 at (16,13) → the same;
      - class 2 at (16,11) (the line runs below its foot) → `.ground((20,12))`;
      - class 1 at (16,13) → `.ground((20,12))`.
      - Receiver: `hitTile(thrower: (10,12), target: PlazaBody(foot: (16,13), size: 3), direction: .right) == (15,12)`, and the class 1 body → nil.
    - `testAColumnThrowHitsABigBodyBesideTheColumn`. From (10,16) facing up:
      - `g` class 3 at (11,9) → `.actor("g", (10,9))`, frames 7, and `hitTile == (10,9)`;
      - class 1 there → `.ground((10,6))`, as today.
    - `testTheReceiverFindsTheNearestBodyColumnWithinEleven`. Target class 3 at (16,13), facing right:
      - thrower (4,12) → (15,12) (11 ahead);
      - (3,12) → nil;
      - thrower (16,12), inside the span, → (17,12), with `aim` from (16,12) agreeing.
    - `testTheReceiverAgreesWithTheThrowersAim`. `PlazaSplitMix64(seed: 0xA61E)`, 10,000 rounds on the synthetic open map, one target body of random class within 12 tiles in every direction:
      - when `aim` returns `.actor(id, tile)`, `hitTile(thrower: from, target: body, direction: facing) == tile`;
      - when `hitTile` returns a tile at most 10 ahead, `aim` hits that body there.
  - `PlazaSnowballSceneTests.testAStarShowsWhenTheBallReachesABigBodyAboveItsFoot`:
    - members `a` at (10,12) and `g` at (16,13) with `bodySize = 3`;
    - `playSnowball(by: "a", shot: PlazaSnowballShot(from: (10,12), direction: .right, end: .actor(id: "g", tile: (15,12))))`, run 0.9 s: `impactsShown == 1`;
    - with `g` class 1: 0, as in `testABallLandingWhereItsTargetNoLongerStandsShowsNoStar`;
    - me: `s.myBodySize = 3` at (16,13) with `end: .actor(id: nil, tile: (15,12))` → 1.
  - `PlazaBodySizeControllerTests`:
    - `testVHitsABigTeammateOneRowOff`:
      - me at (12,11) facing right; b `updateBodySize(3)` at (17,12);
      - V (9): b receives `.snowball` with `targetMemberID == b.id`;
      - `c.activity.snowballHits` is 0 while the ball flies and 1 after landing, as `PlazaActivityControllerTests` reads it;
      - with b class 1, the target is nil.
    - `testABallOneRowOffHitsMyBigBodyUnlessItLeavesTheEndTile`. Me species 130 at (17,12); b at (12,11):
      - `c.showSnowball(from: b.id, on: me.id, tiles: 1, direction: .right)`, run 1.2 s: I am at (18,12);
      - fresh world, `scene.pushMe(.right)` before landing: I stay at (18,12). My body no longer covers (16,11). This also pins ruling 1: had the shot ended on my old foot (17,12), the moved body would still cover it;
      - fresh world, `scene.pushMe(.left)` before landing: I end at (17,12). My body at (16,12) still covers (16,11).
- [ ] **Step 2: Run** `swift test --filter 'PlazaSnowballTests|PlazaSnowballSceneTests|PlazaBodySizeControllerTests'`. Expected: the build fails (`aim(from:facing:bodies:map:)` and `hitTile` are undefined).
- [ ] **Step 3: Implement** `aim`, `hitTile` and the call sites above.
- [ ] **Step 4: Run** `swift test --filter 'PlazaSnowballTests|PlazaSnowballSceneTests|PlazaSnowballControllerTests|PlazaBodySizeControllerTests|PlazaMimicControllerTests|PlazaDittoControllerTests|PlazaSeasonTests'`. Expected: PASS.
- [ ] **Step 5: Injection.**
  - Make `hitTile` require `thrower.y == foot.y` on horizontal throws. Expected: `testABigBodyOneRowOffTheLineIsHitAndASmallOneIsMissed` and `testTheReceiverAgreesWithTheThrowersAim` FAIL. Revert.
  - Make `showSnowball` end the shot at the foot. Expected: `testABallOneRowOffHitsMyBigBodyUnlessItLeavesTheEndTile` FAILs (the right step no longer dodges). Revert, then run Step 4's filter. Expected: PASS.
- [ ] **Step 6: Run** `scripts/shared-check.sh`. Expected: it builds.
- [ ] **Step 7: Sweep.** Run:
```bash
grep -rnE "isAdjacent\(|member\(from:|member\(on:|target\(from:|hits\(thrower|targets: scene|== shot\.endTile|standing == tile" Sources/PokeTokenBar \
  | grep -vE "Plaza(BodySize|Targeting|Pathfinder)\.swift"
```
  Expected: exactly the eight sites the Sweep table keeps, and nothing else:
  - `PlazaDitto.swift` (`copyTarget`);
  - `PlazaDittoBrain.swift` twice (bounce, strike);
  - `PlazaStartle.swift`;
  - `PlazaPullUnder.swift` (`member(on:)`);
  - `PlazaScene.swift` twice (walk-to);
  - `PlazaWindowController.swift` once (`playDecoyTackle`).

  Anything more is a site still judged on one tile: fix it in this task.
- [ ] **Step 8: Coverage.** Run with nothing else building:
```bash
swift test --enable-code-coverage --filter 'PlazaBodySizeTests|PlazaBodySizeControllerTests|PlazaTargetingTests|PlazaTackleReachTests|PlazaSnowballTests|PlazaSnowballSceneTests|PlazaMimicControllerTests|PlazaDittoControllerTests|TeamWireTests|TeamHostilePeerTests'
BIN_PATH=$(swift build --show-bin-path); PROF=$(find "$BIN_PATH/" -name default.profdata | head -1)
BIN=$(find "$BIN_PATH/" -name PokeTokenBarPackageTests -type f ! -path '*.dSYM/*' | head -1)
LLVM_COV="$(dirname "$(realpath "$(command -v swift)")")/llvm-cov"; [ -x "$LLVM_COV" ] || LLVM_COV=$(xcrun --find llvm-cov)
BASE=$(git merge-base HEAD feat/plaza-season-art)
for f in $(git diff --name-only "$BASE" -- Sources/PokeTokenBar/Team); do
  CHANGED=$(git diff -U0 "$BASE" -- "$f" | awk '/^@@/{split($3,a,/[+,]/); n=(a[3]==""?1:a[3]); for(i=0;i<n;i++) print a[2]+i}')
  "$LLVM_COV" show "$BIN" -instr-profile="$PROF" --show-regions "$f" \
    | awk -F'|' '/^ *[0-9]+\|/{ln=$1+0} /\^0/{print ln}' | sort -u | grep -Fx -f <(echo "$CHANGED") | sed "s|^|$f:|"
done
```
  - This prints each added or changed source line that has a `^0` region. The `awk` carries the last numbered line onto the marker lines below it.
  - Expected: nothing.
  - If a line is reported, write the missing branch's test. Do not mark it unreachable without the input-path check from CLAUDE.md step 3.
- [ ] **Step 9: Commit** `feat(team): judge plaza throws by the target's body size`.

### Task 5: TEAM.md, the untouched render check and PR images

**Files:**
- Modify: `TEAM.md`: `:161` (스페이스), `:168` (C), `:169` (V), after `:207` (팀에 보이는 것), and the end of `## 알려진 한계`.
- No other repo file. Renders go under `$S`.

- [ ] **Step 1: Edit `TEAM.md`.**
  - 스페이스 row: before `말을 걸 수 있는 자리에 서면 위쪽에 안내가 뜨고`, insert:
    > `포켓몬이 크면 닿는 범위가 넓어집니다. 광장에 보이는 그림이 큰 포켓몬(2·3등급)은 몸이 옆으로 한 칸, 위로 한두 칸 더 차지해서, 몸끼리 닿으면 바로 옆이 아니어도 말을 걸고 인사(X)·몸통박치기(C)·말풍선(1·2·3)을 보낼 수 있고, 맞을 때도 그 몸 전체로 맞습니다. 작은 포켓몬(1등급)끼리는 예전과 같고, 미는 거리는 그대로 진화 단계입니다. 크기는 각자 자기 그림으로 재서 팀원에게 보내므로 모든 화면이 같은 크기로 판정합니다. `
  - C row: replace `옆에 팀원이 없으면 아무 일도 없습니다.` with `닿는 팀원이 없으면 아무 일도 없습니다(포켓몬이 크면 바로 옆이 아니어도 닿습니다. 스페이스 줄 참고).`
  - V row, two replacements:
    - `10칸 안에서 처음 만나는 팀원이나 메타몽에 맞고,` becomes `10칸 안에서 처음 만나는 팀원이나 메타몽의 몸에 맞고(큰 포켓몬은 몸이 있는 칸이면 어디든 맞아서, 가로로 던지면 발 위 한두 줄, 세로로 던지면 옆 한 줄에서도 맞습니다),`;
    - `맞을 팀원이 그 칸에서 걸어 나갔다면` becomes `맞을 팀원의 몸이 그 칸에서 벗어났다면`.
  - 팀에 보이는 것: after the `닉네임, 고른 이름 색, …` line, add `- 광장에 보이는 내 포켓몬 그림의 크기 등급(1~3). 몸통박치기, 말 걸기, 던지기가 닿는 범위를 모든 화면에서 똑같이 정하는 데 씁니다. 그림과 크기 숫자는 보내지 않고, 가장 작은 1등급이면 등급도 보내지 않습니다`
  - End of `알려진 한계`: add `- v2.5.636 이하를 쓰는 팀원은 몸 크기를 보내지 않아 최신 버전 화면에서 모두 가장 작은 1등급으로 판정됩니다. 큰 포켓몬이 바로 옆이 아닌 곳에서 그 팀원에게 몸통박치기하거나 던지면 충격 별은 보이지만 그 팀원은 밀리지 않습니다. 그 팀원이 치거나 던지면 예전처럼 밀립니다. 업데이트하면 바로잡힙니다.` Re-check the version at release: it must be the last version without this PR.
- [ ] **Step 2: Render check, untouched.** Run `env -u PTB_PLAZA_RENDER_ONLY scripts/plaza-render-cross.sh --check --scratch "$S/cross"`.
  - Expected once PR 1's reference refresh is on this branch: `CROSS-MAC: reference is current (<PR 1's count> captures)`.
  - Expected before that: exit 1, listing exactly PR 1's stale stems (its Task 6 Step 1 list), with no stem PR 2 could explain.
  - If another stem appears, run the same `--check` in a scratch worktree at the parent of Task 1's commit. A stem that is stale there too is not PR 2's.
  - Never `--write` in this PR.
- [ ] **Step 3: PR images** (offscreen, never committed; the memory note on offscreen plaza renders applies).
  - Add a temporary, env-gated test `Tests/PokeTokenBarTests/PlazaBodySizeImages+Mac.swift`. It skips unless `PTB_BODY_SIZE_OUT` is set. Model it on `PlazaRenderCompareTests.testRenderAllScenes`: `PlazaRenderScenes.stage`, `PlazaOffscreenRenderer`, frame stepping, PNG out, `backingOverride = 1`, saved at ×2 nearest.
  - The sprites, read-only from `~/Library/Application Support/PokeTokenBar/sprites`:
    - Gyarados #130 (class 3), with its foot one row below a throw line;
    - Pikachu #25 throwing from four tiles away.
    - If either is not cached, use the harness crowd looks and say so in the caption.
  - **Before:** the shot from `LegacyPlazaSnowball.aim`, which flies past and bursts on the ground. **After:** the shot from `PlazaSnowball.aim` with the sizes, which lands on the body with the star. Capture each at the landing frame and two frames later.
  - Also a tackle row, after only: a class-3 sender lunging at a class-1 teammate three tiles above, then the push, captioned "before: C does nothing here".
  - Make a contact sheet `$S/approval/body-size.png` with a scratch `python3 -I` PIL script at `$S/tools/contact.py`. Label it "Sample-data render, offscreen (SKRenderer), not the live app".
  - Delete the temp test. `git status` must show only `TEAM.md`.
- [ ] **Step 4: Commit** `docs(team): explain plaza body size in TEAM.md`.

---

## After the plan (PR)

- **Before the PR:**
  - after PR 1 lands, merge `origin/main` into the branch;
  - re-run Task 5 Step 2: it must now say "current";
  - re-run Task 4 Step 4's filter.
- **Prepare the PR with `prepare-pr`.**
  - Title: `feat(team): judge plaza hits by each Pokémon's body size`.
  - Under `UI changes`, put the Task 5 contact sheet, pushed to the PR-image gist and labelled "Sample-data render, offscreen".
  - The body names:
    - R5: about 70% of the cached sprites become easier to hit, and class-3 pairs tackle from three tiles. The two thresholds and the span table are the constants to tune;
    - the eight rulings at the top of this plan;
    - the "found, not changed" list;
    - the mixed-version behaviour (spec 6.6, the new `TEAM.md` line);
    - that no render reference changed.
- **Push** with `git push origin feat/plaza-body-size:feat/plaza-body-size`, and check the windows.yml test job (the shared suites, including the oracle comparisons).
- **Release (later, not this PR):** check the `v2.5.636 이하` line in `TEAM.md` against the version actually shipped.
