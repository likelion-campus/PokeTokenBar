# Plaza Season Art (PR 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Each plaza season throws its own open-licence ball picture, a burst never scatters the ball picture, and autumn turns olive, red, orange and yellow instead of "just yellow", while the summer, winter and spring maps stay pixel for pixel the same.

**Architecture:**
- **Ball and burst split** (`PlazaSnowball.swift`, pure). `PlazaSnowballArt.art(season, ball:)` returns `Art { ball, burst }`. `burstPieces` glyph numbers index `burst` only, so a burst can no longer draw the ball (spec R4).
- **Ball files.** The scene loads one file per season once per process (`PlazaResources.ballName`). A missing file falls back to that season's grid ball, so all code lands before the art does.
- **Autumn** (`PlazaSeasonSheet.swift`, `PlazaTileArt.swift`):
  - a new exact-colour table, with lily pads added;
  - three tree colourings, picked per tree by the existing `Noise` (salt 3);
  - one shared `PlazaSeasonSheet.look(...)` that builds a season's map and tall grass. The controller and the three test copies of its builder call it.
- **No wire change, no new key, no per-frame work.** Windows draws the same node tree. The cross-render reference pins both systems.

**Tech Stack:** Swift 6, the shared plaza node tree (SpriteKit on the Mac, Direct2D on Windows), XCTest, the offscreen `SKRenderer` harness (`PlazaOffscreenRenderer`).

**Spec:** `docs/superpowers/specs/2026-11-21-plaza-seasons-and-interactions-design.md` (Korean). It is binding. This plan implements sections 4 and 5, the shared rules in 3 and the per-PR duties in 11–12. Read 0 (R4, R6) first.

## Conflicts with the spec

The pixel counts come from reading `plaza-tiles.png` / `plaza-tallgrass.png` with PIL. Every ruling is a starting value the user tunes in Task 5, like the rest of 5.2.

1. **The bush cell has a dark green the bush row doesn't map.** Cell (2,14) holds `#2D5B3F` (33 px). The spec's own 5.4 test ("덤불 칸에 여름 초록이 한 픽셀도 남지 않는다") would fail. **Ruling:** add `#2D5B3F→#4E1A12` (the maple row's darkest) to the autumn bush row.
2. **The tall-grass tiles the plaza uses have a dark green the 풀숲 row doesn't map.** Sheet cols 0–2, rows 6–8 hold `#4B692F` (518 px). The same test would fail. **Ruling:** add `#4B692F→#5E4220` (a dark dry brown below `#9A6A2C`).
3. **The sign cell has no `#62EB3D`.** The existing guard in `testSpringAndAutumnRecolourTheSheetAndSummerLeavesItAlone` requires every new colour of a piece to appear. So the sign piece carries only `#2ECA35→#B4462A` and `#29973B→#7E3020`. It looks the same as the spec's row.
4. **The render set as the spec lists it can't show what PR 1 changes.**
   - The throwing scenes capture frames 5, 12 and 20, all before the first ball lands. Re-shooting `water-balloon` would change nothing, and the R4 fix would have no render.
   - The season scenes look at (19,10). Every tree stands on the border, outside that view.
   - **Ruling:**
     - add captures 26 and 32 (inside the bursts) to all four throwing scenes;
     - add `summer` (the centre view, for "beside summer");
     - add `summer-edge`, `spring-edge` and `autumn-edge` (zoom 1 at the top-left corner, where trees, tall grass, flowers and the left pond's lily pad are).
   - The edge scenes also pin the tree mix across systems.

Found and **not** changed. These are out of PR 1's scope, so report them to the user with the Task 5 renders:
- The tall-grass rustle leaves (`PlazaTallGrassArt.leaves`) are code-drawn in fixed `#99E550` and `#6ABE30`, so they are green in autumn and winter too.
- Winter keeps `#2D5B3F` in bushes and `#4B692F` in tall grass, because winter must not change.
- Spring keeps green tree bottoms (5.3).

## Global Constraints

**Workspace**
- Work only in `.worktrees/plaza-ideas` on `feat/plaza-season-art`. Never touch the main checkout.
- Never use a bare `git stash`.
- Pass `--repo likelion-campus/PokeTokenBar` to every `gh` command.

**Machine**
- One `swift build`/`swift test` at a time. `pgrep -x swift-build; pgrep -x swift-test; pgrep -x xctest` must print nothing first.
- Run filtered suites only (`swift test --filter …`).
- Never open a window, activate the app or steal focus. Never set `PTB_LIVE_WINDOW_TESTS=1`.
- Renders are offscreen only: `SKRenderer` into a Metal texture. The two scripts below need the GPU, not a window or focus.
- Render scratch directories live outside the repo (`$S` = `<your session scratchpad>/season-art`).

**Shared code**
- Everything changed under `Sources/PokeTokenBar/Team/Plaza/` is shared with Windows: no Apple-only import, no `#if os`.
- New tests go into existing shared files, except the `+Mac` files already listed in `Tests/PokeTokenBarTests/mac-only.txt`.
- A test method on the main actor is `async` (`SharedSourcesScanTests`).

**Art (spec 3.2)**
- Only artist-made open-licence files. No code-drawn or generated stand-ins.
- Files go in exactly as downloaded. At runtime only a crop and exact colour swaps are allowed.
- Integer scale, nearest sampling.
- **Wire:** none. `TeamWire` stays untouched and `protocolVersion` stays 1.

**Expected red test**
- `PlazaCrossRenderCompareMacTests/testCommittedReferenceTreesAreCurrent` fails from Task 1 until Task 6 rewrites the reference.
- Every other filtered suite named in a task must pass at that task's commit.

**Defect protocol**
- R4 is a real defect. Task 2 does the injection check, the sweep and a `defect-log.md` entry.
- New branches get a `--show-regions` look for `^0` (Task 3, step 9).

**Language**
- Commits are English Conventional Commits. Each ends with the line `Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>`.
- `TEAM.md` text is Korean in its current tone.
- New code comments follow the surrounding file (these plaza files comment in Korean).

## Pinned values

```swift
// PlazaResources
static let snowballName = "plaza-snowball", petalBallName = "plaza-petal-ball", leafBallName = "plaza-leaf-ball"   // png
static func ballName(_ season: PlazaSeason) -> String   // winter snowball, spring petal ball, summer waterBalloonName, autumn leaf ball

// PlazaSnowballArt
static func ballScale(_ image: PlazaImage) -> CGFloat  // image.height <= 10 ? 2 : 1  (spec 4.2: 12–20 world px, 1 or 2 px a pixel)
// burst: always 3 pieces at PlazaSnowball.cell (4) world px a pixel:
//   winter, summer: the three snow grids, shaded, in palette(season)   (today's pieces, unchanged)
//   spring: images(.petals) -> [p[0], p[1], p[0]]   autumn: images(.leaves) -> [l[0] orange, l[2] red, l[4] yellow]
// fallback ball (no file): today's grid ball, shaded snow grid 0 in palette(season), scale 4

// Autumn (spec 5.2 verbatim + rulings 1–2); sign per ruling 3
ground (PlazaTileArt.grassCells + PlazaTileArt.lilyCells): 3ABE41→8E9A44, 6ADD4B→A8B052, 328E41→6E7634, 29973B→6E7634, 315740→4A4626
shore  (PlazaPond.shoreCells): ground + 266433→4A4626
flowers(PlazaTileArt.flowerCells): 328E41→6E7634, E8F8D0→F6E7B0, 60D0C0→D98A2A
bush   (PlazaTileArt.bushCell): 2ECA35→B4462A, 62EB3D→D86A34, 29973B→7E3020, 2D5B3F→4E1A12
sign   (PlazaTileArt.signCell): 2ECA35→B4462A, 29973B→7E3020
tall grass (whole plaza-tallgrass sheet): 99E550→C8A050, 6ABE30→9A6A2C, 4B692F→5E4220
trees  (tree cell (5,16) 2×2, crop rect x 80, y 256, 32×32), keys 2ECA5C, 50EB6C, 299750, 328E53, 2B7D4A, 2D5B43:
  maple  → C8402A, E86A3A, 8E2A1C, 7A2418, 6A2016, 4E1A12
  orange → E07A2A, F2A03C, A8501A, 96441A, 7E3A16, 5A2A10
  ginkgo → D9A72A, F2C840, A0741A, 8C6418, 74521A, 523A12
tree pick: Noise(top-left tile of the tree).below(count, 3); index 0 maple, 1 orange, 2 ginkgo
```

Render scenes after Task 1:
- **New:** `summer`, plus `summer-edge`, `spring-edge` and `autumn-edge` (zoom 1, me (4,4), no crowd, capture 10).
- **New:** `petal-balls` (spring) and `leaf-balls` (autumn).
- **Throwing captures:** `[5, 12, 20, 26, 32]` for `snowballs`, `water-balloon`, `petal-balls` and `leaf-balls`.

From the driver (launch in `step(f)`, age `(f − launch + 1)/60` s, 0.1 s a frame), all three bursts are under way at 26 and 32. At 26 they are at steps 0/1/0, at 32 at steps 1/2/1. Steps 0 and 1 are the ones that drew glyph 0.

## Review Focus

1. **The season flips while a ball flies or bursts.** This happens at midnight on `auto`, or when a teammate changes the season. The ball and the pieces switch to the new season's art on the next frame, with no crash and no index past the new burst list. Covered by Task 2, `testASeasonChangeMidBurstRedrawsWithTheNewPieces`.
2. **Windows decodes a new ball file differently, or not at all.** It must draw the Mac's pixels, not quietly fall back to the grid ball. Covered by Task 4 (the files join `PlazaDecodeGoldens.art`, which the Windows decoder tests and selftest compare) and Task 6 (the Windows `render` job).
3. **A delivered file is outside the 12–20 px band, or is a sheet.** It must still fly 12–20 world px high at an integer scale and show one cell. Covered by Task 4, `testEverySeasonThrowsItsOwnBundledPicture`, and the conditional crop step.
4. **Tall grass drawn over a character in autumn.** The front and top slices come from `look.tallGrass`, so they must be the dried art with no green blade. Covered by Task 3, `testAutumnLeavesNoSummerGreen`, which includes the used tall-grass cells.
5. **A plaza opened straight into a season other than summer**, with no season change after open. The scene starts with summer art, so the first ball thrown must already be that season's. Covered by Task 2, `testEachSeasonThrowsItsBundledPictureOrItsGrid`: its first round is the never-chosen winter.

---

### Task 1: Baselines (pinned looks, render scenes)

**Files:**
- Modify: `Tests/PokeTokenBarTests/PlazaSeasonTests+Bundled.swift`
- Modify: `Tests/PokeTokenBarTests/PlazaRenderScenes.swift:299-306` (season builder), `:440-461` (throwing), `:509`, `:579`

**Interfaces:**
- Produces:
  - `func bundledLook(_ season: PlazaSeason) throws -> (map: PlazaImage, grass: PlazaImage)` in `PlazaSeasonTests` (Task 3 swaps its body);
  - `static let pinnedLooks: [PlazaSeason: (map: String, grass: String)]`;
  - the scene names above.

- [ ] **Step 1: Write the pinning test.**
  - `bundledLook` copies today's construction exactly:
    - summer: `PlazaTileArt.mapImage(PlazaMapData.map, sheet: sheet, tallGrass: PlatformPlaza.tallGrassArt())`, with grass = the tall-grass sheet;
    - spring and winter: `PlazaWindowController.seasonLook`'s two lines (`PlazaSeasonSheet.tallGrass` → `PlazaTallGrassArt(sheet:)` → `mapImage(map, sheet: PlazaSeasonSheet.tiles(sheet, season:), tallGrass:)`), with grass = `PlazaSeasonSheet.tallGrass(grassSheet, season:)`.

```swift
func testSummerWinterAndSpringLooksAreUnchanged() async throws {
    for season in [PlazaSeason.summer, .winter, .spring] {
        let look = try bundledLook(season)
        let map = PlazaParityGoldens.sha256Hex(look.map.pixels.bytes), grass = PlazaParityGoldens.sha256Hex(look.grass.pixels.bytes)
        XCTAssertEqual(map, Self.pinnedLooks[season]?.map, "\(season) map \(map)")
        XCTAssertEqual(grass, Self.pinnedLooks[season]?.grass, "\(season) grass \(grass)")
    }
}
```
- [ ] **Step 2: Run** `swift test --filter PlazaSeasonTests/testSummerWinterAndSpringLooksAreUnchanged`. Expected: FAIL with six hashes in the messages (`pinnedLooks` is empty).
- [ ] **Step 3: Paste** the six hashes into `pinnedLooks` and run again. Expected: PASS. These come from the unchanged code; do not take them from any later commit.
- [ ] **Step 4: Injection.** Change spring's `0xF8BBCF` to `0xF8BBD0` in `PlazaSeasonSheet.tilePieces` and run. Expected: FAIL on `spring map` only. Revert the change, then run. Expected: PASS.
- [ ] **Step 5: Add the scenes.**
  - `season("summer", .summer)` goes before `season("spring", .spring)`.
  - Add a builder `edge(_ name: String, _ choice: PlazaSeasonChoice)`:
    - capture `[10]`;
    - `Options` with `season = choice`, `zoom = 1`, `me = TilePoint(x: 4, y: 4)`;
    - no `put`.
  - Add `edge("summer-edge", .summer)`, `edge("spring-edge", .spring)` and `edge("autumn-edge", .autumn)` after `winter-snow`.
  - `throwing` captures become `[5, 12, 20, 26, 32]`.
  - Add `throwing("petal-balls", choice: .spring)` and `throwing("leaf-balls", choice: .autumn)` next to the other two.
- [ ] **Step 6: Run** `swift test --filter PlazaCrossRenderCompareMacTests/testCommittedReferenceTreesAreCurrent` (headless, no GPU). Expected: FAIL. The stale list is exactly these 19 stems, each marked `(not in the reference)`, and nothing else:
  - `summer@10`, `summer@60`;
  - `summer-edge@10`, `spring-edge@10`, `autumn-edge@10`;
  - `snowballs@26`, `snowballs@32`, `water-balloon@26`, `water-balloon@32`;
  - `petal-balls@{5,12,20,26,32}` and `leaf-balls@{5,12,20,26,32}`.
- [ ] **Step 7: Commit** `test(team): pin the summer, winter and spring plaza looks and add season art scenes`. This commit is the "before" base for Task 5.

### Task 2: The ball and its burst are separate (fixes R4)

**Files:**
- Modify:
  - `Sources/PokeTokenBar/Team/Plaza/PlazaSnowball.swift:79-80`, `:97-138`
  - `Sources/PokeTokenBar/Team/Plaza/PlazaSnowballLayer.swift:32-58`, `:67-77`, `:130-146`
  - `Sources/PokeTokenBar/Team/Plaza/PlazaResources.swift:41`
  - `Sources/PokeTokenBar/Team/Plaza/PlazaScene.swift:293-296`, `:434-435`, `:2004-2005`, `:2022`
  - `docs/reference/defect-log.md`: add an entry under `## 표시·UI`
- Test:
  - `Tests/PokeTokenBarTests/PlazaSnowballTests+Pixels.swift`
  - `Tests/PokeTokenBarTests/PlazaSeasonTests.swift:79-101`
  - `Tests/PokeTokenBarTests/PlazaSeasonTests+Bundled.swift:6-15`
  - `Tests/PokeTokenBarTests/PlazaArtParityPixelArtTests.swift:133-143` (Mac only)

**Interfaces:**
- Produces:
  - In `PlazaSnowballArt`:
    - `struct Art { let ball: Piece; let burst: [Piece] }`, where `burst.count == 3`;
    - `static func art(_ season: PlazaSeason = .winter, ball: PlazaImage? = nil) -> Art`;
    - `static func ballScale(_ image: PlazaImage) -> CGFloat`.
  - `pieces(_:balloon:)` is removed.
  - In `PlazaSnowballLayer`:
    - `func setArt(_ art: PlazaSnowballArt.Art)`;
    - test accessors `var ballImages: [PlazaImage]` (flying balls) and `var burstImages: [PlazaImage]` (shown burst sprites), both read from `texture.image`.
  - `PlazaResources.snowballName`, `.petalBallName`, `.leafBallName` and `ballName(_:)`.
  - `PlazaScene.snowballBallImages: [PlazaImage]`.
  - `PlazaSnowball.burstPieces` is unchanged; its glyph now indexes `Art.burst`.

- [ ] **Step 1: Write the failing tests.**
  - `PlazaSnowballTests+Pixels`:
    - `testSnowballArtUsesOnlySnowColours` (rewrite on `art()`):
      - ball scale 4, 4×4, with five `#8DA3BF` pixels;
      - `burst.map(\.scale) == [4, 4, 4]`;
      - every opaque pixel of the ball and the burst is in `{F6FAFF, C6DAF0, 8DA3BF}`.
    - `testABallPictureIsDrawnAtOneOrTwoWorldPixelsAPixel`: fixture bitmaps of height 18, 11, 10 and 6 give `[1, 1, 2, 2]`.
    - The R4 guard, and the Review Focus 1 test:
```swift
@MainActor func testTheBurstNeverDrawsTheBallPicture() async {
    let balloon = PlazaImage(bitmap: PlazaBitmap(width: 14, height: 18, fill: PlazaRGBA(r: 0x2E, g: 0x78, b: 0xC0, a: 255)))
    let art = PlazaSnowballArt.art(.summer, ball: balloon), layer = PlazaSnowballLayer(worldHeight: 1024)
    layer.setArt(art)
    for burst in [PlazaSnowballFlight.Burst.air, .ground] {
        _ = layer.launch(PlazaSnowballFlight(start: CGPoint(x: 100, y: 500), end: CGPoint(x: 164, y: 500),
                                             endHeight: burst == .air ? 20 : 0, frames: 2, burst: burst)) {}
    }
    var seen: [PlazaImage] = []
    for _ in 0..<20 { layer.advance(by: 0.05); seen += layer.burstImages }
    XCTAssertFalse(seen.isEmpty)
    XCTAssertFalse(seen.contains { $0 === balloon }, "a burst drew the ball picture")
    XCTAssertTrue(seen.contains { $0 === art.burst[0].image }, "glyph 0 is a burst piece")
}

@MainActor func testASeasonChangeMidBurstRedrawsWithTheNewPieces() async {
    let layer = PlazaSnowballLayer(worldHeight: 1024)
    layer.setArt(PlazaSnowballArt.art(.summer))
    _ = layer.launch(PlazaSnowballFlight(start: CGPoint(x: 100, y: 500), end: CGPoint(x: 132, y: 500), endHeight: 0, frames: 1, burst: .ground)) {}
    layer.advance(by: 0.15)                       // landed: burst step 0
    XCTAssertFalse(layer.burstImages.isEmpty)
    let autumn = PlazaSnowballArt.art(.autumn)
    layer.setArt(autumn)
    layer.advance(by: 0.1)                        // step 1
    let ids = Set(autumn.burst.map { ObjectIdentifier($0.image) })
    XCTAssertFalse(layer.burstImages.isEmpty)
    XCTAssertTrue(layer.burstImages.allSatisfy { ids.contains(ObjectIdentifier($0)) })
}
```
  - `PlazaSeasonTests`: replace `testEachSeasonThrowsItsOwnColoursInTheSnowballsShapes` with `testEachSeasonsGridBallAndBurstUseOnlyArtThePlazaHas`. For each season, with `art = PlazaSnowballArt.art(season)`:
    - the ball's bytes equal `PlazaWeatherArt.image(PlazaSnowballArt.shaded(snow[0]), palette: PlazaSnowballArt.palette(season))`, at scale 4;
    - `art.burst.map { $0.image.pixels.bytes }` equals the expected list from Pinned values, at scales `[4, 4, 4]`. For winter and summer that is the three shaded snow grids in that palette; for spring and autumn, the listed `PlazaWeatherArt.images` entries.
  - `PlazaSeasonTests+Bundled`:
    - `testSummerThrowsTheWaterBalloonPictureAsItIsAndOnlyInSummer` (rewrite):
      - `art(.summer, ball: balloon).ball.image === balloon`, at scale 1;
      - no burst image is `=== balloon`;
      - the burst bytes equal `art(.summer).burst`;
      - `PlazaResources.ballName(.summer) == PlazaResources.waterBalloonName`.
    - `testEachSeasonNamesItsOwnBallFile`: the four names from Pinned values, all distinct.
    - `testEachSeasonThrowsItsBundledPictureOrItsGrid` (scene, Review Focus 5). Start with `scene()`, then `refreshSnowDay()` and `update(0)`, which gives winter, never chosen. Then for `[.winter, .spring, .summer, .autumn]`:
      - set `seasonChoice` (skip the set on the first round);
      - `playSnowball(by: nil, shot:)` up three tiles;
      - `want = PlazaSnowballArt.art(season, ball: BundledArt.image(PlazaResources.ballName(season))).ball`;
      - assert `s.snowballBallImages.last?.pixels.bytes == want.image.pixels.bytes`;
      - assert the last ball size is the image size × `want.scale`.
      - This passes both before and after Task 4.
  - `PlazaArtParityPixelArtTests`: compare `LegacyPlazaSnowballArt.pieces(season, balloon: nil)` with the new art:
    - `[0]` against `art(season).ball` for every season;
    - all three against `art(season).burst` for winter and summer;
    - keep the identity check `art(.summer, ball: PlazaImage(cgImage: balloon)).ball.image.cgImage === balloon`.
- [ ] **Step 2: Run** `swift test --filter 'PlazaSnowballTests|PlazaSeasonTests'`. Expected: the build fails (`art`, `Art`, `ballScale`, `ballName`, `burstImages` and `snowballBallImages` are undefined).
- [ ] **Step 3: Implement.**
  - The layer keeps one ball texture and scale, and three burst textures and scales:
    - `launch` and `setArt` resize balls from the ball texture;
    - `place` resizes piece `i` from `burst[glyph]`.
  - The scene replaces `waterBalloon` with `private static let ballImages: [PlazaSeason: PlazaImage]`:
    - every season's `ballName` goes through `PlatformPlaza.graphics.assetURL(_, ext: "png")` and `decodeImage`, and missing files are left out;
    - init and `refreshSnowDay` call `snowballLayer.setArt(PlazaSnowballArt.art(s, ball: Self.ballImages[s]))`.
  - Update the `PlazaSnowballArt` and `burstPieces` doc comments.
- [ ] **Step 4: Run** `swift test --filter 'PlazaSnowballTests|PlazaSeasonTests|PlazaSnowballSceneTests|PlazaSnowballControllerTests|PlazaArtParityPixelArtTests'`. Expected: PASS.
- [ ] **Step 5: Injection.** In `PlazaSnowballLayer.place`, draw glyph 0 with the ball texture and run `--filter PlazaSnowballTests/testTheBurstNeverDrawsTheBallPicture`. Expected: FAIL ("a burst drew the ball picture"). Revert, then run. Expected: PASS.
- [ ] **Step 6: Sweep and log.**
  - Run `grep -rnE "\[[0-9]\] = \(|textures\[0\]" Sources/PokeTokenBar/Team/Plaza/`. Expected: nothing outside the code you just changed. Today only `PlazaSnowball.swift:135` and `PlazaSnowballLayer.swift:70,136` match; no other plaza layer swaps one slot of a shared art list.
  - Add the `defect-log.md` entry (Korean, the log's style):
    - the burst glyph table indexed the same `[ball, piece, piece]` list whose slot 0 summer replaced with the balloon;
    - why the tests missed it: they checked the pieces' colour union and the burst geometry separately, never what a summer burst draws;
    - the guard is `testTheBurstNeverDrawsTheBallPicture`;
    - the sweep result.
- [ ] **Step 7: Run** `swift test --filter PlazaCrossRenderCompareMacTests/testCommittedReferenceTreesAreCurrent`. Expected: the same 19 stems as Task 1 and no others. Without the files, every flight and the winter burst are byte-identical to before.
- [ ] **Step 8: Run** `scripts/shared-check.sh`. Expected: it builds.
- [ ] **Step 9: Commit** `fix(team): draw plaza bursts from burst pieces only, never the thrown ball`.

### Task 3: A truer autumn with three trees, one look builder

**Files:**
- Modify:
  - `Sources/PokeTokenBar/Team/Plaza/PlazaSeasonSheet.swift`
  - `Sources/PokeTokenBar/Team/Plaza/PlazaTileArt.swift:16-19`, `:43-79`, `:113-132`
  - `Sources/PokeTokenBar/Team/Plaza/PlazaWindowController.swift:179-189`
  - `TEAM.md:183`
- Modify (the copies of the controller's builder, so renders match the app):
  - `Tests/PokeTokenBarTests/PlazaRenderScenes.swift:150-161`
  - `Tests/PokeTokenBarTests/PlazaPreviewScenes.swift:79-88`
  - `Tests/PokeTokenBarTests/PlazaHUDMenuRenderTests+Mac.swift:118-122`
- Test:
  - `Tests/PokeTokenBarTests/PlazaSeasonTests+Bundled.swift`
  - `Tests/PokeTokenBarTests/PlazaTileArtTests.swift`

**Interfaces:**
- Produces:
  - `PlazaTileArt.lilyCells: [Cell]`, which is `[(2,0), (4,0), (5,0)]` (the existing private lily cells).
  - `PlazaTileArt.mapImage(_ map: PlazaMap, sheet: PlazaImage, tallGrass: PlazaTallGrassArt? = nil, trees: [PlazaImage]? = nil) -> PlazaImage`:
    - nil means the sheet's own tree cell, as today;
    - otherwise each tree plots `trees[treeVariant(at: origin, count: trees.count)]`;
    - callers pass nil or a non-empty list.
  - `PlazaTileArt.treeVariant(at origin: TilePoint, count: Int) -> Int`.
  - `PlazaSeasonSheet.treeColors(_ season: PlazaSeason) -> [PlazaSnowSheet.Colors]`: autumn gives `[maple, orange, ginkgo]`, every other season `[]`.
  - `PlazaSeasonSheet.trees(_ sheet: PlazaImage, season: PlazaSeason) -> [PlazaImage]?`: nil when `treeColors` is empty, otherwise each colouring cropped to the 32×32 tree rect.
  - `PlazaSeasonSheet.look(_ map: PlazaMap, sheet: PlazaImage, tallGrassSheet: PlazaImage?, season: PlazaSeason) -> PlazaSnowLook`.
  - Autumn `tilePieces` no longer carries a tree piece.

- [ ] **Step 1: Write the failing tests** in `PlazaSeasonTests+Bundled`, with the Pinned values tables as a test-side oracle (`static let autumnTable`, `autumnTrees`, `autumnTallGrass`).
  - `testAutumnRecoloursEveryCellByTheTable`. In each table's cells, every opaque original pixel whose colour is a key becomes its value, and no other pixel changes. Mismatch count is 0 per entry. The sources:
    - `PlazaSeasonSheet.tiles(sheet, season: .autumn)` for ground, lily, shore, flowers, bush and sign;
    - each `PlazaSeasonSheet.trees(sheet, season: .autumn)![i]` against the original 32×32 tree crop (`sheet.cropping(to: PlazaPixelRect(x: 80, y: 256, width: 32, height: 32))`);
    - `PlazaSeasonSheet.tallGrass(grassSheet, season: .autumn)` against the whole sheet.
  - `testAutumnLeavesNoSummerGreen` (spec 5.4, Review Focus 4):
    - A summer green is an opaque colour of the **original** cell with g > r, g > b and `(g − min(r, b)) × 10 ≥ g × 3`. This counts the table's keys plus `#2D5B3F` and `#4B692F`, and excludes trunk greys and `#E8F8D0`.
    - For grass + lily, shore, flower, bush and sign cells, each tree crop, and tall-grass cols 0–2 × rows 6–8, the autumn version's colours ∩ that set is `[]`.
  - `testTheRealAutumnMapMixesAllThreeTrees`:
    - `PlazaSeasonSheet.look(PlazaMapData.map, sheet: sheet, tallGrassSheet: grassSheet, season: .autumn).mapImage` contains `#C8402A`, `#E07A2A` and `#D9A72A`;
    - it contains none of `#2ECA5C #50EB6C #299750 #328E53 #2B7D4A #2D5B43`;
    - a second `look` call gives identical bytes.
  - Update `testSpringAndAutumnRecolourTheSheetAndSummerLeavesItAlone`:
    - autumn assertions become olive ground `#8E9A44` and rust bush `#B4462A`;
    - the "none in the original" list gets `#8E9A44 #B4462A #C8402A #E07A2A`;
    - the "every new colour appears" loop also runs each `treeColors(.autumn)` entry over the tree cells.
  - Rename `testTallGrassTurnsGoldInAutumn…` to `testTallGrassDriesBrownInAutumnAndStaysGreenInSpringAndSummer`. Autumn contains `#C8A050 #9A6A2C #5E4220` and none of `#99E550 #6ABE30 #4B692F`.
  - Swap `bundledLook`'s body to `PlazaSeasonSheet.look(PlazaMapData.map, sheet: sheet, tallGrassSheet: grassSheet, season: season)`, with grass = `PlazaSeasonSheet.tallGrass(grassSheet, season: season)`. `pinnedLooks` stays as is: the new builder must reproduce the old summer, winter and spring bytes.
  - `PlazaTileArtTests.testATreesKindDependsOnlyOnItsTopLeftTile`:
    - `treeVariant(at:count: 3)` gives (−1,1)→1, (0,0)→0, (1,1)→1, (2,0)→2, (3,1)→1 and (4,0)→0. These were computed with a replica of `Noise`. If the first run disagrees, report the Swift values instead of pasting them silently.
    - With the synthetic `Self.sheet`, the map `["TTTTTT", "TTTTTT", "NN.S.."]` and three solid 32×32 fixtures (red, green, blue), `mapImage(…, trees:)` has world pixel (0,0) red, (64,0) blue and (128,0) red. Those are the tree origins (0,0), (2,0) and (4,0).
- [ ] **Step 2: Run** `swift test --filter 'PlazaSeasonTests|PlazaTileArtTests'`. Expected: the build fails (`look`, `trees`, `treeColors`, `treeVariant` and `lilyCells` are undefined).
- [ ] **Step 3: Implement.**
  - The tables are the Pinned values.
  - `drawTrees` keeps its loop. With `trees`, it plots the chosen crop through `SheetPixels`/`plot(from:)` the way `drawTallGrass` does.
  - `look` builds:
    - `art = tallGrassSheet.map { tallGrass($0, season:) }.flatMap(PlazaTallGrassArt.init(sheet:))`;
    - `PlazaSnowLook(mapImage: mapImage(map, sheet: tiles(sheet, season:), tallGrass: art, trees: trees(sheet, season:)), tallGrass: art)`.
  - The controller and the three test copies keep their `season != .summer` guard and their caches, and call `look`. The HUD test's `seasonImage` returns `.mapImage`.
- [ ] **Step 4: Run** `swift test --filter 'PlazaSeasonTests|PlazaTileArtTests|PlazaSnowSheetTests|PlazaIceArtTests|PlazaTallGrass|PlazaPreviewScenesTests'`. Expected: PASS, including `testSummerWinterAndSpringLooksAreUnchanged` with the Task 1 hashes.
- [ ] **Step 5: Injection.** Delete `0x2B7D4A` from the maple colouring and run `--filter PlazaSeasonTests/testAutumnLeavesNoSummerGreen`. Expected: FAIL naming the maple tree. Revert, then run. Expected: PASS.
- [ ] **Step 6: Run** `swift test --filter PlazaHUDMenuRenderTests` (Mac, no window). Expected: PASS. If the autumn map-layer bound in `testTheMapLayerIsCloseToSwiftUIsResampling` trips, report the measured line; do not raise the bound silently.
- [ ] **Step 7: Run** `swift test --filter PlazaCrossRenderCompareMacTests/testCommittedReferenceTreesAreCurrent`. Expected: the Task 1 stems plus `autumn@10` and `autumn@60`. The message shows the first 20, sorted.
- [ ] **Step 8: Edit `TEAM.md:183`.** In the 계절 row, replace `가을에는 땅이 누렇게, 나무·덤불·풀숲이 주황과 노랑으로 물들고 낙엽이 떨어지며,` with:
  > `가을에는 땅과 연잎이 올리브빛으로 바래고, 나무는 단풍(빨강)·주황·은행(노랑) 세 가지가 섞여 물들며, 덤불과 팻말은 녹슨 빨강, 풀숲은 마른 갈색이 되고 낙엽이 떨어지며,`
- [ ] **Step 9: Coverage.** Run with nothing else building:
```bash
swift test --enable-code-coverage --filter 'PlazaSeasonTests|PlazaTileArtTests|PlazaSnowballTests'
BIN_PATH=$(swift build --show-bin-path); PROF=$(find "$BIN_PATH/" -name default.profdata | head -1)
BIN=$(find "$BIN_PATH/" -name PokeTokenBarPackageTests -type f ! -path '*.dSYM/*' | head -1)
LLVM_COV="$(dirname "$(realpath "$(command -v swift)")")/llvm-cov"; [ -x "$LLVM_COV" ] || LLVM_COV=$(xcrun --find llvm-cov)
"$LLVM_COV" show "$BIN" -instr-profile="$PROF" --show-regions Sources/PokeTokenBar/Team/Plaza/{PlazaSeasonSheet,PlazaTileArt,PlazaSnowball,PlazaSnowballLayer,PlazaResources}.swift | grep -n '\^0'
```
  Expected: no `^0` inside code that Tasks 2–3 added or changed.
- [ ] **Step 10: Commit** `feat(team): retune the plaza autumn and mix three autumn trees`.

### Task 4: Drop in the three ball files

**Files:**
- Create in `Sources/PokeTokenBar/Resources/Plaza/`: `plaza-snowball.png`, `plaza-petal-ball.png` and `plaza-leaf-ball.png`, byte for byte as downloaded.
- Modify:
  - `Sources/PokeTokenBar/Resources/Plaza/CREDITS.md`
  - `windows/licenses/map.txt:24`
  - `Sources/PokeTokenBar/Team/Plaza/Draw/PlazaDecodeGoldens.swift:15-26`
  - `TEAM.md:169` (V row), the end of `## 알려진 한계`, and `## 출처`
- Modify, **only if a delivered file is a sheet:**
  - `PlazaResources.swift`: add `static func ballCrop(_ season: PlazaSeason) -> PlazaPixelRect?`, nil = the whole file;
  - `PlazaScene.swift`: the loader applies `cropping(to:)`.
- Test:
  - `PlazaSeasonTests+Bundled.swift`
  - `PlazaResourcesTests.swift`
  - `PlazaResourcesTests+Mac.swift`
  - `MacPlazaGraphicsTests.swift:12-25`, `:83-95`

**Interfaces:**
- Consumes: the season-art-source handoff. For each file it needs:
  - the PNG;
  - the work title, author, licence and licence URL;
  - the source page URL and the file's name inside the download;
  - the committed file's SHA-256 and its pixel size;
  - whether it is a sheet, and if so the cell rect.
- Consumes from Task 2: `ballName`, `ballScale`, `art(_:ball:)` and `snowballBallImages`.

- [ ] **Step 1: Write the failing tests.**
  - `PlazaSeasonTests+Bundled.testEverySeasonThrowsItsOwnBundledPicture` (spec 4.4, Review Focus 3). For each season, `file = BundledArt.image(PlazaResources.ballName(season))`, cropped by `ballCrop` if that exists:
    - `file` is non-nil;
    - `(12...20).contains(CGFloat(file.height) * ballScale(file))`;
    - `art(season, ball: file).ball.image === file`;
    - no burst piece of any season is byte-equal to any of the four files;
    - the four files' bytes are distinct.
  - Update `testTheFlyingThingChangesWithTheSeason`. The expected sizes are each season's file size × `ballScale`, not 16×16.
  - `PlazaResourcesTests`:
    - `testSeasonBallFilesLoad`: `[width, height]` from the handoff;
    - `testCreditsNameTheSeasonBallArtists`: for each file, the needles are the author, the title, the URL and the file name.
  - `PlazaResourcesTests+Mac.testSeasonBallsAreTheUnmodifiedOriginals`: the handoff SHA-256s of the file bytes.
  - `MacPlazaGraphicsTests`:
    - `bundledImages()` adds the three files, through `PlazaResources.resourceURL(name, "png", in: bundle)` and `CGImageSourceCreateImageAtIndex`;
    - `expectedColourSpaces` gets three placeholder lines.
  - Add three `PlazaDecodeGoldens.art` entries with `sha256: ""`.
- [ ] **Step 2: Run** `swift test --filter 'PlazaSeasonTests|PlazaResourcesTests|MacPlazaGraphicsTests|PlazaDecodeGoldensMacTests'`. Expected: FAIL (the files are missing).
- [ ] **Step 3: Add the files.**
  - Copy the three PNGs in.
  - Paste the measured values:
    - the `PLAZA-COLOURSPACE:` lines into `expectedColourSpaces`;
    - the `PlazaDecodeGoldensMacTests` "new value above" hashes into `PlazaDecodeGoldens.art`.
  - Add the crop step only if a file is a sheet.
  - Write the `CREDITS.md` sections in the Water balloon section's shape: a `## Snowball (plaza-snowball.png)` heading, then the work and source-file line, the licence, the source, `SHA-256: …`, and `Thrown in the plaza's winter. The app draws it as it is.` Say "cropped to one cell" if it was a sheet. Do the same for `Petal clump` (spring) and `Leaf clump` (autumn).
  - Add the `map.txt` lines after `plaza-water-balloon.png`, in the existing shape. The licence file is `CC-BY-SA-3.0.txt` for CC-BY-SA 3.0 and `-` otherwise; the note is `(CC0)` or `(CC-BY x.0; credit in CREDITS.md)`.
- [ ] **Step 4: Edit `TEAM.md`.**
  - V row: after `(규칙은 모두 같고 그림만 다릅니다).` insert `터지면 그 계절에 날리는 것이 흩어집니다: 겨울은 눈 알갱이, 봄은 벚꽃잎, 여름은 물방울, 가을은 낙엽입니다.`
  - End of `알려진 한계`: add `- v2.5.636 이하를 쓰는 팀원의 광장에서는 던지는 것과 가을 지도가 예전 그림입니다(눈 알갱이를 뭉친 공, 누런 땅과 주황 나무). 맞고 밀리는 규칙은 같습니다. 업데이트하면 바로잡힙니다.` Re-check the version at release; it is the last version without this PR.
  - `출처`: three lines in the shape `- 눈뭉치 그림: <지은이>, "<작품>" (<라이선스>, 변경 없이 사용)`, with `꽃잎 뭉치 그림` and `낙엽 뭉치 그림` for the others. Use `한 칸을 잘라 씀` for a sheet.
- [ ] **Step 5: Run** the Step 2 filter again, plus `PlazaSnowballTests|PlazaSnowballSceneTests` and `scripts/shared-check.sh`. Expected: PASS, and it builds.
- [ ] **Step 6: Commit** `feat(team): add the winter, spring and autumn plaza ball art`. Put each source URL and SHA-256 in the body.

### Task 5: Before/after renders for the user's approval

**Files:** none in the repo. The outputs go under `$S`.

**Harness:** `scripts/plaza-render-compare.sh`.
- It builds the base commit in a detached scratch worktree (`$S/ptb-render-base`) and HEAD.
- It runs `PlazaRenderCompareTests/testRenderAllScenes` (`PTB_PLAZA_RENDER_OUT`, offscreen `SKRenderer`) on both, then compares them.

- [ ] **Step 1: Render.**
```bash
S="<your session scratchpad>/season-art"
BASE=$(git log --format=%H -1 --grep '^test(team): pin the summer, winter and spring')
PTB_PLAZA_RENDER_ONLY=summer,spring,autumn,summer-edge,spring-edge,autumn-edge,snowballs,petal-balls,water-balloon,leaf-balls \
  scripts/plaza-render-compare.sh --base "$BASE" --scratch "$S" --runs 1
```
  Expected:
  - exit 1, with `RENDER: <k> differ: …`;
  - the list covers `autumn@*`, `autumn-edge@10`, `snowballs@*`, `petal-balls@*`, `leaf-balls@*`, `water-balloon@26` and `water-balloon@32`;
  - it does not list `summer*`, `spring*`, `water-balloon@5/12/20` or `summer-edge`/`spring-edge`. Those are byte-identical.
  - Ignore the `FRAMECOST` lines (one run).
  - The PNGs are `$S/plaza-renders/base/<scene>@<frame>.png` and `$S/plaza-renders/head/…`, with diffs in `head/diff-*.png`.
- [ ] **Step 2: Contact sheets.**
  - Write a scratch script, `$S/tools/contact.py`, and run it with `python3 -I`. It uses PIL, halves each frame with NEAREST (lossless here: two device px a world px) and labels each tile.
  - `$S/approval/autumn-map.png`:
    - row 1 (centre @10): `summer`, `spring`, `autumn` before, `autumn` after;
    - row 2 (edge @10): `summer-edge`, `spring-edge`, `autumn-edge` before, `autumn-edge` after.
  - `$S/approval/throws.png`:
    - rows: winter `snowballs`, spring `petal-balls`, summer `water-balloon`, autumn `leaf-balls`;
    - columns: before/after at 12, before/after at 26, before/after at 32.
- [ ] **Step 3: Check by eye.**
  - `water-balloon` before@26 shows balloon pictures inside the bursts; after@26 shows droplets only.
  - `autumn-edge` after shows red, orange and yellow trees and no green tree bottoms.
  - The autumn centre after shows an olive ground, rust bushes and brown tall grass.
- [ ] **Step 4: Send for approval.** Send both paths to the lead, labelled "Sample-data render, offscreen (SKRenderer), not the live app", with the three "found, not changed" items from the top of this plan.
  - **Stop until the user approves.**
  - If the user changes values, edit Task 3's tables and their test oracle, then re-run Task 3's Step 4 and this task.
  - If the art files are late, this task may run once for the map rows alone, and again after Task 4.

### Task 6: Cross-render reference

**Files:** `Tests/PlazaCrossReference/mac-reference.tar.gz`.

`scripts/plaza-render-cross.sh` renders `PlazaCrossHarness.scenes` offscreen, twice for A/A, and waits for an idle machine by itself. Never run it with `PTB_PLAZA_RENDER_ONLY` set: that would write a partial reference.

- [ ] **Step 1: Check against the old reference** (the spec 5.4 `--check`): `env -u PTB_PLAZA_RENDER_ONLY scripts/plaza-render-cross.sh --check --scratch "$S/cross"`.
  - Expected: exit 1, with `CROSS-MAC: reference is STALE:` listing exactly:
    - `autumn@10 pixels`, `autumn@60 pixels`, `snowballs@5 pixels`, `snowballs@12 pixels`, `snowballs@20 pixels`;
    - the 19 Task 1 stems marked `(not in the reference)`.
  - `spring@*`, `winter-snow@*`, `photo-winter-snow`, `water-balloon@5/12/20` and every other scene must not appear.
  - If any other stem appears, run the same `--check` at Task 1's parent in a scratch worktree. A stem that is stale there too is pre-existing; say so in the PR.
- [ ] **Step 2: Write.** Run `env -u PTB_PLAZA_RENDER_ONLY scripts/plaza-render-cross.sh --write --scratch "$S/cross"`. Expected: `wrote …/mac-reference.tar.gz (<bytes> bytes, 148 captures)` (129 today + 19).
- [ ] **Step 3: Verify.**
  - `env -u PTB_PLAZA_RENDER_ONLY scripts/plaza-render-cross.sh --check --scratch "$S/cross"`. Expected: `CROSS-MAC: reference is current (148 captures)`.
  - `swift test --filter PlazaCrossRenderCompareMacTests/testCommittedReferenceTreesAreCurrent`. Expected: PASS.
- [ ] **Step 4: Commit** `test(team): refresh the plaza cross-render reference for the season art`.
- [ ] **Step 5: After the push** (see below), the windows.yml `render` job must pass. On a failure:
  - run `scripts/plaza-render-cross.sh --run <run id> --scratch "$S/cross"`;
  - read `$S/cross/cross-report-<id>/`;
  - a real Windows difference goes into `docs/reference/windows-differences.md` in this PR (spec 3.1).
- [ ] **Step 6: Clean up.** Run `git worktree remove --force "$S/ptb-render-base"`, then `git worktree prune`.

---

## After the plan (PR)

- **Before the PR:** merge `origin/main` into the branch. If that merge changes any plaza scene, re-run Task 6.
- **Prepare the PR with `prepare-pr`.**
  - Title: `feat(team): give each plaza season its own thrown art and a truer autumn`.
  - Under `UI changes`, put the two Task 5 contact sheets (before/after), pushed to the PR-image gist and labelled "Sample-data render, offscreen".
  - The body names:
    - each art file's source URL and SHA-256;
    - the four rulings at the top of this plan;
    - the three "found, not changed" items.
- **Push** with `git push origin feat/plaza-season-art:feat/plaza-season-art`, then do Task 6 step 5.
- **Release (later, not this PR):**
  - `team_docs_check.py` will require new Mac and Windows captures, because a feat commit touches `Team/Plaza/`;
  - check the `v2.5.636 이하` line in `TEAM.md` against the version actually shipped.
