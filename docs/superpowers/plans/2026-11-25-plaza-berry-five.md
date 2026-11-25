# Plaza Berry Five ("열매 다섯") Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A third plaza minigame on the shared lobby: cards flip automatically around a top-view table, the first player to ring the bell (Space) when exactly five of one berry show scores, a wrong ring costs a point, the first to five points wins. Mac and Windows play in one game.

**Architecture:**
- **Lobby reuse.** `PlazaGameKind.berry` rides the lobby as the drawing quiz extended it (menu, invitation, Y/N, per-kind cap, countdown). Its payload is `PlazaGameState.berry: PlazaBerryState?`, beside `bomb` and `draw`.
- **One writer, bells on presence.** Only the dealer (the host; after the host has been out of play for 3 s, the smallest playing id) writes the shared state: which seat each flip turned, the flip count at each clear, scores, judged bell serials. The cards are never sent: every machine recomputes every table from the seed and that list. Each player's bell rides that player's own presence (`TeamPresence.gameBell`), carrying a reaction time measured on the ringing machine's monotonic clock from when the current five first showed on its own screen. No machine compares another machine's timestamp with its own clock.
- **Pure rules, thin glue.** `PlazaBerry` (new file) holds constants, the deck, tables, bounds and state transitions as pure functions. `PlazaBerryLocal` (new file) is one machine's unsent memory (first-seen times, its screen's five, its bells). `PlazaGameEngine` calls them from a `// MARK: - 열매 다섯` section.
- **One full-window panel.** `PlazaBerryTablePanel` draws the scrim, felt, seats, rotated cards and the centre plate with panel shapes (`PlazaCanvas`, `rotate(by:)`). While it shows, the HUD suppresses every other panel (`PlazaHUD.suppressed`, new) and the table is an overlay (`PlazaOverlayContent.berryTable`), so it takes the keys the way the M menu does. No platform input code changes.

**Tech Stack:** Swift 6 (SwiftPM), XCTest, shared sources under `Sources/PokeTokenBar/Team` (Mac and Windows), AppKit only under `Team/UI` and `Platform/Mac`, Win32 under `Platform/Windows`.

**Spec:** `docs/superpowers/specs/2026-11-25-plaza-berry-five-design.md` (Korean) and its approved mockup `docs/superpowers/specs/2026-11-25-plaza-berry-five-mock.html`. Section numbers below (§) refer to the spec. Read both first; where this plan and the spec disagree, the spec wins and the plan is wrong.

## Global Constraints

- Work in a git worktree under `.worktrees/`, never the main checkout. One branch per PR, cut from fresh `origin/main`; merge `origin/main` again before opening it. Fork only: every `gh` call passes `--repo likelion-campus/PokeTokenBar`.
- Commits and PR text in English, Conventional Commits. Every commit message ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. PR text follows `.agents/skills/prepare-pr/SKILL.md` (UI PRs carry images).
- User-visible strings are Korean and live only in `Sources/PokeTokenBar/Team/TeamLocalization.swift` (`TeamLocalizationTests.testTeamSourcesHaveNoHangulLiterals`). Tests may hold Korean literals.
- Shared files (`Team/Plaza/**`, `Team/*.swift`) import only `Foundation` and `Observation`; no `#if os` outside the allowed guard shapes (`SharedSourcesScanTests`). A new Apple-only test file is listed in `Tests/PokeTokenBarTests/mac-only.txt`.
- `@MainActor` test classes: every test method is `async`. Tests make defaults with `TestDefaults`, never `UserDefaults(suiteName:)`.
- Numbers, all in `PlazaBerry` (§3): 2 to 8 players, 8 seats; 4 berries (`oran-berry` 오랭, `sitrus-berry` 자뭉, `pecha-berry` 복슝, `cheri-berry` 버치), 56 cards, 14 per berry as 1×5, 2×3, 3×3, 4×2, 5×1; first flip 3 s after the lock is seen, then one flip every 1.5 s; rest 1.5 s after a clear; judging window 0.6 s; wrong bell −1 (never below 0) and 1 s without ringing; 5 points wins; 3 s after the last card; result 5 s on the table; dealer takeover after 3 s (`PlazaBomb.absenceGrace`).
- §4 is fixed: the dealer is the only writer of shared state and measures only its own intervals; bells ride each player's own presence; reaction time is measured on the ringing machine's monotonic clock from when the current five first showed on its own screen; timestamps from different machines are never compared; a bell from a past clear is dropped without penalty.
- §2 must-nots: no hint before a bell (flips never pause and no card glows before someone rings; no "지금!"); no Pokémon, berry or bell image in the repository or the bundle (fetched at runtime through the existing item path, with §7's fallbacks); no hand-drawn pixel art in code (table and cards are panel shapes: rounded rectangles, ellipses, shadows, stripes; textures only from CC0-type assets with `CREDITS.md`); no name, card art, bell or box design of the game it is based on.
- Reaction times use only the injected monotonic `uptime` closure (`ContinuousClock`), never `Date`. The dealer's intervals use its own `now`.
- No protocol version bump (`TeamWire.protocolVersion` stays 1). The only new wire field is `TeamPresence.gameBell`; no new message kind.
- The game stays out of the M menu until Task 9 (`PlazaGameKind.offered` leaves `.berry` out). A release cut from `main` before Task 9 must show no trace of the game.
- Reduce Motion (`PlatformPlaza.reduceMotion()`) turns every table motion into an instant change (§5.1).
- The table's look is checked by the user against the mockup from a rendered sheet (Task 2) before anything else is built on it. Renders are offscreen in an XCTest and never create, show or activate a window (no focus stealing); a sheet is opened for the user with `open -g` only.
- Mac and Windows behave the same (`docs/reference/windows-differences.md` lists any difference with its reason). Windows-only files do not compile on the Mac: after editing them, grep for the pinned lists they hold (`zOrder`, `drawList.count`, panel id lists, `.gameTitle`) and let the Windows CI prove them.
- One `swift build` or `swift test` at a time on this Mac; never run one while another session's `team-release.sh` runs (`ps aux | grep scripts/team-release.sh`).
- Before each PR: `swift test --filter "Plaza|Team|SpriteKit|Mirror|ScanTests|GuardTests|GateTests|TestIsolationTests|WindowsScanRootPathTests"` (about 18 minutes).
- Every new guard gets a fault injected once to see its test fail (steps say which), then restored.
- PRs: A = Tasks 1 and 2, B = Tasks 3 to 5, C = Tasks 6 to 8, D = Task 9. Each merges to `main` on its own. Do not release unasked.

## Interfaces from the drawing quiz

Berry five is built after the drawing quiz's lobby work (`docs/superpowers/plans/2026-11-25-plaza-draw-quiz.md`, its PRs B and C) is on `main`. The names below are as that plan defines them; Task 1 records what `main` actually has, and those notes win over this list.

- **D1** `PlazaGameKind.offered: [PlazaGameKind]` (what the M menu lists) and `PlazaGameMenu.kinds` defaulting to it (draw Task 4). Draw Task 8 deletes it once `.draw` is offered.
- **D2** The per-kind player cap: `PlazaDraw.maxPlayers` (8) caps `players` in `PlazaGame.accepted` for kind `"draw"` and in the host's lock (the first 8 sorted joiners) (draw Tasks 4 and 5); the invitation counts "참가 n/8", disables the join button for a teammate not yet in once 8 have joined and shows `plazaDrawFull` ("자리가 찼어요") (draw Task 7).
- **D3** A copy without the payload loses: `PlazaDraw.keys(nil) == [-1, -1, -1]`, compared in `PlazaGame.precedes` right after the rank and before the bomb keys; `accepted` requires `draw == nil` while recruiting (draw Task 4).
- **D4** Playing from presence: `tick` reads `playing = joins ∩ players`, plus me when `joined == state.id`; `leave` in countdown or play only sets `joined = nil`; with `connected == false` the engine writes nothing and after `PlazaGame.isolationLimit` sets `lostConnection` and `joined = nil` (draw Task 5).
- **D5** Local first-seen times: each machine keeps when it first saw the lock; a non-bomb game's countdown is 3 s from that moment, never `startsAt` against my clock (draw Task 5).
- **D6** The referee pattern: the smallest id in `playing` other than the absent writer, after `PlazaBomb.absenceGrace` on the referee's own clock (draw Task 5). The dealer takeover follows the pattern; it is not the same function.
- **D7** A game panel in the shared stack: `PlazaPanelID.drawBoard` in `stackOrder`, the controller's `hud` list in the same order, `hiddenInPhotoMode`, and the Windows pins in `WindowsPlazaPanelsTests` (draw Task 6).
- **D8** `PlazaGameView.make` branches by kind and reads a local phase (`engine.drawPhase(now:)`), with `alive` = the players so the bomb game's rings show (draw Task 7).
- **D9** Panel press capture through `scrollerContains` / `scrollerMouse` (existing; the drawing panel's drags use it, draw Task 6).
- **D10** Test patterns: the engine room of `PlazaDrawEngineTests` (per-engine clock skew, `gone`, `cutOff`) and the controller world of `PlazaDrawControllerTests` (draw Tasks 5 and 7).

## Review Focus

Inputs the spec implies and a person will meet, which §9's list does not name; each has its test in the task named.

1. **The countdown begins while I am typing a chat line, have the news board, a card or the M menu open, or am in photo mode.** The table takes over: the line is closed unsent, the overlay is replaced, photo mode ends, and Space rings from then on. Task 7, `testTheTableTakesOverAnOpenChatFieldOverlayOrPhotoMode`.
2. **A five stays on the table through later flips (another seat turns a different berry), or two berries reach five at once.** The reaction counts from when that five first showed, not from the latest flip. Task 4, `testAFiveThatSurvivesAnotherFlipKeepsItsStart`.
3. **The plaza window is covered or minimised when a five appears and shown again later.** The reaction counts from when the table showed again on this screen. Task 4, `testAHiddenPlazaCountsFromWhenTheTableShowedAgain`; Task 7 feeds the window's state.
4. **Eight players with long or emoji nicknames in the smallest window (600 by 372), or the window resized during play.** No seat, pile, deck or the centre plate overlaps another; cards stay on the felt; names are cut with "…". Task 2, `testEightSeatsNeverOverlapAtEverySize` and `testLongAndEmojiNamesStayInsideTheirSeat`.
5. **Several flips or a clear arrive between two renders (a slow frame, the window shown again, an animation still running).** The table shows the latest state at once, no queued animation replays, and Space is judged against that latest table. Task 2, `testAFlipAnimatesOnlyOneStepAndOnlyWithMotion`; Task 7, `testAJumpOfSeveralFlipsShowsTheLatestTable`.

---

### Task 1: Check the drawing quiz's lobby on `main`

**Files:**
- Modify: `docs/superpowers/plans/2026-11-25-plaza-berry-five.md` (append `## Execution notes`)

**Interfaces:**
- Consumes: D1 to D10 above.
- Produces: the Execution notes table, `D-n | name in this plan | name and file:line on origin/main <sha>`, which every later task reads.

- [ ] **Step 1: Fetch and look.** Run `git fetch origin && git log --oneline -1 origin/main`, then for each D-item a `git grep -n` on `origin/main -- Sources Tests`, for example: `"static var offered"`, `"PlazaDraw.maxPlayers"`, `"PlazaDraw.keys"`, `"draw == nil"`, `"playing"` in `Sources/PokeTokenBar/Team/Plaza/PlazaGame.swift`, `"isolationLimit"`, `"drawPhase"`, `"drawBoard"`, `"plazaDrawFull"`, `"scrollerMouse"`, `"class PlazaDrawEngineTests"`, `"class PlazaDrawControllerTests"`.
- [ ] **Step 2: Decide.** D2, D3, D4, D5, D7 and D8 must be on `main`. If any is missing, STOP: report which, do not build it. D1 missing is fine only if draw Task 8 deleted it (Task 3 then re-adds `offered` in the same shape). D9 and D10 are patterns: note where they are.
- [ ] **Step 3: Record.** Append `## Execution notes` with the table and the `origin/main` SHA. Note every rename (for example a shared `PlazaGameKind.maxPlayers` instead of `PlazaDraw.maxPlayers`) and how `tick` and `leave` branch by kind.
- [ ] **Step 4: Commit** `docs(team): record the drawing quiz names berry five builds on`.

### Task 2: The table panel and the sheet the user checks

**Files:**
- Create: `Sources/PokeTokenBar/Team/Plaza/PlazaBerry.swift` (this task: `PlazaBerry.Berry`, `PlazaBerry.Card`, `pips`, `bellItem`, `flipAnimation`)
- Create: `Sources/PokeTokenBar/Team/Plaza/HUD/PlazaBerryTableLayout.swift`, `Sources/PokeTokenBar/Team/Plaza/HUD/PlazaBerryTablePanel.swift` (`PlazaBerryBoard`, `PlazaBerryModel`, `PlazaBerryTablePanel`)
- Modify: `Sources/PokeTokenBar/Team/Plaza/HUD/PlazaPanel.swift` (`PlazaPanelID.berryTable`, last in `stackOrder`, in `swallowingWholeWindow`, not in `hiddenInPhotoMode`)
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaWindowController.swift` (the model, the panel last in the `hud` list, `setBerryBoardForTesting`)
- Modify: `Sources/PokeTokenBar/Team/TeamLocalization.swift` (`plazaBerryHead` "열매 다섯 · 먼저 5점", `plazaBerryRule` "같은 열매가 딱 5개면 스페이스!", `plazaBerryBellFallback` "종", `plazaBerryWrongMark` "✕", `plazaBerryWrongRest` "1초 쉬기", `plazaBerryBellMark` "🔔")
- Modify: `Sources/PokeTokenBar/Platform/Windows/WindowsSelftestPlazaPanels.swift` (capture and cost)
- Test: `Tests/PokeTokenBarTests/PlazaBerryTablePanelTests.swift`, `PlazaBerryTableRenderTests+Mac.swift` (list in `mac-only.txt`), `PlazaPanelCostTests+Mac.swift`, and the pinned panel lists in `WindowsPlazaPanelsTests.swift`, `PlazaPanelRenderTests+Mac.swift`, `PlazaWindowTests+Mac.swift`, `PlazaHUDControlsTests.swift` (grep `.gameTitle` in `Tests/`)

**Interfaces:**
- Consumes: D7 (where the panel joins the stack), D9 (the bell press).
- Produces:
  ```swift
  enum PlazaBerry {
      enum Berry: Int, CaseIterable, Codable, Sendable { case oran, sitrus, pecha, cheri
          var itemName: String      // "oran-berry", "sitrus-berry", "pecha-berry", "cheri-berry"
          var color: PlazaColor     // the fallback dot: 0x3B7BD1, 0xF2C14E, 0xF09AB8, 0xD2453B
      }
      struct Card: Hashable, Sendable { var berry: Berry; var count: Int }   // count 1...5
      static let bellItem = "soothe-bell"
      static let flipAnimation: TimeInterval = 0.3
      /// Berry centres on a face as fractions of its width and height from the top-left (the mockup's dice layout).
      static let pips: [Int: [CGPoint]]
  }
  /// What the table shows; the controller derives it after every game step (Task 7).
  struct PlazaBerryBoard: Equatable {
      struct Seat: Equatable {
          var id: String; var name: String; var nameColor: PlazaColor; var mon: TeamMonSummary   // players are never eggs
          var score: Int            // 0...5, drawn as five ●○ circles
          var deckLeft: Int
          var top: PlazaBerry.Card?
          var under: Int            // pile cards under the top since the last clear; at most 2 are drawn, askew
          var isPlaying: Bool       // false: drawn faded
      }
      enum Center: Equatable { case countdown(Int), playing(event: String?), result(lines: [String]) }
      struct Ring: Equatable {
          var clear: Int            // changes once per right bell: starts the rim, the sweep, the hop and 🔔
          var seat: Int             // who rang, index into `seats`
          var swept: [PlazaBerry.Card?]   // the tops on the table at the clear, by `seats` index
          var five: Set<Int>        // seats whose card made the five (gold rim)
      }
      var seats: [Seat]             // index 0 is me, at the bottom, then clockwise in seat order
      var center: Center
      var flip: Int                 // flips so far; +1 animates `flippedSeat`
      var flippedSeat: Int?
      var ring: Ring?
      var wrong: Bool               // ✕ and "1초 쉬기" over the bell
  }
  @MainActor @Observable final class PlazaBerryModel {
      var board: PlazaBerryBoard?   // nil hides the panel
      var items: [String: PlazaImage] = [:]   // by item name, as they arrive
  }
  struct PlazaBerryTableLayout: Equatable {
      static func make(viewport: CGSize, seats: Int, scale: CGFloat) -> PlazaBerryTableLayout
      var felt: CGRect              // the table ellipse's box
      var center: CGRect            // the centre plate
      var bell: CGRect              // the bell inside the centre plate
      var card: CGSize, deckCard: CGSize   // unrotated
      var seats: [Seat]             // index 0 at the bottom, clockwise
      struct Seat: Equatable { var box: CGRect; var pile: CGPoint; var deck: CGPoint; var rotation: CGFloat }   // pile and deck are centres
  }
  @MainActor final class PlazaBerryTablePanel: PlazaPanel {   // id .berryTable, anchor .fill
      init(model: PlazaBerryModel, icons: any PlazaIconSource, reduceMotion: @escaping () -> Bool = { PlatformPlaza.reduceMotion() },
           clock: PlazaAnimationClock = PlazaAnimationClock(interval: 1.0 / 30))
      var onBell: (() -> Void)?     // a press on the bell, at the press
      var isAnimating: Bool { get }
  }
  // PlazaWindowController
  func setBerryBoardForTesting(_ board: PlazaBerryBoard?)
  ```
  Geometry from the mockup, in units of `u = min(width, height * 1.6) / 100`, centred: felt 74 % of the width by 74 % of the height; seat `i` of `n` at angle `a = π/2 + 2πi/n` (screen y down, so seat 0 is at the bottom and the order runs clockwise), seat centre `(50 + 44.5 cos a, 50 + 41.5 sin a)` %, pile centre `(50 + 29 cos a, 50 + 25 sin a)` %, deck centre the pile centre plus `9u · (−sin a, cos a)`, rotation `a − π/2`; card `7.6u × 10.6u`, deck card `6.2u × 8.6u`, centre plate 23 % of the width. Shrink cards and seat boxes by one common factor only where the overlap test needs it, and say so in the PR. Pips: 1 `(.5,.5)`; 2 `(.30,.28) (.70,.72)`; 3 `(.28,.24) (.5,.5) (.72,.76)`; 4 `(.30,.27) (.70,.27) (.30,.73) (.70,.73)`; 5 `(.28,.24) (.72,.24) (.5,.5) (.28,.76) (.72,.76)`; a berry is half the card's width.

Drawing rules (§5.1, §7): a full-window `.color` scrim (dark, no blur), the felt as flat concentric ellipses (`#2F7A55`, `#23603F`, `#1B4A31`) inside a wood rim (`#7A5232`, `#4F331D`) with a shadow (the canvas has no gradients); the centre plate in the HUD panel colours and the plaza font (head, the bell picture or "종", the rule line, the event line or the countdown or the result lines); each seat: the member's still sprite (`PlazaPictureCache.sprite`), the name in its colour, five score circles; each pile: two cards under the top, slightly askew, then the face (`#FBF8EF`, white border, rounded corners, shadow, berries in pips, or berry-coloured dots while a picture is missing); each deck: striped back (`#B8473D` / `#9E3A31`, white border, never the original game's back) with the count. Cards are drawn into their own small rotated images so a render redraws only what changed. Motion: a flip slides and unfolds the card from the deck onto the pile over `flipAnimation` with its face visible from the first frame (so the reaction clock starts at the same moment with or without motion); a ring rims the five cards gold for 0.4 s, then sweeps the piles to the ringer's seat over 0.4 s, while the ringer's sprite hops (0.5 s) with 🔔 beside it; the animation clock runs only during an animation, only when `board.flip` grew by exactly one or `ring.clear` changed, and never under Reduce Motion. Hits: `"bell"` over the bell (`scrollerContains` true there, so the HUD hands the press to `scrollerMouse(.down)`, which calls `onBell`), `"table"` anywhere else (taken, does nothing). Accessibility: each seat ("하늘 3점"), the centre lines, the bell as a button with action `"bell"`.

- [ ] **Step 1: Write the failing tests** in `PlazaBerryTablePanelTests` (`@MainActor`, `async`; build a `PlazaHUD` with the panel as `PlazaGamePanelTests` does):
  - `testThePanelShowsOnlyWithABoard`: `isVisible` follows `model.board != nil`.
  - `testEightSeatsNeverOverlapAtEverySize` (Review Focus 4): for `n` in 2...8, viewports 600×372, 760×480, 960×640, scales 1 and 2: seat boxes pairwise disjoint and inside the viewport; every pile and deck (rotated rectangles, separating-axis test on their edge normals) pairwise disjoint, clear of every seat box and of `center`, with all four corners inside the felt ellipse; seat 0's centre has the largest y; angles increase clockwise.
  - `testLongAndEmojiNamesStayInsideTheirSeat`: eight seats named `"가나다라마바사아자차카타파하"` and `"🐱🐶🦊🐻🐼🐨🐯🦁"` at 600×372: each name's accessibility frame lies inside its seat box and the drawn name ends with "…".
  - `testTheBellTakesAPressAndNothingElseDoes`: `hud.handleMouse(.down)` at the bell's centre calls `onBell` once, before any `.up`; the `.up` does not call it again; a down elsewhere on the window returns true and calls nothing.
  - `testAFlipAnimatesOnlyOneStepAndOnlyWithMotion` (Review Focus 5): `flip` +1 starts the clock and it stops after `flipAnimation` of driven beats; `flip` +3 renders once with no clock; with `reduceMotion` true, `flip` +1 and a new `ring` render once each and the clock never runs.
  - `testARightBellRimsSweepsAndStops`: a new `ring.clear` runs the clock for 0.8 s of beats, then stops; the same `ring` again starts nothing.
  - `testAHiddenTableCostsNothing`: with `board == nil`, changing `model.items` renders `.berryTable` zero times and no clock runs.
  - `testMissingPicturesDrawTheFallbacks`: with no items and `PlazaStubIconSource`, render succeeds and the bell's accessibility label is `L(.ko).plazaBerryBellFallback`.
  - Update the pinned panel lists (the four files above): `.berryTable` last; `WindowsPlazaPanelsTests`' draw-list counts +1 and its photo-mode `shown` set gains `.berryTable`.
- [ ] **Step 2: Run** `swift test --filter "PlazaBerryTablePanelTests|PlazaHUDControlsTests"`: fails to compile.
- [ ] **Step 3: Implement** the types, the layout, the panel and the drawing rules above, the panel id, the controller's model and panel, and `setBerryBoardForTesting` (sets `berryModel.board`).
- [ ] **Step 4: Run** `swift test --filter "PlazaBerryTablePanel|PlazaHUD|PlazaPanelRender|PlazaWindowTests"`: pass.
- [ ] **Step 5: Inject two faults, one at a time, and see a test fail:** the deck offset along the radius instead of the tangent; the clock started when `flip` grew by more than one. Restore each.
- [ ] **Step 6: Write the sheet** in `PlazaBerryTableRenderTests+Mac`, gated on `PTB_PLAZA_HUD_OUT` like `PlazaPanelRenderTests+Mac.testWritePanelImages` (plaza map background, scale 2): `testWriteTableSheet` writes ONE png labelled "sample data": rows 600×372 and 960×640; columns 2, 5 and 8 players, each at "넘기는 중" (a flip driven to its middle) and "종 친 순간" (rim showing, hop, 🔔, the event line "하늘님이 종을 쳤어요 · 0.41초 · +1"), with the mockup's names and Pokémon (25, 133, 4, 1, 7, 39, 52, 54) and one long name. Pictures come through `PlazaStoreIconSource()` and `PopoverItemImages.load(name:)` (cache or download; fallbacks show when offline, which is fine). Run: `PTB_PLAZA_HUD_OUT=<dir outside the repo> swift test --filter PlazaBerryTableRenderTests`.
- [ ] **Step 7: Measure the Mac cost.** `PlazaPanelCostTests+Mac.testBerryTableRenderCost`: 8 seats at 960×640, scale 2: the mean of 200 renders after `flip` +1, and of 200 renders on animation beats; print both. If the beat mean is above 4 ms, lower the clock to 20 per second and say so in the PR.
- [ ] **Step 8: Measure Windows** (§8 step 1, §11). In `WindowsSelftestPlazaPanels.swift`: set a sample 8-seat board through `setBerryBoardForTesting`, `expect("berry table", present: [.berryTable], png: "plaza-berry-five.png")`, then report `plaza.berryCost` (mean of 100 renders after `flip` +1; a report, not a budget), and clear the board. Push the branch; `gh workflow run windows-app.yml --repo likelion-campus/PokeTokenBar --ref <branch> -f level=light -f fast=true`; read `plaza.berryCost` and check the capture shows rotated cards.
- [ ] **Step 9: STOP. Show the sheet and the Windows capture to the user** (`open -g`) and ask whether they match the approved mockup: layout, 8 seats at the smallest window, card look, colours. Apply what they say; do not go on with your own choice.
- [ ] **Step 10: Commit** `feat(team): add the berry five table panel`. Run the plaza filter. Open **PR A** (Tasks 1 and 2): no visible change (nothing sets a board yet); the sheet and the Windows capture are its images, labelled sample data.

### Task 3: The deck, the tables and the shared state

**Files:**
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaBerry.swift`
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaGame.swift` (`PlazaGameKind.berry`; `offered` leaves it out; `PlazaGameState.berry`; `accepted`; `precedes`; the per-kind cap)
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaGameView.swift` only if D1 had been deleted (re-add `offered` as `kinds`' default)
- Modify: `Sources/PokeTokenBar/Team/TeamLocalization.swift` (`plazaGameName(.berry)` "열매 다섯"; `plazaGameRules(.berry)`: "같은 열매가 딱 5개면 스페이스로 종을 쳐요", "가장 빨리 치면 +1, 잘못 치면 −1이고 1초 쉬어요", "먼저 5점이면 우승 · 한 판 1~2분")
- Test: `Tests/PokeTokenBarTests/PlazaBerryTests.swift`, `PlazaGameTests.swift`

**Interfaces:**
- Consumes: Task 2's `Berry`, `Card`; D1, D2, D3.
- Produces:
  ```swift
  struct PlazaBerryState: Codable, Hashable, Sendable {
      var flips: [Int] = []         // the seat turned at each flip; flips.count is §4's `flip`
      var clears: [Int] = []        // flips.count at each clear, strictly increasing; clears.count is §4's `clears`
      var scores: [Int]             // by seat (the index in `players`)
      var judged: [Int]             // by seat: the serial of that player's last bell the dealer acted on (0: none)
      var last: Verdict?            // the last bell the dealer acted on
      var step = 0                  // +1 with every write
      struct Verdict: Codable, Hashable, Sendable { var seat: Int; var ms: Int; var right: Bool; var flip: Int; var clear: Int }   // clear: clears.count the bell was for
      init(seats: Int)
  }
  /// One ring, as the ringing machine saw it. Rides that machine's presence.
  struct PlazaBerryBell: Codable, Hashable, Sendable {
      var game: String              // PlazaGameState.id
      var clears: Int               // clears.count on my screen
      var flip: Int                 // flips.count on my screen
      var ms: Int                   // my reaction; 0 for a wrong bell
      var right: Bool               // my screen showed exactly five
      var serial: Int               // 1, 2, ... per game
      static func accepted(_ b: PlazaBerryBell?) -> PlazaBerryBell?
  }
  extension PlazaBerry {
      static let maxPlayers = 8, deckSize = 56, winScore = 5
      static let counts: [(count: Int, cards: Int)] = [(1, 5), (2, 3), (3, 3), (4, 2), (5, 1)]   // per berry
      static let flipSeconds: TimeInterval = 1.5, restSeconds: TimeInterval = 1.5, judgeSeconds: TimeInterval = 0.6
      static let lockoutSeconds: TimeInterval = 1, endWait: TimeInterval = 3, resultSeconds: TimeInterval = 5
      static let maxStep = 100_000, maxSerial = 1_000_000, maxReactionMS = 600_000
      /// Every seat's deck in flip order: 56 cards shuffled by the seed and dealt one at a time from seat 0.
      static func decks(seed: UInt64, seats: Int) -> [[Card]]
      /// Every seat's top card among the flips after clear `clear` (0: from the start) up to flip `flip`.
      static func table(_ b: PlazaBerryState, decks: [[Card]], flip: Int, clear: Int) -> [Card?]
      static func table(_ s: PlazaGameState) -> [Card?]        // now; empty without a payload
      static func fives(_ table: [Card?]) -> [Berry]           // berries summing to exactly five, in Berry order
      static func deckLeft(_ b: PlazaBerryState, decks: [[Card]], seat: Int) -> Int
      static func under(_ b: PlazaBerryState, seat: Int) -> Int
      /// The next seat to turn after the last flipped one (seat 0 first), among `playing` with cards left; nil if none.
      static func nextSeat(_ s: PlazaGameState, playing: Set<Int>) -> Int?
      // Transitions: each returns the next state with step + 1, or nil when `s` does not allow it.
      static func flipped(_ s: PlazaGameState, seat: Int) -> PlazaGameState?
      /// The right bell of `seat` wins this clear. Ends the game at `t` when that makes five points or no playing seat has cards.
      static func cleared(_ s: PlazaGameState, seat: Int, bell: PlazaBerryBell, playing: Set<Int>, at t: Double) -> PlazaGameState?
      static func penalized(_ s: PlazaGameState, seat: Int, bell: PlazaBerryBell) -> PlazaGameState?
      /// Ends at `t`; `winner` is the single top scorer among all players (gone ones too), nil on a tie.
      static func ended(_ s: PlazaGameState, at t: Double) -> PlazaGameState
      static func isValidRight(_ bell: PlazaBerryBell, in s: PlazaGameState) -> Bool
      static func isValidWrong(_ bell: PlazaBerryBell, seat: Int, in s: PlazaGameState) -> Bool
      /// Bounds on a received payload (§4). nil drops the whole game state.
      static func accepted(_ b: PlazaBerryState, players: Int) -> PlazaBerryState?
      static func keys(_ b: PlazaBerryState?) -> [Double]      // [clears.count, flips.count, step]; [-1, -1, -1] for nil
      static func tie(_ b: PlazaBerryState?) -> String         // last tie-break of `precedes`: the payload's own text
      static func ranking(_ s: PlazaGameState) -> [(id: String, score: Int)]   // score descending, then id
  }
  ```

- [ ] **Step 1: Write the failing tests** in `PlazaBerryTests` (plain `XCTestCase`):
  - `testADeckHasFourteenOfEachBerryInTheSpecMix`: `decks(seed: 1, seats: 1)[0]` has 56 cards, 14 per berry, and per berry the counts 1, 2, 3, 4, 5 appear 5, 3, 3, 2, 1 times.
  - `testTheDealIsOneAtATimeFromSeatZero`: for 3 seats the sizes are `[19, 19, 18]` and `decks(seed: s, seats: 3)[1][0] == decks(seed: s, seats: 1)[0][1]`.
  - `testTheSameSeedDealsTheSameCardsOnEverySystem` (§3.2, §9): for seed 7 and seats 2...8, FNV-1a 64 over `berry.rawValue * 8 + count` of every deck in order equals a pinned constant per seat count (compute once on the Mac and commit; the Windows unit-test CI proves agreement); seeds 1...20 give at least two hashes.
  - `testTheTableIsEachSeatsTopCardSinceTheLastClear`: 3 seats, flips `[0, 1, 2, 0]`: at flip 4 clear 0 the table is `[d[0][1], d[1][0], d[2][0]]`; at flip 3 `[d[0][0], d[1][0], d[2][0]]`; with clears `[3]`, at flip 4 clear 1 `[d[0][1], nil, nil]`.
  - `testOnlyExactlyFiveOfOneBerryRings` (§9): `[oran 3, oran 2]` gives `[.oran]`; `[oran 3, oran 3]` none; `[oran 4, sitrus 1]` none; `[oran 5]` `[.oran]`; `[oran 2, sitrus 5, oran 3, nil]` `[.oran, .sitrus]`.
  - `testAFlipTurnsTheNextPlayingSeatWithCards`: the first flip turns seat 0 (or the first playing seat); after seat 1 with playing `{0, 2}` comes 2; a seat with an empty deck is passed; nil when no playing seat has cards; `flipped` appends the seat and steps once; `flipped` on a seat with no cards is nil.
  - `testAClearScoresSweepsAndEndsAtFive`: `cleared` by seat 1: `scores[1] + 1`, `clears` gains `flips.count`, `last == Verdict(seat: 1, ms: bell.ms, right: true, flip: bell.flip, clear: old clears.count)`, step + 1; from 4 points it sets `endedAt == t`, `winner == players[1]`; with no playing seat holding cards it ends with the top scorer.
  - `testAWrongBellCostsOnePointOncePerSerialAndNeverBelowZero` (§9): `penalized` serial 3 takes 2 to 1 and sets `judged[seat] = 3`; serial 3 again and serial 2 give nil; at 0 the score stays 0 while `judged` and `last` still change.
  - `testTheEndWithoutFivePointsNamesTheTopScorerOrNobody` (§3.3.8): scores `[3, 1, 3]` give `winner == nil`; `[1, 4, 2]` give `players[1]`.
  - `testARightBellCountsOnlyWhenItsTableHadFive`: true for the current clear at a flip whose recomputed table has five; false at a flip without five, for a past clear, for a flip beyond `flips.count` or at or before the clear's flip, for another game id, for `right == false`.
  - `testAPayloadOutOfBoundsIsRefused` (§4): nil for 9 players, 57 flips, a flip seat ≥ players, a seat flipped more times than its deck holds, clears not strictly increasing, a clear of 0 or above `flips.count`, more clears than flips, scores or judged of the wrong length, a score of 6 or −1, judged above `maxSerial`, `last` naming a seat, flip or clear out of range, step below 0 or above `maxStep`; an honest 8-seat payload passes.
  - `testABellOutOfBoundsIsDropped`: nil for an empty or 65-byte `game`, clears −1 or 57, flip 57, ms −1 or `maxReactionMS + 1`, serial 0 or `maxSerial + 1`.
  - In `PlazaGameTests`: `testABerryStateWithMoreProgressWins` (more clears beats more flips, more flips beats more steps, either argument order); `testTwoDealersWithTheSameStepAgreeEverywhere` (two different payloads with equal keys: `merged(a, b) == merged(b, a)`); `testACopyWithoutTheBerryPayloadLoses` (a state stripped of `berry`, as an older app relays it, never replaces the full one); `testARecruitingGameCarriesNoBerryPayload`; `testABerryPayloadOnAnotherKindIsRefused`; `testBerryFiveIsCappedAtEightPlayers` (9 refused for `"berry"`, the bomb game still takes 20); `testTheMenuDoesNotOfferBerryFiveYet` (`PlazaGameMenu().kinds` does not contain `.berry`).
- [ ] **Step 2: Run** `swift test --filter "PlazaBerryTests|PlazaGameTests"`: fail.
- [ ] **Step 3: Implement.** The unshuffled deck lists berries in `Berry` order, counts ascending, each repeated as `counts` says; shuffle with `var g = PlazaSplitMix64(seed: seed ^ 0xBE77_F1FE)` and `for i in stride(from: 55, to: 0, by: -1) { a.swapAt(i, Int(g.next() % UInt64(i + 1))) }`; card `j` goes to seat `j % seats`. Integer arithmetic only. No transition moves past `maxStep`: at the cap `flipped`, `cleared` and `penalized` return `ended(s, at:)` with `winner == nil` instead. In `PlazaGame`: `.berry` joins the per-kind cap as D2 has it on `main` (if Task 1 found per-kind `kind ==` branches, fold them into `var maxPlayers: Int` on `PlazaGameKind`: bomb `PlazaGame.maxPlayers`, draw `PlazaDraw.maxPlayers`, berry `PlazaBerry.maxPlayers`, rather than adding a third branch); `accepted` requires `berry == nil` while recruiting, refuses a `berry` on another kind, and passes a present payload through `PlazaBerry.accepted`; `precedes` compares `PlazaBerry.keys` after the drawing quiz's keys and `PlazaBerry.tie` after the existing tie strings.
- [ ] **Step 4: Run** the same filter: pass; `swift test --filter "PlazaGame|PlazaDraw"` still passes.
- [ ] **Step 5: Inject three faults, one at a time:** `fives` with `>= 5`; `accepted` without the per-seat deck check; `precedes` without the berry keys. See a test fail for each; restore.
- [ ] **Step 6: Commit** `feat(team): add the berry five rules and state`.

### Task 4: The engine: the dealer, the bells, my screen

**Files:**
- Create: `Sources/PokeTokenBar/Team/Plaza/PlazaBerryLocal.swift` (one machine's unsent memory; pure value)
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaGame.swift` (`PlazaGameEngine`, `// MARK: - 열매 다섯`)
- Test: `Tests/PokeTokenBarTests/PlazaBerryEngineTests.swift`

**Interfaces:**
- Consumes: Task 3; D4, D5, D6, D10.
- Produces (on `PlazaGameEngine`):
  ```swift
  enum PlazaBerryPhase: Equatable, Sendable { case countdown(left: TimeInterval), playing, over }
  enum PlazaBerryRing: Equatable, Sendable { case ignored, right, wrong }
  /// nil unless a locked berry game with its payload runs or just ended. The countdown is 3 s from when THIS machine saw the lock.
  func berryPhase(now: Date) -> PlazaBerryPhase?
  var berryDealer: String? { get }           // who deals, as this machine sees it
  var berryPlaying: Set<String> { get }      // `playing` at the last tick
  var berryBell: PlazaBerryBell? { get }     // my last bell for this game; my presence carries it
  func berryLocked(uptime: TimeInterval) -> Bool   // my wrong bell's second is running
  /// The table now in `state` is on my screen from `uptime` (my monotonic clock); nil while my plaza is hidden.
  mutating func berrySeen(at uptime: TimeInterval?)
  /// Space or a press on the bell.
  mutating func ringBerry(now: Date, uptime: TimeInterval) -> PlazaBerryRing
  // tick(now:present:joins:connected:) gains `bells: [String: PlazaBerryBell] = [:]`: each teammate's own presence bell.
  ```

Rules (§3.3, §4), each with a test below:
- **Lock** (host): players are the first `PlazaBerry.maxPlayers` sorted joiners; `berry = PlazaBerryState(seats:)`.
- **Dealer:** the host while the host is in `playing`; once the host has been out of `playing` for `PlazaBomb.absenceGrace` on my clock, the smallest id in `playing`. Only the dealer writes, and only while connected; nobody else writes (leaving and isolation as D4).
- **Flips:** the first `PlazaGame.countdownSeconds` after the dealer first saw the lock; then `flipSeconds` after it first saw the latest flip; never while its judging window is open, nor within `restSeconds` of when it first saw the latest clear. The seat is `PlazaBerry.nextSeat` among `playing` (a seat missing for one flip is passed once, its deck kept).
- **Right bells:** valid ones (`isValidRight`, from a member in `playing` or my own) open a window when the dealer first sees one; after `judgeSeconds` on its clock the smallest `ms`, then the smaller id, wins: `cleared`. A takeover dealer judges the bells it sees in presences the same way.
- **Wrong bells:** valid ones (`isValidWrong`: current clear, serial above `judged`) are `penalized` at once; flipping goes on.
- **Past clears:** a bell whose `clears` is below `clears.count` is ignored: nothing written, no penalty.
- **End:** five points (`cleared`); no playing seat with cards and `endWait` since the dealer first saw the latest flip with no window open; fewer than two in `playing`; the step cap. `ended` names the winner.
- **My screen:** `berrySeen` keeps, per berry at exactly five on the current table, the uptime it first showed; a berry leaving five forgets it; `nil` forgets all (a hidden plaza shows nothing).
- **My bell:** `ringBerry` is `.ignored` (nothing sent) during the countdown, after the end, on an empty table, while `berryLocked`, while my right bell's verdict is pending (its `clears` is still `clears.count`), when I am not playing, or while my plaza is hidden (the last `berrySeen` was nil). Else `.right` when the table shows a five, with `ms` = uptime minus the earliest first-seen of the berries at five (rounded, at least 0), or `.wrong`, with the lock running `lockoutSeconds`; `serial` + 1 either way. The controller rings before the step's learn, so the table judged is the one `berrySeen` last saw.
- A started berry state without its payload: `berryPhase` nil, `tick` writes nothing.

- [ ] **Step 1: Write the test room** in `PlazaBerryEngineTests`, as `PlazaDrawEngineTests` (D10): engines by id; per engine a wall-clock `skew`, a monotonic `uptimeZero` and a receive `lag` (it hears the others' states and bells that much later); sets `gone`, `cutOff`, `hidden`; `step(_ seconds:)` advances a base time in 0.1 s ticks: every live engine ticks with `now = base + skew` and the bells it has received, then learns the states it has received, then `berrySeen(at: hidden ? nil : base + uptimeZero)`. `ring(_ id:)` calls `ringBerry` at the current base. A helper searches seeds 1...100_000, simulating with Task 3's transitions, for a deal with the pattern a test needs (a first five at a given flip; at least five fives when every five is rung at once).
- [ ] **Step 2: Write the failing tests:**
  - `testThreePlayersPlayToFivePoints`: b rings 0.3 s after each five shows; b ends with 5, `winner == "b"`, every engine holds the same state, `berryPhase == .over`.
  - `testTheDealerFlipsEveryOneAndAHalfSecondsAfterThreeSecondsOfCountdown`: on the host's clock, 0 flips at lock + 2.9 s, 1 at + 3.0 s, 2 at + 4.5 s; seats `[0, 1, 2, 0, …]`; a five on the table with nobody ringing keeps that pace (§2: no hint); no other engine's tick ever changes its state.
  - `testNineAnswersLockTheFirstEightByID` (§3.1): nine yeses at once: `players` is the first eight sorted ids and `berry.scores.count == 8`.
  - `testTheFastestReactionWinsAndATieGoesToTheSmallerID` (§9): b at 0.42 s and c at 0.31 s inside the window (c rings later in base time): c + 1 and `last.ms` within 10 of 310; both at 0.30 s: b wins.
  - `testALateScreenIsJudgedOnItsOwnClock` (§9, the reverse of the 2026-11-25 bomb defect): `lag["c"] = 0.4`; c rings 0.2 s after its own screen showed the five, b 0.35 s after its own: c wins and `last.flip` is the flip c saw.
  - `testTheSameGameEndsTheSameWithClocksFortyFiveSecondsApart` (§9): `skew = ["a": 45, "b": -45, "c": 0]` with different `uptimeZero`: the same script gives the same flips, clears and scores as the unskewed run, and the first flip comes within 3.3 s of the lock on the base clock.
  - `testABellFromAPastClearIsDroppedWithoutPenalty` (§9): c rings right on its stale screen after b's clear was written but before c heard it: c's score, `judged` and `last` are untouched.
  - `testAWrongBellCostsAPointOnceAndLocksForASecond` (§9): c, at 1 point, rings on cards without five: `.wrong`, c drops to 0, `judged` = its serial; again within 1 s of c's uptime: `.ignored`, same serial; the dealer ticking ten more times takes no second point; after 1 s a new wrong bell leaves c at 0 with the newer serial judged.
  - `testSpaceDoesNothingInTheCountdownOnAnEmptyTableOrAfterTheEnd` (§3.3.7, §9): `.ignored` and `berryBell` unchanged in each, and while my right bell awaits its verdict.
  - `testAFiveThatSurvivesAnotherFlipKeepsItsStart` (Review Focus 2): five appears at flip k, flip k + 1 turns another seat's other berry; b rings 0.2 s after flip k + 1 showed: `ms` within 10 of 1700. With two berries at five, the earlier start counts.
  - `testAHiddenPlazaCountsFromWhenTheTableShowedAgain` (Review Focus 3): b hidden from before flip k until 2 s after; b rings 0.3 s after it shows: `ms` within 10 of 300.
  - `testEmptyDecksAndPlayersWhoLeftAreSkipped` (§9): after c leaves its seat is never turned and its top card counts until the next clear; with 2 players each deck of 28 runs out and stops being turned.
  - `testABriefDropSkipsOneTurnAndEveryTableAgrees` (§9): c out of `joins` for one flip only: its seat is passed once, it keeps its cards, it is turned at its next turn, and every engine's `flips` is equal.
  - `testTheGameEndsWhenTheCardsRunOut` (§3.3.8): two players, nobody rings: ends `endWait` after the 56th flip, `winner == nil`; a clear right after the last card ends the game at that clear.
  - `testFewerThanTwoPlayingEndsAndTheTopScorerWinsEvenIfGone` (§9): scores a 0, b 2, c 1; b and c leave: the game ends and `winner == "b"`.
  - `testTheDealerMissingForThreeSecondsIsReplacedByTheSmallestPlayingID` (§9; pin the role, defect log 2026-11-22): host "c" of a, b, c is `gone`: nobody else writes at + 2.9 s; at + 3 s "a" deals, never "b".
  - `testATakeoverDealerJudgesTheBellsItSeesAndNeverTakesAWrongPointTwice` (§9): the host goes right after a's wrong bell was taken off and while b's right bell sits in its window: the new dealer clears for b once; a loses no second point.
  - `testTheHostComingBackDealsAgainAndTheTablesAgree`: host gone 5 s, then back: from then only the host writes flips and every engine's state is equal.
  - `testACutOffDealerWritesNothingAndStepsOut`: the host `cutOff` 11 s: its tick changes nothing, then `joined == nil` and `lostConnection` set; the smallest playing id deals meanwhile.
  - `testACopyWithoutTheBerryPayloadIsNeverDealt` (§10): an engine that only hears the stripped state: `berryPhase == nil`, its tick never changes its state.
  - `testTheLongestGameStaysInsideTheGameLife` (§3.4): 8 players, nobody right, one wrong bell every 1.1 s: ends by the cards before `opensAt + PlazaGame.maxLife`.
  - `testTheStepCapEndsTheGameWithNoWinner`: learned at `step == maxStep`, the dealer's next move ends the game with `winner == nil`.
- [ ] **Step 3: Run** `swift test --filter PlazaBerryEngineTests`: fail.
- [ ] **Step 4: Implement** the rules above. The bomb and drawing quiz branches stay as they are; guard the berry ones with the kind.
- [ ] **Step 5: Run** `swift test --filter "PlazaBerry|PlazaGame|PlazaDraw"`: pass.
- [ ] **Step 6: Inject four faults, one at a time, and see a test fail for each:** `ms` from the latest flip's sight instead of the five's first sight; a past-clear bell penalised; the takeover dealer ignoring `judged`; a flip during the judging window. Restore each.
- [ ] **Step 7: Commit** `feat(team): deal and judge berry five in the game engine`.

### Task 5: The bell in my presence

**Files:**
- Modify: `Sources/PokeTokenBar/Team/TeamWire.swift` (`TeamPresence.gameBell`, `@LossyOptional`)
- Modify: `Sources/PokeTokenBar/Team/TeamSession.swift` (`TeamMemberState.gameBell`; `updateGame`; `makePresence`; the presence `receive` case)
- Test: `Tests/PokeTokenBarTests/TeamWireTests.swift`, `TeamSessionTests.swift`, `TeamHostilePeerTests.swift`

**Interfaces:**
- Consumes: `PlazaBerryBell` (Task 3).
- Produces:
  ```swift
  // TeamPresence: @LossyOptional var gameBell: PlazaBerryBell?   (left out when nil; earlier versions ignore it)
  // TeamMemberState: var gameBell: PlazaBerryBell?              (kept only if PlazaBerryBell.accepted passes)
  // TeamSession:
  func updateGame(_ state: PlazaGameState?, join: String?, bell: PlazaBerryBell? = nil)   // broadcasts on any change
  ```
  `makePresence` sends `gameBell` only while it sends `game` and `bell.game == game.id`.

- [ ] **Step 1: Write the failing tests:**
  - `TeamWireTests.testAPresenceWithABellRoundTrips`; `testAPresenceWithoutABellDecodesAsBefore` (an older frame); `testALaterBellShapeIsDroppedAndTheFrameKept` (`"gameBell": {"game": 3}` decodes to a presence with `gameBell == nil` and its other fields).
  - `TeamSessionTests.testMyBellReachesTeammatesAtOnce` (§4: presence is not delayed): A calls `updateGame(state, join: id, bell: b)`; B's `members[A].gameBell == b` after the hub delivers, with no tick in between; `testABellIsNotSentWithoutItsGame` (state nil, or another game's id: `makePresence().gameBell == nil`).
  - `TeamHostilePeerTests.testAnAbsurdBellIsDropped`: a presence with serial 0 or ms −1 leaves `gameBell == nil` and the rest of the member intact.
- [ ] **Step 2: Run** `swift test --filter "TeamWireTests|TeamSessionTests|TeamHostilePeerTests"`: fail.
- [ ] **Step 3: Implement** the field, the member value, the `updateGame` parameter (its guard compares the bell too), `makePresence` and the receive line. `testWireJSONCarriesNoUsageOrHostWords` must still pass (no field name holds those words).
- [ ] **Step 4: Run** the filter: pass.
- [ ] **Step 5: Commit** `feat(team): carry the berry five bell in the plaza presence`. Run the plaza filter. Open **PR B** (Tasks 3 to 5); its text says the game is not reachable yet.

### Task 6: The HUD hides the other panels while the table shows

**Files:**
- Modify: `Sources/PokeTokenBar/Team/Plaza/HUD/PlazaHUD.swift`
- Test: `Tests/PokeTokenBarTests/PlazaHUDTests.swift`, `WindowsPlazaPanelsTests.swift`

**Interfaces:**
- Produces:
  ```swift
  // PlazaHUD
  /// Panels another panel covers for now (the berry table): treated exactly as not visible. They are hidden through the host, take no
  /// click, hover, scroll or press, and do not render; their changes are remembered and they render once when let go. Setting it ends
  /// a press, a hover and a scroller capture on them. Independent of `hiddenPanels` (photo mode).
  var suppressed: Set<PlazaPanelID>
  ```
  Every place that reads `panel.isVisible` (`layout`, both `hit`s, `handleMouse`, `scrollIntoView`, `update`) reads "visible and not suppressed". No host changes: both windows already follow `show` and `hide`.

- [ ] **Step 1: Write the failing tests** in `PlazaHUDTests` (fake panels, a recording host, as the file's other tests do):
  - `testASuppressedPanelIsHiddenTakesNoClickAndDoesNotRender`: `suppressed = [b]`: the host got `hide(b)`; `hit(at:)` over b gives the panel below or nil; `handleMouse(.down)` over b alone returns false; b's `onChange` renders nothing; `suppressed = []` renders b once and shows it.
  - `testSuppressingDuringAPressOrAScrollerDragEndsIt`: a press on b, then `suppressed = [b]`, then release: no `onAction`; a scroller press on b, suppress, move: b's `scrollerMouse` gets no `.drag`.
  - `testSuppressionAndPhotoModeHidingAreIndependent`: `hiddenPanels = [c]`, `suppressed = [b]`; clearing `suppressed` leaves c hidden.
  - `WindowsPlazaPanelsTests.testASuppressedPanelLeavesTheDrawList`: `hud.suppressed = [.pills]` removes it from `drawList`, `host(at:)` never returns it, and clearing brings it back.
- [ ] **Step 2: Run** `swift test --filter PlazaHUDTests`: fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `swift test --filter "PlazaHUD|PlazaPanel|PlazaWindow"`: pass.
- [ ] **Step 5: Inject a fault:** `handleMouse` still routing a press to a suppressed panel. See a test fail; restore.
- [ ] **Step 6: Commit** `feat(team): let the plaza HUD set panels aside while one covers the window`.

### Task 7: A player's plaza becomes the table

**Files:**
- Create: `Sources/PokeTokenBar/Team/Plaza/PlazaBerryView.swift` (`PlazaBerryBoard.make`)
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaBerry.swift` (`uptime()`)
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaInteraction.swift` (`PlazaOverlayContent.berryTable`)
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaWindowController.swift` (the `uptime` init parameter; `stepGame`; opening and closing the table; keys; the bell; pictures; `setRendering`)
- Modify: `Sources/PokeTokenBar/Team/TeamLocalization.swift` (event and result strings below)
- Test: `Tests/PokeTokenBarTests/PlazaBerryControllerTests.swift`

**Interfaces:**
- Consumes: Tasks 2 to 6; D9, D10.
- Produces:
  ```swift
  extension PlazaBerry { static func uptime() -> TimeInterval }   // ContinuousClock since the first call in this process
  enum PlazaOverlayContent { …, case berryTable }
  extension PlazaBerryBoard {
      /// The table as `engine` knows it, for its own player; nil unless I am a player of a locked berry game with its payload.
      @MainActor static func make(engine: PlazaGameEngine, now: Date, uptime: TimeInterval,
                                  seat: (String) -> (name: String, color: PlazaColor, mon: TeamMonSummary)) -> PlazaBerryBoard?
  }
  // PlazaWindowController
  init(…, uptime: @escaping () -> TimeInterval = PlazaBerry.uptime)
  var berryBoard: PlazaBerryBoard? { get }
  var isBerryTableOpen: Bool { get }
  var berryTableSpaces: Int { get }                        // Space presses that reached the table (Task 9's selftest)
  func setBerryBoardForTesting(_ board: PlazaBerryBoard?)  // now opens the table as a player's would; nil closes it
  ```
  `PlazaBerry.uptime` uses `ContinuousClock` rather than `ProcessInfo.systemUptime`: on Windows the latter counts system ticks of about 15.6 ms.

What each part does:
- **Step:** `stepGame` passes `bells` (each member's `gameBell` among those in the plaza) to `tick`, then `game.berrySeen(at: hud.isRendering ? uptime() : nil)`, then `session.updateGame(game.state, join: game.joined, bell: game.berryBell)`. `setRendering(visible:)` also calls `berrySeen` at once, so a window shown again stamps its five at that moment.
- **Board:** seats rotated so I am index 0, then the players' order; my name and look from `nickname()` and `subject()`, the others' from `members`; `isPlaying` from `berryPlaying`; `center` is `.countdown` (seconds left, rounded up), `.playing(event:)` from `last` (`plazaBerryRang` or `plazaBerryMissed`), or `.result(lines:)` (winner or tie line, then `plazaBerryRank` per player, then `plazaBerryCloseHint`); `ring` when `last.right` and `last.clear == clears.count - 1` (the table at the clear's flip, the five's seats at `last.flip`); `wrong` while `berryLocked` after my own wrong bell.
- **Open** when `berryPhase != nil`, I am a player (`isPlayer`) and this game's table was not closed before: exit photo mode, close an open chat field without sending, `openOverlay(.berryTable)` (it replaces any other overlay), `hud.suppressed` = every panel id but `.berryTable`.
- **Close** `PlazaBerry.resultSeconds` after I first saw the end, at Space or Esc during the result, when I stop being a player, or when the window closes: `closeOverlay()`, `hud.suppressed = []`, remember the game id so the table never reopens for it.
- **Keys:** `handleOverlayKey(.berryTable)`: Space rings (or closes the result); Esc closes only the result; up, down and Enter do nothing. M, Y, N and the rest never reach the controller while an overlay is open, and held keys repeat nothing (the scene drops repeats).
- **Bell:** `berryPanel.onBell` and `panelClicked(.berryTable, "bell")` (VoiceOver) ring through `stepGame { $0.ringBerry(now: $1, uptime: uptime()) }`.
- **Pictures:** when a berry game is first seen (recruiting included), load the four berries and `soothe-bell` once each through `throwItem` (the same item loader as the summer balloon) into `berryModel.items`; a failed one is tried again with the next berry game.
- **Strings** (Korean, `TeamLocalization`): `plazaBerryRang(nickname: String?, ms: Int)` "하늘님이 종을 쳤어요 · 0.41초 · +1" (nil: "내가 종을 쳤어요 · …"), `plazaBerryMissed(nickname: String?)` "민수님 −1" (nil: "내 종 −1"), `plazaBerryWinner(nickname: String?)` "하늘님 우승!" (nil: "내가 우승!"), `plazaBerryTie(names: [String])` "공동 1등 하늘 · 지아", `plazaBerryRank(place: Int, nickname: String, score: Int)` "1등 하늘 5점", `plazaBerryCloseHint` "스페이스나 Esc로 닫기".

- [ ] **Step 1: Write the test world** in `PlazaBerryControllerTests`, as `PlazaDrawControllerTests` (D10): my real controller plus two bare teammate nodes driving their own engines and sending their `berryBell`, a settable wall clock and a settable `uptime`, a seed helper that gives a five at a wanted flip, `stepAll()`.
- [ ] **Step 2: Write the failing tests:**
  - `testTheTableOpensForPlayersAndHidesEveryOtherPanel`: at the lock `isBerryTableOpen`, `overlayContent == .berryTable`, `hud.suppressed` is every other panel id; a teammate who did not join has no table.
  - `testTheTableTakesOverAnOpenChatFieldOverlayOrPhotoMode` (Review Focus 1): three runs: the chat field open with "안녕" (closed, no teammate received a line), the news board open (replaced), photo mode on (left); in each, Space on the next five sends a right bell.
  - `testSpaceRingsAndHoldingItRingsOnce`: `handleKeyDown(49, isRepeat: false)` on a five: the teammate dealer clears for me; ten `isRepeat: true` events leave `berryBell?.serial` unchanged; `berryTableSpaces` counts the one press.
  - `testAPressOnTheBellRingsAtThePress`: `hud.handleMouse(.down)` at the bell's centre raises the serial before any `.up`.
  - `testOtherKeysDoNothingAtTheTable`: M, Y, N, arrows, Enter and Esc during play: no menu, no answer, my tile unchanged, the table stays.
  - `testAWrongBellShowsTheCrossForASecond`: `berryBoard?.wrong` right after a wrong bell; false after `uptime` + 1 s and a step.
  - `testTheResultShowsFiveSecondsThenTheHUDComesBack` (§5.1): at the end `center` is `.result` with the winner line first; 5 s later the table is closed and `hud.suppressed` empty; it does not reopen while the ended game is kept; M opens the menu once the rematch delay passed.
  - `testSpaceOrEscClosesTheResultAtOnce`.
  - `testClosingThePlazaLeavesTheGameAndReopeningWatches` (§3.6): after close and reopen there is no table, and the teammates' boards draw my seat faded.
  - `testTheBoardSeatsMeAtTheBottomThenClockwise`: players `[a, me, c]` give seat ids `[me, c, a]`.
  - `testAFiveWithoutABellShowsNoHint` (§2): while a five shows and nobody has rung, `berryBoard.ring == nil`, the event line is unchanged and the next flip still comes 1.5 s after the last.
  - `testAJumpOfSeveralFlipsShowsTheLatestTable` (Review Focus 5): `setRendering(visible: false)` while three flips arrive; shown again: `berryBoard.flip` grew by 3, the panel is not animating, the tops equal `PlazaBerry.table(state)`, and Space is judged on that table.
  - `testTheBerryPicturesLoadWhenTheGameOpens`: a recording `throwItem` gets the four berry names and `soothe-bell` once each while recruiting.
- [ ] **Step 3: Run** `swift test --filter PlazaBerryControllerTests`: fail.
- [ ] **Step 4: Implement** the parts above.
- [ ] **Step 5: Run** `swift test --filter "PlazaBerry|PlazaGame|PlazaHUD"`: pass.
- [ ] **Step 6: Inject three faults, one at a time:** the chat field left open at the table's opening; `berrySeen` stamped while the window is hidden; `suppressed` not cleared at closing. See a test fail for each; restore.
- [ ] **Step 7: Commit** `feat(team): play berry five at the plaza table`.

### Task 8: What watchers and the result show

**Files:**
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaGameView.swift` (the berry branch of `make`)
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaWindowController.swift` (`gameChanged` and `refreshGame` for berry; the 🔔 bubble; banners; loud lines at the table)
- Modify: `Sources/PokeTokenBar/Team/TeamLocalization.swift` (`plazaBerryStatus(scores: [(name: String, score: Int)])` "열매 다섯 진행 중 · 하늘 3 · 지아 2"; `plazaBerryTieBanner(names:)` "🏆 열매 다섯 공동 1등: 하늘 · 지아")
- Test: `Tests/PokeTokenBarTests/PlazaBerryControllerTests.swift`

**Interfaces:**
- Consumes: Task 7; D2 (the invitation at eight), D8.

What each part does (§5.2, §5.3, §3.1):
- **View:** for a berry game, `make` reads `berryPhase`; `alive` is the players (the bomb game's rings, D8); `status` is `plazaBerryStatus` over `PlazaBerry.ranking` for everyone in the plaza while it runs; players get no card, title or hint (the table shows them); the invitation counts and closes at eight as D2 does for the drawing quiz.
- **🔔:** when a new right clear arrives, `scene.showChat(memberID: ringer, text: plazaBerryBellMark)` (the chat bubble draws emoji on both systems; no new scene node or emote kind).
- **Result:** watchers get `plazaGameWinBanner` or `plazaBerryTieBanner` when the game ends; a player gets the same banner when the table closes; no big title for berry; a lost connection shows `plazaGameLostConnectionBanner` instead.
- **Megaphone:** a loud line received while the table is open goes to the chat log without `showBanner` (§5.1).

- [ ] **Step 1: Write the failing tests:**
  - `testWatchersSeeTheScoresAndTheBellOverTheRinger`: a teammate who did not join: `gameStatus` starts with "열매 다섯 진행 중" and lists the scores; after a clear `scene.shownChat(memberID: ringer) == "🔔"`; no table.
  - `testTheResultIsABannerForWatchersAndForPlayersAfterTheTable`: watcher's banner at the end names the winner; a tie names both through `plazaBerryTieBanner`; my banner appears when my table closes, not before; `gameTitle` stays nil.
  - `testTheInvitationClosesAtEightPlayers`: eight members' presence say yes: my card's join button is disabled with D2's full line; with seven it is enabled.
  - `testALoudLineDuringTheTableShowsNoBanner`: `showChat(isLoud: true)` while the table is open leaves `overlayModel.banner` unchanged and the line is in the chat log.
  - `testPlayersAreRingedDuringTheGame`: every player is marked `.alive`, nobody `.holder`.
- [ ] **Step 2: Run** `swift test --filter PlazaBerryControllerTests`: fail.
- [ ] **Step 3: Implement** the parts above.
- [ ] **Step 4: Run** `swift test --filter "PlazaBerry|PlazaGame"`: pass.
- [ ] **Step 5: Have the strings reviewed** (Tasks 2, 3, 7, 8) by a fresh reviewer (sonnet) against §3 and the bar "a first-time player knows what to do from the line alone" (defect log 2026-11-25, fortune entry); apply what it finds.
- [ ] **Step 6: Commit** `feat(team): show berry five to watchers and end it with a banner`. Run the plaza filter. Open **PR C** (Tasks 6 to 8) with the Task 2 images and a render of the real board at the bell moment; its text says the game is still not in the menu.

### Task 9: Into the menu, Windows checks, documents

**Files:**
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaGame.swift` (`offered` no longer leaves `.berry` out; delete `offered` if nothing else is left out), `PlazaGameView.swift` if `kinds` goes back to `allCases`
- Modify: `Sources/PokeTokenBar/Platform/Windows/WindowsSelftestPlazaInput.swift` or `WindowsSelftestPlazaPanels.swift` (`plaza.berrySpace`; the capture again)
- Modify: `assets/windows/SHOT-LIST.txt`, `assets/windows/SHOTS.txt` (through `scripts/import-windows-shots.sh`), `assets/screenshot-plaza-berry-five.png`, `TEAM.md`
- Test: `Tests/PokeTokenBarTests/PlazaGameTests.swift`, `PlazaGameControllerTests.swift`

- [ ] **Step 1: Write the failing tests:** replace `testTheMenuDoesNotOfferBerryFiveYet` with `testTheMenuOffersEveryGame` (`PlazaGameMenu().kinds == PlazaGameKind.allCases`); in `PlazaGameControllerTests`, `testChoosingBerryFiveOpensItForEveryone` (M, down to the berry row, Space opens a game of kind `"berry"` whose card on the teammate's node shows the three rule lines).
- [ ] **Step 2: Implement** the menu change. Run `swift test --filter "PlazaGame|PlazaBerry"`: pass.
- [ ] **Step 3: Windows selftest** (§11). Through `setBerryBoardForTesting` open the table with a sample board; `tap(49)` (real input on CI only, as `plazaInputChecks` does): `plaza.berrySpace` passes when `berryTableSpaces` grew by one, a 0.9 s hold adds exactly one more, and `drawList` holds only `.berryTable` (the others are suppressed); close it; take `plaza-berry-five.png` again and report `plaza.berryCost`. Push; `gh workflow run windows-app.yml --repo likelion-campus/PokeTokenBar --ref <branch> -f level=light -f fast=true`; read `plaza.berrySpace`, `plaza.berryCost` and the capture. A difference from the Mac goes into `docs/reference/windows-differences.md` with its reason.
- [ ] **Step 4: Documents.** `SHOT-LIST.txt` line `plaza-berry-five.png | windows-app | plaza-berry-five.png`; `scripts/import-windows-shots.sh <run id>`; `assets/screenshot-plaza-berry-five.png` from the Task 2 sheet test (960×640, 5 players, bell moment; labelled sample data); `TEAM.md`: the M row lists the game and describes it in user words (§3 rules and numbers, the table replaces the plaza for players, Space or a click on the bell, Esc and other keys do nothing, closing the plaza leaves, watchers see scores and 🔔), the list of what goes to teammates gains the berry state and the bell (game, clear, flip, reaction in ms, right or wrong, serial), the mixed-version line (v2.5.638 up to the last version without the game see "앱을 업데이트하면 참가할 수 있어요"), both images embedded. `python3 scripts/team_docs_check.py` passes.
- [ ] **Step 5: Run** the plaza filter. **Commit** `feat(team): add berry five to the plaza minigames`. Open **PR D**.
- [ ] **Step 6: Tell the user what only people can check** (§9): one game on a Mac and a Windows PC together; whether a bell ever feels "I rang first" and lost; whether 1.5 s per flip and the 0.6 s window feel right (the window is the number to tune). Do not release unasked.
