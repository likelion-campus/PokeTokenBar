# Plaza Photo Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One photo mode in the team plaza replaces the P snapshot and the G group photo.
- P enters the mode. The camera leaves my Pokémon and a framed viewfinder shows what will be taken. Arrow keys slide the frame anywhere on the map.
- Space or P takes a photo of the frame and puts it on the clipboard.
- G runs the shared group-photo countdown. Whoever is in photo mode, with the plaza in front, at 0 gets the frame on their clipboard.

**Architecture:**
- **Frame geometry:** a pure value function, `PlazaPhotoFrame.layout`. It turns a wanted centre into three things: the frame (the photo's world rect), the window's visible world rect, and the clamped centre. Both the drawing and the photo read this one result.
- **Plaza scene:** owns the mode's camera state (centre, held pan keys). In photo mode, `layout()` follows the frame instead of my feet. `update` slides the centre, and the keys are routed per spec §4.4.
- **Window controller:** reacts to mode changes. It hides the HUD views, hides the hint and shows the frame overlay. It also takes the photo, shows the banner, and folds the group photo's "joined" flag into "in photo mode and frontmost".

**Tech Stack:** Swift 6 SwiftPM, AppKit, SpriteKit, SwiftUI overlays, XCTest. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-11-05-plaza-photo-mode-design.md` (Korean). Read it first. The § numbers below point into it.

## Global Constraints

- **Workspace and history**
  - Work in `/Users/simu/Documents/GitHub/PokeTokenBar/.worktrees/photo-mode` on branch `feat/plaza-photo-mode`.
  - Never touch upstream `chattymin/PokeTokenBar`. Never edit the main checkout `/Users/simu/Documents/GitHub/PokeTokenBar`, where another session works.
  - Commit messages are in English, Conventional Commits, and end with the line `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **Text**
  - Code comments follow the file you edit (the plaza files use Korean comments).
  - All user-facing team text is Korean and lives in `Sources/PokeTokenBar/Team/TeamLocalization.swift` (`L(.ko)`). `testTeamSourcesHaveNoHangulLiterals` fails on any Hangul literal elsewhere in Team sources (defect-log D1). Run `TeamLocalizationTests` after every task that adds text.
- **Wire and timing.** No wire change: no new `TeamEmoteKind`, no presence field. The group-photo countdown stays `groupPhotoSeconds = 5`, and the cooldown stays `groupPhotoCooldown = 2`.
- **Frame and pan constants**
  - Insets in points: top 24, left 24, right 24, bottom 44.
  - Pan speed: 256 world px/s, or 512 with Shift held. Each axis moves at that speed, so a diagonal is not normalised.
  - Frame look: black margin at 50% opacity, and white corner brackets with 18 pt arms and 3 pt lines.
- **Exact strings** (spec §4.2, §4.5, §4.6, §7)
  - guide: `📷 사진 모드 · 방향키 이동 · Shift 빠르게 · −/+ 확대 · Space 찍기 · G 단체 사진 · Esc 나가기`
  - banner after a photo: `사진을 클립보드에 담았어요 · ⌘V로 붙여 넣기`
  - countdown `plazaGroupPhotoCountdown(starter:seconds:joined:)`:

    | starter | joined | text |
    |---|---|---|
    | nil | true | `단체 사진 3 · 모두 모여요!` |
    | nil | false | `단체 사진 3 · P를 누르면 함께 찍어요` |
    | "민수" | true | `민수님의 단체 사진 3 · 함께 찍는 중` |
    | "민수" | false | `민수님의 단체 사진 3 · P를 누르면 함께 찍어요` |
  - shortcut guide label for P: `사진 모드`. G keeps `단체 사진`.
- **Tests and probes**
  - Tests never activate the app or steal keyboard focus: no `showWindow`, no `NSApp.activate`, no event pumping. Build scenes with `prepareScene()`, as existing tests do. Images use offscreen `SKView.texture(from:crop:)` or `ImageRenderer`.
  - Photo pixel tests pin `scene.now` (defect-log D2).
- **Coverage hygiene.** After any coverage run, restore the tracked `default.profraw` before committing: `git checkout -- default.profraw`.
- **Key codes:**

  | Key | Code |
  |---|---|
  | left / right / down / up | 123 / 124 / 125 / 126 |
  | Esc | 53 |
  | Space | 49 |
  | Return | 36 |
  | P | 35 |
  | G | 5 |
  | Z | 6 |
  | X | 7 |
  | C | 8 |
  | 1 | 18 |

## Review Focus

These are the failure modes the spec implies that are most likely to bite someone, most likely first. Each is pinned by a test in the task named.

1. **Focusing, then photo mode.** Someone sitting at the campfire enters photo mode and presses arrows. The focus must not end; after Esc, an arrow stands them up as before. (Task 4, `testArrowsInPhotoModeDoNotEndAFocus`)
2. **Group photo with the plaza in the background.** A teammate's group photo ends while I am in photo mode with the plaza behind another app. My clipboard must stay as it was. (Task 5, `testBackgroundPlazaIsNotPhotographed`)
3. **Holding an arrow at the map edge.** Holding an arrow at the edge, then pressing the opposite arrow, moves the frame at once, with no hidden overshoot to work off. (Task 2, `testHoldingAtTheEdgeDoesNotPileUp`)
4. **Zoom inside photo mode.** Zoom changes made in photo mode are never saved. Leaving photo mode restores the zoom from before, and the photo rect still equals the frame after a zoom. (Task 2, `testZoomKeepsTheCentreAndIsNotReported`)
5. **A pan key whose keyUp never arrives.** This covers Command+arrow, an app switch while holding a key, and the window closing in photo mode. None of these may leave a pan running. After a close and reopen, the camera is back on me with the HUD state reset. (Task 2, `testCommandArrowAndReleaseAllStopThePan`; Task 4, `testClosingInPhotoModeResetsEverything`)

---

### Task 1: Frame geometry

**Files:**
- Create: `Sources/PokeTokenBar/Team/Plaza/PlazaPhotoFrame.swift`
- Test: `Tests/PokeTokenBarTests/PlazaPhotoFrameTests.swift`

**Interfaces:**
- Consumes: `PlazaCamera.visibleRect(focus:viewport:zoom:backingScale:world:rightInset:)` with `rightInset` 0.
- Produces:
  ```swift
  enum PlazaPhotoFrame {
      static let topInset: CGFloat = 24, sideInset: CGFloat = 24, bottomInset: CGFloat = 44   // points
      static let panSpeed: CGFloat = 256, fastPanSpeed: CGFloat = 512                          // world px / s
      static let bracketArm: CGFloat = 18, bracketWidth: CGFloat = 3                           // points
      struct Layout: Equatable { let frame: CGRect; let visible: CGRect; let center: CGPoint } // world px, y down
      static func layout(center: CGPoint, viewport: CGSize, zoom: Int, backingScale: CGFloat, world: CGSize) -> Layout?
  }
  ```

The algorithm (spec §6):
- The frame is `PlazaCamera.visibleRect(focus: center, viewport: viewport − insets, …)`.
- The visible rect is the frame grown by `inset / zoom` on each side. Its size is `viewport / zoom`.
- `center` is `(frame.midX, frame.midY)`.
- Return nil when the viewport less the insets is not positive on either axis.

- [ ] **Step 1: Write the failing tests** in `PlazaPhotoFrameTests` (world 1536×1024, backing 2 unless stated):
  ```swift
  func testFrameIsTheWindowLessItsInsets() {
      let l = PlazaPhotoFrame.layout(center: .init(x: 768, y: 512), viewport: .init(width: 960, height: 640), zoom: 2, backingScale: 2, world: world)
      XCTAssertEqual(l?.frame, CGRect(x: 540, y: 369, width: 456, height: 286))
      XCTAssertEqual(l?.visible, CGRect(x: 528, y: 357, width: 480, height: 320))
      XCTAssertEqual(l?.center, CGPoint(x: 768, y: 512))
  }
  func testFrameStaysOnTheMapAndReportsTheClampedCentre() {
      // centre (-500, -500) → frame.origin == .zero, center == (228, 143)
      // centre (5000, 5000) → frame.maxX == 1536, frame.maxY == 1024, center == (1308, 881)
  }
  func testFrameBiggerThanTheMapCentresTheMap() {
      // zoom 1, viewport 2000×1200, centre (100, 100) →
      // frame == CGRect(x: -208, y: -54, width: 1952, height: 1132), center == (768, 512)
  }
  func testOriginsLandOnDevicePixels() {
      // for zoom in 1...3, centre (700.37, 400.11), viewport 961×641, backing 2:
      // frame.minX, frame.minY, visible.minX and visible.minY times (zoom × 2) are whole numbers (within 1e-9)
  }
  func testNoFrameWhenTheWindowIsSmallerThanTheInsets() {
      // viewport 40×200 → nil; 200×60 → nil; .zero → nil
  }
  ```
- [ ] **Step 2:** Run `swift test --filter PlazaPhotoFrameTests`. Expected: build failure (`PlazaPhotoFrame` not found).
- [ ] **Step 3:** Implement `PlazaPhotoFrame` as above, with a Korean doc comment matching the plaza files.
- [ ] **Step 4:** Run `swift test --filter "PlazaPhotoFrameTests|PlazaCameraTests"`. Expected: all pass.
- [ ] **Step 5:** Commit: `feat(team): add the plaza photo frame geometry`.

### Task 2: Scene photo mode (camera, pan, keys, photo rect)

**Files:**
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaScene.swift`. The changes are:
  - the `zoom` didSet at about :37;
  - `handleKeyDown` at about :396 and `handleKeyUp`;
  - `releaseAllKeys`, `clearInput`;
  - `photoInput()` at about :567;
  - `update` at about :831;
  - `layout()` at about :975.
- Test: `Tests/PokeTokenBarTests/PlazaPhotoModeSceneTests.swift` (new)

**Interfaces:**
- Consumes: `PlazaPhotoFrame.layout`, `PlazaPhotoFrame.panSpeed`, `PlazaPhotoFrame.fastPanSpeed`.
- Produces, on `PlazaScene`:
  ```swift
  private(set) var photoCenter: CGPoint?        // world, y down; nil = normal camera
  var isPhotoMode: Bool { photoCenter != nil }
  private(set) var photoFrame: CGRect?          // world, y down; set by layout() in photo mode
  var onPhotoModeChange: ((Bool) -> Void)?
  func enterPhotoMode()
  func exitPhotoMode()
  ```

The behaviour (spec §4.1, §4.3, §4.4):
- **`enterPhotoMode()`.** Does nothing if the scene is already in photo mode. Otherwise it:
  1. remembers `zoom`;
  2. sets `photoCenter` to the current `visibleRect` centre;
  3. calls `walker.releaseAll()` and `stopWalkingToMember()`, and clears held pan keys;
  4. calls `layout()`, then `onPhotoModeChange?(true)`.
- **`exitPhotoMode()`.** Does nothing if the scene is not in photo mode. Otherwise it:
  1. clears `photoCenter`, `photoFrame` and the pan keys;
  2. sets `zoom` back to the remembered value; the didSet saves it as usual, since the scene is no longer in photo mode;
  3. calls `layout()`, then `onPhotoModeChange?(false)`.
- **`zoom` didSet.** Calls `onZoomChange` only when `!isPhotoMode`.
- **`layout()`.** In photo mode, it takes `PlazaPhotoFrame.layout(center: photoCenter!, viewport: size, zoom:, backingScale: backing, world: worldSize)` and uses:
  - `visible` as `visibleRect`;
  - `frame` as `photoFrame`;
  - `center` as `photoCenter`.

  When that returns nil, keep the normal camera and leave `photoFrame` nil. The actor and plate placement code is unchanged.
- **`update`.**
  - With Command held, also clear the held pan keys.
  - Before `layout()`, move `photoCenter` by `(right − left, down − up) × speed × dt`. The speed is `fastPanSpeed` when `currentModifiers()` contains `.shift`, otherwise `panSpeed`.
  - `walker.advance` still runs, so tackle pushes still move me.
- **`handleKeyDown` in photo mode.** This branch goes after the open-overlay branch and before the normal Esc branch. Every key returns `.swallowed`.
  - **Esc** (not a repeat): `exitPhotoMode()`. It never calls `onCloseRequest`.
  - **Arrows** (not a repeat, no Command): insert into the held pan keys. Never call `onWalkKey` and never touch `walker`.
  - **Space and P:** `onPhotoKey?()`.
  - **G, Z, X, and 1–5:** call their usual callbacks. These keys keep the usual modifier and repeat rule.
  - **C and Return/Enter:** do nothing.
  - **`-`, `=` and `+`:** zoom as now.
- **`handleKeyUp`, `releaseAllKeys()` and `clearInput()`.** These also release the pan keys.
- **`photoInput()`.** Uses `photoFrame ?? visibleRect` for `visibleRect` and for `tallGrassLayer?.photoBands(in:)`.

- [ ] **Step 1: Write the failing tests.**
  - **Scene helper:**
    - map `PlazaMapData.map`, `mapImage: PlazaTileArt.plainGrassImage(map)`;
    - `start: PlazaCampfire.seats[0].tile`, zoom 2, `backingOverride = 2`, size 960×640;
    - `now` pinned to 2026-05-10 12:00;
    - drive time with `scene.update(t)` in 1/30 s steps. `maxFrameDelta` is 0.07.
  - **Tests:**
  ```swift
  func testEnteringKeepsTheViewAndFramesIt()
  //   before = visibleWorldRect; enterPhotoMode()
  //   photoCenter == (before.midX, before.midY); photoFrame == PlazaPhotoFrame.layout(center: that, viewport: size, zoom: 2, backingScale: 2, world: map.pixelSize)?.frame
  //   visibleWorldRect == that layout's visible; onPhotoModeChange got [true]; a second enterPhotoMode() reports nothing more
  func testArrowsSlideTheFrameNotMe()
  //   enter; keyDown 124; 15 updates of 1/30 s → photoCenter.x grew by 128 ± 1; walker.tile unchanged, !walker.isWalking
  //   keyUp 124; 15 more updates → photoCenter unchanged
  //   currentModifiers = { .shift }; keyDown 125; 15 updates → photoCenter.y grew by 256 ± 1
  func testArrowsInPhotoModeNeverCallOnWalkKey()
  //   count onWalkKey; enter; keyDown 123/124/125/126 → 0; exitPhotoMode(); keyDown 124 → 1
  func testHoldingAtTheEdgeDoesNotPileUp()
  //   enter; hold 123 for 10 s of updates → photoFrame.minX == 0; keyUp 123; hold 124 for 0.25 s → photoFrame.minX == 64 ± 1
  func testCommandArrowAndReleaseAllStopThePan()
  //   enter; keyDown 124 with modifiers .command → no movement over 15 updates
  //   keyDown 124; releaseAllKeys(); 15 updates → no movement; same with clearInput()
  func testZoomKeepsTheCentreAndIsNotReported()
  //   record onZoomChange; enter; c0 = photoCenter; keyDown characters "-" → zoom 1, photoCenter == c0, reported == []
  //   photoInput()?.visibleRect == photoFrame
  //   exitPhotoMode() → zoom == 2, reported == [2]
  func testPhotoInputTakesTheFrame()
  //   enter → input.visibleRect == photoFrame; width × ppw == 1824; height × ppw == 1144 (ppw == 4)
  func testKeysInPhotoMode()
  //   Space(49) and P(35) → onPhotoKey 2 times, onInteractKey 0; Return(36) → onChatKey 0; C(8) → onTackleKey 0
  //   G(5) → onGroupPhotoKey 1; Z(6) → onJumpKey 1; X(7) → onGreetKey 1; "1"(18) → onEmoteKey 1
  //   Esc(53) → .swallowed, !isPhotoMode, onCloseRequest 0; Esc again → onCloseRequest 1
  func testLeavingPutsTheCameraBackOnMe()
  //   before = visibleWorldRect; enter; hold 124 for 1 s; exitPhotoMode() → visibleWorldRect == before; photoFrame == nil
  ```
- [ ] **Step 2:** Run `swift test --filter PlazaPhotoModeSceneTests`. Expected: build failure (no `enterPhotoMode`).
- [ ] **Step 3:** Implement the behaviour above in `PlazaScene.swift`.
- [ ] **Step 4:** Run `swift test --filter "PlazaPhotoModeSceneTests|PlazaPhotoTests|PlazaCameraTests|PlazaCampfireSceneTests|PlazaTallGrassSceneTests"`.
  - Expected: the new tests pass.
  - In `PlazaPhotoTests`, the scene-level P tests still pass, because P outside photo mode still calls `onPhotoKey`.
  - The controller-level P tests (`testPhotoKeyWritesPNGOnceAndFlashes` and its neighbours) still pass, because the controller is unchanged in this task.
- [ ] **Step 5:** Commit: `feat(team): let the plaza camera leave my Pokémon in photo mode`.

### Task 3: Frame overlay and photo-mode text

**Files:**
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaInteraction.swift` (`PlazaOverlayModel`, about :128)
- Modify: `Sources/PokeTokenBar/Team/UI/PlazaOverlayView.swift`
- Modify: `Sources/PokeTokenBar/Team/TeamLocalization.swift`
- Test: `Tests/PokeTokenBarTests/PlazaPhotoOverlayTests.swift` (new), `Tests/PokeTokenBarTests/TeamLocalizationTests.swift`

**Interfaces:**
- Consumes: the `PlazaPhotoFrame` insets and bracket constants.
- Produces:
  - `PlazaOverlayModel.isPhotoMode: Bool` (default false).
  - `L.plazaPhotoGuide: String` and `L.plazaPhotoCopied: String`, with the exact strings in Global Constraints.

The behaviour (spec §4.2):
- When `model.isPhotoMode` is set, the overlay draws three things, behind the countdown, banner and hint stack:
  - the even-odd black 50% margin outside the frame rect `(sideInset, topInset, width − 2·sideInset, height − topInset − bottomInset)` in view points;
  - the four corner brackets;
  - `plazaPhotoGuide`, centred in the bottom inset band, in white `PlazaResources.font(.body)` at one line, with `.minimumScaleFactor(0.7)` so that it fits 600 pt.
- None of it takes hits, so `.allowsHitTesting(false)`.
- When the flag is false, nothing changes from today.

- [ ] **Step 1: Write the failing tests.**
  - In `TeamLocalizationTests`, assert the two new strings exactly.
  - In `PlazaPhotoOverlayTests`, render `PlazaOverlayView(model:)` with `isPhotoMode = true` through `ImageRenderer` at 600×320 and scale 1, over nothing (transparent), then check pixels:
    - (300, 160), inside the frame: fully transparent;
    - (10, 160), the left margin: black with alpha 128 ± 3;
    - (2, 318), the bottom band's corner: the margin colour;
    - (25, 25), on the top-left bracket: white with alpha ≥ 250;
    - with `isPhotoMode = false`, (10, 160) is fully transparent.
- [ ] **Step 2:** Run `swift test --filter "PlazaPhotoOverlayTests|TeamLocalizationTests"`. Expected: failures (missing members).
- [ ] **Step 3:** Implement the model flag, the overlay drawing and the two strings.
- [ ] **Step 4:** Run the same filter. Expected: all pass, including `testTeamSourcesHaveNoHangulLiterals`.
- [ ] **Step 5:** Commit: `feat(team): draw the photo-mode frame over the plaza`.

### Task 4: Controller photo mode (enter, shoot, HUD, focus, close)

**Files:**
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaWindowController.swift`. The changes are:
  - `showWindow` view assembly at about :196–290;
  - `prepareScene` wiring at about :315–360;
  - `handlePhotoKey` at about :501;
  - `refreshHint` at about :760;
  - `handleClose` at about :1120–1185.
- Modify: `Tests/PokeTokenBarTests/PlazaPhotoTests.swift`, the controller-level P tests at about :428–480.
- Test: `Tests/PokeTokenBarTests/PlazaPhotoModeTests.swift` (new), `Tests/PokeTokenBarTests/PlazaFocusTests.swift` (one test)

**Interfaces:**
- Consumes: `scene.enterPhotoMode()`, `scene.exitPhotoMode()`, `scene.isPhotoMode`, `scene.onPhotoModeChange` (Task 2); `overlayModel.isPhotoMode` and `L.plazaPhotoCopied` (Task 3).
- Produces:
  - `var isPhotoMode: Bool { scene?.isPhotoMode ?? false }`, for tests and Task 5;
  - `private func takePhoto()`, used by Task 5.

The behaviour (spec §4.1, §4.2, §4.5, §4.7):
- **`handlePhotoKey()`.** In photo mode it calls `takePhoto()`; otherwise it calls `scene.enterPhotoMode()`.
- **`takePhoto()`.** This is today's `handlePhotoKey` body, plus `showBanner(L(.ko).plazaPhotoCopied)` after a successful write:
  1. `scene.photoInput()`;
  2. `PlazaPhotoRenderer.pngData`;
  3. `photoWriter`;
  4. flash.

  `finishGroupPhoto()` calls `takePhoto()` where it called `handlePhotoKey()`, so the group photo keeps working until Task 5.
- **`scene.onPhotoModeChange`.** Wire it in `prepareScene` to `photoModeChanged(_:)`, which:
  - sets `overlayModel.isPhotoMode`;
  - sets `isHidden` on every HUD view;
  - calls `refreshHint()`;
  - calls `refreshCountdown()`; that function is changed in Task 5, and calling it here now is harmless.
- **HUD views.** Keep the HUD views created in `showWindow` in `private var hudViews: [NSView]`: roster, chat log, minimap, clock, shortcut guide, background toggle and name-colour picker. The overlay and the chat bar are not HUD views.
- **`refreshHint()`.** Sets no hint while `isPhotoMode`.
- **`handleClose()`.** Also:
  - nils `scene.onPhotoModeChange`;
  - sets `overlayModel.isPhotoMode = false`;
  - empties `hudViews`.

  The scene and window are discarded there already. The saved zoom stays as it was, because photo-mode zoom was never reported.

- [ ] **Step 1: Write the failing tests.**
  - **Update the existing controller tests in `PlazaPhotoTests`.** P now enters photo mode and a second P shoots.
    - `testPhotoKeyWritesPNGOnceAndFlashes`: P → `written` is empty and `isPhotoMode`; P → one PNG, flashing; a held P (repeat) → still one; `c.banner == "사진을 클립보드에 담았어요 · ⌘V로 붙여 넣기"`.
    - `testFailedWriteDoesNotFlash`: P, P → the writer is called once, no flash, `c.banner == nil`.
    - Keep the closed-window test's intent, using P, P before the close.
  - **New `PlazaPhotoModeTests`.** Build the controller like `PlazaPhotoTests.controller(writer:)`, with the size 960×640.
  ```swift
  func testSpaceShootsOnlyInPhotoMode()
  //   Space outside photo mode → nothing written; P; Space → one PNG; the PNG decodes to 1824 × 1144 (frame at zoom 2 × 2)
  func testEscLeavesAndTheHintComesBack()
  //   the default start (map.spawn) is next to the board, so hint == L(.ko).plazaBoardHint
  //   P → hint == nil; Esc → !isPhotoMode, hint == L(.ko).plazaBoardHint again, nothing written
  func testPhotoModeZoomIsNotSaved()
  //   preferences.zoom == 2; P; "-" → scene.zoom == 1, preferences.zoom == 2; Esc → scene.zoom == 2, preferences.zoom == 2
  func testClosingInPhotoModeResetsEverything()
  //   P; "-"; hold 124; handleClose(); prepareScene() → !isPhotoMode, scene.zoom == 2, overlay isPhotoMode false (read via a test accessor if needed), the visible rect is centred on me again
  ```
  - **In `PlazaFocusTests`**, next to `testArrowKeyStandsMeUp`, using its `pair` harness and `key(_:_:)` helper:
  ```swift
  func testArrowsInPhotoModeDoNotEndAFocus()
  //   c.startFocus(minutes: 25); P (35) → c.isPhotoMode; key(scene, leftKey) → ends == [], c.focus != nil
  //   Esc (53) → !c.isPhotoMode, c.focus != nil; key(scene, leftKey) → ends.count == 1, c.focus == nil
  ```
- [ ] **Step 2:** Run `swift test --filter "PlazaPhotoModeTests|PlazaPhotoTests"`. Expected: the new and updated tests fail.
- [ ] **Step 3:** Implement the behaviour above.
- [ ] **Step 4:** Run `swift test --filter "PlazaPhotoModeTests|PlazaPhotoTests|PlazaFocusTests|PlazaGroupPhotoTests|PlazaCampfire|PlazaChatTests|TeamLocalizationTests"`. Expected: all pass. `PlazaGroupPhotoTests` passes unchanged, because its strings and its `joined` flag are untouched until Task 5.
- [ ] **Step 5:** Commit: `feat(team): open photo mode with P and take the photo with Space`.

### Task 5: Fold the group photo into photo mode

**Files:**
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaWindowController.swift`:
  - the init, adding an `isFrontmost` seam;
  - `isFrontmost` at about :777;
  - the group-photo block at about :548–605.
- Modify: `Sources/PokeTokenBar/Team/TeamLocalization.swift`, `plazaGroupPhotoCountdown` at about :74.
- Modify: `Tests/PokeTokenBarTests/PlazaGroupPhotoTests.swift`, `Tests/PokeTokenBarTests/TeamLocalizationTests.swift` (if it covers the countdown).

**Interfaces:**
- Consumes: `isPhotoMode`, `takePhoto()`, `scene.enterPhotoMode()`.
- Produces:
  - **New init parameter:** `isFrontmost: (@MainActor () -> Bool)? = nil`. When it is nil, `isFrontmost` keeps today's `NSApp.isActive && window?.isKeyWindow == true`.
  - **`groupPhoto` drops `joined`:** the field becomes `(starter: String?, left: Int, task: Task<Void, Never>)`.

The behaviour (spec §4.6, §5):
- **`handleGroupPhotoKey()`.**
  1. If the scene is not in photo mode, enter photo mode.
  2. Then, if a countdown is running, stop: entering photo mode was the joining.
  3. Else, if inside the cooldown, stop.
  4. Else, send `.groupPhoto` and start the countdown.
- **`showGroupPhoto(from:)`.** Unchanged, except that it no longer carries `joined`.
- **`refreshCountdown()`.** Passes `joined: isPhotoMode`. `photoModeChanged` (Task 4) already calls it, so the text flips the moment the mode changes.
- **`finishGroupPhoto()`.** Calls `takePhoto()` when `isPhotoMode && isFrontmost`; otherwise it calls `scene?.playShutterFlash()`. Photo mode stays on after either.
- **`plazaGroupPhotoCountdown`.** Returns the four strings in Global Constraints.

- [ ] **Step 1: Rewrite `PlazaGroupPhotoTests` for the new rules.**
  - The test controller passes `isFrontmost: { [weak self] in self?.frontmost ?? true }`, with `private var frontmost = true`.
  - Keep the `SecondGate` harness.
  - `pressG` is unchanged. Add `pressP` (keyCode 35) and `pressEsc` (53).
  ```swift
  func testGStartsACountdownThatEndsInMyPhoto()
  //   as today, plus: after the first G, c.isPhotoMode; at 0 → one PNG, flash, still in photo mode
  func testTeammatesCountdownTakesMyPhotoOnlyInPhotoMode()
  //   showGroupPhoto → "민수님의 단체 사진 5 · P를 누르면 함께 찍어요"; 5 ticks → flash, nothing written
  //   showGroupPhoto again; tick; pressP → "민수님의 단체 사진 4 · 함께 찍는 중"; 4 ticks → one PNG; nothing sent
  func testGDuringATeammatesCountdownJoinsWithoutSending()
  //   showGroupPhoto; pressG → c.isPhotoMode, "… 함께 찍는 중", received stays 0 after 50 ms; 5 ticks → one PNG
  func testEscDuringTheCountdownLeavesTheShot()
  //   pressG (I start); tick; pressEsc → "단체 사진 4 · P를 누르면 함께 찍어요"; 4 ticks → flash, nothing written
  func testBackgroundPlazaIsNotPhotographed()
  //   pressP (photo mode); showGroupPhoto from 민수; frontmost = false; 5 ticks → flash, nothing written, still in photo mode
  func testATeammateWithNoNameYetShowsAsTeammate()      // text → "팀원님의 단체 사진 5 · P를 누르면 함께 찍어요"
  func testASecondStartWhileCountingIsIgnored()         // text → "민수님의 단체 사진 4 · P를 누르면 함께 찍어요"
  func testClosingThePlazaCancelsTheCountdown()         // unchanged in intent; reopened scene starts outside photo mode, so pressG again enters it
  func testALateGRightAfterTheEndStartsNothing()        // unchanged in intent; the late G still enters photo mode but starts no countdown and sends nothing
  ```
  Add the four countdown strings to `TeamLocalizationTests`.
- [ ] **Step 2:** Run `swift test --filter "PlazaGroupPhotoTests|TeamLocalizationTests"`. Expected: failures.
- [ ] **Step 3:** Implement the behaviour above.
- [ ] **Step 4:** Run `swift test --filter "PlazaGroupPhotoTests|TeamLocalizationTests|TeamRuntimeTests|PlazaPhotoModeTests|PlazaPhotoTests"`. Expected: all pass.
- [ ] **Step 5: Inject the defects.** Each injection must make a test fail. Revert each one after checking.
  - Drop `&& isFrontmost` → `testBackgroundPlazaIsNotPhotographed` fails.
  - Pass `joined: true` → `testEscDuringTheCountdownLeavesTheShot` fails.
- [ ] **Step 6:** Commit: `feat(team): take the group photo from photo mode`.

### Task 6: Docs, shortcut guide, full gate

**Files:**
- Modify: `TEAM.md`, rows `P` and `G` (about :64–65), and every "기념사진에도" in the table (the rows for the campfire, the clock and the weather).
- Modify: `Sources/PokeTokenBar/Team/TeamLocalization.swift`: `plazaShortcutPhoto` becomes `사진 모드`.
- Modify: `docs/superpowers/specs/2026-11-05-plaza-photo-mode-design.md`, but only if implementation forced a deviation. Add a dated revision line at the top.

**TEAM.md content.** Korean, in the table's existing style. It must state:
- **P row:**
  - P enters photo mode: the right-hand list, chat log, minimap and top-left buttons hide, and a frame appears.
  - Arrows slide the frame anywhere on the map, and Shift makes it faster.
  - −/+ zooms, and the zoom returns to the earlier value on leaving.
  - Space or P puts the frame on the clipboard, with a flash and the banner, and the mode stays.
  - Esc leaves the mode, and so does closing the window.
  - 1–5, Z and X still work. C and Enter do nothing.
  - While focusing at the campfire, the arrows don't stand you up.
- **G row:**
  - G (from anywhere) starts the 5 s countdown for everyone in the plaza and enters photo mode.
  - At 0, whoever is in photo mode with the plaza in front gets their frame on the clipboard. Everyone else only sees the flash.
  - "P를 누르면 함께 찍어요".
  - Esc mid-countdown leaves the shot.
  - Teammates on v2.5.617 or earlier see the same countdown and join with G as before.
- **Other rows:** change "기념사진에도 … 담깁니다" to "사진에도 … 담깁니다".

- [ ] **Step 1:** Update `TeamLocalizationTests` if it pins `plazaShortcutPhoto`. Then edit the string, the TEAM.md rows and the "사진에도" wording.
- [ ] **Step 2:** Run the full suite: `swift test 2>&1 | tail -30`. Expected: 0 failures. A line like "N failures (0 unexpected)" is a real failure (defect-log).
- [ ] **Step 3:** Run `scripts/test-gate.sh`. Expected: the gate passes. Then `git checkout -- default.profraw`.
- [ ] **Step 4:** Check for `^0` on the new branches:
  ```bash
  xcrun llvm-cov show .build/debug/PokeTokenBarPackageTests.xctest/Contents/MacOS/PokeTokenBarPackageTests \
    -instr-profile=.build/debug/codecov/default.profdata \
    Sources/PokeTokenBar/Team/Plaza/PlazaPhotoFrame.swift Sources/PokeTokenBar/Team/Plaza/PlazaScene.swift \
    Sources/PokeTokenBar/Team/Plaza/PlazaWindowController.swift --show-regions | grep -n "\^0" | head -40
  ```
  - Every `^0` in the photo-mode code needs a test, or a one-line reason in the final report: for example, the HUD `isHidden` loop runs only with a real window.
- [ ] **Step 5:** Commit: `docs(team): describe photo mode in TEAM.md and the shortcut guide`.

## After the tasks

The PR is prepared with `.claude/skills/prepare-pr`, outside this plan's tasks.
- **Images.** The UI changes need images: before and after, rendered offscreen with sample data, and labelled as sample-data renders.
  - Before: the normal plaza with its HUD.
  - After: photo mode with the frame, guide and countdown, and the resulting clipboard photo.
- **Image hosting.** Upload them to the team gist `4fc5090e7d1a2cd4a72fc68cd7a3bb70`. Never commit sprite images into the repo.
- **Harness.** The mockup harness at `/private/tmp/claude-501/-Users-simu-Documents-GitHub-PokeTokenBar/565430de-c0b7-4604-80e8-d6f04edc0447/scratchpad/ZZPhotoModeMock.swift` is the starting point. Copy it into `Tests/` only while rendering, and never commit it. With the real feature in place, it can call `scene.enterPhotoMode()` instead of composing the window through the photo renderer.
