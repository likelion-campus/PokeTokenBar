# Plaza Ditto Mimic Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a teammate's plaza Pokémon is a Ditto, their tackle turns them into the teammate they hit (look, name, name colour, nature line), for up to 5 minutes, until someone tackles or snowballs them and the banner gives them away.

**Architecture:** The disguise is one new optional presence field, `TeamPresence.mimicOf`: the ID of the member whose real look the sender shows. Each receiving Mac checks it with a pure rule (`PlazaMimic.shownTarget`) and draws the sender with that member's look, taken from that member's own presence, never from a drawn disguise. A Ditto's tackle is a new emote kind, `.mimicTackle`, so nobody is pushed and earlier versions skip it. The disguised Mac decides its own reveal and sends `.mimicFound` before it drops the field. Expiry needs no scene frames: the controller's existing 1 s focus tick ends my disguise and redraws teammates' expired ones.

**Tech Stack:** Swift 6 (CI: macos-15, Xcode 16), SpriteKit, SwiftUI, XCTest, SwiftPM.

**Spec:** `docs/superpowers/specs/2026-11-12-plaza-ditto-mimic-design.md` (Korean). Section numbers below (§4.5 etc.) point into it.

## Global Constraints

- Work only in `/Users/simu/Documents/GitHub/PokeTokenBar/.worktrees/ditto-mimic` (branch `feat/plaza-ditto-mimic`). Never edit the main checkout or other worktrees.
- Code must compile with the CI toolchain (macos-15, Xcode 16, Swift 6.1). Use no newer language features.
- Run only one swift build or test process on this Mac at a time (memory is tight). Before every run, `pgrep -fl "swift-build|swift-test|xctest"` must print nothing.
- Every run is focused (`swift test --filter '<Class>|<Class>'`). Never run the full suite: it runs only in the release gate (lean flow).
- Tests never steal keyboard focus. That rules out window `show()`, `NSApp.activate`, `finishLaunching`, run loops and event pumping. Build controllers with `prepareScene()` and drive scenes with `update(_:)`.
- Commits are English Conventional Commits whose message ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Don't push.
- Team UI is Korean only. Korean string literals live only in `Sources/PokeTokenBar/Team/TeamLocalization.swift`; `TeamLocalizationTests` enforces this.
- Wire rules:
  - No protocol version bump.
  - The new presence field is `@LossyOptional var mimicOf: String?`. It is left out when nil, so older versions decode everything they decode today.
  - `TeamEmoteKind.mimicTackle` and then `.mimicFound` are appended last. Update the pinned kind list in `TeamWireTests`.
  - Never name anything `dittoReveal`. The guest Ditto keeps `decoy*`; the teammate's disguise is `mimic*`.
- The mimic never changes `CompanionState`, the feed and its events, or `PlazaPreferences`. Reopening the plaza starts undisguised (§4.3).
- No new art and no poof. The gesture and star come from `playTackle`, and the reveal shows the existing `.exclaim` bubble.
- No new timer. Expiry and the remaining-time hint run on the controller's existing 1 s focus tick (`startFocusTick`), which keeps running while the scene is paused.
- Treat every received value as chosen by a hostile app (`docs/reference/defect-log.md` "팀 네트워크 (피어 입력)"):
  - `mimicOf` longer than `TeamWire.maxFieldBytes` (64 bytes) is dropped on receipt.
  - The sender is drawn disguised only when it is a Ditto in the plaza and `mimicOf` names someone else in the plaza.
  - A receiver never trusts a sender's clock.
- Values from the spec:
  - Ditto is `PlazaDitto.speciesID` (132) as the plaza character's species (§3).
  - A disguise lasts `PlazaMimic.duration = 300` s from its start or its last switch (§4.2, §4.3).
  - The found banner is `"\(finder)님이 \(owner)의 메타몽을 찾았어요!"`, with real nicknames (§4.4).
  - The hint is `"\(nickname + 로/으로) 변신 중 · m:ss"`, e.g. `지아로 변신 중 · 4:12` (§5.2).

## Review Focus

1. **The window is covered when the 5 minutes run out.** The scene is paused and draws no frames. My disguise must still end at 300 s, and my presence must drop `mimicOf`. A covered receiver must still draw the sender as themselves at 305 s. Tests: Task 5 `testFiveMinutesEndMyDisguiseWhileTheWindowIsCovered` and Task 4 `testACoveredWindowStillDropsADisguiseAfterItsTime`.
2. **The copied member leaves** (closes the plaza or disconnects). My Mac ends my disguise on that members update without waiting for a tick. Every receiver draws me as myself at once, before my release arrives. Tests: Task 5 `testTheCopiedMemberLeavingEndsMyDisguise` and Task 4 `testADisguiseOfAMemberWhoLeftIsDrawnAsTheSender`.
3. **Two Dittos (§4.5).**
   - Ditto A tackles disguised Ditto B: B is revealed and A changes nothing.
   - A tackles undisguised B: A shows B's real look (a Ditto named B) and keeps it after B disguises as C.
   - Receivers draw A as B's real look, never as C.
   - Tests: Task 5 `testTacklingADisguisedDittoLeavesMeAsIAm` and `testCopyingAnUndisguisedDittoTakesItsRealLook`, Task 4 `testACopyOfACopierShowsTheirRealLook`, Task 6 `testADittosTackleRevealsADisguisedMe`.
4. **An older-version teammate tackles a disguised me.** They see a plain Ditto and send an ordinary `.tackle` with a push. I'm revealed, not pushed. New-version teammates see the banner naming them; the older one sees only the star, as with a focusing teammate. Test: Task 6 `testAnOlderVersionsTackleRevealsMeAndDoesNotPush` (in `TeamRuntimeTests`, through the runtime).
5. **A hostile presence value:** a non-Ditto sender, a target not in the plaza, the sender itself, or an over-long or non-string value. The sender is drawn as themselves and the rest of the presence still applies. Tests:
   - Task 1: `testAnOverlongMimicIsDropped`, `testUnreadableMimicDropsOnlyTheMimic`.
   - Task 2: `testShownTargetDropsHostileValues`.
   - Task 4: `testHostileMimicValuesDrawTheSenderAsThemselves`.

## Builder decisions (§9 and the brief, settled here)

- **Field name:** `TeamPresence.mimicOf`, one member ID (§4.5, §7). There is no timestamp field.
- **Announcing:**
  - The disguise, the switch and every release (re-tackle, 5 min, the target leaving, no longer a Ditto, closing the window) are the presence field alone.
  - A tackle that causes one also sends `.mimicTackle` first, which carries the gesture.
  - The reveal sends `.mimicFound` (target = the finder) *before* the presence that drops the field. A receiver accepts it only while it draws the sender disguised: it shows `!` over the sender and the banner. Older versions skip both kinds.
- **The Ditto's tackle kind:** `.mimicTackle` (target = the member hit). Every tackle by a Ditto teammate on a member uses it: disguise, switch, release, or no change. Receivers draw the lunge and star and never push (§4.1, §4.2). A Ditto's tackle on the guest Ditto (form or copy) keeps today's `.tackle` / `.decoyFound` path (§4.1).
- **Receiver expiry:**
  - The session stamps `TeamMemberState.mimicSeenAt` with its own clock when a new `mimicOf` value arrives. A repeat of the same value keeps the stamp.
  - The sender is drawn as themselves once `duration + receiverGrace` (300 + 5 s) have passed.
  - Only the receiver's clock is read, so there is no skew to allow for. The 5 s cover the sender's 1 s tick and delivery.
- **The remaining-time hint** is read in `refreshHint()`. The existing 1 s focus tick already calls it, through `refreshCampfire()`.
- **The guest Ditto copying a disguised member** draws that member's real look: a Ditto with their name, colour and nature. `showDitto` already reads `members` and `nickname()`/`subject()`, never the drawn look, so a disguise can't feed back into the copy (§5.2: no stall or loop). No code change; a test pins it.
- **Hint priority:** the mimic hint comes after the focus, follow and diving hints and above the startle and Space hints.
- **What a disguise does not copy:** the zZ follows the disguised member's own idle state. Evolution stage, speed, dive limit, my roster entry and my own minimap dot stay mine.
- **The reveal rule:**
  - A tackle (`.tackle` or `.mimicTackle`) reveals me only from beside me or my tile, the same rule as a push. A snowball reveals me when it lands, under its in-line rule.
  - The reveal ignores `canBePushed`, because it moves nobody.
  - The guest copy's prank tackle never reveals me (§4.4).
- **Names that would give the disguise away use the copied name:** the Space hint, the follow, pull and startle hints, and the Space menu. The menu passes the resolved hex (`PlazaNameColor.hex(forMemberID: X, chosen: …)`), so it shows X's colour whatever `memberID` the menu has.
- **Names that stay real:** the chat log (name and colour), banners other than the reveal, the roster, cards and notifications (§2).
- **A menu opened on a disguised member** remembers who it showed. Choosing after that changes does nothing (defect-log "낡은 메뉴 검사").

## Spec notes found while planning (reported, not changed)

- §4.5 vs §4.2: if A already copies B and tackles B while B is disguised, §4.2 says "release" and §4.5 says "reveal first, A doesn't change". This plan does the reveal only, so A keeps copying B.
- §5.1's "그 팀원에게 걸어가던 중" doesn't say whether "그 팀원" is X, the disguised Ditto, or both. This plan stops a walk or follow to either, matching the roster rule's "X나 변신한 팀원".
- §4.4 doesn't say whether a tackle from afar reveals. One from afar happens when the menu was opened and then the target walked off. This plan uses the push's beside-or-same-tile rule.
- §5.2 doesn't place the remaining-time hint among the other hints. The priority above is this plan's choice.
- An existing bug, unrelated and left alone: the guest copy's Space menu passes the copied member's *chosen* colour with `memberID = "plaza-ditto"`. `PlazaMemberMenuView` resolves the colour with `menu.memberID`, so when that member never picked a colour, the menu name shows the Ditto key's colour instead of theirs (`handleInteractKey`, the `members[$0]` branch).

---

## File Structure

| File | Responsibility |
|---|---|
| Create `Sources/PokeTokenBar/Team/Plaza/PlazaMimic.swift` | Constants, `PlazaMimicLook`, tackle / expiry / receiver rules. Pure. |
| Modify `Sources/PokeTokenBar/Team/TeamWire.swift`, `TeamSession.swift` | `mimicOf`, the two kinds, member state, `updateMimic`. |
| Modify `Plaza/PlazaEmoteArt.swift`, `TeamLocalization.swift` | Exhaustive switches; hint and banner copy. |
| Modify `Plaza/PlazaScene.swift`, `Plaza/PlazaActor.swift` | My name plate under a disguise. |
| Modify `Plaza/PlazaWindowController.swift` | Drawing teammates' disguises, my disguise, the reveal, roster, menu, hints. |
| Modify `TeamRuntime.swift`, `TEAM.md` | Routing the two kinds; user docs. |

Tests go in `Tests/PokeTokenBarTests/`. The new classes are `PlazaMimicTests`, `PlazaMimicSceneTests` and `PlazaMimicControllerTests`.

---

### Task 1: The mimic on the wire

**Files:**
- Modify: `Sources/PokeTokenBar/Team/TeamWire.swift`, `Sources/PokeTokenBar/Team/TeamSession.swift`, `Sources/PokeTokenBar/Team/Plaza/PlazaEmoteArt.swift`, `Sources/PokeTokenBar/Team/TeamLocalization.swift`
- Test: `TeamWireTests.swift`, `TeamSessionTests.swift`, `TeamHostilePeerTests.swift`, `PlazaEmoteTests.swift`, `TeamNotificationsTests.swift` (all extend)

**Interfaces:**
- Produces:
  ```swift
  // TeamPresence, declared after `dittoReady`
  /// A Ditto's disguise: the member whose real look the sender shows in the plaza. Left out when not disguised;
  /// earlier versions ignore it and draw a Ditto.
  @LossyOptional var mimicOf: String?
  // TeamEmoteKind, appended after .snowball in this order
  /// A Ditto teammate's 몸통박치기 on `targetMemberID`: lunge and star, nobody is pushed. Its presence's `mimicOf` says what it
  /// did to the sender's disguise; the target's Mac reveals the target if disguised. Earlier versions skip it.
  case mimicTackle        // notifiesTarget false, endsSendersDance true
  /// The sender's disguise was found by `targetMemberID`. Sent before the presence that drops `mimicOf`. Earlier versions skip it.
  case mimicFound         // notifiesTarget false, endsSendersDance false
  // TeamMemberState
  var mimicOf: String?        // as received, at most TeamWire.maxFieldBytes bytes
  var mimicSeenAt: Date?      // this Mac's clock when the current mimicOf first arrived; nil with no mimicOf
  // TeamSession
  func updateMimic(_ memberID: String?)   // broadcasts presence only when it changed; makePresence writes it
  ```
- Exhaustive switches:
  - `PlazaEmoteArt.image`: `.mimicTackle` draws `impact` like `.tackle`, and `.mimicFound` draws `exclaim`. Neither is shown as a bubble.
  - `L.teamEmoteLabel`: `.mimicTackle: "💥"`, `.mimicFound: "찾았다"`.
- Receive:
  - The value is `presence.mimicOf` if it is at most `TeamWire.maxFieldBytes` UTF-8 bytes, else nil.
  - When it differs from the stored value, set `mimicSeenAt = value == nil ? nil : clock()`. Then store it.

- [ ] **Step 1: Write the failing tests.**
  - **`TeamWireTests`:**
    - The pinned kind list ends with `"pull", "snowball", "mimicTackle", "mimicFound"`.
    - `testWhichEmotesEndTheSendersDance`: the `ends` set gains `.mimicTackle`, and the other set gains `.mimicFound`.
    - `testEveryOptionalFieldSurvivesARoundTrip` sets `full.mimicOf = "m1"`.
    - `testMimicIsOptionalOnTheWire`: a presence without it encodes no `mimicOf` key, and one with `"m1"` round-trips.
    - `testUnreadableMimicDropsOnlyTheMimic`: the JSON presence of `testUnreadableDittoDropsOnlyTheDitto` with `"mimicOf":7` decodes. `mimicOf` is nil, and the nickname, tile, facing and `nameColor` are intact.
  - **`TeamSessionTests`** (mirror `testUpdateDittoSendsOnlyOnChange`):
    - `testPresenceCarriesMyMimic`: after `a.updateMimic("x")`, b's `members[a].mimicOf == "x"`. After `updateMimic(nil)` it is nil.
    - `testUpdateMimicSendsOnlyOnChange`: `nil` sends nothing. `"x"` twice sends one presence. `"y"` sends a second.
    - `testTheSeenTimeIsTheFirstPresenceWithThatMimic`:
      - `a.updateMimic("x")` at t0 gives `mimicSeenAt == t0`.
      - At t0+10, a moves (another presence still carrying `"x"`): the stamp stays t0.
      - At t0+20, `"y"` gives t0+20.
      - `nil` gives nil.
  - **`TeamHostilePeerTests.testAnOverlongMimicIsDropped`** (Review Focus 5):
    - Presences with a 65-byte and a 10,000-byte `mimicOf` leave `members["hostile"]?.mimicOf` and `mimicSeenAt` nil, and the presence's tile still applies.
    - A 64-byte value is kept.
  - **Lists that sort every kind:** add `.mimicTackle` and `.mimicFound` to the message list in `PlazaEmoteTests.testEachEmoteHasArt` and to `decoyKinds` in `TeamNotificationsTests.testEmoteNoticeNamesEachKind`.
- [ ] **Step 2:** Run `swift test --filter 'TeamWireTests|TeamSessionTests|TeamHostilePeerTests'`. Expected: build failure.
- [ ] **Step 3:** Implement as above. Until Task 6 routes the new kinds, `TeamRuntime` shows them as bubbles. Nothing sends them before Task 5.
- [ ] **Step 4:** Run `swift test --filter 'TeamWireTests|TeamSessionTests|TeamHostilePeerTests|PlazaEmoteTests|TeamNotificationsTests|TeamLocalizationTests'`. Expected: all pass.
- [ ] **Step 5:** Commit: `feat(team): carry a Ditto teammate's disguise on the wire`.

---

### Task 2: Mimic rules (`PlazaMimic.swift`)

**Files:**
- Create: `Sources/PokeTokenBar/Team/Plaza/PlazaMimic.swift`
- Test: `Tests/PokeTokenBarTests/PlazaMimicTests.swift` (new)

**Interfaces:**
- Consumes: Task 1 `TeamMemberState.mimicOf`, `mimicSeenAt`; `PlazaDitto.speciesID`.
- Produces:
  ```swift
  enum PlazaMimic {
      static let duration: TimeInterval = 300
      static let receiverGrace: TimeInterval = 5
      static func isDitto(speciesID: Int?) -> Bool                         // speciesID == PlazaDitto.speciesID
      enum Tackle: Equatable { case disguise(as: String), release, keep }
      /// My tackle on teammate `target` while my plaza Pokémon is a Ditto. In this order: keep when the target is shown disguised
      /// (its own Mac reveals it, §4.5); release when `mine == target`; keep when the target isn't in the plaza; else disguise
      /// (a switch when `mine` is someone else).
      static func tackle(_ target: String, mine: String?, targetIsDisguised: Bool, targetInPlaza: Bool) -> Tackle
      /// My disguise ends: not a Ditto, the copied member out of the plaza, or `duration` passed since `since`.
      static func isOver(since: Date, now: Date, targetInPlaza: Bool, amDitto: Bool) -> Bool
      /// Who `m` is drawn as here, nil for themselves. Needs: `m` is a Ditto, `m.inPlaza`, `m.mimicOf` is in `inPlaza` and isn't
      /// `m.memberID`, and `now - m.mimicSeenAt < duration + receiverGrace`. `inPlaza` holds members in the plaza and me.
      static func shownTarget(of m: TeamMemberState, now: Date, inPlaza: Set<String>) -> String?
  }
  /// A teammate's real look, as a Ditto copies it (§4.1). Always built from that member's own presence, never from a disguise (§4.5).
  struct PlazaMimicLook: Equatable {
      let memberID: String
      let name: String                 // nickname, no zZ
      let nameHex: UInt32              // PlazaNameColor.hex(forMemberID: memberID, chosen: their pick), always a palette value
      let nature: PokemonNature?
      let subject: CompanionStore.RepresentativeSubject
  }
  ```

- [ ] **Step 1: Write the failing tests** in `PlazaMimicTests`:
  - `testOnlyDittoIsDitto`: true for 132, false for 25 and nil.
  - `testTackleDisguisesSwitchesReleasesOrKeeps`. The arguments below are `(target, mine:, targetIsDisguised:, targetInPlaza:)`:
    - `("x", mine: nil, false, true)` gives `.disguise(as: "x")`.
    - `("y", mine: "x", false, true)` gives `.disguise(as: "y")`.
    - `("x", mine: "x", false, true)` gives `.release`.
    - `("b", mine: nil, true, true)`, `("b", mine: "x", true, true)` and `("b", mine: "b", true, true)` give `.keep`.
    - `("x", mine: nil, false, false)` gives `.keep`.
  - `testMyDisguiseIsOverAfterFiveMinutesALeaveOrALostDitto`:
    - False at `since + 299.9`, true at `since + 300`.
    - True with `targetInPlaza: false` or `amDitto: false` at `since + 1`.
  - `testShownTargetFollowsAnHonestDisguise`:
    - Member "m": species 132, in the plaza, `mimicOf: "x"`, seen at t0, with `inPlaza = ["m", "x", "me"]`.
    - `"x"` at t0+304.9 and nil at t0+305.
    - `mimicOf: "me"` gives `"me"`.
  - `testShownTargetDropsHostileValues` (Review Focus 5): nil for each of these:
    - species 25.
    - species nil (an egg).
    - `mimicOf: "m"` (itself).
    - `mimicOf: "gone"` (not in `inPlaza`).
    - `mimicOf: "plaza-ditto"`.
    - `m.inPlaza == false`.
    - `mimicSeenAt == nil`.
    - `mimicOf == nil`.
- [ ] **Step 2:** Run `swift test --filter PlazaMimicTests`. Expected: build failure.
- [ ] **Step 3:** Implement with the interfaces above.
- [ ] **Step 4:** Run `swift test --filter PlazaMimicTests`. Expected: all pass.
- [ ] **Step 5:** Commit: `feat(team): add the Ditto mimic rules`.

---

### Task 3: My name plate under a disguise (scene)

**Files:**
- Modify:
  - `Sources/PokeTokenBar/Team/Plaza/PlazaScene.swift`
  - `Sources/PokeTokenBar/Team/Plaza/PlazaActor.swift`: `name` and `nameColor` become `private(set)`.
- Test: `Tests/PokeTokenBarTests/PlazaMimicSceneTests.swift` (new)

**Interfaces:**
- Consumes: Task 2 `PlazaMimicLook`.
- Produces:
  ```swift
  // PlazaScene
  /// My plate while I copy a teammate (§5.2); nil for my own. `nickname`, `nameColor` and my nature title stay mine:
  /// `setNickname`, `setNameColor` and `setNature` keep storing them and show them only while no disguise is set.
  func setMyDisguise(_ look: PlazaMimicLook?)
  var myShownName: String { get }          // me.name
  var myShownNameColor: CGColor { get }    // me.nameColor
  // `myTitle` (exists) shows the disguise's title while one is set.
  ```
- The disguise's colour is `PlazaNameColor.color(forMemberID: look.memberID, chosen: look.nameHex)`. Its title is `look.nature.map(L(.ko).plazaNatureTitle)`.
- Sprites come through the existing `setCharacter(_:)`; photos, dances and jumps read the actor, so they follow.

- [ ] **Step 1: Write the failing tests** in `PlazaMimicSceneTests`, on a bare `PlazaScene` (nickname "나", `setNameColor(palette[2])`, `setNature(.hardy)`):
  - `testADisguiseShowsTheirNameColourAndTitle`:
    - `setMyDisguise(look("지아", hex 0xFF9ECF, nature .timid))` gives `myShownName == "지아"`, `myShownNameColor ==` the colour of 0xFF9ECF, and `myTitle == L(.ko).plazaNatureTitle(.timid)`.
    - `scene.nickname == "나"` and `scene.nameColor == palette[2]`.
  - `testMyOwnChangesWaitUnderTheDisguise`:
    - While disguised, `setNickname("새이름")`, `setNameColor(palette[4])` and `setNature(.bold)` leave 지아, the pink colour and the timid title shown.
    - `setMyDisguise(nil)` then shows "새이름", `palette[4]` and the bold title.
  - `testADisguiseWithoutANatureHasNoTitle`: `myTitle == nil`.
- [ ] **Step 2:** Run `swift test --filter PlazaMimicSceneTests`. Expected: build failure.
- [ ] **Step 3:** Implement. Keep my own title in a stored property, because `setNature` can no longer compare against `me.title`.
- [ ] **Step 4:** Run `swift test --filter 'PlazaMimicSceneTests|PlazaNatureTests|PlazaNameColorTests|PlazaPhotoTests'`. Expected: all pass.
- [ ] **Step 5:** Commit: `feat(team): show a disguise on my own name plate`.

---

### Task 4: Seeing a teammate's disguise (controller, receiving side)

**Files:**
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaWindowController.swift`
- Test: `Tests/PokeTokenBarTests/PlazaMimicControllerTests.swift` (new)

**Interfaces:**
- Consumes: Task 1 (`mimicOf`, `mimicSeenAt`, `updateMimic`), Task 2 (`shownTarget`, `PlazaMimicLook`).
- Produces (Tasks 5–7 use these):
  ```swift
  // PlazaWindowController
  private(set) var shownMimics: [String: String]   // member -> member whose look they are drawn with now
  /// The 1 s focus tick calls it (after endFocusIfDue, before refreshCampfire). Redraws teammates when
  /// `mimicTargets() != shownMimics`. Task 5 adds my own disguise.
  func endMimicIfDue()
  private func realLook(of id: String) -> PlazaMimicLook?   // me, or a member with inPlaza; else nil
  private func mimicTargets() -> [String: String]           // shownTarget for every member; inPlaza = members in plaza + me
  ```
- Behaviour:
  - **`realLook(of:)`:**
    - Me: `nickname()`, `PlazaNameColor.hex(forMemberID: myID, chosen: nameColor())`, `(myEntryCache ?? nil)?.nature`, `subject()`.
    - A member: their nickname, `hex(forMemberID: id, chosen: m.nameColor)`, `m.character.nature`, and the subject from `m.character`.
  - **`applyMembersToScene`:**
    - `look = mimicTargets()[id].flatMap(realLook)`.
    - `PlazaSceneMember` takes the nickname, `nameColor` (the hex) and nature from `look` when there is one. Everything else stays the member's own: tile, idle zZ, running, diving, stage.
    - The frame subject is `look?.subject` or the member's own. The existing `memberSubjects` check reloads only on a change.
    - Then set `shownMimics`.
    - For each entry that is new or changed to X, stop the walk or follow when `scene.walkingToMember` is that member or X (§5.1).
  - **`showChat`:** the log colour is `PlazaNameColor.color(forMemberID: memberID, chosen: member.nameColor)`, not the drawn colour (§2: the chat log stays real).
  - **`handleClose`:** clears `shownMimics`.

- [ ] **Step 1: Write the failing tests** in `PlazaMimicControllerTests`.
  - **Harness:**
    - Copy `PlazaDittoControllerTests`' `node(_:character:)`, `settle`, `connect` and `sorted`, and `PlazaFocusTests`' `TickGate`.
    - Sessions and controllers share one `now`.
    - Controllers take `subject: { [unowned self] in .init(speciesID: mySpecies, isShiny: false) }`, `focusTickSleep: gate.sleep`, a `dittoLoopSleep` that sleeps for good, `dittoSeed: { 7 }` and a `RecordingFetcher`.
    - Sample characters:
      - `ditto`: species 132.
      - 지아: species 25, shiny, nature `.timid`, `settings.nameColor = 0xFF9ECF`.
    - Teammates get tiles with `updatePlazaPosition`, and a test waits until `scene.memberTiles` shows them. Frame loads are async, so `await settle()` before reading `appliedMemberSpecies`.
    - Keep the guest Ditto out of the way, because the expiry tests jump the clock by 300 s.
      - Unless a test needs the guest Ditto, connect a quiet host with the smallest ID (`sorted`), in the plaza far from the action, with `updateDitto(ready: true, state: nil)`.
      - Then this Mac never hosts and draws no Ditto.
    - Tackles share `emoteInterval`, so advance `now` by 0.3 s between two tackles.
  - `testATeammatesDisguiseDrawsThemAsTheOneTheyCopy`:
    - Ditto m and 지아 x are in the plaza. `m.session.updateMimic(x.id)`.
    - `scene.memberName(m)` is "지아", `memberNameColor(m)` is 0xFF9ECF's colour, and `memberTitle(m)` is the timid title.
    - `shownMimics[m] == x`, `appliedMemberSpecies(m).last == 25`, and the minimap has two dots in that colour.
    - After `updateMimic(nil)`: m's own nickname, and species 132.
  - `testACopyOfMeShowsMyRealLook`: m copies me. `memberName(m) == "나"`, the colour is mine, and the species is my subject's.
  - `testACopyOfACopierShowsTheirRealLook` (Review Focus 3):
    - Ditto a copies Ditto b, and b copies x.
    - `memberName(a)` is b's nickname and `appliedMemberSpecies(a).last == 132`.
    - `memberName(b)` is "지아".
  - `testHostileMimicValuesDrawTheSenderAsThemselves` (Review Focus 5): the sender shows its own nickname in each case:
    - A Pikachu member p with `mimicOf: x`.
    - Ditto m with `mimicOf: "nobody"`.
    - Ditto m with `mimicOf: m.id`.
  - `testADisguiseOfAMemberWhoLeftIsDrawnAsTheSender` (Review Focus 2): m copies x, then x sends `inPlaza: false`. `memberName(m)` is m's own name while m's presence still says x.
  - `testACoveredWindowStillDropsADisguiseAfterItsTime` (Review Focus 1):
    - m copies x at t0. Call `setRendering(visible: false)`.
    - At t0+304, `await gate.tick()` leaves "지아".
    - At t0+305, a tick gives m's own name.
  - `testADisguiseStopsMyWalkToEitherOfThem`:
    - `scene.walk(toMember: x)`, then m copies x: `scene.walkingToMember == nil`.
    - The same with `scene.follow(member: m)`.
  - `testTheChatLogKeepsTheRealNameAndColour`: m copies x, and `showChat(memberID: m, text: "안녕")` logs m's nickname and m's own colour.
  - `testTheGuestDittoCopiesADisguisedMembersRealLook` (§5.2):
    - With `sorted`, host h has the smallest ID and sends a guest copy of m while m copies x.
    - `memberName(PlazaDitto.sceneKey)` is m's nickname, its colour is m's, and `appliedMemberSpecies(key).last == 132`.
    - m then switching to y adds no load under the key.
- [ ] **Step 2:** Run `swift test --filter PlazaMimicControllerTests`. Expected: build failure.
- [ ] **Step 3:** Implement as above.
- [ ] **Step 4:** Run `swift test --filter 'PlazaMimicControllerTests|PlazaDittoControllerTests|PlazaMembersTests|PlazaChatTests|PlazaFocusTests'`. Expected: all pass.
- [ ] **Step 5:** Commit: `feat(team): draw a Ditto teammate as the one it copies`.

---

### Task 5: My disguise (controller, sending side)

**Files:**
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaWindowController.swift`, `Sources/PokeTokenBar/Team/TeamLocalization.swift`
- Test: `PlazaMimicControllerTests.swift`, `PlazaMimicTests.swift` (extend)

**Interfaces:**
- Consumes: Tasks 1–4 (`updateMimic`, `PlazaMimic.tackle`/`isOver`, `setMyDisguise`, `realLook`, `shownMimics`, `endMimicIfDue`).
- Produces:
  ```swift
  // PlazaWindowController
  var mimicking: String? { get }                                  // myMimic?.of
  var myShownSubject: CompanionStore.RepresentativeSubject { get } // myShownLook?.subject ?? subject()
  private var myMimic: (of: String, since: Date)?
  private var myShownLook: PlazaMimicLook?
  private func beginMimic(as id: String)   // since = clock(); updateMimic(id); refreshMyLook(); refreshHint()
  private func endMimic()                  // no-op if not disguised; updateMimic(nil); refreshMyLook(); refreshHint()
  /// look = myMimic.flatMap { realLook(of: $0.of) }. When it changed: scene.setMyDisguise(look); when the subject changed,
  /// Task { await refreshCharacter() }.
  private func refreshMyLook()
  // TeamLocalization
  func plazaMimicHint(nickname: String, seconds: TimeInterval) -> String   // seconds rounded up, at least 0
  ```
- Behaviour:
  - **`tackle(_:)`:** after the two guest-Ditto branches, when `PlazaMimic.isDitto(speciesID: subject().speciesID)`:
    - Send `.mimicTackle` (target `id`) first.
    - Then apply `PlazaMimic.tackle(id, mine: myMimic?.of, targetIsDisguised: shownMimics[id] != nil, targetInPlaza: members[id]?.inPlaza == true)`: `.disguise` calls `beginMimic`, `.release` calls `endMimic`.
    - Return without a `.tackle`.
  - **`endMimicIfDue()`** also ends mine when `PlazaMimic.isOver(since:now:targetInPlaza: members[x]?.inPlaza == true, amDitto:)` holds.
  - **Where it is called:**
    - `observeMembers` calls `endMimicIfDue()` and then `refreshMyLook()` after `applyMembersToScene()`. My look follows the copied member's changes.
    - `refreshCharacter()` calls `endMimicIfDue()` first.
  - **`loadCharacter`** loads `myShownSubject`. `canWalk`, the stage and the dive limit keep using `subject()`.
  - **`refreshHint`:** after the diving branch, when disguised with no overlay or chat input, show `plazaMimicHint(nickname: myShownLook.name, seconds: since + duration - now)`.
  - **`handleClose`:** clears `myMimic` and `myShownLook`, and calls `updateMimic(nil)`.

- [ ] **Step 1: Write the failing tests.** In each test I am a Ditto (`mySpecies = 132`) unless the test says otherwise. Tackles go through `c.chooseMenu(.tackle, memberID:)`, apart from one C-key test that first calls `scene.face` toward the target.
  - `testADittosTackleSendsAMimicTackleAndPushesNobody`: C on adjacent x makes x receive `.mimicTackle` with target x and no `.tackle`.
  - `testOnlyADittoOnThePlazaMimics`: with `mySpecies = 25`, x receives `.tackle` (no `.mimicTackle`) and `mimicking == nil`. A comment notes that `subject()` already shows an egg-disguised Ditto as its fake species (§3).
  - `testTacklingATeammateDisguisesMeAsThem`:
    - `mimicking == x` and `x.session.members[me]?.mimicOf == x`.
    - `scene.myShownName == "지아"`, `myShownNameColor` is 0xFF9ECF's colour, and `scene.myTitle` is the timid title.
    - `myShownSubject == .init(speciesID: 25, isShiny: true)`.
  - `testTacklingAnotherTeammateSwitchesAndRestartsTheClock`:
    - Copy x at t0. At t0+200, tackle y: `mimicking == y`.
    - A tick at t0+499 keeps y. A tick at t0+500 ends it.
  - `testTacklingTheSameTeammateAgainReleasesMe`: `mimicking == nil`, x sees `mimicOf == nil`, and `myShownName == "나"`.
  - `testTacklingADisguisedDittoLeavesMeAsIAm` (Review Focus 3):
    - Ditto b copies x and is drawn so here. Tackle b: b receives `.mimicTackle` and `mimicking` stays nil.
    - Already copying y: still y.
  - `testCopyingAnUndisguisedDittoTakesItsRealLook` (Review Focus 3):
    - Tackle Ditto b: `myShownName` is b's nickname and `myShownSubject.speciesID == 132`.
    - After b copies x, both are unchanged.
  - `testFiveMinutesEndMyDisguiseWhileTheWindowIsCovered` (Review Focus 1):
    - Copy x at t0, then `setRendering(visible: false)`.
    - A tick at t0+299 keeps it.
    - A tick at t0+300 gives `mimicking == nil`, x sees nil, `myShownName == "나"` and `myShownSubject.speciesID == 132`.
  - `testTheCopiedMemberLeavingEndsMyDisguise` (Review Focus 2): x sends `inPlaza: false`. With no tick, `mimicking == nil` and x sees nil.
  - `testNoLongerADittoEndsMyDisguise`: `mySpecies = 25`, then `await c.refreshCharacter()` gives `mimicking == nil`.
  - `testClosingThePlazaEndsMyDisguise`: `handleClose()` makes x see nil. `prepareScene()` again gives `mimicking == nil` and `myShownName == "나"`.
  - `testTheHintShowsWhoIAmAndTheTimeLeft`:
    - Copy x at t0. At t0+48, `refreshHintForTesting()` gives the hint `"지아로 변신 중 · 4:12"`.
    - A tick at t0+59.5 gives `"지아로 변신 중 · 4:01"`.
    - After release, the hint is not a mimic hint.
  - `testMyDisguiseFollowsTheirNameColour`: x picks 0x7FD4FF, and `myShownNameColor` follows.
  - **`PlazaMimicTests.testTheHintNamesThemAndCountsDown`:**
    - `("지아", 252)` gives `"지아로 변신 중 · 4:12"`.
    - `("도윤", 0.2)` gives `"도윤으로 변신 중 · 0:01"`.
    - `("지아", 300)` gives `"… · 5:00"`.
    - `("지아", -3)` gives `"… · 0:00"`.
- [ ] **Step 2:** Run `swift test --filter 'PlazaMimicControllerTests|PlazaMimicTests'`. Expected: the new tests fail.
- [ ] **Step 3:** Implement as above.
- [ ] **Step 4:** Run `swift test --filter 'PlazaMimicControllerTests|PlazaMimicTests|PlazaMimicSceneTests|PlazaEmoteTests|PlazaTackleWaterTests|PlazaFocusTests|PlazaDittoControllerTests|TeamLocalizationTests'`. Expected: all pass.
- [ ] **Step 5:** Commit: `feat(team): let a Ditto teammate disguise itself by tackling`.

---

### Task 6: Being found (tackles, snowballs, the banner, the runtime)

**Files:**
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaWindowController.swift`, `Sources/PokeTokenBar/Team/TeamRuntime.swift`, `Sources/PokeTokenBar/Team/TeamLocalization.swift`
- Test: `PlazaMimicControllerTests.swift`, `TeamRuntimeTests.swift` (extend)

**Interfaces:**
- Consumes: Task 5 (`myMimic`, `endMimic`, `mimicking`), Task 4 (`shownMimics`).
- Produces:
  ```swift
  // PlazaWindowController (TeamRuntime calls the first two)
  func showMimicTackle(from sender: String, on target: String?)
  func showMimicFound(from sender: String, finder: String?)
  private func revealMe(by finder: String)
  // TeamLocalization
  func plazaMimicFound(finder: String, owner: String) -> String   // "\(finder)님이 \(owner)의 메타몽을 찾았어요!"
  ```
- Behaviour:
  - **`showTackle`, the case where I'm the target:** when the sender is beside me or on my tile, a disguised me gets `revealMe(by: sender)`. Otherwise the push happens as today when `canBePushed`.
  - **`showMimicTackle`:**
    - Like `showTackle`, but with no guest-Ditto branch and no push: `playTackle(by: sender, on: target or me)`.
    - When I'm the target, disguised, and the sender is beside me or on my tile: `revealMe`.
    - A target not drawn (an unknown ID, the Ditto key) does nothing.
  - **`showSnowball`'s landing for me:** a hit while I'm still on `shot.endTile` reveals a disguised me; otherwise it pushes as today.
  - **`revealMe(by:)`:**
    - Send `.mimicFound` (target `finder`) first, then call `endMimic()`.
    - Show `.exclaim` over me.
    - Show the banner `plazaMimicFound(finder: members[finder]?.nickname, owner: nickname())`, but only when the finder's name is known.
  - **`showMimicFound`:**
    - Ignore it unless `finder != nil` and `shownMimics[sender] != nil`.
    - Show `.exclaim` over the sender.
    - Show the banner, naming the finder (`nickname()` when it is me) and `members[sender].nickname`.
  - **Unchanged:** `playDecoyTackle` (the guest copy's prank) never reveals (§4.4).
  - **`TeamRuntime.onEmote`:** `.mimicTackle` goes to `showMimicTackle(from:on:)`, and `.mimicFound` to `showMimicFound(from:finder: targetMemberID)`. Both then return.

- [ ] **Step 1: Write the failing tests.** In each test I am a Ditto copying x unless the test says otherwise. Doyun ("도윤", Pikachu) stands beside me.
  - `testATackleRevealsMeInsteadOfPushing` (§9):
    - `showTackle(from: doyun, on: me, tiles: 2)`, then 1 s of frames: my tile is unchanged and `mimicking == nil`.
    - Doyun has received `.mimicFound` with target Doyun, and sees `mimicOf == nil`.
    - `scene.shownEmote(memberID: nil) == .exclaim`, and `c.banner == "도윤님이 나의 메타몽을 찾았어요!"`.
  - `testTheFindIsSentBeforeTheDisguiseIsDropped`: Doyun's `onEmote` records `members[me]?.mimicOf` when `.mimicFound` arrives, and it is x.
  - `testADittosTackleRevealsADisguisedMe` (Review Focus 3): `showMimicTackle(from: dittoA, on: me)` reveals me, and dittoA receives `.mimicFound`.
  - `testADittosTackleOnAnUndisguisedMePushesNobody` (§9): not disguised, `showMimicTackle(from: dittoA, on: me)` and 1 s of frames leave my tile unchanged and give `impactCount == 1`.
  - `testATackleFromAfarOnlyShowsTheStar`: Doyun two tiles away; I stay disguised.
  - `testASnowballRevealsMeWhenItLands` (§6):
    - The clock is on a snow day (copy `PlazaSnowballControllerTests.day(6)`). Doyun is in line, 3 tiles left.
    - `showSnowball(from: doyun, on: me, tiles: 2, direction: .right)`: still disguised before 0.3 s of frames.
    - After 1.2 s of frames: revealed, my tile unchanged, and Doyun has `.mimicFound`.
  - `testMySnowballAsADittoIsAnOrdinarySnowball` (§6): on the snow day, V at x 3 tiles ahead makes x receive `.snowball` with target x, and `mimicking` stays nil.
  - `testTheGuestCopysPrankDoesNotRevealMe` (§4.4): host h (smallest ID) shows a guest copy beside me. `showDecoyTackle(from: h, on: me)` leaves `mimicking == x`.
  - `testOthersSeeTheRevealBanner`:
    - Ditto m copies x and is drawn so here. `showMimicFound(from: m, finder: doyun)` gives `shownEmote(memberID: m) == .exclaim` and the banner `"도윤님이 <m의 닉네임>의 메타몽을 찾았어요!"`.
    - With `finder: me`, the banner starts `"나님이"`.
  - `testAFoundFromSomeoneNotDisguisedIsIgnored`: with m undisguised, or `finder == nil`, there is no banner and no `!`.
  - **`TeamRuntimeTests`:**
    - `testAnOlderVersionsTackleRevealsMeAndDoesNotPush` (Review Focus 4):
      - b's plaza is a Ditto. b copies a through `chooseMenu(.tackle, memberID: a)`.
      - a, beside b, sends the frame an older version sends: `.tackle` at b with `pushTiles: 3`.
      - b's tile is unchanged after the frames, `plaza.mimicking == nil`, and a has received `.mimicFound` with target a.
    - `testMimicKindsReachThePlaza`:
      - a (Ditto) beside b sends `.mimicTackle` at b: `scene.impactCount == 1`, and b's tile is unchanged after the frames.
      - a's session then announces a Ditto character (`updateCharacter`) and `updateMimic(b)`, and b's plaza draws a as b. a sends `.mimicFound` at b: b's banner is `"나님이 <a의 닉네임>의 메타몽을 찾았어요!"`.
- [ ] **Step 2:** Run `swift test --filter 'PlazaMimicControllerTests|TeamRuntimeTests'`. Expected: the new tests fail.
- [ ] **Step 3:** Implement as above.
- [ ] **Step 4:** Run `swift test --filter 'PlazaMimicControllerTests|TeamRuntimeTests|PlazaEmoteTests|PlazaSnowballControllerTests|PlazaDittoControllerTests|PlazaTackleWaterTests|TeamLocalizationTests'`. Expected: all pass.
- [ ] **Step 5:** Commit: `feat(team): reveal a disguised Ditto teammate when tackled`.

---

### Task 7: Roster, menu and hints; TEAM.md

**Files:**
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaWindowController.swift`, `TEAM.md`
- Test: `PlazaMimicControllerTests.swift` (extend)

**Interfaces:**
- Consumes: Task 4 (`shownMimics`, `realLook`), Task 5 (`myMimic`).
- Produces: `private var menuLook: (id: String, shownAs: String?)?`, set when a member menu opens and cleared on close.
- Behaviour:
  - **`walkToMember(id)`** does what key 5 does (`?`) instead of walking when any of these hold:
    - `shownDitto?.decoyOf == id`.
    - `shownMimics[id] != nil`.
    - `shownMimics.values.contains(id)`.
    - `myMimic?.of == id`.
  - **Hint names:**
    - `hintName(of:)` returns `realLook(of: x)?.name` for a member drawn as x.
    - The pull and startle hints call `hintName(of:)` instead of `members[id]?.nickname`.
  - **`handleInteractKey`, `.member(id)`, for a member drawn as x:**
    - The menu is `PlazaMemberMenu(memberID: id, nickname: look.name, nameColor: look.nameHex)`.
    - When x is me, drop `.viewCard`.
    - The focus status and the action filters stay the member's own.
    - Record `menuLook = (id, shownMimics[id])`.
  - **`chooseMenu`, member ids:**
    - When `menuLook?.id == id` and its `shownAs != shownMimics[id]`, call `closeOverlay()` and do nothing else.
    - `viewCard` opens `shownMimics[id] ?? id`.
  - **`TEAM.md`:**
    - A new row "내 메타몽" after "메타몽", in the table's Korean style. It covers:
      - Only when the plaza Pokémon is a Ditto (an egg-disguised Ditto only after its reveal).
      - C or the menu's tackle disguises me as that teammate (look, name, colour, nature line); the hint shows the time left.
      - A Ditto's tackle pushes nobody.
      - Another teammate switches (the 5 minutes restart). The same one again, 5 minutes, the copied teammate leaving, changing my Pokémon, or closing the plaza ends it.
      - A tackle or a snowball reveals me instead of pushing, with the banner.
      - The Ditto-on-Ditto rules.
      - The roster `?`.
      - The roster, cards, notifications and chat log stay real.
      - Teammates on `<latest tag>` 이하 see a plain Ditto and no Ditto tackle.
    - The C row gains one sentence pointing to that row.
    - `<latest tag>` is `git tag --list 'v2.5.*' --sort=-v:refname | head -1` at the time.

- [ ] **Step 1: Write the failing tests:**
  - `testClickingEitherOfThemInTheRosterAsks` (§5.1):
    - m copies x. `walkToMember(x)` and, 0.3 s later, `walkToMember(m)` each leave `scene.walkingToMember == nil` and show `.question` over me. Each sends one `.question`.
    - `walkToMember(y)` walks.
  - `testWhileIMimicClickingTheOneICopyAsks`: copying x, `walkToMember(x)` shows `?` and doesn't walk.
  - `testTheSpaceHintAndMenuUseTheCopiedName` (§5.2):
    - Facing m (drawn as 지아), the hint is `"스페이스바를 눌러 지아에게 말 걸기"`.
    - Space opens `.memberMenu` with nickname "지아" and `nameColor == 0xFF9ECF`, and `.viewCard` is among the actions.
    - `chooseMenu(.viewCard, memberID: m)` opens `.card(.loading(state))` with `state.memberID == x`.
  - `testAMenuOnACopyOfMeHasNoCard`: m copies me, so the menu nickname is "나" and there is no `.viewCard`.
  - `testAMenuWhoseDisguiseChangedDoesNothing`: open the menu on m (지아). m releases and is redrawn. `chooseMenu(.viewCard, memberID: m)` leaves `overlayContent == .none`.
- [ ] **Step 2:** Run `swift test --filter PlazaMimicControllerTests`. Expected: the new tests fail.
- [ ] **Step 3:** Implement as above, and write the TEAM.md rows.
- [ ] **Step 4:** Run `swift test --filter 'PlazaMimicControllerTests|PlazaRosterTests|PlazaCardTests|PlazaDittoControllerTests|PlazaStartleControllerTests|PlazaEmoteTests|PlazaFocusTests'`. Expected: all pass.
- [ ] **Step 5:** Commit: `feat(team): keep a disguise in the roster, menu and hints`.

---

### Task 8: Branch check (fault injection and coverage)

- [ ] **Step 1: Fault injection.** Put each fault in by hand, run the owning focused filter, see it fail, then revert it. Record the results for the PR body.
  1. `shownTarget` skips the Ditto check → `testShownTargetDropsHostileValues` and `testHostileMimicValuesDrawTheSenderAsThemselves`.
  2. `shownTarget` skips the time limit → `testShownTargetFollowsAnHonestDisguise` and `testACoveredWindowStillDropsADisguiseAfterItsTime`.
  3. The session restamps `mimicSeenAt` on every presence → `testTheSeenTimeIsTheFirstPresenceWithThatMimic`.
  4. The focus tick doesn't call `endMimicIfDue()` → `testFiveMinutesEndMyDisguiseWhileTheWindowIsCovered`.
  5. A Ditto's `tackle` sends `.tackle` → `testADittosTackleSendsAMimicTackleAndPushesNobody`.
  6. `PlazaMimic.tackle` ignores `targetIsDisguised` → `testTackleDisguisesSwitchesReleasesOrKeeps` and `testTacklingADisguisedDittoLeavesMeAsIAm`.
  7. `realLook` copies a drawn disguise (`shownMimics`) instead of presence → `testACopyOfACopierShowsTheirRealLook` and `testCopyingAnUndisguisedDittoTakesItsRealLook`.
  8. `showTackle` pushes a disguised me → `testATackleRevealsMeInsteadOfPushing` and `testAnOlderVersionsTackleRevealsMeAndDoesNotPush`.
  9. `revealMe` drops the presence before sending `.mimicFound` → `testTheFindIsSentBeforeTheDisguiseIsDropped`.
  10. `showMimicFound` skips its guard → `testAFoundFromSomeoneNotDisguisedIsIgnored`.
  11. The snowball landing pushes a disguised me → `testASnowballRevealsMeWhenItLands`.
  12. `observeMembers` doesn't call `endMimicIfDue()` → `testTheCopiedMemberLeavingEndsMyDisguise`.
  13. `handleClose` keeps the disguise → `testClosingThePlazaEndsMyDisguise`.
  14. `setNature` writes the title under a disguise → `testMyOwnChangesWaitUnderTheDisguise`.
- [ ] **Step 2: Coverage.**
  - Run `swift test --enable-code-coverage --filter 'PlazaMimic|TeamSessionTests|TeamHostilePeerTests|TeamWireTests|TeamRuntimeTests'`.
  - Find the profile and binary the way `scripts/test-gate.sh` does: `default.profdata`, and `PokeTokenBarPackageTests` outside `*.dSYM`.
  - Run `xcrun llvm-cov show <bin> -instr-profile=<profdata> <file> --show-regions` for `PlazaMimic.swift` and for the new parts of `PlazaWindowController.swift`, `PlazaScene.swift` and `TeamSession.swift`.
  - Every `^0` in a new branch either gets a test or a one-line reason in the PR body.
- [ ] **Step 3:** If tests were added, run their filter and commit: `test(team): cover the Ditto mimic branches`.

---

### Task 9: PR images (temporary offscreen render, deleted afterwards)

- [ ] **Step 1: Write the render test.** Write `Tests/PokeTokenBarTests/ZZMimicRender.swift`. Never commit it.
  - Skip unless `PTB_ZZ_DIR` is set.
  - Render scenes through `SKRenderer` into a Metal texture: no windows and no `show()` (memory "offscreen-plaza-render"). Render SwiftUI parts (hint, banner, roster) through `ImageRenderer` and composite them over the scene image where the window puts them.
  - Use sample data only:
    - Nicknames 지아, 민수 (the Ditto), 도윤 and 서연.
    - Sprites come from the local cache `~/Library/Application Support/PokeTokenBar/sprites`, or coloured blocks when it is missing.
    - Use loopback sessions as in `PlazaMimicControllerTests`, with `backingOverride = 1`.
  - `SKAction`s don't run offscreen, so the star is left out.
  - Label each image "Sample-data render".
- [ ] **Step 2: Render.** Run `PTB_ZZ_DIR=/private/tmp/claude-501/-Users-simu-Documents-GitHub-PokeTokenBar/565430de-c0b7-4604-80e8-d6f04edc0447/scratchpad/mimic-pr swift test --filter ZZMimicRender`, after the `pgrep` check. It writes:
  1. A disguise before and after, from 서연's plaza with 민수 beside 지아: `disguise-before.png` shows a Ditto named 민수, and `disguise-after.png` shows two 지아.
  2. 민수's own plaza while disguised, with the top hint `지아로 변신 중 · 4:12`: `hint.png`.
  3. The roster `?`: 서연's plaza after clicking 지아 in the roster, with `?` over 서연 and the roster panel with real names: `roster-question.png`.
  4. The reveal: 서연's plaza after 도윤 tackles the fake 지아, with `!` over 민수 (back to a Ditto) and the banner `도윤님이 민수의 메타몽을 찾았어요!`: `reveal.png`.
- [ ] **Step 3: Clean up.**
  - Delete `ZZMimicRender.swift`.
  - `git status --short` shows no test file.
  - List the PNG paths for the PR step. Uploading them and preparing the PR (merge `origin/main`, the `prepare-pr` skill) are outside this plan.

---

## Self-review

- **Spec coverage:**

  | Spec | Where it's covered |
  |---|---|
  | §3 who can (Ditto only; egg disguise) | Tasks 2 and 5 |
  | §4.1 disguise: look, name, colour, nature line; no push; new kind | Tasks 1, 3 and 5 |
  | §4.2 release on re-tackle, switch, restart 5 min | Tasks 2 and 5 |
  | §4.3 5 min, target leaves, not a Ditto, window closed | Tasks 4 (tick) and 5 |
  | §4.4 reveal by tackle, banner, guest prank not a reveal | Task 6 |
  | §4.5 Ditto on Ditto; real look only | Tasks 2, 4, 5 and 6 |
  | §5.1 roster `?`; stop walking or following | Tasks 4 and 7 |
  | §5.2 drawing, my view and hint, menu, card, what stays real, guest copy | Tasks 3, 4, 5 and 7 |
  | §6 snowballs | Task 6 |
  | §7 wire and hostile values, receiver expiry | Tasks 1, 2 and 4 |
  | §8 success | Task 9 images |
  | §9 required: hostile values | Tasks 1, 2 and 4 |
  | §9 required: four releases | Tasks 4, 5 and 6 |
  | §9 required: no push | Tasks 5 and 6 |
  | §9 required: covered window | Tasks 4 and 5 |

- **Type consistency:** these names are shared across tasks, and each is defined once in an Interfaces block:
  - `TeamPresence.mimicOf`, `TeamMemberState.mimicOf` and `mimicSeenAt`, `TeamSession.updateMimic(_:)`
  - `TeamEmoteKind.mimicTackle` and `.mimicFound`
  - `PlazaMimic.duration`, `receiverGrace`, `isDitto(speciesID:)`, `tackle(_:mine:targetIsDisguised:targetInPlaza:)`, `isOver(since:now:targetInPlaza:amDitto:)`, `shownTarget(of:now:inPlaza:)`
  - `PlazaMimicLook`, `setMyDisguise(_:)`, `myShownName`, `myShownNameColor`
  - `shownMimics`, `endMimicIfDue()`, `realLook(of:)`, `mimicking`, `myShownSubject`
  - `showMimicTackle(from:on:)`, `showMimicFound(from:finder:)`, `plazaMimicHint(nickname:seconds:)`, `plazaMimicFound(finder:owner:)`
- **Proportion:** code appears only in the Interfaces blocks. The rule bodies follow from their doc comments and the tests.
