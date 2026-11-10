# Plaza Ditto Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Ditto wanders the team plaza, copies a teammate who stands next to it (same look, name, nature line, name colour), roams as them, and turns back into Ditto when anyone tackles the copy.

**Architecture:** One Mac (the one with the smallest member ID whose plaza window is open, the "host") runs a pure state machine (`PlazaDittoBrain`) on a clock-driven loop. It sends the Ditto's state in its own `TeamPresence`; every other Mac draws that state. The scene draws the Ditto as one extra remote actor under a reserved key, so collision, tall grass, photos and emotes work as they do for teammates. Tackling the copy sends a new emote kind; the host turns the copy back.

**Tech Stack:** Swift 6 (CI: Xcode 16.4 / Swift 6.1.2), SpriteKit, SwiftUI, XCTest, SwiftPM.

**Spec:** `docs/superpowers/specs/2026-11-10-plaza-ditto-design.md` (Korean). Section numbers below (§5.4 etc.) point into it.

## Global Constraints

- Work only in the worktree `/Users/simu/Documents/GitHub/PokeTokenBar/.worktrees/plaza-ditto` (branch `feat/plaza-ditto`). Never touch the main checkout.
- Code must compile with Swift 6.1.2 (CI). Don't use language features newer than Swift 6.1.
- Team UI is Korean only. Korean string literals live only in `Sources/PokeTokenBar/Team/TeamLocalization.swift`; `TeamLocalizationTests` enforces it.
- No protocol version bump. New `TeamPresence`/`TeamEmote` fields are optional and omitted when nil/false. New presence fields use `@LossyOptional`. New `TeamEmoteKind` cases are appended at the end, and `TeamWireTests`' pinned raw-value list is updated.
- Never name a new message, field or type `dittoReveal` (that name belongs to the companion's disguised Ditto news).
- No new image files, and no art drawn in code. Effects reuse `PlazaEmoteArt` art (dust, impact, `!`).
- Received values are treated as chosen by a hostile app and checked on receipt (`docs/reference/defect-log.md` "팀 네트워크 (피어 입력)"). Nodes made from received frames are not made while the scene `isPaused`.
- Numbers from the spec: rest after turning back **180 s**; a copy turns back on its own after **900 s**; the copy first walks to at least **8 tiles** (Manhattan) from the real one; walking step **`PlazaWalker.stepDuration` (0.15 s)**, running step **`PlazaWalker.runStepDuration` (0.075 s)**.
- Ditto name plate: text `L(.ko).plazaDittoName` = "메타몽", fixed colour hex **`0xC9A6FF`**, no title line.
- Found banner: `L(.ko).plazaDecoyFound(nickname:)` = `"\(nickname)님이 메타몽을 찾았어요!"`. No other new banner.
- Reserved scene key: `PlazaDitto.sceneKey = "plaza-ditto"`. A peer whose hello claims this member ID is refused.
- Commits in English, ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Run focused tests with `swift test --filter <TestClass>`; the full suite runs once in Task 7.

## Review Focus

1. **The host leaves while a copy is out.** The next host must carry on from the last state it received, so the copy keeps its tile and look and doesn't vanish or jump. Test: Task 5 `testANewHostCarriesOnTheCopyWhereTheOldHostLeftIt`.
2. **A stale presence arrives after the copy was found.** The tackler already shows Ditto, and a pre-found presence that still says "copy" must not flip it back. Test: Task 6 `testAPresenceFromBeforeTheFindDoesNotBringTheCopyBack`.
3. **Two Macs both think they host for a moment, because their ready lists differ.** Every Mac draws only the smallest-ID sender's state, and a larger-ID Mac that sees a smaller one sending stops sending. Test: Task 5 `testTwoHostsSettleOnTheSmallerID`.
4. **The copied teammate's look changes, or arrives late.** The copy shows that member's current frames, name, colour and nature, and follows a change. Test: Task 5 `testTheCopyFollowsTheRealOnesLookChange`.
5. **The host's plaza window is covered (scene paused).** The Ditto still moves (the loop doesn't depend on scene frames), and no poof nodes are made on a paused scene. Tests: Task 4 `testPoofMakesNoNodesWhilePaused`, and Task 5 `testTheHostMovesTheDittoWithoutSceneFrames`.

---

## File Structure

| File | Responsibility |
|---|---|
| Create `Sources/PokeTokenBar/Team/Plaza/PlazaDitto.swift` | Constants, the wire/display state `PlazaDittoState`, receipt checks, host choice, who can be copied, transitions. Pure. |
| Create `Sources/PokeTokenBar/Team/Plaza/PlazaDittoBrain.swift` | The host's state machine: wandering, copying, fleeing, person-like idling, turning back. Pure, seeded RNG. |
| Modify `Sources/PokeTokenBar/Team/TeamWire.swift` | `TeamPresence.ditto`, `TeamPresence.dittoReady`, `TeamEmoteKind.decoyFound/.decoyJump`, `TeamEmote.overDecoy`. |
| Modify `Sources/PokeTokenBar/Team/TeamSession.swift` | Store received Ditto fields per member, send mine, refuse the reserved ID. |
| Modify `Sources/PokeTokenBar/Team/TeamRuntime.swift` | Route the two new emote kinds and the over-decoy greeting. |
| Modify `Sources/PokeTokenBar/Team/Plaza/PlazaScene.swift` | Draw the Ditto as a reserved-key remote; poof; keep it out of `memberTiles`. |
| Modify `Sources/PokeTokenBar/Team/Plaza/PlazaWindowController.swift` | Host loop, showing the state, frames, minimap dot, tackle/greet/emote/roster/menu behaviour. |
| Modify `Sources/PokeTokenBar/Team/TeamLocalization.swift` | Two strings. |
| Modify `TEAM.md` | A plaza table row and the old-version note. |
| Tests | `PlazaDittoTests`, `PlazaDittoBrainTests`, `PlazaDittoSceneTests`, `PlazaDittoControllerTests` (new); `TeamWireTests`, `TeamSessionTests`, `TeamHostilePeerTests`, `TeamRuntimeTests` (extend). |

---

### Task 1: Ditto rules and state (`PlazaDitto.swift`)

**Files:**
- Create: `Sources/PokeTokenBar/Team/Plaza/PlazaDitto.swift`
- Test: `Tests/PokeTokenBarTests/PlazaDittoTests.swift`

**Interfaces:**
- Produces:
  ```swift
  enum PlazaDitto {
      static let sceneKey = "plaza-ditto"
      static let speciesID = PokemonOdds.dittoSpeciesID          // 132
      static let restDuration: TimeInterval = 180
      static let decoyLimit: TimeInterval = 900
      static let fleeDistance = 8
      static let nameHex: UInt32 = 0xC9A6FF
      static let clockSkew: TimeInterval = 600
      /// Land the Ditto may stand on: walkable, not water, not shelter.
      static func isGround(_ t: TilePoint, in map: PlazaMap) -> Bool
      /// Smallest member ID among the ready ones (me included when `meReady`). nil when nobody is ready.
      static func host(me: String, meReady: Bool, others: [String: Bool]) -> String?
      static func canBeCopied(inPlaza: Bool, ready: Bool, isIdle: Bool, isFocusing: Bool, isEgg: Bool) -> Bool
      /// The member to copy: one of `copyable` on a tile next to `ditto` (isAdjacent). Smallest ID when several.
      static func copyTarget(ditto: TilePoint, copyable: [String: TilePoint]) -> String?
      static func change(from old: PlazaDittoState?, to new: PlazaDittoState?) -> PlazaDittoChange
  }
  struct PlazaDittoState: Codable, Equatable, Sendable {
      var tile: TilePoint
      var facing: PlazaDirection
      var isWalking: Bool?          // nil = false on the wire
      var isRunning: Bool?
      var decoyOf: String?          // member copied; nil = Ditto form
      var since: Date               // when the current form began
      var restUntil: Date?          // Ditto form only: no copying before this
      var isDecoy: Bool { decoyOf != nil }
      func copying(_ memberID: String, now: Date) -> PlazaDittoState      // decoyOf set, since = now, restUntil nil, same tile
      func turnedBack(now: Date) -> PlazaDittoState                       // decoyOf nil, since = now, restUntil = now + 180, not walking
      /// Receipt check without a map: nil when `decoyOf` is over `TeamWire.maxFieldBytes` bytes, `since` is after now + skew,
      /// a copy's `since` is before now − (900 + skew), or `restUntil` is after now + 180 + skew.
      static func accepted(_ s: PlazaDittoState?, now: Date) -> PlazaDittoState?
  }
  enum PlazaDittoChange: Equatable { case none, transformed(TilePoint), turnedBack(TilePoint) }
  ```

- [ ] **Step 1: Write the failing tests** in `PlazaDittoTests`:
  - `testHostIsTheSmallestReadyID`: `host(me: "b", meReady: true, others: ["a": true, "c": true]) == "a"`; with `"a": false`, it is `"b"`; with `meReady: false` and no ready others, it is `nil`.
  - `testOnlyActiveHatchedTeammatesWithTheWindowOpenCanBeCopied`: true only for `(inPlaza: true, ready: true, isIdle: false, isFocusing: false, isEgg: false)`. Flipping any one input gives false (five asserts).
  - `testCopyTargetIsANeighbourNotADiagonal`: Ditto at (10,10). `["x": (11,10)]` gives `"x"`, `["x": (11,11)]` gives nil, and `["b": (10,9), "a": (9,10)]` gives `"a"`.
  - `testGroundExcludesWaterShelterAndTrees`: use the real `PlazaMap` (`PlazaMapData`) and assert one known water tile, one shelter tile and one tree tile are false and one grass tile is true. Pick the coordinates from `PlazaMapData.rows`.
  - `testCopyingAndTurningBack`: `copying("m", now:)` keeps the tile and sets `decoyOf == "m"`, `since == now`, `restUntil == nil`. `turnedBack(now:)` gives `decoyOf == nil` and `restUntil == now + 180`.
  - `testAcceptedDropsHostileStates`:
    - nil for a 65-byte `decoyOf`, for `since = now + 601`, for a copy with `since = now − 1501`, and for `restUntil = now + 781`.
    - kept for a Ditto-form state with `since = now − 86_400` (Ditto may have wandered all day).
  - `testChangeReportsTransformsAndTurnBacks`:
    - Ditto form → copy at (3,4) gives `.transformed((3,4))`.
    - Copy → Ditto form gives `.turnedBack(tile)`.
    - Copy of "a" → copy of "b" gives `.transformed`.
    - Same form, moved tile gives `.none`.
    - nil → anything gives `.none` (a first sighting doesn't poof).
  - `testStateRoundTripsAndOmitsFalseFlags`: encode a Ditto-form state with `isWalking: nil` and check the JSON has no `isWalking`, `decoyOf` or `restUntil` keys. Decoding gives the same value back.
- [ ] **Step 2:** Run `swift test --filter PlazaDittoTests`. Expected: build failure (types missing).
- [ ] **Step 3:** Implement `PlazaDitto.swift` with the interfaces above. `isGround` = `map.isWalkable(t) && !map.isWater(t) && map.tile(at: t) != .shelter` (`PlazaMap.tile(at:)` returns `PlazaTile`).
- [ ] **Step 4:** Run `swift test --filter PlazaDittoTests`. Expected: all pass.
- [ ] **Step 5:** Commit: `feat(team): add the plaza Ditto rules`.

---

### Task 2: The host's brain (`PlazaDittoBrain.swift`)

**Files:**
- Create: `Sources/PokeTokenBar/Team/Plaza/PlazaDittoBrain.swift`
- Test: `Tests/PokeTokenBarTests/PlazaDittoBrainTests.swift`

**Interfaces:**
- Consumes: Task 1 (`PlazaDittoState`, `PlazaDitto.isGround`, `copyTarget`, constants), `PlazaPathfinder`, `PlazaSplitMix64`, `PlazaMap`.
- Produces:
  ```swift
  struct PlazaDittoWorld {
      var map: PlazaMap
      var blocked: Set<TilePoint>              // every character's tile except the Ditto's
      var copyable: [String: TilePoint]        // members (me included) that canBeCopied, with their tiles
      var present: [String: TilePoint]         // every member in the plaza with a tile (to find the real one while copying)
  }
  enum PlazaDittoBrainEvent: Equatable { case transformed(String), turnedBack, jumped }
  struct PlazaDittoBrain {
      private(set) var state: PlazaDittoState
      /// Carry on from `resuming` when it is given and its tile is ground and not blocked; otherwise start in Ditto form on a
      /// random free ground tile, `since = now`, no rest.
      init(resuming: PlazaDittoState?, world: PlazaDittoWorld, now: Date, seed: UInt64)
      /// Advance to `now`. Steps one tile per step duration; may emit events.
      mutating func tick(now: Date, world: PlazaDittoWorld) -> [PlazaDittoBrainEvent]
      /// Someone tackled the copy: turn back where it stands. No-op in Ditto form.
      mutating func found(now: Date)
  }
  ```
- Behaviour (spec §5.1, §5.2, §5.4, §5.5):
  - **Ditto form:**
    - Wait 2–6 s, then walk 1–4 tiles to a random reachable ground tile (`PlazaPathfinder` around `blocked`, never into water or shelter).
    - On every tick when `now ≥ restUntil` (or no rest), check `copyTarget(ditto: state.tile, copyable:)`. A hit sets `state = state.copying(id, now:)`, emits `.transformed(id)`, and starts the flee.
  - **Flee:**
    - Walk to a ground tile at Manhattan distance ≥ 8 from the real one's tile (`present[decoyOf]`), choosing among the reachable ones.
    - If none is reachable, walk as far as possible.
  - **Copy idling** (exact odds are the builder's call, tuned so the copy mostly stands; see the test):
    - Wait 6–20 s between actions.
    - Then either stay and maybe turn, or walk 1–3 tiles. About 1 in 10 walks run.
    - Rarely jump, which emits `.jumped`.
  - **Turning back:**
    - When `now − since ≥ 900`, or `decoyOf` is no longer in `copyable`, set `state = state.turnedBack(now:)` and emit `.turnedBack`.
    - `found(now:)` does the same without emitting.
  - **Each step:**
    - The next tile must not be in `blocked`. If it is, re-plan, or wait one step duration.
    - `state.isWalking` is true while a step is under way. `state.isRunning` is true on running steps.
    - `state.facing` follows the step.
- [ ] **Step 1: Write the failing tests** in `PlazaDittoBrainTests`. Use the real plaza map, a fixed seed, and simulated time stepped every 0.05 s.
  - `testItStartsOnFreeGroundAndNeverStepsOffIt`: put `blocked` around the start. Simulate 600 s with nobody copyable, and assert every observed tile `isGround` and is never in `blocked`.
  - `testItResumesAGivenState`: resuming a valid copy state keeps the tile, `decoyOf` and `since`.
  - `testItCopiesANeighbourOnlyAfterResting`:
    - State is Ditto form with `restUntil = now + 180`, and member "m" is next to it.
    - No `.transformed` before 180 s.
    - `.transformed("m")` within one tick after.
  - `testItDoesNotCopyFromAcrossTheField`: "m" is 5 tiles away and stays put. No copy within 1 s.
  - `testTheCopyGetsAtLeastEightTilesAway`: after copying "m" at a tile beside an open area, within 15 s the copy is at Manhattan ≥ 8 from `present["m"]`.
  - `testTheCopyMostlyStands`: over 600 simulated seconds after the flee, the time with `isWalking == true` is under 30%.
  - `testTheCopyTurnsBackAfterFifteenMinutes`: emits `.turnedBack` once at 900 s (not at 899). Afterwards `restUntil == that time + 180`.
  - `testTheCopyTurnsBackWhenTheRealOneLeaves`: drop "m" from `copyable`. The next tick emits `.turnedBack`.
  - `testFoundTurnsBackAndRests`: `found(now:)` on a copy gives Ditto form at the same tile with `restUntil = now + 180`. On Ditto form, `found` changes nothing.
  - `testItWaitsWhenSomeoneStepsIntoItsPath`: block the next route tile mid-walk. The Ditto never enters it.
- [ ] **Step 2:** Run `swift test --filter PlazaDittoBrainTests`. Expected: build failure.
- [ ] **Step 3:** Implement `PlazaDittoBrain`. The RNG is `PlazaSplitMix64(seed:)`. Keep the route, the wait deadline and the current step's end time as private stored properties.
- [ ] **Step 4:** Run `swift test --filter PlazaDittoBrainTests`. Expected: all pass.
- [ ] **Step 5:** Commit: `feat(team): add the plaza Ditto host brain`.

---

### Task 3: Wire and session

**Files:**
- Modify: `Sources/PokeTokenBar/Team/TeamWire.swift`, `Sources/PokeTokenBar/Team/TeamSession.swift`
- Test: `Tests/PokeTokenBarTests/TeamWireTests.swift`, `TeamSessionTests.swift`, `TeamHostilePeerTests.swift`

**Interfaces:**
- Consumes: Task 1 (`PlazaDittoState`, `PlazaDittoState.accepted`, `PlazaDitto.sceneKey`).
- Produces:
  - `TeamPresence`:
    - `@LossyOptional var ditto: PlazaDittoState?`: the host's Ditto. Omitted unless I host.
    - `@LossyOptional var dittoReady: Bool?`: my plaza window is open and runs the Ditto. Omitted when false.
  - `TeamEmoteKind`: append `case decoyFound` (target = the member copied) and `case decoyJump`. Both have `notifiesTarget == false`.
  - `TeamEmote.overDecoy: Bool?`: a greeting at the copy. Omitted when false.
  - `TeamMemberState.ditto: PlazaDittoState?` and `TeamMemberState.dittoReady: Bool` (default false).
  - `TeamSession.updateDitto(ready: Bool, state: PlazaDittoState?)`: broadcasts presence only when either value changed.
  - `TeamSession.sendEmote(..., overDecoy: Bool = false)`: a new trailing parameter. It sets `overDecoy: true` only when true.
- [ ] **Step 1: Write the failing tests:**
  - `TeamWireTests`:
    - Update the pinned `TeamEmoteKind` list to end with `"pickup", "firework", "decoyFound", "decoyJump"`.
    - `testDittoFieldsAreOptionalOnTheWire`: a presence without them encodes with no `ditto`/`dittoReady` keys, and one with them round-trips.
    - `testUnreadableDittoDropsOnlyTheDitto`: a presence frame whose `ditto` is `{"tile": "x"}` decodes with `ditto == nil` and every other field intact.
    - `testOverDecoyIsOmittedWhenFalse`.
  - `TeamSessionTests`:
    - `testPresenceCarriesMyDittoAndReadiness`: after `updateDitto(ready: true, state: s)` the peer's last presence has both. After `updateDitto(ready: false, state: nil)` it has neither.
    - `testUpdateDittoSendsOnlyOnChange`.
    - `testReceivedDittoIsKeptOnTheMember`.
    - `testAHelloClaimingTheDittoKeyIsRefused`: hello `memberID == "plaza-ditto"` → link refused, no member added.
  - `TeamHostilePeerTests`:
    - `testHostileDittoStatesAreDropped`: covers `decoyOf` of 10,000 bytes, `since` a year ahead, and `restUntil` a year ahead. Each gives `members[id]?.ditto == nil`, and the rest of the presence still applies.
- [ ] **Step 2:** Run `swift test --filter TeamWireTests`, then `TeamSessionTests`, then `TeamHostilePeerTests`. Expected: build failure or the new tests fail.
- [ ] **Step 3:** Implement:
  - The receive path sets `member.ditto = PlazaDittoState.accepted(presence.ditto, now: clock())` and `member.dittoReady = presence.dittoReady ?? false`.
  - `makePresence` writes `dittoReady: ready ? true : nil`.
  - `receiveHello` refuses `PlazaDitto.sceneKey`, the same way as its own-ID check.
- [ ] **Step 4:** Run the three filters again. Expected: all pass.
- [ ] **Step 5:** Commit: `feat(team): carry the plaza Ditto on presence`.

---

### Task 4: Drawing the Ditto in the scene

**Files:**
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaScene.swift`
- Test: `Tests/PokeTokenBarTests/PlazaDittoSceneTests.swift`

**Interfaces:**
- Consumes: `PlazaDitto.sceneKey`.
- Produces:
  ```swift
  struct PlazaDittoShown: Equatable {
      var tile: TilePoint; var facing: PlazaDirection; var isWalking: Bool; var isRunning: Bool
      var name: String; var nameColor: CGColor; var title: String?; var isDecoy: Bool
  }
  extension PlazaScene {
      /// nil removes it. Creates/updates one `Remote` under `PlazaDitto.sceneKey` (not away, no wanderer).
      func applyDitto(_ shown: PlazaDittoShown?)
      var dittoTile: TilePoint? { get }   // where it stands, either form
      var decoyTile: TilePoint? { get }   // only while it is a copy
      /// Dust puffs around the Ditto's feet (reuse `PlazaEmoteArt.dustImage`). Nothing while `isPaused` or with no Ditto.
      func playDittoPoof()
  }
  ```
  Frames come through the existing `setMemberFrames(PlazaDitto.sceneKey, frames)`. Jumps and bubbles come through the existing `playJump(memberID:)` and `showEmote(memberID:kind:)` with the key.
- Rules:
  - `applyMembers` never removes the Ditto remote.
  - `memberTiles` leaves the Ditto out. `occupiedTiles` keeps it in, which happens automatically because it is a remote.
  - `photoInput()` includes it, also automatically.
  - Moving by more than one tile at once (a host change) snaps, like `PlazaRemoteMotion.snap`.
- [ ] **Step 1: Write the failing tests** in `PlazaDittoSceneTests`. Build the scene the way `PlazaTallGrassSceneTests` or `PlazaPondSceneTests` do.
  - `testApplyDittoShowsAndRemovesIt`: after `applyDitto(shown)`, `memberName(PlazaDitto.sceneKey) == "메타몽"`. After `applyDitto(nil)` it is nil.
  - `testMembersUpdateLeavesTheDittoAlone`: `applyMembers([])` after `applyDitto` keeps it.
  - `testTheDittoIsNotAMemberTargetButBlocksItsTile`: `memberTiles` has no key, and `occupiedTiles()` contains `dittoTile`.
  - `testDecoyTileOnlyWhileACopy`.
  - `testTheCopyShowsTheGivenNameColourAndTitle`: name "재헌", the colour, title "천진난만한" are visible through `memberName`/`memberNameColor` and the actor's `title`.
  - `testThePhotoIncludesTheDitto`: `photoInput()!.actors.count` is one more than without it.
  - `testPoofMakesNoNodesWhilePaused`: with `isPaused = true`, `playDittoPoof()` leaves `dustCount == 0`. Unpaused, it is > 0.
- [ ] **Step 2:** Run `swift test --filter PlazaDittoSceneTests`. Expected: build failure.
- [ ] **Step 3:** Implement in `PlazaScene.swift`, next to `applyMembers`.
- [ ] **Step 4:** Run `swift test --filter PlazaDittoSceneTests`, plus `PlazaMembersTests` and `PlazaTargetingTests` for regressions. Expected: all pass.
- [ ] **Step 5:** Commit: `feat(team): draw the plaza Ditto`.

---

### Task 5: Hosting and showing the Ditto (controller)

**Files:**
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaWindowController.swift`, `Sources/PokeTokenBar/Team/TeamLocalization.swift`
- Test: `Tests/PokeTokenBarTests/PlazaDittoControllerTests.swift`. Use the harness in `PlazaMembersTests` (`controller(_:fetcher:)` with loopback nodes), copying what's needed.

**Interfaces:**
- Consumes: Tasks 1–4. Also `session.updateDitto`, `startMemberLoad(_:subject:)` / `loadMemberFrames` (keyed by id), `refreshMinimap`, `scene.walkingToMember`, `followingMember` and `stopWalkingToMember()`.
- Produces (used by Task 6):
  ```swift
  // PlazaWindowController
  private(set) var shownDitto: PlazaDittoState?       // what this Mac shows now
  var isDittoHost: Bool { get }
  func advanceDitto(now: Date)                         // one step of the loop; the loop calls it every 0.05 s
  private func showDitto(_ state: PlazaDittoState?, change: PlazaDittoChange)   // scene + frames + minimap + poof
  var dittoLoopSleep: @MainActor (Duration) async -> Void   // init-injected like `bannerSleep`, for tests
  ```
  `TeamLocalization`: `var plazaDittoName: String { "메타몽" }`.
- Behaviour:
  - **Readiness:**
    - On `show()`, start a `Task` loop (like `focusTick`). It sleeps through `dittoLoopSleep(.milliseconds(50))` and calls `advanceDitto(now: clock())`.
    - Call `session.updateDitto(ready: true, state:)` while the window is open.
    - On close, cancel the loop, drop the brain and `shownDitto`, and call `updateDitto(ready: false, state: nil)`.
  - **Host choice:**
    - `others` is every member with `inPlaza && (dittoReady || ditto != nil)`.
    - I host when `PlazaDitto.host(me:meReady: true, others:)` is my ID.
    - While hosting, if any member with a smaller ID has `ditto != nil`, stop hosting at once.
  - **Hosting:**
    - On becoming host, build `PlazaDittoBrain(resuming: shownDitto, ...)` with a random seed.
    - Each step, build `PlazaDittoWorld`:
      - `blocked` = `scene.occupiedTiles(except: PlazaDitto.sceneKey) ∪ {my tile}`.
      - `copyable` = members and me passing `canBeCopied`. For me, use `isIdle = session.isIdle`, `isFocusing = isFocusing`, and `isEgg = character.speciesID == nil` (an egg is a `TeamMonSummary` without a species, for members and for me).
      - `present` = members in the plaza with tiles, plus me.
    - `tick`, then `session.updateDitto(ready: true, state: brain.state)`, then show it.
    - Handle `.jumped` in Task 6.
  - **Not hosting:**
    - Show `members[host]?.ditto` when present. Otherwise keep `shownDitto` as it is (frozen).
    - Call `updateDitto(ready: true, state: nil)`.
  - **Showing:**
    - Drop a state whose tile is not `PlazaDitto.isGround`.
    - Ditto form is named `plazaDittoName`, coloured `PlazaDitto.nameHex`, with no title, and loads subject `(speciesID: 132, isShiny: false, form: nil)` under `PlazaDitto.sceneKey`.
    - A copy of member X uses X's nickname (no zZ), `PlazaNameColor.color(forMemberID: X, chosen: X.nameColor)`, `X.character.nature` title, and X's subject. When X is me, use my own nickname, colour, nature and subject.
    - Reload frames only when the subject changes.
    - On `.transformed` or `.turnedBack`, call `scene.playDittoPoof()`.
    - On `.transformed(X)`: if `scene.walkingToMember == X`, call `stopWalkingToMember()`. This covers following too.
    - On `.turnedBack`: if `followingMember == PlazaDitto.sceneKey`, stop.
  - **Minimap:** while a copy, add a dot `id: PlazaDitto.sceneKey`, tile, X's colour, `isMe: false`, `isAway: false`. Ditto form gets no dot.
  - **Members-subject cleanup:** in `applyMembersToScene`, skip `PlazaDitto.sceneKey` (it isn't in `members`).
- [ ] **Step 1: Write the failing tests** in `PlazaDittoControllerTests`. Drive time by calling `advanceDitto(now:)` directly with a fake clock.
  - `testOpeningTheWindowMakesMeReadyAndClosingClearsIt`.
  - `testTheSmallestReadyIDHosts`: with members "a"(ready) and me "b", I don't host. With "c" instead, I host and my presence carries `ditto`.
  - `testANonHostShowsTheHostsDitto`: a member presence with `ditto` at (20,20) leads to `scene.dittoTile == (20,20)`.
  - `testTwoHostsSettleOnTheSmallerID` (Review Focus 3).
  - `testANewHostCarriesOnTheCopyWhereTheOldHostLeftIt` (Review Focus 1): host "a" shows a copy of "m" at (20,20) and then leaves. I become host and my first sent `ditto` has the same `decoyOf`, `since` and tile.
  - `testTheHostMovesTheDittoWithoutSceneFrames` (Review Focus 5): with the scene paused and no `update(_:)` calls, repeated `advanceDitto` moves the brain's tile.
  - `testACopyLooksLikeTheRealOne`: name, colour and title match member "m". The minimap has two dots with m's colour.
  - `testTheCopyFollowsTheRealOnesLookChange` (Review Focus 4): "m" changes nature or colour in presence, and the copy's plate follows. A species change starts a frame load under the Ditto key.
  - `testDittoFormHasNoMinimapDot`.
  - `testTransformStopsMyWalkToTheCopiedMember`.
  - `testAStateOffTheGroundIsIgnored`: a received `ditto` on a water tile is not shown.
- [ ] **Step 2:** Run `swift test --filter PlazaDittoControllerTests`. Expected: build failure.
- [ ] **Step 3:** Implement in `PlazaWindowController.swift`. Add the init parameter `dittoLoopSleep` with the same default as `bannerSleep`.
- [ ] **Step 4:** Run `swift test --filter PlazaDittoControllerTests`, then `PlazaMembersTests` and `PlazaWindowTests`. Expected: all pass.
- [ ] **Step 5:** Commit: `feat(team): host and show the plaza Ditto`.

---

### Task 6: Finding the copy, and the other interactions

**Files:**
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaWindowController.swift`, `Sources/PokeTokenBar/Team/TeamRuntime.swift`, `Sources/PokeTokenBar/Team/TeamLocalization.swift`, `TEAM.md`
- Test: `PlazaDittoControllerTests.swift` (extend), `TeamRuntimeTests.swift` (extend)

**Interfaces:**
- Consumes: Task 5's `shownDitto`, `isDittoHost`, and the brain's `found(now:)` and `.jumped`. Task 3's emote kinds and `overDecoy`.
- Produces:
  ```swift
  // PlazaWindowController (called by TeamRuntime)
  func showDecoyFound(from memberID: String, copied: String?)
  func showDecoyJump(from memberID: String)
  func showEmote(memberID: String, kind: TeamEmoteKind, alsoOver other: String? = nil, overDecoy: Bool = false)
  ```
  `TeamLocalization`: `func plazaDecoyFound(nickname: String) -> String { "\(nickname)님이 메타몽을 찾았어요!" }`.
- Behaviour (spec §5.5, §5.7):
  - **Targets:**
    - `handleInteractKey`, `faceNearbyMember` (C) and `handleEmoteKey` target `scene.memberTiles` plus `[PlazaDitto.sceneKey: scene.decoyTile]` while a copy is shown.
    - Ditto form is never a target, so Space and C do nothing on it.
  - **Space on the copy:**
    - Open the copied member's menu (nickname and colour of X) with `memberID = PlazaDitto.sceneKey`. Apply the same focus, water and diving action filters as the real member. If X is me, drop `.viewCard`.
    - The `chooseMenu` results for the key:
      - **greet:** bubble over me and over the copy, then `sendEmote(kind, target: nil, overDecoy: true)`.
      - **tackle:** find the copy (below).
      - **follow:** `scene.follow(member: PlazaDitto.sceneKey)`.
      - **viewCard:** X's card.
  - **Finding (my tackle on the copy):**
    - Guards are the same as `tackle(_:)`: not focusing, not diving, the emote interval.
    - Then: `scene.playTackle(by: nil, on: key, ...)`, `sendEmote(.decoyFound, target: X)`, `showDecoyFound(from: myID, copied: X)`.
    - The copied person may do this too.
  - **`showDecoyFound(from:copied:)`:**
    - Ignore it unless `shownDitto?.decoyOf == copied` and this copy's `since` hasn't already been found. Remember the found `since`.
    - Show `.exclaim` over the key, then `playDittoPoof()`.
    - Show the banner `plazaDecoyFound(nickname:)` with the sender's nickname (mine when it's me).
    - Show `shownDitto.turnedBack(now:)` at once.
    - If I host, call `brain.found(now:)`.
    - From then on, ignore a received copy state with that `since` (Review Focus 2).
  - **Jumps:**
    - On the host, `.jumped` → `scene.playJump(memberID: key)` and `sendEmote(.decoyJump, target: nil)`.
    - `showDecoyJump(from:)` jumps the copy only when `from` is the current host and a copy is shown.
  - **Emote keys 1–3:** when the target is the key, send with `target: nil`.
  - **Roster click (`walkToMember`):** when `shownDitto?.decoyOf == id`, don't walk. Instead do what key 5 does: `?` over me plus send `.question`, respecting `emoteInterval`.
  - **`TeamRuntime.onEmote`:**
    - `.decoyFound` → `plaza?.showDecoyFound(from:copied: emote.targetMemberID)`, then return.
    - `.decoyJump` → `plaza?.showDecoyJump(from:)`, then return.
    - Otherwise pass `overDecoy: emote.overDecoy == true` to `showEmote`. When `overDecoy` is true, skip the `emoteToMe` notification.
  - **`TEAM.md`:**
    - Add a plaza-table row "메타몽" describing §5.1–5.7 in the table's style: wandering, copying a neighbour, the copy looks identical, tackling reveals it with the banner, 3-minute rest, 15-minute limit, and the roster `?`.
    - Add the note that v2.5.621 and earlier don't see it.
- [ ] **Step 1: Write the failing tests.**
  - `PlazaDittoControllerTests`:
    - `testTacklingTheCopyRevealsItForEveryone`: my C on the adjacent copy sends `.decoyFound` with target "m". My scene shows Ditto form at that tile, and the banner is "재헌님이 메타몽을 찾았어요!" when my nickname is 재헌.
    - `testTheCopiedPersonCanTackleTheirOwnCopy`.
    - `testTacklingTheRealOneStillPushes`: sends `.tackle` with target "m", not `.decoyFound`.
    - `testAReceivedFindShowsTheBannerOnce`: two `.decoyFound` for the same copy give one banner.
    - `testAFindWithNoCopyIsIgnored`.
    - `testAPresenceFromBeforeTheFindDoesNotBringTheCopyBack` (Review Focus 2).
    - `testTheHostTurnsBackOnAReceivedFind`: the next sent `ditto` has `decoyOf == nil` and `restUntil ≈ now + 180`.
    - `testGreetingTheCopyLooksLikeGreetingTheRealOne`: bubbles over me and over the key. The sent emote has `targetMemberID == nil` and `overDecoy == true`.
    - `testHeartAtTheCopyHasNoTarget`.
    - `testClickingTheCopiedMemberInTheRosterAsksInsteadOfWalking`: `walkToMember("m")` → `scene.walkingToMember == nil`, `shownEmote(memberID: nil) == .question`, and a `.question` emote is sent.
    - `testClickingAnotherMemberStillWalks`.
    - `testSpaceAndTackleDoNothingOnDittoForm`.
    - `testADecoyJumpFromANonHostIsIgnored`.
  - `TeamRuntimeTests`:
    - `testAGreetingAtTheCopyDoesNotNotifyTheRealOne`: an emote `{heart, target nil, overDecoy true}` gives no `emoteToMe`.
    - `testDecoyKindsReachThePlaza`.
- [ ] **Step 2:** Run `swift test --filter PlazaDittoControllerTests`, then `TeamRuntimeTests`. Expected: the new tests fail.
- [ ] **Step 3:** Implement as above.
- [ ] **Step 4:** Run both filters, then `PlazaEmoteTests`, `PlazaTackleReachTests`, `PlazaRosterTests`, `PlazaCardTests` and `TeamLocalizationTests`. Expected: all pass.
- [ ] **Step 5:** Commit: `feat(team): find the plaza Ditto's copy by tackling it`.

---

### Task 7: Whole-branch verification and PR images (controller session, not a subagent)

- [ ] **Step 1:** Run `swift test 2>&1 | tail -30`. Expected: 0 failures.
- [ ] **Step 2: Fault injection.** Put each fault in by hand, run the owning filter, see it fail, then revert. Record the results in the PR body.
  1. `host` picks the largest ID.
  2. `canBeCopied` ignores `isIdle`.
  3. `copyTarget` accepts diagonals.
  4. `accepted` keeps a future `since`.
  5. The brain skips the rest check.
  6. `memberTiles` includes the Ditto.
  7. `showDecoyFound` doesn't dedupe.
  8. A greeting at the copy carries the real target.
  9. The roster click walks anyway.
  10. Session doesn't refuse the reserved ID.
- [ ] **Step 3: llvm-cov.** Check `PlazaDitto.swift`, `PlazaDittoBrain.swift` and the new controller code for `^0` (`swift test --enable-code-coverage`, then `xcrun llvm-cov show ... --show-regions`). Cover or justify each one.
- [ ] **Step 4: Offscreen renders.** Use a temporary env-gated XCTest with `SKRenderer`; don't commit it. See memory "offscreen-plaza-render". Render:
  - the Ditto wandering;
  - the real one and the copy side by side;
  - the transform and found poofs (GIF);
  - the copy's movement (GIF);
  - the P photo.
  Upload them to the team gist and embed them as "Sample-data render".
- [ ] **Step 5:** Merge `origin/main`, then prepare the PR with the `prepare-pr` skill and `scripts/check-pr.py --ui-changes`.
