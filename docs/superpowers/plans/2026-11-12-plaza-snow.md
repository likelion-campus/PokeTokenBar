# Plaza Snow Days Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On snow days the team plaza turns snowy, V throws a snowball that pushes the teammate it hits the way a tackle does, and walkers leave footprints that fade.

**Architecture:** A snow day is the weather rule the plaza already has, read through `PlazaWeatherLayer`'s day cache. The snowy map comes from the existing `PlazaTileArt.mapImage`, fed with sheets that `PlazaSnowSheet` recolours at runtime using exact-colour tables. It is built once per process and swapped onto the map node, the tall grass layer, the photo and the minimap when the day changes. A snowball is a new emote kind `.snowball` that carries its direction. Every Mac draws the flight in a pooled, `dt`-driven `PlazaSnowballLayer`, and the Mac that was hit pushes itself when its ball lands. Footprints are local only: when a step ends, the scene stamps two marks into a pooled `PlazaFootprintLayer`.

**Tech Stack:** Swift 6 (CI: macos-15, Xcode 16), SpriteKit, SwiftUI, XCTest, SwiftPM.

**Spec:** `docs/superpowers/specs/2026-11-12-plaza-snow-design.md` (Korean). Section numbers below (§5.2 etc.) point into it.

## Global Constraints

- Work only in `/Users/simu/Documents/GitHub/PokeTokenBar/.worktrees/plaza-snow` (branch `feat/plaza-snow`). Never edit the main checkout or other worktrees.
- Code must compile with the CI toolchain (macos-15, Xcode 16, Swift 6.1). Use no newer language features.
- Run only one swift build or test process on this Mac at a time (memory is tight). Before every run, `pgrep -fl "swift-build|swift-test|xctest"` must print nothing.
- Every run is focused (`swift test --filter '<Class>|<Class>'`). Never run the full suite: it runs only in the release gate (lean flow).
- Tests never steal keyboard focus. That rules out window `show()`, `NSApp.activate`, `finishLaunching`, run loops and event pumping. Build controllers with `prepareScene()` and drive scenes with `update(_:)`.
- Commits are English Conventional Commits whose message ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Don't push.
- Team UI is Korean only. Korean string literals live only in `Sources/PokeTokenBar/Team/TeamLocalization.swift`; `TeamLocalizationTests` enforces this.
- A snow day is when `PlazaWeather.kind(on: now, calendar: PlazaWeather.gregorian, period: <team period>) == .snow` (§3). A hidden background does not change it.
- No new image files and no new hand-drawn art:
  - The snowy map is a colour map of the existing sheets and uses exactly the §4.2 tables.
  - The ball, the burst and the footprints use only `#F6FAFF`, `#C6DAF0` and `#8DA3BF`.
- `Sources/PokeTokenBar/Resources/Plaza/CREDITS.md` must say that the RedVoxel tall grass is recoloured on snow days and stays under CC-BY-SA 3.0. The bundled PNGs stay byte-identical.
- Wire rules:
  - No protocol version bump.
  - `TeamEmoteKind.snowball` is appended last.
  - The new `TeamEmote` field is optional and left out when nil, so older versions decode everything they decode today (they skip the snowball frame).
  - Update the pinned kind list in `TeamWireTests`.
- Treat every received value as chosen by a hostile app (`docs/reference/defect-log.md` "팀 네트워크 (피어 입력)"):
  - The direction must be one of the four.
  - The push is 1–3 tiles (`TeamEmote.pushTiles`).
  - A target must be on my plaza.
  - Make no nodes on a paused scene, and give the node pools named caps.
- The new layers follow "에너지 (상시 표시 애니메이션)": named caps, reused nodes, and time only from `update`'s `dt`. They use no timers and no `SKAction`.
- Numbers from §5 and §6:
  - The ball reaches 1–5 tiles. The receiver's line check allows up to 6 tiles.
  - It flies at 10 frames a second, one tile per frame.
  - The burst is 4 frames of 0.1 s, and its pieces spread up to 16 px.
  - The ball leaves the hand at 14 px and arcs 16 px above a straight line to the target's body (at most 24 px up), or to the ground on a miss.
  - One ball grid cell is 2 world px. The ball's shadow is 8×4 world px.
  - A footprint is 3×2 sheet px (6×4 world px), set 3 px to the side of the path.
  - A footprint stays at full opacity until 4.5 s, 0.66 until 6.5 s and 0.33 until 9 s, then disappears. At most 160 show.
  - Repeated presses wait `PlazaWindowController.emoteInterval` (0.3 s).

## Review Focus

1. **The plaza window is covered across midnight into a snow day.** The scene is paused and draws no frames. A snowball received then must still be accepted by the clock and push me at once, and the first frame after the window is uncovered must show the snowy map. Tests: Task 2 `testAPausedSceneCatchesUpOnTheFirstFrameAfterMidnight` and Task 7 `testASnowballWhileCoveredOnANewSnowDayStillPushesMe`.
2. **The window is covered while a ball is in the air.** The landing must not wait for frames that never come: every flight lands at once, the push is applied, and no nodes are left behind. Tests: Task 6 `testPausingMidFlightLandsEveryBallAtOnce` and Task 7 `testCoveringTheWindowMidFlightStillPushesMe`.
3. **The V row makes the unfolded shortcut guide taller than the smallest window.** An existing test already pins this limit for the guide without V. Test: Task 7 `testTheSnowDayGuideFitsTheSmallestWindowAndItsWidth`.
4. **The tile sheet fails to load** (the plain-grass fallback). A snow day is still a snow day (V works and the guide shows it), and the plain map stays without crashing. Test: Task 2 `testWithoutSnowArtTheDayIsSnowButTheMapStays`.
5. **The team switches the weather period while the plaza is open** (day to week). The snowy look follows at once, not at the next midnight. Test: Task 2 `testChangingThePeriodTurnsTheMapAtOnce`.

## Builder decisions (§4.5, §8 and the brief, settled here)

- **Runtime recolour, no shipped PNG.** `PlazaSnowSheet` swaps exact colours of fully opaque pixels, but only inside the sheet cells each table belongs to. The PNGs stay byte-identical, so `testTallGrassSheetIsTheUnmodifiedOriginal` keeps holding. Opaque pixels are enough: the 105 semi-transparent pixels in those cells are all dark shades in no table (`#201729`, `#1C1D26`, `#302838`).
- **Wire fields.** The new kind is `TeamEmoteKind.snowball`. The target goes in the existing `targetMemberID` (nil on a miss, `PlazaDitto.sceneKey` for the Ditto), and the push in the existing `pushTiles`. One field is new: `TeamEmote.snowballDirection: PlazaDirection?`. An unknown direction string fails decoding, so the frame is skipped. A snowball without a direction is dropped.
- **Push timing.** The hit Mac pushes itself when its ball lands (one frame per tile at 0.1 s), timed by the scene's `dt`. When the scene is paused or the flight cap is full, the landing runs at once. Pausing mid-flight lands every flight at once.
- **A hit on the Ditto's copy.** The thrower sends `.snowball` (target `PlazaDitto.sceneKey`) when it throws. When its own ball lands, it sends `.decoyFound` (target = the copied member) and calls `showDecoyFound` locally. So versions that know the Ditto but not snowballs still see the copy found, and an older host still turns the copy back.
- **A hit on the Ditto form.** The host reacts at landing through `dittoFormTackled(by:)`, and only when the thrower stands in line within 6 tiles.
- **Pools and caps.**
  - `PlazaSnowballLayer.maxFlights = 24`. Each flight has a ball, a shadow and up to 6 burst sprites, all pooled.
  - `PlazaFootprintLayer.maxFootprints = 160`; the oldest mark goes first.
- **Minimap.** The minimap draws the map image, so on snow days it shows the snowy map (`PlazaMinimapModel.snowMapImage`).
- **An obstacle or the map edge directly ahead.** V does nothing: no throw and nothing sent (see the spec notes below).
- **A target that isn't drawn on my plaza** (an unknown ID, the Ditto key with no Ditto drawn, or someone diving) is treated as a miss: the ball flies on and falls on the ground.
- **The impact star** shows on every hit (§5.2).
- **Photos.** Balls and bursts are not in photos (the spec says nothing either way); footprints are not either (§6).
- **The hidden background.** With the background hidden, balls and bursts still show, like fireworks. Footprints hide and are not stamped (§6).
- **Footprints.**
  - Marks are stamped when a step ends.
  - A step that starts or ends in water leaves none. This covers plunging in and climbing out.
  - Each mark is kept only if the tile under its centre is snow ground.

## Spec notes found while planning (reported, not changed)

- §5.2 says a ball that meets a tree bursts on "그 앞 칸". With the obstacle directly ahead, that tile is the thrower's own, so the spec leaves this case undefined. This plan decides that V does nothing then.
- §4.2 recolours the tall grass for the map only. `PlazaTallGrassLayer` also draws the front bands over characters and the rustle overlays from the same sheet, and left alone they would stay green over the snow. This plan recolours the layer too.
- §5.3's last bullet leaves the impact star open, but §5.2 already says it shows. This plan follows §5.2.
- §4.3 says photos get the snowy map automatically. They don't today: `PlazaScene.mapImage` is fixed at init. This plan makes it swappable.
- The spec header names 2.5.625 as the next version, but `v2.5.625` is already tagged. TEAM.md's note for older versions uses whatever the latest tag is at implementation time.

---

## File Structure

| File | Responsibility |
|---|---|
| Create `Sources/PokeTokenBar/Team/Plaza/PlazaSnowSheet.swift` | §4.2 colour tables, the exact-colour recolour, `PlazaSnowLook`. Pure CoreGraphics. |
| Create `Sources/PokeTokenBar/Team/Plaza/PlazaSnow.swift` | Snow ground, footprint marks and their fade. Pure. |
| Create `Sources/PokeTokenBar/Team/Plaza/PlazaFootprintLayer.swift` | Pooled, capped, `dt`-driven footprint sprites. |
| Create `Sources/PokeTokenBar/Team/Plaza/PlazaSnowball.swift` | Aim, the receiver's line check, the arc, burst pieces, ball art. Pure. |
| Create `Sources/PokeTokenBar/Team/Plaza/PlazaSnowballLayer.swift` | Pooled, capped, `dt`-driven flights and bursts; landing callbacks. |
| Modify `PlazaTileArt.swift`, `PlazaPond.swift` | Expose the sheet cells the map draws. |
| Modify `PlazaWeatherLayer.swift`, `PlazaTallGrassLayer.swift`, `PlazaWalker.swift` | Day-kind lookup, art swap, the push-step flag. |
| Modify `PlazaScene.swift` | Snow-day look, footprint stamping, snowball play, the V key. |
| Modify `PlazaWindowController.swift`, `TeamRuntime.swift` | Snow look cache, V, receiving snowballs, minimap and guide. |
| Modify `TeamWire.swift`, `TeamSession.swift`, `PlazaEmoteArt.swift`, `TeamLocalization.swift` | The new kind and field. |
| Modify `Team/UI/PlazaShortcutGuideView.swift`, `PlazaMinimap.swift`, `Team/UI/PlazaMinimapView.swift` | V row on snow days, snowy minimap. |
| Modify `Resources/Plaza/CREDITS.md`, `TEAM.md` | Credit and user docs. |

All new and modified Swift files are under `Sources/PokeTokenBar/Team/` (`Plaza/` unless shown). Tests go in `Tests/PokeTokenBarTests/`.

---

### Task 1: Snow sheets (`PlazaSnowSheet.swift`)

**Files:**
- Create: `Sources/PokeTokenBar/Team/Plaza/PlazaSnowSheet.swift`
- Modify:
  - `Sources/PokeTokenBar/Team/Plaza/PlazaTileArt.swift`: `typealias Cell`, `grassCells`, `flowerCells`, `bushCell` and `treeCell` lose `private`.
  - `Sources/PokeTokenBar/Team/Plaza/PlazaPond.swift`
  - `Sources/PokeTokenBar/Resources/Plaza/CREDITS.md`
- Test: `Tests/PokeTokenBarTests/PlazaSnowSheetTests.swift` (new), `PlazaResourcesTests.swift` (extend)

**Interfaces:**
- Produces:
  ```swift
  extension PlazaPond {
      /// Every sheet cell `shore(at:isWater:)` can return: (2,6),(3,6),(4,6),(2,7),(4,7),(2,8),(3,8),(4,8),(2,9),(3,9),(2,10),(3,10).
      static let shoreCells: [(col: Int, row: Int)]
  }
  enum PlazaSnowSheet {
      typealias Colors = [UInt32: UInt32]          // 0xRRGGBB -> 0xRRGGBB
      typealias Piece = (colors: Colors, cells: [(col: Int, row: Int)])
      static let groundColors: Colors              // [0x3ABE41: 0xC6DAF0, 0x6ADD4B: 0xE8F0FA, 0x328E41: 0xB2C7E0, 0x29973B: 0x9FC3E6, 0x315740: 0x8DA3BF]
      static let shoreColors: Colors               // groundColors + [0x266433: 0x8DA3BF]
      static let flowerColors: Colors              // [0xE8F8D0: 0xF6FAFF, 0x328E41: 0xC6DAF0, 0x60D0C0: 0x9FC3E6]
      static let bushColors: Colors                // [0x2ECA35: 0xE8F0FA, 0x62EB3D: 0xF6FAFF, 0x29973B: 0xB2C7E0]
      static let treeColors: Colors                // [0x2ECA5C: 0xE8F0FA, 0x50EB6C: 0xF6FAFF, 0x299750: 0xC6DAF0, 0x328E53: 0xC6DAF0]
      static let signColors: Colors                // [0x2ECA35: 0xE8F0FA, 0x29973B: 0xB2C7E0]
      static let tallGrassColors: Colors           // [0x99E550: 0xF6FAFF, 0x6ABE30: 0xC6DAF0]
      /// plaza-tiles.png pieces: ground on `PlazaTileArt.grassCells`, shore on `PlazaPond.shoreCells`, flowers on `flowerCells`,
      /// bush on `bushCell`, tree on the 2x2 cells from `treeCell`, sign on `signCell`. Water and lily cells are absent.
      static var tilePieces: [Piece] { get }
      /// Copy of `sheet` where, inside each piece's 16-px cells, an opaque pixel whose RGB is a key becomes its value.
      /// Same size; alpha, shapes and every other pixel unchanged.
      static func recolored(_ sheet: CGImage, pieces: [Piece]) -> CGImage
      static func tiles(_ sheet: CGImage) -> CGImage        // recolored(sheet, pieces: tilePieces)
      static func tallGrass(_ sheet: CGImage) -> CGImage    // tallGrassColors on every cell of the sheet
  }
  ```

- [ ] **Step 1: Write the failing tests** in `PlazaSnowSheetTests`:
  - `testColorTablesAreTheSpecs`: each of the seven tables equals the dictionary in the Interfaces block above (`shoreColors` included).
  - `testShoreCellsListEveryCellTheShoreRuleDraws`:
    - Feed `PlazaPond.shore(at:isWater:)` the 256 water/land patterns of the 8 neighbours around (1,1).
    - Every `.cell(col, row)` it returns is in `shoreCells`.
    - All 12 listed cells come up at least once.
  - `testRecolourSwapsOnlyListedColoursOfOpaquePixelsInsideListedCells`:
    - Build a synthetic 32×16 RGBA sheet (two cells) and call `recolored(_, pieces: [(groundColors, [(0, 0)])])`.
    - In cell (0,0): an opaque `#3ABE41` pixel becomes `#C6DAF0`. An opaque `#331F29` stays. A 50 %-alpha `#3ABE41` stays. A transparent pixel stays transparent.
    - In cell (1,0), which is not listed: an opaque `#3ABE41` stays.
  - `testSnowTilesKeepWaterLiliesAndEveryAlpha`, on the real `PlazaResources.tileSheet()`:
    - The bytes of the water cell (3,7) and the lily cells (2,0), (4,0) and (5,0) are identical before and after.
    - The alpha channel is identical over the whole sheet.
    - Grass cell (0,9) has no opaque `#3ABE41` left and does have `#C6DAF0`.
    - Tree cell (5,17) keeps its `#2D5B43` count.
    - Sign cell (34,2) keeps its `#885040` count.
  - `testSnowTallGrassKeepsTheDarkBladesAndOutline`, on the real `PlazaResources.tallGrassSheet()`:
    - No opaque `#99E550` or `#6ABE30` is left.
    - The counts of `#4B692F` and `#222034` are unchanged.
    - `PlazaTallGrassArt(sheet:)` accepts the result.
  - `PlazaResourcesTests.testCreditsNameTheTallGrassLicense`: add the needle `"snow days"`.
- [ ] **Step 2:** Run `swift test --filter 'PlazaSnowSheetTests|PlazaResourcesTests'`. Expected: build failure.
- [ ] **Step 3: Implement.**
  - Draw the sheet into RGBA8 premultiplied the way `PlazaTileArt.SheetPixels` does. For opaque pixels the premultiplied bytes are the straight colour, so compare only alpha 255. Build the result with the same bitmap info as `PlazaTileArt.Canvas.image()`.
  - Under "Tall grass" in CREDITS.md add: `- On snow days the app recolours this image at runtime (exact colour swaps, no new shapes); the recoloured image is a derivative and stays under CC-BY-SA 3.0.`
- [ ] **Step 4:** Run `swift test --filter 'PlazaSnowSheetTests|PlazaResourcesTests|PlazaTileArtTests|PlazaPondTests'`. Expected: all pass.
- [ ] **Step 5:** Commit: `feat(team): recolour the plaza sheets for snow days`.

---

### Task 2: The snowy look (scene, tall grass, controller, minimap)

**Files:**
- Modify:
  - `Sources/PokeTokenBar/Team/Plaza/PlazaSnowSheet.swift` (`PlazaSnowLook`)
  - `PlazaWeatherLayer.swift`, `PlazaTallGrassLayer.swift`, `PlazaScene.swift`, `PlazaWindowController.swift`, `PlazaMinimap.swift`
  - `Sources/PokeTokenBar/Team/UI/PlazaMinimapView.swift`
- Test: `Tests/PokeTokenBarTests/PlazaSnowSceneTests.swift` (new), `PlazaTallGrassLayerTests.swift` (extend)

**Interfaces:**
- Consumes: Task 1 `PlazaSnowSheet.tiles`, `PlazaSnowSheet.tallGrass`.
- Produces:
  ```swift
  struct PlazaSnowLook { let mapImage: CGImage; let tallGrass: PlazaTallGrassArt? }
  // PlazaWeatherLayer: `kind(at:period:)` loses `private`. It returns the cached day kind and ignores the hidden background.
  func kind(at date: Date, period: PlazaWeather.Period) -> PlazaWeather.Kind
  // PlazaTallGrassLayer (`art` becomes `private var`)
  func setArt(_ art: PlazaTallGrassArt)              // finish running rustles, clear the texture cache, re-texture every band
  func bandTexture(at p: TilePoint) -> SKTexture?    // test
  // PlazaScene (`mapImage` becomes `private(set) var`; the init image and tall grass art are the normal look)
  var snowLook: () -> PlazaSnowLook? = { nil }
  var onSnowDayChange: ((Bool) -> Void)?
  var isSnowDay: Bool { get }                        // weatherLayer.kind(at: now(), period: weatherPeriod) == .snow
  private(set) var isSnowShown: Bool                 // the day last applied by refreshSnowDay
  func refreshSnowDay()
  var shownMapImage: CGImage { get }                 // test
  // PlazaMinimapModel
  var snowMapImage: NSImage?                         // PlazaMinimapView draws `model.snowMapImage ?? mapImage`
  // PlazaWindowController
  private static var cachedSnowLook: PlazaSnowLook?? // built once per process, like `cachedTallGrass`
  private static func snowLook(for map: PlazaMap) -> PlazaSnowLook?   // nil without the tile sheet
  private func snowDayChanged(_ on: Bool)            // minimap now; the guide row in Task 7
  var minimapShowsSnow: Bool { get }                 // test
  ```
- Behaviour:
  - **`refreshSnowDay()`:**
    - `on = isSnowDay`. Return when `on == isSnowShown`.
    - When `on`: if `snowLook()` gives a look, set the map node's texture (new `SKTexture`, `.nearest`) and `mapImage` to its map, and call `tallGrassLayer?.setArt` with its tall grass when that isn't nil. When `on` is false, put back the normal look.
    - Set `isSnowShown = on`, then call `onSnowDayChange?(on)`.
  - **Who calls it:** `update` after `advanceWeather`, `weatherPeriod`'s `didSet`, and the controller.
  - **Controller `prepareScene`:**
    - Before `applySchedule()`, set `s.snowLook = { [map] in Self.snowLook(for: map) }` and `s.onSnowDayChange`.
    - After it, call `s.refreshSnowDay()` and then `snowDayChanged(s.isSnowShown)`. A reopened plaza starts from the right state.
  - **`snowLook(for:)`:** builds `PlazaTileArt.mapImage(map, sheet: PlazaSnowSheet.tiles(sheet), tallGrass: art)`, where `art = PlazaResources.tallGrassSheet().map(PlazaSnowSheet.tallGrass).flatMap(PlazaTallGrassArt.init(sheet:))`.
  - **`snowDayChanged(on)`:** `minimap.snowMapImage = on ? Self.snowLook(for: map).map { NSImage(cgImage: $0.mapImage, size: .zero) } : nil`.

- [ ] **Step 1: Write the failing tests.**
  - **Setup for `PlazaSnowSceneTests`:**
    - Add a helper `date(_ day: Int, _ h: Int, _ m: Int, _ s: Int)` for November 2026 in `PlazaWeather.gregorian`.
    - Assert as preconditions:
      - Nov 6 is a snow day, and Nov 5 and Nov 7 are not.
      - Nov 12 12:00 is `.greenLeaves` by day and `.snow` by week.
    - Scenes use `PlazaTileArt.plainGrassImage(map)` as `plain`. `snowLook` returns a second `plainGrassImage(map)` instance as `snow`; compare with `===`.
  - `testASnowDayShowsTheSnowMapUntilTheDayEnds`:
    - Nov 5 23:59:59, then `refreshSnowDay()`: `shownMapImage === plain`.
    - Nov 6 00:00:00, then `update`: `=== snow`, and `photoInput()!.mapImage === snow`.
    - Nov 6 23:59:59: still `snow`.
    - Nov 7 00:00:00, then `update`: `plain`.
    - `onSnowDayChange` saw `[true, false]`, and `snowLook` was asked once.
  - `testTheTallGrassTurnsSnowyWithTheMap`:
    - Build the scene with `tallGrass: PlazaTallGrassArt.load()`. `snowLook`'s tall grass is the recoloured art.
    - Nov 6: no image from `tallGrassLayer!.photoBands(in: <whole map>)` has an opaque `#99E550` or `#6ABE30`.
    - Nov 7: some image does (the front rows hold both colours).
  - `testAPausedSceneCatchesUpOnTheFirstFrameAfterMidnight` (Review Focus 1):
    - Pause the scene at Nov 5 23:59:59, then move the clock to Nov 6 00:00:01.
    - `isSnowDay` is true with no frame, and `shownMapImage === plain`.
    - After `isPaused = false` and one `update`: `=== snow`.
  - `testChangingThePeriodTurnsTheMapAtOnce` (Review Focus 5), at Nov 12 12:00:
    - `weatherPeriod = .week` gives `snow` with no `update`.
    - `.day` gives `plain`.
  - `testWithoutSnowArtTheDayIsSnowButTheMapStays` (Review Focus 4), with `snowLook = { nil }` on Nov 6:
    - `isSnowDay` and `isSnowShown` are true.
    - `onSnowDayChange` saw `[true]`.
    - `shownMapImage === plain`.
  - `testHidingTheBackgroundKeepsTheSnowDay`: after `setBackgroundHidden(true)` on Nov 6, `isSnowDay` and `isSnowShown` are still true.
  - `testTheMinimapShowsTheSnowMapOnSnowDays`, with controllers built like `PlazaEmoteTests.controller` but without a session, and `clock:` fixed:
    - Nov 6: `minimapShowsSnow` is true.
    - Two Nov 6 controllers give `scene!.shownMapImage` instances that are `===` (built once).
    - A Nov 7 controller's map is `!==` the snowy one and `minimapShowsSnow` is false.
  - `PlazaTallGrassLayerTests.testSetArtRetexturesTheBandsInPlace`:
    - After `setArt(<recoloured art>)`, band `a`'s z and offset are unchanged.
    - `bandTexture(at: a)!.cgImage()` has no opaque `#99E550` or `#6ABE30`.
    - A running rustle is finished (`activeRustles` is empty).
- [ ] **Step 2:** Run `swift test --filter 'PlazaSnowSceneTests|PlazaTallGrassLayerTests'`. Expected: build failure.
- [ ] **Step 3:** Implement as above.
- [ ] **Step 4:** Run `swift test --filter 'PlazaSnowSceneTests|PlazaTallGrassLayerTests|PlazaWeatherTests|PlazaPhotoTests|PlazaScheduleWiringTests|PlazaWindowTests'`. Expected: all pass.
- [ ] **Step 5:** Commit: `feat(team): turn the plaza snowy on snow days`.

---

### Task 3: Footprints

**Files:**
- Create: `Sources/PokeTokenBar/Team/Plaza/PlazaSnow.swift`, `Sources/PokeTokenBar/Team/Plaza/PlazaFootprintLayer.swift`
- Modify: `PlazaWalker.swift`, `PlazaScene.swift`
- Test: `Tests/PokeTokenBarTests/PlazaSnowTests.swift` and `PlazaFootprintTests.swift` (new), `PlazaWalkerTests.swift` (extend)

**Interfaces:**
- Consumes: Task 2 `isSnowShown`, `refreshSnowDay()`.
- Produces:
  ```swift
  enum PlazaSnow {
      static let footprintLength: CGFloat = 6, footprintWidth: CGFloat = 4, footprintSide: CGFloat = 3
      static let footprintHex: UInt32 = 0x8DA3BF
      struct Footprint: Equatable { let center: CGPoint; let alongX: Bool }   // world px, y down; 6 wide along the step
      /// Grass, flowers and shelter.
      static func isSnowGround(_ t: TilePoint, in map: PlazaMap) -> Bool
      /// Two marks per step between the tiles' foot points (`PlazaWalker.footPoint`): the left foot a quarter of the way and the right
      /// foot three quarters of the way, each 3 px off the path to its side (left of the walker = (dy, -dx) in world y-down). A mark is
      /// kept only if the tile under its centre `isSnowGround`. [] when `from` or `to` is water.
      static func footprints(from: TilePoint, to: TilePoint, map: PlazaMap) -> [Footprint]
      /// 1 below 4.5 s, 0.66 below 6.5 s, 0.33 below 9 s, then nil.
      static func footprintAlpha(age: TimeInterval) -> CGFloat?
  }
  @MainActor final class PlazaFootprintLayer: SKNode {
      static let maxFootprints = 160
      init(worldHeight: CGFloat)          // zPosition 0.04: above the map, under tall-grass overlays (0.05), shadows (0.5) and actors
      func stamp(_ marks: [PlazaSnow.Footprint])   // over the cap, the oldest goes first; nodes come from a pool
      func advance(by dt: TimeInterval)            // ages, sets alpha, recycles expired marks
      func removeAll()
      var count: Int { get }
      var alphas: [CGFloat] { get }                // test
  }
  // PlazaWalker
  var isSliding: Bool { get }             // the step under way is a push step
  // PlazaScene
  var footprintCount: Int { get }          // test
  var footprintAlphas: [CGFloat] { get }   // test
  ```
- Scene behaviour:
  - **Watching steps:**
    - Add a private `PrintWatch` beside `GrassWatch`. It remembers the step under way and whether it slides, and it returns the step that just ended unless that step slid.
    - Keep one watch for me (`walker.currentStep`, `walker.isSliding`) and one per remote (`motion.currentStep`, `remote.isBouncing`).
    - `Remote.isBouncing` is set by `applyDitto` from `shown.isBouncing`, and is false for teammates.
  - **Stamping:** in `update`, after the animations, while `isSnowShown && !isBackgroundHidden`, stamp `PlazaSnow.footprints(from:to:map:)` for every ended step. Advance the layer by `dt` on every frame.
  - **Clearing:**
    - `refreshSnowDay()` turning off calls `footprintLayer.removeAll()`.
    - `setBackgroundHidden(true)` calls `removeAll()` and hides the layer; `false` shows it again.

- [ ] **Step 1: Write the failing tests.**
  - **`PlazaSnowTests`** (real `PlazaMapData.map`):
    - `testSnowGroundIsGrassFlowersAndShelter`:
      - True for (10,10) grass, (5,4) flowers and (22,4) shelter.
      - False for (5,5) tall grass, (5,13) water, (15,4) bush, (23,4) board, (23,15) campfire, (0,0) tree and (-1,5) off the map.
    - `testAStepLeavesTwoMarksBesideThePath`:
      - (10,10)→(11,10) gives `[((344,345), true), ((360,351), true)]`.
      - (10,10)→(10,11) gives `[((339,356), false), ((333,372), false)]`.
    - `testMarksSkipTallGrassAndWater`:
      - (12,5)→(11,5) gives only `((392,191), true)`.
      - (5,12)→(5,13) and (5,13)→(5,12) give `[]`.
    - `testMarksFadeInThreeSteps`: `footprintAlpha` gives 1 at 0 and 4.49, 0.66 at 4.5 and 6.49, 0.33 at 6.5 and 8.99, and nil at 9.
  - **`PlazaWalkerTests.testIsSlidingOnlyDuringAPushStep`:**
    - After `push(.right, tiles: 2)` and `advance(0.05)`: `isSliding`.
    - After both push steps end and a pressed key starts a walk: `isWalking && !isSliding`.
    - A plunge step is not sliding.
  - **`PlazaFootprintTests`:**
    - Setup: start at (10,10), `now` Nov 6 12:00, `refreshSnowDay()`, and step frames at 1/30 s.
    - `testWalkingOnASnowDayLeavesMarksThatFadeAway`:
      - Press then release → (keyCode 124); after 0.2 s, `footprintCount == 2`.
      - At 5 s, the alphas are all 0.66.
      - At 9.3 s, the count is 0.
    - `testNoMarksOnOtherDays`: the same walk on Nov 7 leaves 0.
    - `testAPushLeavesNoMarks`: `pushMe(.right, tiles: 2)` and 1 s of frames leave 0.
    - `testAWalkingTeammateAndTheDittoLeaveMarks`:
      - A remote member moved one tile adds 2.
      - `applyDitto` moved one tile with `isBouncing: false` adds 2.
      - With `isBouncing: true` it adds 0.
    - `testTheDayEndingClearsTheMarks`: with marks shown, Nov 7 00:00 and one `update` give 0.
    - `testAHiddenBackgroundClearsAndMakesNoMarks`: hiding clears the marks, and a walk while hidden adds 0.
    - `testMarksStopAtTheCapAndReuseNodes`, on a bare `PlazaFootprintLayer`:
      - 200 single-mark stamps give `count == 160` and `children.count <= 160`.
      - `advance(by: 10)` gives 0.
      - 160 more stamps keep `children.count <= 160`.
- [ ] **Step 2:** Run `swift test --filter 'PlazaSnowTests|PlazaFootprintTests|PlazaWalkerTests'`. Expected: build failure.
- [ ] **Step 3:** Implement. The marks are `SKSpriteNode(color:size:)` in `#8DA3BF`: 6×4 along x and 4×6 along y. Place them at even world pixels.
- [ ] **Step 4:** Run `swift test --filter 'PlazaSnowTests|PlazaFootprintTests|PlazaWalkerTests|PlazaDittoSceneTests|PlazaTackleWaterTests|PlazaTallGrassSceneTests'`. Expected: all pass.
- [ ] **Step 5:** Commit: `feat(team): leave footprints in the plaza snow`.

---

### Task 4: The snowball on the wire

**Files:**
- Modify: `Sources/PokeTokenBar/Team/TeamWire.swift`, `TeamSession.swift`, `TeamLocalization.swift`, `Plaza/PlazaEmoteArt.swift`
- Test: `TeamWireTests.swift`, `TeamSessionTests.swift`, `PlazaEmoteTests.swift`, `TeamNotificationsTests.swift` (all extend)

**Interfaces:**
- Produces:
  - **`TeamEmoteKind.snowball`**, appended after `.pull`:
    - Doc comment: "눈뭉치 (V on snow days): one ball along `TeamEmote.snowballDirection`. `targetMemberID` is the member or `PlazaDitto.sceneKey` it hits, nil on a miss; `pushTiles` as for a tackle. The hit Mac pushes itself when the ball lands. Earlier versions skip it."
    - `notifiesTarget == false` and `endsSendersDance == true`.
  - **`TeamEmote.snowballDirection: PlazaDirection?`:** declared after `overDecoy`. Doc comment: "A snowball: the way it was thrown. Left out by every other kind."
  - **`TeamSession.sendEmote(..., overDecoy: Bool = false, snowballDirection: PlazaDirection? = nil)`.**
  - **Exhaustive switches:**
    - `PlazaEmoteArt.image` adds `case .snowball:` with the `.decoyTackle` drawing (it is never shown as a bubble).
    - `L.teamEmoteLabel` adds `case .snowball: "눈뭉치"`.

- [ ] **Step 1: Write the failing tests.**
  - **`TeamWireTests`:**
    - The pinned kind list ends with `"decoyTackle", "pull", "snowball"`.
    - `testWhichEmotesEndTheSendersDance`'s `ends` set gains `.snowball`.
    - `testSnowballDirectionIsOptionalOnTheWire`:
      - `TeamEmote(kind: .snowball, targetMemberID: "m", pushTiles: 2, snowballDirection: .left)` round-trips.
      - An encoded tackle has no `snowballDirection` key.
      - `{"kind":"tackle","targetMemberID":"m"}` decodes with a nil direction.
    - `testASnowballWithAnUnknownDirectionIsSkipped`: a frame rewritten to `"snowballDirection": "north"`, followed by `.profileRequest`, decodes to `[.profileRequest]` without throwing. Use the `rewritten` helper.
  - **`TeamSessionTests.testASnowballCarriesItsDirectionAndPush`:** after `a.sendEmote(.snowball, target: b, pushTiles: 3, snowballDirection: .up)`, b's `onEmote` gets kind `.snowball`, `pushTiles == 3` and `snowballDirection == .up`.
  - **Lists that sort every kind:** add `.snowball` to the message list in `PlazaEmoteTests.testEachEmoteHasArt` and to `decoyKinds` in `TeamNotificationsTests.testEmoteNoticeNamesEachKind`.
- [ ] **Step 2:** Run `swift test --filter 'TeamWireTests|TeamSessionTests'`. Expected: build failure.
- [ ] **Step 3:** Implement as above.
- [ ] **Step 4:** Run `swift test --filter 'TeamWireTests|TeamSessionTests|PlazaEmoteTests|TeamNotificationsTests|TeamLocalizationTests'`. Expected: all pass.
- [ ] **Step 5:** Commit: `feat(team): add the snowball emote to the wire`.

---

### Task 5: Snowball rules and art (`PlazaSnowball.swift`)

**Files:**
- Create: `Sources/PokeTokenBar/Team/Plaza/PlazaSnowball.swift`
- Test: `Tests/PokeTokenBarTests/PlazaSnowballTests.swift` (new)

**Interfaces:**
- Produces:
  ```swift
  struct PlazaSnowballShot: Equatable {
      enum End: Equatable { case actor(id: String?, tile: TilePoint), ground(TilePoint) }   // id nil = me
      let from: TilePoint
      let direction: PlazaDirection
      let end: End
      var endTile: TilePoint { get }
      /// One frame per tile: the Manhattan distance from `from` to `endTile`, kept within 1...PlazaSnowball.maxFrames.
      var frames: Int { get }
  }
  enum PlazaSnowball {
      static let range = 5, reach = 6, maxFrames = 6, burstFrames = 4
      static let frameDuration: TimeInterval = 0.1
      static let handHeight: CGFloat = 14, peak: CGFloat = 16, maxBodyHeight: CGFloat = 24
      static let handReach: CGFloat = 10      // the ball starts this far ahead of the thrower's feet
      static let bodyInset: CGFloat = 8       // a hit ends this far short of the target's feet
      static let cell: CGFloat = 2            // world px per grid cell
      static let shadowSize = CGSize(width: 8, height: 4)
      /// Not walkable and not water: tree, bush, board, campfire, off the map.
      static func blocksBall(_ t: TilePoint, in map: PlazaMap) -> Bool
      /// Tiles 1...range ahead. Stops before a blocking tile. The first tile holding a target (smallest ID on a tie) is the hit;
      /// otherwise the last open tile is the ground end. nil when the tile directly ahead blocks.
      static func aim(from: TilePoint, facing: PlazaDirection, targets: [String: TilePoint], map: PlazaMap) -> PlazaSnowballShot?
      /// Receiver's check: same row or column, the target lies `direction` from the thrower, distance 1...reach.
      static func hits(thrower: TilePoint, target: TilePoint, direction: PlazaDirection) -> Bool
      /// handHeight + (endHeight - handHeight)·u + 4·peak·u·(1 - u).
      static func height(at u: CGFloat, endHeight: CGFloat) -> CGFloat
      /// min(max(spriteHeight, 28)·0.5, maxBodyHeight).
      static func bodyHeight(spriteHeight: CGFloat) -> CGFloat
      /// Pieces of burst frame `step` around its centre (scene px, y up), with a glyph index into `PlazaSnowballArt.pieces`.
      static func burstPieces(step: Int, onGround: Bool) -> [(offset: CGVector, glyph: Int)]
  }
  enum PlazaSnowballArt {
      /// Adds a cell of shade ("o") in every empty cell whose left or upper neighbour is painted. Grid grows by one each way.
      static func shaded(_ grid: [String]) -> [String]
      /// The three snow flakes of `PlazaWeatherArt.grids(.snow)`, shaded, in W #F6FAFF, S #C6DAF0, o #8DA3BF. [0] is the ball.
      static func pieces() -> [CGImage]
  }
  ```
- `burstPieces` is the approved mockup's table. Write it exactly, since neither the signature nor the tests fix it:
  ```swift
  let radius: [CGFloat] = [9, 11, 14, 16], drop: [CGFloat] = [0, 1, 4, 8], glyph = [1, 0, 1, 2]
  let angles: [Double] = step == 0 ? (onGround ? [0, 45, 135, 180] : [45, 135, 225, 315])
                                   : (onGround ? [0, 45, 90, 135, 180] : [30, 90, 150, 210, 270, 330])
  // each angle a: dx = r·cos a, dy = r·sin a - drop (onGround: max(dy, 0)), glyph[step]; step 0 also adds (0, 0) with glyph 0
  ```

- [ ] **Step 1: Write the failing tests** in `PlazaSnowballTests` (real map; row 12 is open grass from x 3 to 36):
  - `testAimHitsTheFirstTargetAhead`, all from (10,12) facing `.right`:
    - Targets `["a": (14,12), "b": (12,12)]` give `.actor("b", (12,12))` with `frames == 2`.
    - `["a": (16,12)]` gives `.ground((15,12))` with `frames == 5`.
    - `["x": (10,12)]` gives `.ground((15,12))`: my own tile is not a target.
    - `["b": (12,12), "a": (12,12)]` gives `"a"`.
  - `testAimStopsBeforeObstaclesAndFliesOverWater`:
    - From (12,17) facing `.right` with `["m": (16,17)]`: `.ground((14,17))`. The bush at (15,17) stops it.
    - From (17,14) facing `.left` with no targets: `.ground((12,14))`, a water tile.
    - The same throw with `["s": (13,14)]`: `.actor("s", (13,14))`.
  - `testFacingAnObstacleOrTheEdgeThrowsNothing`: nil for (3,12) `.left`, (44,12) `.right` and (14,17) `.right`.
  - `testHitsNeedTheSameLineTheRightWayWithinSix`:
    - From (10,12) to (14,12): `.right` is true and `.left` is false.
    - (8,12)→(14,12) `.right` is true; (7,12)→(14,12) is false.
    - (10,11)→(14,12) is false, and (14,12)→(14,12) is false.
  - `testFramesAreTheTileCountFromOneToSix`: a shot from (0,0) to `.actor(nil, (0,9))` has 6 frames; to `.ground((1,0))`, 1.
  - `testTheArcStartsAtTheHandPeaksAndEndsOnTheBodyOrTheGround`:
    - `height(at: 0, endHeight: 24) == 14`, `height(at: 1, endHeight: 24) == 24`, `height(at: 1, endHeight: 0) == 0` and `height(at: 0.5, endHeight: 0) == 23`.
    - `bodyHeight` gives 14 for 0, 15 for 30 and 24 for 80.
  - `testBurstPiecesSpreadToSixteenAndStayUpOnAMiss`:
    - Step 0 has 5 pieces either way, including `(0,0)` with glyph 0.
    - Steps 1–3 have 5 pieces on the ground and 6 in the air.
    - Glyphs by step are 1, 0, 1, 2.
    - Apart from step 0's centre piece, every air piece lies on its step's circle: `hypot(dx, dy + drop[step]) == radius[step]`, at most 16.
    - Every ground piece has `abs(dx) <= 16` and `dy >= 0`.
  - `testShadedGridsAddTheShadeRightAndBelow`:
    - `[".W.", "WWW", ".W."]` → `[".Wo.", "WWWo", "oWo.", ".o.."]`
    - `["WW", "WS"]` → `["WWo", "WSo", "oo."]`
    - `["W"]` → `["Wo", "o."]`
  - `testSnowballArtUsesOnlySnowColours`:
    - Every opaque pixel of `pieces()` is `#F6FAFF`, `#C6DAF0` or `#8DA3BF`.
    - `pieces()[0]` is 4×4 and has 5 shade pixels.
- [ ] **Step 2:** Run `swift test --filter PlazaSnowballTests`. Expected: build failure.
- [ ] **Step 3:** Implement. The images go through `PlazaWeatherArt.image(_:palette:)` with the shaded grids.
- [ ] **Step 4:** Run `swift test --filter PlazaSnowballTests`. Expected: all pass.
- [ ] **Step 5:** Commit: `feat(team): add the plaza snowball rules and art`.

---

### Task 6: Snowballs in the scene

**Files:**
- Create: `Sources/PokeTokenBar/Team/Plaza/PlazaSnowballLayer.swift`
- Modify: `PlazaScene.swift`
- Test: `Tests/PokeTokenBarTests/PlazaSnowballSceneTests.swift` (new)

**Interfaces:**
- Consumes: Task 5 (all of it), and the existing `PlazaGroundShadow.image(width:height:)`.
- Produces:
  ```swift
  struct PlazaSnowballFlight {
      var start: CGPoint, end: CGPoint     // ground points, world px, y down
      var endHeight: CGFloat               // 0 on a miss
      var frames: Int
      var burst: Burst
      enum Burst { case air, ground, none }   // none: the scene splashes instead
  }
  @MainActor final class PlazaSnowballLayer: SKNode {
      static let maxFlights = 24
      init(worldHeight: CGFloat)
      /// false when `maxFlights` are already up (the caller lands it at once).
      func launch(_ flight: PlazaSnowballFlight, onLand: @escaping @MainActor () -> Void) -> Bool
      func advance(by dt: TimeInterval)
      /// Every flight lands now: its onLand runs, no burst is drawn, all nodes go back to the pools.
      func landAll()
      var flightCount: Int { get }; var nodeCount: Int { get }; var shownSpriteCount: Int { get }   // test
  }
  // PlazaScene
  var onSnowballKey: (() -> Void)?
  var snowballTargets: [String: TilePoint] { get }   // interactionTiles without members shown diving
  /// Lunges the thrower (nil = me) and flies one ball along `shot`. Draws nothing when paused or full; then `onLand` runs at once.
  func playSnowball(by thrower: String?, shot: PlazaSnowballShot, onLand: @escaping @MainActor () -> Void)
  var snowballFlightCount: Int { get }; var snowballNodeCount: Int { get }; var snowballSpriteCount: Int { get }   // test
  ```
- **Layer behaviour:**
  - **Frames:** a flight's `age` grows by `dt`, and its frame is `Int(age / 0.1 + 1e-9)`.
  - **In the air:** while `frame < frames`, the ball and shadow sit at `u = frame / frames`:
    - Ground point: `start + (end - start)·u`.
    - Ball: bottom-left at `(even(g.x - 4), even(H - g.y + height(at: u, endHeight:)))`, z `1 + g.y / H + 0.0003`.
    - Shadow: at `(even(g.x - 4), even(H - g.y - 2))`, z 0.5.
  - **Landing:** at `frame == frames`, hide the ball and shadow and run `onLand` once.
  - **Burst:** for the next 4 frames, show `burstPieces(step:onGround:)` around the centre:
    - In the air: centre `(end.x, H - end.y + endHeight)`, z 21 (over the impact star at 20).
    - On the ground: centre `(end.x, H - end.y)`, at the ball's z.
  - **Done:** after `frames + 4`, every node goes back to the pools.
  - **Snapping:** `even(v) = (v / 2).rounded() * 2`.
- **Scene behaviour:**
  - **Building the flight:**
    - `start = foot(shot.from) + d·handReach`, where `d` is the unit vector of `shot.direction` (world, y down).
    - `.actor(id, tile)`: `end = foot(tile) - d·bodyInset` and `endHeight = bodyHeight(spriteHeight: actor(id)?.characterSize.height ?? 0)`. Burst `.air`.
    - `.ground(tile)`: `end = foot(tile)` and `endHeight = 0`. Burst `.none` on water, `.ground` otherwise.
  - **On landing:** the wrapped `onLand` first plays the effects when not paused, then runs the caller's closure.
    - A hit calls `showImpact(on: id, direction:)`, extracted from `playTackle`, which now calls it.
    - A miss on water calls `pondLayer?.splash(at: tile, big: false)`. It splashes but wets nobody.
  - **Each frame:** `update` advances the layer.
  - **On pause:** `isPaused`'s `didSet` calls `snowballLayer.landAll()` when pausing.
  - **The V key:**
    - V is keyCode 9, handled with C and P in `handleKeyDown`. A plain press (no repeat, no ⌘⌃⌥) calls `onSnowballKey`.
    - Photo mode swallows V like C. An open overlay swallows it as it already does.

- [ ] **Step 1: Write the failing tests** in `PlazaSnowballSceneTests`. Build the scene the way `PlazaTackleWaterTests` does (red-rectangle frames, `pondVisuals: true`). Use me at (14,12) and member "a" at (10,12).
  - `testABallFliesATileATenthAndLandsOnce`, with the shot `(from (10,12), .right, .actor(nil, (14,12)))`:
    - At 0.35 s: 0 landings, `snowballFlightCount == 1` and `snowballSpriteCount == 2`.
    - At 0.45 s: 1 landing and `snowballSpriteCount >= 5`.
    - At 0.85 s: no flights, no sprites, still 1 landing.
  - `testAHitShowsTheImpactStarAndTheThrowerLunges`:
    - Right after the throw, `lungeOffset(memberID: "a") != .zero`.
    - After the landing, `impactCount == 1`.
  - `testAMissInTheWaterSplashesInsteadOfBursting`, with the shot `(from (19,14), .left, .ground((14,14)))`, built directly:
    - The landing frame gives `pondLayer!.dropletCount == PlazaPondLayer.smallDroplets` and draws no burst sprites.
    - Member "w" on the shore at (15,14) stays dry (`isWet(memberID: "w") == false`). The scene's own small splash would wet it.
  - `testAPausedSceneDrawsNothingAndLandsAtOnce`: with `isPaused = true`, the throw lands once at once and leaves `snowballSpriteCount == 0`, `impactCount == 0` and `children.count` unchanged.
  - `testPausingMidFlightLandsEveryBallAtOnce` (Review Focus 2): 3 shots, 0.15 s of frames, then `isPaused = true` give 3 landings, 0 flights and 0 sprites.
  - `testFlightsBeyondTheCapLandAtOnce`: `maxFlights + 5` throws leave `snowballFlightCount == maxFlights` and 5 landings at once.
  - `testNodesAreReused`: 30 throws, each run to the end, keep `snowballNodeCount <= 8`.
  - `testVIsTheSnowballKeyOutsidePhotoModeAndOverlays`:
    - keyCode 9 fires once.
    - Nothing fires with ⌘, as a repeat, with `isOverlayOpen`, or after `enterPhotoMode()`.
  - `testSnowballTargetsSkipDivers`:
    - Diving member "d" at (13,14) is absent.
    - Swimming member "s" at (12,14) is present.
    - The Ditto key is present whenever a Ditto is applied.
- [ ] **Step 2:** Run `swift test --filter PlazaSnowballSceneTests`. Expected: build failure.
- [ ] **Step 3:** Implement as above.
- [ ] **Step 4:** Run `swift test --filter 'PlazaSnowballSceneTests|PlazaEmoteTests|PlazaPhotoModeTests|PlazaCardTests|TeamHostilePeerTests'`. Expected: all pass. The last three cover the `playTackle` extraction and the paused-effects guards.
- [ ] **Step 5:** Commit: `feat(team): fly snowballs across the plaza scene`.

---

### Task 7: Throwing and being hit (controller, runtime, guide, docs)

**Files:**
- Modify:
  - `PlazaWindowController.swift`, plus `minContentSize` if needed
  - `Sources/PokeTokenBar/Team/TeamRuntime.swift`, `TeamLocalization.swift`
  - `Sources/PokeTokenBar/Team/UI/PlazaShortcutGuideView.swift`
  - `TEAM.md`
- Test: `Tests/PokeTokenBarTests/PlazaSnowballControllerTests.swift` (new). Extend `PlazaDittoControllerTests`, `TeamRuntimeTests`, `PlazaEmoteTests` and `PlazaFireworksTests`.

**Interfaces:**
- Consumes:
  - Tasks 2–6: `isSnowDay`, `snowDayChanged`, `PlazaSnowball.aim/hits`, `playSnowball`, `snowballTargets`, `onSnowballKey`, `TeamEmote.snowballDirection`.
  - Existing: `dittoFormTackled(by:)`, `showDecoyFound(from:copied:)`, `canBePushed`, `lastEmoteAt`.
- Produces:
  ```swift
  // PlazaWindowController
  func showSnowball(from sender: String, on target: String?, tiles: Int, direction: PlazaDirection?)   // the runtime calls it
  var shortcutsShowSnowball: Bool { get }                                                               // test
  // PlazaShortcutGuide (`entries` stays as entries(isSnowDay: false))
  static func entries(isSnowDay: Bool) -> [(key: String, label: String)]   // inserts ("V", plazaShortcutSnowball) right after "C"
  // PlazaShortcutGuideModel
  var isSnowDay = false
  // TeamLocalization
  var plazaShortcutSnowball: String { "눈뭉치" }
  ```
- Behaviour:
  - **V (`handleSnowballKey`, wired as `s.onSnowballKey`):**
    - Do nothing unless all of these hold:
      - `scene.isSnowDay`.
      - Not focusing.
      - `scene.canWalk`, so not an egg.
      - `!scene.isMeInWater` (not swimming, not diving).
      - `PlazaSnowball.aim(from: walker.tile, facing: walker.facing, targets: scene.snowballTargets, map:)` is not nil.
      - `emoteInterval` has passed since `lastEmoteAt` (shared with tackle and greet).
    - Then stop my dance, `sendEmote(.snowball, target: <hit id>, pushTiles: TeamEmote.pushTiles(evolutionStage()), snowballDirection: facing)`, and `scene.playSnowball(by: nil, shot:)`. I don't turn.
    - For the Ditto key, note `shownDitto?.decoyOf` at the throw. When my ball lands:
      - **The copy:** if the noted member is still `shownDitto?.decoyOf`, send `sendEmote(.decoyFound, target: copied)`, then call `showDecoyFound(from: myID, copied:)`.
      - **The Ditto form:** if `shownDitto?.isDecoy == false`, call `dittoFormTackled(by: myID)`.
    - Any other target: the landing does nothing here.
  - **`showSnowball(from:on:tiles:direction:)`:**
    - **Drop the frame** unless there is a scene, `direction` is not nil, `scene.isSnowDay` holds, and `scene.memberTiles[sender]` is known.
    - **Resolve the target:**
      - Me: my tile, unless I'm diving.
      - `PlazaDitto.sceneKey`: `scene.dittoTile`.
      - A key of `scene.memberTiles` not shown diving: its tile.
      - Anything else: a miss.
    - **Build the shot:** a hit gives `.actor`. A miss is `PlazaSnowball.aim(from: senderTile, facing: direction, targets: [:], map:)`; drop the frame if that is nil.
    - `hit = target resolved && PlazaSnowball.hits(thrower: senderTile, target: targetTile, direction:)`.
    - **On landing:**
      - Me, `hit` and `canBePushed`: `scene.pushMe(direction, tiles: tiles)`.
      - The Ditto key, `hit` and `shownDitto?.isDecoy == false`: `dittoFormTackled(by: sender)`.
  - **`TeamRuntime.onEmote`:** route `.snowball` to `plaza?.showSnowball(from: memberID, on: emote.targetMemberID, tiles: TeamEmote.pushTiles(emote.pushTiles), direction: emote.snowballDirection)`, then return.
  - **Guide:** `snowDayChanged(_:)` also sets `shortcutModel.isSnowDay = on`, and the view lists `Self.entries(isSnowDay: model.isSnowDay)`. If the snow-day guide test fails, raise `minContentSize.height` to the smallest value that passes. Update `PlazaRosterTests`' capacity assertion only if it changes, and say so in the commit body.
  - **TEAM.md**, written in the table's Korean style:
    - **A V row after C:**
      - Snow days only. The ball goes the way you face, and you don't turn.
      - It hits the first teammate or Ditto within 5 tiles, never one on your own tile. It flies over divers and hits swimmers.
      - Trees, bushes, the board and the fire stop it in front of them; a tree right ahead means nothing is thrown. It flies over water.
      - A miss bursts on the ground, or splashes on water.
      - A hit shows the impact star and pushes like a tackle: 1–3 tiles by evolution stage, into the pond from the shore, and through the water for swimmers.
      - You can't throw while swimming, diving, focusing, as an egg, or in photo mode.
      - Focusing teammates and teammates with the campfire menu open are not pushed.
      - The Ditto reacts as to a tackle; a copy is found even from afar.
      - Teammates on `<latest tag>` 이하 don't see the ball and aren't pushed.
    - **The weather row:**
      - On snow days the map, trees, bushes and tall grass, and the minimap with them, turn snowy, for teammates on the same version.
      - Walkers leave footprints that fade over 9 s. Footprints don't show with the background hidden and aren't in photos.
    - **The P row:** V does nothing in photo mode, like C.
    - `<latest tag>` is `git tag --list 'v2.5.*' --sort=-v:refname | head -1` at the time (now v2.5.625).

- [ ] **Step 1: Write the failing tests.**
  - **`PlazaSnowballControllerTests`:**
    - **Setup:**
      - Copy the harness from `PlazaEmoteTests` (`node`, `controller` with `clock: { [unowned self] in now }`, `connect`, `settle`).
      - Teammates get tiles through `updatePlazaPosition`.
      - Snow day: Nov 6 12:00. Other day: Nov 7 12:00.
      - `lastTile(validIn:)` refuses water, so to get into the pond, start at (15,14), `scene.face(.left)`, press Z (keyCode 6) and run 0.5 s of frames. I then swim at (14,14), and a second Z dives.
    - `testVThrowsAtTheFirstTeammateAheadAndSendsIt`:
      - Me at (10,12) facing `.right`, b at (14,12), evolution stage 2. Press V.
      - b records `.snowball` with target b, `pushTiles == 2` and `snowballDirection == .right`.
      - `scene.snowballFlightCount == 1`.
    - `testVWithNobodyAheadSendsNoTarget`: with b at (10,8), the target is nil.
    - `testVDoesNothingOffSnowDaysOrWhenICannotThrow`: nothing is sent and no flight starts in any of these cases:
      - Nov 7.
      - Focusing (`startFocus(minutes: 25)`).
      - Swimming at (14,14).
      - An egg (`speciesID: nil`).
      - Facing the tree at (2,12) from (3,12).
    - `testVFollowsTheDay`:
      - On Nov 6 23:59:59, V sends and `shortcutsShowSnowball` is true.
      - Move the clock to Nov 7 00:00:00 and run one `scene.update`. Now V sends nothing and the row is hidden.
    - `testVIsLimitedLikeTheOtherKeys`: two V presses 0.29 s apart send one; a third at 0.31 s sends a second.
    - `testAHitPushesMeWhenTheBallLands`:
      - Me at (14,12), b at (10,12). Call `showSnowball(from: b, on: me, tiles: 2, direction: .right)`.
      - Before 0.4 s of frames, my tile is still (14,12).
      - After 1.2 s, it is (16,12).
    - `testAHitFromOutOfLineOrTooFarOnlyBursts`: in each case my tile stays and `impactCount` goes up by one:
      - b at (7,12).
      - b at (10,11).
      - b at (10,12) with direction `.left`.
    - `testAFocusingOrMenuOpenMeIsNotPushed`.
    - `testAHitOnTheShoreDropsMeIntoThePond`: me at (15,14), b at (18,14), `.left` → I end at (14,14) and `scene.isMeInWater`.
    - `testASwimmerIsPushedThroughTheWater`: me swimming at (14,14), b at (18,14), `.left` → (13,14).
    - `testADivingMeIsPassedOver`: diving at (14,14) with b at (18,14), my tile stays and `impactCount == 0`.
    - **Frames only a modified app sends:**
      - `testASnowballWithoutADirectionDoesNothing`: no flight and no push.
      - `testAnUnknownOrHugeTargetFliesAsAMiss`: with a target of 10,000 × "x": 1 flight, no push, no impact.
      - `testSnowballsOffSnowDaysAreDropped`.
      - `testAFloodOfSnowballsStaysUnderTheCap`: 500 calls leave `snowballFlightCount <= PlazaSnowballLayer.maxFlights` and `snowballNodeCount <= maxFlights * 8`.
    - `testASnowballWhileCoveredOnANewSnowDayStillPushesMe` (Review Focus 1):
      - Start the clock at Nov 5 23:59:59 and call `setRendering(visible: false)`.
      - Move the clock to Nov 6 00:00:01. b sends an in-line ball.
      - I'm pushed with no frame, and `snowballNodeCount == 0`.
    - `testCoveringTheWindowMidFlightStillPushesMe` (Review Focus 2): receive a ball, run 0.15 s of frames, then `setRendering(visible: false)`. I'm pushed at once.
  - **`PlazaDittoControllerTests`** (its harness, with `clock:` on Nov 6; record the host's emotes through `onEmote`):
    - `testASnowballRevealsTheCopyWhenItLands`:
      - Host h shows a copy of m 3 tiles to my right, and I face right and press V.
      - h has received `.snowball` with target `plaza-ditto`, and no `.decoyFound` yet.
      - After 0.5 s of my scene: h receives `.decoyFound` with target m, `shownDitto?.isDecoy == false`, and the banner reads `"나님이 메타몽을 찾았어요!"`.
    - `testASnowballFromAfarTurnsTheHostsDittoFormIntoTheThrower`:
      - Set up with `hostingDittoForm()`. m stands on ground 2–6 tiles from the Ditto on its row or column; call `showSnowball(from: m, on: key, tiles: 1, direction: <toward the Ditto>)`.
      - After the landing, `shownDitto?.decoyOf == m.id`.
      - Out of line, the form stays.
  - **`TeamRuntimeTests.testSnowballReachesThePlazaAndPushesAtMostThreeTiles`**, with the `testStrongerTacklePushesMeSeveralTiles` setup on Nov 6:
    - Peer a, in line 1 tile to my left, sends `TeamEmote(kind: .snowball, targetMemberID: me, pushTiles: 99, snowballDirection: .right)`.
    - After landing frames, I am exactly 3 tiles right.
  - **`PlazaEmoteTests.testShortcutGuideAddsVOnSnowDays`:**
    - `entries(isSnowDay: true)` keys equal the current list with `"V"` after `"C"`, and the labels gain `"눈뭉치"` in the same place.
    - The keys are unique.
    - `entries(isSnowDay: false)` equals `entries`.
  - **`PlazaFireworksTests.testTheSnowDayGuideFitsTheSmallestWindowAndItsWidth`** (Review Focus 3): `guideSize(snowDay: true)` passes both existing limits. `guideSize` gains a `snowDay` parameter that sets the model.
- [ ] **Step 2:** Run `swift test --filter 'PlazaSnowballControllerTests|TeamRuntimeTests'`. Expected: build failure.
- [ ] **Step 3:** Implement as above.
- [ ] **Step 4:** Run `swift test --filter 'PlazaSnowballControllerTests|PlazaDittoControllerTests|TeamRuntimeTests|PlazaEmoteTests|PlazaFireworksTests|PlazaRosterTests|PlazaFocusTests|TeamLocalizationTests'`. Expected: all pass.
- [ ] **Step 5:** Commit: `feat(team): throw snowballs with V on snow days`.

---

### Task 8: Branch check (fault injection and coverage)

- [ ] **Step 1: Fault injection.** Put each fault in by hand, run the owning focused filter, see it fail, then revert it. Record the results for the PR body.
  1. `recolored` ignores the cell bounds → `PlazaSnowSheetTests`.
  2. `refreshSnowDay` doesn't swap the tall grass art → `PlazaSnowSceneTests`.
  3. `weatherPeriod`'s `didSet` doesn't call `refreshSnowDay` → `testChangingThePeriodTurnsTheMapAtOnce`.
  4. `PrintWatch` stamps sliding steps → `testAPushLeavesNoMarks`.
  5. `PlazaFootprintLayer` ignores its cap → `testMarksStopAtTheCapAndReuseNodes`.
  6. `hits` ignores the direction → `testHitsNeedTheSameLineTheRightWayWithinSix` and `testAHitFromOutOfLineOrTooFarOnlyBursts`.
  7. The receiver pushes on receipt instead of landing → `testAHitPushesMeWhenTheBallLands`.
  8. `isPaused`'s `didSet` doesn't call `landAll` → `testPausingMidFlightLandsEveryBallAtOnce` and `testCoveringTheWindowMidFlightStillPushesMe`.
  9. The thrower sends `.decoyFound` at the throw → `testASnowballRevealsTheCopyWhenItLands`.
  10. `showSnowball` skips the snow-day check → `testSnowballsOffSnowDaysAreDropped`.
  11. The landing push ignores `canBePushed` → `testAFocusingOrMenuOpenMeIsNotPushed`.
- [ ] **Step 2: Coverage.**
  - Run `swift test --enable-code-coverage --filter 'PlazaSnow|PlazaFootprint|PlazaSnowball'`.
  - Find the profile and binary the way `scripts/test-gate.sh` does: `default.profdata`, and `PokeTokenBarPackageTests` outside `*.dSYM`.
  - Run `llvm-cov show <bin> -instr-profile=<profdata> <file> --show-regions` for the five new files, and for the new parts of `PlazaScene.swift` and `PlazaWindowController.swift`.
  - Every `^0` in a new branch either gets a test or a one-line reason in the PR body.
- [ ] **Step 3:** If tests were added, run their filter and commit: `test(team): cover the snow-day branches`.

---

### Task 9: PR images (temporary offscreen render, deleted afterwards)

- [ ] **Step 1: Write the render test.** Write `Tests/PokeTokenBarTests/ZZSnowRender.swift`. Never commit it.
  - Skip unless `PTB_ZZ_DIR` is set.
  - Render through `SKRenderer` into a Metal texture: no windows and no `show()` (memory "offscreen-plaza-render").
  - Use sample data only. Nicknames: 지아, 하준, 서연, 도윤. Sprites come from the local cache `~/Library/Application Support/PokeTokenBar/sprites`, or coloured blocks when it is missing.
  - Get the real snow look through `PlazaSnowSheet` and the scene's `snowLook`. Fix the clock to Nov 6 12:00 (snow) or Nov 8 12:00 (green leaves), and set `backingOverride = 1`.
  - `SKAction`s don't run under the offscreen renderer, so drive the impact star's scale and fade by hand. Use the numbers in `playTackle`: 0.6→1.4 over 0.14 s, then fade over 0.22 s after 0.12 s.
  - Label each image "Sample-data render".
- [ ] **Step 2: Render.** Run `PTB_ZZ_DIR=<scratch>/snow-pr swift test --filter ZZSnowRender`, after the `pgrep` check. `<scratch>` is the executor's scratchpad, e.g. `/private/tmp/claude-501/-Users-simu-Documents-GitHub-PokeTokenBar/565430de-c0b7-4604-80e8-d6f04edc0447/scratchpad`. It writes:
  1. The whole map before and after (weather particles hidden): `map-before.png`, `map-after.png`.
  2. The default 960×640 window at zoom 2 with four members (tall grass band, shore, board, campfire): `window-before.png`, `window-after.png`.
  3. A hit at 4 tiles: `snowball-hit.gif`, plus key frames for the throw, the flight and the burst with impact and push.
  4. A miss on the ground and a miss into the pond: `snowball-miss.gif`, `snowball-water.png`.
  5. Footprints at about 0.5 s and 5 s: `footprints.gif`, `footprints-fresh.png`, `footprints-fading.png`.
  6. The shortcut guide on other days and on snow days, through `ImageRenderer`: `guide-before.png`, `guide-after.png`.
  7. The minimap on a snow day, through `ImageRenderer` of `PlazaMinimapView` with `fixedDate`: `minimap-after.png`.
- [ ] **Step 3: Clean up.**
  - Delete `ZZSnowRender.swift`.
  - `git status --short` shows no test file.
  - List the PNG and GIF paths for the PR step. Uploading them and preparing the PR (merge `origin/main`, the `prepare-pr` skill) are outside this plan.

---

## Self-review

- **Spec coverage:**

  | Spec | Where it's covered |
  |---|---|
  | §3 snow day and day change | Tasks 2, 3 and 7 |
  | §4.1–4.3 recolour, what changes, photo | Tasks 1 and 2 |
  | §4.4 falling snow | Accepted as is: no task |
  | §4.5 licence | Task 1 |
  | §4.6 build once, swap only on change | Task 2 |
  | §5.1 when V works, rate limit, dance, guide | Tasks 6 and 7 |
  | §5.2 path, look and timing | Tasks 5 and 6 |
  | §5.3 push, pond, focus, Ditto | Task 7 |
  | §5.4 wire and hostile frames | Tasks 4 and 7 |
  | §6 footprints | Task 3 |
  | §7 success | Task 9 images |
  | §8 required tests: day boundary | Tasks 2, 3 and 7 |
  | §8 required tests: tackle branches | Task 7 |
  | §8 required tests: modified frames | Tasks 4 and 7 |
  | §8 required tests: covered window | Tasks 6 and 7 |

- **Type consistency:** these names are shared across tasks, and each is defined once in the Interfaces blocks:
  - `PlazaSnowLook`, `isSnowShown`, `refreshSnowDay()`, `snowDayChanged(_:)`
  - `PlazaSnowballShot.End.actor(id:tile:)`
  - `PlazaSnowballLayer.maxFlights`, `PlazaFootprintLayer.maxFootprints`
  - `snowballDirection`, `showSnowball(from:on:tiles:direction:)`
- **Proportion:** code appears only for the interfaces and for the burst table, which the tests don't fix.
