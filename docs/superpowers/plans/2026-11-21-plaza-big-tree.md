# Plaza Big Tree (PR 5) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A big pine, drawn at 3× (126×144 world px), stands in the plaza south-west of the shelter. Its trunk is on x17, its base on row 10's bottom edge, and its leaves rise into y6–7.
- Its trunk row and full-width lower boughs (x16–18, y8–10, the spec's 3×3) block walking and thrown balls. The row behind the narrow top (y7) stays open. Anyone standing there shows their head above the tree, and the leaves hide the rest.
- C while facing it tackles the tree: the tackler lunges, freezes for a few frames at contact, and bounces back. The impact star pops. The tree bends away from the hit and swings to rest. Leaves (snow in winter) burst out and drift down, and dust puffs at the trunk.
- Hits grow stronger through the day's first, second and third. The third hit of my local day drops one mint from the leaves to my feet, with a sparkle and a banner. That happens once a day per Mac.
- Teammates' screens show the same hit, and the falling mint.
- Its leaves change with the season: as drawn in summer, fresh light green in spring, golden larch in autumn, snow in winter. The ground patch under it takes the season's own ground shade, so it reads as the tree's shadow on that ground. It shows in photos and on the minimap, and hides with the background.
- Nothing else on the map changes: every season's map image stays byte-identical.

**Architecture:**
- **One map run, one rule set.** A new tile `'B'` (`PlazaTile.bigTree`) is neither walkable nor water. Every rule that already asks `isWalkable` or `blocksBall` treats it like a bush.
  - Only two places ask about the tree directly: `PlazaScene.resolvedTile` (it accepts `'B'`, ruling 8) and the item tiles (the run and the row behind it hide items, ruling 10).
  - The map's `'B'` run is the tree's position (ruling 2). The Sweep table lists every site.
- **Pure rules** go in `PlazaTree.swift`, a new SpriteKit-free file like `PlazaHotSpring.swift`:
  - every tunable of PR 5;
  - the tiles, the art rectangle and the depth line;
  - the reach rule, the strength level and the hit timeline (pure functions of the time since the hit began);
  - the leaf field and the item fall;
  - `PlazaTreeDay`, the day count;
  - the art: the crop, the row-band recolour, the bend bands and the minimap bake.
- **The art comes from a file we already ship.** RedVoxel's pine is inside the bundled `plaza-tallgrass.png`.
  - It is cropped at runtime (83, 48, 42×48) and recoloured per season by exact swaps on pixel-row bands: the leaves take the user's season table, and the ground skirt takes the season's ground shade.
  - It is drawn at 3× (decision (c)); the map is 2×. Each season's image is made once per process.
- **One layer with a fixed pool.** `PlazaTreeLayer` makes all its nodes when the scene is built and never makes another: 4 bend bands, 12 leaves and 2 dust puffs under `root`, and the impact star and the falling item under `fxRoot` (20 sprites and 2 roots).
  - Time passes only through `update(dt)`.
  - When idle, the layer returns without writing a node property. Off-screen, it advances its clocks and writes nothing.
  - A new hit restarts the shake instead of stacking a second one.
- **The controller decides; the scene draws.** The controller owns the C precedence, the day count, the drop, the grant, the banner and the activity record. It reads the injected clock and saves the count in `PlazaPreferences`. The scene only draws, and a paused scene draws nothing.
- **Wire:**
  - one new emote kind, `.treeShake`;
  - one new emote field, `treeDrop: ItemKind?` (`@LossyOptional`);
  - the strength rides in the existing `pushTiles` (ruling 7).

  Receivers draw a shake only when the sender's body touches the tree on their own screen. Nobody is moved, so PR 3's receive cooldown does not apply. There is no presence change and no new key.

**Tech Stack:** Swift 6, the shared plaza node tree (SpriteKit on the Mac, Direct2D on Windows), XCTest, `FakeTransportHub` loopback sessions, `PlazaHeadlessShell` controllers (no window), the offscreen `SKRenderer` harness, PIL for scratch contact sheets.

**Spec:** `docs/superpowers/specs/2026-11-21-plaza-seasons-and-interactions-design.md` (Korean). It is binding. This plan implements section 9, with R3 and R6, the shared rules in 3, the network row in 10, the per-PR duties in 11–12 and the constants in 13. Later user decisions are also binding:
- **(a) The art.** It is candidate 2, the pine by RedVoxel from "Pokemon-inspired 16x16 tiles" (CC-BY-SA 3.0), 42×48 px.
- **(b) The hit feel.** "나무 쳤을때 타격감있게 잘 만들어줘": the hit must feel impactful. It may reuse only art the plaza already has, and every strength, duration and count is a named constant.
- **(c) Size (after the mockups).** Draw the pine at 3×, 126×144 world px. The user found 2× too small and accepted the chunkier pixels.
- **(d) Leaf colours (after the mockups).** The starting table for the source leaves `#99E550`, `#6ABE30`, `#4B692F`, `#524B24`:

  | Season | Leaves | Look |
  |---|---|---|
  | summer | as drawn | |
  | spring | `#C4F27A`, `#8EDC52`, `#4F8E3C`, `#4A5A2A` | fresh light green |
  | autumn | `#F2C840`, `#E09A2A`, `#A8641A`, `#5E3E16` | golden larch |
  | winter | `#F4F8FC`, `#CFE0EE`, `#6F93AC`, `#3F4E5E` | snow |

  It stays tunable, in one table.
- **(e) The ground skirt (after the mockups).** The patch under the tree must sit naturally on each season's ground, not stay one fixed yellow-green. It is recoloured by exact swaps on its row band to that season's ground tones.

The user approves the pine at 3× in all four seasons, its place and the hit strip at Task 11.

## Revision 2 (2026-11-21): 3×, the season table, the skirt

**What changed**
- **Scale.** `PlazaTree.scale` is 3, and the drawn box grows to x15–19, y6–10.
- **Footprint.** The footprint becomes the spec's 3×3, x16–18, y8–10: row 8 joins the `'B'` run.
- **Items.** `coveredTiles` becomes "the run and the row behind it": x16–18, y7–10, 12 tiles.
- **Leaves.** The canopy follows decision (d), and the leaf burst follows the tree's look per season.
- **Skirt.** The skirt follows decision (e).
- **Bend.** It moves in whole sheet pixels (3 world px).
- **Leaf pixels, dust and the mint's start.** The leaves draw at 3, the dust sits at the roots' edges, and the mint starts above the tackler.

The hit timing, the day count, the wire, the C order and the tests' intent are unchanged.

**Redo in the committed tasks** (each as a new commit on top; do not rewrite history):
- **Task 1 (`8060582e`):**
  - in `bigTree` and `bigTreeHit`, Misty (17,8) → (17,7): (17,8) is now `'B'`;
  - in `chatScene`, `plateScene` and `emotes`, member `a` (15,9) → (14,9) and member `b` (19,8) → (20,8). Both were under the 3× canopy's edges (Sweep B).

  Nothing else in Task 1 changes. The map pin already maps `'B'` → `'.'`.
- **Task 2 (`5ae1ade4`):**
  - `PlazaMapData.rows` row 8 gets `BBB` at x16–18 (Pinned values);
  - `PlazaTree.scale` 2 → 3;
  - `coveredTiles(in:)` gets the new definition and doc;
  - the tests' pinned values (Task 2 Step 1):
    - `tiles` = x16...18 × y8...10;
    - `artRect` = (497, 208, 126, 144);
    - `coveredTiles` = x16...18 × y7...10; `z` is unchanged;
    - `testItemsUnderTheBigTreeAreHidden` covers y7...10, and (15,9), (17,6) and (19,8) are shown;
    - `testTheTreeStandsOnPlainGrassReachableFromEverySide` uses nine tiles, the new neighbours and the art-overlap check.

  `resolvedTile`, the snowball, Ditto, old-peer and scan tests stand as committed.
- **Task 3 (`e172d4de`):**
  - `canopyColors` (decision (d)), `groundColors` (decision (e), with the new `PlazaSeasonSheet.groundColors(_:)`) and `burstArt` (replaces `burstKind`);
  - the CREDITS line ("drawn at 3×…", same needles);
  - the tests: `testTheCropIsThePineAsShipped` compares the raw crop, not the summer image (the summer skirt now changes). `testEachSeasonSwapsOnlyItsBand` drops "spring/summer are the sheet's pine" and "autumn's canopy = summer's". Add `testTheSkirtTakesTheSeasonsGroundShade`;
  - `baked` already reads `scale` and `minimapImage(for:)` needs no change. If the minimap test hard-codes 2×2 blocks, it reads `PlazaTree.scale` instead.

## Footprint and position (measured)

- **The file.** The download `tilemap_0.png` is byte-identical to the bundled `Resources/Plaza/plaza-tallgrass.png`. Both have SHA-256 `d8b02d00acf54d3daf21c33e1cd7873ba6d82b3aa949989258e5d785885319fd`, which `PlazaResourcesTests+Mac.testTallGrassSheetIsTheUnmodifiedOriginal` already pins.
- **The crop.** The scratch crop `tree-2.png` matches the sheet exactly at (83, 48), 42×48. Every pixel is equal, and transparent wherever the crop is transparent. So no file is added (ruling 3).
- **Colours, by crop rows** (PIL, from the bundled sheet):

  | Rows | Colours (count) | What |
  |---|---|---|
  | 0–37 | `#4B692F` 437, `#6ABE30` 309, `#222034` 170, `#524B24` 162, `#99E550` 80 | the canopy: four leaf colours and the outline |
  | 38 | `#222034` 12, `#524B24` 12, `#6ABE30` 6, `#4B692F` 2 | the canopy's lowest shade, and the skirt's ends |
  | 39–47 | `#6ABE30` 140, `#4B692F` 44, `#222034` 32, `#663931` 26, `#8F563B` 18, `#45283C` 14 | the ground skirt and the trunk |

  - The leaf colours (`#99E550`, `#6ABE30`, `#4B692F`, `#524B24`) and the trunk colours (`#663931`, `#8F563B`, `#45283C`) do not overlap, so exact swaps are possible. That meets spec 9.5's "six or fewer, not the trunk's".
  - The outline `#222034` is shared and never changes.
  - The skirt reuses two leaf colours. That is why the recolour works on pixel-row bands, not on whole colours or 16 px cells (ruling 5).
  - `#524B24` occurs only in the canopy (rows 7–38).
- **Size (decision (c)).** At 3× the pine is 126×144 world px, 3.94 × 4.5 tiles.
  - Crop row r draws at world y = 208 + 3r, and crop column c at world x = 497 + 3c.
  - The trunk core (crop columns 17–24) is 24 world px wide at x 548–572, inside x17.
  - The roots (columns 12–29) span x 533–584, spilling 11 px into x16 and 8 px into x18.
  - The skirt (columns 3–38) spans x 506–611.
- **Placement (unchanged).** The crop is centred on x = 17.5 tiles (560 world px), with its bottom on the bottom edge of row 10 (y = 352).
  - The art fills x 497–623 × y 208–352: the tiles x15–19, y6–10. Row 6 holds only the tip, in its lower half.
  - The leaves now rise into y6–7, as spec 9.1 expected.
- **What each tile row of the box covers** (crop rows → row extents in crop columns, from the bundled sheet):

  | Tile row | Crop rows | Width | Covered |
  |---|---|---|---|
  | 6 | 0–5 | tip, columns 17–24, then 12–29 | most of x17's lower half; slivers of x16 and x18 |
  | 7 | 6–15 | 9–32, then 4–37 | x16–18 mostly; at most 3 px of x15, none of x19 |
  | 8 | 16–26 | 4–37 up to 1–40 | x16–18 fully; at most 12 px of x15 and 9 px of x19 |
  | 9 | 27–37 | 0–41 at the widest (rows 27–29) | x16–18 fully; at most 15 px of x15 and x19 |
  | 10 | 37–47 | the canopy's last row, the roots, the skirt 3–38 | x16–18 (the skirt's bottom corners leave a small curve of grass); 6 px of x15, 3 px of x19 |

- **Footprint (blocked, `'B'`): x16–18, y8–10, nine tiles** (ruling 1). This is the trunk row and the two full-width bough rows. Each blocked tile is almost entirely under the art, so there are no invisible walls.
- **Behind the narrow top (row 7, x16–18): walkable.**
  - A Pokémon there is drawn behind the tree.
  - The tree's top edge is at y 208, 44 px above row 7's foot line (252). So anything taller than 44 world px shows its head above the tree. The spec's smallest measured example is 57 px (R5).
  - Beside the tree (x15 and x19, rows 6–10), at most the inner 15 px of the tile is under the leaves.
- **Position check on today's map** (rows 8–10 are printed in Pinned values):
  - All nine footprint tiles are `'.'`. Every neighbour is walkable: (15,8..10), (19,8), (19,9) `'f'`, (19,10), (16..18,7) and (16..18,11).
  - The art rectangle covers no shelter, board, bush, tall-grass, water, campfire or border tile. Under it are only grass and two flower tiles, (17,6) and (19,9), drawn in the map image. Its right edge (623) is 49 px from the shelter (x 672).
  - Chebyshev distance from the footprint to each feature:

    | Feature | Nearest tile | Distance |
    |---|---|---|
    | border trees | (10,2) | 6 |
    | bush | (15,4) | 4 |
    | shelter | (21,6) | 3 |
    | board | (23,4) | 5 |
    | tall grass | (11,5) | 5 |
    | left pond | (13,13) | 3 |
    | hot spring | (32,14) | 14 |
    | campfire | (23,15) | 5 |
    | campfire seat ring | (22,14) | 4 |

  - The spawn (23,6) is untouched.
  - Nothing crowds the bigger box, so **the tree does not move**. Every requirement in spec 9.1 holds for the footprint and the drawn box.

## Conflicts with the spec

Each ruling below changes what gets built.

1. **The footprint at 3× (decision (c)).** Spec 9.1 allows "up to 3×3 (x16–18, y8–10)" and expects the leaves to rise into y6–7. At 3× both hold.
   - Rows 8 and 9 are the full-width boughs. Leaving row 8 walkable would hide a whole Pokémon there.
   - Row 7 is the narrow top. Blocking it would hide nobody, but it would block the one row where a teammate can stand behind the tree with their head showing.
   - **Ruling:** block x16–18, y8–10 (the spec's 3×3). Row 7 stays walkable behind the tree. The drawn box is x15–19, y6–10, and items follow ruling 10.
   - Superseded: revision 1 blocked 3×2 (x16–18, y9–10) for the 2× pine.
2. **`PlazaTree.origin`.** Spec 13 lists it as a constant. A second copy of the position next to the map rows would be a trap.
   - **Ruling:** the map's `'B'` run is the position, as `'h'` is the spring's.
   - The art is placed from the run: centred on its middle column, with its bottom on its bottom edge.
   - Moving the tree means moving the `'B'`s. `testTheTreeIsTheBRun` pins the run.
3. **No new art file.** Spec 9.5 and 11 say "나무 그림 한 파일", which PR 1 would add as a new sheet. The pine is already in the bundled `plaza-tallgrass.png` (see Footprint).
   - **Ruling:** crop it at runtime (`PlazaResources.treeCrop`). There is no new file, no `map.txt` line, no decode golden and no new SHA-256 test. The tall-grass ones already pin the file.
   - `CREDITS.md`'s tall-grass section and TEAM.md's 출처 line say how the pine is used.
4. **Seasons (decision (d)).** Spec 9.2 asks for spring blossom, autumn maple (one of 5.2's three), winter snow and the summer original. The user chose instead: summer as drawn, spring fresh light green, autumn golden larch, winter snow.
   - **Ruling:** the leaves take the decision (d) table, one row per season in `PlazaTree.seasonLeaves`.
   - The leaf burst uses the plaza's existing particle grid that matches the tree's look in that season (`PlazaTree.burstArt`):

     | Season | Grid | Why it matches |
     |---|---|---|
     | summer | `.greenLeaves`, all four grids (`G`/`H`) | the summer weather's own grid |
     | spring | `.greenLeaves`, all four | `H` `#C4EC5E` is the spring light `#C4F27A`. The spring weather's pink petals would not come off a green pine |
     | autumn | `.leaves`, the orange and yellow grids only (indices 0, 1, 4, 5; not the red 2, 3) | `Y` `#F2C230` ≈ `#F2C840`, `O` `#E8832A` ≈ `#E09A2A`. A larch has no red |
     | winter | `.snow`, all three | `W`/`S` are the snow whites |

   - The leaf burst's motion is that grid kind's `PlazaWeather.motion`.
   - Superseded: revision 1's evergreen spring and autumn, its winter table, and Task 11's alternatives row.
5. **The recolour works on pixel-row bands, not cells.** `PlazaSnowSheet.recolored` swaps per 16 px cell. The crop is not cell-aligned, and the canopy and the skirt share `#6ABE30` and `#4B692F`.
   - **Ruling:** add `PlazaSnowSheet.recolored(_:rows:)`, the same exact swap over whole pixel rows.
   - The canopy table covers crop rows 0..<38 and the ground table rows 38..<48. The ground table carries the canopy's entry for `#524B24`, because that colour's only row-38 pixels belong to the canopy.
6. **The shake.** Spec 9.3 says "±2 world px, three times, 0.3 s, `moveBy`", with three leaves. Decision (b) replaces it with the hit feel below: a directional, decaying bend, hit-stop, recoil, an escalating leaf burst, dust and (on the drop) a camera kick. Every number is in `PlazaTree`.
   - At 3× the bend moves in whole sheet pixels (3 world px). An offset of 1 or 2 world px would split a tree pixel between two bands.
7. **Escalation on teammates' screens.** Spec 9.4 lists only `treeDrop`.
   - **Ruling:** `.treeShake` also carries the strength level (1–3) in the existing `pushTiles` field. Receivers already clamp it with `TeamEmote.pushTiles`, and a level of 1 is left out, as for every kind.
   - Level 3 is sent only with a `treeDrop`.
   - There is no new field, and old peers drop the frame anyway.
8. **An old peer on the tree's tiles.** Spec 9.4 says new screens draw an old peer in or behind the tree.
   - Today `resolvedTile` (`PlazaScene.swift:787-790`) moves anyone on a tile that is neither walkable nor water to the shelter. That is the campfire precedent (TEAM.md:270, "새 버전 화면에서는 그 칸에 있는 동안 쉼터에 보입니다"). An old peer crossing the trunk would jump to the shelter and back.
   - **Ruling:** `resolvedTile` also accepts `'B'` tiles, so the old peer walks through, mostly hidden behind the tree (same-row depth rule). The campfire keeps its rule.
   - A tackle from inside the trunk is judged from that tile, as on the old peer's own screen.
9. **"물속이면 치지 않는다" (spec 9.3, 9.6).** No water tile is within reach of the tree for any body class. The nearest water, (13,13), is three tiles from the footprint, and a class-3 body reaches one tile sideways and two up.
   - **Ruling:** per CLAUDE.md step 3, no swimmer guard. `testNoSwimmerCanFaceOrTouchTheTree` pins the geometry instead. It fails if the tree or a pond moves, which is when the guard becomes needed.
   - C keeps its order: 물귀신 (`pullUnder`), then today's diving `return`, then the tree, then a teammate.
10. **Items under the leaves.** Spec 9.1 hides items on the nine tiles under the tree. At 3× the leaves also cover the item spot of the three walkable row-7 tiles behind the narrow top: an item (z 0.6) there would be under the tree and invisible.
    - **Ruling:** `PlazaItems.candidates(in:)` skips `PlazaTree.coveredTiles(in: map)`, the run and the row behind it over the run's columns: x16–18, y7–10, 12 tiles. That is 12 of about 1,060 candidates, 1.1%, where the spec estimated 0.85%.
    - Not the whole 5×5 art box: on x15, x19 and row 6 an item stays mostly visible. (17,6)'s item shows its top half above the tip. Those stay pickable.
    - The scene already never picks up an item that `isShown` rejects (`PlazaScene.swift:2020`).
    - `spawnCandidates` comes from `itemLayoutMap`, which has no `'B'`, so it is unchanged.
11. **A clock set back.** Spec 9.3 says "날이 바뀌면 처음부터다".
    - **Ruling:** the count rolls over only to a later day key. A clock set back keeps the saved day and counts on it, so it gives no second mint. That is the defect-log class "되감긴 시계" (`PlazaActivity.rolled` resets on any change and is left alone).
    - A clock set forward uses up that future day's mint.
12. **The banner.** Spec 9.3 says "나무에서 민트가 떨어졌어요".
    - **Ruling:** "나무에서 민트가 떨어졌어요! 가방에 넣었어요", in the pickup banner's pattern (`plazaPickedUp`), because nothing is left to pick up.
    - It shows at the hit, not when the mint lands. The decision is the controller's, and a paused scene never lands.
13. **The render set.** Spec 9.6 asks for a `big-tree` scene set (four seasons, a mid-shake frame, a teammate behind the leaves) and the minimap.
    - The minimap is a HUD panel, not in the cross harness. It is pinned by a pixel test of the baked image instead.
    - Existing scenes put members on footprint or box tiles. Task 1 moves them (Sweep B).
    - The render harness's default `me` is (19,10), right beside the trunk. So 122 of the 147 committed scene captures, and 7 of the 9 photos, now show the tree (the stale set is in Task 12).
14. **The TEAM.md old-version number** is "v2.5.636 이하". v2.5.636 is the latest tag, and PRs 1–4 use the same line. Re-check it at release.
15. **The skirt (decision (e)).** The skirt is the light disc `#6ABE30` (146 px) with a dark ring `#4B692F` (46 px) near the trunk, and it has no outline.
    - **Ruling:** it becomes the tree's soft shade on that season's own ground. The disc takes the ground's shade tone and the ring takes its darkest tone. Both colours come through the same table the season already applies to the grass cells (`PlazaTileArt.grassCells`):

      | Season | Ground table (`PlazaSeasonSheet.groundColors`) | Disc `#6ABE30` → | Ring `#4B692F` → |
      |---|---|---|---|
      | summer | none (the sheet's grass) | `#328E41` | `#315740` |
      | spring | none (spring keeps summer ground, spec 5.3) | `#328E41` | `#315740` |
      | autumn | `autumnGround` (PR 1) | `#6E7634` | `#4A4626` |
      | winter | `PlazaSnowSheet.groundColors` | `#B2C7E0` | `#8DA3BF` |

    - The summer grass cells hold `#3ABE41` (base, 1,821 px), `#6ADD4B` (light specks, 140), `#328E41` (shade, 60), `#29973B` (shade, 15) and `#315740` (darkest, 10), measured with PIL. So the disc is one step darker than the base and the ring is the darkest ground pixel. The patch reads as shade of the same grass, not a different-coloured disc.
    - The base colour itself was not chosen. A flat base disc would show as a speckless oval.
    - This is still an exact swap on the row band, and the shapes are unchanged.
    - `testTheSkirtTakesTheSeasonsGroundShade` asserts, for each season, that the skirt's colours are exactly {disc, ring}, and that both are in that season's grass-cell palette (read from the season sheet).
    - Superseded: revision 1's tall-grass tables for the skirt.

Found and **not** changed. List these in the PR:
- **Throws are not blocked on the receiving side.** `PlazaSnowball.hitTile` (`PlazaSnowball.swift:58`) does not look for blocking tiles. So a throw from an old peer, or from a hostile app, that crosses the tree still pushes on new screens. The same is true today for bushes, the board and the campfire.
- **An old host's plaza Ditto pauses at the tree.** It stops in front of the tree on new screens while it crosses the trunk: `applyDitto`'s `isGround` guard (`PlazaWindowController.swift:1734`) holds the last good state.
- **The ball scenes script an impossible throw.** The `throwing` render scenes (`PlazaRenderScenes.swift:459-480`) throw from (15,10) through the trunk to (19,10), and a real throw stops at the tree. They test the ball art, so they are left as they are. The ball in the air is drawn at z 21, over the tree.
- **PR 4's flush flood test is vacuous on steam.** `TeamHostilePeerTests.testAFlushFloodAddsNoNode` checks `steamNodeCount` on a scene built without `pondVisuals`, so that assertion is 0 == 0. It is PR 4's test, so tell the lead rather than change it here. The tree flood test below asserts that the layer exists first.
- **Received pickups are not capped within a frame.** `showPickup` sparkles once per received pickup with no per-frame cap. A flood within one frame makes 7 nodes each; they are gone within a second, and it is a pre-existing visible-flood case.

## Hit feel (decision (b))

All times are seconds since the hit began. `l` is the level (1–3), and `[l]` reads that level's entry.

| Time | Tackler | Tree | Effects |
|---|---|---|---|
| 0 → `contactAt` (0.1) | lunges `lungeDistance[l]` (8/9/10 px) toward the tree, easing out | at rest | — |
| `contactAt` → `+ hitStop[l]` (0.05/0.067/0.1, i.e. 3/4/6 frames) | **holds** at full lunge (hit-stop) | **holds**, snapped to full bend away from the hit | impact star pops (0.6 → `impactScale[l]` 1.4/1.6/1.9, fades as a tackle's); camera kick on level 3, my screen only |
| hold end → `+ recoilDuration` (0.08) | **recoils** past its start by `recoil[l]` (2/3/4 px) | swings: `bend[l]·e^(−t′/swingDecay)·cos(2πt′/swingPeriod)`, with bend 3/6/9 world px (1/2/3 tree pixels) at the top band, period 0.24 s and decay 0.18 s | leaf burst of `leaves[l]` (3/5/8) from opaque canopy pixels, away from the hit and up, each leaf drawn at the tree's own pixel size (3); two dust puffs at the roots' edges (`dustOffsetX` 26 px each side of the trunk centre), spreading `dustSpread[l]` 10/12/14 px over 0.35 s |
| then `+ returnDuration` (0.14) | returns to 0 | still swinging | leaves fall to the weather kind's speed, then sway and drift (`PlazaWeather.motion`) |
| hold end + `itemDelay` (0.05) → `+ itemFall` (0.45), only with a drop | — | — | the item starts in the canopy above the tackler and arcs 12 px down to the tackler's feet. Its x is the tackler's, clamped 24 px inside the art. Its y is crop row 30 (y 298), or 48 px above the feet if that is higher (a hit from behind). It bounces 2 px over 0.1 s, then `playSparkle` runs once and the item hides |
| hold end + `swingLength` (0.8) | — | at rest (offsets 0, stretch 1) | leaves land 0–18 px below the trunk base, rest `leafRest` (0.3 s) fading, and are gone (at most `leafLife`, 2.4 s) |

- **Which way the tree bends.** Its root is still; only the bands above it move.
  - A horizontal hit (`.right`/`.left`) shears the four crop bands sideways: offsets `bend × [1, 2/3, 1/3, 0]`, top first, rounded to whole tree pixels (multiples of `scale`, 3 world px).
    - Level 1 peaks at [3, 3, 0, 0], level 2 at [6, 3, 3, 0] and level 3 at [9, 6, 3, 0].
    - Every pixel stays crisp, and no rotation resamples the pixel art.
  - A vertical hit sets `root.yScale = 1 + (whole tree pixels of bend) × 3 / 144`, anchored at the trunk base. A hit from the south (`.up`) leans away, so the tree stretches. A hit from the north (`.down`) leans toward the viewer, so it squashes. The shared draw order composes parent scale (`PlazaDrawOrder.swift:55-59`), so both platforms draw it.
  - The bend always starts **away** from the tackler. It is never a symmetric jitter.
- **Escalation.** Every per-level table rises from level 1 to 3. Level 3 is only the dropping hit. After the day's mint, hits cycle 1, 2, 2, 1, 2, 2, … so the drop stays the biggest (`PlazaTree.level`).
- **The camera kick (ruling).** Yes, but only on my own level-3 hit, which is once a day per person.
  - It is 2 world px in the hit direction, out and back over 0.12 s, starting at contact.
  - It is added to `cameraPos` in `layout()` after the device-grid snap. The actor context (plates) follows it; `visibleRect` (culling, photo) does not.
  - It is never applied for a teammate's hit, never in photo mode (C is off there), and `cameraKick = 0` turns it off.
  - Cost: no node, one vector per frame for 0.12 s.
  - Motion comfort: a single, small, rare jolt, not a repeated shake.
- **Floods and pauses.**
  - A new hit restarts the tree's timeline, the dust, the star and the item fall.
  - The leaf burst takes free pool slots first, then restarts the oldest leaves, so the count never exceeds `maxFallingLeaves`.
  - A restart before the item lands cancels that landing, so a flood ends in at most one sparkle.
  - `playTreeHit` on a paused scene does nothing at all.
  - The pool is made at scene build, so nothing is ever created later, paused or not.

## Global Constraints

**Workspace**
- Work only in `.worktrees/plaza-big-tree` on `feat/plaza-big-tree`. Never touch the main checkout or a sibling worktree.
- The branch is stacked on `feat/plaza-hot-spring` (PR 4, #325, open). PRs 1–3 are on `main`. When PR 4 lands, merge `origin/main` into this branch. Do not rebase.
- Never use a bare `git stash`.
- Pass `--repo likelion-campus/PokeTokenBar` to every `gh` command.

**Machine**
- One `swift build`/`swift test` at a time. `pgrep -x swift-build; pgrep -x swift-test; pgrep -x xctest` must print nothing first.
- Run filtered suites only (`swift test --filter …`).
- Never open a window, activate the app or steal focus. Never set `PTB_LIVE_WINDOW_TESTS=1`.
- Renders are offscreen only: `SKRenderer` into a Metal texture. The scripts need the GPU, not a window or focus.
- Render scratch directories live outside the repo (`$S` = `<your session scratchpad>/plaza-big-tree`).

**Shared code**
- Everything changed under `Sources/PokeTokenBar/Team/` is shared with Windows: no Apple-only import, no `#if os`.
- New tests go into existing shared files, except the `+Mac` files already listed in `Tests/PokeTokenBarTests/mac-only.txt`.
  - The new files `PlazaTreeTests.swift`, `PlazaTreeTests+Bundled.swift`, `PlazaTreeLayerTests.swift` and `PlazaTreeControllerTests.swift` are shared. `+Bundled` files are not in `mac-only.txt`; they load the sheet through `PlatformPlaza`.
  - The source scan extends `PlazaPondSweepTests+Mac.swift`, which is already Mac-only.
- A test method on the main actor is `async` (`SharedSourcesScanTests`). New `@MainActor` test methods are `async`.
- Before a task is called done, run the guard suites `swift test --filter 'ScanTests|GuardTests|GateTests|TestIsolationTests|WindowsScanRootPathTests'`.

**Art (spec 3.2)**
- Only artist-made open-licence art. No code-drawn or generated stand-ins.
- The pine is a crop of `plaza-tallgrass.png` (RedVoxel, CC-BY-SA 3.0, already credited). No file is added or changed.
- The hit effects reuse only art the plaza already has: the impact star, the dust puff, the weather grids and the sparkle.
- At runtime, only crops and exact colour swaps are allowed. Integer scale (the tree 3, per decision (c); the map stays 2), nearest sampling.

**Wire (spec 3.3)**
- `TeamWire.protocolVersion` stays 1. There is one new emote kind, `.treeShake` (raw `"treeShake"`), and one new emote field, `treeDrop: ItemKind?` (`@LossyOptional`, left out unless it is a drop). `pushTiles` carries the level.
- There is no presence change and no new key.
- `TeamWireTests` pins the raw value. The hostile tests send what an honest app never sends.

**Expected red tests**
- `PlazaCrossRenderCompareMacTests/testCommittedReferenceTreesAreCurrent` fails from Task 1 (moved fixtures, new stems) until Task 12 rewrites the reference.
- Every other filtered suite named in a task must pass at that task's commit.

**Defect protocol**
- PR 5 is a feature, not a defect fix.
- Each new guard gets one injection run that must fail (named in its task).
- One `--show-regions` pass covers the new branches (Task 8, Step 6).

**Language**
- Commits are English Conventional Commits. Each ends with the line `Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>`.
- `TEAM.md` text is Korean in its current tone.
- New code comments follow the surrounding file. These plaza files comment in Korean; `TeamWire`/`TeamSession` doc comments are English.

## Pinned values

```swift
// PlazaMap.swift
case bigTree = "B"                        // PlazaTile, the "지나갈 수 없음" list: not walkable, not water (so blocksBall is true)
func isBigTree(_ p: TilePoint) -> Bool    // .bigTree only; off the map false
// PlazaMapData.rows: rows 8, 9 and 10, columns 16...18, "..." -> "BBB". No other character changes. itemLayoutRows never change.
//   row 8:  "TTT..ggggggg....BBB..........................TTT"
//   row 9:  "TTT.....f.......BBBf............f....f.......TTT"
//   row 10: "TTT.............BBB..........ggg.......b.....TTT"

// PlazaSeasonSheet: the table a season applies to the grass cells, for the skirt. No output of the sheet changes
static func groundColors(_ s: PlazaSeason) -> PlazaSnowSheet.Colors   // summer, spring [:]; autumn autumnGround; winter PlazaSnowSheet.groundColors

// PlazaResources
static let treeCrop = PlazaPixelRect(x: 83, y: 48, width: 42, height: 48)   // RedVoxel's pine inside plaza-tallgrass.png (no new file)

// PlazaSnowSheet: the same exact swap as recolored(_:pieces:), over whole pixel rows of `image`
static func recolored(_ image: PlazaImage, rows pieces: [(colors: Colors, rows: Range<Int>)]) -> PlazaImage

// PlazaTree.swift: every tunable of PR 5 is in this one file
enum PlazaTree {
    // 하루 규칙 (명세 9.3, 13)
    static let hitsPerDrop = 3                // 조정용 상수 (명세 13, 위임)
    static let dropsPerDay = 1                // 조정용 상수 (명세 13, 위임)
    static let dropItem: ItemKind = .mint     // 조정용 상수 (명세 13, 위임, R3)
    static let maxFallingLeaves = 12          // 조정용 상수 (명세 13, 설계자 판단·미확인)

    // 자리: 지도의 'B' (ruling 2)
    static func tiles(in map: PlazaMap) -> Set<TilePoint>          // every 'B'; [] on a map without one
    static func artRect(in map: PlazaMap) -> CGRect?               // world px, y down. Centre x = (minX + maxX + 1) / 2 · 32, bottom = (maxY + 1) · 32,
                                                                   // size = treeCrop × scale. (497, 208, 126, 144) on the real map
    static func coveredTiles(in map: PlazaMap) -> Set<TilePoint>   // where the leaves hide an item: the run and the row behind it over the run's
                                                                   // columns, x16...18 × y7...10 (12). Not the whole art box (ruling 10)
    static func z(in map: PlazaMap) -> CGFloat?                    // 1 + (maxY + 1) · 32 / map pixel height = 1.34375 (the campfire's formula)

    // 닿기 (명세 9.3, 6.3)
    static func isFacing(_ body: PlazaBody, facing: PlazaDirection, tiles: Set<TilePoint>) -> Bool
        // some cell c of the body, c ∉ tiles, with PlazaWalker.offset(c, facing) ∈ tiles. Class 1: the faced tile is a tree tile
    static func touches(_ body: PlazaBody, tiles: Set<TilePoint>) -> Bool
        // body.touches(PlazaBody(foot: t, size: 1)) for some t ∈ tiles
    static func hitDirection(_ body: PlazaBody, facing: PlazaDirection, tiles: Set<TilePoint>) -> PlazaDirection
        // `facing` when isFacing; else the side the body is on: west of the run .right, east .left, north .down, south .up
    static func level(hits: Int, drops: Bool) -> Int               // 3 when this hit drops; else min(2, (hits − 1) % hitsPerDrop + 1)

    // 그림 (rulings 3–5, 15)
    static let scale: CGFloat = 3                                  // a sheet pixel draws 3×3 world px (decision (c); the map is 2×)
    static let canopyRows = 0..<38                                 // crop rows: the leaves and their outline
    static let groundRows = 38..<48                                // crop rows: the ground skirt, the trunk, the canopy's last shade
    static let bandRows: [Range<Int>] = [0..<10, 10..<20, 20..<30, 30..<48]   // bend bands, top first; the last holds the trunk and never moves
    static let bandWeights: [CGFloat] = [1, 2.0 / 3, 1.0 / 3, 0]
    static let leafColors: [UInt32] = [0x99E550, 0x6ABE30, 0x4B692F, 0x524B24]   // the source leaves, light to shadow
    static let seasonLeaves: [PlazaSeason: [UInt32]] = [                          // 조정용 표 (decision (d)); summer has no row
        .spring: [0xC4F27A, 0x8EDC52, 0x4F8E3C, 0x4A5A2A],
        .autumn: [0xF2C840, 0xE09A2A, 0xA8641A, 0x5E3E16],
        .winter: [0xF4F8FC, 0xCFE0EE, 0x6F93AC, 0x3F4E5E]]
    static func canopyColors(_ s: PlazaSeason) -> PlazaSnowSheet.Colors   // zip(leafColors, seasonLeaves[s]); [:] in summer
    static let skirt: (disc: UInt32, ring: UInt32) = (0x6ABE30, 0x4B692F)        // the skirt's two colours in groundRows
    static let skirtGround: (disc: UInt32, ring: UInt32) = (0x328E41, 0x315740)  // the grass cells' shade and darkest (ruling 15)
    static func groundColors(_ s: PlazaSeason) -> PlazaSnowSheet.Colors
        // [skirt.disc: g(skirtGround.disc), skirt.ring: g(skirtGround.ring)], g = PlazaSeasonSheet.groundColors(s) (identity when absent),
        // plus canopyColors(s)'s 0x524B24 entry. Disc/ring: summer and spring 0x328E41/0x315740, autumn 0x6E7634/0x4A4626, winter 0xB2C7E0/0x8DA3BF
    static func image(_ tallGrassSheet: PlazaImage, season: PlazaSeason) -> PlazaImage?
        // nil unless the sheet is 208×144. The treeCrop, then recolored(rows: [(canopyColors, canopyRows), (groundColors, groundRows)])
    static func bands(_ image: PlazaImage) -> [PlazaImage]          // the bandRows crops of a season image (42 wide)
    static func burstArt(_ s: PlazaSeason) -> (kind: PlazaWeather.Kind, grids: [Int])   // ruling 4; grids index PlazaWeatherArt.grids(kind):
        // summer, spring (.greenLeaves, [0, 1, 2, 3]); autumn (.leaves, [0, 1, 4, 5]), orange and yellow, no red; winter (.snow, [0, 1, 2])
    static func canopySpawnPoints(_ image: PlazaImage, artRect: CGRect) -> [CGPoint]
        // world px, y down: the centre of every opaque pixel in crop rows 4..<34 (the alpha is the same in every season)
    static func baked(_ mapImage: PlazaImage, tree: PlazaImage, at rect: CGRect) -> PlazaImage
        // the minimap image: the tree over the map at `scale`, Canvas.plot's premultiplied formula; every pixel outside `rect` is unchanged

    // 타격감 (decision (b)); entries are [level − 1]
    static let contactAt: TimeInterval = 0.1                       // the lunge reaches the trunk
    static let hitStop: [TimeInterval] = [0.05, 0.067, 0.1]        // tackler and tree hold (3, 4, 6 frames)
    static let lungeDistance: [CGFloat] = [8, 9, 10]               // world px (a tackle lunges 8)
    static let recoil: [CGFloat] = [2, 3, 4]                       // world px back past the start
    static let recoilDuration: TimeInterval = 0.08
    static let returnDuration: TimeInterval = 0.14
    static let bend: [CGFloat] = [3, 6, 9]                         // world px at the top band = 1, 2, 3 tree pixels; a vertical hit stretches by bend / 144
    static let swingPeriod: TimeInterval = 0.24
    static let swingDecay: TimeInterval = 0.18
    static let swingLength: TimeInterval = 0.8                     // after the hold; then at rest
    static let leaves: [Int] = [3, 5, 8]
    static let leafScale: CGFloat = 3                              // a weather grid cell draws 3 world px, the tree's own pixel size
    static let leafPop: ClosedRange<CGFloat> = 30...60             // world px/s, away from the hit and up
    static let leafGravity: CGFloat = 160                          // world px/s², until the burst kind's PlazaWeather fall speed
    static let leafRest: TimeInterval = 0.3                        // on the ground, fading
    static let leafLife: TimeInterval = 2.4
    static let dustSpread: [CGFloat] = [10, 12, 14]                // world px over 0.35 s, as puffDust
    static let dustOffsetX: CGFloat = 26                           // world px from the trunk's centre to each puff: the roots' edge at 3×
    static let impactScale: [CGFloat] = [1.4, 1.6, 1.9]            // the star grows from 0.6 (a tackle's: 1.4)
    static let itemDelay: TimeInterval = 0.05                      // after the hold
    static let itemFall: TimeInterval = 0.45
    static let itemArc: CGFloat = 12
    static let itemBounce: CGFloat = 2
    static let itemBounceDuration: TimeInterval = 0.1
    static let cameraKick: CGFloat = 2                             // world px; my own level-3 hit only; 0 turns it off
    static let cameraKickDuration: TimeInterval = 0.12

    // The timeline, pure. t = seconds since the hit began; t′ = t − contactAt − hitStop[l]
    static func bendAmount(at t: TimeInterval, level: Int) -> CGFloat   // 0 before contactAt; bend[l] through the hold;
                                                                        // bend·e^(−t′/swingDecay)·cos(2πt′/swingPeriod); 0 from t′ = swingLength
    static func bandOffsets(bend: CGFloat) -> [CGFloat]                 // (bend / scale × weight).rounded() × scale: whole tree pixels
                                                                        // bend 3 → [3, 3, 0, 0], 6 → [6, 3, 3, 0], 9 → [9, 6, 3, 0], −4.7 → [−6, −3, −3, 0]
    static func stretch(bend: CGFloat) -> CGFloat                       // 1 + (bend / scale).rounded() × scale / 144
    static func lungeOffset(at t: TimeInterval, level: Int) -> CGFloat  // along the hit direction: 0 → +d by contactAt, held through the hit-stop,
                                                                        // → −recoil over recoilDuration, → 0 over returnDuration, then 0
    static func lungeLength(level: Int) -> TimeInterval                 // contactAt + hitStop + recoilDuration + returnDuration
    static func cameraKick(at t: TimeInterval, level: Int) -> CGFloat   // 0 unless level 3; 0 → cameraKick → 0 over cameraKickDuration from contactAt
    static func impactPoint(tacklerFoot: CGPoint, direction: PlazaDirection, height: CGFloat) -> CGPoint
        // world px, y down: the foot moved half a tile toward `direction`, up by max(height, 24) · 0.55 (showImpact's height)
    static func itemStart(artRect: CGRect, tacklerFoot: CGPoint) -> CGPoint
        // x = tacklerFoot.x clamped to artRect.minX + 24 ... maxX − 24; y = min(tacklerFoot.y − 48, artRect.minY + 30 · scale), crop row 30
}

struct PlazaTreeLeaf: Equatable {
    var x: CGFloat, y: CGFloat, vx: CGFloat, vy: CGFloat   // world px and px/s, y down
    var age: TimeInterval
    var restedAt: TimeInterval?                            // the age at which it reached `groundY`
    let groundY: CGFloat                                   // baseY + 0...18, per leaf
    let image: Int                                         // one of burstArt(season).grids
    let phase: CGFloat
}
struct PlazaTreeLeaves {
    init(spawnPoints: [CGPoint], baseY: CGFloat)           // spawnPoints from PlazaTree.canopySpawnPoints
    private(set) var leaves: [PlazaTreeLeaf]               // never more than maxFallingLeaves
    private(set) var bursts: Int                           // burst n is seeded with fnv1a("plaza-tree-leaves-\(n)")
    mutating func burst(count: Int, direction: PlazaDirection, grids: [Int])   // seeded spawn points; free slots first, then restarts the oldest
    mutating func advance(by dt: TimeInterval, kind: PlazaWeather.Kind)   // pop → gravity → the kind's fall, drift and sway → rest → gone
    static func alpha(_ leaf: PlazaTreeLeaf) -> CGFloat    // 1, then down to 0 over leafRest after restedAt
}
struct PlazaTreeItemFall: Equatable {
    init(from: CGPoint, to: CGPoint)                       // world px, y down; `to` is the tackler's foot point at the hit
    func position(at t: TimeInterval) -> CGPoint?          // t since the fall began; nil after itemFall + itemBounceDuration
}
struct PlazaTreeDay: Codable, Equatable, Sendable {
    var day: String
    var hits = 0
    var dropped = 0
    static let maxHits = 99_999
    init(day: String)
    /// One hit on `today` (a `PlazaActivity.dayKey`). A later day starts over first; an earlier day (a clock set back) keeps
    /// counting on the saved one (ruling 11). True when this hit drops: hits % hitsPerDrop == 0 and dropped < dropsPerDay.
    mutating func hit(on today: String) -> Bool
}

// PlazaTreeLayer (@MainActor final class)
//   root:   z = PlazaTree.z(in:). Four band sprites, maxFallingLeaves leaf sprites (+0.0003), two dust sprites (+0.0002). Hidden with the background
//   fxRoot: z 20. The impact star and the falling item. Not hidden with the background
//   init(map:images: [PlazaSeason: PlazaImage], worldHeight:)    makes all 20 sprites; nothing else ever adds a node
//   setSeason(_:), setHidden(_:)
//   hit(direction:level:tacklerFoot:tacklerHeight:drop: ItemKind?)   restarts the timeline
//   update(dt:visible:step:) -> Bool                                  true on the one frame the item lands
//   isBusy, photoProps() -> [PlazaPhotoProp]                          bands at their offsets and shown leaves, baseY = (maxY + 1) · 32
//   test reads: nodeCount, bandOffsets, stretch, shownLeafCount, isImpactShown, itemPosition, spriteStates

// PlazaScene
//   private static let treeImages: [PlazaSeason: PlazaImage]   once per process, from PlatformPlaza.tallGrassSheet()
//   let treeTiles: Set<TilePoint>                              PlazaTree.tiles(in: map)
//   func playTreeHit(by tackler: String?, direction: PlazaDirection, level: Int, drop: ItemKind?)
//   test reads: isTreeShown, treeZ, treeNodeCount, treeBandOffsets, treeStretch, treeLeafCount, isTreeBusy, treeItemPosition, cameraKickOffset
// PlazaActor
//   func treeLunge(toward d: PlazaDirection, level: Int)       lungeOffset follows PlazaTree.lungeOffset for lungeLength(level)

// Wire, session, runtime, text
//   TeamEmoteKind.treeShake                raw "treeShake"; notifiesTarget false; endsSendersDance true
//   TeamEmote: @LossyOptional var treeDrop: ItemKind?
//   TeamSession.sendEmote(…, treeDrop: ItemKind? = nil)
//   TeamRuntime: .treeShake → plaza?.showTreeShake(from:level: TeamEmote.pushTiles(emote.pushTiles), drop: emote.treeDrop), before the bubble fallback
//   L(.ko).teamEmoteLabel(.treeShake) = "나무 흔들기"
//   L(.ko).plazaTreeDropped(_ kind: ItemKind) -> String     .mint: "나무에서 민트가 떨어졌어요! 가방에 넣었어요"
//                                                           (.rareCandy "이상한 사탕이", .shinyCharm "이로치 부적이", same sentence)
// Saved
//   PlazaPreferences: private static let treeKey = "team.plaza.tree"; var tree: PlazaTreeDay? (JSON, nil removes, as `activity`)
// Controller
//   private var treeDay: PlazaTreeDay      preferences.tree ?? PlazaTreeDay(day: "")
//   private func hitTree() -> Bool         true when I face the tree (handled, even when rate-limited)
//   func showTreeShake(from sender: String, level: Int, drop: ItemKind?)
//   test reads: bannersShown (bannerGeneration), treeHitsToday
```

## Sweep

**A. Every site that decides by tile kind.** Found with `grep -rnE '\.tree\b|\.bush\b|PlazaTile\b|isWalkable\(|blocksBall|isGround|tile\(at' Sources/PokeTokenBar/Team Sources/PokeTokenBar/Platform`.

| Site | Decides | Big tree | Guard |
|---|---|---|---|
| `PlazaTile.isWalkable` (`PlazaMap.swift:16-21`, exhaustive switch) | walking, pathing, items, last tile, pushes, drags, 물귀신 landing | not walkable | the compiler (no `default`); equivalence test |
| `PlazaMap.isWater` (`:103`) | every water rule | not water | equivalence test |
| `PlazaSnow.isSnowGround` (`PlazaSnow.swift:17-20`, exhaustive) | footprints | false | the compiler; equivalence test |
| `PlazaSnowball.blocksBall` (`PlazaSnowball.swift:35-37`) | a ball stops in front | blocks (not walkable, not water) | equivalence test; `PlazaSnowballTests.testTheBigTreeStopsABall` |
| `PlazaSnowball.hitTile` (`:58`, receiving side) | push by a received throw | no blocker check (found, not changed) | — |
| `PlazaDitto.isGround` (`PlazaDitto.swift:14-16`) and `PlazaDittoBrain` (`:70`, `:129`, `:212`, `:247`, `:370`, `:375`, `:398`) | Ditto ground, routes, prank victims, received Ditto states (`PlazaWindowController.swift:1734`) | not ground | equivalence test; `PlazaDittoBrainTests.testTheDittoWalksAroundTheBigTree` |
| `PlazaItems.candidates`/`openTiles` (`PlazaItems.swift:52-70`) | items shown and picked up (`PlazaScene.swift:2020`) | the nine `'B'` (not walkable) **and** row 7 x16–18 under the narrow top (ruling 10) | `PlazaItemsTests.testItemsUnderTheBigTreeAreHidden`, `testSpawnCandidatesAreUnchanged` |
| `PlazaPreferences.lastTile` (`PlazaPreferences.swift:108-113`) | start tile | a saved `'B'` starts at the spawn | equivalence test |
| `PlazaPathfinder.path` (`PlazaPathfinder.swift:19`) | walk-to and follow routes | around | equivalence test |
| `PlazaScene.resolvedTile` (`PlazaScene.swift:787-790`) | where a teammate is drawn | **accepts `'B'`** (ruling 8); other blocked tiles still go to the shelter | `PlazaTreeLayerTests.testAnOldPeerOnTheTrunkIsDrawnThere` |
| `PlazaScene.isWalkableNow` (`:1072`) and its users (`canEnterTile`, `canPushTile`, `PlazaDrag`, `pullTarget`) | walker, pushes, drag step-back and slide | not walkable | equivalence test (through `isWalkable`) |
| `PlazaInteraction.target` (`PlazaInteraction.swift:21-33`) | Space: board, campfire | not a Space target (C only) | `PlazaTreeControllerTests.testSpaceBesideTheTreeStillGreetsATeammate` |
| `PlazaTileArt.mapImage` tile switch (`PlazaTileArt.swift:64-70`, `default: break`) | map art | drawn as grass, byte for byte | `PlazaTreeTests+Bundled.testEveryMapImageIsUnchanged` |
| `PlazaTileArt.drawTrees` (`:141`, `== .tree`) | border forest | not a border tree | the scan |
| `LegacyPlazaTileArt` (`Tests/…/Legacy/LegacyPlazaTileArt.swift:62`, `default: break`) | parity port | grass | `PlazaArtParityPixelArtTests` unchanged |
| `PlazaTallGrass*` (`== .tallGrass`), `PlazaIce` (`== .pond`), `PlazaHotSpring` (`== .hotSpring`) | their own tiles | n/a | — |
| Minimap (`PlazaMinimapPanel.swift:77`, `seasonMapImage ?? mapImage()`) | small map | the baked image (Task 3) | `PlazaTreeTests+Bundled.testTheMinimapShowsTheTreeInEverySeason` |
| `PlazaPhotoRenderer` props (`PlazaScene.swift:1402`) | photo | bands and leaves as props (Tasks 4, 6) | `PlazaTreeLayerTests.testThePhotoCarriesTheTree` |
| Windows selftests (`Platform/Windows/WindowsSelftestPlaza*.swift`) | none stand on or walk through x16–18, y8–10 (grep) | — | `plaza.renderCostTree` added (Task 9) |

- **The equivalence test** is `PlazaTreeTests.testTheTreeAnswersLikeTheGrassItReplaced`. It builds `old` = `PlazaMap(rows: PlazaMapData.rows` with every `'B'` turned back to `'.'`). Then:
  - For every tile in x −1...48, y −1...32, it asserts the same answer from both maps for `isWalkable`, `isWater`, `PlazaSnow.isSnowGround`, `PlazaSnowball.blocksBall`, `PlazaDitto.isGround` and `PlazaPond.shore(at:isWater:)`. The exception is the nine `'B'` tiles, where the new map answers false, false, false, true, false and the same shore.
  - It asserts the same `spawn`, `boardTile`, `shelterTiles`, `campfireTiles` and `PlazaItems.spawnCandidates`.
  - It asserts `PlazaItems.openTiles(in: map) == openTiles(in: old).subtracting(PlazaTree.coveredTiles(in: map))`.
  - It asserts that `PlazaPathfinder.path(from: (15,10), toNextTo: (19,10), map:)` exists on both maps and never enters a `'B'` tile on the new one.
  - It asserts that `PlazaPreferences.lastTile(validIn:)` with a saved (17,10) is the spawn on the new map and (17,10) on `old`.
- **The scan** is `PlazaPondSweepTests+Mac.testEveryDirectTreeTileCheckIsClassified`.
  - It greps `Sources/PokeTokenBar/Team/Plaza/**/*.swift` with `(^|[^A-Za-z0-9_)\]?!])\.(tree|bigTree)\b`. `\b` keeps `treeCell`, `treeColors` and `PlazaTree` out.
  - It asserts that the hits equal an allow-list of (file, trimmed line). A new direct check fails with "a blocked tile is asked through isWalkable/blocksBall; the tree through PlazaMap.isBigTree; list a real exception here".
  - Task 1 writes today's hits. Expect four: the `PlazaMap.swift` case line, `PlazaMap.tile(at:)`'s off-map `return .tree`, the `PlazaSnow.swift` case line and `PlazaTileArt.swift`'s `drawTrees` check. Task 2 changes the two case lines and adds `isBigTree`.
  - The pond scan's allow-list (`:7-15`) holds the same two case lines, so Task 2 updates them there too.

**B. Fixtures that stand on the footprint or the drawn box.** Found with `grep -rnE '\b(p|t|tp|tile|at|P)\(1[6-8], ?(8|9|10)\)|TilePoint\(x: ?1[6-8], ?y: ?(8|9|10)\)|member\("[a-z0-9]+", "[^"]*", 1[6-8], (8|9|10)\b' Tests`. Each move keeps the fixture's role. Task 1 makes the moves on today's map, so each suite stays green before `'B'` exists.

| File | Fixture | Today | Moved to |
|---|---|---|---|
| `PlazaRenderScenes.swift:394` (`chatScene`), `:413` (`plateScene`) | member `a`; member `b` | (16,9); (19,8) | (14,9); (20,8). Revision 1 moved `a` to (15,9). At 3× both (15,9) and (19,8) are under the canopy's edges, so revision 2 moves them clear |
| `PlazaRenderScenes.swift:591` (`emotes`) | `a`; `b` | (16,9); (18,8) | (14,9); (20,8). Revision 1 moved them to (15,9) and (19,8); same reason as above |
| `PlazaRenderScenes.swift` `bigTree`, `bigTreeHit` (Task 1's new builders) | `misty` | (17,8) | (17,7), behind the narrow top: (17,8) is `'B'` at 3× |
| `PlazaRenderScenes.swift:586` (`pray-wobble`) | `ash` | (17,10) | (17,12) |
| `PlazaRenderScenes.swift:692-699` (`lunges`) | `ash` | (17,10), facing right | (16,11), facing right (Mix still walks to (17,12) and then (17,11)) |
| `PlazaBodySizeControllerTests.swift:145-266` | every `p(17, y)` (me and b, rows 8–13) | column 17 | column 20 (x20, rows 6–15, is open ground; the tests' geometry is only the column) |
| `SpriteKitMirrorParityTests.swift:856` | Ditto tile | (17,10) | (17,11) |

`crowd(me)` (`PlazaRenderScenes.swift:223-228`) puts nobody on these tiles around the default `me` (19,10): Brock (17,11) stands in front of the trunk. That is a depth case the renders now show.

Left as they are, and checked by eye at Task 11: at 3× the canopy's edges reach 15 px into x15 and x19. So the default `me` (19,10) has its left edge behind the tree in the default scenes, and the `throwing` scenes' Ash (15,10) has its right edge behind it. Moving the default `me` would shift every scene's scripted shots.

## Layers around the tree

| Layer | z | Against the tree (z = 1.34375) |
|---|---|---|
| map 0, footprints 0.04, shadows 0.5, ground item 0.6 | below | under the tree; items under the box are not shown anyway (ruling 10) |
| characters, `1 + footY/1024` (`PlazaActor.swift:372`; footY = (y + 0.875) · 32) | row ≤ 10 below (row 10's foot 348 < 352), row ≥ 11 above | behind at x15/x19 (rows 6–10) and on row 7; in front from row 11 |
| a walker stepping from row 10 to row 11 | crosses at 0.75 of the step | — |
| leaves +0.0003, trunk dust +0.0002 (children of `root`) | just above the tree | in front of the leaves, behind characters standing in front |
| ball in flight 21, on the ground `1 + y/1024 + 0.0003` | over in flight | a ball arcs over the canopy; the footprint stops it |
| steam 2.9, weather 3 | above | snow and leaves of the weather fall over the tree |
| daylight multiply 5 (camera) | above | tints the tree at night like the map |
| name plates 10, emotes 11 (camera space) | above | a teammate behind the leaves keeps their plate and bubbles; the tree is not a hiding place |
| impact star, falling item (`fxRoot`) 20, sparkle 20 | above | always seen |
| photo | — | bands and leaves are `PlazaPhotoProp`s with baseY 352, the campfire's rule: a character whose foot y is below that is drawn behind |
| minimap | — | the baked image per season |
| background hidden | — | `root` hidden (bands, leaves, dust). `fxRoot`, the lunge and the hit-stop still play. The footprint still blocks |

## Mixed versions

Old = v2.5.636 and earlier (TEAM.md line in Task 10).

| Case | New screen | Old screen |
|---|---|---|
| The tree | a pine; x16–18, y8–10 blocked | grass |
| An old peer walks across x16–18, y8–10 | behind the tree or inside the trunk, plate shown, no jump to the shelter (ruling 8). On row 8, under the full-width boughs, only the plate shows | walks on grass |
| A new teammate hits the tree | lunge, star, bend, leaves, dust; a falling mint and a sparkle on the drop | frame dropped (unknown kind): the teammate just stands there |
| An old peer tackles me from a trunk tile | judged from that tile: pushed if our bodies touch | as today |
| An item on the nine tiles under the tree | not shown, cannot be picked up | shown and pickable; picking it sends `takenItemSlot`, so it is gone everywhere |
| An old peer throws across the tree | the ball passes the trunk and I am pushed (`hitTile` does not check blockers) | a hit |
| A new teammate throws at the tree | stops in front of the trunk | flies further on, with no tree there, and misses |
| An old host's Ditto crosses the footprint | holds in front of the tree until it is off it (`applyDitto` keeps the last good state) | walks across |
| A new host's Ditto | walks around the tree | walks around an invisible obstacle |
| A new teammate stands at (16..18, 7) | the head above the tree, the rest hidden by the leaves | stands on grass |

All of it is visual. No connection cools, and no rule sends anything new to an old peer.

## Review Focus

1. **One blocked-tile rule.** Look for a tile decision outside the Sweep A table. The scan and the equivalence test must both fail when one is missed (Task 2 injections).
2. **The art is the shipped file.** No new resource. The crop's bytes equal the sheet's region. Summer's leaves are byte-identical. Every swap is exact and confined to its row band. The leaves follow decision (d)'s one table. The skirt's colours are that season's ground shade and darkest. The trunk and the outline never change.
3. **The pool and the clock.**
   - All 20 sprites exist from the scene's first frame, and none is added after.
   - A paused scene does nothing at all.
   - Idle and culled frames write no node property, so the Windows renderer stays clean (`plaza.idleVisible`).
   - A flood restarts; it never stacks. At most one sparkle follows a flood.
4. **The hit feel.** The bend starts away from the hit and decays. The hold is flat for both the tackler and the tree. The recoil is negative. Every per-level value rises from 1 to 3, and only a drop is level 3. The camera kick is mine, on level 3 only.
5. **The day.**
   - The clock is the controller's injected clock.
   - The day key is `PlazaActivity.dayKey` (local midnight), and 23:59:59 → 00:00:00 is tested.
   - A clock set back gives nothing.
   - `grantItem`, the banner and the pickup record happen once, at the hit, whatever the scene does.
6. **C order and reach.** 물귀신, then the tree, then a teammate. A body that touches the tree but faces away does not hit it.
7. **Hostile peers.** A sender who does not touch the tree, a level of 99, an unknown item kind, a flood of 1,000 shakes, a paused receiver. The receiver never moves, grants or banners.

---

### Task 1: Baselines (map pin, tree scan, fixtures off the tree, render scenes)

**Files:**
- Modify:
  - `Tests/PokeTokenBarTests/PlazaPondMapTests.swift`: PR 4's `testTheMapIsV2_5_635sWithOnlyTheRightPondRenamed`
  - `Tests/PokeTokenBarTests/PlazaPondSweepTests+Mac.swift`
  - `Tests/PokeTokenBarTests/PlazaRenderScenes.swift`: the Sweep B rows; new builders after `hotSpring(…)`; `makeAll`
  - `Tests/PokeTokenBarTests/PlazaBodySizeControllerTests.swift`
  - `Tests/PokeTokenBarTests/PlazaRender/SpriteKitMirrorParityTests.swift:856`

- [ ] **Step 1: Pin today's map.**
  - Extend PR 4's map pin so its replacement chain also maps `"B"` → `"."`, and rename it `testTheMapIsV2_5_635sWithOnlyTheSpringAndTheTreeAdded`. It passes now (there is no `'B'` yet) and keeps passing after Task 2.
  - Today's rows are still v2.5.635's outside the spring. Check that with `git diff v2.5.636 -- Sources/PokeTokenBar/Team/Plaza/PlazaMapData.swift`, which shows only PR 4's `'h'` change.
- [ ] **Step 2: The scan** (Sweep A). Add `testEveryDirectTreeTileCheckIsClassified` with today's hits as its allow-list.
  - Run `swift test --filter PlazaPondSweepTests`. Expected: PASS.
  - Injection: add `if map.tile(at: t) == .tree {}` to `PlazaItems.candidates` and run the filter. Expected: FAIL. Revert.
- [ ] **Step 3: Move the fixtures** (Sweep B), one file at a time. Re-run the grep. Expected: no hit outside `PlazaCrossReference`.
- [ ] **Step 4: The render scenes.**
  - Add `bigTree(_ name: String, _ choice: PlazaSeasonChoice, photo: Bool = false)`:
    - `o.me = (17,12)` facing `.up`, zoom 2;
    - `put([member("ash", "Ash", 15, 10, facing: .right), member("misty", "Misty", 17, 7, facing: .down), member("brock", "Brock", 19, 11, facing: .left), member("dawn", "Dawn", 20, 9)], looks: crowdLooks)`;
    - Misty stands behind the narrow top (row 7), with her head above the tree.
  - Add `bigTreeHit(_ name: String, captures: [Int])`, summer, zoom 2. Every hitter touches the trunk:
    - `o.me = (17,11)` facing `.up`;
    - `put([member("ash", "Ash", 15, 10, facing: .right), member("brock", "Brock", 19, 10, facing: .left), member("misty", "Misty", 17, 7, facing: .down), member("dawn", "Dawn", 20, 12)], looks: crowdLooks)`.

    Task 6 adds the hit calls. Until then the scene only stands.
  - Add to `makeAll`, after the `hot-spring-*` scenes:
    - `bigTree("big-tree-summer", .summer)`, `-spring`, `-autumn`, `bigTree("big-tree-winter", .winter, photo: true)`;
    - `bigTreeHit("big-tree-hit-1", captures: [6, 9, 21, 72])`;
    - `bigTreeHit("big-tree-hit-2", captures: [6, 10, 22, 72])`;
    - `bigTreeHit("big-tree-hit-3", captures: [6, 12, 28, 44, 90])`.
  - The frames come from the defaults at 1/60 s, with the hit fired in `step(1)`: contact ≈ ⌈contactAt · 60⌉, peak = ⌈(contactAt + hitStop[l]) · 60⌉, burst = peak + 12, settle 72. For hit 3, the item is mid-fall at peak + 16 and lands at ⌈(contactAt + hitStop + itemDelay + itemFall) · 60⌉ + 2. Task 6 Step 4 re-checks them against the first run.
- [ ] **Step 5: Run** `swift test --filter 'PlazaPondMapTests|PlazaPondSweepTests|PlazaBodySizeControllerTests|SpriteKitMirrorParityTests'`. Expected: PASS.
  - `PlazaCrossRenderCompareMacTests/testCommittedReferenceTreesAreCurrent` now fails. It lists the 18 new stems "(not in the reference)" and the moved fixtures' stems. This is the expected red.
- [ ] **Step 6: Commit** `test(team): pin the plaza map, classify tree tile checks and add big-tree render scenes` (done, `8060582e`). Revision 2 redo: `test(team): move plaza scene members clear of the 3x tree`.

### Task 2: The big-tree tile and the sweep

**Files:**
- Modify:
  - `Sources/PokeTokenBar/Team/Plaza/PlazaMap.swift:10-21`, `:100-106`: the case, with the doc comment "큰 나무: 걸을 수 없고 물이 아니며 던진 것을 막는다. 그림은 지도에 굽지 않고 `PlazaTreeLayer` 가 그린다", plus `isBigTree`.
  - `Sources/PokeTokenBar/Team/Plaza/PlazaMapData.swift`: rows 8, 9 and 10 (Pinned values).
  - `Sources/PokeTokenBar/Team/Plaza/PlazaSnow.swift:19`: `.bigTree` joins the `false` list.
  - `Sources/PokeTokenBar/Team/Plaza/PlazaItems.swift:58-70`: `candidates(in:)` skips `PlazaTree.coveredTiles(in: map)`. Doc: "큰 나무 밑동과 그 뒤 한 줄(잎이 아이템 자리를 덮는 칸)에는 놓지 않는다".
  - `Sources/PokeTokenBar/Team/Plaza/PlazaScene.swift:786-790`: `resolvedTile` also returns `t` when `map.isBigTree(t)`. Doc: "구버전 팀원은 큰 나무 칸을 걸어 지나간다. 쉼터로 튀지 않고 그 칸(나무 뒤)에 그린다".
  - `Tests/PokeTokenBarTests/PlazaPondSweepTests+Mac.swift`: both allow-lists.
- Create: `Sources/PokeTokenBar/Team/Plaza/PlazaTree.swift`, with the day constants, `tiles`, `artRect`, `coveredTiles`, `z`, `scale` and the crop size only for now.
- Test:
  - Create `Tests/PokeTokenBarTests/PlazaTreeTests.swift`.
  - Modify `PlazaMapTests.swift`, `PlazaItemsTests.swift`, `PlazaSnowballTests.swift`, `PlazaDittoBrainTests.swift`.
  - Create `Tests/PokeTokenBarTests/PlazaTreeLayerTests.swift` (scene tests; Task 4 fills it).
- Task 2 changes no pixel of any map image: `'B'` falls to the tile switch's `default` and draws grass. So `PlazaSeasonTests+Bundled`'s pinned looks stay green.

**Interfaces:**
- Produces `PlazaTile.bigTree`, `PlazaMap.isBigTree`, and `PlazaTree.tiles`, `artRect`, `coveredTiles` and `z`.
- `PlazaTree` reads the tree through `isBigTree` only (the scan).

- [ ] **Step 1: Write the failing tests.**
  - `PlazaTreeTests`:
    - `testTheTreeIsTheBRun`:
      - `PlazaTile(rawValue: "B") == .bigTree` and `.bigTree.isWalkable == false`;
      - `tiles(in: PlazaMapData.map)` is exactly x16...18 × y8...10;
      - `artRect == CGRect(x: 497, y: 208, width: 126, height: 144)`;
      - `coveredTiles` is x16...18 × y7...10, and `z == 1.34375`;
      - on a map without `'B'` (`PlazaMap(rows: ["SN..", "...."])`), `tiles` is empty and the rest are nil or empty.
    - `testTheTreeAnswersLikeTheGrassItReplaced` (the equivalence test, Sweep A).
    - `testTheTreeStandsOnPlainGrassReachableFromEverySide`:
      - on `old`, the nine tiles are `'.'`;
      - on the new map, every 4-neighbour of the run is walkable;
      - `artRect` overlaps no shelter, board, bush, tall-grass, water, campfire or border tile;
      - every feature in the Footprint table is at Chebyshev ≥ 3 from the footprint, and the spawn is outside `coveredTiles`.
  - `PlazaMapTests.testAMapWithABParses`: `PlazaMap(rows: ["SN..", "BB.."])` parses, and the `'B'` tiles are neither walkable nor water.
  - `PlazaItemsTests`:
    - `testItemsUnderTheBigTreeAreHidden`: for a `Spawn` on each of the 12 covered tiles (x16...18 × y7...10), `isShown(_, openTiles: openTiles(in: map)) == false`. Spawns on (15,9), (17,6) and (19,8) are shown.
    - `testSpawnCandidatesAreUnchanged`: `spawnCandidates == candidates(in: PlazaMapData.itemLayoutMap)`, with the count pinned from the first run.
  - `PlazaSnowballTests.testTheBigTreeStopsABall`: `aim(from: (14,10), facing: .right, bodies: [:], map:)` ends `.ground((15,10))`. `aim(from: (15,10), …)` is nil (the next tile is blocked).
  - `PlazaDittoBrainTests.testTheDittoWalksAroundTheBigTree`: a brain route from (15,10) to the far side never enters a `'B'` tile (use the file's existing route helper).
  - `PlazaTreeLayerTests`:
    - `testAnOldPeerOnTheTrunkIsDrawnThere`: `applyMembers` with a member at (17,10). Then `memberFoot` is (17,10)'s foot, not a shelter tile.
    - `testABlockedTileThatIsNotTheTreeStillGoesToTheShelter`: a member at the bush (15,4) is drawn on a shelter tile (the old rule, unchanged).
- [ ] **Step 2: Run** `swift test --filter 'PlazaTreeTests|PlazaMapTests'`. Expected: the build fails (`type 'PlazaTile' has no member 'bigTree'`).
- [ ] **Step 3: Implement** the Interfaces. Update both scan allow-lists.
- [ ] **Step 4: Run** `swift test --filter 'PlazaTreeTests|PlazaTreeLayerTests|PlazaMapTests|PlazaPondMapTests|PlazaItemsTests|PlazaSnowballTests|PlazaSnowTests|PlazaDittoBrainTests|PlazaDittoTests|PlazaPathfinderTests|PlazaWalkerTests|PlazaDragTests|PlazaTackleReachTests|PlazaTargetingTests|PlazaPondSweepTests|PlazaSeasonTests|PlazaTileArtTests|PlazaArtParityPixelArtTests|PlazaBodySizeControllerTests|PlazaWindowTests'`. Expected: PASS, and `PlazaSeasonTests+Bundled`'s pinned look hashes are unchanged.
- [ ] **Step 5: Injection.** Run each change with Step 4's filter, then revert it:
  - Put `.bigTree` in the walkable list. Expected: the equivalence test FAILs.
  - Put `.bigTree` in `isSnowGround`'s `true` list. Expected: the equivalence test FAILs.
  - Drop the `coveredTiles` skip. Expected: `testItemsUnderTheBigTreeAreHidden` FAILs (row 7).
  - Compute the skip from `PlazaMapData.map` instead of the given map. Expected: `testSpawnCandidatesAreUnchanged` FAILs.
  - Drop the `isBigTree` branch from `resolvedTile`. Expected: `testAnOldPeerOnTheTrunkIsDrawnThere` FAILs.

  After the last revert, run the filter again. Expected: PASS.
- [ ] **Step 6: Run** `scripts/shared-check.sh`. Expected: it builds.
- [ ] **Step 7: Commit** `feat(team): block a 3x2 big-tree footprint on the plaza map` (done, `5ae1ade4`). Revision 2 redo: `feat(team): grow the big-tree footprint to 3x3 for the 3x pine`.

### Task 3: The pine art and the minimap

**Files:**
- Modify:
  - `Sources/PokeTokenBar/Team/Plaza/PlazaResources.swift:39-47`: `treeCrop`.
  - `Sources/PokeTokenBar/Team/Plaza/PlazaSnowSheet.swift`: `recolored(_:rows:)`, sharing the inner swap with `recolored(_:pieces:)`. `PlazaSnowSheet`'s outputs stay byte-identical (`PlazaArtParityPixelArtTests`).
  - `Sources/PokeTokenBar/Team/Plaza/PlazaTree.swift`: the art part of Pinned values (`canopyRows` … `baked`, with `seasonLeaves`, `skirt`, `skirtGround`, `burstArt` and `canopySpawnPoints`).
  - `Sources/PokeTokenBar/Team/Plaza/PlazaSeasonSheet.swift`: `groundColors(_:)`, which returns the table the season already applies to `PlazaTileArt.grassCells` (`autumnGround` stays private behind it). No output of the sheet changes; `PlazaSeasonTests+Bundled`'s pinned looks prove it.
  - `Sources/PokeTokenBar/Team/Plaza/PlazaWindowController.swift`:
    - a static `cachedMinimapImages: [PlazaSeason: PlazaImage]`;
    - `minimapImage(for:)`: the season's map image (`seasonLook(for:season:)?.mapImage`, or `mapImage` for summer) baked with `PlazaTree.image(PlatformPlaza.tallGrassSheet(), season:)` at `PlazaTree.artRect(in: map)`. It returns the plain image when either is missing;
    - `seasonChanged` (`:196-199`) sets `minimap.seasonMapImage = season == .summer ? nil : minimapImage(for: season)`, so `minimapShowsSnow` keeps its meaning;
    - `minimapPanel`'s closure (`:144-145`) returns `minimapImage(for: .summer)`.
  - `Sources/PokeTokenBar/Resources/Plaza/CREDITS.md`, `## Tall grass` section. Add: "- The plaza's big tree is the pine at (83, 48), 42×48, cut from this image at runtime and drawn at 3×. In spring, autumn and winter its four leaf colours get exact colour swaps, and in every season the light patch under it takes that season's ground shade. The cut and recoloured pine is a derivative and stays under CC-BY-SA 3.0."
- Test: create `Tests/PokeTokenBarTests/PlazaTreeTests+Bundled.swift`; modify `PlazaResourcesTests.swift`, `PlazaSnowSheetTests.swift` and `PlazaMinimapTests.swift` (or the file that already reads `minimapShowsSnow`).

**Interfaces:** as in Pinned values. `image(_:season:)` is nil when the sheet is not 208×144 (a synthetic test sheet), so the tree layer is not built.

- [ ] **Step 1: Write the failing tests.**
  - `PlazaTreeTests+Bundled` (sheet from `PlatformPlaza.tallGrassSheet()`):
    - `testTheCropIsThePineAsShipped`: the raw crop (`sheet.cropping(to: treeCrop)`, before any swap) is 42×48 and byte-equal to the sheet's (83,48) region. Its opaque count is 1,464, and the colour counts per row band are the Footprint table's. The summer image's canopy rows and every trunk and outline pixel are byte-equal to the crop.
    - `testLeafColoursNeverTouchTheTrunk`: the canopy rows hold exactly {`#99E550`, `#6ABE30`, `#4B692F`, `#524B24`, `#222034`}. The trunk colours {`#663931`, `#8F563B`, `#45283C`} appear only in `groundRows`. The two sets do not meet.
    - `testEachSeasonSwapsOnlyItsBand`. For every season:
      - alpha bytes equal summer's;
      - every pixel with a trunk colour or the outline is unchanged;
      - canopy pixels equal `canopyColors(s)` applied to the raw crop's, and ground pixels equal `groundColors(s)` applied to the raw crop's;
      - the canopy's colours are exactly `seasonLeaves[s]` plus the outline (in summer, `leafColors` plus the outline), so no source leaf colour is left in spring, autumn or winter.
    - `testTheSkirtTakesTheSeasonsGroundShade` (decision (e)). For every season, the ground band's colours other than the trunk, the outline and the canopy's mapped `#524B24`:
      - are exactly {disc, ring} from ruling 15's table;
      - are a subset of the colours in that season's grass cells: `PlazaTileArt.grassCells` cut from `PlazaSeasonSheet.tiles(sheet, season:)`;
      - no source skirt colour (`#6ABE30`, `#4B692F`) is left in the band.
    - `testTheBurstMatchesTheTreesLook`: `burstArt` is (.greenLeaves, [0...3]) in summer and spring, (.leaves, [0, 1, 4, 5]) in autumn and (.snow, [0, 1, 2]) in winter. Every index is inside `PlazaWeatherArt.grids(kind)`. Autumn's grids hold no `R`/`r` cell.
    - `testTheBandsTileTheImage`: `bands` has four images of heights 10, 10, 10 and 18. Stacked, they are byte-equal to the image.
    - `testEveryMapImageIsUnchanged`: for each season, the look built from `PlazaMapData.map` equals the look built from `old` (`'B'` → `'.'`) byte for byte, and so does `PlazaTileArt.mapImage` (summer).
    - `testTheMinimapShowsTheTreeInEverySeason`. For each season, `baked(map, tree: image, at: artRect)`:
      - equals the map outside `artRect`;
      - inside it, every `scale`×`scale` (3×3) block under an opaque tree pixel is that pixel;
      - transparent tree pixels leave the map.
  - `PlazaSnowSheetTests.testRowRecolourMatchesCellRecolourOnACellAlignedBand`: on a 32×32 sheet, `recolored(rows: [(c, 0..<16)])` equals `recolored(pieces: [(c, [(0,0), (1,0)])])`. A row outside the band is unchanged.
  - `PlazaResourcesTests.testCreditsNameTheBigTreeCut`: the needles are `(83, 48)`, `42×48`, `big tree` and `plaza-tallgrass.png`.
  - Minimap controller test, `testTheMinimapImageHasTheTreeAndKeepsTheSnowFlag`:
    - in summer, the panel's image differs from `mapImage` only inside `artRect`, and `minimapShowsSnow` is false;
    - in winter, `seasonMapImage` is set and `minimapShowsSnow` follows the scene.
- [ ] **Step 2: Run** `swift test --filter 'PlazaTreeTests|PlazaSnowSheetTests'`. Expected: the build fails (`PlazaTree` has no member `image`).
- [ ] **Step 3: Implement** the Interfaces and the credit line.
- [ ] **Step 4: Run** `swift test --filter 'PlazaTreeTests|PlazaSnowSheetTests|PlazaSeasonTests|PlazaArtParityPixelArtTests|PlazaArtParityTests|PlazaResourcesTests|PlazaMinimap|PlazaTileArtTests'`. Expected: PASS.
- [ ] **Step 5: Injection.** Run each change with Step 4's filter, then revert it:
  - Recolour with one table over all rows. Expected: `testEachSeasonSwapsOnlyItsBand` and `testTheSkirtTakesTheSeasonsGroundShade` FAIL (the skirt takes leaf colours).
  - Map the skirt with `PlazaSeasonSheet.tallGrassColors` (revision 1). Expected: `testTheSkirtTakesTheSeasonsGroundShade` FAILs.
  - Crop at (84, 48). Expected: `testTheCropIsThePineAsShipped` FAILs.
  - Bake without skipping transparent pixels (write alpha 0 over the map). Expected: `testTheMinimapShowsTheTreeInEverySeason` FAILs.

  After the last revert, run Step 4's filter. Expected: PASS.
- [ ] **Step 6: Run** `scripts/shared-check.sh`. Expected: it builds.
- [ ] **Step 7: Commit** `feat(team): cut the plaza big tree from the tall-grass sheet with season colours and a minimap copy` (done, `e172d4de`). Revision 2 redo: `feat(team): draw the big tree at 3x with the season leaf table and a ground-shade skirt`.

### Task 4: The tree at rest (layer, depth, seasons, photo, background)

**Files:**
- Create: `Sources/PokeTokenBar/Team/Plaza/PlazaTreeLayer.swift`. This task makes `root`, the four bands and `fxRoot`. Task 6 adds the pools.
- Modify `Sources/PokeTokenBar/Team/Plaza/PlazaScene.swift`:
  - a static `treeImages`, decoded once like `ballImages` (`:2097-2106`);
  - `treeTiles`;
  - `treeLayer`, built beside the campfire node (`:496`) when `pondVisuals`, `!treeTiles.isEmpty` and `treeImages.count == 4`. Its roots are added before `weatherLayer.root`;
  - `refreshSnowDay` (`:2109`): `treeLayer?.setSeason(s)`;
  - `setBackgroundHidden` (`:572`): `treeLayer?.setHidden(hidden)`;
  - `photoInput` (`:1402`): `props: campfirePhotoProps + (treeLayer?.photoProps() ?? [])`;
  - test reads `isTreeShown`, `treeZ` and `treeNodeCount`.
- Test: `PlazaTreeLayerTests.swift` (the real map, `pondVisuals: true`, bundled sheets).

**Interfaces:**
- Bands:
  - each is a `PlazaSprite` of its band image at `scale`, anchored at its bottom-left;
  - it is placed at the band's rest rect in `artRect`: the bottom band's bottom on baseY;
  - positions are snapped with `PlazaPixelSnap.step`, as the steam layer does.
- `root.zPosition = PlazaTree.z(in:)`; bands have local z 0.
- `setSeason` swaps the four band textures (and, from Task 6, the leaf textures: `burstArt(s)`'s grids at `leafScale`). Each season's textures are made once.
- `photoProps()`: one `PlazaPhotoProp` per band at its current rect, `baseY = (maxY + 1) · 32`.

- [ ] **Step 1: Write the failing tests.**
  - `testTheTreeIsDrawnAtItsRect`:
    - a scene at (17,12): `isTreeShown`;
    - the bands' union frame in world px is `artRect`;
    - `treeNodeCount` counts the roots and bands (Task 6 raises it).
  - `testTeammatesInFrontAndBehind`:
    - members at (17,11), (15,10), (19,10), (17,7) and (16,12);
    - `memberZ` is above `treeZ` for rows 11 and 12, and below it for (15,10), (19,10) and (17,7).
  - `testPlatesAndBubblesStayOverTheTree`: a member at (17,7) with a chat line. The plate and the bubble are camera-space (`memberNamePlateVisible == true`), and their z is above the daylight.
  - `testWeatherAndDaylightLieOverTheTree`: `weather z > treeZ`, `daylight z > treeZ`, `steam z > treeZ` (the `PlazaWeatherTests+Scene` pattern).
  - `testSeasonsSwapTheArt`: in winter, the canopy bands' texture pixels contain no source leaf colour (`leafColors`), and do contain `seasonLeaves[.winter]`. Back to summer, they are byte-equal to `bands(image(.summer))`.
  - `testHidingTheBackgroundHidesTheTreeButKeepsItsWall`:
    - `setBackgroundHidden(true)` → `isTreeShown == false`;
    - the walker at (17,11) pressing up stays at (17,11);
    - back to false → shown.
  - `testThePhotoCarriesTheTree`:
    - a winter scene's `photoInput()?.props` has four tree props with baseY 352;
    - a rendered photo (`PlazaPhotoRenderer.render`) has the winter leaf `#F4F8FC` inside `artRect`. A member at (17,7) is drawn under the canopy pixels below its head, and its head shows above y 208.
  - `testAMapWithoutTheTreeHasNoLayer`: a scene on `PlazaMap(rows: ["SN..", "...."])` → `treeNodeCount == 0`.
- [ ] **Step 2: Run** `swift test --filter PlazaTreeLayerTests`. Expected: the build fails (`cannot find 'PlazaTreeLayer' in scope`).
- [ ] **Step 3: Implement** the Interfaces.
- [ ] **Step 4: Run** `swift test --filter 'PlazaTreeLayerTests|PlazaPhotoTests|PlazaPhotoParityTests|PlazaWeatherTests|PlazaSnowSceneTests|PlazaCampfireTests|TeamHostilePeerTests|SpriteKitMirrorParityTests|PlazaSceneTests'`. Expected: PASS.
- [ ] **Step 5: Injection.** Run each change with Step 4's filter, then revert it:
  - Compute `z` from `maxY` instead of `maxY + 1`. Expected: `testTeammatesInFrontAndBehind` FAILs at (15,10).
  - Skip `setHidden` in `setBackgroundHidden`. Expected: `testHidingTheBackgroundHidesTheTreeButKeepsItsWall` FAILs.
  - Skip `setSeason` in `refreshSnowDay`. Expected: `testSeasonsSwapTheArt` FAILs.

  After the last revert, run Step 4's filter. Expected: PASS.
- [ ] **Step 6: Run** `scripts/shared-check.sh`. Expected: it builds.
- [ ] **Step 7: Commit** `feat(team): stand the big tree in the plaza with depth, seasons and photos`.

### Task 5: The hit timeline (pure)

**Files:**
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaTree.swift`: the hit-feel constants, the timeline functions, `level`, `isFacing`, `touches`, `hitDirection`, `PlazaTreeLeaf`, `PlazaTreeLeaves`, `PlazaTreeItemFall`, `itemStart` and `impactPoint`.
- Test: `PlazaTreeTests.swift`.

- [ ] **Step 1: Write the failing tests.**
  - Reach, with the bodies from Pinned values:
    - `testClassOneHitsTheFacedTile`: (17,11) facing `.up`, (15,9) facing `.right` and (16,7) facing `.down` hit. (17,11) facing `.left` does not, and neither does (14,10) facing `.right`.
    - `testABigBodyHitsWithItsBody` (B only, the foot's faced tile is not a tree tile):
      - class 3 at (15,11) facing `.right` hits;
      - class 2 at (17,12) facing `.up` hits;
      - class 2 at (19,11) facing `.left` hits.
    - `testTouchingButFacingAwayDoesNotHit`: class 2 at (19,11) facing `.down` or `.right` does not hit, and `touches` is true for it.
    - `testNoSwimmerCanFaceOrTouchTheTree` (ruling 9): for every water tile of the real map, every class (1...3) and every direction, `isFacing` and `touches` are false.
    - `testHitDirection`: facing wins when facing. Otherwise the side: (15,9) → `.right`, (19,10) → `.left`, (17,7) → `.down`, (17,11) → `.up`.
  - Strength, `testOnlyTheDropIsLevelThree`:
    - `level(hits: 1…6, drops: [f, f, t, f, f, f])` is [1, 2, 3, 1, 2, 2];
    - `level(hits: 3, drops: false) == 2`.
  - The timeline:
    - `testTheBendStartsAwayHoldsThenSwingsToRest`, per level:
      - 0 before `contactAt`;
      - `bend[l]` at contact and at hold end − 0.001;
      - negative near t′ = `swingPeriod`/2;
      - |bend| < 0.5 by t′ = `swingLength`, and 0 after it.
    - `testBandsAndStretch`:
      - `bandOffsets(bend: 3) == [3, 3, 0, 0]`, `(6) == [6, 3, 3, 0]`, `(9) == [9, 6, 3, 0]`, `(−4.7) == [−6, −3, −3, 0]`; every offset is a multiple of `scale`;
      - `stretch(bend: 9) == 1.0625`, `stretch(bend: −4.7) == 1 − 6 / 144`.
    - `testTheTacklerHoldsAtContactThenRecoils`:
      - `lungeOffset` rises to `lungeDistance[l]` by `contactAt` and is constant through the hold (sampled every 1/240 s);
      - it reaches `−recoil[l]` at hold end + `recoilDuration` and is 0 from `lungeLength(l)`.
    - `testEveryLevelIsStrongerThanTheOneBefore`: for each per-level table, the entries strictly increase.
    - `testTheCameraKickIsLevelThreeOnly`: 0 for levels 1 and 2 at all t. For 3 it peaks at `cameraKick` and is 0 at contact and at contact + `cameraKickDuration`.
    - `testTheImpactSitsBetweenTacklerAndTrunk`: for foot (560, 380) `.up`, the point is (560, 364 − max(h, 24) · 0.55), and it is mirrored per direction.
  - Leaves:
    - `testABurstScattersAwayAndUpThenFallsAndRests`:
      - `burst(count: 8, direction: .right, grids: [0, 1, 2, 3])` makes 8 leaves, each starting on one of `canopySpawnPoints` (an opaque canopy pixel of the summer image);
      - after 0.1 s every leaf has moved right and up;
      - each later reaches its `groundY` (`restedAt` set), fades over `leafRest` and is gone by `leafLife`.
    - `testTheFieldNeverHoldsMoreThanTheCap`: 1,000 bursts of 8, with an advance of 1/60 between each: the count is ≤ 12 at every step.
    - `testTheSameBurstNumberGivesTheSameLeaves`: two fields with the same bursts and advances are equal.
  - Item:
    - `testTheItemStartsAboveTheTackler`: for feet (560, 380) (`.up`), `itemStart` is (560, 298). For (496, 348) (`.right` from x15), it is (521, 298). For (560, 252) (`.down` from row 7), it is (560, 204), 48 px above the feet.
    - `testTheItemFallsFromTheCanopyToTheFeet`:
      - `position(0) == itemStart(...)`;
      - `position(itemFall) == to`;
      - its y stays ≤ `to.y` and above the arc's line;
      - it bounces `itemBounce` within `itemBounceDuration`;
      - it is nil after that.
- [ ] **Step 2: Run** `swift test --filter PlazaTreeTests`. Expected: the build fails (`PlazaTree` has no member `bendAmount`).
- [ ] **Step 3: Implement** the Interfaces.
- [ ] **Step 4: Run** Step 2's filter. Expected: PASS.
- [ ] **Step 5: Injection.** Run each change with the filter, then revert it:
  - Let the lunge keep moving through the hold. Expected: `testTheTacklerHoldsAtContactThenRecoils` FAILs.
  - Start the bend toward the tackler (negative sign). Expected: `testTheBendStartsAwayHoldsThenSwingsToRest` FAILs.
  - Append a burst without recycling. Expected: `testTheFieldNeverHoldsMoreThanTheCap` FAILs.
  - Return 3 for every third hit. Expected: `testOnlyTheDropIsLevelThree` FAILs.

  After the last revert, run the filter. Expected: PASS.
- [ ] **Step 6: Run** `scripts/shared-check.sh`. Expected: it builds.
- [ ] **Step 7: Commit** `feat(team): add the big-tree hit timeline, reach rule and leaf field`.

### Task 6: The hit on screen

**Files:**
- Modify:
  - `Sources/PokeTokenBar/Team/Plaza/PlazaTreeLayer.swift`: the pools (12 leaves, 2 dust, the impact, the item), `hit`, `update`, `isBusy` and the Task 6 test reads.
  - `Sources/PokeTokenBar/Team/Plaza/PlazaActor.swift:198-200`, `:273-282`, `:296-299`: `treeLunge`. The lunge state gains `level: Int?`; nil keeps today's sine curve and duration.
  - `Sources/PokeTokenBar/Team/Plaza/PlazaScene.swift`:
    - `playTreeHit`;
    - `advanceTree(by:)` after `advanceSteam(by:)` in `update` (`:1994`). When the layer reports a landing, it calls `playSparkle(memberID: tackler)`;
    - the camera-kick state, advanced before `layout()`, which adds `PlazaTree.cameraKick` along its direction to `cameraPos` (`:2222`) before the actor context is built;
    - the remaining test reads.
  - `Tests/PokeTokenBarTests/PlazaRenderScenes.swift`, `bigTreeHit` calls, in `step(1)`:
    - hit-1 `playTreeHit(by: "ash", direction: .right, level: 1, drop: nil)`;
    - hit-2 `by: "brock", direction: .left, level: 2`;
    - hit-3 `by: nil, direction: .up, level: 3, drop: .mint`.
- Test: `PlazaTreeLayerTests.swift`, `TeamHostilePeerTests.swift`.

**Interfaces:**
- `playTreeHit(by tackler:direction:level:drop:)`:
  - `guard !isPaused, let actor = actor(tackler)`;
  - `actor.treeLunge(toward: direction, level:)`;
  - `treeLayer?.hit(direction:level:tacklerFoot:tacklerHeight:drop:)`, with the tackler's foot point and `characterSize.height`;
  - when `tackler == nil && level == 3`, start the camera kick.
- `PlazaTreeLayer.update(dt:visible:step:)`:
  - The leaf field starts from `PlazaTree.canopySpawnPoints(images[.summer], artRect:)`, computed once in `init`. A burst uses the current season's `burstArt` grids.
  - Idle (no shake, no shown leaf, no impact, no fall): return false at once, with no node write.
  - Otherwise advance the timeline, the leaf field, the dust, the impact and the fall.
  - When `artRect` grown by one tile misses `visible`, write nothing. The timeline still advances, so a tree scrolled into view shows the right moment.
  - Return true on the one frame the fall passes `itemFall`.
- Background hidden: `root` is hidden and the leaf and dust clocks still run. `fxRoot` draws.

- [ ] **Step 1: Write the failing tests.**
  - `testThePoolIsMadeOnceAndNeverGrows`:
    - a scene at (17,12): `treeNodeCount == 22` (2 roots + 20 sprites), and that count is in the scene's `children` from the first frame;
    - after 1,000 `playTreeHit`s across levels, directions and drops, with 600 updates of 1/60 between and after, it is still 23 and the scene's other node counts are unchanged.
  - `testAPausedSceneDoesNothing`: `isPaused = true`; 100 hits; `lungeOffset(memberID:)` is 0, `isTreeBusy` is false and every node count is unchanged.
  - `testAnIdleTreeWritesNothing`: record `spriteStates` (position, alpha, texture, hidden, scale). After 600 idle updates they are identical.
  - `testAnOffscreenHitAdvancesButWritesNothing`:
    - me at (34,17); a member at (17,11) hits; 0.2 s of updates: `spriteStates` unchanged;
    - then move me to (17,12) and run 0.05 s: the bend matches `bendAmount` at the total elapsed time.
  - `testAHorizontalHitShearsAwayAndSettles`:
    - Ash at (15,10) `.right`, level 2;
    - at the hold, `treeBandOffsets == [6, 3, 3, 0]`, and all are 0 after `contactAt + hitStop + swingLength`;
    - `.left` from (19,10) mirrors it;
    - the bottom band never moves.
  - `testAVerticalHitStretchesOrSquashes`: `.up` → `treeStretch > 1`; `.down` from (17,7) → `< 1`; 1 at rest.
  - `testHitStopHoldsTheTacklerAndTheTree`: over `[contactAt, contactAt + hitStop[l]]`, at 1/240 s steps, the tackler's `lungeOffset` and `treeBandOffsets` do not change.
  - `testTheBurstGrowsWithTheLevel`: just after the hold, `treeLeafCount` is 3, 5 and 8 for levels 1, 2 and 3. A level-3 hit on top of 8 shown leaves keeps it at 12 at most.
  - `testTheDropFallsToTheTacklersFeetAndSparklesOnce`:
    - my level-3 hit with `.mint`: `treeItemPosition` goes from the canopy to my foot;
    - `sparkleCount` goes 0 → 7 on the landing frame and never again;
    - a second hit 0.2 s into the fall restarts the fall, and only its landing sparkles.
  - `testOnlyMyDropKicksTheCamera`:
    - my level-3 hit moves `cameraPosition` by 2 px in the hit direction at contact + 0.04 and back by contact + 0.12;
    - `visibleWorldRect` does not move;
    - a teammate's level-3 hit and my level-2 hit leave `cameraKickOffset == .zero` throughout.
  - `testWithTheBackgroundHiddenOnlyTheTacklerAndTheStarPlay`: hidden background; a level-3 drop hit: the lunge plays, `isImpactShown` and `treeItemPosition` are non-nil, and `isTreeShown == false`.
  - `testThePhotoFollowsTheBend`: during a horizontal hit, `photoInput()?.props` band origins carry `treeBandOffsets`, and shown leaves are props too.
  - `TeamHostilePeerTests.testATreeShakeFloodAddsNoNode`:
    - `pondVisuals: true`; assert `treeNodeCount == 22` first, so the test cannot pass vacuously (found list);
    - 1,000 `playTreeHit(by: "A", …, drop: .mint)` within one frame, then 2 s of updates;
    - `children.count` is unchanged and `sparkleCount` peaks at ≤ 7;
    - repeat on a paused scene: nothing changes.
- [ ] **Step 2: Run** `swift test --filter PlazaTreeLayerTests`. Expected: the build fails (`value of type 'PlazaScene' has no member 'playTreeHit'`).
- [ ] **Step 3: Implement** the Interfaces.
- [ ] **Step 4: Run** `swift test --filter 'PlazaTreeLayerTests|PlazaTreeTests|TeamHostilePeerTests|PlazaActorTests|PlazaTackleTests|PlazaPhotoTests|PlazaPhotoParityTests|PlazaSceneTests|SpriteKitMirrorParityTests|PlazaWeatherTests'`. Expected: PASS.
  - Render `big-tree-hit-*` once with `PTB_PLAZA_RENDER_ONLY=big-tree-hit-1,big-tree-hit-2,big-tree-hit-3 scripts/plaza-render-compare.sh --scratch "$S" --runs 1`.
  - Check by eye that each capture frame shows its moment: contact (star and hold), peak, burst, settle, and for hit 3 the item falling and landing. If one is off by a frame or two, move the capture in `PlazaRenderScenes` now.
- [ ] **Step 5: Injection.** Run each change with Step 4's filter, then revert it:
  - Make a leaf sprite per burst instead of using the pool. Expected: `testThePoolIsMadeOnceAndNeverGrows` FAILs.
  - Write the band positions every frame, even when idle. Expected: `testAnIdleTreeWritesNothing` FAILs.
  - Kick the camera for every level-3 hit. Expected: `testOnlyMyDropKicksTheCamera` FAILs.
  - Sparkle at every restart. Expected: `testATreeShakeFloodAddsNoNode` and `testTheDropFallsToTheTacklersFeetAndSparklesOnce` FAIL.
  - Drop the `isPaused` guard. Expected: `testAPausedSceneDoesNothing` FAILs.

  After the last revert, run Step 4's filter. Expected: PASS.
- [ ] **Step 6: Run** `scripts/shared-check.sh`. Expected: it builds.
- [ ] **Step 7: Commit** `feat(team): shake the big tree with hit-stop, recoil, leaves, dust and a falling item`.

### Task 7: The day count, the saved state and the wire

**Files:**
- Modify:
  - `Sources/PokeTokenBar/Team/Plaza/PlazaTree.swift`: `PlazaTreeDay`.
  - `Sources/PokeTokenBar/Team/Plaza/PlazaPreferences.swift:13`, `:93-105`: `treeKey`, `tree`.
  - `Sources/PokeTokenBar/Team/TeamWire.swift`:
    - `:91-133`: `case treeShake`. Doc: "큰 나무 흔들기 (C facing the plaza's big tree): the sender's lunge, star, shake, leaves and dust, drawn only where the sender's body touches the tree. `pushTiles` is the hit's strength (1–3, 3 only with `treeDrop`). Nobody is moved. Earlier versions skip it.";
    - `:134-148`: `notifiesTarget` false, `endsSendersDance` true;
    - `:179`: `@LossyOptional var treeDrop: ItemKind?`. Doc: "A tree shake that dropped an item into the sender's bag: drawn falling to the sender. Left out by every other shake and kind. Unreadable values and unknown kinds become nil; earlier versions skip the frame."
  - `Sources/PokeTokenBar/Team/TeamSession.swift:271-279`: `treeDrop:` in `sendEmote`.
  - `Sources/PokeTokenBar/Team/TeamLocalization.swift:270-292`: `.treeShake: "나무 흔들기"`, and `plazaTreeDropped` after `plazaPickedUp` (`:169`).
  - `Sources/PokeTokenBar/Team/Plaza/PlazaEmoteArt.swift:131`: `.treeShake` draws the impact grid ("never shown as a bubble").
- Test: `PlazaTreeTests.swift`, `PlazaPreferencesTests.swift`, `TeamWireTests.swift`, `TeamHostilePeerTests.swift`.

- [ ] **Step 1: Write the failing tests.**
  - `PlazaTreeTests`:
    - `testTheThirdHitDropsAndTheFourthDoesNot`: on "2026-11-21", the hits return [f, f, t, f, f, f]. `dropped == 1` after them.
    - `testANewDayDropsAgain`: three hits on "2026-11-21", then "2026-11-22": hits 1, 2, 3 → the third drops.
    - `testTheDayTurnsAtLocalMidnight`:
      - with a fixed `Calendar(identifier: .gregorian)` in `Asia/Seoul`, `PlazaActivity.dayKey` of 23:59:59 and 00:00:00 differ, and of 00:00:00 and 00:00:01 are equal;
      - two hits at 23:59:58/59 and one at 00:00:00 do not drop;
      - two more on the new day drop.
    - `testAClockSetBackGivesNoSecondMint`:
      - three hits on "2026-11-22" (drop), then three on "2026-11-21": none drops, and `day` stays "2026-11-22";
      - then "2026-11-23" drops.
    - `testHitsStopAtTheCap`: from `hits = maxHits`, a hit keeps `maxHits`.
  - `PlazaPreferencesTests.testTheTreeDaySurvivesARestart`: set `tree` on one `PlazaPreferences(defaults: suite)` and read it from a new one. nil removes it. Garbage data reads nil.
  - `TeamWireTests`:
    - `:704`: the raw-value list ends `…, "drag", "treeShake"`;
    - `:196-197`: `.treeShake` is in the `endsSendersDance` set. `notifiesTarget` is false;
    - `testEveryOptionalFieldSurvivesARoundTrip` (`:101-120`): set `treeDrop = .mint`;
    - `testTreeDropIsOptionalOnTheWire`:
      - a shake without a drop has no `"treeDrop"` key;
      - `.mint` encodes `"treeDrop":"mint"` and round-trips;
      - level 2 encodes `"pushTiles":2`, and level 1 leaves the key out.
  - `TeamHostilePeerTests.testAbsurdTreeShakesBecomeHarmless`. For `"treeDrop"` values `"banana"`, `5`, `{}`, `null` and `"MINT"`:
    - the frame lives, and `onEmote` gets `.treeShake` with `treeDrop == nil`;
    - `"pushTiles": 99` → `TeamEmote.pushTiles` is 3, and `-1` → 1;
    - control: `"mint"` → `.mint`.
- [ ] **Step 2: Run** `swift test --filter 'PlazaTreeTests|PlazaPreferencesTests|TeamWireTests|TeamHostilePeerTests'`. Expected: the build fails (`cannot find 'PlazaTreeDay' in scope`).
- [ ] **Step 3: Implement** the Interfaces.
- [ ] **Step 4: Run** Step 2's filter. Expected: PASS.
- [ ] **Step 5: Injection.** Run each change with the filter, then revert it:
  - Roll over on any different day. Expected: `testAClockSetBackGivesNoSecondMint` FAILs.
  - Drop on `hits >= hitsPerDrop` without `dropped`. Expected: `testTheThirdHitDropsAndTheFourthDoesNot` FAILs.
  - Declare `treeDrop` without `@LossyOptional`. Expected: `testAbsurdTreeShakesBecomeHarmless` FAILs (the frame dies).

  After the last revert, run the filter. Expected: PASS.
- [ ] **Step 6: Run** `scripts/shared-check.sh`. Expected: it builds.
- [ ] **Step 7: Commit** `feat(team): count big-tree hits per local day and add the treeShake emote`.

### Task 8: C on the tree, the drop, and teammates' shakes

**Files:**
- Modify:
  - `Sources/PokeTokenBar/Team/Plaza/PlazaWindowController.swift`:
    - `treeDay`, loaded in `init` from `preferences.tree`;
    - `onTackleKey` (`:404-409`): after the `isDiving` return, `if self.hitTree() { return }`;
    - `hitTree()` and `showTreeShake(from:level:drop:)` after `tackle(_:)` (`:1085`);
    - test reads `bannersShown` and `treeHitsToday`.
  - `Sources/PokeTokenBar/Team/TeamRuntime.swift:56-120`: the `.treeShake` branch before `.pray`.
- Test:
  - Create `Tests/PokeTokenBarTests/PlazaTreeControllerTests.swift`. Copy `node`, `controller`, `settle`, `run`, `press`, `World`, `world` and `place` from `PlazaSnowballControllerTests`. Pass `grantItem: { granted.append($0) }` and `bannerSleep` as `PlazaItemsTests+Controller.swift:20-22` does. Use a settable `clock`.
  - Modify `TeamRuntimeTests.swift`.

**Interfaces:**
- `hitTree() -> Bool`:
  1. If `PlazaTree.isFacing(scene.myBody, facing: scene.walker.facing, tiles: scene.treeTiles)` is false, return false.
  2. The 0.3 s `lastEmoteAt` limit. When limited, return true (C does not fall through to a teammate).
  3. `scene.stopDance(memberID: nil)`.
  4. `let drops = treeDay.hit(on: PlazaActivity.dayKey(clock()))`, then `preferences.tree = treeDay`.
  5. `let level = PlazaTree.level(hits: treeDay.hits, drops: drops)`, and `drop = drops ? PlazaTree.dropItem : nil`.
  6. `scene.playTreeHit(by: nil, direction: scene.walker.facing, level:, drop:)`.
  7. `session?.sendEmote(.treeShake, target: nil, pushTiles: level, treeDrop: drop)`.
  8. With a drop: `grantItem(drop)`, `record(.pickup)`, `showBanner(L(.ko).plazaTreeDropped(drop))`.
  9. Return true.

  It records no `.tackle` (spec 2, 비목표).
- `showTreeShake(from:level:drop:)`:
  - draw only when `scene.memberTiles[sender] != nil` and `PlazaTree.touches(scene.body(of: sender)!, tiles: scene.treeTiles)`;
  - direction = `hitDirection(body, facing: members[sender]?.facing ?? .down, tiles:)`;
  - then `scene.playTreeHit(by: sender, …)`;
  - no `shove`, no grant, no banner, no record.

- [ ] **Step 1: Write the failing tests** in `PlazaTreeControllerTests` (shared).
  - Order and reach:
    - `testFacingTheTreeHitsItEvenWithATeammateBeside`:
      - me at (17,11) facing `.up`, b at (16,11); C;
      - my transport sent `.treeShake` and no `.tackle`, b's tile is unchanged and `treeHitsToday == 1`;
      - the same with b at (18,11), and with an old peer drawn at (17,10) inside the trunk.
    - `testFacingAwayStillTacklesTheTeammate`: me at (17,11) facing `.left` at b (16,11): a `.tackle` is sent and the tree count is 0.
    - `testABigBodyHitsFromWhereItsBodyReaches`: my body class 3 at (15,11) facing `.right` hits (B only). Facing `.down`, with b at (15,12), tackles b.
    - `testSpaceBesideTheTreeStillGreetsATeammate`: me at (17,11) facing `.up`, b at (16,11). Space opens b's menu, and the tree is no Space target.
    - `testNoHitWhileFocusingOrInPhotoMode`: focusing → C does nothing. Photo mode (`P`) → C is swallowed. `treeHitsToday == 0` after both.
    - `testHitsAreRateLimitedLikeATackle`: me at (17,11) facing `.up`, b at (16,11). Two C 0.29 s apart → one hit, and I still face `.up`. A fall-through would reach `faceNearbyMember`, which turns me to b, even though `tackle` itself is rate-limited by the same `lastEmoteAt`. 0.3 s apart → two hits.
  - The drop:
    - `testTheThirdHitGrantsOneMintOnce`:
      - three hits 0.3 s apart: `granted == [.mint]`;
      - `banner == "나무에서 민트가 떨어졌어요! 가방에 넣었어요"` and `bannersShown` rose by exactly 1;
      - the activity's `pickups == 1` and `tackles == 0`;
      - the third `.treeShake` carries `pushTiles 3, treeDrop .mint`, and the first two `1, nil` and `2, nil`;
      - a fourth hit grants nothing, shows no banner, and sends `1, nil`.
    - `testTheCountCrossesMidnight`: clock at 23:59:59.0 and .3 for two hits, then 00:00:00.0 for the third: no grant. Two more → one grant.
    - `testTheCountSurvivesAReopen`: two hits; `handleClose()`; a new controller on the same defaults; one hit → one grant.
    - `testAHiddenSceneStillDecides`: `setRendering(visible: false)` before the third hit (call `hitTree` through the key handler); `granted == [.mint]`.
  - Teammates' shakes:
    - `testATeammatesShakeIsDrawnWhereTheyTouchTheTree`:
      - b at (17,11) facing `.up` sends `.treeShake` level 2 → my scene: `isTreeBusy`, and b's lunge is non-zero within 0.1 s;
      - b's drop → `treeItemPosition` ends at b's foot;
      - `granted` is empty, `banner` is unchanged, my activity is unchanged and my tile is unchanged.
    - `// MARK: - Hostile peers`:
      - `testAShakeFromAPeerNotTouchingTheTreeIsIgnored`: b at (14,11), or b with `inPlaza: false` → `isTreeBusy == false` and b's lunge is 0.
      - `testAShakeWithAnUnknownItemShakesOnly`: a raw frame with `"treeDrop":"banana"` → busy, `treeItemPosition == nil`.
      - `testAShakeNeverMovesMe`: me at (17,12), b at (17,11); 100 shakes in 1 s → my tile is unchanged (PR 3's cooldown is not involved: nothing moves).
  - `TeamRuntimeTests.testATreeShakeGoesToTheTreeNotABubble`: a received `.treeShake` calls `showTreeShake` (a spy plaza), and `showEmote` is not called.
- [ ] **Step 2: Run** `swift test --filter 'PlazaTreeControllerTests|TeamRuntimeTests'`. Expected: the build fails (`value of type 'PlazaWindowController' has no member 'showTreeShake'`).
- [ ] **Step 3: Implement** the Interfaces.
- [ ] **Step 4: Run** `swift test --filter 'PlazaTreeControllerTests|PlazaTreeLayerTests|PlazaTreeTests|TeamRuntimeTests|TeamHostilePeerTests|PlazaItemsTests|PlazaActivityControllerTests|PlazaTackleTests|PlazaPullUnderTests|PlazaDragControllerTests|PlazaMimicControllerTests|PlazaDittoControllerTests|PlazaFocusTests|PlazaWindowShellTests|PlazaBodySizeControllerTests'`. Expected: PASS.
- [ ] **Step 5: Injection.** Run each change with Step 4's filter, then revert it:
  - Put `hitTree()` after `faceNearbyMember`. Expected: `testFacingTheTreeHitsItEvenWithATeammateBeside` FAILs.
  - Use the foot's faced tile only. Expected: `testABigBodyHitsFromWhereItsBodyReaches` FAILs.
  - Grant when the item lands (from the scene) instead of at the hit. Expected: `testAHiddenSceneStillDecides` FAILs.
  - Drop the `touches` check in `showTreeShake`. Expected: `testAShakeFromAPeerNotTouchingTheTreeIsIgnored` FAILs.
  - Return false when rate-limited. Expected: `testHitsAreRateLimitedLikeATackle` FAILs (the second C falls through and turns me to b).

  After the last revert, run Step 4's filter. Expected: PASS.
- [ ] **Step 6: Coverage.** Run with nothing else building:
```bash
swift test --enable-code-coverage --filter 'PlazaTreeTests|PlazaTreeLayerTests|PlazaTreeControllerTests|PlazaItemsTests|PlazaSnowballTests|PlazaSnowSheetTests|PlazaPreferencesTests|TeamWireTests|TeamSessionTests|TeamHostilePeerTests|TeamRuntimeTests'
BIN_PATH=$(swift build --show-bin-path); PROF=$(find "$BIN_PATH/" -name default.profdata | head -1)
BIN=$(find "$BIN_PATH/" -name PokeTokenBarPackageTests -type f ! -path '*.dSYM/*' | head -1)
LLVM_COV="$(dirname "$(realpath "$(command -v swift)")")/llvm-cov"; [ -x "$LLVM_COV" ] || LLVM_COV=$(xcrun --find llvm-cov)
BASE=$(git merge-base HEAD feat/plaza-hot-spring)
for f in $(git diff --name-only "$BASE" -- Sources/PokeTokenBar/Team); do
  CHANGED=$(git diff -U0 "$BASE" -- "$f" | awk '/^@@/{split($3,a,/[+,]/); n=(a[3]==""?1:a[3]); for(i=0;i<n;i++) print a[2]+i}')
  "$LLVM_COV" show "$BIN" -instr-profile="$PROF" --show-regions "$f" \
    | awk -F'|' '/^ *[0-9]+\|/{ln=$1+0} /\^0/{print ln}' | sort -u | grep -Fx -f <(echo "$CHANGED") | sed "s|^|$f:|"
done
```
  - This prints each added or changed source line that has a `^0` region.
  - Expected: nothing.
  - If a line is reported, write the missing branch's test. Do not mark it unreachable without the input-path check from CLAUDE.md step 3.
- [ ] **Step 7: Run** `scripts/shared-check.sh`. Expected: it builds.
- [ ] **Step 8: Commit** `feat(team): hit the big tree with C and drop a mint on the third hit of the day`.

### Task 9: Windows selftests

**Files:**
- Modify:
  - `Sources/PokeTokenBar/Platform/Windows/WindowsSelftestPlazaRender.swift:11-40`
  - `Sources/PokeTokenBar/Platform/Windows/WindowsSelftestPlaza.swift:208-246`

These are Windows-only (`#if os(Windows)`). The Mac does not compile them. The windows.yml selftest job checks them after the push.

- [ ] **Step 1: The render cost with the tree busy.**
  - Add a third `measure(…)` call, `plaza.renderCostTree`:
    - me at (17,12) facing up;
    - twelve members at x 13...24, y 12 and 7 (none on a `'B'` tile; those on row 7 x16–18 stand behind the tree), walking ±1 every 20 frames;
    - every 20 frames, `scene.playTreeHit(by: nil, direction: .up, level: 1 + n % 3, drop: n % 3 == 2 ? .mint : nil)` and a member's hit from (15,10);
    - the same winter night and fireworks.
  - The judgement is today's: median ≤ 4 ms and `failedFrames == 0`.
  - Add `tree=\(scene.isTreeShown) leaves=\(scene.treeLeafCount)` to its detail, and require `isTreeShown`.
  - `plaza.renderCost` (the first campfire seat) already has the tree's lower-right corner in view. That is spec 9.6's "나무가 화면 가장자리에 든다". Leave it.
- [ ] **Step 2: Idle.**
  - The idle plaza stands at the spawn (23,6), whose view includes the tree's top-right corner.
  - Add `treeBusy=\(scene?.isTreeBusy ?? false)` to `plaza.idleVisible`'s detail and `&& scene?.isTreeBusy != true` to its judgement. A tree at rest must add no draw.
- [ ] **Step 3: `map.txt`.** No change. There is no new file, and the `plaza-tallgrass.png` line already covers it (`package.ps1` checks it).
- [ ] **Step 4: Run** `scripts/shared-check.sh`. Expected: it builds.
- [ ] **Step 5: Commit** `test(windows): measure the plaza render cost with the big tree shaking`.

### Task 10: TEAM.md

**Files:** `TEAM.md`:
- the 온천 row (`:168`), with a new row after it;
- the C row (`:169`);
- `## 팀에 보이는 것과 보이지 않는 것` (after the 온천 line, `:209`);
- the end of `## 알려진 한계`;
- `## 출처` (the 풀숲 그림 line).

- [ ] **Step 1: Edit `TEAM.md`.**
  - C row: after `물속에서 물가 팀원을 끌어들일 수 있으면 몸통박치기 대신 물귀신이 됩니다(연못 줄).` add `큰 나무를 바라보고 있으면(포켓몬이 크면 몸이 나무에 닿고 그쪽을 바라보면) 옆에 팀원이 있어도 팀원 대신 나무를 칩니다("큰 나무" 줄). 순서는 물귀신, 나무, 팀원입니다.`
  - New row after 온천:
    > `| 큰 나무 | 쉼터 왼쪽 아래 풀밭에 큰 소나무 한 그루가 서 있습니다(가로 네 칸, 세로 네 칸 반쯤). 밑동과 아래쪽 가지(가로 3칸, 세로 3칸)는 지나갈 수 없고 던진 것도 막지만, 뾰족한 꼭대기 뒤 줄은 걸어 다닐 수 있어서 거기 선 포켓몬은 머리만 나무 위로 보이고 나머지는 잎에 가려집니다(이름표와 말풍선은 그대로 보입니다). 나무 양옆에 서면 몸 한쪽이 잎에 조금 가려집니다. 나무를 바라보고 C 를 누르면(포켓몬이 크면 몸이 나무에 닿고 그쪽을 바라보면) 나무에 몸통박치기합니다. 부딪히는 순간 나와 나무가 잠깐 멈칫하고 충격 별이 터지며, 나는 살짝 튕겨 나오고, 나무는 맞은 반대쪽으로 휘었다가 몇 번 흔들리며 멈추고, 잎(겨울에는 쌓인 눈)이 우수수 흩어졌다가 떨어지고, 밑동에 먼지가 입니다. 그날 칠수록 세게 흔들리고, 그날 세 번째로 치면 민트 하나가 잎에서 내 발밑으로 떨어져 반짝이며 가방에 들어가고 "나무에서 민트가 떨어졌어요! 가방에 넣었어요" 가 뜹니다(오늘 광장 기록의 주운 아이템으로 셉니다). 그때만 내 화면이 한 번 살짝 흔들립니다. 민트는 하루에 한 번뿐이고 그 뒤로는 흔들리기만 하며, 내 Mac 시계의 자정에 다시 셉니다. 센 횟수는 앱을 껐다 켜도 남고, 시계를 되돌려도 다시 받지 않으며, Mac 마다 따로 셉니다(Mac 두 대면 두 번 받습니다). 몸통박치기처럼 0.3초에 한 번이고, 집중 중이거나 사진 모드에서는 칠 수 없습니다. 물귀신으로 끌어들일 팀원이 있으면 물귀신이 먼저입니다. 치는 모습은 팀원 화면에도 보이고, 민트가 떨어지는 번이면 팀원 화면에도 떨어지는 민트와 반짝임이 보입니다(팀원 가방에는 들어가지 않습니다). 나무 밑과 그 뒤 한 줄에 떨어진 광장 아이템은 보이지 않고 주울 수 없습니다. 잎은 여름에는 원래 초록, 봄에는 연둣빛, 가을에는 금빛이고 겨울에는 눈에 덮이며, 나무 밑 그늘도 계절마다 그 땅 색을 따릅니다. 사진과 작은 지도에도 나오고, 배경을 숨기면 나무도 숨지만 막힌 칸은 그대로입니다 |`
  - 팀에 보이는 것, after the 온천 line: `- 큰 나무를 친 것과 그 세기(그날 몇 번째로 쳤는지에 따라 1~3), 그 번에 민트가 떨어졌는지. 그날 친 횟수와 받은 민트 수는 보내지 않습니다`.
  - End of 알려진 한계:
    > `- v2.5.636 이하를 쓰는 팀원의 광장에는 큰 나무가 없습니다. 그 팀원은 나무 자리를 풀밭처럼 걸어 지나가고, 최신 버전 화면에서는 그동안 나무 뒤나 밑동 안에 가려 보입니다(이름표는 보입니다). 나무를 치는 모습은 그 팀원 화면에 보이지 않습니다. 그 팀원은 나무 밑과 그 뒤 한 줄에 떨어진 아이템을 보고 주울 수 있고, 주우면 모두에게서 사라집니다. 그 팀원이 나무 너머로 던지면 최신 버전 화면에서도 공이 나무를 지나 맞습니다. 그 팀원이 메타몽을 돌리는 동안 메타몽이 나무 자리를 지나가면 최신 버전 화면에서는 나무 앞에서 잠깐 멈춰 있다가 이어 갑니다. 업데이트하면 바로잡힙니다.`
  - 출처: `- 풀숲 그림: …` becomes `- 풀숲·큰 나무 그림: RedVoxel, "Pokemon inspired 16x16 tiles" (CC-BY-SA 3.0, 파일은 변경 없이 쓰고, 큰 나무는 실행 중에 소나무 한 그루를 잘라 3배로 그리고 계절 색만 바꿔 씀)`.
  - The row names the looks, not colours. A colour retuned at Task 11 needs no TEAM.md change unless a season's look changes.
  - `TeamReleaseScriptTests.testTeamGuideHoldsNoPrivateDetails` must still pass: no `@`, no `.local`.
- [ ] **Step 2: Run** `swift test --filter 'TeamReleaseScriptTests'`. Expected: PASS.
- [ ] **Step 3: Commit** `docs(team): explain the plaza big tree in TEAM.md`.

### Task 11: Renders for the user's approval

**Files:** none in the repo. The outputs go under `$S`.

**Harness:** `scripts/plaza-render-compare.sh`. It builds the base commit in `$S/ptb-render-base` and HEAD, runs `PlazaRenderCompareTests/testRenderAllScenes` offscreen on both, and compares them.

- [ ] **Step 1: Render.**
```bash
S="<your session scratchpad>/plaza-big-tree"
BASE=$(git log --format=%H -1 --grep '^test(team): pin the plaza map, classify tree tile checks')
PTB_PLAZA_RENDER_ONLY=big-tree-summer,big-tree-spring,big-tree-autumn,big-tree-winter,big-tree-hit-1,big-tree-hit-2,big-tree-hit-3,base-noon,name-plates,lunges,items,ice-frozen \
  scripts/plaza-render-compare.sh --base "$BASE" --scratch "$S" --runs 1
```
  Expected:
  - exit 1, with `RENDER: <k> differ`;
  - the list covers every `big-tree*@*`, `base-noon@*`, `name-plates@*` and `lunges@*`;
  - it does **not** list `items@*` or `ice-frozen@*`. Their views miss the tree (Task 12's miss list; `ice-frozen` by 1 px).
  - Ignore the `FRAMECOST` lines (one run).
- [ ] **Step 2: Contact sheet.** Write `$S/tools/contact.py` and run it with `python3 -I`. It halves each frame with NEAREST and labels each tile. Make `$S/approval/big-tree.png` with:
  - row 1: `big-tree-summer`, `-spring`, `-autumn`, `-winter` @10, before (grass) and after: the 3× tree in its place, Ash beside it, Misty behind the narrow top, me in front;
  - row 2: `big-tree-hit-1` @6, 9, 21, 72 (contact, peak bend, leaf burst, settle);
  - row 3: `big-tree-hit-2` @6, 10, 22, 72;
  - row 4: `big-tree-hit-3` @6, 12, 28, 44, 90 (contact, peak, the mint falling, landing with the sparkle, settle);
  - row 5: the pine at full frame resolution in each season, cut from the row-1 frames: x 480–640, y 192–368 world px, the art box plus half a tile;
  - row 6: the skirt and trunk base in each season, cut at x 496–624, y 316–356 and enlarged ×2 NEAREST, to judge the ground shade against the grass around it;
  - row 7: `base-noon@10` and `name-plates@10` after, the default scenes with `me` at (19,10) beside the tree's right edge.

  Label the sheet "Sample-data render, offscreen (SKRenderer), not the live app".
- [ ] **Step 3: Check by eye.**
  - The pine sits on the grass with its trunk on row 10, and the canopy does not touch the shelter.
  - Misty's head shows above the narrow top, and her lower body is hidden.
  - Ash at (15,10) is drawn behind the canopy's edge, and Brock and I in front.
  - The bend leans away from each hitter and settles. Leaves scatter out, then drift.
  - Hit 3 is visibly the biggest, the mint lands at my feet, and the sparkle follows.
  - Each season's leaves match decision (d): as drawn, fresh light green, golden larch, snow.
  - Each season's skirt reads as shade of that season's ground, not a different-coloured disc (ruling 15).
  - Each burst matches the tree: green leaves in summer and spring, orange and yellow in autumn, snow in winter.
  - The default `me` at (19,10) is still readable with its left edge behind the canopy (Sweep B).
- [ ] **Step 4: Send for approval.** Send the path to the lead, labelled as above, with:
  - the footprint and position (Footprint section; ruling 1: 3×3 blocked, row 7 walkable; ruling 10: items hidden on 12 tiles);
  - the leaf table as rendered (decision (d)), the skirt colours (ruling 15) and the burst grids (ruling 4);
  - the hit-feel tunables: the Hit feel table, `leafScale`, `maxFallingLeaves` and the camera kick (ruling, 2 px, level 3 only);
  - the banner text (ruling 12);
  - the "found, not changed" list.

  **Stop until the user approves.**
  - If the user changes a value, edit `seasonLeaves`, `skirtGround` or the hit-feel constants and their tests, re-run Task 3's or Task 6's Step 4, update TEAM.md if a look changed (Task 10), and redo this task.
  - If the user moves the tree, move the `'B'` run. Then redo the position check (`testTheTreeStandsOnPlainGrassReachableFromEverySide`), Sweep B and Task 12's stale list.

### Task 12: Cross-render reference

**Files:** `Tests/PlazaCrossReference/mac-reference.tar.gz`.

`scripts/plaza-render-cross.sh` renders `PlazaCrossHarness.scenes` offscreen, twice for A/A, and waits for an idle machine by itself. Never run it with `PTB_PLAZA_RENDER_ONLY` set: that would write a partial reference.

- [ ] **Step 1: Check against the old reference.** Run `env -u PTB_PLAZA_RENDER_ONLY scripts/plaza-render-cross.sh --check --scratch "$S/cross"`.
  - Expected: exit 1, with `CROSS-MAC: reference is STALE:`. It lists:
    - every existing scene stem as a tree change (`line N of M`): the tree layer's 22 nodes are in every scene;
    - the 18 new stems `(not in the reference)`: `big-tree-summer@10`, `-spring@10`, `-autumn@10`, `-winter@10`, `photo-big-tree-winter`, `big-tree-hit-1@6/9/21/72`, `big-tree-hit-2@6/10/22/72` and `big-tree-hit-3@6/12/28/44/90`.
  - **Pixels** must change only where the view reaches the art rect (497–623 × 208–352, measured from the committed cameras). The `ice-*` views end at x 496, 1 px short of the art. That is 122 scene captures: every stem except the 25 below, plus the moved fixtures' scenes, which are among the 122.
  - These must stay byte-identical: `hot-spring*@*` (7), `ice-breaking@*`, `ice-frozen@*`, `ice-refreeze@*` (9), `items@10/40`, `pond-hop@*` (4) and `pond-swim@*` (3).
  - Photos:
    - `photo-base-noon`, `-campfire-lit-night`, `-dance`, `-fireworks-night`, `-night`, `-tall-grass` and `-winter-snow` change. `tall-grass`'s view reaches only 10 px of the tree's left edge;
    - `photo-pond-swim` and `photo-hot-spring-winter` must not change.
  - If any other capture changes, run the same `--check` at Task 1's parent in a scratch worktree. A stem that is stale there too is pre-existing; say so in the PR.
- [ ] **Step 2: Write.** Run `env -u PTB_PLAZA_RENDER_ONLY scripts/plaza-render-cross.sh --write --scratch "$S/cross"`. Expected: `wrote …/mac-reference.tar.gz (<bytes> bytes, 174 captures)` (156 today + 18).
- [ ] **Step 3: Verify.**
  - `env -u PTB_PLAZA_RENDER_ONLY scripts/plaza-render-cross.sh --check --scratch "$S/cross"`. Expected: `CROSS-MAC: reference is current (174 captures)`.
  - `swift test --filter PlazaCrossRenderCompareMacTests/testCommittedReferenceTreesAreCurrent`. Expected: PASS.
- [ ] **Step 4: Commit** `test(team): refresh the plaza cross-render reference for the big tree`.
- [ ] **Step 5: After the push** (see below), the windows.yml `render` job must pass. On a failure:
  - run `scripts/plaza-render-cross.sh --run <run id> --scratch "$S/cross"`;
  - read `$S/cross/cross-report-<id>/`;
  - a real Windows difference goes into `docs/reference/windows-differences.md` in this PR (spec 3.1). None is expected: the bands are plain sprites, and the container scale goes through the shared `PlazaDrawOrder`.
- [ ] **Step 6: Clean up.** Run `git worktree remove --force "$S/ptb-render-base"`, then `git worktree prune`.

---

## After the plan (PR)

- **Before the PR:**
  - after PR 4 lands, merge `origin/main` into the branch;
  - if that merge changes any plaza scene, re-run Task 12;
  - re-run Task 8 Step 4's filter and the guard suites.
- **Prepare the PR with `prepare-pr`.**
  - Title: `feat(team): add a big plaza tree that drops a mint`.
  - Under `UI changes`, put the Task 11 contact sheet, before and after, pushed to the PR-image gist. Label it "Sample-data render, offscreen".
  - The body names:
    - the art: the pine is a runtime crop of the already-credited `plaza-tallgrass.png` (SHA-256 `d8b02d00…19fd`), so no file is added;
    - the footprint and position, and why (ruling 1);
    - the Sweep table, the equivalence test and the scan;
    - the hit feel (the table and the camera-kick ruling) and the pools;
    - the fifteen rulings at the top of this plan and the "found, not changed" list;
    - the mixed-version behaviour (the table, and the new `TEAM.md` line). Old peers drop `.treeShake` like any unknown kind;
    - that every cross-render tree changed (the tree layer's nodes), while pixels changed in the 122 + 7 captures whose views reach the tree.
- **Push** with `git push origin feat/plaza-big-tree:feat/plaza-big-tree`. Then:
  - check the windows.yml test job (the shared suites, including the new ones);
  - check the selftest job (`plaza.renderCost`, `plaza.renderCostSpring`, `plaza.renderCostTree`, `plaza.idleVisible`);
  - do Task 12 Step 5.
- **Release (later, not this PR):**
  - `team_docs_check.py` will require new Mac and Windows captures, because a feat commit touches `Team/Plaza/`;
  - check the `v2.5.636 이하` line against the version actually shipped, with PRs 1–4's lines.
