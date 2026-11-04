# Plaza Campfire Focus Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A campfire in the lower right of the team plaza where teammates sit to show they are focusing (25 min, 50 min or 8 h): it can't be tackled, team notices wait until the end, it survives restarts, and at dusk and night it lights the ground around it.

**Architecture:**
- **Pure models:** map tile `F` and seats (`PlazaCampfire`), the focus value (`PlazaFocus`), and procedural pixel art and light maths (`PlazaCampfireArt`, `PlazaCampfireLight`). These are unit-tested without SpriteKit.
- **Plaza scene:** draws the pit, the 12-frame flicker, the smoke and the multiply light.
- **Plaza window controller:** owns the focus. It persists the focus, sends it in presence (`focusEndsAt`), and enforces the interaction rules.
- **Team runtime:** ends a due focus on its 5 s tick, and wires `TeamNotifier` to hold notices while focusing.

**Tech Stack:** Swift 6 SwiftPM, AppKit, SpriteKit, SwiftUI overlays, XCTest. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-11-04-plaza-campfire-design.md`. Read it first; section numbers below point into it.

## Global Constraints

- Work in `/Users/simu/Documents/GitHub/PokeTokenBar/.worktrees/campfire` on branch `feat/plaza-campfire`. Never touch upstream `chattymin/PokeTokenBar`.
- Commit messages are in English, Conventional Commits, and end with the line `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Code comments follow the file you edit (the plaza files use Korean comments).
- All user-facing team text is Korean, in `TeamLocalization.swift` (`L(.ko)`).
- Pit footprint `F`: (36,23) (37,23) (36,24) (37,24). Seats, in this order with their facing:
  - (35,21) down, (38,21) down
  - (32,21) right, (41,21) left
  - (33,24) right, (40,24) left
  - (35,27) up, (38,27) up
- Durations are exactly `[25, 50, 480]` minutes.
- A received `focusEndsAt` is accepted only when `now < endsAt <= now + 8 h + 600 s` on the receiving Mac's clock.
- Flicker is 12 frames at 0.09 s each. Smoke shows for 15 s after the fire goes out.
- Light:
  - warm colour `(1.0, 0.84, 0.62)`;
  - radii 150 × 104 world px;
  - rings at normalised distance `< 0.42 / 0.62 / 0.82 / 1.0`, mixing `1 / 0.78 / 0.52 / 0.26`;
  - flicker `1 + 0.035 sin(2πt) + 0.025 sin(4πt + 1.3) + 0.015 sin(6πt + 0.4)` with `t = phase / 12`.
- Tests must never activate the app or steal keyboard focus. That means no `show()` in tests, and no `NSApp.activate` or event pumping. Build scenes with `prepareScene()` as existing tests do.
- After any coverage run, restore the tracked `default.profraw` before committing:
  ```bash
  git checkout -- default.profraw
  ```
- Defect protocol (repo `CLAUDE.md`): every new conditional branch needs a test that reaches it. Once per task, inject the defect and confirm the test fails, then check `llvm-cov --show-regions` for `^0` on the changed lines.

## Review Focus

1. **A teammate's clock is far ahead, or a modified app sends `focusEndsAt` years ahead or in the past.** That teammate must not look like they are focusing, and must not keep the fire lit. *Tested in Task 5.*
2. **The app is quit, or the Mac sleeps, across the end time.**
   - On wake, the focus ends exactly once: one end notice and no repeat on the next tick.
   - On relaunch after the end time, the saved focus is silently dropped.
   - On relaunch before it, the seat presence is sent without opening the window.

   *Tested in Tasks 6 and 8.*
3. **All eight seats are taken, or a non-focusing teammate stands on a seat.** That seat is skipped. With no free seat, the menu shows only "자리가 없어요" and choosing it does nothing. *Tested in Tasks 2 and 6.*
4. **An older-version teammate tackles a focusing user, or one stands on a pit tile.** The focusing user is not pushed. The teammate on the pit tile is drawn in the shelter, which is the existing rule for unwalkable tiles. *Tested in Tasks 1 and 7.*
5. **The team code changes, or the team turns off, mid-focus.** The focus clears silently: no end notice, no 🎉, and presence no longer carries `focusEndsAt`. *Tested in Task 8.*

---

### Task 1: Pit tiles on the map, item compatibility, Space target

**Files:**
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaMap.swift`, `PlazaMapData.swift`, `PlazaItems.swift`, `PlazaInteraction.swift`, `PlazaScene.swift` (item lookup only)
- Test: `Tests/PokeTokenBarTests/PlazaMapTests.swift`, `PlazaItemsTests.swift`, `PlazaTargetingTests.swift`, `PlazaTileArtTests.swift`

**Interfaces:**
- Produces:
  - `PlazaTile.campfire` (raw `"F"`, not walkable);
  - `PlazaMap.campfireTiles: [TilePoint]` (row-major; empty when the map has none);
  - `PlazaInteractionTarget.campfire`;
  - `PlazaItems.candidates(in:)` unchanged in signature but counting `F` as grass;
  - `PlazaItems.isOnCampfire(_ spawn: Spawn, map: PlazaMap) -> Bool`.

- [ ] **Step 1: Record the baseline before changing the map.** Run once, on the unmodified tree, a throwaway test that prints the values the pins below need. Don't commit it; it only feeds Step 2. It prints:
  - `PlazaItems.candidates(in: PlazaMapData.map).count`;
  - `PlazaItems.spawn(slot:candidates:)?.tile` for slots `160_000, 160_001, 160_002, 160_003, 160_004`.
- [ ] **Step 2: Write the failing tests**
  - `PlazaMapTests.testCampfireFillsTwoByTwoInTheLowerRight`:
    - `campfireTiles == [(36,23),(37,23),(36,24),(37,24)]`;
    - none walkable;
    - every seat in the Global Constraints list is walkable and not a campfire tile.
  - `PlazaItemsTests.testCampfireKeepsItemSpotsOfEarlierVersions`: the candidate count and the five spawn tiles equal the Step 1 baseline (hard-coded).
  - `PlazaItemsTests.testAnItemThatWouldLandInTheFireIsNotShown`:
    - find a slot ≥ 160_000 whose spawn tile is a campfire tile, and assert `isOnCampfire` is true;
    - assert the scene shows no item at that slot's time, with `scene.now` set into the slot after `appearsAt` and `itemTile == nil`.
  - `PlazaTargetingTests.testSpaceReachesTheCampfireLikeTheBoard`. Assert `PlazaInteraction.target` returns `.campfire`:
    - facing (36,23) from (36,22) gives `.campfire` facing `.down`;
    - with the pit on the side, from (35,23) facing up, it gives `.campfire` facing `.right`;
    - a member on the faced tile beats a side pit.
  - `PlazaTileArtTests.testCampfireTilesAreDrawnAsGrass`: the map image pixels of tile (36,23) equal those of the same image built from a copy of the rows with `F` replaced by `.`.
  - `PlazaMapTests.testATeammateReportedOnThePitIsDrawnInTheShelter`: an older-version teammate can walk onto the pit. A `PlazaScene` given `PlazaSceneMember(tile: (36,23), isAway: false, …)` places that member on a shelter tile (`map.shelterTiles.contains(scene.memberTiles[id]!)`). This is the existing unwalkable-tile rule, pinned for the new tile.
- [ ] **Step 3: Run them**
  - Run: `swift test --filter 'PlazaMapTests|PlazaItemsTests|PlazaTargetingTests|PlazaTileArtTests'`.
  - Expected: FAIL. Before Step 4 `F` is unknown, so the map rows fail to parse.
- [ ] **Step 4: Implement**
  - Add `.campfire = "F"` to `PlazaTile`, and to the not-walkable list.
  - `PlazaMap` collects `campfireTiles` beside `shelterTiles`.
  - In `PlazaMapData.rows`, put `F` at x 36–37 on rows 23 and 24.
  - `PlazaTileArt` needs no change, because its `default:` arm draws grass. The test pins that.
  - `PlazaItems.candidates` treats `.campfire` like `.grass`. Do the walkability check on the tile kind, keeping the existing board-neighbour rule.
  - `PlazaScene.currentItem()` returns nil when `PlazaItems.isOnCampfire(spawn, map:)`.
  - `PlazaInteraction.target` checks `.campfire` in the same two places as `.board`, right after each board check.
  - `PlazaWindowController.handleInteractKey` and `refreshHint` gain a `.campfire` case. For now:
    - `handleInteractKey` does nothing;
    - `refreshHint` shows `L(.ko).plazaCampfireLightHint` = `"스페이스바를 눌러 모닥불 피우기"`.

    Task 6 replaces both.
- [ ] **Step 5: Run the tests and the whole plaza suite**
  - Run: `swift test --filter Plaza`.
  - Expected: PASS.
- [ ] **Step 6: Commit** `feat(team): add the campfire pit to the plaza map`

### Task 2: Seats, durations and the focus value

**Files:**
- Create: `Sources/PokeTokenBar/Team/Plaza/PlazaCampfire.swift`, `Sources/PokeTokenBar/Team/Plaza/PlazaFocus.swift`
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaPreferences.swift`, `Sources/PokeTokenBar/Team/TeamLocalization.swift`
- Test: `Tests/PokeTokenBarTests/PlazaCampfireTests.swift`

**Interfaces:**
- Produces:
  - `PlazaCampfire.Seat`: `Equatable, Sendable`, with `let tile: TilePoint; let facing: PlazaDirection`.
  - `PlazaCampfire.seats: [Seat]`: the eight seats in Global Constraints order.
  - `PlazaCampfire.durations: [Int] = [25, 50, 480]`.
  - Timing constants: `PlazaCampfire.frameCount = 12`, `frameDuration: TimeInterval = 0.09`, `smokeDuration: TimeInterval = 15`.
  - `PlazaCampfire.nearestFreeSeat(from: TilePoint, occupied: Set<TilePoint>) -> Seat?`. It uses squared distance, with ties going to the earlier seat in the list.
  - `PlazaCampfire.clock(_ seconds: TimeInterval) -> String`: `"18:42"` under an hour, `"7:42:10"` from an hour. It rounds up to the next second and never goes below `"0:00"`.
  - `PlazaFocus`: `Codable, Equatable, Sendable`, with `endsAt: Date, minutes: Int, seat: TilePoint`, and `func isActive(at now: Date) -> Bool`, true when `endsAt > now`.
  - `PlazaFocus.maxAhead: TimeInterval = 8 * 3600 + 600`.
  - `PlazaFocus.accepted(_ endsAt: Date?, now: Date) -> Date?`.
  - `PlazaPreferences.focus: PlazaFocus?`: JSON under key `"team.plaza.focus"`; setting nil removes it.
  - Strings:
    - `L(.ko).plazaFocusRemaining(seconds:) -> String`: `"18분 남음"`, `"7시간 42분 남음"`, `"1분 남음"` under a minute;
    - `plazaFocusDuration(minutes:) -> String`: `"25분"`, `"50분"`, `"8시간"`.

- [ ] **Step 1: Write the failing tests** in `PlazaCampfireTests`:
  - `testSeatsAreTheEightFromTheSpec`: equality with the Global Constraints list.
  - `testNearestFreeSeatSkipsTakenSeatsAndBreaksTiesInListOrder`:
    - from (36,22), the nearest seat is (35,21);
    - with (35,21) occupied, it is (38,21);
    - with all eight occupied, it is nil;
    - from (34,24), it is (33,24).
  - `testClockFormat`: 1122 → `"18:42"`, 27730 → `"7:42:10"`, 0.2 → `"0:01"`, −5 → `"0:00"`, 3600 → `"1:00:00"`.
  - `testRemainingWords`: 1122 → `"19분 남음"` (rounds up), 27730 → `"7시간 43분 남음"`, 30 → `"1분 남음"`.
  - `testAcceptedEndsAtWindow`. With `now = t0`:
    - nil → nil;
    - `t0 − 1` → nil;
    - `t0 + 1500` → itself;
    - `t0 + maxAhead` → itself;
    - `t0 + maxAhead + 1` → nil;
    - `distantFuture` → nil.
  - `testFocusSurvivesPreferencesRoundTrip`: set, read back equal, then set nil and read back nil, in a temporary suite.
- [ ] **Step 2: Run**
  - Run: `swift test --filter PlazaCampfireTests`.
  - Expected: FAIL to compile, because the types don't exist yet.
- [ ] **Step 3: Implement** the two files, the preferences property (like `lastTile`, but as `Optional`) and the strings.
- [ ] **Step 4: Run**
  - Run: `swift test --filter PlazaCampfireTests`.
  - Expected: PASS.
- [ ] **Step 5: Commit** `feat(team): add campfire seats and the focus value`

### Task 3: Campfire pixel art and light maths

**Files:**
- Create: `Sources/PokeTokenBar/Team/Plaza/PlazaCampfireArt.swift`, `Sources/PokeTokenBar/Team/Plaza/PlazaCampfireLight.swift`
- Test: `Tests/PokeTokenBarTests/PlazaCampfireArtTests.swift`

**Interfaces:**
- Produces:
  - `PlazaCampfireArt.State`: `ready, lit, ended`.
  - `PlazaCampfireArt.cells = (w: 32, h: 40)` and `worldSize = CGSize(width: 64, height: 80)`.
  - `PlazaCampfireArt.image(_ state: State, phase: Int, scale: Int) -> CGImage`. `phase` runs `0..<12` and `ready` ignores it. The image is `32·scale × 40·scale` pixels, transparent outside the art.
  - `PlazaCampfireArt.frames(_ state: State) -> [CGImage]`: at scale 8, cached per process (a static dictionary). `ready` gives 1 frame; the others give 12.
  - `PlazaCampfireLight`:
    - `static let warm = (r: 1.0, g: 0.84, b: 0.62)`;
    - `static let radii = CGSize(width: 150, height: 104)`;
    - `static func flicker(phase: Int) -> Double`;
    - `static func strength(_ tint: PlazaDaylight.Tint) -> Double`: `clamp((1 − min(r,g,b)) / (1 − 0.42), 0, 1)`;
    - `static func mix(normalizedDistance d: Double) -> Double`: the ring values;
    - `static func multiplier(tint: PlazaDaylight.Tint, mix k: Double) -> (r: Double, g: Double, b: Double)`. Per channel, `min(2, (1 − k·s) + k·s·warm/tint)`, with `s = strength(tint)`; this is the factor applied on top of the tinted scene.
    - `static func center(campfireTiles: [TilePoint]) -> CGPoint?`: in world px with y down. `x` is the middle of the footprint's columns, and `y` is the footprint's bottom edge minus 14.

- [ ] **Step 1: Write the failing tests**
  - `testFramesLoopWithoutAJump`: for lit and ended, `image(_, phase: 12, scale: 1)` has the same pixels as `phase: 0`, and phases 0 and 1 differ.
  - `testArtIsDeterministic`: two calls give the same bytes.
  - `testLitLogsStayUnderTheFlames`: in the lit frames, no log bark colour (`0x79584F`, `0x94785C`) appears above cell row 11 counted from the bottom. In the ready frame, bark does appear between rows 6 and 11.
  - `testArtUsesOnlyThePalette`: every opaque pixel at scale 1 is one of the spec 4.1 colours, the flame bands, the spark/ember colours of the appendix, or a smoke blend. Exempt the ended state's alpha < 255 pixels.
  - `testLightIsOffInDaylightAndFullAtNight`: `strength(.none) == 0`, `strength(PlazaDaylight.night) == 1`, and `multiplier(tint: .none, mix: 1)` is `(1,1,1)`.
  - `testNightLightLiftsTowardWarmDaylight`: `multiplier(tint: night, mix: 1)` is `(2.0 capped, 0.84/0.48, 0.62/0.78)` within 1e-9.
  - `testRingsAndFlicker`:
    - `mix(0.3) == 1`, `mix(0.5) == 0.78`, `mix(0.7) == 0.52`, `mix(0.9) == 0.26`, `mix(1.0) == 0`;
    - `flicker(0) == flicker(12)`;
    - flicker over the phases stays within `0.925...1.075`.
  - `testLightCenterSitsUnderTheFlames`: for the map's campfire tiles, the centre is `(37·32, 25·32 − 14)`.
- [ ] **Step 2: Run**
  - Run: `swift test --filter PlazaCampfireArtTests`.
  - Expected: FAIL to compile.
- [ ] **Step 3: Implement**
  - Port the appendix code (bottom of this plan) into `PlazaCampfireArt`. Keep its rules exactly, since they are the look the user approved:
    - the `Raster`;
    - the palette;
    - the layer order, including the lit-only order of logs, then flames with the log-showing bottom rows, then front stones, then caps;
    - the noise periods;
    - the sparks and the smoke.
  - Its `t` is `Double(phase) / 12`. `scale` replaces the fixed 8.
  - `PlazaCampfireLight` is new, and follows the formulas above.
- [ ] **Step 4: Run**
  - Run: `swift test --filter PlazaCampfireArtTests`.
  - Expected: PASS.
- [ ] **Step 5: Commit** `feat(team): draw the campfire and its light`

### Task 4: The pit, flicker, smoke and light in the scene and in photos

**Files:**
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaScene.swift`, `PlazaPhotoRenderer.swift`
- Test: `Tests/PokeTokenBarTests/PlazaCampfireSceneTests.swift` (new), `PlazaPhotoTests.swift`

**Interfaces:**
- Consumes: `PlazaCampfireArt`, `PlazaCampfireLight`, `PlazaCampfire` timing constants, `map.campfireTiles`.
- Produces:
  - `PlazaScene.campfireLit: Bool`. The controller sets it. The `true → false` transition starts the 15 s smoke.
  - `PlazaScene.campfireState: PlazaCampfireArt.State` and `campfirePhase: Int`, both read-only, for tests.
  - `PlazaScene.isCampfireLightShown: Bool`.
  - `PlazaScene.sit(at seat: PlazaCampfire.Seat)`. It snaps the walker to the seat tile and facing, stops auto-walk and follow, and reports the position.
  - `PlazaScene.onWalkKey: (() -> Void)?`. It is called on a non-repeat arrow key-down with no overlay open, before the `canWalk` check.
  - `PlazaScene.setCampfireTimer(_ text: String?)` and `campfireTimerText: String?` (read-only, for tests).
  - `PlazaScene.campfireZ: CGFloat?` (read-only, for tests).
  - `PlazaPhotoInput.light: PlazaPhotoLight?` with `struct PlazaPhotoLight { let center: CGPoint; let radii: CGSize; let tint: PlazaDaylight.Tint }` (world px, y down, radii already flickered).

- [ ] **Step 1: Write the failing tests** (`PlazaCampfireSceneTests`, scene built with `PlazaScene(map:mapImage:start:zoom:nickname:)` and stepped with `update`, as in `PlazaWindowTests.run`):
  - `testPitIsReadyUntilLitAndFlickersByFrameTime`:
    - the state is ready;
    - after `campfireLit = true` it is lit;
    - stepping 0.09 s × 13 advances the phase 0→1…→0 (12 wraps to 0);
    - with `isPaused` (or zero `dt` steps) the phase stays.
  - `testSmokeShowsFifteenSecondsAfterTheFireGoesOut`:
    - lit, then `campfireLit = false` gives ended;
    - after 14.9 s of updates it is still ended, and at 15.1 s it is ready.
    - A scene that never saw it lit shows ready immediately.
  - `testPitDrawsBehindCharactersInFrontOfIt`:
    - the pit node's z equals `1 + (25·32)/worldHeight`;
    - a remote at (36,26) has a higher z, and one at (36,21) a lower z.

    Use the existing `memberZ(_:)`. Expose the pit's `campfireZ` for tests.
  - `testLightOnlyAtDuskAndNightWhileLit`:
    - with `now` at 13:00 and lit, `isCampfireLightShown == false`;
    - at 21:00 and lit, it is true;
    - at 21:00 and unlit, it is false;
    - with the background hidden at 21:00 and lit, both the pit and the light are hidden.
  - `testSitSnapsToTheSeatAndFacesTheFire`: after `sit(at: seats[4])` the walker is at (33,24) facing right, not walking, and `onLocalPositionChange` fired once.
  - `testArrowKeyCallsOnWalkKeyEvenForAnEgg`: with `canWalk = false`, one arrow key-down calls `onWalkKey` once, and a repeat key-down does not.
  - `PlazaPhotoTests.testPhotoCarriesTheFireAndItsNightLight`:
    - at 21:00 with the fire lit, `photoInput()` has the pit as the first `items` particle, and `light != nil`;
    - in the rendered photo, a ground pixel 1 tile left of the pit is brighter than the same pixel with `light = nil`;
    - a name plate pixel is identical in both.
  - `PlazaPhotoTests.testPhotoLightMatchesTheSceneMaths`: for one block inside ring 1, the photo pixel equals `tinted × multiplier(tint:, mix: 1)` within 2/255 per channel.
- [ ] **Step 2: Run**
  - Run: `swift test --filter 'PlazaCampfireSceneTests|PlazaPhotoTests'`.
  - Expected: FAIL.
- [ ] **Step 3: Implement the scene**
  - **Pit node:** one `SKSpriteNode` at the footprint, built once in `init` when `map.campfireTiles` is not empty.
    - `anchorPoint` is the bottom-centre. Its base is the footprint's bottom edge plus 4 px into the tile below, as in the mockup.
    - `size` is `PlazaCampfireArt.worldSize`.
    - Textures come from `PlazaCampfireArt.frames`, with `filteringMode = .nearest`.
    - It is hidden while the background is hidden.
  - **Frame time:** an accumulator advanced in `update` by the same clamped `dt`. No `SKAction` and no timer.
  - **Light node:** a world-space `SKSpriteNode` with `blendMode = .multiplyX2` and `zPosition = 6`. That puts it above the daylight node (5) and below the plates (10).
    - Its texture is the ring bounding box at 1 texel per 2 world px, coloured `multiplier/2` per ring, with `(0.5, 0.5, 0.5)` outside the ellipse.
    - It is rebuilt only when the tint (rounded to 1/256) or the phase changes. Cache the 12 phase textures per tint key.
    - It is shown only when lit, the background is shown, and `strength(tint) > 0`.
  - **Timer:** a small node under the pit, using the name plate image style (`PlazaNamePlate.image(text:color:scale:)`, white text).
    - nil hides it.
    - It is redrawn only when the text changes, and is left out of photos.
- [ ] **Step 4: Implement the photo path**
  - `photoInput()` prepends the pit particle, the current frame at scale 8, to `items`. When the light is shown, it sets `light`.
  - In `PlazaPhotoRenderer.render`, apply the light right after the tint multiply and before plates and bubbles. For each 2-world-px block whose centre is inside the ellipse, multiply its pixels by `PlazaCampfireLight.multiplier(tint:, mix: mix(d))`, clamped to 255.
- [ ] **Step 5: Run**
  - Run: `swift test --filter 'PlazaCampfireSceneTests|PlazaPhotoTests|PlazaWindowTests'`.
  - Expected: PASS.
- [ ] **Step 6: Commit** `feat(team): show the campfire, its flicker and night light in the plaza`

### Task 5: Focus in presence

**Files:**
- Modify: `Sources/PokeTokenBar/Team/TeamWire.swift`, `TeamSession.swift`
- Test: `Tests/PokeTokenBarTests/TeamWireTests.swift`, `TeamSessionTests.swift`

**Interfaces:**
- Consumes: `PlazaFocus.accepted(_:now:)`.
- Produces:
  - `TeamPresence.focusEndsAt: Date?`, left out of the JSON when nil.
  - `TeamMemberState.focusEndsAt: Date?`, stored only when accepted.
  - `TeamSession.updateFocus(endsAt: Date?)`. It broadcasts presence when the value changes.

- [ ] **Step 1: Write the failing tests**
  - `TeamWireTests.testPresenceFocusIsOptionalForEarlierVersions`:
    - a presence with `focusEndsAt == nil` encodes without the key `focusEndsAt`;
    - one with a date round-trips;
    - a JSON presence without the key decodes with nil;
    - a JSON presence with the key decodes in a struct copy of the v2.5.613 `TeamPresence` fields. Declare the copy in the test to prove that unknown keys are ignored.
  - `TeamSessionTests.testReceivedFocusIsKeptOnlyInsideTheWindow`. Use the existing fake-transport session pair, and drive the receiver's `clock` to `t0`. A sender presence with `focusEndsAt`:
    - `t0 + 1500` → stored;
    - `t0 + 9 h` → nil;
    - `t0 − 60` → nil.
  - `TeamSessionTests.testUpdateFocusSendsPresenceOnlyOnChange`: setting the same value twice sends one presence frame. Count via the fake transport.
- [ ] **Step 2: Run**
  - Run: `swift test --filter 'TeamWireTests|TeamSessionTests'`.
  - Expected: FAIL.
- [ ] **Step 3: Implement**
  - Add the field.
  - `makePresence()` passes `focusEndsAt`.
  - The `.presence` receive case sets `member.focusEndsAt = PlazaFocus.accepted(presence.focusEndsAt, now: clock())`.
  - Do not bump `TeamWire.protocolVersion`.
- [ ] **Step 4: Run**
  - Run: `swift test --filter 'TeamWireTests|TeamSessionTests'`.
  - Expected: PASS.
- [ ] **Step 5: Commit** `feat(team): carry the focus end time in presence`

### Task 6: Starting, joining, sitting and ending a focus

**Files:**
- Modify:
  - `Sources/PokeTokenBar/Team/Plaza/PlazaWindowController.swift`;
  - `PlazaInteraction.swift`, for the menu model;
  - `Sources/PokeTokenBar/Team/UI/PlazaOverlayView.swift` and `PlazaMemberMenuView.swift`, for drawing;
  - `TeamLocalization.swift`.
- Test: `Tests/PokeTokenBarTests/PlazaFocusTests.swift` (new)

**Interfaces:**
- Consumes:
  - Task 2's `PlazaCampfire`, `PlazaFocus` and `preferences.focus`;
  - Task 4's `scene.campfireLit`, `sit(at:)`, `onWalkKey` and `setCampfireTimer`;
  - Task 5's `session.updateFocus` and `members[...].focusEndsAt`.
- Produces:
  - `PlazaOverlayContent.campfireMenu(PlazaCampfireMenu)`.
  - `struct PlazaCampfireMenu: Equatable { let isJoin: Bool; let minutes: [Int]; var selection: Int }`. `minutes` is empty when no seat is free, and `selection` is an index.
  - `PlazaWindowController.isFocusing: Bool`.
  - `PlazaWindowController.focus: PlazaFocus?` (read-only).
  - `PlazaWindowController.onFocusEnd: ((PlazaFocusEnd) -> Void)?`, with `struct PlazaFocusEnd: Equatable, Sendable { let minutes: Int; let elapsedMinutes: Int; let completed: Bool }`.
  - `PlazaWindowController.startFocus(minutes: Int)`, `standUp()`, `endFocusIfDue()` and `endFocusSilently()`.
  - `PlazaWindowController.isCampfireLit: Bool` and `isCampfireMenuOpen: Bool` (true while the overlay is `.campfireMenu`).
  - The init parameter `focusTickSleep: @escaping @MainActor (Duration) async -> Void` (default `Task.sleep`), for the 1 s display tick while the window is open.

- [ ] **Step 1: Write the failing tests** in `PlazaFocusTests`. Use the `PlazaWindowTests`/`TeamRuntimeTests` controller and session-pair helpers, a fixed `clock`, `prepareScene()` and never `show()`. Each test that opens a scene ends with `handleClose()`.
  - `testSpaceAtTheUnlitPitOffersTheThreeDurations`:
    - with the walker at (36,22) facing down, `handleInteractKey` opens `.campfireMenu(isJoin: false, minutes: [25, 50, 480], selection: 0)`;
    - the hint while standing there is `"스페이스바를 눌러 모닥불 피우기"`.
  - `testChoosingADurationSitsMeAndLightsTheFire`. Choose 50 (down, then space through `handleOverlayKey`). Then:
    - `focus == PlazaFocus(endsAt: clock + 3000, minutes: 50, seat: (35,21))`;
    - the walker is at (35,21) facing down;
    - `scene.campfireLit`;
    - `preferences.focus` equals `focus`;
    - as seen by the connected teammate's session (`members[me]`): `inPlaza: true`, `tile: (35,21)`, `focusEndsAt: clock + 3000`;
    - the hint is `"🔥 50분 남음 · 방향키로 일어나기"`.
  - `testJoiningALitFireUsesMyOwnDuration`:
    - a teammate's presence has `focusEndsAt = clock + 600` at (35,21);
    - `isCampfireLit`, the menu has `isJoin: true` and the hint is `"스페이스바를 눌러 같이 집중하기"`;
    - choosing 25 seats me at (38,21) with `endsAt = clock + 1500`.
  - `testNoFreeSeatShowsOnlyTheNotice`. Teammates stand on all eight seats.
    - The menu's `minutes` is empty and the view's row reads `"자리가 없어요"`.
    - Space or Enter closes the menu without starting.
  - `testArrowKeyStandsMeUp`:
    - while focusing, an arrow key-down calls `onFocusEnd` once with `completed: false` and the elapsed minutes;
    - afterwards `focus` and `preferences.focus` are nil, and presence has no `focusEndsAt`.
  - `testDueFocusEndsOnceWithACelebration`:
    - advance `clock` past `endsAt`, then call `endFocusIfDue()` twice;
    - `onFocusEnd` fires once with `completed: true`;
    - the scene shows `.party` over me, and the session sent one `.party` emote with no target.
  - `testClosingWhileFocusingKeepsMeSeated`:
    - after `handleClose()` the teammate sees me with `inPlaza: true, tile: seat, facing: seat.facing`;
    - after the focus ends with the window closed, it is `inPlaza: false`.
  - `testReopeningStartsMeOnMySeat`: `prepareScene()` after a close puts the walker on the seat, not on the last tile.
  - `testRelaunchResumesOrDropsTheSavedFocus`:
    - a new controller built with `preferences.focus` set and `clock` before `endsAt`:
      - is focusing;
      - has put the seat presence and `focusEndsAt` into the session at init, with no scene;
    - with `clock` after `endsAt`:
      - it is not focusing;
      - `preferences.focus` is cleared;
      - `onFocusEnd` is not called.
  - `testWalkingToATeammateFromTheListStandsMeUp`: while focusing, `walkToMember(id)` calls `onFocusEnd` once with `completed: false`, and `scene.walkingToMember == id`.
  - `testAnEggOnASeatCanStandUp`: with `subject` returning an egg, a restored focus, and an arrow key-down, the focus ends and the walker stays on the seat.
  - `testTimerUnderThePitCountsDown`: while focusing with the scene open, after one display tick (injected sleep) `scene` shows the timer text `PlazaCampfire.clock(remaining)`. When not focusing, the timer is nil.
  - `testFireLightsFromTeammatesAndGoesOut`:
    - a teammate's `focusEndsAt` in the future gives `scene.campfireLit == true`;
    - once their end passes (advance `clock`, one display tick), it is false.
- [ ] **Step 2: Run**
  - Run: `swift test --filter PlazaFocusTests`.
  - Expected: FAIL.
- [ ] **Step 3: Implement**
  - **Interaction:** `handleInteractKey` `.campfire` opens the menu. `handleOverlayKey` handles `.campfireMenu` like `.memberMenu`: ↑/↓ wrap, space or enter chooses, escape closes. `chooseCampfire(index:)` calls `startFocus`.
  - **`startFocus`:**
    - seat = `nearestFreeSeat(from: walker.tile, occupied: Set(scene.memberTiles.values))`;
    - stop following;
    - `scene.sit(at:)`;
    - set and save `focus`;
    - `session?.updateFocus(endsAt:)`;
    - send the position;
    - refresh the lit state, hint and timer.
  - **Leaving early:** `scene.onWalkKey` calls `standUp()` when focusing. The key still walks as usual. `walkToMember(_:)` also calls `standUp()` first when focusing.
  - **`endFocus(completed:)`:**
    - clear and save;
    - `session?.updateFocus(endsAt: nil)`;
    - if the scene is nil, `updatePlazaPosition(inPlaza: false, …)`;
    - on `completed`, show and send `.party`;
    - call `onFocusEnd`.

    `endFocusSilently()` does the same without `onFocusEnd` and without the party.
  - **Init and close:**
    - init restores an active `preferences.focus` and pushes the seat presence and `updateFocus`, or clears an expired one;
    - `prepareScene` starts the walker at `focus.seat` when focusing;
    - `handleClose` sends the seat presence instead of `inPlaza: false` when focusing.
  - **Display tick:** a `Task` loop started in `prepareScene` and cancelled in `handleClose`. On each tick it recomputes `isCampfireLit`, then the timer text, then the hint. `observeMembers` recomputes them too.
  - **Hints:** add the strings to `TeamLocalization`:
    - `"스페이스바를 눌러 모닥불 피우기"`;
    - `"스페이스바를 눌러 같이 집중하기"`;
    - `"🔥 \(remaining) · 방향키로 일어나기"`, which takes `plazaFocusRemaining`.
  - **Menu labels:**
    - titles `"모닥불"` and `"같이 집중하기"`;
    - rows `"\(plazaFocusDuration) 집중"`;
    - `"자리가 없어요"`.

    The view reuses `PlazaRosterBackground` and the `PlazaMemberMenuView` row style, with its title in `0xF2C14E`.
- [ ] **Step 4: Run**
  - Run: `swift test --filter 'PlazaFocusTests|PlazaWindowTests|PlazaBoardTests'`.
  - Expected: PASS.
- [ ] **Step 5: Commit** `feat(team): focus at the campfire`

### Task 7: No tackles and no following around a focus

**Files:**
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaWindowController.swift`, `PlazaInteraction.swift` (`PlazaMemberMenu.status`), `Sources/PokeTokenBar/Team/UI/PlazaMemberMenuView.swift`
- Test: `Tests/PokeTokenBarTests/TeamRuntimeTests.swift`, `PlazaFocusTests.swift`

**Interfaces:**
- Consumes: Task 6's `isFocusing`, `isCampfireMenuOpen` (derived from `overlayModel.content`) and the teammates' `focusEndsAt`.
- Produces: `PlazaMemberMenu.status: String?`, drawn under the name in `0xF2C14E`.

- [ ] **Step 1: Write the failing tests**
  - `TeamRuntimeTests.testFocusingMeIsNotPushedByATackle`:
    - same setup as `testTackleFromBesideMePushesMeOneTileAway`, but with my plaza focusing;
    - the impact count rises, and my tile stays the seat.
  - `TeamRuntimeTests.testCampfireMenuOpenBlocksThePush`:
    - the campfire menu is open and I am not focusing;
    - a tackle shows the impact, and my tile is unchanged.
  - The same push-blocking test with `isFocusing == false` and the menu closed still pushes. This is the existing test, which proves the `||` gate's other side.
  - `PlazaFocusTests.testFocusingTeammateMenuHasNoTackleOrFollow`:
    - Space beside a teammate with `focusEndsAt = clock + 1080`;
    - `actions == [.greet, .viewCard]` and `status == "🔥 집중 중 · 18분 남음"`.
  - `PlazaFocusTests.testWhileFocusingMyMenuHasNoTackleOrFollow`: while I am focusing, Space beside a non-focusing teammate gives `actions == [.greet, .viewCard]` and `status == nil`.
  - `PlazaFocusTests.testCDoesNothingAroundAFocus`:
    - pressing C (`scene.onTackleKey`) beside a focusing teammate sends no `.tackle`;
    - C while I am focusing sends none;
    - C beside a non-focusing teammate while I am not focusing sends one.
  - `PlazaFocusTests.testFollowStopsWhenEitherSideStartsFocusing`:
    - following a teammate, then starting my focus, gives `scene.followingMember == nil`;
    - following a teammate who then starts focusing (presence update) gives nil after `observeMembers`.
- [ ] **Step 2: Run**
  - Run: `swift test --filter 'TeamRuntimeTests|PlazaFocusTests'`.
  - Expected: FAIL.
- [ ] **Step 3: Implement**
  - `showTackle` pushes only when `isMe && !isFocusing && !isCampfireMenuOpen`. It still plays the impact.
  - `tackle(_:)` returns early when `isFocusing` or the target is focusing.
  - `handleInteractKey` `.member`:
    - drop `.tackle` and `.follow` when either side is focusing;
    - set `status` when the target is focusing, using `plazaFocusRemaining` with the prefix `"🔥 집중 중 · "`.
  - `startFocus` and `observeMembers` stop the follow, as the tests describe.
- [ ] **Step 4: Run**
  - Run: `swift test --filter 'TeamRuntimeTests|PlazaFocusTests|PlazaCardTests'`.
  - Expected: PASS.
- [ ] **Step 5: Commit** `feat(team): keep focusing teammates from being tackled or followed`

### Task 8: Hold team notices during a focus, end it from the runtime

**Files:**
- Modify: `Sources/PokeTokenBar/Team/TeamNotifications.swift`, `TeamRuntime.swift`, `TeamLocalization.swift`
- Test: `Tests/PokeTokenBarTests/TeamNotificationsTests.swift`, `TeamRuntimeTests.swift`

**Interfaces:**
- Consumes: `PlazaFocusEnd`, plus Task 6's `plaza.isFocusing`, `onFocusEnd`, `endFocusIfDue()` and `endFocusSilently()`.
- Produces:
  - `TeamNotifier.isFocusing: () -> Bool`, defaulting to `{ false }`;
  - `TeamNotifier.focusEnded(_ end: PlazaFocusEnd)`;
  - `struct TeamFocusTally: Equatable { var hearts = 0, lols = 0, parties = 0, reactions = 0, news = 0 }`, internal to the notifier, with a read-only `heldTally` for tests.
- Strings:
  - `"🔥 \(minutes) 집중 끝!"`, where `minutes` takes `plazaFocusDuration`;
  - `"집중을 마쳤어요 · \(n)분"`;
  - the summary `"그동안 ♥ 2 · ㅋㅋ 1 · 🎉 1 · 반응 3 · 소식 1"`, which leaves out zero parts. With nothing held, only the first line shows.

- [ ] **Step 1: Write the failing tests**
  - `TeamNotifierTests.testFocusHoldsEmotesReactionsAndNewsButNotTheMegaphone`. While `isFocusing` is true and the plaza is **not** frontmost, send `emoteToMe(.heart)` ×2, `.lol`, `reactionToMine` ×3 and `bigEvent` ×1. Then:
    - no posts;
    - `heldTally == (2, 1, 0, 3, 1)`;
    - `megaphone` posts at once.
  - `testFocusDoesNotHoldWhatThePlazaShows`: focusing with the plaza frontmost, `reactionToMine` still calls `showInPlaza` once and the tally stays zero.
  - `testFocusEndPostsOneSummaryAndResets`:
    - `focusEnded(completed: true, minutes: 25)` posts one body, `"🔥 25분 집중 끝!\n그동안 ♥ 2 · ㅋㅋ 1 · 반응 3 · 소식 1"`, and resets the tally;
    - a second `focusEnded` with nothing held posts only the first line;
    - with the plaza frontmost, it goes to `showInPlaza` instead.
  - `testFocusEndRespectsTheNotificationSwitch`: with `notificationsEnabled = false`, nothing is posted when the plaza is not frontmost, but the end line is still shown in the plaza when it is.
  - `testEarlyStandUpLine`: `completed: false, elapsedMinutes: 12` gives `"집중을 마쳤어요 · 12분"`.
  - `TeamRuntimeTests.testTickEndsADueFocus`:
    - a plaza focusing with `clock` past `endsAt`;
    - `tickOnce()` makes the notifier, using a fake poster, post the end line once;
    - a second `tickOnce()` posts nothing.
  - `TeamRuntimeTests.testChangingTeamEndsTheFocusSilently`:
    - while focusing, setting `settings.code` to a new code clears `plaza.focus`;
    - nothing is posted;
    - the session presence has no `focusEndsAt`.

    Repeat with `settings.isEnabled = false`.
- [ ] **Step 2: Run**
  - Run: `swift test --filter 'TeamNotif|TeamRuntimeTests'`.
  - Expected: FAIL.
- [ ] **Step 3: Implement**
  - **Holding:** in `emoteToMe`, `reactionToMine` and `bigEvent`, count instead of delivering when `isFocusing() && !isPlazaFrontmost()`. Check this after the existing guards, which are unchanged.
  - **`focusEnded`:** builds the body, bypassing the batcher. It shows the body in the plaza when the plaza is frontmost, regardless of `notificationsEnabled`. Otherwise it posts only when `notificationsEnabled` is on. Then it resets the tally.
  - **`TeamRuntime.start()`:**
    - `plaza?.onFocusEnd = { [weak self] in self?.notifier?.focusEnded($0) }`;
    - `notifier?.isFocusing = { [weak self] in self?.plaza?.isFocusing ?? false }`.
  - **`tickOnce()`:** calls `plaza?.endFocusIfDue()` before `notifier?.flush()`.
  - **`observeSettings()`:** calls `plaza?.endFocusSilently()` in the same condition that already calls `notifier?.reset()`.
- [ ] **Step 4: Run**
  - Run: `swift test --filter 'TeamNotif|TeamRuntimeTests'`.
  - Expected: PASS.
- [ ] **Step 5: Commit** `feat(team): hold team notices while focusing`

### Task 9: 🔥집중 in the list, the fire on the minimap, the shortcut line

**Files:**
- Modify:
  - `Sources/PokeTokenBar/Team/Plaza/PlazaRoster.swift` and `Sources/PokeTokenBar/Team/UI/PlazaRosterView.swift`;
  - `Sources/PokeTokenBar/Team/Plaza/PlazaMinimap.swift` and `UI/PlazaMinimapView.swift`;
  - `UI/PlazaShortcutGuideView.swift`;
  - `PlazaWindowController.swift`, for `refreshRoster` and `refreshMinimap`;
  - `TeamLocalization.swift`.
- Test: `Tests/PokeTokenBarTests/PlazaRosterTests.swift`, `PlazaFocusTests.swift`

**Interfaces:**
- Produces:
  - `PlazaPresence.focus`, with badge `("🔥집중", 0xD9502A)`, ranked with online, and coloured like online;
  - `PlazaRoster.entries(me:meIsIdle:meIsFocusing:members:asleep:now:)`, which keeps the old call sites compiling through defaults: `meIsFocusing = false`, `now = Date()`;
  - `PlazaMinimapModel.campfire: TilePoint?`, the footprint's top-left, set while lit, and `PlazaWindowController.minimapCampfire: TilePoint?` (read-only, for tests).

- [ ] **Step 1: Write the failing tests**
  - `PlazaRosterTests.testFocusBadgeBeatsIdleButNotAsleep`:
    - a connected member with a future `focusEndsAt` and `isIdle` is shown `.focus`;
    - an asleep one with `focusEndsAt` is shown `.asleep`;
    - an expired `focusEndsAt` is shown `.online`;
    - me with `meIsFocusing` is shown `.focus`;
    - the sort order puts focus with online.
  - `PlazaRosterTests.testFocusBadgeText`: `PlazaPresence.focus.badge == ("🔥집중", 0xD9502A)`.
  - `PlazaFocusTests.testMinimapShowsTheFireOnlyWhileLit`: `minimapCampfire == (36,23)` while lit, and nil when not.
- [ ] **Step 2: Run**
  - Run: `swift test --filter 'PlazaRosterTests|PlazaFocusTests'`.
  - Expected: FAIL.
- [ ] **Step 3: Implement**
  - **Roster and minimap:** add the case and the parameters, then fill `refreshRoster` and `refreshMinimap` from `isFocusing`, `members` and `isCampfireLit`.
  - **Minimap view:** draws a 5×5 pt orange (`0xF08A24`) square with a 1 pt dark outline at the footprint centre, under the dots.
  - **Shortcut guide:** add the row `("Space", "모닥불 옆: 집중")` after the Space row.
- [ ] **Step 4: Run**
  - Run: `swift test --filter 'PlazaRosterTests|PlazaFocusTests|PlazaWindowTests'`.
  - Expected: PASS.
- [ ] **Step 5: Commit** `feat(team): show focusing teammates and the lit fire`

### Task 10: TEAM.md, full gate, coverage regions

**Files:**
- Modify: `TEAM.md`, `docs/reference/defect-log.md` (only if a defect was found and fixed during the work)

- [ ] **Step 1: TEAM.md**
  - **Controls table:** add a `모닥불` row describing spec chapters 3, 5, 6, 8 and 9. Cover:
    - where it is;
    - the three durations;
    - each person's own end time;
    - stand-up with an arrow key;
    - not being pushed;
    - the notices held, megaphone excepted;
    - restart and sleep;
    - 🔥집중 in the list and the minimap mark;
    - the night light.
  - **Known limitations:** add the v2.5.613-and-below lines of spec chapter 10.
  - **"팀에 보이는 것":** add "집중 중인지와 끝나는 시각".
- [ ] **Step 2: Full suite**
  - Run: `swift test 2>&1 | tail -5`.
  - Expected: `0 failures`.
- [ ] **Step 3: Coverage regions on changed lines**
  - Run `./scripts/test-gate.sh`, then the `^0` listing over the branch diff:
    ```bash
    python3 /private/tmp/claude-501/-Users-simu-Documents-GitHub-PokeTokenBar/565430de-c0b7-4604-80e8-d6f04edc0447/scratchpad/zero.py
    ```
  - Expected: no `^0` region on new conditional lines. If there is one, add the missing test to the owning task's test file.
  - Then run `git checkout -- default.profraw`.
- [ ] **Step 4: Commit** `docs(team): describe the campfire focus`

---

## Appendix: approved campfire art (mockup code)

This is the generator the user approved in mockups 2–4, taken verbatim from the throwaway render harness. Port it into `PlazaCampfireArt`; `t` = `Double(phase) / 12`, and the fixed `8` in `image(scale:)` becomes the `scale` parameter. Its `fireImage` returned the 8× image; production returns any scale.

```swift
    // MARK: Fire art — a 32x40 cell canvas (2 world px per cell, the tile sheet's own pixel size), upscaled 8x.
    // Colours come from the plaza tile sheet: bark/rock browns, the log's yellow ends, the grey stone ramp,
    // the purple-black outline, dirt and grass.

    static let cellsW = 32, cellsH = 40
    enum PitState { case ready, lit, ended }

    private static func hash(_ x: Int, _ y: Int) -> Double {
        var h = UInt64(bitPattern: Int64(x &* 374_761_393 &+ y &* 668_265_263))
        h = (h ^ (h >> 13)) &* 1_274_126_177
        h ^= h >> 16
        return Double(h & 0xFFFF) / 65535
    }

    /// Value noise that repeats every `period` lattice cells in y, so an upward scroll of one period loops cleanly.
    private static func noise(_ x: Double, _ y: Double, period: Int, seed: Int) -> Double {
        let x0 = Int(floor(x)), y0 = Int(floor(y))
        let fx = x - floor(x), fy = y - floor(y)
        func w(_ v: Int) -> Int { ((v % period) + period) % period }
        let a = hash(x0 + seed, w(y0)), b = hash(x0 + 1 + seed, w(y0))
        let c = hash(x0 + seed, w(y0 + 1)), d = hash(x0 + 1 + seed, w(y0 + 1))
        let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
        let top = a + (b - a) * sx, bottom = c + (d - c) * sx
        return top + (bottom - top) * sy
    }

    /// A tiny cell raster, y up from the bottom. A cell holds 0xRRGGBB and an alpha (0 = empty).
    struct Raster {
        let w: Int, h: Int
        var rgb: [UInt32], alpha: [UInt8]
        init(_ w: Int, _ h: Int) { self.w = w; self.h = h; rgb = Array(repeating: 0, count: w * h); alpha = Array(repeating: 0, count: w * h) }
        func filled(_ x: Int, _ y: Int) -> Bool { (0..<w).contains(x) && (0..<h).contains(y) && alpha[y * w + x] > 0 }
        mutating func set(_ x: Int, _ y: Int, _ c: UInt32, _ a: UInt8 = 255) {
            guard (0..<w).contains(x), (0..<h).contains(y) else { return }
            rgb[y * w + x] = c; alpha[y * w + x] = a
        }
        mutating func ellipse(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double, _ c: (Int, Int, Double) -> UInt32?) {
            for y in 0..<h { for x in 0..<w {
                let dx = (Double(x) + 0.5 - cx) / rx, dy = (Double(y) + 0.5 - cy) / ry
                let d = (dx * dx + dy * dy).squareRoot()
                if d <= 1, let col = c(x, y, d) { set(x, y, col) }
            } }
        }
        mutating func segment(_ a: (Double, Double), _ b: (Double, Double), width: Double, _ c: (Int, Int, Double) -> UInt32?) {
            let vx = b.0 - a.0, vy = b.1 - a.1, len2 = vx * vx + vy * vy
            for y in 0..<h { for x in 0..<w {
                let px = Double(x) + 0.5, py = Double(y) + 0.5
                let t = max(0, min(1, ((px - a.0) * vx + (py - a.1) * vy) / len2))
                let qx = a.0 + vx * t, qy = a.1 + vy * t
                // signed offset across the log: positive is the upper side
                let side = ((px - qx) * -vy + (py - qy) * vx) / len2.squareRoot()
                let d = ((px - qx) * (px - qx) + (py - qy) * (py - qy)).squareRoot()
                if d <= width / 2, t > 0, t < 1, let col = c(x, y, side) { set(x, y, col) }
            } }
        }
        /// The same shape with a one-cell outline around it (four neighbours), like the tile sheet's sprites.
        func outlined(_ c: UInt32) -> Raster {
            var out = self
            for y in 0..<h { for x in 0..<w where !filled(x, y) {
                if filled(x - 1, y) || filled(x + 1, y) || filled(x, y - 1) || filled(x, y + 1) { out.set(x, y, c) }
            } }
            return out
        }
        mutating func over(_ top: Raster) {
            for i in 0..<(w * h) where top.alpha[i] > 0 {
                if top.alpha[i] == 255 || alpha[i] == 0 { rgb[i] = top.rgb[i]; alpha[i] = max(alpha[i], top.alpha[i]); continue }
                let a = Double(top.alpha[i]) / 255
                func mix(_ s: Int) -> UInt32 {
                    let p = Double((rgb[i] >> s) & 0xFF), q = Double((top.rgb[i] >> s) & 0xFF)
                    return UInt32(p * (1 - a) + q * a) << s
                }
                rgb[i] = mix(16) | mix(8) | mix(0)
            }
        }
        func image(scale k: Int) -> CGImage {
            let ctx = CGContext(data: nil, width: w * k, height: h * k, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            for y in 0..<h { for x in 0..<w where alpha[y * w + x] > 0 {
                let c = rgb[y * w + x], a = CGFloat(alpha[y * w + x]) / 255
                ctx.setFillColor(CGColor(srgbRed: CGFloat(c >> 16 & 0xFF) / 255, green: CGFloat(c >> 8 & 0xFF) / 255,
                                         blue: CGFloat(c & 0xFF) / 255, alpha: a))
                ctx.fill(CGRect(x: x * k, y: y * k, width: k, height: k))
            } }
            return ctx.makeImage()!
        }
    }

    // Tile sheet palette.
    static let ink: UInt32 = 0x201729, inkSoft: UInt32 = 0x302639
    static let bark0: UInt32 = 0x331F29, bark1: UInt32 = 0x563A3F, bark2: UInt32 = 0x79584F, bark3: UInt32 = 0x94785C, bark4: UInt32 = 0xBC9A78
    static let cut0: UInt32 = 0xC8B060, cut1: UInt32 = 0xE0D078
    static let stone0: UInt32 = 0x505060, stone1: UInt32 = 0x949EA8, stone2: UInt32 = 0xBBBFC3, stone3: UInt32 = 0xD5D5D5
    static let grass0: UInt32 = 0x328E41, grass1: UInt32 = 0x6ADD4B

    static func fireImage(_ state: PitState, t: Double) -> CGImage {
        let W = cellsW, H = cellsH
        var canvas = Raster(W, H)

        // Ground: a dirt patch with a ragged grassy rim, like the sheet's dirt tile.
        var ground = Raster(W, H)
        ground.ellipse(16, 6.2, 15.6, 6.8) { x, y, d in
            let n = hash(x * 3 + 7, y * 5 + 1)
            if d > 0.9 && n < 0.5 { return nil }
            if d > 0.78 && n > 0.86 { return grass1 }
            if hash(x, y) < 0.12 { return bark2 }
            if hash(x + 40, y) < 0.06 { return bark4 }
            return bark3
        }
        canvas.over(ground)

        let stones = (0..<11).map { i -> (Double, Double, Bool) in
            let a = Double(i) / 11 * 2 * .pi + 0.2
            return (16 + 10.4 * cos(a), 6.8 + 3.9 * sin(a), sin(a) > 0.05)
        }
        func stoneLayer(_ front: Bool) -> Raster {
            var r = Raster(W, H)
            for s in stones where s.2 != front {
                r.ellipse(s.0, s.1, 2.3, 1.7) { x, y, _ in
                    let top = Double(y) + 0.5 > s.1 + 0.4, bottom = Double(y) + 0.5 < s.1 - 0.9
                    if top && Double(x) + 0.5 < s.0 { return stone3 }
                    return top ? stone2 : bottom ? stone0 : stone1
                }
            }
            return r.outlined(inkSoft)
        }
        canvas.over(stoneLayer(false))

        // Fire bed: grey ash with charcoal; embers glow while lit and fade after.
        var bed = Raster(W, H)
        bed.ellipse(16, 6.8, 8.2, 2.8) { x, y, d in d > 0.65 ? stone1 : hash(x + 9, y) < 0.35 ? inkSoft : stone0 }
        switch state {
        case .lit:
            for (i, (x, y)) in [(11, 6), (14, 5), (18, 6), (21, 6), (16, 7), (13, 7), (19, 7)].enumerated() {
                let on = sin(2 * .pi * (t * 2 + Double(i) * 0.37)) > -0.2
                bed.set(x, y, on ? 0xF8A030 : 0xC0401E)
            }
        case .ended:
            for (i, (x, y)) in [(13, 6), (17, 7), (19, 6)].enumerated() {
                let glow = sin(2 * .pi * (t + Double(i) * 0.3))
                bed.set(x, y, glow > 0.3 ? 0xF08A24 : glow > -0.4 ? 0xC0401E : 0x8E2A1C)
            }
        case .ready: break
        }
        canvas.over(bed)

        // Two logs crossed in front, bark like the sheet's log: dark underside, light top edge, yellow cut ends.
        func logLayer(_ a: (Double, Double), _ b: (Double, Double)) -> Raster {
            var r = Raster(W, H)
            r.segment(a, b, width: 3.8) { x, y, side in
                if side > 0.9 { return bark4 }
                if side < -0.9 { return bark1 }
                return abs(side) < 0.3 && hash(x * 7, y * 3) < 0.5 ? bark2 : bark3
            }
            r.ellipse(a.0, a.1, 2.1, 2.0) { _, _, d in d > 0.6 ? cut0 : cut1 }
            r.set(Int(a.0), Int(a.1), bark3)
            return r.outlined(ink)
        }
        func capLayer(_ a: (Double, Double)) -> Raster {
            var r = Raster(W, H)
            r.ellipse(a.0, a.1, 2.1, 2.0) { _, _, d in d > 0.6 ? cut0 : cut1 }
            r.set(Int(a.0), Int(a.1), bark3)
            return r.outlined(ink)
        }
        if state == .lit {
            // Lit: the fire burns on top of the logs; only their cut ends show in front of the stones.
            var logs = logLayer((7, 3.4), (22, 11.5))
            logs.over(logLayer((25, 3.4), (10, 11.5)))
            canvas.over(logs)
            let bands: [(Double, UInt32)] = [(0.96, 0xFFF4C2), (0.64, 0xF8CF3A), (0.43, 0xF08A24), (0.22, 0xD8382E), (0.09, 0x9E2A1E)]
            var flame = Raster(W, H)
            for y in 6..<H { for x in 0..<W {
                let h = Double(y - 6) + 0.5
                let xc = Double(x) + 0.5 - 16
                let sway = 0.8 * sin(2 * .pi * t + h * 0.2) * min(1, h / 16)
                let xs = xc - sway
                let dome = 1 - pow(abs(xs) / 10, 2)
                guard dome > 0 else { continue }
                var s = 1 - h / (27 * pow(dome, 0.75))
                if h < 4 { s += 0.18 * max(0, 1 - abs(xc) / 9) }
                // The logs show through the very bottom of the flames.
                if h < 2 + 2.2 * noise(Double(x) * 0.7, t * 6, period: 6, seed: 91), logs.filled(x, y) { continue }
                let n = 0.62 * noise(xs * 0.3, h * 0.2 - t * 4, period: 4, seed: 11)
                    + 0.38 * noise(xs * 0.6, h * 0.4 - t * 8, period: 8, seed: 57)
                let i = s + 0.8 * (n - 0.5)
                guard let band = bands.first(where: { i > $0.0 }) else { continue }
                flame.set(x, y, band.1 == 0xFFF4C2 && (h > 6 || h < 2.5 || abs(xc) > 4.5) ? 0xF8CF3A : band.1)
            } }
            canvas.over(flame)
        }

        canvas.over(stoneLayer(true))
        if state == .lit {
            canvas.over(capLayer((7, 3.4)))
            canvas.over(capLayer((25, 3.4)))
        } else {
            canvas.over(logLayer((7, 3.4), (22, 11.5)))
            canvas.over(logLayer((25, 3.4), (10, 11.5)))
        }

        switch state {
        case .lit:
            for (i, (phase, dx)) in [(0.0, -4.0), (0.27, 3.0), (0.55, -1.0), (0.8, 5.0)].enumerated() {
                let p = (t + phase).truncatingRemainder(dividingBy: 1)
                guard p < 0.9 else { continue }
                let y = 20 + p * 17
                let x = 16 + dx + 1.5 * sin(2 * .pi * (p * 1.5 + Double(i) * 0.3))
                canvas.set(Int(x), Int(y), p < 0.35 ? 0xFFE070 : p < 0.7 ? 0xF08A24 : 0xC0401E)
            }
        case .ended:
            // A thin wisp of smoke: puffs rise, swell and fade.
            var smoke = Raster(W, H)
            for k in 0..<4 {
                let p = (t + Double(k) / 4).truncatingRemainder(dividingBy: 1)
                let cy = 10 + p * 24, cx = 16 + 2.2 * sin(2 * .pi * (p * 1.2 + 0.1))
                let r = 1.8 + p * 1.8
                let a = UInt8(max(0, min(1, (1 - p) * 1.25)) * 170)
                var puff = Raster(W, H)
                puff.ellipse(cx, cy, r, r * 0.9) { _, y, _ in Double(y) + 0.5 > cy ? stone3 : stone2 }
                for i in 0..<(W * H) where puff.alpha[i] > 0 { puff.alpha[i] = a }
                smoke.over(puff)
            }
            canvas.over(smoke)
        case .ready: break
        }
        return canvas.image(scale: 8)
    }

```
