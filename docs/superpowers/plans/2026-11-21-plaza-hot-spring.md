# Plaza Hot Spring (PR 4) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The right plaza pond (x32–38, y14–20) is a hot spring all year. Its water is a milky jade, stones from the plaza tile sheet sit in and around it, it has no lily pads, and steam rises from it. Swimming, diving, splashes, wetness, 물귀신 and being pushed in work as in any pond. It never freezes, so the left and bottom ponds now take turns freezing. A teammate who stays in it for three minutes turns red on every up-to-date screen and fades back over a minute after leaving. Nothing else on the map moves, and no walkable tile changes.

**Architecture:**
- **One water rule, one exception list.** A new tile `'h'` (`PlazaTile.hotSpring`) is water: `PlazaMap.isWater` is true for `.pond` and `.hotSpring`, so every rule that already asks `isWater` treats the spring as a pond. Only two things ask "pond only": which ponds freeze (`PlazaIce.ponds`) and where lily pads go. `PlazaMap.isHotSpring` is new and drives the art, the steam and the flush. The Sweep table lists every site.
- **Pure rules** go in `PlazaHotSpring.swift`, a new SpriteKit-free file like `PlazaPond` and `PlazaDrag`:
  - `enum PlazaHotSpring`: every tunable of PR 4, the props table, the spring sheet and the photo tint;
  - `struct PlazaSoak`: my soak clock;
  - `struct PlazaFlushFade`: one actor's red level as a function of the wall clock;
  - `enum PlazaSteam` and `struct PlazaSteamField`: the steam's tunables and its node-free motion.
- **The water colour is baked into the map image.** `PlazaTileArt.mapImage` draws the spring tiles, their eight-neighbour ring (the shore) and the props from a spring copy of the season's sheet. The copy is the season sheet with the water colours swapped exactly in the water cell, the shore cells and the foam-rock cells (ruling 2). Every season, the minimap and the photo then show the spring with no extra code. The props are drawn only when the map really has the spring. On a map without `'h'` the builder draws exactly what it draws today.
- **Steam is one layer with a fixed pool.** `PlazaSteamLayer` makes its eight sprites when the scene is built and never makes another. Time passes only through `update(dt)`, and only while the spring (plus one tile) is in view and the background is shown. Its root sits under the weather and over the characters, so the daylight multiply tints it. Its wisps join the photo's weather particles at their current alpha.
- **The flush is decided by the sender and drawn from the wall clock.**
  - The controller keeps `PlazaSoak` and arms **one** deadline (`soakSleep`, injected like the other sleeps) when I enter the spring. It does not poll, and it does not use the 1 s `focusTick`.
  - `isFlushed` travels in the same presence as my tile: `updatePlazaPosition(…, isFlushed:)`. Leaving the spring, leaving the plaza and closing the window all send a presence without it. The deadline sends `updateFlushed(true)`.
  - Every screen draws a member red only when the flag is on **and** that member's presence tile is a spring tile. The level comes from `PlazaFlushFade.level(at: now())`, never from counted frames, so a paused scene is right on its first frame back.
- **Ice keeps its rules.** `PlazaIce.ponds` keeps only `.pond` tiles, so the list is [left, bottom]. A stored or received break at (32,14) is no longer an anchor: `accepted` drops it, as the spec asks, with no new code.
- **Wire:** one new presence field, `isFlushed: Bool?` (`@LossyOptional`), sent only when true. There is no new emote and no new key.

**Tech Stack:** Swift 6, the shared plaza node tree (SpriteKit on the Mac, Direct2D on Windows), XCTest, `FakeTransportHub` loopback sessions, `PlazaHeadlessShell` controllers (no window), the offscreen `SKRenderer` harness, PIL for scratch contact sheets.

**Spec:** `docs/superpowers/specs/2026-11-21-plaza-seasons-and-interactions-design.md` (Korean). It is binding. This plan implements section 8, with R2, R6 and R7, the shared rules in 3, the network row in 10, the per-PR duties in 11–12 and the constants in 13. Read R2 and R7 first. The flush timings are **[위임]**. The colours, the blend, the steam cap and the props are **[설계자 판단·미확인]**. The user sees all of them at the Task 10 render.

## Conflicts with the spec

Each ruling below changes what gets built.

1. **The foam-rock cells.** Spec 8.2 lists "(11,9)–(14,10), (12,7)–(13,7)". On the sheet, (13,7) is the door of a hut (cells (13,5)–(14,7)). The foam-ringed rock pair is (11,7)–(12,8). In (11,9)–(14,9), most cells are pieces of bigger rocks that cross cell edges and would be cut off.
   - **Ruling:** the water props are the self-contained foam rocks (12,10), (14,10) and the 2×2 pair (11,7)–(12,8). The Props table below has them, and the user approves them at Task 10.
2. **The recolour order.** Spec 8.2 says to draw the props, then swap the water colours on the finished map image.
   - Every foam-rock cell carries a shadow of `#201729` at alpha 0x66. `Canvas.plot` blends it into the water underneath, which gives `#1F537E` over `#1E7CB8`. That colour is in no exact table, so a last pass would leave blue shadows on jade water.
   - **Ruling:** swap the colours in the sheet cells the spring uses (`PlazaHotSpring.sheet`), then draw the spring tiles, the ring and the props from that sheet.
   - Every opaque pixel ends up exactly as the spec's order would make it. The shadows blend over jade.
   - The spec's purpose holds: the props' own water rings turn jade too.
   - `testNoBlueShadowIsLeftInTheSpring` fails if the swap is moved to the end (Task 3 injection).
3. **A fourth colour pair.** The spec's table has three pairs. The code-drawn pond effects (`PlazaPondArt.droplet`, `ring`, `swimRing`; `bubble` has none) also use `#2996DB`. The spring region of the map has none, because there are no lily pads.
   - **Ruling:** add `#2996DB → #74C0B6`, the midpoint of the spec's `#4FA8A0` and `#9AD8CC`. With it, the spring's swim ring, droplets and rings (spec "[구현자 재량]", taken) are all jade.
   - This is the plan's own value. It is flagged at Task 10.
4. **Grass on the bank stones by season.** The lead asked for "no summer green on the props in any season". Spec 8.2 adds the stone cells to the season tables, and spec 5.3 keeps spring's ground summer-green.
   - **Ruling:** the stone tufts follow the ground. Autumn and winter swap them with the ground's own pairs. Spring and summer keep them green, as their ground is.
   - `testTheWholeAutumnMapHasNoSummerGreen` (existing) and a new winter twin pin it.
5. **Winter's stone pairs live in `PlazaSeasonSheet.tilePieces(.winter)`, not in `PlazaSnowSheet.tilePieces`.** `PlazaArtParityPixelArtTests` pins `PlazaSnowSheet.tiles` byte for byte against the legacy port. The winter season sheet now differs from it only in the two stone cells. The parity test checks exactly that (Task 3).
6. **The render set.** Spec 8.7 names a `hot-spring` scene (day and night) and says the `ice-*` scenes are re-shot.
   - Every committed tree changes. The ice layer has one node per freezable pond (`PlazaIceLayer.swift:34-41`), so it loses one. The steam layer adds nine (a root and eight sprites). Both happen in every scene.
   - Pixels change only where the view reaches the spring's art. Measured from the committed reference cameras, that is `board-marker@10/@40`, and nowhere else. `ice-*` look at the left pond, so their pixels do not change.
   - **Ruling:** add seven scenes, eight captures:
     - `hot-spring` (summer noon, zoom 2, frames 10 and 60) and `hot-spring-night` (23:00, zoom 2, frame 10), the close-ups the spec asks for;
     - `hot-spring-summer`, `-spring`, `-autumn` and `-winter` (zoom 1, frame 10; winter also takes a photo), for the four-season approval and to pin the stone recolours on both systems.
7. **The steam's seed.** Spec 8.3 says the randomness is per Mac.
   - **Ruling:** use a fixed seed, `fnv1a("plaza-steam")`, as the weather does. The cross renders then reproduce on both systems.
   - Macs still drift apart: each one advances the field only while the spring is on its own screen.
   - The field is prewarmed by one life (3 s), so steam is up at frame 10 and when the spring first scrolls into view.
8. **Where the hostile cases live** (as PR 3's ruling 1). `TeamHostilePeerTests` feeds a bare `TeamSession`.
   - The `"yes"`/`1` values go there: they become `member.isFlushed == false`, and the frame lives.
   - The flood that adds no node goes there too, next to the paused-scene node check.
   - The "flag on, tile off the spring" claim needs a scene. It goes in `PlazaHotSpringControllerTests` under `// MARK: - Hostile peers`.
9. **The TEAM.md old-version number** is "v2.5.635 이하". v2.5.635 is the latest release; 2.5.636 is only a bump on `main`. Re-check it at release, with PRs 1–3's lines.

Found and **not** changed. List these in the PR:
- `lilyPairTiles` has (16,11), which is not water on today's map. The pair cells (4,0)/(5,0) were never drawn there. After PR 4, no two-cell pad is drawn anywhere.
- The photo's submerged tint (`PlazaPhotoRenderer.submerged`) mixes the body towards the water colour with a `sourceAtop` fill. The screen multiplies it. PR 4 only passes the spring colour through.
- A plaza Ditto copy of a teammate who is still fading is not red. The Ditto never enters water, and the tell lasts at most 60 s.
- A plaza opened while someone was already fading shows them unflushed. It never saw the fade start.
- The legacy test ports (`Tests/.../Legacy/LegacyPlazaTileArt.swift`, `LegacyPlazaIceArt.swift`) keep the old pond look and the old gloss entry. They are frozen copies, compared only on the pre-spring map (Task 3).

## Global Constraints

**Workspace**
- Work only in `.worktrees/plaza-hot-spring` on `feat/plaza-hot-spring`. Never touch the main checkout or a sibling worktree.
- The branch is stacked: on `feat/plaza-pull` (PR 3), on `feat/plaza-body-size` (PR 2), on `feat/plaza-season-art` (PR 1). None is merged. When they land, merge `origin/main` into this branch. Do not rebase.
- Never use a bare `git stash`.
- Pass `--repo likelion-campus/PokeTokenBar` to every `gh` command.

**Machine**
- One `swift build`/`swift test` at a time. `pgrep -x swift-build; pgrep -x swift-test; pgrep -x xctest` must print nothing first.
- Run filtered suites only (`swift test --filter …`).
- Never open a window, activate the app or steal focus. Never set `PTB_LIVE_WINDOW_TESTS=1`.
- Renders are offscreen only: `SKRenderer` into a Metal texture. The scripts need the GPU, not a window or focus.
- Render scratch directories live outside the repo (`$S` = `<your session scratchpad>/plaza-hot-spring`).

**Shared code**
- Everything changed under `Sources/PokeTokenBar/Team/` is shared with Windows: no Apple-only import, no `#if os`.
- New tests go into existing shared files, except the `+Mac` files already listed in `Tests/PokeTokenBarTests/mac-only.txt`.
  - The new files `PlazaHotSpringTests.swift`, `PlazaSteamLayerTests.swift` and `PlazaHotSpringControllerTests.swift` are shared.
  - `PlazaPondSweepTests+Mac.swift` (Task 1) reads the source tree with `SharedSources`, so it is Mac-only. List it in `mac-only.txt` under a comment, as `ToolLaunchArgumentScanTests` is.
- A test method on the main actor is `async` (`SharedSourcesScanTests`).

**Art (spec 3.2)**
- Only artist-made open-licence files. No code-drawn or generated stand-ins. The props are cells of `plaza-tiles.png` (ArMM1998, CC0, already credited).
- Files go in exactly as downloaded. At runtime, only crops and exact colour swaps are allowed.
- Integer scale, nearest sampling.

**Wire (spec 3.3)**
- `TeamWire.protocolVersion` stays 1. There is one new presence field, `isFlushed: Bool?` (`@LossyOptional`), left out unless true. There is no new emote kind.
- The receiver reads only a literal `true`, and draws it only on a hot-spring presence tile. `TeamWireTests` pins the key. The hostile tests send what an honest app never sends.

**Expected red tests**
- `PlazaCrossRenderCompareMacTests/testCommittedReferenceTreesAreCurrent` fails from Task 1 (new stems) until Task 11 rewrites the reference.
- Every other filtered suite named in a task must pass at that task's commit.

**Defect protocol**
- PR 4 is a feature, not a defect fix.
- Each new guard gets one injection run that must fail (named in its task).
- One `--show-regions` pass covers the new branches (Task 7, Step 7).

**Language**
- Commits are English Conventional Commits. Each ends with the line `Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>`.
- `TEAM.md` text is Korean in its current tone.
- New code comments follow the surrounding file. These plaza files comment in Korean; `TeamWire`/`TeamSession` doc comments are English.

## Pinned values

```swift
// PlazaMap.swift
case hotSpring = "h"                     // PlazaTile: not walkable (the "지나갈 수 없음" list), water
func isWater(_ p: TilePoint) -> Bool     // .pond or .hotSpring; off the map false
func isHotSpring(_ p: TilePoint) -> Bool // .hotSpring only; off the map false
// PlazaMapData.rows: rows 14...20, columns 32...38, "wwwwwww" -> "hhhhhhh". No other character changes.

// PlazaHotSpring.swift: every tunable of PR 4 (spec 13) is in this one file
enum PlazaHotSpring {
    static let flushAfter: TimeInterval = 180            // 조정용 상수 (명세 13, 위임)
    static let flushFade: TimeInterval = 60              // 조정용 상수 (명세 13, 위임)
    static let flushRise: TimeInterval = 2               // 명세 8.4 구현자 재량
    static let flushBlend: CGFloat = 0.45                // 조정용 상수 (명세 13, 설계자 판단·미확인)
    static let flushColor = PlazaColor(hex: 0xE0503C)    // 조정용 상수 (명세 13, 설계자 판단·미확인)
    static let waterColors: PlazaSnowSheet.Colors = [    // 명세 8.2 세 쌍 + ruling 3
        0x1E7CB8: 0x4FA8A0, 0x165C88: 0x2F7C78, 0x5AAEE4: 0x9AD8CC, 0x2996DB: 0x74C0B6]
    static let waterColor = PlazaColor(hex: 0x4FA8A0)    // the submerged part's tint in the spring (PlazaPondArt.waterColor's twin)
    struct Prop: Equatable { let col: Int, row: Int, cols: Int, rows: Int; let at: TilePoint; let inWater: Bool }
    static let props: [Prop]                              // the Props table, in that order
    static let waterPropCells: [(col: Int, row: Int)]     // (12,10), (14,10), (11,7), (12,7), (11,8), (12,8)
    static let bankStoneCells: [(col: Int, row: Int)] = [(7, 5), (10, 5)]
    static let autumnStoneColors: PlazaSnowSheet.Colors = [0x2ECA35: 0x8E9A44, 0x328E41: 0x6E7634]   // the ground's olive pair
    static let winterStoneColors: PlazaSnowSheet.Colors = [0x2ECA35: 0xE8F0FA, 0x328E41: 0xB2C7E0]   // bush and ground snow
    static func tiles(in map: PlazaMap) -> [TilePoint]                    // row-major; [] on a map with no 'h'
    static func usesSpringWater(_ p: TilePoint, in map: PlazaMap) -> Bool // a spring tile or one of its 8 neighbours
    static func props(in map: PlazaMap) -> [Prop]   // all six when every inWater tile is .hotSpring and every bank tile is walkable; else []
    static func artBounds(in map: PlazaMap) -> (minX: Int, minY: Int, maxX: Int, maxY: Int)?   // ring ∪ props: (31,13)...(40,21)
    static func sheet(_ seasonSheet: PlazaImage) -> PlazaImage   // recolored(seasonSheet, [(waterColors, [waterCell] + shoreCells + waterPropCells)])
    static func recolored(_ art: PlazaImage) -> PlazaImage        // waterColors on every pixel (droplet, ring, bubble, swim ring)
    static func tinted(_ image: PlazaImage, blend f: CGFloat) -> PlazaImage   // photo only: premultiplied rgb × (1 − f + f·c),
                                                                              // WinPlazaRenderer.swift:165's formula
}

struct PlazaSoak: Equatable {
    private(set) var since: Date?
    mutating func update(inSpring: Bool, now: Date) -> Bool   // true when `since` changed: entered (now), left (nil),
                                                              // or a clock that went back (since > now) restarted it at now
    var deadline: Date? { get }                               // since + flushAfter
    func isFlushed(now: Date) -> Bool                         // since != nil && now − since >= flushAfter: 179.9 s no, 180 s yes
}

struct PlazaFlushFade: Equatable {
    init(on: Bool, now: Date)                   // a first sight: level 1 or 0 at once (late joiner, spec 8.4)
    private(set) var on: Bool
    mutating func set(_ on: Bool, now: Date)    // no-op when unchanged; else from = level(at: now), since = now
    func level(at now: Date) -> CGFloat         // t = now − since; on: min(1, from + t / flushRise), off: max(0, from − t / flushFade);
                                                // t < 0 (a clock that went back) holds `from`
    func blend(at now: Date) -> CGFloat         // level × flushBlend
}

enum PlazaSteam {
    static let maxWisps = 8                       // 조정용 상수 (명세 13, 설계자 판단·미확인)
    static let life: TimeInterval = 3             // 명세 8.3
    static let rise: CGFloat = 24                 // world px over the life (명세 8.3)
    static let peakAlpha: CGFloat = 0.6           // 명세 8.3
    static let peakAt: TimeInterval = 0.75        // 구현자 재량: alpha 0 → 0.6 by here, then → 0 at `life`
    static let spawnInterval: TimeInterval = 0.5  // life / spawnInterval = 6 up at a time ("보통 여섯 개쯤")
    static let frameCount = 6                     // smoke_5.png's first six 32×32 cells; frame = min(5, ⌊age / life × 6⌋), 0.5 s each
    static let scale: CGFloat = 2                 // world px a sheet pixel (3.2's tile density): a cell draws 64×64
    static let z: CGFloat = 2.9                   // over characters (1...2) and droplets (2.5), under weather (3) and daylight (5)
    static let cullMargin = CGFloat(PlazaMap.tileSize)   // 명세 8.3 "여유 한 칸"
}
struct PlazaSteamWisp: Equatable { let x: CGFloat, y: CGFloat; var age: TimeInterval }   // spawn point, world px, y down
struct PlazaSteamField {
    init(tiles: [TilePoint], seed: UInt64 = UInt64(PlazaNameColor.fnv1a("plaza-steam")))   // then advances `life` in 0.05 s steps
    private(set) var wisps: [PlazaSteamWisp]
    mutating func advance(by dt: TimeInterval)   // ages, drops age >= life, spawns one per spawnInterval while count < maxWisps
    static func frame(age: TimeInterval) -> Int
    static func alpha(age: TimeInterval) -> CGFloat
    static func lift(age: TimeInterval) -> CGFloat   // rise × age / life
}

// PlazaResources
static let steamSheetName = "plaza-steam"   // png, 224×32, "Smoke Puff" smoke_5.png byte for byte
                                            // (sha256 246e0f333142c5d388dab36d50caf19fe508e8274ad4ecf7c7b96c0b92b0b8f8)
static let steamFrames: [PlazaPixelRect]    // (0..<6).map { PlazaPixelRect(x: 32 * $0, y: 0, width: 32, height: 32) }

// Wire and session
//   TeamPresence: @LossyOptional var isFlushed: Bool?       true only; left out when false
//   TeamMember:   var isFlushed = false                      presence.isFlushed == true
//   TeamSession:  func updateFlushed(_ on: Bool)             sends on a change only
//                 func updatePlazaPosition(inPlaza:tile:facing:isWalking:isRunning:isFlushed: Bool = false)
//                     the flag rides in the presence that moves me; `changed` includes it
//   PlazaSceneMember: var isFlushed = false
```

Sheet measurements, from PIL on `plaza-tiles.png`:
- The water cell (3,7) is solid `#1E7CB8`.
- The shore cells add `#165C88`, `#5AAEE4` and white foam.
- The foam rocks carry `#1E7CB8`, `#5AAEE4`, white and the 0x66-alpha `#201729` shadow. They have no green.
- The boulder (37,5)–(38,6) has no green.
- The bank stones (7,5) and (10,5) carry `#2ECA35` and `#328E41`.

Steam sheet, from PIL on `smoke_5.png`: one colour, `#F5F5F5`, all opaque. The opaque counts per cell are 327, 321, 215, 80, 18, 4, 0. The seventh cell is empty, so six frames lose nothing.

**Props (first proposal; the user approves the tiles at Task 10):**

| # | Sheet cells | Size | Tiles | What |
|---|---|---|---|---|
| P1 | (12,10) | 1×1 | (32,16) | flat rock, foam ring, west edge water |
| P2 | (14,10) | 1×1 | (36,14) | two pebbles, foam, north edge water |
| P3 | (11,7)–(12,8) | 2×2 | (37,19)–(38,20) | rock pair, foam, south-east corner water |
| P4 | (37,5)–(38,6) | 2×2 | (39,16)–(40,17) | grey boulder on the east bank |
| P5 | (7,5) | 1×1 | (31,21) | stone with grass tufts, south-west corner |
| P6 | (10,5) | 1×1 | (39,13) | pebbles with grass tufts, north-east corner |

- Every bank tile is open ground (`'.'`) today. No prop changes walkability.
- The north-west corner stays bare. It faces the plaza centre, and `zoom-1@40/@90` and `items@*` see to within 16 px of it. Leaving it bare keeps those captures byte-identical.

**Season stone tables:** autumn `autumnStoneColors`, winter `winterStoneColors`, both on `bankStoneCells`. Spring and summer have none (ruling 4).

## Sweep (R7)

**A. Every site that decides by tile kind.** Found with `grep -rnE '\.pond\b|PlazaTile\b|isWater\(|isWalkable\(|tile\(at' Sources/PokeTokenBar/Team Sources/PokeTokenBar/Platform`.

| Site | Decides | Hot spring | Guard |
|---|---|---|---|
| `PlazaTile.isWalkable` (`PlazaMap.swift:16-21`, exhaustive switch) | walking, pathing, items, last tile | water: not walkable | the compiler (no `default`); equivalence test |
| `PlazaMap.isWater` (`:101`) | everything in the rows below marked "via isWater" | water | equivalence test; the existing right-pond suites |
| `PlazaSnow.isSnowGround` (`PlazaSnow.swift:17-20`, exhaustive) | snow ground for footprints | water: not snow ground | the compiler; equivalence test |
| `PlazaSnow.footprints` (`:26`, via isWater) | no prints into or out of water | water | equivalence test |
| `PlazaSnowball.blocksBall` (`PlazaSnowball.swift:35-37`) | balls fly over water | water | equivalence test |
| `PlazaDitto.isGround` (`PlazaDitto.swift:15`) | the Ditto stays on land | water | equivalence test |
| `PlazaDittoBrain` prank, `wet` (`PlazaDittoBrain.swift:251`, via isWater) | a copy prefers shoving someone into water | water | same predicate as above |
| `PlazaItems.openTiles` (`PlazaItems.swift:64`, via isWalkable) | an item on water is hidden | water | `PlazaPondMapTests.testItemsOnThePondAreHidden` (its water set includes `'h'`) |
| `PlazaPreferences.lastTile` (`PlazaPreferences.swift:111`) | the start tile is never water | water | equivalence test (isWalkable) |
| `PlazaPathfinder.path` (`PlazaPathfinder.swift:19`) | routes around water | water | equivalence test; the path test |
| `PlazaScene`: `resolvedTile` `:755`, `isMeInWater`/`memberIsInWater` `:968-970`, `isWaterNow`/`isWalkableNow` `:1038-1039`, `splash`/`watchPond`/`swimSink`/`waterRect` `:1173-1255`, `canEnterTile`/`canPushTile` `:1262-1272`, `stepAshore` `:1757`, `:1928` | swim, dive, splash, wetness, an egg climbing out, remote placement, push-in | water | the right-pond suites (Part B) |
| `PlazaPullUnder.target`/`drag` (controller `:1296`, `:1321`, via `isWaterNow`) | 물귀신 | water | `PlazaPullUnderTests` (right pond) |
| `PlazaDrag` (PR 3) via `isWalkableNow`, `isMeInWater`, `memberIsInWater` | no drag in water | water | PR 3's tests at the left pond; same predicates |
| `PlazaIce.ponds(in:)` (`PlazaIce.swift:87`, `:96`, via isWater) | which ponds freeze | **pond only**: `map.tile(at:) == .pond` | `PlazaIceTests.testTheHotSpringIsNotAPondThatFreezes` |
| `PlazaScene.icePondIndex` (`PlazaScene.swift:434-438`) | which tiles can be ice | pond only (built from `PlazaIce.ponds`) | `PlazaIceSceneTests.testTheHotSpringStaysWaterAllWinter` |
| `PlazaIceArt.glossPatches` (`PlazaIceArt.swift:11-14`) | gloss on R's ice | **entry removed** | `PlazaIceArtTests.testGlossPatchesAreFixedPerPond` (count 2) |
| `PlazaTileArt.mapImage` water cell (`PlazaTileArt.swift:52`) and shore (`:57`, both via isWater) | water and shore art | water, drawn from the spring sheet | Task 3 pixel tests |
| `PlazaTileArt.drawLilyPads` (`:86`, `:90`, via isWater) | lily pads | **pond only** | `PlazaTileArtTests+Bundled.testTheHotSpringHasNoLilyPads` |
| `PlazaPondLayer.splash`/`bubble` (`PlazaPondLayer.swift:60-87`) | droplet, ring and bubble colours | spring colours on a spring tile | `PlazaPondLayerTests.testEffectsInTheSpringAreJade` |
| `PlazaActor` ghost tint and swim ring (`PlazaActor.swift:104-105`, `:572`) | the submerged part's colour, the ring at the waterline | spring colours | `PlazaPondSceneTests.testASwimmerInTheSpringShowsSpringWater` |
| `PlazaPhotoRenderer.submerged` (`PlazaPhotoRenderer.swift:318-327`) | the photo's submerged tint | the actor's `waterColor` | `PlazaPhotoTests.testAPhotoOfTheSpringShowsSpringWaterAndTheFlush` |
| Minimap (`PlazaMinimapPanel.swift:77`) | small map | draws the map image: jade with no code | the map-image tests |
| Windows selftests (`Platform/Windows/WindowsSelftestPlaza*.swift`) | none touch the right pond (grep) | — | `plaza.renderCostSpring` added (Task 8) |

- **The equivalence test** is `PlazaHotSpringTests.testTheSpringAnswersLikeThePondItReplaced`.
  - It builds `old` = `PlazaMap(rows: PlazaMapData.rows` with every `'h'` turned back to `'w'`), the v2.5.635 map.
  - For every tile in x −1...48, y −1...32, it asserts the same answer from both maps for: `isWalkable`, `isWater`, `PlazaSnow.isSnowGround`, `PlazaSnowball.blocksBall`, `PlazaDitto.isGround` and `PlazaPond.shore(at:isWater:)`.
  - It asserts `PlazaSnow.footprints` for each step into and out of the spring.
  - It asserts the same `PlazaItems.openTiles`, `spawn`, `boardTile`, `shelterTiles` and `campfireTiles`.
  - It asserts `PlazaPathfinder.path(from: (31,13), toNextTo: (39,21), map:)` on both maps.
  - Only `isHotSpring`, `PlazaIce.ponds` and the lily pads may differ, and the test lists them.
- **The scan.** `PlazaPondSweepTests+Mac.testEveryDirectPondCheckIsClassified` greps `Sources/PokeTokenBar/Team/Plaza/**/*.swift` with `(^|[^A-Za-z0-9_)\]?!])\.pond\b`. That matches the tile literal, not the `PlazaIceBreak.pond` property.
  - It asserts the hits are exactly an allow-list of (file, trimmed line).
  - A new direct `.pond` check anywhere fails with "classify it as water (use isWater) or pond-only and list it here".
  - Task 1 writes the allow-list as today's three hits (checked with `grep -rnE '(^|[^A-Za-z0-9_)?!]|\])\.pond\b'`): `PlazaMap.swift:19`, `:101` and `PlazaSnow.swift:19`. Task 2 adds `PlazaIce.swift`'s check and Task 3 the lily pads'.

**B. Suites that already run at the right pond.** After Task 2 they prove the spring is water, unchanged:
- `PlazaPondSceneTests`: swim, dive and splash at (34,18) and others;
- `PlazaPullUnderTests` and `+Pond`: 물귀신 at x32–38;
- `PlazaTackleWaterTests`: pushes into, inside and out of the right pond;
- `PlazaSwimLowerHalfTests` and `+Pixels`: the submerged part;
- `PlazaWindowTests.pondPair` and `PlazaPhotoTests` (`:814`, `:827`);
- `PlazaDanceTests` (`:562-981`);
- `PlazaDittoBrainTests:708`.

Each of the first three gains one fixture test that asserts the tiles it uses are `isHotSpring`, so moving the spring cannot quietly turn them back into pond tests.

**C. Tests that pin three ponds, R or the right pond's pads.** Task 2 changes these, except the two marked Task 3. Rule: a test that needs R's 7×7 geometry or the three-pond draw uses `oldPonds = PlazaIce.ponds(in: old)`. A test that needs "another pond" on the real map uses B.
- `PlazaIceTests`:
  - `testPondsAreFoundInRowMajorOrderOfTheirFirstTile` → [L, B], counts [30, 9], with the three-pond list on `old`;
  - `testTheDrawIsPinnedToTheSeedString`, `testTheFrozenPondIsNeverTheBrokenOneAndEveryOtherPondGetsPicked`, `testTheDrawEdgeCases`, `testMergeKeepsTheLaterBreakThenTheLaterPond`, `testThreeBreaksInTheSameMinuteEndOnTheLastOne`, `testCentreAndNearestTile`, `testCrackRingsAndTheirStep`, `testShardTilesSpreadFromTheHit`, `testCrackCellsAreFixedPerTileAndUseAllSix` → `oldPonds`. Their pinned values are v2.5.635's behaviour, which the mixed-version table needs;
  - `testTheFrozenPondFollowsTheLastBreakAMinuteLater` → the real two-pond list: after L, B; after B, L; an R break counts as no break, so L.
- `PlazaIceControllerTests` (`:22`, `:259-279`), `PlazaIceSceneTests` (`:14`, `:242`, `:291`, `:350`), `PlazaIceLayerTests` (`:18`): R → B.
- `PlazaIceArtTests.testGlossPatchesAreFixedPerPond`: count 2, and the R line is removed.
- `PlazaIceArtTests+Bundled`:
  - `testTheOverlaysMatchTheApprovedMock` loses its R entry;
  - `testWithoutTheFilesThePiecesAreEmptyAndTheOverlayStillBuilds` uses L. Pin its `0xADCDEC` count from the first run.
- `PlazaArtParityPixelArtTests` (`:238-239`): count 2. In Task 3, its map comparisons (`:53-61`, `:85-86`) move to `old`.
- `PlazaPondMapTests`: `water` reads `'w'` or `'h'`; `testOnlyOpenGroundChanged` accepts both as water.
- Task 3: `PlazaTileArtTests+Bundled.testLilyPadsAreBakedInEachPond`: the pads are [(14,13), (21,25)], and the bare tile is (8,14).
- Stale comments that PR 4 makes false ("the next one is the far right pond"): `PlazaDittoControllerTests.swift:88`, `PlazaDragControllerTests.swift:72`, `PlazaActivityControllerTests.swift:81`, `PlazaSnowballControllerTests.swift:78` → "the next one is the bottom pond".

## Tints already on an actor

| On the actor today | Where | With the flush |
|---|---|---|
| Submerged part, water tint | `ghostNode.color`/`colorBlendFactor` (`PlazaActor.swift:104-105`) | A separate node. It keeps the water tint (jade in the spring). The flush goes on `characterNode` only |
| A sunk egg (body alpha 0) | `:344` | The flush is invisible while sunk. Nothing to do: an egg climbs out by itself (spec 8.4) |
| Tall-grass concealment, dive fade | `characterNode.alpha` | Alpha and colour blend are independent, and both apply |
| Wet 💧 | `wetNode`, camera space | Independent node |
| "Frozen" | No actor tint exists. Ice is a pond layer, and the spring never freezes | Nothing |
| Focus | No actor tint (a seat and a timer) | Someone still fading may sit down and keeps fading. Nothing to do |
| My Ditto disguise | frames swap on my actor (`myShownLook`) | The flush follows the actor, whatever it shows. My presence carries the flag |
| Plaza Ditto and its copies (scene key) | `applyDitto` | Never flush. They never enter water. Listed under "found" |
| Daylight multiply | `daylightNode`, z 5 in the camera | Multiplies the red at night like everything else |

## Review Focus

1. **One water rule.** Look for a tile decision outside the Sweep A table. The scan and the equivalence test must both fail when one is missed (Task 2 injections).
2. **The recolour order** (ruling 2). Look for the old shadow blend in the spring, and for any map pixel outside `artBounds` that changed.
3. **Steam cost.**
   - The pool is made at init and never grows.
   - Nothing moves or changes while paused, culled or hidden.
   - A culled layer writes no node property, so the Windows renderer stays clean (`plaza.idleVisible`).
4. **The flush.**
   - The clock is the wall clock. There is one deadline. The flag and the tile go in one presence.
   - The receiver needs the flag **and** a spring tile. A late joiner sees red at once. A resumed scene is right on its first frame.
5. **Ice.** The left and bottom ponds alternate. R breaks are rejected when stored and when received (merge only ever sees accepted breaks). The three-pond pinned draws stay as v2.5.635's.
6. **Hostile peers.** `"yes"`, `1` and `{}` for the flag. A flag on a land tile or for an away member. A flood of toggles adds no node.

---

### Task 1: Baselines (map pin, pond scan, render scenes)

**Files:**
- Modify:
  - `Tests/PokeTokenBarTests/PlazaPondMapTests.swift`
  - `Tests/PokeTokenBarTests/PlazaRenderScenes.swift`, after `pond(…)` (`:322`) and in `makeAll` (`:519-534`)
  - `Tests/PokeTokenBarTests/mac-only.txt`
- Create: `Tests/PokeTokenBarTests/PlazaPondSweepTests+Mac.swift`

- [ ] **Step 1: Pin today's map.** In `PlazaPondMapTests`:
  - add `static let v2_5_635RowsSHA256`, pinned from the first run. Today's rows are v2.5.635's: `git diff v2.5.635 -- Sources/PokeTokenBar/Team/Plaza/PlazaMapData.swift` prints nothing. Check that before pinning;
  - add `testTheMapIsV2_5_635sWithOnlyTheRightPondRenamed`: the SHA-256 of `PlazaMapData.rows.map { $0.replacingOccurrences(of: "h", with: "w") }.joined(separator: "\n")` equals the pin. It passes now and keeps passing after Task 2.
- [ ] **Step 2: The scan** (`PlazaPondSweepTests+Mac`, Sweep A). The allow-list is today's three hits.
  - Run `swift test --filter PlazaPondSweepTests`. Expected: PASS.
  - Injection: add `if map.tile(at: p) == .pond {}` to `PlazaTileArt.swift` and run the filter. Expected: FAIL. Revert.
  - Add `PlazaPondSweepTests+Mac.swift` to `mac-only.txt` with the comment `# PlazaPondSweepTests+Mac: scans the plaza sources with SharedSources (SharedSourcesScanTests.swift), which is Mac-only`.
- [ ] **Step 3: The render scenes** (ruling 6).
  - Add a builder `hotSpring(_ name: String, _ choice: PlazaSeasonChoice, hour: Int = 12, zoom: Int, captures: [Int], photo: Bool = false)`:
    - `o.me = (35,17)`. I swim in the middle, as `pond-swim` puts me in water;
    - `put([member("ash", "Ash", 33, 16, facing: .right), member("misty", "Misty", 37, 18, facing: .left), member("brock", "Brock", 35, 21, facing: .up)], looks: crowdLooks)`.
  - Add to `makeAll`, after `pond-egg`:
    - `hotSpring("hot-spring", .summer, zoom: 2, captures: [10, 60])`;
    - `hotSpring("hot-spring-night", .summer, hour: 23, zoom: 2, captures: [10])`;
    - `hotSpring("hot-spring-summer", .summer, zoom: 1, captures: [10])`, `-spring`, `-autumn`;
    - `hotSpring("hot-spring-winter", .winter, zoom: 1, captures: [10], photo: true)`.
  - Task 7 makes Ash flushed. Until then the scenes show the old pond. That is the "before" of Task 10.
- [ ] **Step 4: Run** `swift test --filter 'PlazaPondMapTests|PlazaPondSweepTests'`. Expected: PASS. The run compiles the whole test target, so it also checks the new scenes build. `PlazaCrossRenderCompareMacTests/testCommittedReferenceTreesAreCurrent` now fails with 8 stems "(not in the reference)". This is the expected red.
- [ ] **Step 5: Commit** `test(team): pin the plaza map and add hot-spring render scenes`.

### Task 2: The hot-spring tile and the water sweep

**Files:**
- Modify:
  - `Sources/PokeTokenBar/Team/Plaza/PlazaMap.swift:10-21`, `:100-101`: the case, its doc comment ("온천: 물이지만 얼지 않고 연잎이 없다"), `isWater` and `isHotSpring`.
  - `Sources/PokeTokenBar/Team/Plaza/PlazaMapData.swift:21-27` (rows 14–20): `wwwwwww` → `hhhhhhh` at x32–38. Update the doc comment's character list.
  - `Sources/PokeTokenBar/Team/Plaza/PlazaSnow.swift:19`: `.hotSpring` joins the `false` list.
  - `Sources/PokeTokenBar/Team/Plaza/PlazaIce.swift:80-103`: `ponds(in:)` groups `map.tile(at:) == .pond` tiles. Doc: "온천은 얼지 않아 목록에 없다".
  - `Sources/PokeTokenBar/Team/Plaza/PlazaIceArt.swift:11-14`: remove the (32,14) entry. The comment names only L and B.
- Create: `Sources/PokeTokenBar/Team/Plaza/PlazaHotSpring.swift`, with `tiles(in:)` only for now.
- Task 2 changes no pixel of any map image. The water cell, the shore and the lily pads still follow `isWater` until Task 3, so the pinned season looks and the map parity tests stay green here.
- Test:
  - Create `Tests/PokeTokenBarTests/PlazaHotSpringTests.swift`.
  - Modify:
    - `PlazaMapTests.swift`, `PlazaPondMapTests.swift`, `PlazaSnowTests.swift`;
    - `PlazaIceTests.swift`, `PlazaIceControllerTests.swift`, `PlazaIceSceneTests.swift`, `PlazaIceLayerTests.swift`, `PlazaIceArtTests.swift`, `PlazaIceArtTests+Bundled.swift`, `PlazaArtParityPixelArtTests.swift` (Sweep C);
    - `PlazaPondSceneTests.swift`, `PlazaPullUnderTests.swift`, `PlazaTackleWaterTests.swift` (the fixture tests);
    - `PlazaPondSweepTests+Mac.swift` (the allow-list gains `PlazaIce.swift`'s `.pond` check, and `PlazaMap.swift`'s lines change);
    - the four stale comments (Sweep C).

**Interfaces:**
- Produces: `PlazaTile.hotSpring`, `PlazaMap.isWater` (widened), `PlazaMap.isHotSpring`, `PlazaHotSpring.tiles(in:)`.
- `PlazaIce.ponds` reads `.pond` directly. It is the only new scan hit here; the lily pads add the second in Task 3.

- [ ] **Step 1: Write the failing tests.**
  - `PlazaHotSpringTests`:
    - `testTheRightPondIsTheHotSpring`:
      - `PlazaTile(rawValue: "h") == .hotSpring`, and `.hotSpring.isWalkable == false`;
      - `tiles(in: map)` is exactly x32...38 × y14...20 (49 tiles), and `isWater` and `isHotSpring` hold on each;
      - `isHotSpring` is false on (31,17), on the left pond (5,13), off the map (−1,0), and on every tile of a map without `'h'`.
    - `testTheSpringAnswersLikeThePondItReplaced` (the equivalence test, Sweep A).
  - `PlazaMapTests.testAMapWithAnHParses`: `PlazaMap(rows: ["SN..", "hh.."])` parses. The `'h'` tiles are water and not walkable.
  - `PlazaPondMapTests`:
    - `water` reads `'w' || 'h'`;
    - `testOnlyOpenGroundChanged` accepts either character;
    - Step 1 of Task 1 keeps passing.
  - `PlazaSnowTests.testTheHotSpringIsNoSnowGroundAndTakesNoPrints`:
    - `isSnowGround((34,17)) == false`;
    - `footprints(from: (31,17), to: (32,17))` and `from: (32,17), to: (31,17)` are `[]`.
  - `PlazaIceTests` (Sweep C rewrites):
    - `testTheHotSpringIsNotAPondThatFreezes`: `ponds(in: map).map(\.anchor) == [(5,13), (20,24)]`, and `oldPonds` has three.
    - `testAStoredOrReceivedBreakOfTheSpringIsUnknown`:
      - `accepted(br(R, T), now: T, ponds:)` is nil;
      - `frozenIndex(last: br(R, T), now: T + 600, ponds:) == 0` (left);
      - merge does not filter: `merged(br(L, T), br(R, T + 1), ponds:)` is the R break. Its callers pass only accepted breaks (`PlazaWindowController.swift:684-685`), so an R break never reaches it. `testAJumpThatBreaksTheSpringIsJustAJump` covers that caller.
    - `testTheLeftAndBottomPondsTakeTurns`: for `at` in T, T+7.31, …, 200 values: L → B and B → L.
    - **The mixed-version table (spec 8.6), as far as code can say it:**
      - `testMixedVersionsAgreeWithNoBreak`: new `frozenIndex(nil)` is L and old `frozenIndex(nil)` is L.
      - `testAfterALeftBreakNewFreezesTheBottomAndOldFreezesEitherOther`: over the 200 `at`s, new is always B. Old picks R some times and B other times; assert both occur (the table's "시드로 정해진다").
      - `testAfterABottomBreakNewFreezesTheLeftAndOldFreezesLeftOrRight`: the same for B.
      - `testOldVersionsAcceptTheBreaksNewVersionsSend`: `accepted(br(L|B, T), ponds: oldPonds) != nil`.
      - `testMergeOrdersLeftAndBottomTheSameInBothLists`: `merged(br(L, T), br(B, T))` is B under both lists.
  - `PlazaIceControllerTests`:
    - `testASavedBreakOfTheSpringFreezesTheLeftPond`: `prefs.iceBreak = br(R, now − 3600)`, winter, open. `c.iceBreak == nil` and `scene.frozenPondAnchor == L`.
    - `testAJumpThatBreaksTheSpringIsJustAJump`:
      - `c.showJump(memberID: b, iceBreak: br(R, now))`;
      - `c.iceBreak` and `prefs.iceBreak` are unchanged, and `scene.iceLandingCount == 0`;
      - the same through `b.session.updateIceBreak(br(R, now))`.
  - `PlazaIceSceneTests.testTheHotSpringStaysWaterAllWinter`:
    - winter, no break: `isIce((34,17)) == false` and `isWaterNow((34,17))`;
    - `setIceBreak(br(R))` is ignored: `iceBreak` is unchanged.
  - The fixture tests:
    - `PlazaPondSceneTests.testThisSuiteSwimsInTheHotSpring`;
    - `PlazaPullUnderTests.testThisSuitePullsFromTheHotSpring`;
    - `PlazaTackleWaterTests.testThisSuitePushesIntoTheHotSpring`.

    Each asserts `PlazaMapData.map.isHotSpring` on the water tiles its tests use.
- [ ] **Step 2: Run** `swift test --filter 'PlazaHotSpringTests|PlazaMapTests|PlazaPondMapTests'`. Expected: the build fails (`type 'PlazaTile' has no member 'hotSpring'`).
- [ ] **Step 3: Implement** the Interfaces. Apply the Sweep C edits.
- [ ] **Step 4: Run** `swift test --filter 'PlazaHotSpringTests|PlazaMapTests|PlazaPondMapTests|PlazaSnowTests|PlazaIce|PlazaArtParityPixelArtTests|PlazaTileArtTests|PlazaSeasonTests|PlazaPondSceneTests|PlazaPondTests|PlazaPullUnderTests|PlazaTackleWaterTests|PlazaSwimLowerHalfTests|PlazaDanceTests|PlazaDittoBrainTests|PlazaItemsTests|PlazaPathfinderTests|PlazaFootprintTests|PlazaSnowballTests|PlazaWindowTests|PlazaPondSweepTests|PlazaPhotoTests'`. Expected: PASS.
  - `PlazaIceArtTests+Bundled`'s L count is pinned from this run.
  - The Sweep B suites, `PlazaTileArtTests` and `PlazaSeasonTests` pass unchanged.
- [ ] **Step 5: Injection.** Run each change with Step 4's filter, then revert it:
  - `isWater` back to `.pond` only. Expected: `testTheSpringAnswersLikeThePondItReplaced` and the Sweep B suites FAIL.
  - `PlazaIce.ponds` back to `isWater`. Expected: `testTheHotSpringIsNotAPondThatFreezes`, `testTheHotSpringStaysWaterAllWinter` and the scan FAIL.
  - `PlazaSnow.isSnowGround` with `.hotSpring` in the `true` list. Expected: the equivalence test FAILs.
  - Add `|| map.tile(at: t) == .hotSpring` to `PlazaDitto.isGround`. Expected: the equivalence test FAILs.

  After the last revert, run the filter again. Expected: PASS.
- [ ] **Step 6: Run** `scripts/shared-check.sh`. Expected: it builds.
- [ ] **Step 7: Commit** `feat(team): turn the right plaza pond into hot-spring water that never freezes`.

### Task 3: The spring's colour, stones and effects

**Files:**
- Modify:
  - `Sources/PokeTokenBar/Team/Plaza/PlazaHotSpring.swift`: the colour constants, the props, `usesSpringWater`, `props(in:)`, `artBounds`, `sheet`, `recolored` and `tinted` (Pinned values).
  - `Sources/PokeTokenBar/Team/Plaza/PlazaTileArt.swift`:
    - `waterCell` becomes `static let` (internal), for `PlazaHotSpring.sheet`;
    - `mapImage` builds `PlazaHotSpring.sheet(sheet)` once when `tiles(in: map)` is not empty;
    - the tile loop blits from it where `usesSpringWater`;
    - `drawLilyPads` (`:84-93`) checks `map.tile(at:) == .pond`. Doc: "온천에는 연잎이 없다";
    - `drawHotSpringProps` runs after `drawLilyPads`;
    - `Canvas.blit(_:cols:rows:x:y:from:)` is new.
  - `Sources/PokeTokenBar/Team/Plaza/PlazaSeasonSheet.swift:38-54`:
    - autumn gains `(PlazaHotSpring.autumnStoneColors, PlazaHotSpring.bankStoneCells)`;
    - winter becomes `PlazaSnowSheet.tilePieces + [(PlazaHotSpring.winterStoneColors, PlazaHotSpring.bankStoneCells)]` (ruling 5).
  - `Sources/PokeTokenBar/Team/Plaza/PlazaPondLayer.swift`:
    - keep `map`, and add spring droplet and bubble textures;
    - `ringTextures` is keyed by `(radius, spring)`;
    - `splash(at:big:)` and `bubble(at:)` pick by `map.isHotSpring(tile)`.
  - `Sources/PokeTokenBar/Team/Plaza/PlazaActor.swift`:
    - `springSwimRingTexture`;
    - `place(…, hotSpring: Bool = false)` sets `ghostNode.color` (`waterColor` or `PlazaPondArt.waterColor`) and the swim ring texture;
    - `photoActor(…, hotSpring: Bool = false)` sets `waterColor`.
  - `Sources/PokeTokenBar/Team/Plaza/PlazaScene.swift`:
    - `layout()` (`:2168-2179`) and `photoInput()` (`:1350-1354`) pass `hotSpring: map.isHotSpring(tile)`. Use `walker.tile` and `r.motion.tile`.
  - `Sources/PokeTokenBar/Team/Plaza/PlazaPhotoRenderer.swift`:
    - `PlazaPhotoActor.waterColor` (default `PlazaPondArt.waterColor`);
    - `submerged(_:graphics:color:)` (`:318-327`).
- Test:
  - `PlazaHotSpringTests`
  - `PlazaTileArtTests+Bundled` (and `testLilyPadsAreBakedInEachPond`, Sweep C)
  - `PlazaSeasonTests+Bundled` (`:13-26`, `:203-258`)
  - `PlazaArtParityPixelArtTests` (`:47-98`)
  - `PlazaPondSweepTests+Mac` (the allow-list gains the lily check)
  - `PlazaPondLayerTests`
  - `PlazaPondSceneTests`
  - `PlazaPhotoTests`

**Interfaces:**
- Produces: everything in `PlazaHotSpring` except `PlazaSoak` and `PlazaFlushFade`.
- `props(in:)` is all-or-nothing, so on `old` (no `'h'`) `mapImage` draws today's pond byte for byte.
- `artBounds(in: map)` = the ring's box ∪ the props' tiles = (31,13)…(40,21).

- [ ] **Step 1: Write the failing tests.**
  - `PlazaHotSpringTests`:
    - `testThePropsSitOnTheirTilesAndChangeNoWalking`:
      - on the real map, `props(in:)` is the six props;
      - every `inWater` tile is `.hotSpring`, and every bank tile is walkable and not water;
      - on `old`, `props(in:) == []`.
    - `testTheSpringSheetSwapsOnlyTheWaterColours`:
      - the bundled sheet through `sheet(_:)`: cell (3,7) is solid `#4FA8A0`;
      - outside `[waterCell] + shoreCells + waterPropCells`, every byte is unchanged;
      - inside, no opaque pixel keeps a `waterColors` key.
    - `testRecolouredEffectsKeepTheirShapes`: `recolored(PlazaPondArt.swimRing())` has the same alpha bytes, and `#74C0B6` replaces `#2996DB`.
    - `testTheTintIsTheSharedRenderersFormula`: a white opaque pixel at blend 0.45 becomes (241, 176, 167) ±1. Alpha is unchanged and transparent stays transparent.
  - `PlazaTileArtTests+Bundled`:
    - `testTheSpringIsJadeInEverySeason`. For each season's `PlazaSeasonSheet.look(PlazaMapData.map, …)`:
      - every tile where `usesSpringWater` has no opaque pixel equal to `#1E7CB8`, `#165C88` or `#5AAEE4`;
      - bare tile (36,18) is solid `#4FA8A0`.
    - `testNoBlueShadowIsLeftInTheSpring` (ruling 2):
      - take the premultiplied bytes of one 0x66-alpha shadow pixel of cell (12,10) from the bundled sheet;
      - blend them over `#1E7CB8`, `#165C88` and `#5AAEE4` with `Canvas.plot`'s formula (`min(255, src + dst × (255 − a) / 255)`);
      - none of the three results appears anywhere in any season's map. A last-pass swap leaves them under every foam rock. (A "bluish pixel" threshold would not work: winter's snow colours such as `#9FC3E6` are bluish.)
    - `testTheHotSpringHasNoLilyPads`: tiles (33,18), (35,16) and (36,16) of the real map equal tile (36,18). All are bare spring water.
    - `testOnlyTheHotSpringChangedTheMap`: for each season, the map built from `PlazaMapData.map` equals the map built from `old` (same sheet, same season) outside `artBounds`, byte for byte.
    - `testAMapWithoutTheSpringDrawsTheOldPond`: the summer look built from `old` has today's summer hash. Keep the pre-PR `pinnedLooks[.summer].map` value (`949e959d…9ffb`) as its own constant before re-pinning `pinnedLooks`. The legacy port is Mac-only, so this shared test pins the hash instead.
  - `PlazaSeasonTests+Bundled`:
    - re-pin `pinnedLooks` map hashes for summer, winter and spring from the first run. Comment: "PR 4: the right pond is the hot spring; outside it the maps are unchanged (`testOnlyTheHotSpringChangedTheMap`)". The grass hashes are unchanged;
    - `testAutumnLeavesNoSummerGreen`: the cell list adds `PlazaHotSpring.bankStoneCells`;
    - `testTheHotSpringStonesKeepNoSummerGreenInWinter`: the winter season sheet's `bankStoneCells` have no summer green left (5.4's definition);
    - `testSpringAndSummerStonesStayGreenLikeTheGround`: spring's and summer's stone cells are byte-equal to the original sheet's.
  - `PlazaArtParityPixelArtTests`:
    - the map comparisons (`:53-61`, `:85-86`) use `old` (the pre-spring rows), where the new builder must still match the legacy port;
    - `testSeasonSheetsAreByteIdentical` compares winter's season sheet to the legacy one outside `bankStoneCells`. It adds `PlazaSnowSheet.tiles` equal to the legacy sheet, as today.
  - `PlazaPondLayerTests.testEffectsInTheSpringAreJade`:
    - `splash(at: (34,17), big: true)` then one update: every droplet's texture image has no `#2996DB`/`#5AAEE4` pixel, and has `#74C0B6`;
    - at (8,14) the textures are today's.
  - `PlazaPondSceneTests.testASwimmerInTheSpringShowsSpringWater`: a member swimming at (34,18) has `ghost color == PlazaHotSpring.waterColor` and the spring ring texture. A member at (8,14) has today's.
  - `PlazaPhotoTests.testAPhotoOfTheSpringShowsSpringWaterAndTheFlush`, the water half: `photoInput()` gives the swimmer at (34,18) `waterColor == PlazaHotSpring.waterColor`. Task 7 adds the flush half.
- [ ] **Step 2: Run** `swift test --filter 'PlazaHotSpringTests|PlazaTileArtTests'`. Expected: the build fails (`PlazaHotSpring` has no member `sheet`).
- [ ] **Step 3: Implement** the Interfaces.
- [ ] **Step 4: Run** `swift test --filter 'PlazaHotSpringTests|PlazaTileArtTests|PlazaSeasonTests|PlazaArtParityPixelArtTests|PlazaArtParityTests|PlazaPondLayerTests|PlazaPondSceneTests|PlazaSwimLowerHalfTests|PlazaPhotoTests|PlazaPhotoParityTests|PlazaIceArtTests|PlazaMinimap'`. Expected: PASS.
- [ ] **Step 5: Injection.** Run each change with Step 4's filter, then revert it:
  - Swap the water colours on the finished canvas instead (draw from the season sheet, recolour the spring region last). Expected: `testNoBlueShadowIsLeftInTheSpring` FAILs.
  - Drop the autumn stone piece. Expected: `testTheWholeAutumnMapHasNoSummerGreen` FAILs.
  - Drop the winter stone piece. Expected: `testTheHotSpringStonesKeepNoSummerGreenInWinter` FAILs.
  - Make `props(in:)` skip the `'h'` check. Expected: `testAMapWithoutTheSpringDrawsTheOldPond` and the parity tests FAIL.
  - Use the spring sheet for every tile. Expected: `testOnlyTheHotSpringChangedTheMap` FAILs (the left pond turns jade).
  - Lily pads back to `isWater`. Expected: `testTheHotSpringHasNoLilyPads` FAILs.

  After the last revert, run Step 4's filter. Expected: PASS.
- [ ] **Step 6: Run** `scripts/shared-check.sh`. Expected: it builds.
- [ ] **Step 7: Commit** `feat(team): paint the plaza hot spring jade and set stones around it`.

### Task 4: Drop in the steam sheet

**Files:**
- Create: `Sources/PokeTokenBar/Resources/Plaza/plaza-steam.png`, byte for byte the downloaded `smoke_5.png` (224×32, SHA-256 `246e0f333142c5d388dab36d50caf19fe508e8274ad4ecf7c7b96c0b92b0b8f8`).
- Modify:
  - `Sources/PokeTokenBar/Team/Plaza/PlazaResources.swift:40-47`: `steamSheetName`, `steamFrames`.
  - `Sources/PokeTokenBar/Resources/Plaza/CREDITS.md`
  - `windows/licenses/map.txt:29`
  - `Sources/PokeTokenBar/Team/Plaza/Draw/PlazaDecodeGoldens.swift:15-28`
  - `TEAM.md` `## 출처`
- Test:
  - `PlazaResourcesTests.swift`
  - `PlazaResourcesTests+Mac.swift`
  - `MacPlazaGraphicsTests.swift:12-25`, `:92-98`

**Interfaces:**
- Consumes the art-sourcing scratch: `/private/tmp/claude-501/-Users-simu-Documents-GitHub-PokeTokenBar/91160cc1-46af-46c5-90bf-69dfeff21416/scratchpad/spring-tree-art/downloads/smoke-puff/smoke_5.png`.
  - `smoke_6.png` beside it is byte-identical; the page links both.
  - The scratchpad gets pruned after a few days. If the file is gone, download `https://opengameart.org/sites/default/files/smoke_5.png` again and check its SHA-256 before committing.
- **The credit (settled from the saved page, re-checked in Step 1):**
  - work "Smoke Puff", page `https://opengameart.org/content/smoke-puff`;
  - author **Aidan_Walker** (`/users/aidanwalker`; "A smoke puff effect i made for this game jam: https://aidanwalker.itch.io/fractured-grief");
  - licence CC0;
  - the page lists the file as `smoke.png`, 622 bytes. The download URL is `smoke_5.png`, also 622 bytes.
  - AntumDeluge only left a comment (using it in Stendhal). They are not the author.
  - The scratch preview's caption "AntumDeluge" is wrong.

- [ ] **Step 1: Re-read the page.** Open `https://opengameart.org/content/smoke-puff` with the web-fetch agent and confirm three things: the Author field is Aidan_Walker, the licence is CC0, and the file link is `smoke_5.png`.
  - If any differs, stop and report it to the lead. Do not commit the file.
- [ ] **Step 2: Write the failing tests.**
  - `PlazaResourcesTests`:
    - `testSteamSheetLoads`: `[224, 32]`.
    - `testTheSixFramesAreTheFirstSixCellsAndTheSeventhIsEmpty`:
      - `PlazaResources.steamFrames.count == 6`, and each is 32×32 at x = 32·i;
      - the opaque counts of the six crops are `[327, 321, 215, 80, 18, 4]`;
      - the cell at x 192 has no opaque pixel.
    - `testCreditsNameTheSteamArtist`: the needles are `Aidan_Walker`, `Smoke Puff`, `https://opengameart.org/content/smoke-puff`, `plaza-steam.png` and `CC0`.
  - `PlazaResourcesTests+Mac.testSteamSheetIsTheUnmodifiedOriginal`: the SHA-256 above.
  - `MacPlazaGraphicsTests`:
    - `bundledImages()` adds `plaza-steam.png`, through `PlazaResources.resourceURL` and `CGImageSourceCreateImageAtIndex`, as the leaf sheet does;
    - `expectedColourSpaces` gets one placeholder line.
  - Add a `PlazaDecodeGoldens.art` entry (`plaza-steam`, 224×32, `sha256: ""`).
- [ ] **Step 3: Run** `swift test --filter 'PlazaResourcesTests|MacPlazaGraphicsTests|PlazaDecodeGoldensMacTests'`. Expected: FAIL (the file is missing).
- [ ] **Step 4: Add the file.**
  - Copy it in as `plaza-steam.png`, then check its SHA-256.
  - Paste the measured `PLAZA-COLOURSPACE:` line and the `PlazaDecodeGoldensMacTests` "new value above" hash.
  - Add a `CREDITS.md` section after `Ice shards`:
    - heading `## Steam (plaza-steam.png)`;
    - `- "Smoke Puff" (\`smoke_5.png\`, unmodified; the page lists it as \`smoke.png\`) by Aidan_Walker`;
    - `- License: CC0 (public domain)`;
    - `- Source: https://opengameart.org/content/smoke-puff`;
    - `- SHA-256: 246e0f33…b8f8` (in full);
    - `- The plaza hot spring's steam: the first six of its seven 32×32 cells (the seventh is empty), cut at runtime and drawn as they are with a changing transparency.`
  - Add a `map.txt` line after `plaza-ice-shatter.gif`: `plaza-steam.png<TAB>-<TAB>"Smoke Puff" by Aidan_Walker (CC0)`.
  - Add a `TEAM.md` `출처` line after 얼음 파편: `- 김 그림: Aidan_Walker, "Smoke Puff" (CC0, 앞 여섯 칸을 잘라 씀)`.
- [ ] **Step 5: Run** the Step 3 filter, then `scripts/shared-check.sh`. Expected: PASS, and it builds.
- [ ] **Step 6: Commit** `feat(team): add the Smoke Puff sheet for the hot spring's steam`. The body has the source URL, the author and the SHA-256.

### Task 5: Steam over the spring

**Files:**
- Modify:
  - `Sources/PokeTokenBar/Team/Plaza/PlazaHotSpring.swift`: `PlazaSteam`, `PlazaSteamWisp`, `PlazaSteamField`.
  - `Sources/PokeTokenBar/Team/Plaza/PlazaScene.swift`:
    - a static `steamFrames: [PlazaImage]`, decoded once like `ballImages` (`:2048-2057`) and cropped by `PlazaResources.steamFrames`;
    - `steamLayer` built beside `pondLayer` (`:470-474`) when `pondVisuals`, the map has spring tiles and six frames decoded; root added before `weatherLayer.root` (`:489-490`);
    - `advanceSteam(by:)` after `advanceWeather(by:)` in `update` (`:1951`);
    - `advanceSteam(by: 0)` in `setBackgroundHidden` (`:568`);
    - the photo's `weather:` (`:1358`) appends `steamLayer?.photoParticles(worldHeight:)`;
    - test reads `isSteamShown`, `steamNodeCount`, `steamWisps`.
  - `Sources/PokeTokenBar/Team/Plaza/PlazaPhotoRenderer.swift:248-251`: the weather loop applies `p.alpha` (weather particles are 1, so they are unchanged).
- Create: `Sources/PokeTokenBar/Team/Plaza/PlazaSteamLayer.swift`
- Test:
  - Create `Tests/PokeTokenBarTests/PlazaSteamLayerTests.swift`.
  - Modify `PlazaWeatherTests+Pixels.swift`.

**Interfaces:**
- `PlazaSteamLayer` (`@MainActor final class`, nodes in `root`, which sits at `PlazaSteam.z`):
  - `init(springTiles: [TilePoint], worldHeight: CGFloat, frames: [PlazaImage])` makes `maxWisps` hidden sprites, one `PlazaTexture` per frame. No other method adds a node.
  - `update(dt: TimeInterval, visible: CGRect, isHidden: Bool, step: CGFloat)`. `visible` is in world coordinates, y down.
    - If `isHidden` or `visible` misses the spring's bounds grown by `cullMargin`: set `root.isHidden = true` and return. The field does not advance and no other property is written.
    - Otherwise: show the root, `field.advance(by: dt)`, and place each wisp. Its sprite is centred on the spawn point, lifted by `lift(age)`, with texture `frame(age)` and alpha `alpha(age)`, snapped to `step`. Unused sprites are hidden.
  - `photoParticles(worldHeight:) -> [PlazaPhotoParticle]`: shown wisps only, each with its alpha. Empty when hidden.
- `PlazaScene.advanceSteam(by:)` passes `visibleRect`, `isBackgroundHidden` and `PlazaPixelSnap.step(...)`, as `advanceWeather` does. A paused scene never calls it.

- [ ] **Step 1: Write the failing tests** in `PlazaSteamLayerTests`.
  - Pure:
    - `testAWispRisesAndThinsOverItsLife`:
      - `frame`: 0 at age 0 and 0.49; 1 at 0.5; 5 at 2.99;
      - `alpha`: 0 at 0, 0.6 at `peakAt`, 0.3 at `(peakAt + life) / 2`, 0 at `life`;
      - `lift`: 0 at 0, 12 at 1.5, 24 at 3.
    - `testTheFieldIsPrewarmedAndKeepsAboutSix`: a new field has 5–7 wisps. Over 600 steps of 1/60, the mean count is in 5.5...6.5 and the max is ≤ `maxWisps`.
    - `testWispsSpawnOnlyOverSpringTiles`: every spawn point over 600 steps lies inside x 1024..<1248 and y 448..<672.
    - `testTheSameSeedGivesTheSameSteam`: two fields after 100 equal steps are equal.
  - Layer and scene (the real map, `pondVisuals: true`, the bundled frames):
    - `testThePoolIsMadeOnceAndNeverGrows`:
      - a scene at (35,17), zoom 2: `steamNodeCount == 9` (a root and eight);
      - after 1,000 `update` calls of 1/60, still 9, and the scene root's children count is unchanged;
      - shown sprites ≤ 8 on every frame.
    - `testAPausedSceneMovesNoWispAndMakesNoNode`: `isPaused = true`, then 100 `stage.tick`s, `setBackgroundHidden(true)`, `setBackgroundHidden(false)` and `layout`-calling setters. `steamWisps` and the node count are unchanged.
    - `testAnOffscreenSpringIsNeitherAdvancedNorTouched`:
      - me at (19,10): `isSteamShown == false`;
      - record every steam sprite's position, alpha, texture and `isHidden`; after 600 updates they are identical, and so is `steamWisps`;
      - then put me at (35,17) and run 0.5 s: `isSteamShown` is true and the wisps' ages grew.
    - `testTheMarginIsOneTile`, on the layer directly: `update(dt: 1/60, visible: CGRect(x: 1000, y: 0, width: 300, height: 416), isHidden: false, step: 0.5)` leaves it hidden (the rect only touches the spring grown by one tile, which starts at y 416). With height 417 it is shown.
    - `testHidingTheBackgroundHidesTheSteam`: `setBackgroundHidden(true)` → `isSteamShown == false` at once. Back to false → shown on the next frame.
    - `testSteamSitsAboveCharactersAndBelowTheDaylightMultiply`: the `PlazaWeatherTests+Scene` pattern. `steam z > character z` (any foot), `< weather z`, `< daylight z`.
    - `testThePhotoCarriesTheWispsAtTheirAlpha`: `photoInput()?.weather` includes every shown wisp, each with the alpha of its sprite.
  - `PlazaWeatherTests+Pixels.testAParticleIsDrawnAtItsAlpha`: a 2×2 white particle with alpha 0.5 over black gives 128 ±1.
- [ ] **Step 2: Run** `swift test --filter 'PlazaSteamLayerTests|PlazaWeatherTests'`. Expected: the build fails (`cannot find 'PlazaSteamField' in scope`).
- [ ] **Step 3: Implement** the Interfaces.
- [ ] **Step 4: Run** `swift test --filter 'PlazaSteamLayerTests|PlazaWeatherTests|PlazaPhotoTests|PlazaPhotoParityTests|TeamHostilePeerTests|PlazaSnowSceneTests|PlazaPondSceneTests'`. Expected: PASS.
- [ ] **Step 5: Injection.** Run each change with Step 4's filter, then revert it:
  - Make a sprite per spawn instead of using the pool. Expected: `testThePoolIsMadeOnceAndNeverGrows` FAILs.
  - Advance the field while culled. Expected: `testAnOffscreenSpringIsNeitherAdvancedNorTouched` FAILs.
  - Drop the `p.alpha` in the photo's weather loop. Expected: `testAParticleIsDrawnAtItsAlpha` FAILs.
  - Drop `isHidden` from the cull. Expected: `testHidingTheBackgroundHidesTheSteam` FAILs.

  After the last revert, run Step 4's filter. Expected: PASS.
- [ ] **Step 6: Run** `scripts/shared-check.sh`. Expected: it builds.
- [ ] **Step 7: Commit** `feat(team): raise steam over the plaza hot spring`.

### Task 6: The soak clock, the fade and the presence flag

**Files:**
- Modify:
  - `Sources/PokeTokenBar/Team/Plaza/PlazaHotSpring.swift`: `PlazaSoak`, `PlazaFlushFade`.
  - `Sources/PokeTokenBar/Team/TeamWire.swift:54-56`: `@LossyOptional var isFlushed: Bool?`. Doc: "Flushed red from three minutes in the plaza hot spring. Left out when false; a receiver draws it only while the sender's tile is a hot-spring tile; unreadable values become nil; earlier versions ignore it."
  - `Sources/PokeTokenBar/Team/TeamSession.swift`:
    - `TeamMember.isFlushed` (`:42`);
    - the private `isFlushed` (`:137`);
    - `updatePlazaPosition(…, isFlushed:)` (`:226-235`);
    - `updateFlushed` after `updateBodySize` (`:338-344`);
    - receive (`:438`): `member.isFlushed = presence.isFlushed == true`;
    - `makePresence` (`:549`): `isFlushed: isFlushed ? true : nil`.
- Test: `PlazaHotSpringTests`, `TeamWireTests`, `TeamSessionTests`, `TeamHostilePeerTests`.

**Interfaces:** as in Pinned values.

- [ ] **Step 1: Write the failing tests.** `t0 = Date(timeIntervalSinceReferenceDate: 1_000)`.
  - `PlazaHotSpringTests`:
    - `testFlushedAtExactlyThreeMinutes`: `update(inSpring: true, now: t0)` is true. `isFlushed` is false at `t0 + 179.9` and true at `t0 + 180`. `deadline == t0 + 180`.
    - `testLeavingAt179RestartsTheCount`: in at t0, out at +179 (true; `since == nil`), in at +180 (true). At +359.9 false, at +360 true.
    - `testStayingInDoesNotRestart`: `update(inSpring: true, now: t0 + 10)` again is false, and `since == t0`.
    - `testAClockThatWentBackRestartsTheSoak`: in at t0; `update(inSpring: true, now: t0 − 3600)` is true and `since == t0 − 3600`. `isFlushed` is false at `t0 − 3600 + 179`.
    - `testTheRedRisesInTwoSecondsAndFadesOverAMinute`:
      - `PlazaFlushFade(on: false, now: t0)`, then `set(true, now: t0)`: level 0, 0.5, 1 at +0, +1, +2;
      - `set(false, now: t0 + 2)`: level 1, 0.5, 0 at +2, +32, +62 (the spec's 0, 30, 60 s);
      - `blend` at +2 is 0.45.
    - `testALateJoinerSeesTheRedAtOnce`: `PlazaFlushFade(on: true, now: t0).level(at: t0) == 1`, and `(on: false)` is 0.
    - `testTurningBackMidFadeStartsFromTheCurrentLevel`: on, full, off at T, back on at T + 30 (level 0.5). Level is 1 at T + 31.
    - `testAClockThatWentBackHoldsTheLevel`: off at T from 1. `level(at: T − 100) == 1`.
  - `TeamWireTests`:
    - In `testEveryOptionalFieldSurvivesARoundTrip` (`:101-120`), set `full.isFlushed = true`.
    - `testIsFlushedIsOptionalOnTheWire`:
      - the plain presence has no `"isFlushed"`;
      - `isFlushed = true` encodes `"isFlushed":true` and round-trips;
      - `isFlushed = false` and nil both encode without the key;
      - an earlier frame (no key) decodes to nil.
    - `testUnreadableIsFlushedDropsOnlyTheFlag`: `"yes"`, `1`, `{}` → nil. The nickname and tile survive.
  - `TeamSessionTests.testPresenceCarriesFlushedOnlyWhileOn` (the pattern of `testPresenceCarriesDivingAndStage`, `:946`):
    - `updatePlazaPosition(…, isFlushed: true)` → the peer's `members[me].isFlushed` is true;
    - a move with the default → false, carried in that same presence;
    - `updateFlushed(true)` sends one presence, and a second call sends none.
  - `TeamHostilePeerTests.testAbsurdFlushValuesBecomeFalseAndTheFrameLives` (next to `:120`): for `"yes"`, `1`, `"true"`, `{}`, `null`, `member.isFlushed == false` and the tile is (7,8). Control: `true` → true.
- [ ] **Step 2: Run** `swift test --filter 'PlazaHotSpringTests|TeamWireTests|TeamSessionTests|TeamHostilePeerTests'`. Expected: the build fails (`cannot find 'PlazaSoak' in scope`).
- [ ] **Step 3: Implement** the Interfaces.
- [ ] **Step 4: Run** Step 2's filter. Expected: PASS.
- [ ] **Step 5: Injection.** Run each change with Step 2's filter, then revert it:
  - `isFlushed` uses `>`. Expected: `testFlushedAtExactlyThreeMinutes` FAILs.
  - `update` keeps `since` on leaving. Expected: `testLeavingAt179RestartsTheCount` FAILs.
  - `set` restarts from 0 or 1 instead of the current level. Expected: `testTurningBackMidFadeStartsFromTheCurrentLevel` FAILs.
  - `makePresence` sends `false` instead of leaving the key out. Expected: `testIsFlushedIsOptionalOnTheWire` FAILs.

  After the last revert, run the filter again. Expected: PASS.
- [ ] **Step 6: Run** `scripts/shared-check.sh`. Expected: it builds.
- [ ] **Step 7: Commit** `feat(team): add the hot-spring soak clock, the flush fade and the isFlushed presence flag`.

### Task 7: Flush teammates red on every screen

**Files:**
- Modify:
  - `Sources/PokeTokenBar/Team/Plaza/PlazaScene.swift`:
    - `PlazaSceneMember.isFlushed` (`:27`);
    - `Remote.flush: PlazaFlushFade` (`:204-226`);
    - `applyMembers` (`:619-668`);
    - `private var myFlush`, `setMyFlushed`;
    - `layout()` (`:2168-2179`) calls `setFlush`;
    - `photoInput()` (`:1350-1354`) passes `flush:`;
    - test reads `myFlushBlend`, `memberFlushBlend(_:)`.
  - `Sources/PokeTokenBar/Team/Plaza/PlazaActor.swift`:
    - `setFlush(_:)`;
    - `photoActor(…, flush:)` (`:406-427`);
    - `var flushBlend: CGFloat` (test read).
  - `Sources/PokeTokenBar/Team/Plaza/PlazaPhotoRenderer.swift`: `PlazaPhotoActor.flush`. The body draw (`:214`) uses `PlazaHotSpring.tinted(a.image, blend: a.flush)` when `flush > 0`. The submerged part does not.
  - `Sources/PokeTokenBar/Team/Plaza/PlazaWindowController.swift`:
    - init param `soakSleep` (beside `focusTickSleep`, `:272`, `:283`);
    - `soak`, `soakTask`;
    - `sendPosition` (`:1880-1883`), `armSoak`, `flushIfDue`;
    - `handleClose` (`:2183-2220`): cancel and reset;
    - the scene member map (`:2039-2043`): `isFlushed: $0.isFlushed`.
  - `Tests/PokeTokenBarTests/PlazaRenderScenes.swift`:
    - `member(…, flushed: Bool = false)` (`:215-220`);
    - in `hotSpring(…)`, Ash is `flushed: true`.
- Test:
  - Create `Tests/PokeTokenBarTests/PlazaHotSpringControllerTests.swift`.
  - Modify `PlazaPhotoTests.swift`, `TeamHostilePeerTests.swift`, `PlazaWindowShellTests.swift`.

**Interfaces:**
- Scene:
  - `applyMembers`: `on = !m.isAway && m.isFlushed && map.isHotSpring(resolvedTile(m))`. A new remote gets `PlazaFlushFade(on:now: now())`. An existing remote gets `r.flush.set(on, now: now())`. The Ditto key never gets one.
  - `setMyFlushed(_ on: Bool)`: `myFlush.set(on, now: now())`.
  - `layout()`: `let date = now()`, then `me.setFlush(myFlush.blend(at: date))` and `r.actor.setFlush(r.flush.blend(at: date))`.
- Actor: `setFlush(_ blend: CGFloat)` sets `characterNode.color = PlazaHotSpring.flushColor` and `characterNode.colorBlendFactor = blend`. The ghost is untouched.
- Controller:
  - `sendPosition(inPlaza:scene:)`:
    1. `let now = clock()`;
    2. `let inSpring = inPlaza && map.isHotSpring(scene.walker.tile)`;
    3. `if soak.update(inSpring: inSpring, now: now) { armSoak() }`;
    4. `let flushed = inSpring && soak.isFlushed(now: now)`;
    5. `scene.setMyFlushed(flushed)`;
    6. `session?.updatePlazaPosition(…, isFlushed: flushed)`.
  - `armSoak()`: `soakTask?.cancel()`. If `soak.deadline` is set, start one Task that awaits `soakSleep(.milliseconds(⌈(deadline − clock()) × 1000⌉, at least 0))`, then `guard !Task.isCancelled, let self` (as `startFocusTick` does) and calls `flushIfDue()`. The Task holds `self` weakly while it waits.
  - `flushIfDue()`: if `soak.isFlushed(now: clock())`, call `scene?.setMyFlushed(true)` and `session?.updateFlushed(true)`. Else, if `soak.deadline != nil`, call `armSoak()` (a clock that went back).
  - `handleClose`: `soakTask?.cancel(); soakTask = nil; soak = PlazaSoak()`. The existing `inPlaza: false` presence already leaves the flag out.

- [ ] **Step 1: Write the failing tests.**
  - `PlazaHotSpringControllerTests` (new, shared):
    - Copy `node`, `controller`, `settle`, `run`, `press`, `World`, `world` and `place` from `PlazaSnowballControllerTests`. Add a `SoakGate` like `LoopGate` (`PlazaDittoControllerTests.swift:73-80`), and pass `soakSleep: { await gate.sleep($0) }`.
    - `testThreeMinutesInTheSpringFlushesMeOnEveryScreen`:
      - me at (31,17) facing `.right`, b at (20,12); Z (6), run 1 s: I am at (32,17);
      - `gate.requested == [.milliseconds(180_000)]`, and b sees `isFlushed == false`;
      - `now += 180`, `gate.fire()`, settle: b's `members[me].isFlushed` is true and my `scene.myFlushBlend` is about 0;
      - `now += 2`, run 0.1 s: `myFlushBlend == 0.45`. The fixture's clock moves only when the test sets `now`.
    - `testOneDeadlineNotAPoll`: walking within the spring for 60 s (five steps) leaves `gate.requested.count == 1`. Leaving cancels it; re-entering requests 180 s again.
    - `testLeavingClearsTheFlagInThePresenceThatMovesMe`:
      - flushed as above, then press left;
      - in my transport's `sent` presences, the first one with tile (31,17) has `isFlushed == nil`;
      - no presence ever has a land tile with `isFlushed == true`.
    - `testClosingThePlazaClearsTheFlag`:
      - flushed, then `handleClose()`: the last presence has `inPlaza == false` and no flag;
      - a fresh world, in the spring but not yet flushed: `handleClose()`, `now += 180`, `gate.fire()`, settle. No presence with `isFlushed == true` is sent after the close (the cancelled task returns after its sleep).
    - `testAHiddenPlazaStillFlushes`: in the spring, `setRendering(visible: false)`, `now += 180`, fire. b sees true.
    - `testATeammatesRedFadesOverAMinuteAfterTheyLeave`:
      - b sends `updatePlazaPosition(inPlaza: true, tile: (34,17), …, isFlushed: true)`, settle, run 0.1 s: `memberFlushBlend(b) == 0.45`. The first sight has no rise;
      - b moves to (31,17) with the default flag; `now += 30`, run 0.1 s: 0.225 ±0.01; `now += 30`: 0.
    - `testATeammateTurningRedRisesOverTwoSeconds`: b already shown in the spring unflushed; flag on; run 1 s with `now += 1`: 0.225 ±0.01.
    - `testAPausedSceneIsRightOnItsFirstFrameBack`: b red; `setRendering(visible: false)`; b leaves; `now += 30`; `setRendering(visible: true)`; run 1/60 s: 0.225 ±0.01.
    - `// MARK: - Hostile peers`:
      - `testAFlushClaimOffTheSpringIsNotDrawn`: b at (30,17) with `isFlushed: true`. After `now += 3` and a 0.1 s run, `memberFlushBlend(b) == 0`.
      - `testAFlushClaimFromAnAwayMemberIsNotDrawn`: `inPlaza: false`, tile (34,17), flag on → 0.
  - `PlazaPhotoTests.testAPhotoOfTheSpringShowsSpringWaterAndTheFlush`, the flush half: a flushed swimmer's `PlazaPhotoActor.flush == 0.45`. A rendered white body pixel above the waterline is (241, 176, 167) ±1.
  - `TeamHostilePeerTests.testAFlushFloodAddsNoNode`: on the existing visible-scene helper, 1,000 `applyMembers` calls alternate `isFlushed` for a member at (34,17). `scene.children.count` and each actor's world node count are unchanged. Repeat on a paused scene.
  - `PlazaWindowShellTests.testWhatTeammatesAndTimersTriggerNeverBringsThePlazaForward` (`:565-595`): after `showDrag`, the teammate sends `updatePlazaPosition(inPlaza: true, tile: beside, facing: .left, isWalking: false, isFlushed: true)`. It must not bring the plaza forward, like the rest of the list.
- [ ] **Step 2: Run** `swift test --filter 'PlazaHotSpringControllerTests|PlazaPhotoTests'`. Expected: the build fails (`extra argument 'soakSleep'`).
- [ ] **Step 3: Implement** the Interfaces.
- [ ] **Step 4: Run** `swift test --filter 'PlazaHotSpringControllerTests|PlazaHotSpringTests|PlazaPhotoTests|PlazaPhotoParityTests|TeamHostilePeerTests|PlazaWindowShellTests|PlazaPondSceneTests|PlazaMimicControllerTests|PlazaDittoControllerTests|PlazaFocusTests|TeamRuntimeTests|PlazaSteamLayerTests'`. Expected: PASS.
- [ ] **Step 5: Injection.** Run each change with Step 4's filter, then revert it:
  - Compute the fade from summed frame `dt` instead of `now()`. Expected: `testAPausedSceneIsRightOnItsFirstFrameBack` FAILs.
  - Drop `map.isHotSpring(...)` from the receive rule. Expected: `testAFlushClaimOffTheSpringIsNotDrawn` FAILs.
  - Send the cleared flag in a second presence after the tile one (call `updateFlushed(false)` after `updatePlazaPosition` without the param). Expected: `testLeavingClearsTheFlagInThePresenceThatMovesMe` FAILs.
  - Arm the deadline on every `sendPosition`. Expected: `testOneDeadlineNotAPoll` FAILs.
  - Start new remotes at level 0 with a rise. Expected: `testATeammatesRedFadesOverAMinuteAfterTheyLeave` (its first assertion) FAILs.

  After the last revert, run Step 4's filter. Expected: PASS.
- [ ] **Step 6: Run** `scripts/shared-check.sh`. Expected: it builds.
- [ ] **Step 7: Coverage.** Run with nothing else building:
```bash
swift test --enable-code-coverage --filter 'PlazaHotSpringTests|PlazaHotSpringControllerTests|PlazaSteamLayerTests|PlazaTileArtTests|PlazaSeasonTests|PlazaPondLayerTests|PlazaPondSceneTests|PlazaPhotoTests|PlazaIceTests|PlazaIceControllerTests|PlazaIceSceneTests|TeamWireTests|TeamSessionTests|TeamHostilePeerTests'
BIN_PATH=$(swift build --show-bin-path); PROF=$(find "$BIN_PATH/" -name default.profdata | head -1)
BIN=$(find "$BIN_PATH/" -name PokeTokenBarPackageTests -type f ! -path '*.dSYM/*' | head -1)
LLVM_COV="$(dirname "$(realpath "$(command -v swift)")")/llvm-cov"; [ -x "$LLVM_COV" ] || LLVM_COV=$(xcrun --find llvm-cov)
BASE=$(git merge-base HEAD feat/plaza-pull)
for f in $(git diff --name-only "$BASE" -- Sources/PokeTokenBar/Team); do
  CHANGED=$(git diff -U0 "$BASE" -- "$f" | awk '/^@@/{split($3,a,/[+,]/); n=(a[3]==""?1:a[3]); for(i=0;i<n;i++) print a[2]+i}')
  "$LLVM_COV" show "$BIN" -instr-profile="$PROF" --show-regions "$f" \
    | awk -F'|' '/^ *[0-9]+\|/{ln=$1+0} /\^0/{print ln}' | sort -u | grep -Fx -f <(echo "$CHANGED") | sed "s|^|$f:|"
done
```
  - This prints each added or changed source line that has a `^0` region.
  - Expected: nothing.
  - If a line is reported, write the missing branch's test. Do not mark it unreachable without the input-path check from CLAUDE.md step 3.
- [ ] **Step 8: Commit** `feat(team): flush a teammate red after three minutes in the hot spring`.

### Task 8: Windows selftests

**Files:**
- Modify:
  - `Sources/PokeTokenBar/Platform/Windows/WindowsSelftestPlazaRender.swift`
  - `Sources/PokeTokenBar/Platform/Windows/WindowsSelftestPlaza.swift:233-246`

These are Windows-only (`#if os(Windows)`). The Mac does not compile them. The windows.yml selftest job checks them after the push.

- [ ] **Step 1: The render cost with the spring in view.**
  - Move the body of `plazaRenderChecks` (`:11-96`) into `measure(_ r: Recorder, name: String, me: TilePoint, sit: Bool, members: [PlazaSceneMember])`. Call it twice:
    - `plaza.renderCost`: exactly today's case (the first campfire seat, sitting, twelve walkers).
    - `plaza.renderCostSpring`: me at (31,17) facing right, not sitting. Twelve members swim at x 32...37, y 15 and 18. Every second one has `isFlushed = true`. The same winter night, fireworks and per-20-frame moves (members stepping to x 31 or 38 leave or stay in the spring; both are fine).
  - The judgement is the same for both: median ≤ 4 ms and `failedFrames == 0`.
  - Add `steam=\(scene.isSteamShown)` to the spring line's detail, and require it true.
- [ ] **Step 2: Idle.**
  - Add `steamShown=\(scene?.isSteamShown ?? false)` to `plaza.idleVisible`'s detail.
  - Add `&& scene?.isSteamShown != true` to its judgement. The selftest plaza stands at the spawn (23,6); the spring is off-screen there, so it must cost nothing (spec 2, 안티골 "무거워지는 광장").
- [ ] **Step 3: Run** `scripts/shared-check.sh`. Expected: it builds. The Windows files are compiled by the windows.yml build.
- [ ] **Step 4: Commit** `test(windows): measure the plaza render cost with the hot spring in view`.

### Task 9: TEAM.md

**Files:** `TEAM.md:167` (the 연못 row), a new row after it, `## 팀에 보이는 것과 보이지 않는 것` (after the 크기 등급 line, `:208`), and the end of `## 알려진 한계` (after `:281`).

- [ ] **Step 1: Edit `TEAM.md`.**
  - 연못 row:
    - `광장 곳곳에 연못이 세 군데 있습니다.` becomes `광장에 연못이 두 군데(왼쪽, 아래쪽) 있고, 오른쪽에는 온천이 있습니다("온천" 줄). 이 줄의 헤엄, 잠수, 물보라, 젖기, 물귀신, 몸통박치기에 밀려 빠지기는 온천에서도 똑같습니다.`
    - `연못은 한 군데씩 얼어붙습니다. 처음에는 왼쪽 연못이 얼어 있습니다. 얼음은 누가 깰 때까지 그대로 있고, 얼음이 깨지면 깨진 연못을 뺀 나머지 연못 중 하나가 무작위로 1분 뒤에 얼어붙습니다(팀원 모두 같은 연못이고, 같은 연못이 두 번 연달아 얼지는 않습니다).` becomes `연못은 한 군데씩 얼어붙습니다(온천은 얼지 않습니다). 처음에는 왼쪽 연못이 얼어 있습니다. 얼음은 누가 깰 때까지 그대로 있고, 얼음이 깨지면 1분 뒤에 다른 연못이 얼어붙어 왼쪽과 아래쪽 연못이 번갈아 업니다(팀원 모두 같은 연못입니다).`
  - New row after 연못:
    > `| 온천 | 오른쪽 연못은 일 년 내내 온천입니다. 물빛이 뿌연 옥빛이고 물속과 물가에 돌이 놓여 있으며(물가의 돌은 밟고 지나갈 수 있습니다), 연잎은 없고 김이 피어오릅니다. 들어가고 헤엄치고 잠수하는 것은 연못과 같고, 겨울에도 얼지 않습니다. 온천에 3분 동안 계속 있으면 몸이 빨갛게 달아오르고 팀원 화면에서도 빨갛게 보입니다. 3분이 되기 전에 나왔다 다시 들어가면 처음부터 셉니다. 나오거나 광장을 닫으면 1분에 걸쳐 원래 색으로 돌아옵니다. 보이기만 하고 점수, 보너스, 오늘 광장 기록은 없습니다. 광장을 나중에 연 팀원에게는 이미 빨개진 팀원이 처음부터 빨갛게 보이고, 그 전에 나와서 식는 중이던 팀원은 빨갛게 보이지 않습니다. 김은 온천이 화면에 보일 때만 피어오르고, 캐릭터 위·이름표와 말풍선 아래에 그려지며 낮과 밤의 색을 같이 입습니다. 김과 빨간 모습은 사진에도 담기고, 배경을 숨기면 김도 사라집니다. 작은 지도의 온천도 옥빛입니다 |`
  - 팀에 보이는 것, after the 크기 등급 line: `- 온천에 3분 넘게 있어서 몸이 빨개졌는지 여부. 빨개졌을 때만 보내고, 온천을 나오거나 광장을 닫으면 그 자리에서 빠집니다`.
  - End of 알려진 한계:
    > `- v2.5.635 이하를 쓰는 팀원의 광장에서는 오른쪽이 예전처럼 연잎이 뜬 파란 연못이고 아무도 빨개지지 않습니다. 그 팀원은 최신 버전 화면에서 온천에 오래 있어도 빨개지지 않습니다. 얼음도 모두 업데이트할 때까지 서로 다를 수 있습니다: 그 팀원은 오른쪽 연못도 얼 수 있는 연못으로 세어 왼쪽이나 아래쪽 얼음이 깨진 뒤 오른쪽 연못을 얼리기도 하고, 그 팀원이 오른쪽 얼음을 깨면 최신 버전 화면에서는 그냥 점프입니다. 그 팀원이 오른쪽 얼음 위를 걸으면 최신 버전 화면에서는 온천에서 헤엄치는 것으로 보입니다. 업데이트하면 바로잡힙니다.`
  - Re-check the version at release (ruling 9).
  - `TeamReleaseScriptTests.testTeamGuideHoldsNoPrivateDetails` must still pass: no `@`, no `.local`.
- [ ] **Step 2: Run** `swift test --filter 'TeamReleaseScriptTests'`. Expected: PASS.
- [ ] **Step 3: Commit** `docs(team): explain the plaza hot spring in TEAM.md`.

### Task 10: Renders for the user's approval

**Files:** none in the repo. The outputs go under `$S`.

**Harness:** `scripts/plaza-render-compare.sh`. It builds the base commit in `$S/ptb-render-base` and HEAD, runs `PlazaRenderCompareTests/testRenderAllScenes` offscreen on both, and compares them.

- [ ] **Step 1: Render.**
```bash
S="<your session scratchpad>/plaza-hot-spring"
BASE=$(git log --format=%H -1 --grep '^test(team): pin the plaza map and add hot-spring render scenes')
PTB_PLAZA_RENDER_ONLY=hot-spring,hot-spring-night,hot-spring-summer,hot-spring-spring,hot-spring-autumn,hot-spring-winter,board-marker,items,zoom-1,ice-frozen,ice-breaking,ice-refreeze \
  scripts/plaza-render-compare.sh --base "$BASE" --scratch "$S" --runs 1
```
  Expected:
  - exit 1, with `RENDER: <k> differ`;
  - the list covers every `hot-spring*@*`, `board-marker@10` and `board-marker@40`;
  - it does **not** list `items@*`, `zoom-1@*` or `ice-*@*`. Those are byte-identical (ruling 6; the bare north-west corner and the one-tile cull keep them so).
  - Ignore the `FRAMECOST` lines (one run).
- [ ] **Step 2: Contact sheet.** Write `$S/tools/contact.py` and run it with `python3 -I`. It halves each frame with NEAREST and labels each tile. Make `$S/approval/hot-spring.png` with:
  - row 1: `hot-spring-summer`, `-spring`, `-autumn`, `-winter` @10, before;
  - row 2: the same after;
  - row 3: `hot-spring@10`, `hot-spring@60` and `hot-spring-night@10` after (the red swimmer, Ash, and steam at two frames), and `photo-hot-spring-winter` if the harness wrote it;
  - a strip of the six steam frames at ×4 on the summer spring colour.

  Label the sheet "Sample-data render, offscreen (SKRenderer), not the live app".
- [ ] **Step 3: Check by eye.**
  - The water is jade in all four seasons. No blue is left on shore edges or under rock shadows.
  - The stones in winter and autumn show no summer green.
  - Steam is visible at both frames and stays over the spring.
  - Ash is red, Misty is not, and the red is darker at night.
- [ ] **Step 4: Send for approval.** Send the path to the lead, labelled as above, with:
  - the Props table;
  - the tunables: the four colour pairs (ruling 3), `flushBlend` and `flushColor`, `PlazaSteam.scale` (2; the alternative is 1, which draws a 32 px puff), `maxWisps`, `peakAt`;
  - the "found, not changed" list.

  **Stop until the user approves.**
  - If the user changes props or values, edit the Pinned values, the Props table and their tests, then re-run Task 3's or Task 5's Step 4 and this task.
  - If a prop moves next to the north-west corner, re-derive the byte-identical list in Step 1 (the views are in the committed reference trees; `$S/tools/views.py` reads the cameras).

### Task 11: Cross-render reference

**Files:** `Tests/PlazaCrossReference/mac-reference.tar.gz`.

`scripts/plaza-render-cross.sh` renders `PlazaCrossHarness.scenes` offscreen, twice for A/A, and waits for an idle machine by itself. Never run it with `PTB_PLAZA_RENDER_ONLY` set: that would write a partial reference.

- [ ] **Step 1: Check against the old reference.** Run `env -u PTB_PLAZA_RENDER_ONLY scripts/plaza-render-cross.sh --check --scratch "$S/cross"`.
  - Expected: exit 1, with `CROSS-MAC: reference is STALE:`, listing:
    - every existing scene stem as a tree change (`line N of M`). The ice layer has one node fewer and the steam layer adds nine (ruling 6);
    - the 8 new stems `(not in the reference)`: `hot-spring@10`, `hot-spring@60`, `hot-spring-night@10`, `hot-spring-summer@10`, `hot-spring-spring@10`, `hot-spring-autumn@10`, `hot-spring-winter@10` and `photo-hot-spring-winter`.
  - No existing `photo-*` stem may appear. Their views miss the spring, and a culled layer adds no photo particle.
  - If a photo stem appears, run the same `--check` at Task 1's parent in a scratch worktree. A stem that is stale there too is pre-existing; say so in the PR.
- [ ] **Step 2: Write.** Run `env -u PTB_PLAZA_RENDER_ONLY scripts/plaza-render-cross.sh --write --scratch "$S/cross"`. Expected: `wrote …/mac-reference.tar.gz (<bytes> bytes, 156 captures)` (148 today + 8).
- [ ] **Step 3: Verify.**
  - `env -u PTB_PLAZA_RENDER_ONLY scripts/plaza-render-cross.sh --check --scratch "$S/cross"`. Expected: `CROSS-MAC: reference is current (156 captures)`.
  - `swift test --filter PlazaCrossRenderCompareMacTests/testCommittedReferenceTreesAreCurrent`. Expected: PASS.
- [ ] **Step 4: Commit** `test(team): refresh the plaza cross-render reference for the hot spring`.
- [ ] **Step 5: After the push** (see below), the windows.yml `render` job must pass. On a failure:
  - run `scripts/plaza-render-cross.sh --run <run id> --scratch "$S/cross"`;
  - read `$S/cross/cross-report-<id>/`;
  - a real Windows difference goes into `docs/reference/windows-differences.md` in this PR (spec 3.1). None is expected: the tint path is `WinPlazaRenderer.swift:165`, already used by the submerged part.
- [ ] **Step 6: Clean up.** Run `git worktree remove --force "$S/ptb-render-base"`, then `git worktree prune`.

---

## After the plan (PR)

- **Before the PR:**
  - after PRs 1–3 land, merge `origin/main` into the branch;
  - if that merge changes any plaza scene, re-run Task 11;
  - re-run Task 7 Step 4's filter.
- **Prepare the PR with `prepare-pr`.**
  - Title: `feat(team): turn the right plaza pond into a hot spring`.
  - Under `UI changes`, put the Task 10 contact sheet, before and after, pushed to the PR-image gist. Label it "Sample-data render, offscreen".
  - The body names:
    - the steam file's source URL, author and SHA-256, and that the props come from `plaza-tiles.png` (already credited);
    - R2: the left and bottom ponds now alternate;
    - R7: the Sweep table, the equivalence test and the scan;
    - the nine rulings at the top of this plan and the "found, not changed" list;
    - the mixed-version behaviour (spec 8.6, the new `TEAM.md` line). Old peers ignore `isFlushed` like any unknown presence key;
    - that every cross-render tree changed (ice and steam nodes), while pixels changed only in `board-marker`.
- **Push** with `git push origin feat/plaza-hot-spring:feat/plaza-hot-spring`. Then:
  - check the windows.yml test job (the shared suites, including the new ones);
  - check the selftest job (`plaza.renderCost`, `plaza.renderCostSpring`, `plaza.idleVisible`; `package.ps1` checks `map.txt` for `plaza-steam.png`);
  - do Task 11 Step 5.
- **Release (later, not this PR):**
  - `team_docs_check.py` will require new Mac and Windows captures, because a feat commit touches `Team/Plaza/`;
  - check the `v2.5.635 이하` line against the version actually shipped, with PRs 1–3's lines.
