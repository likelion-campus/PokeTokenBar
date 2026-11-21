# Plaza Pull and Receive Cooldown (PR 3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The plaza Space menu gets a fifth row, 끌어당기기, between 몸통박치기 and 따라가기. Choosing it steps me back up to my evolution stage in tiles, and the teammate slides after me and stops beside my new tile. The teammate's own Mac decides whether they move. Separately, every emote that moves me (`.tackle`, `.drag`, the underwater `.pull`, a snowball hit) moves me at most once a second per sender. The star and the pull still draw when the move is refused.

**Architecture:**
- **Pure rules** go in `PlazaDrag.swift`, a new SpriteKit-free file like `PlazaPullUnder` and `PlazaBodySize`:
  - `enum PlazaDrag`: the line, the drag direction, how far I step back (k), how far the target slides (n).
  - `struct PlazaShove`: the per-sender receive cooldown. Its `receiveCooldown` is the only new tunable.
  - `PlazaDirection.opposite`.
- **Both sides call one function for the geometry.** `PlazaDrag.direction(puller:target:)` uses PR 2's `PlazaBody.touches` (symmetric) on the same two bodies, so the sender's menu and the receiver's check cannot disagree on screens that see the same tiles.
- **One condition function on the sender**, `dragStep(_:to:)`. Both the menu row and the chosen action read it, so the two cannot drift apart. `chooseMenu(.drag)` runs it again, because the layout may have changed while the menu was open.
- **Order on the wire:** the `.drag` emote first, then my step back (`scene.pushMe`). The receiver therefore still sees my tile from before the step, as with 물귀신 and ice breaking.
- **Each screen draws only existing art.**
  - The puller does a short lunge away from the target. That is the tackle's `lunge`, in the opposite direction.
  - Two dust puffs rise at the target's feet. This is the jump's `puffDust` art.
  - Nothing new is drawn in code. `scene.playDrag` adds no per-frame work and creates no node on a paused scene.
- **The receive cooldown lives in the controller.**
  - The controller holds one `PlazaShove` record. It is the last guard before `pushMe`/`plunge` on the four paths that move me.
  - It reads the injected `clock()`.
  - The Ditto copy's prank (`playDecoyTackle`) keeps its own 60 s rule and never touches the record.
- **No new key, no new presence field, no render-scene change.** The menu is a HUD panel. No cross-render scene draws a menu. `.drag` is appended last to `TeamEmoteKind`, and the `emotes` scene shows only the first seven kinds.

**Tech Stack:** Swift 6, the shared plaza node tree (SpriteKit on the Mac, Direct2D on Windows), XCTest, `FakeTransportHub` loopback sessions, `PlazaHeadlessShell` controllers (no window).

**Spec:** `docs/superpowers/specs/2026-11-21-plaza-seasons-and-interactions-design.md` (Korean). It is binding. This plan implements section 7, with R1 and R8, the shared rules in 3.1 and 3.3, the network rows in 10, the per-PR duties in 11 and the constant in 13. Read R1 and R8 first. The shape (I step back, the target follows) and the cooldown's reach to 물귀신 and snowballs are both **[설계자 판단·미확인]**: the user has not seen them yet, and the PR shows them.

## Conflicts with the spec

Each ruling below changes what gets built.

1. **Where the hostile cases live.** Spec 7.4 names `TeamHostilePeerTests`, but that suite feeds a bare `TeamSession` and has no plaza controller and no runtime. The cooldown and the reach live in the controller, and the `pushTiles` clamp lives in `TeamRuntime`.
   - **Ruling:**
     - The flood and the out-of-reach drag go in `PlazaDragControllerTests` under `// MARK: - Hostile peers`.
     - `pushTiles` 99 → 3 is tested end to end in `TeamRuntimeTests`, next to `testSnowballReachesThePlazaAndPushesAtMostThreeTiles`, which already does this for snowballs. It is also tested purely in `PlazaDragTests`.
     - `TeamHostilePeerTests` gets the paused-scene node check for the new effect. That is where this class of check already lives.
2. **The water rule covers diving.**
   - `setDiving` requires `isMeInWater` (`PlazaScene.swift:974`), and a member is shown diving only on a water tile (`isShownDiving`, `:1183`).
   - **Ruling:** one check each side, `!scene.isMeInWater` and `scene.memberIsInWater(id) != true`, decides both the menu and the receive. The spec's 잠수 cases pass through this branch.
   - Only one layout makes "I am in water and the target is not" matter: two class-3 bodies across the 3-row left pond, with land behind me. The test uses that layout.
3. **Ice counts as ground for the target's slide too.** Spec 7.1 says so for my step back ("얼음 포함"). For the slide it says only "땅만".
   - **Ruling:** both use `scene.isWalkableNow`, which is true on ice and false on open water.
4. **Re-checking when the row is chosen.** The spec does not say what happens if the layout changes while the menu is open.
   - **Ruling:** `drag(_:)` runs `dragStep` again. If it fails now, nothing is sent and I do not move.
   - A tackle still lunges and sends in the same situation. A drag with nobody to follow has nothing to show.
5. **The order of checks on the receiver.** It mirrors `showTackle`:
   1. Geometry: P is in my plaza, on my line, and touching.
   2. A disguised me is revealed instead.
   3. My water state and `canBePushed`.
   4. At least one tile to slide.
   5. The cooldown.
   6. The move.

   A zero-tile slide does not use up the second.
6. **What the cooldown records.** "마지막으로 움직인 시각" is the time of the last move the cooldown let through.
   - A refused attempt never restarts the second. Otherwise a 100-a-second flood would never let one through.
   - An attempt refused for another reason (out of reach, focusing) never starts one. The existing `TeamRuntimeTests.testTackleFromBesideMePushesMeOneTileAway` sends an out-of-reach tackle and then, at once, a reaching one.
   - A clock that went back lets the move through (defect-log 되감긴 시계).
   - There is one record per sender, shared by all four kinds.
7. **The pull's direction on a screen where P and T are not on a line** (lag, or a hostile sender). The spec does not say.
   - **Ruling:** use the opposite of P's presence facing. P faces T while stepping back.
8. **Photo mode.** Spec 7.1's list of receive conditions is exhaustive and leaves photo mode out. A tackle pushes a photographer today; the 물귀신 pull does not.
   - **Ruling:** the drag follows the tackle, with no photo-mode check.
9. **The menu's default rows.**
   - **Ruling:** `PlazaMemberMenu.actions` stays `PlazaMemberAction.allCases`, which now has five rows. `handleInteractKey` removes `.drag` when `dragStep` returns nil, the same way it removes `.tackle` and `.follow`.
   - The tests that compare whole menus change. Task 3 lists them.
10. **The TEAM.md old-version number.** The line for older versions says "v2.5.635 이하": the latest release is v2.5.635, and 2.5.636 is only a version bump on `main`.
    - The lines PR 1 and PR 2 added say "v2.5.636 이하". They are not changed here; this is flagged for the release check.

Found and **not** changed. List these in the PR:
- `PlazaPullUnder.opposite` (private) duplicates the new `PlazaDirection.opposite`.
- `playDecoyTackle` keeps its 60 s rule (spec 7.3) and does not use the shove record.
- A hostile puller that never steps back can leave me on its tile. Its tile never blocks the slide, as with 물귀신, and walking out of an overlap is allowed.
- `showPull` has no `canBePushed` check. A focusing me cannot be pulled anyway: no campfire seat has a pond within the pull's three tiles.

## Global Constraints

**Workspace**
- Work only in `.worktrees/plaza-pull` on `feat/plaza-pull`. Never touch the main checkout or a sibling worktree.
- The branch is stacked on `feat/plaza-body-size` (PR 2), which is stacked on `feat/plaza-season-art` (PR 1). Neither is merged. When they land, merge `origin/main` into this branch. Do not rebase.
- Never use a bare `git stash`.
- Pass `--repo likelion-campus/PokeTokenBar` to every `gh` command.

**Machine**
- One `swift build`/`swift test` at a time. `pgrep -x swift-build; pgrep -x swift-test; pgrep -x xctest` must print nothing first.
- Run filtered suites only (`swift test --filter …`).
- Never open a window, activate the app or steal focus. Never set `PTB_LIVE_WINDOW_TESTS=1`.
- Renders are offscreen only: `SKRenderer` into a Metal texture. The scripts need the GPU, not a window or focus.
- Render scratch directories live outside the repo (`$S` = `<your session scratchpad>/plaza-pull`).

**Shared code**
- Everything changed under `Sources/PokeTokenBar/Team/` is shared with Windows: no Apple-only import, no `#if os`.
- New tests go into existing shared files, except the `+Mac` files already listed in `Tests/PokeTokenBarTests/mac-only.txt`.
  - The new test files `PlazaDragTests.swift` and `PlazaDragControllerTests.swift` are shared. Do not list them in `mac-only.txt`.
  - The two `Legacy/` files touched in Tasks 2 and 3 are Mac-only and stay that way.
- A test method on the main actor is `async` (`SharedSourcesScanTests`).

**Wire (spec 3.3)**
- `TeamWire.protocolVersion` stays 1. There is one new emote kind, `.drag` (raw value `"drag"`), appended **last** to `TeamEmoteKind`. There is no new presence field.
- Receivers clamp `pushTiles` with `TeamEmote.pushTiles`. `TeamWireTests` pins the raw value, and the controller and runtime tests send what an honest app never sends.

**Expected red test**
- None. `PlazaCrossRenderCompareMacTests/testCommittedReferenceTreesAreCurrent` must pass: PR 1's refresh (`4ec364e5`) is on this branch, and neither PR 2 nor PR 3 adds or changes a scene.
- Every filtered suite named in a task must pass at that task's commit.

**Defect protocol**
- PR 3 is a feature, not a defect fix.
- Each new guard gets one injection run that must fail (named in its task).
- One `--show-regions` pass covers the new branches (Task 4, Step 7).

**Language**
- Commits are English Conventional Commits. Each ends with the line `Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>`.
- `TEAM.md` text is Korean in its current tone.
- New code comments follow the surrounding file. These plaza files comment in Korean; `TeamWire`/`TeamSession` doc comments are English.

## Pinned values

```swift
// PlazaShove — the one new tunable (spec 13: 설계자 판단·미확인; the user tunes it hands-on)
static let receiveCooldown: TimeInterval = 1
private(set) var lastMoved: [String: Date] = [:]
mutating func admit(_ sender: String, now: Date) -> Bool
//   1. drops every entry with now − t >= receiveCooldown, or now < t (a clock that went back)
//   2. an entry left for `sender` → false, nothing recorded; none → records `now`, true
//   So it refuses while 0 <= now − last < 1: 0.99 s refused, 1.0 s admitted.

// PlazaDrag — no tunables: the step limit is TeamEmote.pushTileRange (1...3), the reach is PlazaBody.touches (PR 2)
static func line(from: TilePoint, to: TilePoint) -> PlazaDirection?
//   the way from `from` to `to` when they share x or y and are not the same tile; else nil
static func direction(puller: PlazaBody, target: PlazaBody) -> PlazaDirection?
//   b, the way from the target to the puller: puller.touches(target) ? line(target.foot → puller.foot) : nil
static func stepBack(from: TilePoint, direction: PlazaDirection, stage: Int, isOpen: (TilePoint) -> Bool) -> Int
//   k: tiles 1...TeamEmote.pushTiles(stage) along `direction`, stopping before the first tile that is not open
static func slide(victim: TilePoint, puller: TilePoint, pushTiles: Int, isOpen: (TilePoint) -> Bool) -> Int
//   n: (foot distance − 1) + TeamEmote.pushTiles(pushTiles) along line(victim → puller), stopping before the first
//   tile that is not open; 0 when not on a line. With every tile open, the victim ends beside the puller's new tile.
extension PlazaDirection { var opposite: PlazaDirection }

// isOpen in the controller: scene.isWalkableNow(t) && !occupied.contains(t)   (ice open, open water closed)
//   sender:   occupied = scene.occupiedTiles()
//   receiver: occupied = scene.occupiedTiles(except: sender)   (the puller's tile never blocks; pushMe(…, pulledBy: sender) agrees)

// Wire: TeamEmoteKind.drag, raw "drag", last case. pushTiles = k, left out at 1 (sendEmote already does). notifiesTarget false,
//   endsSendersDance true.
// Menu: PlazaMemberAction order greet, tackle, drag, follow, viewCard. L(.ko).plazaMenuDrag == "끌어당기기".
// Sender rate limit: PlazaWindowController.emoteInterval (0.3 s), the shared lastEmoteAt.
```

Test coordinates use the real map (`PlazaMapData.map`). Each tile below was checked on this branch:
- Row 12 is open from x 3 to 44, and (45,12) is a tree. Row 10 is open from x 32 to 38, and (39,10) is a bush.
- Column 17 is open from y 12 to 16. (10,11), (10,12) and (10,16) are ground; (10,13)–(10,15) are the left pond.
- (14,14) is water, and (15,14) and (16,14) are ground.
- (31,18) is a flower, (30,18) is ground and (32,18) is the right pond.
- The spawn is (23,6), and (23,5) is the board, so the `standing()` fixture (a teammate below the spawn) has no drag row.
- `ParkedDitto.seed` parks the Ditto at (43,18), away from every tile here.

The controller fixture is `PlazaSnowballControllerTests`'s. Its controller breaks the left pond, so the left pond is water, and it injects the clock `now`.

## Sweep

**A. Every path that moves me on a peer's word.** The grep is `grep -n "pushMe(\|\.plunge(" Sources/PokeTokenBar/Team/Plaza/PlazaWindowController.swift`.

| Site | Moves me because | PR 3 |
|---|---|---|
| `showTackle` `pushMe` (`:1137`) | `.tackle` | cooldown |
| `showSnowball` landing `pushMe` (`:1241`) | `.snowball` hit | cooldown, checked when the ball lands |
| `showPull` `plunge`/`pushMe` (`:1283`) | `.pull` | cooldown |
| `showDrag` `pushMe` (new) | `.drag` | cooldown |
| `playDecoyTackle` `pushMe` (`:1647`) | `.decoyTackle` | unchanged: its 60 s rule (spec 7.3) |
| `pullUnder` `pushMe` (`:1270`), `drag` `pushMe` (new), Z `plunge` (`:613`) | my own key | not a receive path |

**B. Exhaustive switches and kind lists the new cases must join.**

| Site | `.drag` gets |
|---|---|
| `TeamEmoteKind.notifiesTarget` / `.endsSendersDance` (`TeamWire.swift:127-142`) | false / true |
| `teamEmoteLabel` (`TeamLocalization.swift:269`) | `"끌어당기기"` (never shown: no notice) |
| `PlazaEmoteArt.image` (`:110`) and `Legacy/LegacyPlazaEmoteArt.swift:115-135` | the impact grid, "never shown as a bubble", identical in both |
| `PlazaMenuText.title` and `Legacy/LegacyPlazaHUDMenus.swift:52` | `l.plazaMenuDrag` |
| `chooseMenu` switch | `drag(id)` |
| `TeamWireTests` raw pin and dance set; `PlazaEmoteTests+Pixels.testEachEmoteHasArt` and `TeamNotificationsTests.testEmoteNoticeNamesEachKind` (the "never a bubble / never notifies" lists) | listed |
| `PlazaRenderScenes` `emotes` (first seven kinds), `TeamRuntimeTests.testARemotesActionEmoteOrChatStopsItsDance`, `PlazaTextArt*` loops, `PlazaCardTests+Mac.testMenuLinesFitTheMenu` | automatic; the render is unchanged because `.drag` is last |

**C. Tests that pin a whole member menu.** Task 3 changes exactly these:
- `PlazaFocusTests.testWhileFocusingMyMenuHasNoTackleOrFollow` (its baseline line) and `testFacingTheTeammateOpensTheirMenuWithTheDittoAhead`. Both have (9,10) free behind me, so the expected list gains `.drag`.
- `PlazaCardTests+Controller.testSpaceBesideATeammateOpensTheMenu` and `testHeldSpaceDoesNotChooseFromTheMenu` (the spawn layout). The tile behind me is the board, so they now pass the four rows explicitly.
- `PlazaCardTests+Mac.testMenuKeepsItsWidthAndOneLineEach`: the default menu now has six lines.

Unchanged, and now also proof of a drag rule, because drag would show there without the rule (confirmed by Task 3's injections):
- `PlazaFocusTests.testFocusingTeammateMenuHasNoTackleOrFollow` and the focusing half of `testWhileFocusingMyMenuHasNoTackleOrFollow`;
- `PlazaWindowTests.testTackleReachesASwimmingTarget` and the diver half of `testNoTackleWithADiver` (I stand at (31,18) with (30,18) free);
- `PlazaDittoControllerTests.testSpaceOnTheDittoFormOffersOnlyTackle`.

Unchanged because the layout already shows drag and the default now has five rows:
- `PlazaCardTests+Controller.testTeammateBesideMeGetsAHintAndSpaceTurnsToThem`;
- `PlazaBodySizeControllerTests.testTheHintSpaceXAndCAllPickTheBigReach`.

The arrow-count helpers `viewCard` and `follow` run at the spawn, where there is no drag row, so they stay as they are.

## Review Focus

1. **The menu row and the action read the same conditions.** Both go through `dragStep`. Look for a condition checked in one place only.
2. **Order on the wire.** `testChoosingDragSendsItFirstThenStepsMeBack` chooses on a hidden plaza, where `pushMe` reports at once. Its assertion is that the target saw my old tile when the drag arrived.
3. **Cooldown placement.**
   - It is the last guard on the four paths, after the reveal and before the move.
   - It never gates the star, the pull or a reveal, and records per sender.
   - It handles a backwards clock, and `playDecoyTackle` is untouched.
4. **A hostile sender.** The cases are a flood at 100 a second, a drag from out of reach, from off my line or from a fake class-3 claim, `pushTiles` 99, an unknown or huge target, the Ditto key, and a paused scene.
5. **The Ditto scene key.** There is one test per path: the Ditto form (existing), a copy of a member, a copy of me, a drag chosen on the key, a stale menu on a copy, and a drag received for the key.
6. **No art drawn in code.** `playDrag` calls `lunge` and `puffDust` only.

---

### Task 1: The drag rules and the cooldown record

**Files:**
- Create: `Sources/PokeTokenBar/Team/Plaza/PlazaDrag.swift`
- Create: `Tests/PokeTokenBarTests/PlazaDragTests.swift`

**Interfaces:**
- Produces: `PlazaDrag`, `PlazaShove` and `PlazaDirection.opposite`, exactly as in Pinned values.
- Consumes: `PlazaBody.touches` (PR 2), `TeamEmote.pushTiles`, `PlazaWalker.offset`.

- [ ] **Step 1: Write the failing tests** in `PlazaDragTests` (new, shared). `open` is `{ _ in true }`, and `ground` is `{ PlazaMapData.map.isWalkable($0) }`.
  - `testTheTunablesAreTheSpecsStartingValues`: `PlazaShove.receiveCooldown == 1` and `TeamEmote.pushTileRange == 1...3`.
  - `testALineIsARowOrAColumnButNotTheSameTile`. From (5,5):
    - to (8,5) → `.right`, to (2,5) → `.left`, to (5,1) → `.up`, to (5,9) → `.down`;
    - to (5,5) → nil, to (6,6) → nil.
  - `testADragNeedsTheSameLineAndTouchingBodies`. Target class 1 at (5,5):
    - puller class 1 at (6,5) → `.right`;
    - puller class 1 at (7,5) → nil (not touching);
    - puller class 3 at (5,8) → `.down`, and at (5,9) → nil;
    - puller class 2 at (6,6) → nil (touching, but the feet are diagonal);
    - puller class 1 at (5,5) → nil.
  - `testIStepBackAsFarAsMyStageAndTheOpenGround`. With `ground`, unless stated:
    - from (20,12) `.right`, stage 1, 2, 3 → 1, 2, 3; stage 0 → 1; stage 99 → 3;
    - (44,12) `.right` → 0 (the tree at the map edge);
    - (38,10) `.right` → 0 (the bush), and (36,10) `.right` with stage 3 → 2;
    - (10,12) `.down` → 0 (the pond);
    - with (21,12) taken out of `ground`: (20,12) `.right` with stage 3 → 0. With (22,12) taken out: 1;
    - ice, `ground` plus (10,13): (10,12) `.down` with stage 1 → 1.
  - `testTheTargetSlidesToBesideMyNewTile`. With `open`:
    - victim (18,12), puller (19,12), `pushTiles` 1, 2, 3 → 1, 2, 3;
    - victim (17,12), puller (17,15): `pushTiles` 1 → 3, 2 → 4;
    - victim (20,12), puller (21,13) → 0.
  - `testTheEndIsBesideThePullersNewTileForEveryReachablePair`. `PlazaSplitMix64(seed: 0xD4A6)`, 5,000 rounds:
    - target foot (20,15), a puller offset of 1–4 tiles along a random direction, classes 1–3 each, k in 1...3, `open`;
    - whenever `direction(puller:target:)` gives `b`: walking `slide(...)` tiles from the target along `b` reaches the tile that is k − 1 tiles from the puller along `b`.
  - `testTheSlideStopsBeforeTheFirstClosedTile`. Victim (17,12), puller (17,15), `pushTiles` 1 (n would be 3):
    - (17,14) closed → 1;
    - (17,13) closed → 0;
    - only (17,16) closed → 3.
  - `testAskedTilesStayWithinOneToThree`. Victim (20,12), puller (19,12), `open`: `pushTiles` 99 → 3, 0 → 1, −5 → 1.
  - With `t0 = Date(timeIntervalSinceReferenceDate: 1_000)`:
    - `testASecondMoveWithinASecondIsRefusedAndAtASecondAdmitted`: `admit("a", t0)` true, at `t0 + 0.99` false, at `t0 + 1.0` true.
    - `testARefusedMoveDoesNotRestartTheSecond`: "a" at t0 true, at +0.5 false, at +1.0 true.
    - `testEachSenderHasItsOwnSecond`: "a" at t0 true, "b" at +0.1 true, "a" at +0.2 false.
    - `testAHundredMovesASecondAreLetThroughOnceASecond`: i in 0..<300, at `t0 + Double(i) / 100`. The admitted indices are `[0, 100, 200]`.
    - `testTheRecordKeepsOnlyTheLastSecond`: senders "s0"…"s999" at `t0 + i / 1000`, then "x" at `t0 + 2`. `lastMoved.keys == ["x"]`.
    - `testAClockThatWentBackLetsTheMoveThrough`: "a" at t0 true, at `t0 − 3600` true, at `t0 − 3599.5` false.
- [ ] **Step 2: Run** `swift test --filter PlazaDragTests`. Expected: the build fails (`cannot find 'PlazaDrag' in scope`).
- [ ] **Step 3: Implement** the Pinned values.
  - The doc comments say which side calls what, and that both sides use `direction`.
  - Comment `receiveCooldown` with "조정용 상수 (명세 13, 설계자 판단·미확인)".
- [ ] **Step 4: Run** Step 2's filter. Expected: PASS.
- [ ] **Step 5: Injection.** Run each change with Step 2's filter, then revert it:
  - `stepBack` checks only the first tile. Expected: `testIStepBackAsFarAsMyStageAndTheOpenGround` FAILs ((36,10) gives 3).
  - `slide` uses d + k. Expected: `testTheEndIsBesideThePullersNewTileForEveryReachablePair` FAILs.
  - `direction` drops `touches`. Expected: `testADragNeedsTheSameLineAndTouchingBodies` FAILs.
  - `admit` records a refused try. Expected: `testARefusedMoveDoesNotRestartTheSecond` FAILs.
  - The prune ignores `now < t`. Expected: `testAClockThatWentBackLetsTheMoveThrough` FAILs.

  After the last revert, run the filter again. Expected: PASS.
- [ ] **Step 6: Run** `scripts/shared-check.sh`. Expected: it builds.
- [ ] **Step 7: Commit** `feat(team): add the plaza drag rules and a per-sender receive cooldown`.

### Task 2: A received drag (wire kind, runtime, scene, controller)

**Files:**
- Modify:
  - `Sources/PokeTokenBar/Team/TeamWire.swift`:
    - `:88-125`: `case drag` after `pray`. Doc: the sender steps back `pushTiles` tiles (its evolution stage, fewer where blocked) away from `targetMemberID`, sent before that step. The target's app slides the target after it, to stand beside the sender's new tile. Earlier versions skip it.
    - `:127-142`: `notifiesTarget` and `endsSendersDance`.
    - `:151-153`: the `pushTiles` doc names the drag.
  - `Sources/PokeTokenBar/Team/TeamLocalization.swift:269-291`: `teamEmoteLabel(.drag)`.
  - `Sources/PokeTokenBar/Team/Plaza/PlazaEmoteArt.swift:110-131`: `.drag`, the impact grid ("never shown as a bubble").
  - `Tests/PokeTokenBarTests/Legacy/LegacyPlazaEmoteArt.swift:115-135`: the same case, so `testEmoteArtIsByteIdentical` stays identical.
  - `Sources/PokeTokenBar/Team/PlazaPresenting.swift`: `showDrag`.
  - `Sources/PokeTokenBar/Team/TeamRuntime.swift:105-108`: route `.drag`.
  - `Sources/PokeTokenBar/Team/Plaza/PlazaScene.swift`, after `playTackle` (`:1457`): `playDrag`.
  - `Sources/PokeTokenBar/Team/Plaza/PlazaWindowController.swift`, after `showPull` (`:1284`): `showDrag`.
- Test:
  - Create: `Tests/PokeTokenBarTests/PlazaDragControllerTests.swift`
  - Modify:
    - `TeamWireTests.swift`: `:180-184`, `:654-664`, and a new test after `:58`;
    - `PlazaEmoteTests+Pixels.swift:50`;
    - `TeamNotificationsTests.swift:162`;
    - `TeamHostilePeerTests.swift:370-405`;
    - `PlazaMimicControllerTests.swift`, after `:856`;
    - `TeamRuntimeTests.swift`, after `:455`;
    - `PlazaWindowShellTests.swift:588`.

**Interfaces:**
- Consumes from Task 1: `PlazaDrag.line`, `.direction`, `.slide` and `PlazaDirection.opposite`.
- Produces:
  - `TeamEmoteKind.drag`.
  - `PlazaPresenting.showDrag(from sender: String, on target: String?, tiles: Int)`.
  - `PlazaScene.playDrag(by puller: String?, on target: String?, direction: PlazaDirection)`:
    - `actor(puller)?.lunge(toward: direction)`;
    - then `guard !isPaused` and `puffDust(under: target)`. nil is me.
  - `PlazaWindowController.showDrag`:
    - `guard let scene, let target, let from = scene.memberTiles[sender]`.
    - `to` is `isMe ? walker.tile : memberTiles[target]`. Otherwise return: an unknown ID, or the Ditto key, which `memberTiles` never holds.
    - `scene.playDrag(by: sender, on: isMe ? nil : target, direction: PlazaDrag.line(from: to, to: from) ?? (members[sender]?.facing ?? .down).opposite)` (ruling 7).
    - `guard isMe, let b = PlazaDrag.direction(puller: PlazaBody(foot: from, size: scene.body(of: sender)?.size ?? 1), target: scene.myBody)`.
    - If `myMimic != nil`, `return revealMe(by: sender)`.
    - `guard !scene.isMeInWater, canBePushed`.
    - `n = PlazaDrag.slide(victim: walker.tile, puller: from, pushTiles: tiles, isOpen:)` with the receiver's `occupied`, then `guard n > 0`.
    - `scene.pushMe(b, tiles: n, pulledBy: sender)`.
  - `TeamRuntime`: `if emote.kind == .drag { plaza?.showDrag(from: memberID, on: emote.targetMemberID, tiles: TeamEmote.pushTiles(emote.pushTiles)); return }`.

- [ ] **Step 1: Write the failing tests.**
  - `PlazaDragControllerTests` (new, shared). Copy `node`, `controller`, `settle`, `run`, `press`, `World`, `world` and `place` from `PlazaSnowballControllerTests`. Then:
    - generalise `place` to `place(_ n: Node, _ tile: TilePoint, in w: World)`;
    - add `join(_ w: World, _ name: String, at: TilePoint) async -> Node`: a third teammate c, connected to me only;
    - add `func pull(_ w: World, from n: Node, tiles: Int = 1) { w.c.showDrag(from: n.id, on: w.me.id, tiles: tiles) }`.

    The tests:
    - `testADragSlidesMeToBesideThePullersNewTile`:
      - me at (20,12), b at (19,12); `pull(w, from: b, tiles: 2)`;
      - `scene.dustShown` went up by 2 at once;
      - after `run(scene, PlazaActor.lungeDuration / 2)`: `lungeOffset(memberID: b.id)!.x < 0` (b yanks left, away from me);
      - after `run(scene, 1.5)`: I am at (18,12). b's old tile did not block me.
    - `testABigPullerDragsMeFromThreeTilesAway`: me at (17,12); b sends `updateBodySize(3)` and stands at (17,15). `pull(w, from: b)`, run 1.5 s: I am at (17,15).
    - `testTheSlideStopsBeforeSomeoneOrTheWater`:
      - the same layout with c at (17,14): I end at (17,13);
      - fresh world, me at (10,11), b claiming class 3 in the pond at (10,14): I end at (10,12) on the shore.
    - `testADragFromOutOfReachOrOffMyLineOnlyShowsThePull` (hostile, spec 7.4). Me at (20,12), each case in a fresh world:
      - b class 1 at (22,12);
      - b class 2 at (21,13) (touching, not on my line);
      - b claiming class 3 at (20,16).

      Each: `pull`, run 1 s, I stay at (20,12) and `dustShown` went up by 2. b's lunge after half a lunge:
      - x > 0 at (22,12) (the line);
      - y < 0 at (21,13) (the opposite of b's `.down` facing, ruling 7).
    - `testADragOnSomeoneElseIsDrawnButMovesNobody`: c at (21,12), b at (22,12). `w.c.showDrag(from: b.id, on: c.id, tiles: 1)`:
      - `dustShown` went up by 2;
      - after 1 s: my tile is the same, and c's drawn tile is the same, because presence moves c.
    - `testAnUnknownTargetOrSenderOrTheDittoDrawsNothing`. Each of these leaves `dustShown`, `impactsShown` and my tile unchanged:
      - target nil;
      - `String(repeating: "x", count: 10_000)`;
      - `PlazaDitto.sceneKey`;
      - sender `"nobody"` on me.
    - `testASwimmingMeIsNotDragged`. The `swimming()` layout from `PlazaSnowballControllerTests` (me plunged to (14,14)), then b placed at (15,14):
      - `pull(w, from: b)`, run 1 s: I stay at (14,14);
      - control, fresh world on land: me at (16,14), b at (15,14): I move.
    - `testAFocusingOrMenuOpenMeIsNotDragged`. A helper `draggedAtTheFire(focusing:menuOpen:) -> Bool`, modelled on `pushedAtTheFire`:
      - me at (23,14); a side `d` whose tile is walkable and free; b on that tile; `pull`; run 1 s; did I move?
      - control (neither) → true; focusing → false; campfire menu open → false.
    - `testAHiddenPlazaIsStillDraggedButMakesNoDust`:
      - me at (20,12), b at (19,12); `w.c.setRendering(visible: false)`; `pull(w, from: b, tiles: 2)`;
      - I am at (18,12) at once, and `dustShown` is unchanged (defect-log: no node on a paused scene).
  - `PlazaMimicControllerTests`:
    - `testADragRevealsMeInsteadOfMovingMe`:
      - `disguisedWorld()`; `w.c.showDrag(from: doyun.id, on: w.me.id, tiles: 2)`; run 1 s;
      - my tile is unchanged and `mimicking == nil`;
      - `founds(log).first?.targetMemberID == doyun.id`.
    - `testADragFromAfarLeavesMyDisguise`:
      - `disguisedWorld(doyunAt: row(7))`;
      - `mimicking != nil`, my tile is unchanged, and `founds(log)` is empty.
  - `TeamRuntimeTests.testADragReachesThePlazaAndAsksForAtMostThreeTiles`, modelled on `testStrongerTacklePushesMeSeveralTiles`:
    - give the controller `dittoLoopSleep: ParkedDitto.loopSleep, dittoSeed: { ParkedDitto.seed }`;
    - a at `(start.x − 1, start.y)`; precondition: x − 1…x − 4 on that row are walkable;
    - `a.runtime.session.sendEmote(.drag, target: b.settings.memberID, pushTiles: 99)`;
    - settle and run: I am at `(start.x − 3, start.y)`.
  - `TeamWireTests`:
    - In `testWireRawValuesArePinned`, append `"drag"`.
    - In `testWhichEmotesEndTheSendersDance`, add `.drag` to `ends`. The not-ends set is unchanged.
    - `testDragPushTilesAreOptionalAndRoundTrip`:
      - `.drag` with `pushTiles` 2 round-trips;
      - `TeamEmote(kind: .drag, targetMemberID: "m")` encodes with no `"pushTiles"`;
      - the frame `{"emote":{"_0":{"kind":"drag","targetMemberID":"m","pushTiles":2}}}` decodes to that emote.
    - An old peer: no new test. v2.5.635's decoder returns nil for an emote it cannot read (`TeamWire.swift:281` at `v2.5.635`). That is the path `testUnknownNestedValuesInEphemeralFramesAreIgnoredNotMalformed` pins with `"confetti"`, and only a throw drops a link (`TeamTransportContract.malformedFrameDisconnects`). So "drag" in v2.5.635 skips the frame without cooling the link. Say so in the PR.
  - Add `.drag` to `decoyKinds` in `PlazaEmoteTests+Pixels.testEachEmoteHasArt` and in `TeamNotificationsTests.testEmoteNoticeNamesEachKind`.
  - `TeamHostilePeerTests`:
    - `testEffectsAddNothingWhileTheSceneIsPaused`: the loop also calls `s.playDrag(by: "A", on: nil, direction: .up)`;
    - `testEffectsStillPlayOnAVisibleScene`: a `drag` scene, where `playDrag` adds children.
  - `PlazaWindowShellTests.testWhatTeammatesAndTimersTriggerNeverBringsThePlazaForward`: add `presenting.showDrag(from: otherID, on: me, tiles: 1)` after `showPull`.
- [ ] **Step 2: Run** `swift test --filter 'PlazaDragControllerTests|TeamWireTests|TeamRuntimeTests|TeamHostilePeerTests'`. Expected: the build fails (`type 'TeamEmoteKind' has no member 'drag'`, `value of type 'PlazaWindowController' has no member 'showDrag'`).
- [ ] **Step 3: Implement** the Interfaces.
- [ ] **Step 4: Run** `swift test --filter 'PlazaDragControllerTests|PlazaMimicControllerTests|TeamWireTests|TeamRuntimeTests|TeamHostilePeerTests|TeamNotificationsTests|PlazaEmoteTests|PlazaTextArtParityTests|PlazaTextArtLayoutTests|PlazaPrayTests|PlazaWindowShellTests|PlazaPullUnderTests'`. Expected: PASS.
- [ ] **Step 5: Injection.** Run each change with Step 4's filter, then revert it:
  - Drop `pulledBy: sender`. Expected: `testADragSlidesMeToBesideThePullersNewTile` FAILs.
  - Replace `PlazaDrag.direction` with `touches` alone. Expected: `testADragFromOutOfReachOrOffMyLineOnlyShowsThePull` FAILs (the diagonal case).
  - Drop `!scene.isMeInWater`. Expected: `testASwimmingMeIsNotDragged` FAILs.
  - Drop `canBePushed`. Expected: `testAFocusingOrMenuOpenMeIsNotDragged` FAILs.
  - Drop the reveal. Expected: `testADragRevealsMeInsteadOfMovingMe` FAILs.
  - Drop `guard !isPaused` in `playDrag`. Expected: `testEffectsAddNothingWhileTheSceneIsPaused` FAILs.

  After the last revert, run Step 4's filter. Expected: PASS.
- [ ] **Step 6: Run** `scripts/shared-check.sh`. Expected: it builds.
- [ ] **Step 7: Commit** `feat(team): slide after a teammate who drags me in the plaza`.

### Task 3: The fifth menu row and the sender

**Files:**
- Modify:
  - `Sources/PokeTokenBar/Team/Plaza/PlazaInteraction.swift:86-95`: `case drag` between `tackle` and `follow`, with a doc comment.
  - `Sources/PokeTokenBar/Team/Plaza/HUD/PlazaMenuText.swift:10-15`.
  - `Sources/PokeTokenBar/Team/TeamLocalization.swift`, after `:131`: `var plazaMenuDrag: String { "끌어당기기" }`.
  - `Tests/PokeTokenBarTests/Legacy/LegacyPlazaHUDMenus.swift:52-60`: the title switch (needed to compile).
  - `Sources/PokeTokenBar/Team/Plaza/PlazaWindowController.swift`:
    - `:985-992`: `handleInteractKey` removes `.drag`;
    - `:1049-1070`: `chooseMenu`;
    - after `tackle` (`:1115`): `dragStep` and `drag`.
- Test:
  - `Tests/PokeTokenBarTests/PlazaDragControllerTests.swift`
  - `Tests/PokeTokenBarTests/PlazaDittoControllerTests.swift`:
    - `adjacentCopy` (`:943-956`) gains `start: TilePoint? = nil`. The default is `meStart.me`, as today, and the copy stands one tile to the right of the start.
    - `meStart` is (3,3), where the map edge leaves nothing to step back onto, so a drag could never show there.
    - New tests after `:1519`; `:1495` (the loop gains `.drag`).
  - `Tests/PokeTokenBarTests/PlazaHUDMenusTests.swift`
  - `Tests/PokeTokenBarTests/PlazaHUDMenuRenderTests+Mac.swift:44-60`
  - The Sweep C edits: `PlazaFocusTests.swift:637`, `:660`; `PlazaCardTests+Controller.swift:368`, `:750`; `PlazaCardTests+Mac.swift:87-92`.

**Interfaces:**
- Consumes: Task 1's `PlazaDrag.direction` and `stepBack`, and Task 2's `.drag` and `playDrag`.
- Produces:
  - `PlazaMemberAction.drag`. `allCases == [.greet, .tackle, .drag, .follow, .viewCard]`, and `PlazaMemberMenu.actions` defaults to it.
  - `private func dragStep(_ scene: PlazaScene, to id: String) -> (direction: PlazaDirection, tiles: Int)?`. It returns nil unless all of these hold:
    - `scene.memberTiles[id]` exists: the target is a member, never the Ditto key, so neither the Ditto form nor a copy;
    - `!isFocusing` and `focusRemaining(of: id) == nil`;
    - `scene.canWalk` (not an egg);
    - `!scene.isMeInWater` and `scene.memberIsInWater(id) != true` (ruling 2);
    - `b = PlazaDrag.direction(puller: scene.myBody, target: scene.body(of: id)!)`;
    - `k = stepBack(from: walker.tile, direction: b, stage: evolutionStage(), isOpen:) > 0`, with the sender's `occupied`.

    A Ditto me drags normally: there is no `PlazaMimic.isDitto` branch.
  - In `handleInteractKey`, after the existing removals: `if dragStep(scene, to: id) == nil { menu.actions.removeAll { $0 == .drag } }`.
  - `chooseMenu(.drag)`: `closeOverlay()`, then `drag(id)`.
  - `private func drag(_ id: String)`:
    1. `guard let scene, let step = dragStep(scene, to: id)` (ruling 4);
    2. the `lastEmoteAt`/`emoteInterval` rate limit;
    3. `scene.stopDance(memberID: nil)`;
    4. `session?.sendEmote(.drag, target: id, pushTiles: step.tiles)`;
    5. `scene.playDrag(by: nil, on: id, direction: step.direction)`;
    6. `scene.pushMe(step.direction, tiles: step.tiles)`.

    It makes no `record(...)` call (spec 2 non-goal).

- [ ] **Step 1: Write the failing tests.**
  - `PlazaDragControllerTests`:
    - `testTheMenuListsDragBetweenTackleAndFollow`:
      - me at (20,12) facing `.left`, b at (19,12); Space (49);
      - `actions == [.greet, .tackle, .drag, .follow, .viewCard]`;
      - two downs (125) → `selection == .drag`.
    - `testChoosingDragSendsItFirstThenStepsMeBack`:
      - stage 2; replace b's `onEmote` so it records `b.session.members[w.me.id]?.tile` when a `.drag` arrives;
      - `w.c.setRendering(visible: false)`, so `pushMe` reports at once and the order is visible;
      - `w.c.chooseMenu(.drag, memberID: b.id)`;
      - b receives `TeamEmote(kind: .drag, targetMemberID: b.id, pushTiles: 2)`, and the recorded tile is `[(20,12)]`;
      - I am at (22,12), facing `.left`;
      - `w.c.activity.tackles == 0`.
    - `testMyPullShowsOnMyScreen`, on a visible plaza:
      - Space, down, down, Space: `dustShown` went up by 2;
      - after half a lunge: `lungeOffset(memberID: nil)!.x > 0`;
      - after 1 s: I am at (21,12).
    - `testAShortStepBackSendsWhatIStepped`: stage 3, me at (36,10) facing `.left`, b at (35,10). The sent `pushTiles` is 2 and I end at (38,10).
    - `testNoDragWhenICannotStepBack`. Each layout alone, in a fresh world:
      - me at (44,12), b at (43,12);
      - me at (38,10), b at (37,10);
      - me at (10,12) facing `.up`, b at (10,11);
      - me at (20,12), b at (19,12), c joined at (21,12).

      Each: Space opens the menu, `actions` contains `.tackle` and does not contain `.drag`.
    - `testNoDragForAnEgg`: `world(…, speciesID: nil)`, me at (20,12), b at (19,12). The actions are `[.greet, .tackle, .viewCard]`. Control with species 25: `.drag` is present.
    - `testNoDragWhileISwimEvenWithLandBehindMe` (the "only I am in water" side of ruling 2):
      - me at (10,12) facing `.down`, Z (6), run 0.5 s: I am at (10,13) in water;
      - `w.scene.myBodySize = 3`; b `updateBodySize(3)` at (10,16);
      - precondition: `PlazaDrag.direction(puller: w.scene.myBody, target: w.scene.body(of: b.id)!) == .up`, and `stepBack(from: (10,13), direction: .up, stage: 1, isOpen: ground) == 1`;
      - Space opens b's menu without `.drag`.
    - `testADittoMeStillDragsNormally`:
      - species 132, me at (20,12), b at (19,12);
      - the menu has `.drag`; `chooseMenu(.drag, …)`;
      - b receives `.drag`, no `.mimicTackle`, and `w.c.mimicking == nil`.
    - `testAChangedLayoutAtChoiceTimeDoesNothing`:
      - Space opens the menu with `.drag`; then c joins at (21,12); `chooseMenu(.drag, memberID: b.id)`;
      - b receives no `.drag`, and I stay at (20,12).
    - `testDragSharesTheTackleRateLimit`:
      - C (8) sends a `.tackle`; at once `chooseMenu(.drag, …)` sends nothing;
      - `now += 0.3`, choose again: a `.drag` is sent.
  - `PlazaDittoControllerTests`:
    - `testTheMenuOnACopyHasNoDrag` (`adjacentCopy(start: TilePoint(x: 20, y: 12))`, so the copy is at (21,12)):
      - precondition: `PlazaDrag.line(from: (21,12), to: (20,12)) == .left`, and `stepBack(from: (20,12), direction: .left, stage: 1, isOpen:) == 1` on the scene's open tiles. A member there could be pulled;
      - Space: `actions` contains `.tackle` and not `.drag`.
    - `testTheMenuOnMyOwnCopyHasNoDrag`: the same with `adjacentCopy(ofMe: true, nickname: "재헌", start: TilePoint(x: 20, y: 12))`.
    - `testChoosingDragOnTheDittoSendsNothing`: `adjacentDittoForm()`; `t.c.chooseMenu(.drag, memberID: key)`; settle. `emotes(from: t.a)` has no `.drag`, and `shownDitto` is unchanged.
    - In `testAMenuOnACopyThatTurnedBackDoesNothing`, the loop's list gains `.drag`.
    - `testSpaceOnTheDittoFormOffersOnlyTackle` is unchanged and covers the Ditto form.
  - `PlazaHUDMenusTests.testTheMemberMenuListsDragAfterTackle`:
    - `rig(.memberMenu(PlazaMemberMenu(memberID: "m", nickname: "민수", nameColor: nil)))`;
    - the accessibility labels are `["민수", "인사하기", "몸통박치기", "끌어당기기", "따라가기", "포켓몬 보기"]`, the roles `.staticText` then five `.menuItem`;
    - a click on the third row logs `"menu choose 2"`;
    - `PlazaMenuText.title(.drag) == "끌어당기기"`.
  - `PlazaHUDMenuRenderTests+Mac`: add `MenuCase(name: "member-5-rows", content: .memberMenu(PlazaMemberMenu(memberID: "m4", nickname: "피카츄", nameColor: nil, selection: .drag)))`. `testMenusAreWhereAndAsBigAsSwiftUIMadeThem` checks it against the legacy SwiftUI view.
  - The Sweep C edits:
    - `PlazaFocusTests:637` and `:660` → `[.greet, .tackle, .drag, .follow, .viewCard]`;
    - `PlazaCardTests+Controller:368` → `PlazaMemberMenu(memberID: id, nickname: "민수", selection: .greet, actions: [.greet, .tackle, .follow, .viewCard])`;
    - `PlazaCardTests+Controller:750` → the same without `selection`. Both carry the comment "no 끌어당기기: the tile behind me (23,5) is the board";
    - `PlazaCardTests+Mac.testMenuKeepsItsWidthAndOneLineEach` → "The name and five rows with five gaps", bound `6.5 * line + 2 * (PlazaRosterMetrics.padding + 2) + 5 * 4`, message "six lines, none wrapped".
- [ ] **Step 2: Run** `swift test --filter 'PlazaDragControllerTests|PlazaHUDMenusTests'`. Expected: the build fails (`type 'PlazaMemberAction' has no member 'drag'`).
- [ ] **Step 3: Implement** the Interfaces.
- [ ] **Step 4: Run** `swift test --filter 'PlazaDragControllerTests|PlazaDittoControllerTests|PlazaMimicControllerTests|PlazaHUDMenusTests|PlazaHUDMenuRenderTests|PlazaCardTests|PlazaInteractionTests|PlazaFocusTests|PlazaWindowTests|PlazaBodySizeControllerTests|PlazaPanelRenderTests'`. Expected: PASS.
- [ ] **Step 5: Injection.** Run each change with Step 4's filter, then revert it:
  - Look the target up in `scene.interactionTiles` instead of `memberTiles`. Expected: `testTheMenuOnACopyHasNoDrag` and `testTheMenuOnMyOwnCopyHasNoDrag` FAIL.
  - Drop the water check. Expected: `PlazaWindowTests.testTackleReachesASwimmingTarget` and `testNoDragWhileISwimEvenWithLandBehindMe` FAIL.
  - Drop the focus check. Expected: `PlazaFocusTests.testFocusingTeammateMenuHasNoTackleOrFollow` and `testWhileFocusingMyMenuHasNoTackleOrFollow` FAIL.
  - Drop `scene.canWalk`. Expected: `testNoDragForAnEgg` FAILs.
  - In `drag`, step back before sending. Expected: `testChoosingDragSendsItFirstThenStepsMeBack` FAILs.
  - In `drag`, skip the `dragStep` re-check (use the menu's step). Expected: `testAChangedLayoutAtChoiceTimeDoesNothing` FAILs.

  After the last revert, run Step 4's filter. Expected: PASS.
- [ ] **Step 6: Run** `scripts/shared-check.sh`. Expected: it builds.
- [ ] **Step 7: Commit** `feat(team): pull a teammate from the plaza Space menu`.

### Task 4: Move me at most once a second per teammate

**Files:**
- Modify `Sources/PokeTokenBar/Team/Plaza/PlazaWindowController.swift`:
  - near `:1249`: `private var shoves = PlazaShove()`;
  - `showTackle` `:1137`;
  - `showSnowball` `:1241`;
  - `showPull` `:1279-1283`;
  - `showDrag` (Task 2).
- Test: `Tests/PokeTokenBarTests/PlazaDragControllerTests.swift` (`// MARK: - Receive cooldown`, `// MARK: - Hostile peers`).

**Interfaces:**
- Consumes: Task 1's `PlazaShove`.
- Produces `shoves.admit(sender, now: clock())` as the last guard on each path:
  - `showTackle`: `if canBePushed, shoves.admit(sender, now: clock()) { scene.pushMe(direction, tiles: tiles) }`, after the reveal.
  - `showSnowball` landing: `else if self.canBePushed, self.shoves.admit(sender, now: self.clock()) { … pushMe … }`.
  - `showPull`: `let drag = …, shoves.admit(sender, now: clock()) else { return }` in its guard.
  - `showDrag`: `guard n > 0, shoves.admit(sender, now: clock())`.

  `playDecoyTackle`, reveals and every `play…` call stay outside the cooldown.

- [ ] **Step 1: Write the failing tests** in `PlazaDragControllerTests`. `t0` is the fixture's `now`, a whole second; `now = t0.addingTimeInterval(…)` sets the controller clock.
  - `testTwoTacklesFromOneTeammateUnderASecondApartPushMeOnce`:
    - me at (20,12), b at (19,12); `showTackle(from: b, on: me, tiles: 1)`; run 1 s: I am at (21,12);
    - `place(b, (20,12))`; `now = t0 + 0.99`; tackle again; run 1 s: I am still at (21,12);
    - `impactsShown` went up by 2 (the star shows both times).
  - `testTwoTacklesASecondApartPushMeTwice`: the same at `t0 + 1.0`: I am at (22,12).
  - `testASnowballPullOrDragWithinASecondOfATackleDoesNotMoveMe`. Each follow-up in a fresh world, at `t0 + 0.99`, then a control at `t0 + 1.0` that does move me:
    - snowball: after the tackle, b at (17,12); `showSnowball(… direction: .right)`; run 1.2 s. I stay at (21,12), and `impactsShown` went up. Control: (22,12);
    - pull: me at (15,14), b swimming at (14,14); b's tackle puts me at (16,14); `showPull`; run 1 s. I stay at (16,14). Control: I end in the water at (14,14);
    - drag: after the tackle, b at (20,12); `pull(w, from: b)`; run 1 s. I stay at (21,12), and `dustShown` went up. Control: I move.
  - `testAnotherTeammatesMoveIsNotHeldByTheFirstOnesSecond`: b tackles me from (19,12) at t0; c joins at (20,12) (left of my new tile) and tackles at `t0 + 0.5`. I am at (22,12).
  - `testAnAttemptFromOutOfReachDoesNotStartTheSecond`:
    - b at (18,12) tackles at t0: I do not move;
    - `place(b, (19,12))`; `now = t0 + 0.1`; tackle: I am at (21,12).
  - `testAHundredHitsASecondFromOneTeammateMoveMeOnceASecond` (hostile, spec 7.4):
    - me at (8,12), b at (4,12); `w.c.setRendering(visible: false)`. A hidden plaza lands each ball at once and pushes at once;
    - for i in 0..<200: `now = t0.addingTimeInterval(Double(i) / 100)`, then `showSnowball(from: b, on: me, tiles: 1, direction: .right)`;
    - I am at (10,12): moved at i = 0 and i = 100 only. Without the cooldown, every ball within 11 tiles pushes, to (16,12).
- [ ] **Step 2: Run** `swift test --filter PlazaDragControllerTests`. Expected: FAIL. The second tackle pushes, the follow-ups move me, and the flood ends at (16,12).
- [ ] **Step 3: Implement** the Interfaces.
- [ ] **Step 4: Run** `swift test --filter 'PlazaDragTests|PlazaDragControllerTests|PlazaSnowballControllerTests|PlazaPullUnderTests|PlazaBodySizeControllerTests|PlazaMimicControllerTests|PlazaFocusTests|PlazaWindowShellTests|TeamRuntimeTests|PlazaTackleWaterTests'`. Expected: PASS. No existing test moves me twice from one sender within a second; Sweep A was checked for this.
- [ ] **Step 5: Injection.** Run each change with Step 4's filter, then revert it:
  - Remove `admit` from `showTackle`. Expected: `testTwoTacklesFromOneTeammateUnderASecondApartPushMeOnce` FAILs.
  - Remove it from `showSnowball`. Expected: `testAHundredHitsASecondFromOneTeammateMoveMeOnceASecond` and the snowball case FAIL.
  - Remove it from `showPull`. Expected: the pull case FAILs.
  - Remove it from `showDrag`. Expected: the drag case FAILs.
  - In `showTackle`, check `admit` before `touching`. Expected: `testAnAttemptFromOutOfReachDoesNotStartTheSecond` and `TeamRuntimeTests.testTackleFromBesideMePushesMeOneTileAway` FAIL.
  - Pass `""` as every sender. Expected: `testAnotherTeammatesMoveIsNotHeldByTheFirstOnesSecond` FAILs.

  After the last revert, run Step 4's filter. Expected: PASS.
- [ ] **Step 6: Run** `scripts/shared-check.sh`. Expected: it builds.
- [ ] **Step 7: Coverage.** Run with nothing else building:
```bash
swift test --enable-code-coverage --filter 'PlazaDragTests|PlazaDragControllerTests|PlazaDittoControllerTests|PlazaMimicControllerTests|PlazaHUDMenusTests|PlazaFocusTests|PlazaWindowTests|PlazaSnowballControllerTests|PlazaPullUnderTests|TeamWireTests|TeamRuntimeTests|TeamHostilePeerTests'
BIN_PATH=$(swift build --show-bin-path); PROF=$(find "$BIN_PATH/" -name default.profdata | head -1)
BIN=$(find "$BIN_PATH/" -name PokeTokenBarPackageTests -type f ! -path '*.dSYM/*' | head -1)
LLVM_COV="$(dirname "$(realpath "$(command -v swift)")")/llvm-cov"; [ -x "$LLVM_COV" ] || LLVM_COV=$(xcrun --find llvm-cov)
BASE=$(git merge-base HEAD feat/plaza-body-size)
for f in $(git diff --name-only "$BASE" -- Sources/PokeTokenBar/Team); do
  CHANGED=$(git diff -U0 "$BASE" -- "$f" | awk '/^@@/{split($3,a,/[+,]/); n=(a[3]==""?1:a[3]); for(i=0;i<n;i++) print a[2]+i}')
  "$LLVM_COV" show "$BIN" -instr-profile="$PROF" --show-regions "$f" \
    | awk -F'|' '/^ *[0-9]+\|/{ln=$1+0} /\^0/{print ln}' | sort -u | grep -Fx -f <(echo "$CHANGED") | sed "s|^|$f:|"
done
```
  - This prints each added or changed source line that has a `^0` region.
  - Expected: nothing.
  - If a line is reported, write the missing branch's test. Do not mark it unreachable without the input-path check from CLAUDE.md step 3.
- [ ] **Step 8: Commit** `feat(team): move me at most once a second per plaza teammate`.

### Task 5: TEAM.md, the untouched render check and PR images

**Files:**
- Modify: `TEAM.md` `:161` (the 스페이스 row), and after `:280` (the end of `## 알려진 한계`).
  - `팀에 보이는 것` is unchanged: there is no new presence value, and emotes are already listed.
- No other repo file. Renders go under `$S`.

- [ ] **Step 1: Edit `TEAM.md`.**
  - 스페이스 row:
    - `"인사하기", "몸통박치기", "따라가기", "포켓몬 보기" 메뉴가 뜹니다` becomes `"인사하기", "몸통박치기", "끌어당기기", "따라가기", "포켓몬 보기" 메뉴가 뜹니다`.
    - After `알도 밀립니다.`, insert:
      > `끌어당기기는 내가 뒤로 물러나면서 그 팀원을 끌고 와 내 옆에 세웁니다. 나는 그 팀원을 바라본 채 광장에 선 내 포켓몬의 진화 단계만큼(1~3칸, 뒤가 막혔으면 그 앞까지) 물러나고, 그 팀원은 내 쪽으로 미끄러져 와 내 새 자리 바로 옆에 섭니다. 가는 길에 막힌 칸, 물, 다른 캐릭터가 있으면 그 앞에서 멈춥니다. 앞뒤나 양옆으로 같은 줄에 있는 팀원만 끌 수 있고(포켓몬이 크면 몸이 닿는 만큼 떨어져 있어도 됩니다), 내 뒤에 물러날 빈 땅이 없거나, 나나 그 팀원이 집중 중이거나 물속에 있거나, 내가 알이면 메뉴에 나오지 않습니다. 메타몽(메타몽 모습과 복사본)은 끌 수 없습니다. 끌려오는지는 그 팀원 쪽 앱이 정하므로, 그 팀원 화면에서 이미 비켜섰으면 나만 물러납니다. 변장한 메타몽 팀원은 끌려오지 않고 정체가 드러납니다. 같은 팀원이 몸통박치기, 끌어당기기, 물귀신, 던지기로 나를 움직이는 것은 1초에 한 번뿐이라, 1초 안에 또 오면 충격 별이나 당기는 모습만 보이고 움직이지 않습니다. `
  - End of `알려진 한계`: add `- v2.5.635 이하를 쓰는 팀원은 끌어당기기를 받지 못해 끌려오지 않습니다. 끄는 사람은 그대로 물러나고, 그 팀원 화면에는 끄는 사람이 물러나는 것만 보입니다. 그 버전에는 1초에 한 번만 움직이는 규칙도 없어서 연달아 밀릴 수 있습니다. 업데이트하면 바로잡힙니다.`
  - Re-check the version at release: it must be the last released version without this PR (ruling 10).
  - `TeamReleaseScriptTests.testTeamGuideHoldsNoPrivateDetails` must still pass: no `@`, no `.local`.
- [ ] **Step 2: Render check, untouched.** Run `env -u PTB_PLAZA_RENDER_ONLY scripts/plaza-render-cross.sh --check --scratch "$S/cross"`.
  - Expected: `CROSS-MAC: reference is current (<count> captures)`.
  - If a stem is listed, run the same `--check` in a scratch worktree at the parent of Task 1's commit. A stem that is stale there too is not PR 3's.
  - Never `--write` in this PR.
- [ ] **Step 3: PR images** (offscreen, never committed; the memory note on offscreen plaza renders applies).
  - Add a temporary, env-gated test `Tests/PokeTokenBarTests/PlazaDragImages+Mac.swift`. It skips unless `PTB_DRAG_OUT` is set.
  - **The menu, before and after**, at ×2: `PlazaMenuPanel` through `PlatformPlaza.graphics`, cropped to the menu.
    - Before: `PlazaMemberMenu(memberID: "m", nickname: "피카츄", nameColor: nil, actions: [.greet, .tackle, .follow, .viewCard])`, today's four rows.
    - After: the default five-row menu with `selection: .drag`.
  - **The drag (new; there is no earlier screen).** Model it on `PlazaRenderCompareTests.testRenderAllScenes`: `PlazaRenderScenes.stage`, `PlazaOffscreenRenderer`, frame stepping, PNG out, `backingOverride = 1`, saved at ×2 nearest. Two strips at t = 0, 0.12, 0.4, 0.8 and 1.4 s:
    - The target's screen: me at (20,12), the puller at (19,12). `playDrag(by: puller, on: nil, direction: .left)`, then `pushMe(.left, tiles: 2, pulledBy: puller)`. At the first frame, the puller is moved to (17,12) by `put`, as presence would.
    - The puller's screen: me at (20,12) facing `.left`, the target at (19,12). `playDrag(by: nil, on: target, direction: .right)` and `pushMe(.right, tiles: 2)`. The target is moved to (21,12) by `put`.
    - The sprites: Pikachu #25 and Bulbasaur #1, read-only from `~/Library/Application Support/PokeTokenBar/sprites`. If either is not cached, use the harness crowd looks and say so in the caption.
  - Make a contact sheet `$S/approval/pull.png` with a scratch `python3 -I` PIL script at `$S/tools/contact.py`. Label it "Sample-data render, offscreen (SKRenderer), not the live app".
  - Delete the temp test. `git status` must show only `TEAM.md`.
- [ ] **Step 4: Commit** `docs(team): explain plaza dragging and the receive cooldown in TEAM.md`.

---

## After the plan (PR)

- **Before the PR:**
  - after PR 1 and PR 2 land, merge `origin/main` into the branch;
  - re-run Task 5 Step 2: it must still say "current";
  - re-run Task 4 Step 4's filter.
- **Prepare the PR with `prepare-pr`.**
  - Title: `feat(team): pull a teammate from the plaza menu, with a receive cooldown`.
  - Under `UI changes`, put the Task 5 contact sheet, pushed to the PR-image gist. Label it "Sample-data render, offscreen". The drag strip has no earlier screen; say so.
  - The body names:
    - R1: the shape (I step back, the target follows) is the designer's call, not yet seen by the user. The other shapes the spec names are a swap or a pull from afar;
    - R8: an honest second tackle, drag, 물귀신 or snowball from the same teammate within a second shows but does not move. `PlazaShove.receiveCooldown` is the constant to tune;
    - the ten rulings at the top of this plan and the "found, not changed" list;
    - the mixed-version behaviour (spec 7.2, the new `TEAM.md` line). Old peers skip the frame without cooling the link (`v2.5.635` `TeamWire.swift:281`);
    - that no render reference changed.
- **Push** with `git push origin feat/plaza-pull:feat/plaza-pull`, and check the windows.yml test job (the shared suites, including `PlazaDragTests` and `PlazaDragControllerTests`).
  - On Windows, `plaza.panels` and `plaza.clicks` use the default menu. They now draw and click its fifth row; their counts are computed, not fixed.
- **Release (later, not this PR):** check the `v2.5.635 이하` line against the version actually shipped, together with PR 1's and PR 2's `v2.5.636 이하` lines.
