# Plaza Drawing Quiz ("그림 퀴즈") Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A second plaza minigame: players take turns typing a word and drawing it with the mouse on a small pixel canvas, the others guess by chat, the first correct guess ends the turn, and a ranking shows at the end. Mac and Windows play in one game.

**Architecture:**
- **Lobby reuse.** `PlazaGameKind.draw` rides the existing lobby (`PlazaGame.swift`): menu, invitation card, Y/N, countdown. Its payload is `PlazaGameState.draw: PlazaDrawState?`, beside `bomb`.
- **One writer per turn.** Only the drawer's machine (and a referee when the drawer is gone) writes the shared state. Every deadline is measured on the writer's own clock from the moment it learned of the phase; no machine compares another machine's timestamp with its own clock. Who is "playing" is read from each member's presence (`inPlaza` and `gameJoin == id`), never written into the shared state.
- **Pure rules, thin glue.** `PlazaDraw` (new file) holds constants, word/answer/hint text rules and state transitions as pure functions on values. `PlazaGameEngine` (in `PlazaGame.swift`, where its private state lives) adds the local timers and calls them.
- **Strokes.** A new top-level wire message `draw` (`TeamDraw`) carries strokes, clears and whole-canvas snapshots from the drawer. Old apps skip unknown kinds. The canvas is a value type (`PlazaDrawCanvas`) with integer-only drawing, shown as one enlarged image layer of a new HUD panel.
- **Input.** The panel takes drags through the capture path the legacy scroller already has (`scrollerContains` / `scrollerMouse`): no platform input code changes. The word is typed in the existing chat field, which gains a `purpose`.

**Tech Stack:** Swift 6 (SwiftPM), XCTest, shared sources under `Sources/PokeTokenBar/Team` (Mac and Windows), AppKit only under `Team/UI` and `Platform/Mac`, Win32 under `Platform/Windows`.

**Spec:** `docs/superpowers/specs/2026-11-25-plaza-draw-quiz-design.md` (Korean). Section numbers below (§) refer to it. Read it first; where this plan and the spec disagree, the spec wins and the plan is wrong.

## Global Constraints

- Work in a git worktree under `.worktrees/`, never the main checkout. Merge `origin/main` before each PR. Fork only: always `--repo likelion-campus/PokeTokenBar`.
- Commits and PR text in English (Conventional Commits). User-visible strings are Korean and live only in `Sources/PokeTokenBar/Team/TeamLocalization.swift` (`TeamLocalizationTests.testTeamSourcesHaveNoHangulLiterals`). Tests may hold Korean literals.
- Shared files (`Team/Plaza/**`, `Team/*.swift`) import only `Foundation` and `Observation`. No `#if os` outside the three allowed guard shapes (`SharedSourcesScanTests`).
- `@MainActor` test classes: every test method is `async`. Tests make defaults with `TestDefaults`, never `UserDefaults(suiteName:)`.
- Numbers (§3, §15), all in `PlazaDraw`: 2 to 8 players; two rounds for 2 to 4 players, one for 5 to 8; word entry 20 s, drawing 60 s, result 6 s; referee slack 10 s; guesser +10, drawer +5; word 1 to 12 characters; hint 1 at half the drawing time (letter count), hint 2 at three quarters (initial consonants); canvas 96 by 64 cells, 8 pen colours on a paper colour.
- No protocol version bump (`TeamWire.protocolVersion` stays 1). No new field on `TeamChat`, `TeamEmote` or `TeamPresence` other than `PlazaGameState.draw`.
- The word never leaves the drawer's machine before the turn ends (§2). No test or log may print it earlier.
- The game stays out of the M menu until Task 8: `PlazaGameMenu.kinds` reads `PlazaGameKind.offered`, which leaves `.draw` out. A release cut from `main` before Task 8 must show no trace of the game.
- No hand-drawn icons in code: tools are text buttons and plain colour squares (§2).
- The panel's layout and colours are chosen by the user from a rendered sheet (Task 6). Do not pick for them.
- One `swift build` or `swift test` at a time on this Mac; never run one while another session's `team-release.sh` runs (`ps aux | grep scripts/team-release.sh`).
- Before each PR: `swift test --filter "Plaza|Team|SpriteKit|Mirror|ScanTests|GuardTests|GateTests|TestIsolationTests|WindowsScanRootPathTests"` (about 18 minutes).
- PRs: A = Tasks 1 to 3, B = Tasks 4 and 5, C = Tasks 6 and 7, D = Task 8. Each merges to `main` on its own. PR text follows `.agents/skills/prepare-pr/SKILL.md`.

## Review Focus

Inputs the spec implies and a person will hit; each has its test in the task named.

1. **The window is resized, or sits at the minimum 600 by 372, while a stroke is under way.** The pointer still maps to the right cell and the stroke does not jump. Task 6, `testACellUnderThePointerIsTheSameAtEveryWindowSize`.
2. **An overlay (news board, member card, M menu) opens, or photo mode starts, while the mouse is down on the canvas.** The stroke ends there; no capture is left behind and the next press draws. Task 7, `testAnOverlayOpenedMidStrokeEndsTheStroke`.
3. **My turn begins while I am typing a chat line.** The line is not thrown away and is not taken as the word; the word field opens after the chat field closes. Task 7, `testMyTurnWaitsForAnOpenChatLine`.
4. **The 20 seconds run out while a Korean syllable is being composed in the word field.** The field closes, the turn passes with no word, nothing half-typed is sent as a word or as chat. Task 7, `testTheWordFieldClosesAtTheDeadlineWithoutSending`; Task 2 covers the field itself on each OS.
5. **A right answer typed differently.** Decomposed Hangul (NFD), spaces inside, trailing punctuation and upper case match; an answer with extra letters ("사과인가", "사과ㅋㅋ") does not. Task 4, `testAnAnswerMatchesWhateverItsSpacingCaseOrComposition`.

---

### Task 1: The `draw` wire message and the session's send and receive

**Files:**
- Modify: `Sources/PokeTokenBar/Team/TeamWire.swift` (new `TeamDraw`; `TeamMessage.draw`; `knownKinds`; the lenient `catch`)
- Modify: `Sources/PokeTokenBar/Team/TeamSession.swift` (`sendDraw`, `onDraw`, a per-link bucket, the `receive` case)
- Modify: `Sources/PokeTokenBar/Team/TeamRuntime.swift`, `Sources/PokeTokenBar/Team/PlazaPresenting.swift`
- Modify: every `PlazaPresenting` conformer: `Team/Plaza/PlazaWindowController.swift` (empty body for now), `Platform/Windows/WindowsSelftestPlaza.swift`, `Tests/PokeTokenBarTests/PlazaWindowShellTests.swift`
- Test: `Tests/PokeTokenBarTests/TeamWireTests.swift`, `TeamSessionTests.swift`, `TeamHostilePeerTests.swift`

**Interfaces:**
- Produces:
  ```swift
  struct TeamDraw: Codable, Equatable, Sendable {
      static let maxPoints = 64                 // points in one stroke message
      static let maxCellsBase64 = 20_000        // characters of `cells`
      enum Op: String, Codable, Sendable { case stroke, clear, snapshot }
      var game: String        // PlazaGameState.id
      var turn: Int
      var seq: Int            // grows by one per message within a turn; a snapshot carries the last seq it includes
      var op: Op
      var color: Int?         // stroke
      var width: Int?         // stroke
      var points: [Int]?      // stroke: x0, y0, x1, y1, ...
      var cells: String?      // snapshot: base64 of PlazaDrawCanvas.packed()
  }
  // TeamMessage gains: case draw(TeamDraw)
  // TeamSession gains:
  static let drawPerSecond = 40
  func sendDraw(_ draw: TeamDraw)                                   // broadcast
  @ObservationIgnored var onDraw: ((_ memberID: String, TeamDraw) -> Void)?
  // PlazaPresenting gains:
  func showDraw(from sender: String, _ draw: TeamDraw)
  ```

- [ ] **Step 1: Write the failing wire tests** in `TeamWireTests`:
  - `testADrawMessageRoundTrips`: encode and decode `.draw(TeamDraw(game: "g", turn: 2, seq: 7, op: .stroke, color: 3, width: 1, points: [1, 2, 3, 4]))`, equal.
  - Extend `testWireRawValuesArePinned`: the top-level key set now includes `"draw"`; `TeamDraw.Op` raw values are `["stroke", "clear", "snapshot"]`.
  - `testAnUnreadableDrawIsSkippedAndTheLinkStays`: a frame `{"draw":{"_0":{"game":"g","turn":0,"seq":0,"op":"fill"}}}` followed by a valid chat frame decodes to exactly the chat (no throw).
  - Add `.draw(...)` to `allMessages` (the list the suite iterates).
- [ ] **Step 2: Run** `swift test --filter TeamWireTests` and see them fail (no `TeamDraw`).
- [ ] **Step 3: Implement** `TeamDraw`, the enum case, `"draw"` in `knownKinds`, and `kind == "draw"` in the lenient `catch` beside presence, emote and chat.
- [ ] **Step 4: Write the failing session tests:**
  - `TeamSessionTests.testADrawReachesTheTeammatesOnDraw`: two sessions on a `FakeTransportHub`; A calls `sendDraw`, B's `onDraw` gets `(A.memberID, the same value)`.
  - `TeamHostilePeerTests.testDrawsOverTheRateAreDropped`: B receives 100 draws from A at one clock instant; `onDraw` fires `TeamSession.drawPerSecond` times; after the clock moves 1 s, 40 more pass.
  - `TeamRuntimeTests.testAReceivedDrawReachesThePlaza`: the fake plaza's `showDraw` is called with the sender and value.
- [ ] **Step 5: Implement** `sendDraw` (as `sendChat`), a `TeamTokenBucket` named `draws` on `Link` (capacity and refill `drawPerSecond`), the `receive` case (`guard links[peer]?.draws.take(now: clock()) == true`), `onDraw`, the runtime hook `session.onDraw = { [weak self] id, d in self?.plaza?.showDraw(from: id, d) }`, the protocol requirement and the empty conformances.
- [ ] **Step 6: Run** `swift test --filter "TeamWireTests|TeamSessionTests|TeamHostilePeerTests|TeamRuntimeTests"`: all pass.
- [ ] **Step 7: Commit** `feat(team): add the draw message for plaza drawings`.

### Task 2: The chat field can ask for a quiz word

**Files:**
- Modify: `Sources/PokeTokenBar/Team/Plaza/Draw/PlazaWindowShell.swift` (`PlazaChatInputHost`, new `PlazaChatInputPurpose`)
- Modify: `Sources/PokeTokenBar/Team/UI/PlazaChatInput.swift` (Mac), `Sources/PokeTokenBar/Platform/Windows/Plaza/WinPlazaChatInput.swift`, `Sources/PokeTokenBar/Team/Plaza/Draw/PlazaHeadlessShell.swift` (`PlazaStubChatInput`), and `Team/Plaza/HUD/PlazaChatBarPanel.swift` if the Windows placeholder is drawn there
- Modify: `Sources/PokeTokenBar/Team/TeamLocalization.swift` (`plazaDrawWordPlaceholder`: "제시어 (12자까지)")
- Test: `Tests/PokeTokenBarTests/PlazaChatTests+Mac.swift`, `WindowsPlazaChatInputTests.swift`

**Interfaces:**
- Produces:
  ```swift
  enum PlazaChatInputPurpose: Equatable, Sendable {
      case chat, quizWord
      var maxCharacters: Int { self == .chat ? TeamChat.maxCharacters : 12 }
  }
  // PlazaChatInputHost gains:
  /// What the field is asking for. Set it before `open()`. `close()` puts it back to `.chat`.
  var purpose: PlazaChatInputPurpose { get set }
  ```
  In `.quizWord`: the placeholder is `plazaDrawWordPlaceholder`, the text is cut at 12 characters (after a composition ends, as the chat cut), Tab does not switch the megaphone and `isLoud` is false, and the emoji picker does not open.

- [ ] **Step 1: Write the failing tests**, the same three on each OS's field (`PlazaChatTests+Mac`, `WindowsPlazaChatInputTests`):
  - `testTheWordFieldCutsAtTwelveAndHasItsOwnPlaceholder`: purpose `.quizWord`, open, type 15 Hangul syllables; the field holds 12; the placeholder equals `L(.ko).plazaDrawWordPlaceholder`.
  - `testTheWordFieldHasNoMegaphone`: Tab in `.quizWord` leaves `isLoud == false`.
  - `testClosingPutsThePurposeBackToChat`: after `close()`, `purpose == .chat` and the next `open()` cuts at `TeamChat.maxCharacters`.
  - Mac only, `testEnterDuringCompositionInTheWordFieldOnlyCommits`: with marked text, Enter does not call `onSubmit` (the existing chat rule holds in this purpose).
- [ ] **Step 2: Run** `swift test --filter "PlazaChatTests"` and see them fail.
- [ ] **Step 3: Implement** the enum, the protocol property and the three implementations. The stub stores the value and resets it in `close()`.
- [ ] **Step 4: Run** `swift test --filter "PlazaChat|WindowsPlazaChatInput"`: pass.
- [ ] **Step 5: Commit** `feat(team): let the plaza chat field ask for a quiz word`.

### Task 3: The canvas value

**Files:**
- Create: `Sources/PokeTokenBar/Team/Plaza/PlazaDrawCanvas.swift`
- Test: `Tests/PokeTokenBarTests/PlazaDrawCanvasTests.swift`

**Interfaces:**
- Produces:
  ```swift
  /// The quiz canvas: one palette index per cell, row 0 on top. Integer drawing only, so both systems draw the same cells.
  struct PlazaDrawCanvas: Equatable, Sendable {
      static let width = 96, height = 64
      static let colorCount = 9                    // 0 is the paper, 1...8 the pens
      static let widths: Set<Int> = [1, 3, 5]      // thin pen, thick pen, eraser
      private(set) var cells: [UInt8]              // width * height
      init()
      subscript(x: Int, y: Int) -> UInt8 { get }   // 0 outside the canvas
      /// Draws straight segments between the points with a square brush `width` cells wide, centred on the line.
      /// Nothing is drawn and false comes back when the list is empty, odd, longer than `2 * TeamDraw.maxPoints`,
      /// holds a point outside the canvas, or the colour or width is not one of the allowed values.
      @discardableResult mutating func stroke(points: [Int], color: Int, width: Int) -> Bool
      mutating func clear()
      /// Run-length pairs (count 1...255, colour), rows in order.
      func packed() -> Data
      /// nil unless the data expands to exactly `width * height` cells of valid colours.
      init?(packed: Data)
      func bitmap(palette: [PlazaRGBA]) -> PlazaBitmap     // palette.count == colorCount
  }
  ```

- [ ] **Step 1: Write the failing tests** (plain `XCTestCase`, not `@MainActor`):
  - `testAThinStrokeSetsExactlyTheCellsOfItsLine`: `stroke(points: [2, 2, 5, 2], color: 3, width: 1)`; cells (2...5, 2) are 3, every other cell 0.
  - `testAThickDotIsAThreeByThreeBlock`: `stroke(points: [10, 10], color: 1, width: 3)`; the nine cells around (10, 10) are 1, the count of non-zero cells is 9.
  - `testADiagonalIsContinuous`: `[0, 0, 7, 5]` width 1 touches every column 0...7 once per step with no gap (each consecutive pair of set cells differs by at most 1 in x and in y).
  - `testABrushAtTheEdgeIsClippedNotWrapped`: width 5 at (0, 0) sets only cells with x and y in 0...2.
  - `testABadStrokeDrawsNothing`: each of odd count, empty, 130 values, a point at x = 96 or y = -1, colour 9, width 2 returns false and leaves the canvas equal to `PlazaDrawCanvas()`.
  - `testPackingRoundTripsAndIsSmallForAnEmptyCanvas`: a canvas with three strokes equals `PlazaDrawCanvas(packed: c.packed())`; an empty canvas packs to at most 60 bytes.
  - `testUnpackingRejectsTheWrongSizeAndBadColours`: data one cell short, one cell long, a count of 0, and a colour of 9 each give nil.
  - `testTheSameStrokesMakeTheSameCanvasOnEverySystem`: three fixed strokes (write them in the test), then FNV-1a 64 over `cells` equals a pinned constant. Compute the constant once on the Mac and commit it; the Windows unit-test CI then proves the two systems agree.
  - `testTheBitmapUsesThePaletteCellByCell`: with a 9-colour palette, `bitmap(palette:)` is 96 by 64 and pixel (x, y) equals `palette[cells]` at three sampled cells.
- [ ] **Step 2: Run** `swift test --filter PlazaDrawCanvasTests`: fails to compile.
- [ ] **Step 3: Implement.** Bresenham's line with integer error terms, stamping the brush at every step:
  ```swift
  // brush: cells (x - r ... x + r, y - r ... y + r) with r = (width - 1) / 2, those inside the canvas only
  // line: dx = abs(x1 - x0), dy = -abs(y1 - y0), sx, sy = ±1, err = dx + dy; loop { stamp; if at end break;
  //       e2 = 2 * err; if e2 >= dy { err += dy; x0 += sx }; if e2 <= dx { err += dx; y0 += sy } }
  ```
- [ ] **Step 4: Run** `swift test --filter PlazaDrawCanvasTests`: pass.
- [ ] **Step 5: Commit** `feat(team): add the drawing quiz canvas value`. Open **PR A** (Tasks 1 to 3; no visible change).

### Task 4: The rules as pure functions

**Files:**
- Create: `Sources/PokeTokenBar/Team/Plaza/PlazaDraw.swift`
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaGame.swift` (`PlazaGameKind.draw` and `offered`; `PlazaGameState.draw`; `PlazaGame.accepted`; `PlazaGame.precedes`)
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaGameView.swift` (`PlazaGameMenu.kinds` default becomes `PlazaGameKind.offered`)
- Modify: `Sources/PokeTokenBar/Team/TeamLocalization.swift` (`plazaGameName(.draw)`: "그림 퀴즈"; `plazaGameRules(.draw)`: three lines, drafted here and reviewed in Task 7)
- Test: `Tests/PokeTokenBarTests/PlazaDrawTests.swift`, `PlazaGameTests.swift`

**Interfaces:**
- Produces:
  ```swift
  // PlazaGame.swift
  enum PlazaGameKind { case bomb, draw
      /// What the M menu lists. `.draw` joins it in the last task of the drawing-quiz plan; delete this then.
      static var offered: [PlazaGameKind] { allCases.filter { $0 != .draw } } }
  // PlazaGameState gains: var draw: PlazaDrawState?

  // PlazaDraw.swift
  struct PlazaDrawState: Codable, Hashable, Sendable {
      var order: [String]        // who draws, turn by turn; its count is the number of turns
      var turn: Int              // 0-based; equal to order.count when every turn is done
      var entryAt: Double?       // the drawer opened the word field (the drawer's clock)
      var drawAt: Double?        // the drawer set a word; drawing runs from here (the drawer's clock)
      var letters: Int?          // hint 1, once published
      var initials: String?      // hint 2, once published
      var step: Int              // +1 with every change, whoever makes it
      var scores: [String: Int]
      var last: Result?          // the turn before this one
      struct Result: Codable, Hashable, Sendable { var turn: Int; var drawer: String; var word: String?; var solver: String? }
  }
  enum PlazaDraw {
      static let maxPlayers = 8, maxTurns = 8
      static let wordSeconds: TimeInterval = 20, drawSeconds: TimeInterval = 60, revealSeconds: TimeInterval = 6
      static let refereeSlack: TimeInterval = 10
      static let guessPoints = 10, drawerPoints = 5
      static let maxWordCharacters = 12
      /// The players shuffled once by the seed; twice in a row when there are 4 or fewer.
      static func order(players: [String], seed: UInt64) -> [String]
      /// The word as it is kept (ends trimmed, inner runs of spaces single), or nil when it breaks §3.3.
      static func word(_ raw: String) -> String?
      static func matches(_ line: String, word: String) -> Bool          // §3.4
      static func contains(_ line: String, word: String) -> Bool         // the drawer's own line holds the word
      static func letters(_ word: String) -> Int                         // spaces not counted
      static func initials(_ word: String) -> String                     // "ㅅㄱ"; a non-Hangul letter or digit is "○"; spaces dropped
      static func hints(elapsed: TimeInterval, word: String) -> (letters: Int?, initials: String?)
      // Transitions. Each returns the next state with draw.step + 1, or nil when `s` does not allow it.
      static func opened(_ s: PlazaGameState, by me: String, at t: Double) -> PlazaGameState?
      static func wordSet(_ s: PlazaGameState, by me: String, at t: Double) -> PlazaGameState?
      static func hinted(_ s: PlazaGameState, by me: String, letters: Int?, initials: String?) -> PlazaGameState?
      /// Ends the current turn: the result, the scores, and the next turn whose drawer is in `playing`
      /// (turns of drawers who are not are skipped, once each). With no such turn, or fewer than two in `playing`,
      /// the game ends at `t` (`endedAt`; `winner` is the single top scorer, nil on a tie).
      static func ended(_ s: PlazaGameState, word: String?, solver: String?, playing: Set<String>, at t: Double) -> PlazaGameState
      /// Bounds on a received payload. nil drops the whole game state. A word that fails its bounds is only removed.
      static func accepted(_ d: PlazaDrawState, players: [String]) -> PlazaDrawState?
      /// For `PlazaGame.precedes`: [turn, step, 1 if last?.word != nil else 0]; [-1, -1, -1] for no payload.
      static func keys(_ d: PlazaDrawState?) -> [Double]
      static func ranking(_ s: PlazaGameState) -> [(id: String, score: Int)]   // score descending, then id
  }
  ```

- [ ] **Step 1: Write the failing text-rule tests** in `PlazaDrawTests` (plain `XCTestCase`):
  - `testAWordIsOneToTwelveLettersDigitsAndSpaces`: `word(" 사과 ") == "사과"`, `word("ice  cream") == "ice cream"`, `word("사과2개") == "사과2개"`; nil for `""`, `"   "`, a 13-character word, `"사과!"`, `"🍎"`, a word holding a line break.
  - `testAnAnswerMatchesWhateverItsSpacingCaseOrComposition` (Review Focus 5): against the word `"아이스 크림"`: `"아이스크림"`, `" 아이스  크림!"`, `"아이스크림~~"`, `"\"아이스크림\""` match; the same word written in decomposed jamo (build it with `unicodeScalars` of conjoining jamo) matches; against `"Apple"`: `"apple"`, `"APPLE."` match; `"사과인가"`, `"사과ㅋㅋ"`, `"사 과 요"` do not match `"사과"`; an empty line matches nothing.
  - `testTheDrawersOwnLineIsBlockedOnlyWhenItHoldsTheWord`: `contains("힌트: 사 과!", word: "사과")` true; `contains("과일이야", word: "사과")` false.
  - `testHintsCountLettersAndGiveInitials`: `letters("아이스 크림") == 5`; `initials("사과") == "ㅅㄱ"`; `initials("꽃 2송이") == "ㄲ○ㅅㅇ"`; `initials("TV") == "○○"`; `hints(elapsed: 29.9, word:)` is `(nil, nil)`, at 30 `(2, nil)`, at 45 `(2, "ㅅㄱ")` for `"사과"`.
- [ ] **Step 2: Write the failing transition tests:**
  - `testTheOrderIsEveryPlayerOnceOrTwiceAndTheSameForOneSeed`: 3 players give 6 turns, the second half equal to the first; 5 players give 5; 8 give 8; equal for equal seeds, a permutation of the players; different for at least one of seeds 1...20.
  - `testOnlyTheDrawerOpensAndSetsAndEachStepCounts`: from a started state (turn 0, drawer "b"): `opened(by: "a")` nil; `opened(by: "b", at: 100)` sets `entryAt == 100`, step 1; `wordSet` before `opened` nil; after, `drawAt` set, step 2; `hinted` before `wordSet` nil.
  - `testEndingATurnScoresAndMovesOn`: solved by "c": scores c +10, drawer +5, `last == Result(turn: 0, drawer: "b", word: "사과", solver: "c")`, turn 1, `entryAt`, `drawAt`, hints nil, step +1. Timed out (`solver: nil`): no score. A solver who is not a player scores nobody.
  - `testADrawerWhoIsNotPlayingIsSkippedOnceNotRemoved`: order [a, b, c, a, b, c], ending turn 0 with `playing: ["a", "c"]` gives turn 2; ending turn 2 with everyone playing gives turn 3 and then b draws turn 4.
  - `testTheGameEndsAfterTheLastTurnOrWithFewerThanTwoPlaying`: the last turn's end sets `endedAt`, `turn == order.count`, `winner` the top scorer; a tie gives `winner == nil`; `playing: ["a"]` ends at once.
  - `testAPayloadOutOfBoundsIsRefusedAndABadWordIsOnlyRemoved`: nil for 9 turns, a turn of -1 or above `order.count`, a negative step, a drawer not among the players, a score above `order.count * 10` or below 0, a 20-character `initials`; a `last.word` of 13 characters or holding a control character comes back with `word == nil` and the rest intact.
  - In `PlazaGameTests`: `testADrawStateWithMoreProgressWins` (`merged` picks the higher turn, then the higher step, then the copy whose result has a word; either argument order) and `testACopyWithoutTheDrawPayloadLoses` (a state stripped of `draw`, as an old app relays it, loses to the full one and never replaces it); `testARecruitingGameCarriesNoDrawPayload` (`accepted` refuses it); `testTheMenuDoesNotOfferTheDrawingQuizYet` (`PlazaGameMenu().kinds == [.bomb]`).
- [ ] **Step 3: Run** `swift test --filter "PlazaDrawTests|PlazaGameTests"`: fail.
- [ ] **Step 4: Implement.** Text rules use Swift `String`/`Character` comparison (canonical equivalence is built in) and scalar arithmetic for Hangul; do not call Foundation's normalisation (§5.1). Initial consonant of a precomposed syllable `s` (U+AC00...U+D7A3): index `(s - 0xAC00) / 588` into `"ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ"`; for a decomposed syllable use its first scalar (U+1100...U+1112), same index. Answer cleaning: drop whitespace, drop the characters `. , ! ? ~ … " ' “ ” ‘ ’`, lowercase ASCII letters, then compare whole strings. `PlazaGame.accepted`: with `kind == "draw"` cap players at `PlazaDraw.maxPlayers`, require `draw == nil` while `startsAt == nil`, and pass a present payload through `PlazaDraw.accepted`. `PlazaGame.precedes`: compare `PlazaDraw.keys` right after the rank, before the bomb keys.
- [ ] **Step 5: Run** the same filter: pass. Check `swift test --filter "PlazaGame"` still passes (the bomb game is untouched).
- [ ] **Step 6: Commit** `feat(team): add the drawing quiz rules and state`.

### Task 5: The engine: timers, the drawer, the referee

**Files:**
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaGame.swift` (`PlazaGameEngine`; its private state must stay in this file)
- Test: `Tests/PokeTokenBarTests/PlazaDrawEngineTests.swift`

**Interfaces:**
- Consumes: Task 4.
- Produces (on `PlazaGameEngine`):
  ```swift
  enum PlazaDrawPhase: Equatable, Sendable {
      case countdown(left: TimeInterval)      // locked, before the first turn
      case reveal(left: TimeInterval)         // the last result is showing
      case entry(left: TimeInterval)          // the drawer is choosing a word
      case drawing(left: TimeInterval)
      case over                               // the game ended
  }
  /// nil unless a drawing quiz is running or just ended. Times are counted from when THIS machine learned of the phase.
  func drawPhase(now: Date) -> PlazaDrawPhase?
  var drawer: String? { get }                 // order[turn], nil when none
  var isDrawer: Bool { get }                  // drawer == me and I am playing
  var myWord: String? { get }                 // only on the drawer's machine, only during its turn
  /// The drawer's word. False (keep the field open) when it breaks §3.3 or it is not my entry phase.
  mutating func setWord(_ raw: String, now: Date) -> Bool
  /// A chat line that arrived. Only the drawer's machine acts; true when the line ended the turn.
  mutating func guess(_ line: String, from sender: String, now: Date, playing: Set<String>) -> Bool
  func blocksOwnLine(_ line: String) -> Bool  // I am drawing and the line holds my word
  ```
  `tick(now:present:joins:connected:)` keeps its signature. For a drawing quiz it reads `playing = joins ∩ players` plus me when `joined == state.id`.

Rules to implement (§3.7, §4), each with a test below:
- Host lock for `.draw`: players are the first `PlazaDraw.maxPlayers` of the sorted joiners; `draw = PlazaDrawState(order: PlazaDraw.order(...), turn: 0, step: 0, scores: all 0)`.
- Local clocks only. Keep, per machine, the time it first saw: the lock (`startsAt != nil`), each `(turn)`, each `entryAt`, each `drawAt`. `drawPhase` and every deadline use those. The countdown is 3 s from seeing the lock, not `startsAt` against my clock. No machine counts from a stamp: only players see the board, and a player is in the plaza from the lock.
- The drawer's machine: opens entry when its countdown or its 6 s reveal is over (`PlazaDraw.opened`); `setWord` calls `wordSet` and remembers the word privately; publishes hints when `PlazaDraw.hints` gains one; ends the turn on a matching guess, at 60 s of drawing, or at 20 s of entry with no word (`PlazaDraw.ended`, word nil in that last case).
- It abandons its turn (forgets the word, writes nothing) as soon as the state it knows has another turn or drawer.
- The referee is the smallest id in `playing` other than the drawer. It ends the turn with no word and no solver when the drawer has not been in `present` for 3 s (`PlazaBomb.absenceGrace`), or when `revealSeconds + wordSeconds + drawSeconds + refereeSlack` have passed on its own clock since it first saw the turn.
- Nobody else writes. `leave` for a drawing quiz in countdown or play only sets `joined = nil` (my presence then says I am out; reopening the plaza does not bring me back).
- `connected == false`: write nothing; after `PlazaGame.isolationLimit` set `lostConnection` and `joined = nil`.
- A started drawing quiz whose state has no `draw` (an old app's relay): `drawPhase` is nil and `tick` writes nothing.

- [ ] **Step 1: Write the test room** in `PlazaDrawEngineTests`: a struct holding engines by id, a per-engine clock offset `skew[id]`, sets `gone` and `cutOff`, and `step(_ seconds:)` that advances a shared base time, ticks every live engine with `now = base + skew[id]`, `present`/`joins` from the others' `joined`, and then hands every engine every other engine's state (`learn(_:from:now:)`), as `PlazaGameTests.Plaza` does. A helper `play(turns:)` drives a whole game where each drawer sets `"사과"` and the next player in id order guesses it after 5 s.
- [ ] **Step 2: Write the failing tests:**
  - `testAGameOfThreeRunsSixTurnsAndRanks`: three engines; open, join, lock; `play` to the end; every engine has `endedAt`, the same `scores`, six results seen, `drawPhase == .over`.
  - `testTheSameGameEndsTheSameWithClocksUnderAMinuteApart` (§11): the same script with `skew = ["a": 14, "b": -45, "c": 0]` and host c (clocks 59 s apart; ±45 is refused by the lobby's own clock checks), including a first drawer whose clock is slow; scores and the number of turns equal the unskewed run, and the first drawer opens its word field within 4 s of the lock on the shared base time.
  - `testNoWordInTwentySecondsPassesTheTurn`, `testSixtySecondsOfDrawingEndsWithTheWordShown`, `testHintsArePublishedAtThirtyAndFortyFiveSeconds`.
  - `testAGuessFromSomeoneNotPlayingIsIgnored`: `guess("사과", from: "z", playing: ["a","b","c"])` is false and the turn goes on; the same from the drawer itself is false.
  - `testTheWordStaysOnTheDrawersMachineUntilTheTurnEnds`: while b draws, no other engine's `state` (encoded to JSON) contains `"사과"`, and their `myWord` is nil; after the end, `last.word == "사과"` everywhere.
  - `testADrawerWhoSleptDoesNotEndTheGameForEveryone` (builder check 1): b is `cutOff` during its drawing for 40 s; the referee ends the turn and two more turns pass; b comes back: its state becomes the others', it wrote nothing while cut off, the game is still running.
  - `testTheDrawerAndTheRefereeEndingAtOnceAgree` (builder check 2): both write the same turn's end before hearing each other; after exchange all engines hold one state, and when the drawer's result carries a word that one wins.
  - `testADrawerMissingForAMomentLosesOneTurnNotTheGame` (builder check 4): c is not in `joins` at the end of turn 1 only; c's next turn is skipped, c draws in the second round.
  - `testClosingThePlazaTakesMeOutAndIDoNotComeBack`: `leave` clears `joined`; after "reopening" (ticks continue) `isDrawer` stays false and my turns are skipped.
  - `testACopyWithoutTheDrawPayloadIsNeverPlayedOrRefereed` (builder check 8): an engine that only ever hears the stripped state has `drawPhase == nil` and its `state` never changes by its own tick.
  - `testAnIsolatedMachineWritesNothingAndStepsOut`: `connected: false` for 11 s: no state change, then `joined == nil` and `lostConnection` set.
  - `testEightTurnsWithTheRefereeEveryTimeStayInsideTheGameLife`: 8 players, every drawer `cutOff` at its turn; the game ends with `endedAt` set before `opensAt + PlazaGame.maxLife`.
- [ ] **Step 3: Run** `swift test --filter PlazaDrawEngineTests`: fail.
- [ ] **Step 4: Implement** the rules above in `PlazaGameEngine`, in a section marked `// MARK: - 그림 퀴즈`. The bomb branches stay as they are; guard them with the kind.
- [ ] **Step 5: Run** `swift test --filter "PlazaDraw|PlazaGame"`: pass.
- [ ] **Step 6: Inject four faults, one at a time, and see a test fail for each:** the countdown read from `startsAt` against the local clock; the referee firing without the 10 s slack; `leave` keeping `joined`; `ended` removing a skipped drawer from `order`. Restore each.
- [ ] **Step 7: Commit** `feat(team): run the drawing quiz in the game engine`. Run the plaza filter (Global Constraints). Open **PR B**; its text says the game is not reachable yet.

### Task 6: The panel, and the sheet the user picks from

**Files:**
- Create: `Sources/PokeTokenBar/Team/Plaza/HUD/PlazaDrawPanel.swift` (`PlazaDrawBoard`, `PlazaDrawModel`, `PlazaDrawLayout`, `PlazaDrawPanel`)
- Modify: `Sources/PokeTokenBar/Team/Plaza/HUD/PlazaPanel.swift` (`PlazaPanelID.drawBoard`; `stackOrder`: right after `.roster`; `hiddenInPhotoMode`)
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaDraw.swift` (`static let palette: [PlazaRGBA]`, paper first)
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaWindowController.swift` (the panel in the `hud` list, same place as in `stackOrder`)
- Modify: `Sources/PokeTokenBar/Team/TeamLocalization.swift` (tool labels: "가는 펜", "굵은 펜", "지우개", "모두 지우기", "제시어")
- Test: `Tests/PokeTokenBarTests/PlazaDrawPanelTests.swift`, `PlazaDrawPanelRenderTests+Mac.swift` (list it in `Tests/PokeTokenBarTests/mac-only.txt`), `WindowsPlazaPanelsTests.swift` (the pinned stack and counts)

**Interfaces:**
- Consumes: `PlazaDrawCanvas` (Task 3).
- Produces:
  ```swift
  /// What the panel shows right now; the controller derives it on every game step.
  struct PlazaDrawBoard: Equatable {
      var head: String                 // "그림 퀴즈 3/6 · 그리는 사람 민수"
      var time: String                 // "⏱ 52"
      var cover: String?               // text over an empty canvas (word entry); nil shows the canvas
      enum Foot: Equatable { case tools(word: String), lines([String]) }
      var foot: Foot
      var canDraw: Bool
  }
  enum PlazaDrawLayout: String, CaseIterable, Sendable { case center, top, side }
  @MainActor @Observable final class PlazaDrawModel {
      var board: PlazaDrawBoard?       // nil hides the panel
      var canvas = PlazaDrawCanvas()
      var color = 1                    // 1...8, or 0 for the eraser
      var width = 3                    // 1 or 3; the eraser draws 5 wide
      var layout: PlazaDrawLayout = .center
  }
  @MainActor final class PlazaDrawPanel: PlazaPanel {
      init(model: PlazaDrawModel, pills: PlazaPillsPanel)
      /// A stroke the user just drew on this machine, already applied to `model.canvas`: canvas points, colour, width.
      var onStroke: ((_ points: [Int], _ color: Int, _ width: Int) -> Void)?
      var onClear: (() -> Void)?
      /// The cell under a panel point, nil outside the canvas.
      func cell(at point: CGPoint) -> (x: Int, y: Int)?
      /// A click the HUD reported on this panel (`PlazaWindowController.panelClicked` passes every `.drawBoard` hit here).
      func clicked(_ hit: PlazaPanelHit)
  }
  ```
  Hits: `"color"` with `index` 1...8, `"width"` with `index` 1 or 3, `"erase"`, `"clear"`, `"canvas"` (one stable hit over the whole canvas, so the Mac host takes the press), `"board"` (the plate). Colour, width, erase and clear are handled inside the panel on click through a closure the controller's `panelClicked` calls (`func clicked(_ hit: PlazaPanelHit)`).

Rules:
- **Cell size** is a whole number of device pixels: the largest `n >= 2` such that the panel fits the viewport for the layout; the canvas frame is `96 * n / scale` by `64 * n / scale` points (§6).
- **Drags** use the existing capture path: `scrollerContains(point)` is true over the canvas while `board.canDraw`; `scrollerMouse(.down / .drag / .up, at:)` turns points into cells. A point outside the canvas ends the current stroke; a point back inside starts a new one. Each `.down` and `.drag` applies the segment to `model.canvas` and reports it through `onStroke`.
- The canvas is one `.image(PlazaImage(bitmap: canvas.bitmap(palette:)), frame:)` layer; the hosts enlarge it with nearest sampling. Re-render (`onChange`) at most 30 times a second, with one trailing render after the last change.

- [ ] **Step 1: Write the failing panel tests** (`@MainActor`, `async`), building the panel with a `PlazaHUD` as `PlazaGamePanelTests` does:
  - `testThePanelShowsOnlyWithABoard`: `isVisible` follows `model.board != nil`.
  - `testACellIsAWholeNumberOfDevicePixels`: for viewport sizes 600 by 372 and 960 by 640 and scales 1, 1.25, 1.5 and 2, the canvas layer's frame width times the scale is a multiple of 96 (within 0.001) and at least 192.
  - `testACellUnderThePointerIsTheSameAtEveryWindowSize` (Review Focus 1): at both viewport sizes, the centre of the canvas frame gives cell (48, 32), its top-left corner (0, 0), a point 1 pt outside gives nil; and a stroke begun at one size and continued after `setViewport` to the other draws a connected line between the two cells.
  - `testAPressAndDragDrawAndReport`: with `canDraw`, `hud.handleMouse(.down)` on the canvas then two `.moved` then `.up`: `model.canvas` has non-paper cells along the path, `onStroke` got the points, the events returned true; with `canDraw == false` the canvas is unchanged and `onStroke` silent.
  - `testLeavingTheCanvasEndsTheStrokeAndComingBackStartsANewOne`: down inside, move far outside the panel (as Windows sends on a lost capture: `WinPlazaInputRouter.nowhere` is outside every frame), move back inside at another place, up: no line joins the two inside parts.
  - `testToolClicksChangeTheModel`: clicks on colour 5, thin pen, eraser, clear set `color`, `width`, `color == 0`, and empty the canvas (and call `onClear`).
  - `testOnlyTheDrawerSeesTools`: `foot == .lines` renders no tool hits (`hit` over the foot is `"board"`).
  - In `WindowsPlazaPanelsTests`: update the pinned draw-list count (14 to 15) and the photo-mode shown set (unchanged: the new panel hides in photo mode); `c.hud.panels.map(\.id) == WinPlazaPanels.zOrder` must still hold.
- [ ] **Step 2: Run** `swift test --filter "PlazaDrawPanelTests|WindowsPlazaPanelsTests"`: fail.
- [ ] **Step 3: Implement** the panel for all three layouts: `center` (a large panel in the middle), `top` (under the pills, canvas as wide as the height allows), `side` (against the trailing edge, above the minimap). Plate, stroke and corner as the other panels (`PlazaPanelStyle`; the game card's gold for the head). Start the palette from: paper `#F6F1E3`, then `#2B2233 #D2453B #E8862E #F2C14E #3F9D4B #3B7BD1 #7D4FC2 #8A5A36`.
- [ ] **Step 4: Run** the filter: pass.
- [ ] **Step 5: Write the sheet** in `PlazaDrawPanelRenderTests+Mac`, gated on `PTB_PLAZA_HUD_OUT` like `PlazaPanelRenderTests+Mac.testWritePanelImages` (panel over the plaza map background, other HUD panels drawn too so overlaps show): `testWriteLayoutSheet` writes ONE png holding, for each layout numbered 1, 2, 3: the drawer's view while drawing and a guesser's view with a hint, each at 600 by 372 and at 960 by 640, with a sample drawing on the canvas, plus a strip of the nine palette colours with their numbers. Run it: `PTB_PLAZA_HUD_OUT=<dir outside the repo> swift test --filter PlazaDrawPanelRenderTests`.
- [ ] **Step 6: Measure the redraw cost.** In `PlazaPanelCostTests+Mac` add `testDrawBoardRenderCost`: 200 renders after a canvas change at 960 by 640, scale 2; print the mean. If it is above 2 ms, lower the 30 per second cap and say so in the PR. The Windows figure comes from Task 8's selftest.
- [ ] **Step 7: STOP. Show the sheet to the user** (open it with `open -g`; never steal focus) and ask which layout number and whether the colours and the 96 by 64 size are right. Do not continue on your own choice.
- [ ] **Step 8: Apply the choice:** delete `PlazaDrawLayout` and the two layouts not chosen, fix the palette, re-run the filter, write the chosen layout's two views as the PR's images.
- [ ] **Step 9: Commit** `feat(team): add the drawing quiz panel`.

### Task 7: The plaza plays the game

**Files:**
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaGameView.swift` (`PlazaGameView.board: PlazaDrawBoard?`; the drawing-quiz branches of `make`)
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaWindowController.swift` (model and panel wiring, word entry, guesses, strokes out and in, snapshots, the result title, `panelClicked`)
- Modify: `Sources/PokeTokenBar/Team/TeamLocalization.swift` (every string below)
- Test: `Tests/PokeTokenBarTests/PlazaDrawControllerTests.swift`, `PlazaGamePanelTests.swift` (the ranking card)

**Interfaces:**
- Consumes: Tasks 1 to 6.
- Produces: `PlazaWindowController.showDraw(from:_:)` (real body), `var drawBoard: PlazaDrawBoard?` and `var drawCanvas: PlazaDrawCanvas` for tests.

What each part does:
- **View** (`make`): for a drawing quiz use `engine.drawPhase(now:)`, not the lobby phase. Players get the board (§8 table), the hint line and the big title; teammates who are not playing get only the status line ("그림 퀴즈 진행 중" and the scores) and, at the end, the ranking card (shown to everyone in the plaza while the ended state is kept). The status line lists `PlazaDraw.ranking`. `alive` is the players, so the rings under them and on the minimap are the bomb game's (no holder, nobody out).
- **Invitation** (§3.1): for a drawing quiz the card counts "참가 n/8"; once eight have joined, a teammate who has not joined sees the join button disabled and the line `plazaDrawFull` ("자리가 찼어요").
- **Word entry:** when `drawPhase` is `.entry` and I am the drawer, open the chat field once per turn with `purpose = .quizWord`; if a chat line is being typed, wait until that field closes. `onSubmit` in that purpose calls `stepGame { $0.setWord(raw, now:) }`; false keeps the field open and the hint says why (`plazaDrawWordInvalid`). Enter reopens it while the phase lasts. When the phase ends the field is closed without submitting.
- **Guesses:** `showChat(memberID:text:isLoud:)` shows the line as today, then calls `stepGame { $0.guess(text, from: memberID, now:, playing:) }`. `submitChat` refuses a line for which `game.blocksOwnLine(text)` is true (banner `plazaDrawOwnWordBlocked`, field stays open).
- **Strokes out:** `drawPanel.onStroke` collects points; flush as one `TeamDraw` (`op: .stroke`) when 0.08 s have passed since the last flush, when 64 points are held, and on the stroke's end; consecutive messages of one stroke start at the previous message's last point. `onClear` sends `.clear`. `seq` starts at 0 each turn.
- **Snapshots:** send `op: .snapshot` (base64 of `canvas.packed()`, `seq` = last sent) when a member id appears in `members` that was not there on the last step, or a member's `inPlaza` turns true, and every 10 s while the canvas changed since the last snapshot.
- **Strokes in** (`showDraw`): ignore unless I am playing this game. Accept only from the member whose own presence state (`members[sender]?.game`) has this game's id, `draw.order[draw.turn] == sender`, `draw.drawAt != nil` and `turn == d.turn` (§5.2: do not wait for my next game step). Apply a stroke or clear; a snapshot replaces the canvas when its `cells` is within `TeamDraw.maxCellsBase64` and unpacks, and sets the last seq. Strokes with `seq` at or below the last seq are ignored. The canvas and the seq reset when the game id or the turn changes.
- **Titles:** when `draw.last` changes, flash "정답!" (tone `.win`) or "시간 초과" (tone `.out`) through the existing `gameFlashes`, for players only.
- **Strings** (Korean, in `TeamLocalization`; one reviewer who did not write them reads them once before the PR, as the defect log's 2026-11-25 fortune entry requires): rules (three lines), head, time, "내 차례! 제시어를 정하세요 · N초", "○○님이 제시어를 정하고 있어요 · N초", "그리세요! 제시어는 X · N초", "○○님이 그리는 중 · Enter로 답을 말해요 · N초", hint lines ("힌트는 30초가 남으면 나와요", "힌트 □□□", "힌트 ㅅㄱ"), result lines ("정답은 X · ○○님이 맞혔어요", "○○ +10 · ○○ +5", "정답은 X였어요", "이번 차례는 점수가 없어요", "정답을 알 수 없어요"), "다음은 ○○님 차례 · N초", "그림 퀴즈 진행 중", the ranking card ("그림 퀴즈 결과", "1등 ○○ 35점", "공동 1등"), `plazaDrawWordInvalid`, `plazaDrawOwnWordBlocked`, "연결이 끊겨 빠졌어요" (reuse the bomb game's if it exists).

- [ ] **Step 1: Write the test world** in `PlazaDrawControllerTests`, modelled on `PlazaGameControllerTests`: my real controller plus two bare teammate nodes each driving its own engine, a shared settable clock, helpers `start(order:)` (teammate hosts with a seed that gives the wanted order) and `stepAll()`.
- [ ] **Step 2: Write the failing tests:**
  - `testMyTurnOpensTheWordFieldAndTheWordStartsTheDrawing`: at my turn `chatInput.isOpen` and `purpose == .quizWord`; submitting "사과" closes it, `drawBoard?.canDraw == true`, the foot is `.tools(word: "사과")`, and no teammate's received state contains the word.
  - `testAWordThatBreaksTheRulesKeepsTheFieldOpen`: "사과!" returns false and the hint is `plazaDrawWordInvalid`.
  - `testMyTurnWaitsForAnOpenChatLine` (Review Focus 3): the chat field is open with text when my entry begins; purpose stays `.chat`; after that line is sent the word field opens.
  - `testTheWordFieldClosesAtTheDeadlineWithoutSending` (Review Focus 4): the stub field holds "사" when 20 s pass; the field is closed, no chat line and no word went out, the turn moved on with `last.word == nil`.
  - `testATeammatesRightAnswerEndsMyTurnAndScores`: while I draw, `showChat(memberID: b, text: "사과!")` ends the turn: b +10, me +5, the flash is the "정답!" title.
  - `testICannotSayMyOwnWord`: `submitChat` with "이건 사 과야" sends nothing and shows `plazaDrawOwnWordBlocked`; "과일이야" is sent.
  - `testMyStrokesGoOutInBatchesAndASnapshotFollowsANewcomer`: a drag of 100 points yields stroke messages of at most 64 points whose first point equals the previous message's last; a member appearing in the plaza triggers one snapshot whose unpacked canvas equals mine.
  - `testATeammatesStrokesDrawOnMyCanvasOnlyFromTheDrawer`: strokes from the drawer change `drawCanvas`; the same from another member, with the wrong turn, or before the drawer's presence says `drawAt`, do not.
  - `testTheFirstStrokesAfterTheWordAreNotLost` (builder check 9): deliver the drawer's presence with `drawAt` and a stroke back to back with no game step between; the stroke is drawn.
  - `testASnapshotReplacesTheCanvasAndOldStrokesAreIgnored`; `testAnOversizedOrBrokenSnapshotChangesNothing`.
  - `testATeammateWhoIsNotPlayingSeesNoBoardAndNoDrawing`: with `joined == nil`, `drawBoard == nil`, `showDraw` leaves the canvas empty, the status line reads "그림 퀴즈 진행 중 …", and the ranking card shows at the end.
  - `testAnOverlayOpenedMidStrokeEndsTheStroke` (Review Focus 2): mouse down on the canvas, open the M menu (and, separately, start photo mode), then move and release: the stroke stopped at the last point before the overlay, and a new press after closing draws.
  - `testTheCanvasClearsWhenTheTurnChanges`.
  - `testTheInvitationClosesAtEightPlayers`: with eight members' presence saying yes, my card's join button is disabled and its last line is `plazaDrawFull`; with seven it is enabled.
  - `testPlayersAreRingedDuringTheQuiz`: `scene` marks every player `.alive` and nobody `.holder` while a quiz runs.
  - In `PlazaGamePanelTests`: `testTheRankingCardListsEveryoneAndMarksATie`.
- [ ] **Step 3: Run** `swift test --filter "PlazaDrawControllerTests|PlazaGamePanelTests"`: fail.
- [ ] **Step 4: Implement** the parts above.
- [ ] **Step 5: Run** `swift test --filter "PlazaDraw|PlazaGame|PlazaChat"`: pass.
- [ ] **Step 6: Inject three faults, one at a time, and see a test fail:** the word included in the state at `wordSet`; `showDraw` validating against my own engine state instead of the sender's presence; the stroke batch not restarting at the previous last point. Restore each.
- [ ] **Step 7: Have the strings reviewed** by a fresh reviewer (sonnet) against §3 and the bar "a first-time player understands what to do from the line alone"; apply what it finds.
- [ ] **Step 8: Commit** `feat(team): play the drawing quiz in the plaza`. Run the plaza filter. Open **PR C** with the Task 6 images; its text says the game is still not in the menu.

### Task 8: Into the menu, Windows checks, documents

**Files:**
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaGame.swift` (delete `PlazaGameKind.offered`), `PlazaGameView.swift` (`kinds` back to `allCases`)
- Modify: `Sources/PokeTokenBar/Platform/Windows/WindowsSelftestPlazaPanels.swift` (a board capture and a drag check)
- Modify: `assets/windows/SHOT-LIST.txt`, `assets/windows/SHOTS.txt` (through `scripts/import-windows-shots.sh`), `assets/` (one Mac image), `TEAM.md` (the M row, the version list, the mixed-version line)
- Test: `Tests/PokeTokenBarTests/PlazaGameTests.swift`, `PlazaGameControllerTests.swift`

- [ ] **Step 1: Write the failing tests:** replace `testTheMenuDoesNotOfferTheDrawingQuizYet` with `testTheMenuOffersBothGames` (`PlazaGameMenu().kinds == [.bomb, .draw]`); in `PlazaGameControllerTests`, `testChoosingTheDrawingQuizOpensItForEveryone` (M, down, Space opens a game of kind `"draw"` that the teammate's node sees with the three rule lines on its card).
- [ ] **Step 2: Implement:** delete `offered`.
- [ ] **Step 3: Windows selftest.** In `WindowsSelftestPlazaPanels.swift`: show the board in the drawer's state, send `WM_LBUTTONDOWN`, three `WM_MOUSEMOVE` and `WM_LBUTTONUP` across the canvas as `plaza.clicks` does for buttons, and check `plaza.drawDrag`: the canvas has non-paper cells on the path. Add `expect("draw board", present: [.drawBoard], png: "plaza-draw-quiz.png")`. Report the mean render time of 100 redraws as `plaza.drawCost` (a report, not a budget).
- [ ] **Step 4: Run** `swift test --filter "PlazaGame|PlazaDraw|WindowsMessageParameterScanTests|WindowsSeamScanTests"`: pass. Push; start `windows-app` on the branch (`gh workflow run windows-app.yml --repo likelion-campus/PokeTokenBar --ref <branch> -f level=light -f fast=true`); read `plaza.drawDrag` and `plaza.drawCost` in its log.
- [ ] **Step 5: Documents.** `SHOT-LIST.txt` line `plaza-draw-quiz.png | windows-app | plaza-draw-quiz.png`; `scripts/import-windows-shots.sh <run id>`; a Mac image `assets/screenshot-plaza-draw-quiz.png` from the Task 6 render test; `TEAM.md`: the M row describes the second game (§3 in user words, the numbers, mouse needed, players only see the drawing), the mixed-version line (v2.5.638 to the last version without the game see "앱을 업데이트하면 참가할 수 있어요"; older ones see nothing), both images embedded. `python3 scripts/team_docs_check.py` passes.
- [ ] **Step 6: Run** the plaza filter. **Commit** `feat(team): add the drawing quiz to the plaza minigames`. Open **PR D**.
- [ ] **Step 7: Tell the user what only people can check** (§11): one game on a Mac and a Windows PC together; whether drawing feels right under the mouse; whether 60 seconds and the hint times feel right. Do not release unasked.
