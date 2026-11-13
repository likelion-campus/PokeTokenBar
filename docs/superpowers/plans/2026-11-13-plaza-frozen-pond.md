# Plaza Frozen Ponds Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The three plaza ponds freeze one at a time on a 3-minute turn. Members walk on the frozen pond. A breaking jump (Z) cracks and shatters the ice, and everyone standing on it falls in. Every new-version Mac sees the same pond frozen.

**Architecture:**
- **Pure rules.** A SpriteKit-free `PlazaIce` (`PlazaIce.swift`) finds the ponds, computes the 3-minute turn, merges "last breaks" and derives the frozen pond. It also holds the break timeline.
- **The controller.** It owns the last break the team knows (`PlazaIceBreak`). It saves it in the plaza preferences, sends it in presence and on a `.jump` emote, and hands it to the scene.
- **The scene.** It asks one question everywhere: "water now / walkable now?" It runs the break's rules (the jump lands at 0.36 s, the ice sinks at 0.6 s) on scene time only.
- **The art.** A pooled `PlazaIceLayer` draws the ice, cracks and shards from the elapsed time. The ice picture is the scene's own snow-map pixels with exact colour swaps. Cracks, gloss and shards come from three unmodified artist files, recoloured at runtime by `PlazaIceArt`.

**Tech Stack:** Swift 6 (CI: macos-15, Xcode 16), SpriteKit, CoreGraphics/ImageIO, XCTest, SwiftPM.

**Spec:** `docs/superpowers/specs/2026-11-13-plaza-frozen-pond-design.md` (Korean). Section numbers below (§5.1 etc.) point into it. Its approved reference image is `docs/superpowers/specs/2026-11-13-plaza-frozen-pond-mock.png`.

## Global Constraints

- **Where to work.** Work only in `/Users/simu/Documents/GitHub/PokeTokenBar/.worktrees/frozen-pond` (branch `feat/frozen-pond`, based on origin/main ef11253 plus the spec commit 2d6b790). Never edit the main checkout or any other worktree.
- **Toolchain.** Code must compile with the CI toolchain (macos-15, Xcode 16, Swift 6.1). Use no newer language features.
- **One Swift process at a time.** Only one `swift build` or `swift test` process may run on this Mac at a time. Before every run, `pgrep -x swift-build`, `pgrep -x swift-test` and `pgrep -x xctest` must all print nothing.
- **Focused tests (lean flow).** Every test run is focused: `swift test --filter '<Class>|<Class>'`. Never run the full suite; it runs only in the release gate.
- **No focus stealing.** Tests never take keyboard focus. That rules out window `show()`, `NSApp.activate`, `finishLaunching`, run loops and event pumping. Build controllers with `prepareScene()` and drive scenes with `update(_:)`.
- **UserDefaults.** Tests create UserDefaults suites only through `TestDefaults.make(suite:)`. `TestDefaultsScanTests` enforces this.
- **Commits.** English Conventional Commits whose message ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Don't push.
- **Korean text.** Team UI is Korean only. Korean string literals live only in `Sources/PokeTokenBar/Team/TeamLocalization.swift` (`TeamLocalizationTests`). `TEAM.md` is Korean, in its current tone.
- **Art: no code-drawn pixel art.** Use only the plaza's own map pixels and the three artist files, with the exact colour swaps of §4:
  - `ice_mountain_tileset.png` sha256 `28faadcc4cddd8cc8a6962bb5c5a5bdd475c4133d174ac979a3d74a309397f3e`.
  - `stuff_1.png` sha256 `9973d4d6674d0f3cb475d33878f832ee05dc057e2adfae006577688c85d01214`.
  - `boulder.gif` sha256 `b5907dd9b03aec03bd4a26acb48b125d8af528a7170dbc1326562d88b54587db`.
  - All three ship byte-identical. The approved art (§4, **[결정]**) is not retouched: no fewer crack strands, no bigger shards.
- **Wire.**
  - New fields are optional and go through `LossyOptional`, so an unreadable value becomes nil and the rest of the frame lives.
  - Older versions keep decoding everything they decode today.
  - `TeamWire.protocolVersion` stays 1, and there is no new emote kind: a breaking jump is a `.jump`.
- **Timing.**
  - Scene time flows only through `update(dt:)`. No `Timer`, no `DispatchQueue.asyncAfter`, and no `SKAction` in the ice code.
  - Correct state never depends on an animation having run (§2 anti-goal, §7). A paused scene resolves at once.
  - The freeze fade is computed from the clock.
- **Received values (`docs/reference/defect-log.md` "팀 네트워크 (피어 입력)").**
  - Treat every received break as chosen by a hostile app. Drop it unless its turn is at most my turn + 1 and its pond is one of my ponds' anchors.
  - Queue at most `PlazaScene.maxIceLandings` landings.
  - Make no nodes on a paused scene.
- **Energy (defect log "에너지 (상시 표시 애니메이션)").**
  - With the ice standing still, the per-frame work is one turn-number comparison.
  - Every ice node is pooled under a named cap.
- **Numbers (§3, §4).**
  - The turn is `floor(unix seconds / 180)`.
  - Cracks appear in ring `Int(hypot(dx, dy))` at `ring × min(0.055, 0.33 / maxRing)` s.
  - Shards come as 6 bursts. The first starts at 0.26 s, the others 0.04 s apart, each 3 frames of 0.07 s, drawn 64×64 world px.
  - Ice and cracks fade from 0.50 to 0.65 s. The pond turns to water at 0.60 s.
  - A freezing pond fades in over 1 s. The breaking jump lasts 0.36 s (`PlazaActor.jumpDuration`).
- **Keep these exactly as they are:** every **[결정]** in the spec, the Ditto never entering pond tiles, the minimap staying water-coloured, no footprints on ice, and no date/weather/chance gate (the ice always runs).

## Review Focus

1. **The window is covered mid-break, or a breaking jump arrives while it is covered.**
   - Expected: the landing happens at once and the pond is water. Everyone who stood on it swims on the first frame after uncovering, and no nodes are made while covered.
   - Tests: Task 4 `testPausingMidBreakSinksAtOnceAndLeavesNoBreak`, Task 6 `testABreakWhileCoveredIsWaterWhenUncovered`.
2. **A 3-minute boundary passes while the window is covered or the Mac sleeps.**
   - Expected: the next pond is solid on the first frame, fully opaque, with no fade replayed.
   - Tests: Task 4 `testATurnPassedWhilePausedFreezesAtOnce`, Task 5 `testAFreezeLongAgoShowsAtFullOpacity`.
3. **The breaker's presence arrives before (or during) the 0.36 s wait for their jump to land.**
   - Expected: the break still starts when the jump lands, from the jumper's tile. It does not start at once, and not from the centre.
   - Test: Task 6 `testPresenceBeforeTheLandingWaitsForTheJump`.
4. **People on a pond when its state changes.**
   - Expected: a diver on a freezing pond stands on the ice and their dive ends. An egg on breaking ice climbs out. Someone who walks off within the 0.6 s stays dry, and someone who walks on sinks.
   - Tests: Task 4 `testFreezingUnderASwimmerAndADiverStandsThemOnTheIce`, `testAnEggOnBreakingIceClimbsOut`, `testStepsDuringTheBreakDecideWhoSinks`.
5. **A teammate with a far-ahead clock or a modified app.** They send a turn two or more ahead, a tile that is no pond's anchor, `Int.max`/`Int.min`, or a flood of breaking jumps.
   - Expected: each such break is dropped or loses the merge. At most `maxIceLandings` landings are queued, and no nodes pile up.
   - Tests: Task 1 `testAcceptedDropsFutureTurnsAndUnknownPonds`, Task 6 `testFutureForeignAndImpossibleBreaksAreDropped`, `testAFloodOfBreakingJumpsStaysUnderTheCap`.

## Builder decisions (settled here)

- **The ice-state type.**
  - `PlazaIce.swift` holds `struct PlazaIceBreak: Codable { pond: TilePoint; turn: Int }` (§6), `PlazaIce.Pond`, and the pure functions in Task 1. These are pond discovery, the turn, `accepted`, `merged`, `frozenIndex`, `freezeAlpha` and the timeline.
  - The Z decision stays in `PlazaPond.action`. It gains an `isIce` closure and two cases, `.breakIce` and `.leapOntoIce(d)`.
- **Dynamic water and walkability.**
  - The scene gains `isWaterNow(_:)` (a pond tile that is not solid ice) and `isWalkableNow(_:)` (a map-walkable tile or solid ice).
  - Each "yes" row of §5.1 swaps `map.isWater`/`map.isWalkable` for these. The full list of call sites is in Task 4. Every "no" row keeps the static map.
  - `PlazaPathfinder.path` gains an optional `isWalkable` closure.
  - The controller's pull-under checks use `scene.isWaterNow`.
  - A scene built without `iceArt` never freezes anything. That is every existing scene test. The controller always passes the art.
- **Driving the break.**
  - The scene owns the rule timeline: queued landings (0.36 s each), one `breaking` slot, and the sink at 0.6 s. It advances them in `update(dt:)`.
  - The layer only draws from the elapsed time.
  - Pausing the scene (`isPaused` set to true) lands every queued jump, finishes the break (sinking at once if 0.6 s had not come) and clears the drawing. So does closing the window, which pauses the scene.
  - A hidden background hides the layer, but the timeline and the rules go on.
  - A change in the known state animates only while the scene is unpaused and has drawn at least one frame. Otherwise it applies at once. That covers the window opening (§6 "광장을 열 때는 아는 상태 그대로").
- **Persistence.** The last break is saved under the preference key `team.plaza.iceBreak` as JSON-encoded `PlazaIceBreak`, like `focus`; nil removes the key. On load it goes through `PlazaIce.accepted`.
- **The breaking jump.**
  - It reuses `plunge`. `PlazaWalker.plunge(_:duration:)` gains an optional fixed step length.
  - `PlazaScene.leapOntoIce(d)` plunges with `PlazaPond.plungeStepDuration` (0.36 s).
  - `plungeJumpOwed` changes from `Bool` to the target tile. The jump arc plays when the walker's step to that tile starts.
  - The landing (and the break) is timed 0.36 s of scene time from the press, the same as on receiving Macs (§6).
- **Order of my own break.**
  - At the press, the controller sends `.jump` with `iceBreak` (the turn at the press, §6 **[구현자 재량]**) and queues my landing.
  - At the landing it learns the break. It saves it, updates my presence and sets it on the scene, so the presence goes after the emote (§6).
  - A presence break that equals a queued landing is not learned until that landing.
- **Hit tiles.**
  - The hit is the jumper's shown tile at landing (`walker.tile` for me), clamped to the pond's nearest tile (Euclidean, ties row-major).
  - A presence-only break uses the pond's centre: the tile nearest the centroid, ties row-major. That gives (9,14), (35,17) and (21,25).
- **Shards are not in photos** (§7 **[구현자 재량]**). Ice and visible cracks are, with their current alpha.
- **Layer z.** Ice 0.02, cracks 0.025, shards 0.045. That is above the map (0) and footprints (0.04), below tall-grass overlays (0.05), rings (0.06), shadows (0.5) and characters (1+).
- **Resource names** are the spec's: `plaza-ice-cracks.png`, `plaza-ice-gloss.png` and `plaza-ice-shatter.gif`. They are loaded like `plaza-tallgrass.png`, through `PlazaResources.resourceURL` and `CGImageSource`, and cached once per process in the controller (`cachedIceArt`).
- **Gloss spots for the other two ponds** (§4.1 **[설계자 판단·미확인]**, fixed here). Each patch is (pond-local i, j, n, rx, ry):
  - Left: (1,0,2,30,22), (5,1,1,15,12) and (8,0,1,15,12).
  - Bottom: (1,1,1,15,12).
- **The crack cell per tile** (§4.2 **[구현자 재량]**):
  - Seed `PlazaSplitMix64(seed: UInt64(PlazaNameColor.fnv1a("plaza-ice-crack-\(x)-\(y)")))`.
  - `cell = Int(next() % 6)`, and the cell is mirrored when `next() % 2 == 1`. The index is `cell + (mirrored ? 6 : 0)`.
- **Sinking.** At 0.6 s, or at once for an unanimated change, every actor whose tile (the destination when walking) is in the pond gets one big splash at that tile with its own stage (`splash(... big: true ...)`). Nobody is moved. A paused scene makes no splash and calls `climbOutNowIfPaused()`.
- **Quitting while on the ice** restarts at the spawn. `PlazaPreferences.lastTile` stays static, as it is today for swimmers.

## Spec notes found while planning (reported, not changed)

- **§4.3, interior tiles.** It says the 10×3 pond has fewer than five interior tiles, so all its tiles are shard candidates. It has eight: row 14, x 6–13. This plan follows the general rule (fewer than five interior tiles means all tiles). So the left pond's shard bursts stay on its middle row. If the user wanted the parenthesis, change `shardTiles`' candidate rule and its test only.
- **§4.6, source addresses.** It asks for source addresses in CREDITS.md but gives none, only sha256s. This plan takes them from the mock's saved OpenGameArt pages (Task 3).
  - Two of the pages' attachment names differ from the spec's file names: the gloss attachment is `stuff_0.png` (the preview is `stuff_1.png`), and the shards attachment is `boulder_0.gif` (the preview is `boulder.gif`).
  - Keep whichever download matches the sha256.
- **§5.4, the hint.** Ruling (controller, after the plan was written): the spec now shows the hint only when Z would break the ice, i.e. when I can move (`scene.canWalk && !isFocusing`). An egg or a focusing member on the ice sees no ice hint.
- **§4.4 vs §5.1, a step onto the pond at 0.6 s.** A member mid-step from the shore onto a breaking pond at 0.6 s gets their big splash at 0.6 s, slightly before they land. §5.1 leaves this detail to the implementer.

---

## File Structure

| File | Responsibility |
|---|---|
| Create `Sources/PokeTokenBar/Team/Plaza/PlazaIce.swift` | `PlazaIceBreak`, `PlazaIce.Pond`, turn, merge, frozen pond, freeze fade, break timeline, shard tiles, crack cell. Pure. |
| Create `Sources/PokeTokenBar/Team/Plaza/PlazaIceArt.swift` | Gloss cell, crack cells, shard frames and the per-pond ice overlay. Pure CoreGraphics. |
| Create `Sources/PokeTokenBar/Team/Plaza/PlazaIceLayer.swift` | Pooled sprites: ice per pond, cracks, shards. Draws from a given elapsed time. |
| Create `Sources/PokeTokenBar/Resources/Plaza/plaza-ice-cracks.png`, `plaza-ice-gloss.png`, `plaza-ice-shatter.gif` | The three unmodified artist files. |
| Modify `PlazaPond.swift`, `PlazaWalker.swift`, `PlazaPathfinder.swift` | Z cases, plunge length, walkability closure. |
| Modify `PlazaScene.swift` | Water/walkable now, the ice state and timeline, landings, sinking, leap, layer and photo. |
| Modify `PlazaPhotoRenderer.swift`, `PlazaResources.swift`, `PlazaPreferences.swift` | Ice in photos, loaders, saved break. |
| Modify `PlazaWindowController.swift`, `Team/TeamRuntime.swift`, `Team/TeamLocalization.swift` | Z, learning and saving breaks, presence, hint, routing. |
| Modify `Team/TeamWire.swift`, `Team/TeamSession.swift` | Optional `iceBreak` on `TeamEmote` and `TeamPresence`. |
| Modify `Resources/Plaza/CREDITS.md`, `TEAM.md`, `scripts/test-gate.sh` | Credits, user docs, and the logic-core list. |

All Swift files are under `Sources/PokeTokenBar/Team/` (`Plaza/` unless shown). Tests go in `Tests/PokeTokenBarTests/`.

Ponds on the real map, in row-major order of their first tile:

| Pond | Anchor | Size |
|---|---|---|
| L (left) | (5,13) | 10×3 |
| R (right) | (32,14) | 7×7 |
| B (bottom) | (20,24) | 3×3 |

Shore and land tiles used below: (4,14), (4,13), (6,12), (3,14), (15,14), (16,14), (31,17) and (19,25).

---

### Task 1: The ice rules (`PlazaIce.swift`) and the Z decision

**Files:**
- Create: `Sources/PokeTokenBar/Team/Plaza/PlazaIce.swift`
- Modify:
  - `Sources/PokeTokenBar/Team/Plaza/PlazaPond.swift` (`PlazaPondAction`, `action`)
  - `PlazaWindowController.swift`: `handleJumpKey`'s switch only, so it keeps compiling
  - `scripts/test-gate.sh`: add `PlazaIce.swift` to `LOGIC_CORE`
- Test: `Tests/PokeTokenBarTests/PlazaIceTests.swift` (new), `PlazaPondTests.swift` (extend)

**Interfaces:**
- Produces:
  ```swift
  /// The last break (§3): the broken pond's anchor and the turn it broke in. Sent on a jump emote and in presence (§6).
  struct PlazaIceBreak: Codable, Equatable, Sendable { var pond: TilePoint; var turn: Int }

  enum PlazaIce {
      struct Pond: Equatable, Sendable {
          let anchor: TilePoint            // its row-major first tile
          let tiles: [TilePoint]           // row-major
          let minX: Int, minY: Int, maxX: Int, maxY: Int
          func contains(_ t: TilePoint) -> Bool        // Set-backed
          var inner: [TilePoint] { get }               // tiles whose four neighbours are all in the pond, row-major
          var center: TilePoint { get }                // tile nearest the centroid, ties row-major
          func nearestTile(to t: TilePoint) -> TilePoint   // t itself if inside; else nearest (Euclidean), ties row-major
      }
      static let turnLength: TimeInterval = 180
      static let freezeFade: TimeInterval = 1
      static let crackStep: TimeInterval = 0.055, crackSpan: TimeInterval = 0.33
      static let shardStart: TimeInterval = 0.26, shardStagger: TimeInterval = 0.04, shardFrameLength: TimeInterval = 0.07
      static let shardBursts = 6, shardFrames = 3
      static let fadeStart: TimeInterval = 0.5, fadeEnd: TimeInterval = 0.65
      static let sinkAt: TimeInterval = 0.6
      static let breakEnd: TimeInterval = 0.67          // shardStart + 5·shardStagger + 3·shardFrameLength

      static func turn(at date: Date) -> Int                                   // Int((t / 180).rounded(.down))
      /// 4-connected groups of `PlazaTile.pond`, ordered by anchor (row-major). [] on a map without water.
      static func ponds(in map: PlazaMap) -> [Pond]
      /// nil unless b.turn <= turn + 1 and b.pond is one of the anchors.
      static func accepted(_ b: PlazaIceBreak?, turn: Int, ponds: [Pond]) -> PlazaIceBreak?
      /// The larger (turn, pond order) of the two; nil loses; on a tie, `a`.
      static func merged(_ a: PlazaIceBreak?, _ b: PlazaIceBreak?, ponds: [Pond]) -> PlazaIceBreak?
      /// No ponds: nil. last nil (or an unknown anchor): 0. turn <= last.turn: nil. Else the next pond after last.pond, wrapping.
      static func frozenIndex(last: PlazaIceBreak?, turn: Int, ponds: [Pond]) -> Int?
      /// last nil: 1. Else clamp((now − (last.turn + 1)·180) / freezeFade, 0, 1).
      static func freezeAlpha(now: Date, last: PlazaIceBreak?) -> CGFloat
      static func ring(of t: TilePoint, hit: TilePoint) -> Int                  // Int(hypot(dx, dy))
      static func crackStep(maxRing: Int) -> TimeInterval                       // maxRing > 0 ? min(0.055, 0.33 / maxRing) : 0.055
      /// 1 before fadeStart, linear to 0 at fadeEnd, then 0.
      static func iceAlpha(elapsed: TimeInterval) -> CGFloat
      /// Burst k (0...5) starts at shardStart + k·shardStagger; frame 0...2 while it runs, else nil.
      static func shardFrame(burst: Int, elapsed: TimeInterval) -> Int?
      /// [hit] + 5 more. Candidates: `inner` if it has at least 5 tiles, else every tile. Each pick maximises the smallest
      /// Euclidean distance to the hit and the tiles already picked; ties row-major.
      static func shardTiles(pond: Pond, hit: TilePoint) -> [TilePoint]
      /// 0..<12 from the fixed hash in "Builder decisions"; >= 6 means the cell (index − 6) mirrored.
      static func crackCell(at t: TilePoint) -> Int
  }
  enum PlazaPondAction { ...existing cases..., case breakIce, leapOntoIce(PlazaDirection) }
  // PlazaPond.action gains a last parameter `isIce: (TilePoint) -> Bool = { _ in false }`
  ```
- Rules added to `PlazaPond.action`, before the existing land branch and after the water branch:
  - On `isIce(tile)`: `.breakIce` when `canMove`, else `.jump`.
  - On land, if `canMove`, `isIce(ahead)` and `isFree(ahead)`: `.leapOntoIce(facing)`. The existing `.plunge` check comes first.
  - Everything else is unchanged. `nearWater` uses `isWater` only, so standing beside ice gives `.jump`.
- In `handleJumpKey`'s switch, add `case .breakIce, .leapOntoIce: break   // wired in Task 6`.

- [ ] **Step 1: Write the failing tests.**
  - **`PlazaIceTests`** (real `PlazaMapData.map` unless noted; `L`, `R`, `B` are the ponds; `T = 9_960_000`):
    - `testPondsAreFoundInRowMajorOrderOfTheirFirstTile`:
      - The anchors are [(5,13), (32,14), (20,24)], with 30, 49 and 9 tiles.
      - The bounds of R are 32...38 × 14...20.
      - A map with no `w` gives [].
    - `testPondsJoinOnlyThroughTheFourSides`: the map `["SN....", "ww.w..", "..w...", "......"]` gives anchors [(0,1), (3,1), (2,2)] with 2, 1 and 1 tiles.
    - `testTheTurnIsThreeMinutesLikeTheItemSlot`: 0 s → 0, 179.999 → 0, 180 → 1, −0.5 → −1.
    - `testTheFrozenPondFollowsTheLastBreak`:
      - nil → 0.
      - (L, T) at T → nil; at T+1 → 1.
      - (R, T) at T+1 → 2.
      - (B, T) at T+1 → 0.
      - With `ponds: []` → nil.
    - `testMergeKeepsTheLaterTurnThenTheLaterPond`:
      - (L,T) vs (R,T−1) → (L,T).
      - (L,T) vs (R,T) → (R,T).
      - (B,T) vs (R,T) → (B,T).
      - nil vs x → x, and x vs nil → x.
      - Equal values → the first.
    - `testAcceptedDropsFutureTurnsAndUnknownPonds`, at turn T:
      - (L,T+1) is kept.
      - (L,T+2) and (L,Int.max) are nil.
      - (L,Int.min) is kept.
      - ((6,13),T) is nil: not an anchor. nil → nil.
    - `testFreezeAlphaFadesInOverASecondFromTheBoundary`, with last (L,T) and boundary `(T+1)·180`:
      - boundary − 1 → 0; +0.25 → 0.25; +2 → 1.
      - last nil → 1; last (L,Int.min) → 1.
    - `testCentreAndNearestTile`:
      - The centres are L (9,14), R (35,17) and B (21,25).
      - R's nearest tile to (31,17) is (32,17), to (30,13) is (32,14), and to (40,25) is (38,20). (34,16) gives itself.
    - `testCrackRingsAndTheirStep`:
      - From hit (32,17), R's ring counts are {0:1, 1:5, 2:9, 3:11, 4:7, 5:9, 6:7}.
      - `crackStep(maxRing: 6) == 0.055`, `crackStep(maxRing: 9) == 0.33/9` and `crackStep(maxRing: 0) == 0.055`.
    - `testShardTilesSpreadFromTheHit`:
      - R from (32,17) → [(32,17), (37,15), (36,19), (34,15), (35,17), (33,19)].
      - L from (5,14) → [(5,14), (13,14), (9,14), (7,14), (11,14), (6,14)].
      - B from (20,24) → [(20,24), (22,26), (22,24), (20,26), (21,25), (21,24)].
    - `testTheBreakTimeline`:
      - `iceAlpha`: 0.49 → 1, 0.575 → 0.5 (accuracy 1e-9), 0.65 → 0, 0.7 → 0.
      - Burst 0: 0.25 → nil, 0.27 → 0, 0.34 → 1, 0.41 → 2, 0.48 → nil.
      - Burst 5: 0.45 → nil, 0.47 → 0, 0.62 → 2, 0.68 → nil.
      - `breakEnd` equals `shardStart + 5·shardStagger + 3·shardFrameLength` within 1e-9.
    - `testCrackCellsAreFixedPerTileAndUseAllSix`:
      - `crackCell(at: (32,14)) == 5`, `(35,17) == 0` and `(20,24) == 8`.
      - Over R, `Set(cells.map { $0 % 6 })` has all 6, and 25 of the 49 are `>= 6`.
  - **`PlazaPondTests.testZOnIceBreaksAndFromTheShoreLeaps`**, with water `{}` and ice `{(6,5)}`, built like `act` with an `isIce` argument:
    - On (6,5): `.breakIce`, or `.jump` with `canMove: false`.
    - From (5,5) facing `.right`: `.leapOntoIce(.right)`.
    - The same with `free: false`, or `canMove: false`: `.jump`.
    - From (5,5) facing `.up`: `.jump`.
    - The existing test, which leaves `isIce` out, still passes.
- [ ] **Step 2:** Run `swift test --filter 'PlazaIceTests|PlazaPondTests'`. Expected: build failure (`PlazaIce` not defined).
- [ ] **Step 3: Implement** as above. Give `Pond` a private `Set<TilePoint>` for `contains`. Build ponds with one BFS per unseen `.pond` tile, scanning row-major.
- [ ] **Step 4:** Run `swift test --filter 'PlazaIceTests|PlazaPondTests|PlazaPondMapTests'`. Expected: all pass.
- [ ] **Step 5:** Commit: `feat(team): add the frozen pond rules`.

---

### Task 2: The break on the wire

**Files:**
- Modify: `Sources/PokeTokenBar/Team/TeamWire.swift`, `Sources/PokeTokenBar/Team/TeamSession.swift`
- Test: `TeamWireTests.swift`, `TeamSessionTests.swift` (both extend)

**Interfaces:**
- Consumes: Task 1 `PlazaIceBreak`.
- Produces:
  ```swift
  // TeamEmote, declared after `snowballDirection`
  /// A jump that breaks the plaza ice: the frozen pond and the turn (§6). Left out by every other jump and kind; earlier
  /// versions see a plain jump. Unreadable values become nil.
  @LossyOptional var iceBreak: PlazaIceBreak?
  // TeamPresence, declared after `mimicOf`
  /// The last plaza ice break this member knows. Every member passes it on. Left out when none.
  @LossyOptional var iceBreak: PlazaIceBreak?
  // TeamMemberState
  var iceBreak: PlazaIceBreak?          // as received; the plaza filters it
  // TeamSession
  func sendEmote(..., snowballDirection: PlazaDirection? = nil, iceBreak: PlazaIceBreak? = nil)
  func updateIceBreak(_ b: PlazaIceBreak?)   // no-op when unchanged; else broadcast presence
  ```
- `makePresence` passes `iceBreak:`. `receive(.presence)` copies `presence.iceBreak` into the member.

- [ ] **Step 1: Write the failing tests.**
  - **`TeamWireTests`:**
    - `testIceBreakIsOptionalOnTheWire`:
      - `TeamEmote(kind: .jump, targetMemberID: nil, iceBreak: PlazaIceBreak(pond: TilePoint(x: 5, y: 13), turn: 9_960_000))` round-trips.
      - An encoded plain jump and the plain `presence` contain no `"iceBreak"`.
      - A presence with the break round-trips.
      - `{"emote":{"_0":{"kind":"jump"}}}` decodes with a nil break.
    - `testUnreadableIceBreakDropsOnlyTheBreak`:
      - `{"emote":{"_0":{"kind":"jump","iceBreak":{"pond":"x","turn":1}}}}` decodes to `.emote(TeamEmote(kind: .jump, targetMemberID: nil))`.
      - The `testUnreadableMimicDropsOnlyTheMimic` JSON with `"iceBreak":7` in place of `mimicOf` gives a nil break. Nickname, tile, facing and name colour are kept.
    - `testEveryOptionalFieldSurvivesARoundTrip` sets `full.iceBreak`.
    - `testWireRawValuesArePinned`: the JSON keys of an encoded `PlazaIceBreak` are exactly `["pond", "turn"]`, and `protocolVersion` is still 1.
  - **`TeamSessionTests`:**
    - `testABreakingJumpCarriesItsBreak`: after `a.session.sendEmote(.jump, target: nil, iceBreak: x)`, b's emote has `iceBreak == x`.
    - `testMyLastBreakTravelsInPresence`: `a.session.updateIceBreak(x)` makes `b.session.members[a.memberID]?.iceBreak == x`.
  - Unreadable values are a decoding matter, pinned above. `FakeTeamTransport` carries typed messages, so a session test can't send garbage bytes. Readable hostile values (future turns, foreign anchors) pass through the session as received; Task 6 filters and tests them where they are used.
- [ ] **Step 2:** Run `swift test --filter 'TeamWireTests|TeamSessionTests'`. Expected: build failure.
- [ ] **Step 3:** Implement as above.
- [ ] **Step 4:** Run `swift test --filter 'TeamWireTests|TeamSessionTests|TeamSessionLoopbackTests|TeamHostilePeerTests|PlazaCardTests'`. Expected: all pass. `PlazaCardTests` compares whole `TeamEmote` values.
- [ ] **Step 5:** Commit: `feat(team): carry the plaza ice break on the wire`.

---

### Task 3: The ice art (files, loaders, `PlazaIceArt`)

**Files:**
- Create:
  - `Sources/PokeTokenBar/Resources/Plaza/plaza-ice-cracks.png`
  - `Sources/PokeTokenBar/Resources/Plaza/plaza-ice-gloss.png`
  - `Sources/PokeTokenBar/Resources/Plaza/plaza-ice-shatter.gif`
  - `Sources/PokeTokenBar/Team/Plaza/PlazaIceArt.swift`
- Modify:
  - `PlazaResources.swift`
  - `Resources/Plaza/CREDITS.md`
  - `TEAM.md` ("출처" only)
  - `scripts/test-gate.sh`: add `PlazaIceArt.swift`
- Test: `Tests/PokeTokenBarTests/PlazaIceArtTests.swift` (new), `PlazaResourcesTests.swift` (extend)

**Interfaces:**
- Consumes: Task 1 `PlazaIce.Pond`, `PlazaIce.ponds(in:)`.
- Produces:
  ```swift
  // PlazaResources (same pattern as `tallGrassSheet(in:)`)
  static func iceCrackSheet(in bundle: Bundle?) -> CGImage?      // plaza-ice-cracks.png
  static func iceGlossSheet(in bundle: Bundle?) -> CGImage?      // plaza-ice-gloss.png
  static func iceShatterFrames(in bundle: Bundle?) -> [CGImage]  // every frame of plaza-ice-shatter.gif; [] when missing

  struct PlazaIceArt {
      struct GlossPatch: Equatable { let i: Int, j: Int, n: Int; let rx: Double, ry: Double }
      static let fill: UInt32 = 0xADCDEC, band: UInt32 = 0x94B9DF, hilite: UInt32 = 0xC8DEF4, crack: UInt32 = 0x6A97C6
      static let glossColors: [UInt32] = [0xB5D3EF, 0xC0DBF3, 0xD0E5F8]
      static let shardColors: [UInt32: UInt32] = [0x2D2727: 0x6A98C8, 0x39342F: 0x8FB7DE, 0x736353: 0xD8EAF8, 0xB39B83: 0xF4FAFF]
      /// Keyed by pond anchor: R (32,14) per §4.1, L (5,13) and B (20,24) per "Builder decisions". Other ponds: none.
      static let glossPatches: [TilePoint: [GlossPatch]]
      let gloss: CGImage?        // 16×16, recoloured; nil without the file
      let cracks: [CGImage]      // 12 cells of 16×16: six crack cells, then the same six mirrored; [] without the file
      let shards: [CGImage]      // 3 frames of 32×32 (gif frames 2–4); [] unless the gif has at least 4 frames
      static let none = PlazaIceArt(gloss: nil, cracks: [], shards: [])
      static func load(bundle: Bundle? = PlazaResources.resourceBundle()) -> PlazaIceArt
      static func gloss(fromSheet sheet: CGImage) -> CGImage
      static func cracks(fromSheet sheet: CGImage) -> [CGImage]
      static func shards(fromFrames frames: [CGImage]) -> [CGImage]
      /// The ice over `pond` in world px (32 per tile), covering its bounds grown by one tile; its top-left is world
      /// ((minX − 1)·32, (minY − 1)·32). Map pixels outside the image stay clear.
      static func overlay(mapImage: CGImage, pond: PlazaIce.Pond, gloss: CGImage?) -> CGImage
  }
  ```
- **The recolours (§4.1–4.3).** Read pixels as RGBA8 premultiplied, the way `PlazaSnowSheet.recolored` does.
  - **Gloss:** the cell (51,51)…(66,66) of the sheet. Sort its four colours by 0.30R + 0.59G + 0.11B. The darkest becomes clear; the other three become `glossColors` in order.
  - **Cracks:** for i in 0..<6, the cell at (i·18, 18), 16×16. Only opaque `#4F87BC` pixels stay, as `#6A97C6`; everything else is clear. Cells 6…11 are cells 0…5 mirrored left to right.
  - **Shards:** frames 1, 2 and 3. Opaque pixels whose colour is a key of `shardColors` take its value. Other pixels are unchanged.
- **The overlay.** Write it exactly like this. The approved mock's pixel counts in the tests depend on it.
  ```text
  crop mapImage to the region (bounds ± 1 tile), clipped to the image; read RGBA8
  for each region pixel with RGB c, inside = pond.contains(its tile):
      inside:  out = (c == 0x165C88) ? band : fill
      outside: out = [0x1E7CB8: fill, 0x165C88: band, 0x5AAEE4: hilite][c] ?? clear
  if gloss: g2 = gloss scaled ×2 (32×32, nearest)
      for each patch: S = 32·n; for x, y in 0..<S:
          dx = Double(x) − Double(S)/2, dy = Double(y) − Double(S)/2
          if (dx/rx)² + (dy/ry)² <= 1 and g2[x % 32, y % 32] is opaque:
              out[32·(i+1) + x, 32·(j+1) + y] = g2[x % 32, y % 32]
  ```
- **The files (§4.6).** Download each candidate into its own new empty directory under the scratchpad, then run `shasum -a 256`. Keep the file whose digest matches the Global Constraints value, copy it unmodified to its new name, and delete the downloads. Run any Python on downloaded files with `python3 -I`. If no candidate matches or the network fails, stop and report. Never fall back to the mock's copies.

  | Ship as | Candidate URLs | Page |
  |---|---|---|
  | `plaza-ice-cracks.png` | `…/files/ice_mountain_tileset.png` | `https://opengameart.org/content/ice-mountains-tileset` |
  | `plaza-ice-gloss.png` | `…/files/stuff_1.png`, `…/files/stuff_0.png` | `https://opengameart.org/content/some-16x16-floor-tiles` |
  | `plaza-ice-shatter.gif` | `…/files/boulder_0.gif`, `…/files/boulder.gif` | `https://opengameart.org/content/shattering-boulder` |

  `…/files/` is `https://opengameart.org/sites/default/files/`.
- **CREDITS.md.** Append these exact lines:
  ```markdown
  ## Ice cracks (plaza-ice-cracks.png)
  - "Ice Mountains Tileset" (`ice_mountain_tileset.png`, unmodified) by CookieEfedu
  - License: CC-BY 4.0 (https://creativecommons.org/licenses/by/4.0/). This file is not under the app's MIT license.
  - Source: https://opengameart.org/content/ice-mountains-tileset
  - The app keeps only the crack pixels of six cells and recolours them at runtime (exact colour swaps, no new shapes); the result is a derivative and stays under CC-BY 4.0.

  ## Ice gloss (plaza-ice-gloss.png)
  - "Some 16x16 floor tiles" (`stuff_1.png`, unmodified) by ChikenwingJJA
  - License: CC0 (public domain)
  - Source: https://opengameart.org/content/some-16x16-floor-tiles
  - The app recolours one cell at runtime.

  ## Ice shards (plaza-ice-shatter.gif)
  - "Shattering Boulder" (`boulder.gif`, unmodified) by Spring Spring
  - License: CC0 (public domain)
  - Source: https://opengameart.org/content/shattering-boulder
  - The app recolours frames 2–4 at runtime.
  ```
- **TEAM.md "출처".** Add three lines:
  - 얼음 금 그림: CookieEfedu, "Ice Mountains Tileset" (CC-BY 4.0, 실행 중에 금 픽셀만 남기고 색을 바꿈)
  - 얼음 윤기 그림: ChikenwingJJA, "Some 16x16 floor tiles" (CC0)
  - 얼음 파편 그림: Spring Spring, "Shattering Boulder" (CC0)

- [ ] **Step 1: Write the failing tests.**
  - **`PlazaResourcesTests`:**
    - `testIceFilesAreTheUnmodifiedOriginals`: the three bundled files hash to the three sha256s.
    - `testIceFilesLoad`: the crack sheet is 256×256, the gloss sheet 84×67, and the gif has 4 frames of 32×32.
    - `testCreditsNameTheIceArtists`: the credits contain "Ice Mountains Tileset", "CookieEfedu", "CC-BY 4.0", `https://creativecommons.org/licenses/by/4.0/`, `https://opengameart.org/content/ice-mountains-tileset`, "crack pixels", "Some 16x16 floor tiles", "ChikenwingJJA", "Shattering Boulder" and "Spring Spring".
    - `testMissingBundleReturnsNilInsteadOfCrashing` adds: the two sheets are nil and the frames are [] for `in: nil`.
  - **`PlazaIceArtTests`:**
    - `testTheGlossCellKeepsItsThreeLightColours`: 16×16, with `#B5D3EF` 97, `#C0DBF3` 45, `#D0E5F8` 15 and clear 99.
    - `testCracksKeepOnlyTheCrackPixelsAndMirrorTheSecondSix`:
      - 12 images of 16×16.
      - Images 0…5 have [59, 59, 58, 48, 62, 47] opaque pixels, all `#6A97C6`.
      - Image 6+i pixel (x,y) equals image i pixel (15−x,y).
    - `testShardsAreFramesTwoToFourRecoloured`:
      - 3 images of 32×32 with 205, 97 and 12 opaque pixels.
      - Frame 0 has `#6A98C8` 99, `#8FB7DE` 58, `#D8EAF8` 39 and `#F4FAFF` 9.
      - Frame 2 is all `#6A98C8`.
    - `testOverlayRulesOnASyntheticMap`:
      - Map rows `["SN....", "......", "..ww..", "......"]`. Its 192×128 image is filled `#6DB955` except these world pixels:

        | World px | Tile | Colour |
        |---|---|---|
        | (70,70) | pond | `#5AAEE4` |
        | (71,70) | pond | `#328E41` |
        | (72,70) | pond | `#123456` |
        | (73,70) | pond | `#165C88` |
        | (40,40) | shore | `#5AAEE4` |
        | (41,40) | shore | `#1E7CB8` |
        | (42,40) | shore | `#165C88` |
        | (43,40) | shore | `#328E41` |
        | (44,40) | shore | `#123456` |

      - The overlay is 128×96. Overlay pixels: (38,38), (39,38) and (40,38) are `#ADCDEC`; (41,38) is `#94B9DF`.
      - (8,8) is `#C8DEF4`, (9,8) `#ADCDEC` and (10,8) `#94B9DF`; (11,8) and (12,8) are clear.
      - (70,40) is `#ADCDEC` (grass in the pond) and (0,0) is clear.
    - `testTheOverlaysMatchTheApprovedMock`:
      - The snow map is built exactly as `PlazaWindowController.snowLook(for:)` builds it.
      - Each pond uses `PlazaIceArt.load().gloss`. Expected sizes and colour counts (they reproduce the approved mock's `ice.png` for R pixel for pixel):

        | Pond | Size | `#ADCDEC` | `#B5D3EF` | `#94B9DF` | `#C0DBF3` | `#C8DEF4` | `#D0E5F8` | Clear |
        |---|---|---|---|---|---|---|---|---|
        | R | 288×288 | 51797 | 2038 | 1040 | 900 | 420 | 297 | 26452 |
        | L | 384×160 | 33180 | 1213 | 1460 | 531 | 408 | 172 | 24476 |
        | B | 160×160 | 11012 | 223 | 480 | 89 | 212 | 28 | 13556 |

      - If these counts don't match, stop and report. The snow map may differ from the mock's base; never tune the numbers to pass.
    - `testGlossPatchesAreFixedPerPond`: the table equals the §4.1 values for (32,14) and the decided values for (5,13) and (20,24).
    - `testWithoutTheFilesThePiecesAreEmptyAndTheOverlayStillBuilds`:
      - `load(bundle: nil)` gives nil, [] and [].
      - `overlay(..., gloss: nil)` for R has no gloss colours, and `#ADCDEC` is 51797 + 3235.
- [ ] **Step 2:** Run `swift test --filter 'PlazaIceArtTests|PlazaResourcesTests'`. Expected: build failure.
- [ ] **Step 3:** Fetch and verify the three files, implement, and write CREDITS.md and TEAM.md as above.
- [ ] **Step 4:** Run `swift test --filter 'PlazaIceArtTests|PlazaResourcesTests|PlazaSnowSheetTests'`. Expected: all pass.
- [ ] **Step 5:** Commit: `feat(team): add the recoloured plaza ice art`. Name the three sources and the sha256 check in the body.

---

### Task 4: Ice rules in the scene (water now, landings, the break, sinking)

**Files:**
- Modify: `PlazaScene.swift`, `PlazaWalker.swift`, `PlazaPathfinder.swift`
- Test: `Tests/PokeTokenBarTests/PlazaIceSceneTests.swift` (new). Extend `PlazaWalkerTests.swift`, `PlazaPathfinderTests.swift` and `TeamHostilePeerTests.swift`.

**Interfaces:**
- Consumes: Task 1 (all), Task 3 `PlazaIceArt` (only as the init flag).
- Produces:
  ```swift
  // PlazaWalker
  mutating func plunge(_ d: PlazaDirection, duration: TimeInterval? = nil)   // the plunge step lasts `duration` when given
  // PlazaPathfinder
  static func path(from: TilePoint, toNextTo: TilePoint, map: PlazaMap, blocked: Set<TilePoint> = [],
                   isWalkable: ((TilePoint) -> Bool)? = nil) -> [PlazaDirection]?   // nil: map.isWalkable
  // PlazaScene
  init(map:, mapImage:, start:, zoom:, nickname:, tallGrass: PlazaTallGrassArt? = nil, pondVisuals: Bool = false,
       iceArt: PlazaIceArt? = nil)          // nil: the ponds never freeze
  static let maxIceLandings = 8
  func isIce(_ t: TilePoint) -> Bool          // the frozen pond, or a breaking pond before sinkAt
  func isWaterNow(_ t: TilePoint) -> Bool     // map.isWater(t) && !isIce(t)
  func isWalkableNow(_ t: TilePoint) -> Bool  // map.isWalkable(t) || isIce(t)
  var frozenPondAnchor: TilePoint? { get }    // the frozen pond (never the breaking one)
  var isMeOnIce: Bool { get }                 // walker.tile is in the frozen pond
  private(set) var iceBreak: PlazaIceBreak?
  func setIceBreak(_ b: PlazaIceBreak?, hit: TilePoint? = nil)
  func queueIceLanding(_ b: PlazaIceBreak, jumper: String?)   // nil jumper = me
  func isIceLandingQueued(_ b: PlazaIceBreak) -> Bool
  var onIceLanding: ((PlazaIceBreak, TilePoint) -> Void)?     // the break and its hit tile
  var onIceChange: (() -> Void)?                              // the solid ice changed (freeze, sink)
  func leapOntoIce(_ d: PlazaDirection)
  var breakingPondAnchor: TilePoint? { get }; var breakingHit: TilePoint? { get }; var iceLandingCount: Int { get }   // test
  ```
- **State.**
  - `icePonds` and a `[TilePoint: Int]` pond index, both built once at init (empty without `iceArt`).
  - `iceTurn`, `frozenIndex: Int?`.
  - `breaking: (pond: Int, hit: TilePoint, elapsed: TimeInterval)?`.
  - `landings: [(break: PlazaIceBreak, jumper: String?, remaining: TimeInterval)]`.
- **`refreshIce(hit:)`**, called from `setIceBreak` and from `advanceIce` when the turn changes. Keep this order:
  1. `iceTurn = turn(now())` and `target = frozenIndex(last: iceBreak, turn: iceTurn, ponds:)`. Return if `target == frozenIndex`.
  2. `old = frozenIndex`, then `frozenIndex = target`.
  3. If `old != nil`:
     - When the scene is unpaused, `updateCount > 0` and `iceBreak?.pond == icePonds[old].anchor`: start a break. First finish any running break. Then set `breaking = (old, hit.map(nearestTile) ?? center, 0)`.
     - Otherwise sink `old` at once.
  4. Call `onIceChange`.
- **`advanceIce(by:)`** runs first in `update`, right after `clock = currentTime`, so the walker sees this frame's ice:
  1. Count down the landings and land those at or below 0.
  2. Advance `breaking`. When it crosses `sinkAt`, sink and call `onIceChange`. At `breakEnd`, clear it.
  3. Compare `turn(now())` with `iceTurn`.
- **Land.**
  - The hit is the jumper's shown tile: `walker.tile` for nil, `remotes[id]?.motion.tile` otherwise. It is clamped by the break's pond `nearestTile`, or is the `center` when unknown.
  - Then call `onIceLanding?(b, hit)`.
  - `queueIceLanding` lands at once when paused or when `landings.count == maxIceLandings`.
- **Pausing.** `isPaused`'s `didSet`, when pausing, calls a private `finishIceNow()`:
  - Land a copy of `landings`, then empty it.
  - If `breaking` is set and short of `sinkAt`, sink.
  - Clear `breaking`.
- **Sink(pond).**
  - Unless paused: for me and every remote whose tile is in the pond, `splash(at: tile, big: true, stage: <its stage>, splasher: id)`.
  - When paused: `climbOutNowIfPaused()`.
- **`leapOntoIce(d)`.** `stopDance(nil)`, then `walker.plunge(d, duration: PlazaPond.plungeStepDuration)`, then `plungeJumpOwed = PlazaWalker.offset(walker.tile, d)`.
- **`plunge(_:)`.** Sets `plungeJumpOwed` to the same target tile. `update` plays the jump when `walker.currentStep?.to == plungeJumpOwed`, then clears it. This replaces the land-to-water test at line 1663.
- **§5.1 call sites** (line numbers at 2d6b790). "Now" means `isWaterNow`/`isWalkableNow`:

  | Where | Change |
  |---|---|
  | `watchPond` closure (988) → `PondWatch.advance` (280–298) | Now |
  | `applyMembers` surfacing splash (589) | Now |
  | `isMeInWater` (895), `memberIsInWater` (897) | Now |
  | `pondAction` (912) | Now, plus `isIce: { frozen pond contains $0 }` (not the breaking pond) |
  | `splash` wet targets (937), `isShownDiving` (943) | Now |
  | `swimSink` (998), `waterRect` (1007–1012) | Now |
  | `canEnterTile` (1025), `canPushTile` (1031), `pondStepDuration` (1036) | Now |
  | `advanceWalkToMember` (1055, 1065–1067, 1075) | Now, and the pathfinder gets `isWalkable: isWalkableNow` |
  | `playSnowball` landing burst and splash (1277, 1286) | Now |
  | `playDance` (1360), `advancePendingDances` (1377), `stopMovingDancers` (1404) | Now |
  | `puffDust` (1430), `pushMe` fall (1469) | Now |
  | `climbOutNowIfPaused` (1492–1493), `update` egg ashore (1653–1654) | Now |
  | `resolvedTile` (698), `PlazaSnow.footprints`, `PlazaSnowball.aim/blocksBall`, `PlazaDitto*`, `PlazaItems`, `PlazaTileArt`, `PlazaPreferences.lastTile` | keep static |

- [ ] **Step 1: Write the failing tests.**
  - **`PlazaWalkerTests.testAPlungeCanTakeAGivenLength`:**
    - `plunge(.right, duration: 0.36)` with `stepDuration` returning 0.15.
    - After `advance(0.3)` it is still walking; after another 0.07 it is at the target and stopped.
  - **`PlazaPathfinderTests.testPathUsesTheGivenWalkability`:**
    - On the real map from (4,14) to beside (16,14), with `isWalkable: { map.isWalkable($0) || L.contains($0) }`, the path is 11 × `.right`.
    - Without it, the first step is not `.right`.
  - **`PlazaIceSceneTests`** setup:
    - Real map, `PlazaTileArt.plainGrassImage`, `pondVisuals: true`, `iceArt: .none`.
    - `now` fixed at `T·180 + 60` with `T = 9_960_000`.
    - 32×48 red frames, members and `run` copied from `PlazaPondSceneTests`.
    - "Controller stand-in": `s.onIceLanding = { [unowned s] in s.setIceBreak($0, hit: $1) }`.
    - `breakL(hit:)` means one `update`, then `setIceBreak((L,T), hit:)`.
    - Tests:
    - `testWithoutIceArtNothingFreezes`: a scene without `iceArt` has `frozenPondAnchor == nil` and `isWaterNow((6,14)) == true`.
    - `testAFreshSceneFreezesTheFirstPond`:
      - `frozenPondAnchor == (5,13)`.
      - `isIce((6,14))` and `isWalkableNow((6,14))` are true; `isWaterNow((6,14))` is false.
      - `isWaterNow((34,17))` is true.
    - `testTheLastBreakDecidesTheFrozenPond`:
      - `setIceBreak((L,T))` → nil.
      - Clock +180, then `update` → (32,14).
      - `setIceBreak((B,T))` → (5,13) at once.
    - `testArrowKeysWalkOntoTheIceAndAcrossIt`:
      - From (4,14), a right tap reaches (5,14) at 0.16 s: a land step, not a 0.36 s plunge. A second tap reaches (6,14).
      - `isMeInWater` is false and `myVisibleHeight == 72`.
    - `testZOnTheIceBreaksItAndEveryoneOnItSinksAt600ms`:
      - Me at (6,13). Member a at (8,14). Member c at (6,12) on the shore.
      - `pondAction(canMove: true) == .breakIce`. Then `playJump(nil)` and `queueIceLanding((L,T), jumper: nil)`.
      - At 0.35 s: `iceLandingCount == 1`, not breaking.
      - At 0.40 s: `breakingPondAnchor == (5,13)`, `breakingHit == (6,13)`, `frozenPondAnchor == nil`. `pondAction(canMove: true) == .jump` (breaking ice).
      - At 0.90 s (all times from the press): `isMeInWater` false.
      - At 1.02 s: me and a in water, `pondLayer!.dropletCount == 2 · PlazaPondLayer.bigDroplets`, and `isWet(memberID: "c") == true`.
    - `testStepsDuringTheBreakDecideWhoSinks` (Review Focus 4):
      - Break from (9,14), with me at (9,14), a at (5,14) and d at (15,14).
      - At +0.1 s, a moves to (4,14) and d to (14,14).
      - At +0.7 s: a is not in water; d and I are.
    - `testLeapingFromTheShoreTakesAPlungeLongAndLandsOnTheIce`:
      - Me at (4,14) facing right: `.leapOntoIce(.right)`, then `leapOntoIce(.right)`.
      - At 0.30 s: walking, `jumpLift(nil) > 0`.
      - At 0.40 s: (5,14), not walking, not in water.
    - `testFacingTakenIceOrBeingAnEggIsAPlainJump`:
      - With member m at (5,14), me at (4,14) facing right: `.jump`.
      - Without m and `canMove: false`: `.jump`.
      - On (6,14) with `canMove: false`: `.jump`.
    - `testABreakOfAnotherPondTurnsMyIceToWaterAtOnce`:
      - Me on (6,14). After one `update`, `setIceBreak((R,T))`.
      - `breakingPondAnchor == nil`, `isMeInWater` is true at once, and `onIceChange` fired.
    - `testAPresenceOnlyBreakRunsFromTheCentre`: `breakL(hit: nil)` gives `breakingHit == (9,14)`.
    - `testOpeningAppliesTheStateWithoutABreak`: `setIceBreak((L,T))` before any `update` gives no breaking and water at once.
    - `testPausingMidBreakSinksAtOnceAndLeavesNoBreak` (Review Focus 1):
      - Me on (6,14), `breakL(hit: (6,14))`, 0.2 s of frames, then `isPaused = true`.
      - `isMeInWater`, `breakingPondAnchor == nil` and the droplet count unchanged.
    - `testPausingFlushesQueuedLandings`:
      - Two `queueIceLanding` calls, then `isPaused = true`: `onIceLanding` ran twice and `iceLandingCount == 0`.
      - One more call while paused lands at once.
    - `testALandingFloodIsCappedAndAPausedFloodMakesNoNodes`:
      - 20 landings leave `iceLandingCount == 8` with 12 landed at once.
      - Paused: 50 landings and 50 `setIceBreak` changes keep `children.count` unchanged.
    - `testATurnPassedWhilePausedFreezesAtOnce` (Review Focus 2):
      - `setIceBreak((L,T))`, pause, clock +600, unpause, one `update`.
      - `frozenPondAnchor == (32,14)` and `isWalkableNow((34,17))`.
    - `testFreezingUnderASwimmerAndADiverStandsThemOnTheIce` (Review Focus 4):
      - `setIceBreak((L,T))`. Me at (34,17) with `setDiving(true)`, member s at (35,17) diving.
      - Clock +180, then `update`: `isMeInWater` false, `isDiving` false, `onDivingChange` saw `[false]`.
      - `memberIsDiving("s") == false`, and after 0.1 s `memberVisibleHeight("s") == 72`.
    - `testAnEggOnBreakingIceClimbsOut` (Review Focus 4): `canWalk = false` on (6,14), `breakL(hit: (6,14))`, 2 s of frames → `map.isWater(walker.tile) == false`.
    - `testAPushSlidesAcrossTheIce`: from (4,14), `pushMe(.right, tiles: 3)` and 1 s → (7,14), not in water.
    - `testWalkingToAMemberCrossesTheIce`: member m at (16,14), me at (4,14). After `walk(toMember: "m")` and 0.16 s, I'm at (5,14).
    - `testASnowballThatLandsOnTheIceBurstsLikeGround`: shot `(from (6,11), .down, .ground((6,14)))` → after landing `pondLayer!.dropletCount == 0` and `snowballSpriteCount >= 5`.
    - `testTheIceTakesNoFootprints`: `refreshSnowDay()`, then two right taps from (4,14) → `footprintCount == 0`. One up tap from (4,14) → 2.
  - **`TeamHostilePeerTests.testEffectsAddNothingWhileTheSceneIsPaused`** also builds an `iceArt: .none` scene. Paused, it gets 50 `queueIceLanding((L,T), jumper: "A")` calls, and `children.count` is unchanged.
- [ ] **Step 2:** Run `swift test --filter 'PlazaIceSceneTests|PlazaWalkerTests|PlazaPathfinderTests'`. Expected: build failure.
- [ ] **Step 3:** Implement as above.
- [ ] **Step 4:** Run `swift test --filter 'PlazaIceSceneTests|PlazaWalkerTests|PlazaPathfinderTests|PlazaPondSceneTests|PlazaPondMotionTests|PlazaTackleWaterTests|PlazaTackleReachTests|PlazaSnowballSceneTests|PlazaFootprintTests|PlazaSwimLowerHalfTests|PlazaCollisionTests|PlazaDittoSceneTests|PlazaDanceTests|TeamHostilePeerTests'`. Expected: all pass. Without `iceArt` nothing in those classes changes.
- [ ] **Step 5:** Commit: `feat(team): walk on and break the frozen plaza ponds`.

---

### Task 5: Drawing the ice (`PlazaIceLayer`, photo)

**Files:**
- Create: `Sources/PokeTokenBar/Team/Plaza/PlazaIceLayer.swift`
- Modify: `PlazaScene.swift`, `PlazaPhotoRenderer.swift`
- Test: `Tests/PokeTokenBarTests/PlazaIceLayerTests.swift` (new), `PlazaPhotoTests.swift` (extend)

**Interfaces:**
- Consumes: Task 1 timeline functions, Task 3 `PlazaIceArt`, Task 4 scene state.
- Produces:
  ```swift
  @MainActor final class PlazaIceLayer: SKNode {
      static let iceZ: CGFloat = 0.02, crackZ: CGFloat = 0.025, shardZ: CGFloat = 0.045
      init(ponds: [PlazaIce.Pond], art: PlazaIceArt, mapImage: CGImage, worldHeight: CGFloat)
      func setMapImage(_ image: CGImage)        // rebuilds every pond's ice texture (PlazaIceArt.overlay)
      /// Ice over `frozen` at `alpha`; the breaking pond's ice, cracks (ring <= elapsed / crackStep, at iceAlpha(elapsed),
      /// hidden at 0) and shard bursts (64×64 centred on shardTiles[k]); everything else hidden.
      func show(frozen: Int?, alpha: CGFloat, breaking: (pond: Int, hit: TilePoint, elapsed: TimeInterval)?)
      func setConcealed(_ hidden: Bool)
      /// Shown ice and cracks with their alpha (world px, top-left origin); no shards; [] while concealed.
      func photoParticles() -> [PlazaPhotoParticle]
      var nodeCount: Int { get }; var shownCrackCount: Int { get }; var shownShardCount: Int { get }   // test
      func iceAlpha(pond: Int) -> CGFloat?; func iceTextureID(pond: Int) -> ObjectIdentifier?           // test
  }
  // PlazaPhotoParticle
  var alpha: CGFloat = 1
  // PlazaPhotoInput, declared after `items`
  var ice: [PlazaPhotoParticle] = []   // drawn right after the map, each with its alpha
  // PlazaScene (test)
  private(set) var iceDrawCount: Int   // calls to the layer's `show`
  var shownCrackCount: Int { get }; var shownShardCount: Int { get }; var iceLayerNodeCount: Int { get }
  func iceAlpha(pondAnchor: TilePoint) -> CGFloat?
  ```
- **Layer nodes.**
  - One ice sprite per pond: texture from `overlay`, `.nearest`, placed by its top-left.
  - A crack pool that grows to at most the largest pond's tile count. Each crack is 32×32 at its tile, with texture `cracks[crackCell(at:)]`.
  - Six shard sprites.
  - Nothing is created per frame or per break beyond those caps. With `art.cracks` or `art.shards` empty, those sprites are never made.
- **Scene wiring.**
  - The scene makes the layer when `iceArt != nil`.
  - It calls `drawIce()` after every `refreshIce`, sink and `finishIceNow`, and every frame while breaking or while `freezeAlpha < 1`. `drawIce()` is `show(frozen: frozenIndex, alpha: PlazaIce.freezeAlpha(now: now(), last: iceBreak), breaking: breaking)`.
  - Idle frames don't call it.
  - `refreshSnowDay` passes the new image to `setMapImage`.
  - `setBackgroundHidden` calls `setConcealed`.
  - `photoInput()` passes `ice: iceLayer?.photoParticles() ?? []`.

- [ ] **Step 1: Write the failing tests.**
  - **`PlazaIceLayerTests`.** Layer tests use the snow map and `PlazaIceArt.load()`; scene tests use the Task 4 setup with `iceArt: .load()`. In a scene, "break R at h" means `setIceBreak((L,T−1))` (R frozen), one `update`, then `setIceBreak((R,T), hit: h)`. Timeline checkpoints avoid exact frame edges (0.055·k, 0.26 + 0.04·k).
    - `testOnlyTheFrozenPondShowsIce`: `show(frozen: 1, alpha: 1, breaking: nil)` gives `iceAlpha(pond: 1) == 1`, and nil for 0 and 2.
    - `testTheBreakDrawsTheTimeline`. On R, hit (32,17), at these elapsed times:

      | Elapsed | Cracks | Shards | Ice alpha (pond 1) |
      |---|---|---|---|
      | 0.03 | 1 | 0 | |
      | 0.06 | 6 | 0 | |
      | 0.12 | 15 | 0 | |
      | 0.335 | 49 | 2 | |
      | 0.45 | 49 | 5 | |
      | 0.50 | | 5 | |
      | 0.575 | | | 0.5 |
      | 0.66 | 0 | 1 | nil |
      | 0.70 | 0 | 0 | |

    - `testAFreezeFadesInByTheClock`:
      - Scene with `setIceBreak((L,T))`, then clock = `(T+1)·180 + 0.25` and one `update` → `iceAlpha(pondAnchor: (32,14)) == 0.25` (accuracy 1e-6).
      - Clock +1 s → 1.
    - `testAFreezeLongAgoShowsAtFullOpacity` (Review Focus 2): the clock already 10 minutes past the boundary on the first frame → 1.
    - `testAnIdleFrozenPondDoesNoWorkPerFrame`: after the first frame, 60 idle updates leave `iceDrawCount`, `iceLayerNodeCount` and the R texture ID unchanged.
    - `testBreaksReuseTheirNodes`: ten breaks of R in a row on the layer leave `nodeCount <= 3 + 49 + 6`.
    - `testWithoutArtTheIceStillShowsAndBreaks`: with `PlazaIceArt.none`, `iceAlpha(pond: 0) == 1`, and at 0.45 cracks and shards are both 0.
    - `testAHiddenBackgroundHidesTheIceButNotTheRules`: after `setBackgroundHidden(true)`, `photoInput()!.ice` is empty and `isWalkableNow((6,14))` is still true.
    - `testANewMapPictureRebuildsTheIce`: the texture ID changes across `refreshSnowDay()` with a `snowLook` whose map image is new.
    - `testTheSceneDrivesTheBreakByFrames`: the scene breaks R at (33,17) with 0.32 s of 0.01-s frames → `shownCrackCount == 49` and `shownShardCount == 2`.
    - `testThePhotoShowsTheIceAndFadingCracksButNoShards`:
      - Frozen L → one ice particle with alpha 1.
      - Breaking R at 0.55 s → the R ice particle and 49 crack particles, each with alpha `iceAlpha(0.55)`, and no 64×64 particle.
  - **`PlazaPhotoTests.testIceIsDrawnOverTheMapWithItsAlpha`:**
    - A 4×4 black map, `pixelsPerWorld: 1`, and one white 2×2 ice particle at (1,1) with alpha 0.5.
    - Pixel (1,1) is mid-grey (128 ± 2) and pixel (0,0) is black.
- [ ] **Step 2:** Run `swift test --filter 'PlazaIceLayerTests|PlazaPhotoTests'`. Expected: build failure.
- [ ] **Step 3:** Implement as above.
- [ ] **Step 4:** Run `swift test --filter 'PlazaIceLayerTests|PlazaPhotoTests|PlazaIceSceneTests|PlazaSnowSceneTests|PlazaPhotoModeSceneTests'`. Expected: all pass.
- [ ] **Step 5:** Commit: `feat(team): draw the plaza ice, cracks and shards`.

---

### Task 6: Breaking together (controller, runtime, hint, docs)

**Files:**
- Modify:
  - `PlazaWindowController.swift`, `PlazaPreferences.swift`
  - `Sources/PokeTokenBar/Team/TeamRuntime.swift`, `TeamLocalization.swift`
  - `TEAM.md`
- Test: `Tests/PokeTokenBarTests/PlazaIceControllerTests.swift` (new). Extend `TeamRuntimeTests.swift` and `PlazaSnowballControllerTests.swift` (harness only).

**Interfaces:**
- Consumes: Tasks 1–5. In particular `PlazaIce.accepted/merged/turn`, `TeamSession.updateIceBreak`, `sendEmote(iceBreak:)`, and the scene's `setIceBreak`, `queueIceLanding`, `isIceLandingQueued`, `onIceLanding`, `onIceChange`, `leapOntoIce`, `frozenPondAnchor`, `isMeOnIce` and `isWaterNow`.
- Produces:
  ```swift
  // PlazaPreferences
  var iceBreak: PlazaIceBreak? { get set }        // key "team.plaza.iceBreak", JSON; nil removes
  // PlazaWindowController
  private(set) var iceBreak: PlazaIceBreak?
  func showJump(memberID: String, iceBreak: PlazaIceBreak? = nil)   // the runtime calls it
  private static let icePonds: [PlazaIce.Pond]    // PlazaIce.ponds(in: PlazaMapData.map)
  private static var cachedIceArt: PlazaIceArt?   // PlazaIceArt.load(), once per process
  // TeamLocalization
  var plazaIceHint: String { "얼음 위예요 · Z로 얼음 깨기" }
  ```
- Behaviour:
  - **`learnIceBreak(_ b:, hit: TilePoint? = nil)`** (private):
    - `b = accepted(b, turn: turn(clock()), ponds:)`, then `merged = merged(iceBreak, b, ...)`. Return if unchanged.
    - Store it, save it to the preferences, `session?.updateIceBreak(merged)`, and `scene?.setIceBreak(merged, hit: hit)`.
  - **init:** after the item slots, `iceBreak = accepted(preferences.iceBreak, turn: <now>, ponds:)`, then `session?.updateIceBreak(iceBreak)`.
  - **`prepareScene`:**
    - Pass `iceArt: Self.iceArt()`.
    - Right after `s.now = clock`, learn every `session?.members` value's `iceBreak`, then `s.setIceBreak(iceBreak)`.
    - Set `s.onIceLanding = { learnIceBreak($0, hit: $1) }` and `s.onIceChange = { refreshHint() }`.
  - **Z (`handleJumpKey`):** `.breakIce` and `.leapOntoIce(d)`:
    - `guard let pond = scene.frozenPondAnchor` (always set for these two cases), then `b = PlazaIceBreak(pond: pond, turn: turn(now))`.
    - `stopDance`, then `leapOntoIce(d)` or `playJump(nil)`.
    - `session?.sendEmote(.jump, target: nil, iceBreak: b)`, then `scene.queueIceLanding(b, jumper: nil)`.
    - Other cases are unchanged.
  - **`showJump(memberID:iceBreak:)`:**
    - The existing jump and startle first.
    - Then the accepted break: `scene.queueIceLanding(b, jumper: memberID)`, or `learnIceBreak(b)` when there is no scene.
  - **`applyMembersToScene`:** after `learnTaken`, `learnIceBreak(b)` for each member `iceBreak` that is not `scene.isIceLandingQueued(b)`.
  - **Pull-under:** `pullTargets` and `showPull` pass `{ scene.isWaterNow($0) }`.
  - **Hint:** the existing fallback line becomes `text = startleHint()?.text ?? (scene?.isMeOnIce == true && scene?.canWalk == true && !isFocusing ? L(.ko).plazaIceHint : nil)`, so member, startle and campfire hints win, and an egg or a focusing member sees no ice hint (spec §5.4).
  - **`handleClose`:**
    - Set `scene.onIceChange = nil` before `scene.isPaused = true`, so pausing lands a pending break of mine and learns it.
    - Set `scene.onIceLanding = nil` with the other nils after it.
  - **`TeamRuntime`:** `.jump` calls `plaza?.showJump(memberID: memberID, iceBreak: emote.iceBreak)`.
  - **TEAM.md**, in Korean and the table's tone:
    - **연못 row.**
      - The three ponds freeze in turn every 3 minutes (left, right, bottom), one at a time, and stay until broken. The next freezes at the next 3-minute boundary.
      - You walk on frozen ice with the arrow keys. A push slides you across it.
      - Z on the ice, or Z from the shore facing free ice, cracks and shatters it when you land. Everyone on it falls in.
      - For 0.6 s it is still solid, so stepping off in time stays dry. An egg or a focusing member only jumps.
      - Someone in the pond when it freezes stands on the ice, and a dive ends.
      - No footprints on ice. A snowball bursts on ice like ground. The Ditto stays off. The minimap stays water-coloured.
      - The last break is remembered across restarts.
    - **Z row:** on the ice, Z breaks it (see 연못). Standing on ice shows "얼음 위예요 · Z로 얼음 깨기" in the hint line.
    - **P row:** Z also breaks ice in photo mode.
    - **The mixed-version list.** One bullet for `<latest tag>` 이하, covering the four §6 points:
      - They see no ice: a new-version walker on ice looks like a swimmer, and stepping onto the ice from the shore splashes.
      - A breaking jump is a plain jump there.
      - They can't walk onto the ice; a plunge looks like standing on the ice here.
      - They don't pass breaks on.
    - `<latest tag>` is `git tag --list 'v2.5.*' --sort=-v:refname | head -1` at the time (now v2.5.629).

- [ ] **Step 1: Write the failing tests.**
  - **`PlazaIceControllerTests`.** Copy the harness from `PlazaSnowballControllerTests` (`node`, `controller` with `clock: { [unowned self] in now }`, `settle`, `run`, `press`).
    - The clock is `now = Date(timeIntervalSince1970: T·180 + 60)`.
    - Fresh preferences, so L is frozen.
    - `lastTile(validIn:)` refuses pond tiles, so start on (4,14) and tap right (keyCode 124) to step onto the ice.
    - Tests:
    - `testZOnTheIceSendsABreakingJumpAndBreaksWhenItLands`:
      - Me on (5,14), then Z (keyCode 6). b receives `.jump` with `iceBreak == (L,T)`.
      - At 0.3 s of frames: `c.iceBreak == nil`, the preference is nil, and b's `members[me].iceBreak` is nil.
      - At 0.4 s: `c.iceBreak == (L,T)`, the preference is saved, and (after `settle`) b's member has it.
      - At 1.1 s: `scene.isMeInWater`.
    - `testZFromTheShoreLeapsOntoTheIceAndBreaksIt`: me at (4,14) facing right, then Z. b gets the breaking jump; at 0.4 s `walker.tile == (5,14)`; at 1.1 s I'm in water.
    - `testAnEggOnTheIceSendsAPlainJump`:
      - `speciesID: nil`. Reach (5,14) with `scene.pushMe(.right)`, then Z.
      - b's jump has a nil `iceBreak` and `scene.iceLandingCount == 0`.
    - `testAReceivedBreakingJumpBreaksFromTheJumpersTile`:
      - b's tile is (8,14), placed via `updatePlazaPosition`. Call `c.showJump(memberID: b.id, iceBreak: (L,T))`.
      - At 0.3 s not breaking; at 0.4 s `breakingHit == (8,14)` and `c.iceBreak == (L,T)`.
    - `testAJumperOffThePondHitsTheNearestPondTile`: b at (3,14) → `breakingHit == (5,14)`.
    - `testAPresenceOnlyBreakRunsFromTheCentre`: `b.session.updateIceBreak((L,T))`, then `settle` → `breakingHit == (9,14)`.
    - `testPresenceBeforeTheLandingWaitsForTheJump` (Review Focus 3):
      - `showJump(b, (L,T))`, then at once `b.session.updateIceBreak((L,T))` and `settle`.
      - Not breaking yet. At 0.4 s `breakingHit == (8,14)`.
    - `testAMismatchedBreakTurnsMyIceToWaterAtOnce`: b's presence `(R,T)` → L is water at once, not breaking, `frozenPondAnchor == nil`.
    - `testARestartKeepsTheLastBreak`:
      - The preference is `(L,T−1)`. Opening gives `frozenPondAnchor == (32,14)`, not breaking.
      - b sees `(L,T−1)` in my presence.
      - Also `testThePreferenceRoundTrips`: nil, a value, then nil again.
    - `testFutureForeignAndImpossibleBreaksAreDropped` (Review Focus 5):
      - `showJump` with `(L,T+2)`, `((6,13),T)` and `(L,Int.max)` leaves `iceLandingCount == 0` and `c.iceBreak == nil`. So does a presence with `(L,T+2)`.
      - `(L,T+1)` is queued.
    - `testAFloodOfBreakingJumpsStaysUnderTheCap` (Review Focus 5): 200 `showJump(b, (L,T))` calls give `iceLandingCount <= PlazaScene.maxIceLandings`. After 1.5 s, `iceLayerNodeCount <= 3 + 49 + 6`.
    - `testABreakWhileCoveredIsWaterWhenUncovered` (Review Focus 1):
      - Me on (5,14), `setRendering(visible: false)`. Note `children.count`, then `showJump(b, (L,T))`.
      - `c.iceBreak == (L,T)`, `isMeInWater` and `children.count` unchanged.
      - `setRendering(visible: true)` and one `update`: still water, not breaking.
    - `testClosingBeforeTheLandingStillLearnsMyBreak`: Z on the ice, then at once `handleClose()` → the preference is `(L,T)`.
    - `testTheIceHintShowsOnTheIceUnlessAnotherHintWins`:
      - On (5,14): `c.hint == L(.ko).plazaIceHint`.
      - With b on (6,14), facing it: the member hint.
      - After the break sinks me: not the ice hint.
      - With `scene.canWalk = false` (an egg) on (5,14): not the ice hint.
  - **`TeamRuntimeTests.testABreakingJumpReachesThePlaza`.** Use the snowball test's setup.
    - Peer a sends `.jump` with `iceBreak (L, turn(clock))`.
    - After landing frames, `plaza.iceBreak` equals it.
  - **`PlazaSnowballControllerTests`:** its `controller` helper sets `prefs.iceBreak = PlazaIceBreak(pond: TilePoint(x: 5, y: 13), turn: PlazaIce.turn(at: now))`, so no pond is frozen. The class swims in the left pond. Don't change any assertion.
- [ ] **Step 2:** Run `swift test --filter 'PlazaIceControllerTests|TeamRuntimeTests'`. Expected: build failure.
- [ ] **Step 3:** Implement as above.
- [ ] **Step 4: Run every controller class.**
  - Run `swift test --filter 'PlazaIceControllerTests|TeamRuntimeTests|PlazaSnowballControllerTests|PlazaWindowTests|PlazaPullUnderTests|PlazaEmoteTests|PlazaCardTests|PlazaChatTests|PlazaBoardTests|PlazaFocusTests|PlazaControllerLifetimeTests|PlazaItemsTests|PlazaMembersTests|PlazaDittoControllerTests|PlazaPhotoModeTests|PlazaFireworksTests|PlazaPhotoTests|PlazaGroupPhotoTests|PlazaMimicControllerTests|PlazaScheduleWiringTests|PlazaStartleControllerTests|PlazaSnowSceneTests|TeamLocalizationTests'`. Expected: all pass.
  - If a test fails only because the left pond is now frozen, give its harness the same no-ice preference as `PlazaSnowballControllerTests`. Name it in the commit body and never weaken an assertion.
- [ ] **Step 5:** Commit: `feat(team): freeze the plaza ponds in turn and break them together`.

---

### Task 7: Branch check (fault injection and coverage)

- [ ] **Step 1: Fault injection.** Put each fault in by hand, run the owning focused filter, see it fail, then revert it. Record the results for the PR body.
  1. `accepted` drops the turn bound → `testAcceptedDropsFutureTurnsAndUnknownPonds`, `testFutureForeignAndImpossibleBreaksAreDropped`.
  2. `merged` compares the turn only → `testMergeKeepsTheLaterTurnThenTheLaterPond`.
  3. `isWaterNow` returns `map.isWater` → `testArrowKeysWalkOntoTheIceAndAcrossIt`.
  4. Sinking at the landing instead of `sinkAt` → `testZOnTheIceBreaksItAndEveryoneOnItSinksAt600ms`, `testStepsDuringTheBreakDecideWhoSinks`.
  5. `isPaused`'s `didSet` skips `finishIceNow` → `testPausingMidBreakSinksAtOnceAndLeavesNoBreak`, `testABreakWhileCoveredIsWaterWhenUncovered`.
  6. `refreshIce` animates a break of another pond → `testABreakOfAnotherPondTurnsMyIceToWaterAtOnce`.
  7. The presence path ignores `isIceLandingQueued` → `testPresenceBeforeTheLandingWaitsForTheJump`.
  8. The controller learns my break at the press → `testZOnTheIceSendsABreakingJumpAndBreaksWhenItLands`.
  9. No landing cap → `testALandingFloodIsCappedAndAPausedFloodMakesNoNodes`, `testAFloodOfBreakingJumpsStaysUnderTheCap`.
  10. `drawIce()` every frame → `testAnIdleFrozenPondDoesNoWorkPerFrame`.
  11. The overlay's inside rule maps `#165C88` to fill → `testTheOverlaysMatchTheApprovedMock`.
  12. `freezeAlpha` ignores the clock (fade by frames) → `testAFreezeLongAgoShowsAtFullOpacity`.
  13. `TeamEmote.iceBreak` without `@LossyOptional` → `testUnreadableIceBreakDropsOnlyTheBreak`.
  14. `handleClose` nils `onIceLanding` before pausing → `testClosingBeforeTheLandingStillLearnsMyBreak`.
- [ ] **Step 2: Coverage.**
  - Run `swift test --enable-code-coverage --filter 'PlazaIce'`.
  - Find the profile and binary the way `scripts/test-gate.sh` does.
  - Run `llvm-cov show <bin> -instr-profile=<profdata> <file> --show-regions` for the three new files and the new parts of `PlazaScene.swift` and `PlazaWindowController.swift`.
  - Every `^0` in a new branch either gets a test or a one-line reason in the PR body.
- [ ] **Step 3:** If tests were added, run their filter and commit: `test(team): cover the frozen pond branches`.

---

### Task 8: PR images (temporary offscreen render, deleted afterwards)

- [ ] **Step 1: Write the render test.** Write `Tests/PokeTokenBarTests/ZZFrozenPondRender.swift`. Never commit it.
  - Skip unless `PTB_ZZ_DIR` is set.
  - Render through `SKRenderer` into a Metal texture: no windows and no `show()` (memory "offscreen-plaza-render").
  - **Sample data only:**
    - Me is 지아 (Eevee, 133) and the teammate is 민수 (Pikachu, 25).
    - Sprites come from `~/Library/Application Support/PokeTokenBar/sprites`, or coloured blocks when it is missing.
    - Zoom 2, a 960×640 view, and `backingOverride = 1`.
  - **The scene:**
    - The snow map is built like `PlazaWindowController.snowLook(for:)`. Use `pondVisuals: true` and `iceArt: PlazaIceArt.load()`.
    - The clock is fixed at `T·180 + 60`.
    - The controller stand-in from Task 4 drives the landings.
  - `SKAction`s don't run offscreen: remove the nodes named `"jump-dust"` before each frame. Label every image "Sample-data render".
- [ ] **Step 2: Render.** Run `PTB_ZZ_DIR=/private/tmp/claude-501/-Users-simu-Documents-GitHub-PokeTokenBar/565430de-c0b7-4604-80e8-d6f04edc0447/scratchpad/frozenpond-pr swift test --filter ZZFrozenPondRender`, after the `pgrep` check. It writes:
  1. Each pond frozen, with the camera on it, 지아 on the shore and 민수 on the ice:
     - `frozen-left.png`: break nil.
     - `frozen-right.png`: break `(L,T−1)`.
     - `frozen-bottom.png`: break `(R,T−1)`.
  2. The right pond's break, with 지아 on (33,17) and 민수 on (35,16), both on the ice.
     - Freeze R with the break `(L,T−1)`.
     - 지아 jumps (`playJump(nil)`), and the scene gets `queueIceLanding((R,T), jumper: nil)`.
     - Frames:
     - `break-1-frozen.png`: mid-jump, 0.2 s after the press.
     - `break-2-cracks.png`: landing + 0.15 s.
     - `break-3-shards.png`: landing + 0.40 s.
     - `break-4-swimming.png`: landing + 1.2 s.
  3. `break.gif`: from 0.4 s before the press to 1.5 s after the landing, at 30 fps.
- [ ] **Step 3: Clean up.**
  - Delete `ZZFrozenPondRender.swift`.
  - `git status --short` shows no test file.
  - List the PNG and GIF paths for the PR step. Uploading them and preparing the PR (merge `origin/main`, the `prepare-pr` skill) are outside this plan.

---

## Self-review

- **Spec coverage:**

  | Spec | Where it's covered |
  |---|---|
  | §1 intent, §2 goals and anti-goals | Tasks 4–6. Separate looks: Task 3 mock counts. Divergent ice: Tasks 1 and 6. Only the jumper sinking: Task 4. Heavy plaza: Task 5 idle test. State tied to animation: Tasks 4–6 pause tests. |
  | §3 ponds, turn, last break, merge, save, map change | Task 1 (rules), Task 6 (save, accept on load) |
  | §4.1 ice and gloss | Task 3 (art), Task 5 (drawing) |
  | §4.2 cracks, §4.3 shards, §4.4 timeline | Task 1 (numbers), Task 5 (drawing), Task 4 (600 ms rule) |
  | §4.5 freeze fade, no melting, mismatch, someone in the pond | Tasks 1, 4 and 5 |
  | §4.6 licences and files | Task 3 |
  | §5.1 walking and water table | Task 4 (call-site table and tests) |
  | §5.2 Z, §5.3 falling in | Tasks 1, 4 and 6 |
  | §5.4 hint | Task 6 |
  | §6 wire, receiving, presence, ordering, older versions | Tasks 2 and 6, TEAM.md in Task 6 |
  | §7 drawing, layers, hidden background, photo | Task 5 |
  | §9 success | Task 8 images |
  | §10 tests the spec asks for | Tasks 1–6 (tables, timeline, state, merge order, clock ahead, propagation and save, 600 ms sink, field left out) |

- **Type consistency:** these names are shared across tasks, and each is defined once in an Interfaces block:
  - `PlazaIceBreak(pond:turn:)`, `PlazaIce.Pond`, `PlazaIce.frozenIndex/accepted/merged/freezeAlpha`
  - `PlazaIceArt.load/overlay/none`, `PlazaIceLayer.show(frozen:alpha:breaking:)`
  - `PlazaScene.setIceBreak(_:hit:)/queueIceLanding(_:jumper:)/isIceLandingQueued/onIceLanding/onIceChange/isWaterNow/isWalkableNow/isIce/frozenPondAnchor/isMeOnIce/leapOntoIce/maxIceLandings`
  - `TeamSession.updateIceBreak`, `sendEmote(iceBreak:)`, `PlazaWindowController.showJump(memberID:iceBreak:)`, `L.plazaIceHint`
- **Proportion:** code appears only for interfaces, the overlay algorithm (the tests' pixel counts depend on its exact ellipse and rules), and the CREDITS.md text.
