# Plaza Core Time and Season Period Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the plaza's bright core time and the season-weather period team settings. Anyone on the team can change them, and every participant converges on the latest change.

**Architecture:**
- **Pure models:**
  - `PlazaCoreTime` drives `PlazaDaylight`.
  - `PlazaWeather.Period` drives `PlazaWeather.kind`.
- **Shared value:** `PlazaSchedule` is a last-writer-wins register.
  - Storage: `TeamSettings` keeps one per team code.
  - Transport: the value rides in `TeamPresence` and is re-gossiped when adopted.
- **Plaza:** the window controller reads the current team's schedule and pushes it into the scene, minimap and clock.

**Tech Stack:** Swift 6 SwiftPM, AppKit, SpriteKit, SwiftUI, XCTest. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-11-05-plaza-schedule-design.md` (Korean). Read it first.

**Starting point:** this branch already has commit fba86dc. It fixes core time at 10–16 with one-hour glows and rotates the weather daily (`PlazaWeather.cycle`, `dayNumber`). This plan generalizes that.

## Global Constraints

- **Workspace.**
  - Work in `/Users/simu/Documents/GitHub/PokeTokenBar/.worktrees/day-weather` on branch `feat/plaza-core-time-weather`.
  - Never edit `/Users/simu/Documents/GitHub/PokeTokenBar` or the upstream repo.
- **Commits.** English Conventional Commits, ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **Text.** User-facing team text is Korean and lives only in `Sources/PokeTokenBar/Team/TeamLocalization.swift` (`testTeamSourcesHaveNoHangulLiterals`). Plaza files use Korean comments.
- **Wire.** The new presence field is optional and omitted when nil. There is no protocol bump. Unknown period strings read as `day`.
- **Value ranges.**
  - Core start is 1...22. Core end is (start + 1)...23. The defaults are 10 and 16.
  - Periods: `day`, `week` (weeks start Monday), `month`. The default is `day`.
- **Last-writer-wins rule.** A received schedule is adopted only when all of these hold:
  - its core range is valid;
  - `changedAt <= now + 600 s`;
  - it is newer than the stored one: a later `changedAt` wins, and on a tie the lexicographically greater `changedBy` wins.

  Once adopted, it is stored for the current team and re-broadcast in my presence.
- **CI compatibility.** CI compiles with Xcode 16.4 / Swift 6.1.2, and the local compiler is newer. In `@MainActor` XCTestCase subclasses, a synchronous `setUp()`/`tearDown()` may touch only `nonisolated(unsafe)` members. `NSImage` is not `Sendable` there.
- **Testing rules.**
  - Tests never open windows, call `NSApp.activate`, or pump events. Build plazas with `prepareScene()` as existing tests do.
  - Pin clocks in colour and photo tests.
- **Memory.** The machine is short on memory. Run only the focused filters each task names. The full suite runs once, in Task 3.
- **Coverage.** After any coverage run: `git checkout -- default.profraw`.

## Review Focus

1. **Lost or reverting change.** Two teammates change the schedule seconds apart. Both must end on the later one; no device may stay on the older or flip back. (Task 2)
2. **Late joiner and old peers.**
   - A teammate who was offline when the change happened must get it when they connect.
   - A presence without the field (an old version) must not reset or block anything.

   (Task 2)
3. **Fast clock.** A Mac whose clock is far ahead must not lock everyone into its value forever. (Task 2)
4. **Team switch.** Changing team code shows that team's schedule, or the default; another team's value never leaks. (Task 2)
5. **Invalid edits.** Choosing a start at or after the end, or out-of-range hours, must never produce a schedule with start ≥ end. (Task 2 clamp, Task 3 UI)

---

### Task 1: Core time and season period in the pure models

**Files:**
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaDaylight.swift`, `Sources/PokeTokenBar/Team/Plaza/PlazaWeather.swift`
- Test: `Tests/PokeTokenBarTests/PlazaDaylightTests.swift`, `Tests/PokeTokenBarTests/PlazaWeatherTests.swift`

**Interfaces (Produces):**
```swift
struct PlazaCoreTime: Equatable, Sendable {
    let start: Int, end: Int               // hours
    static let standard = PlazaCoreTime(start: 10, end: 16)!
    init?(start: Int, end: Int)            // nil unless 1 <= start, start < end, end <= 23
}
extension PlazaDaylight {
    static func tint(minute: Double, core: PlazaCoreTime = .standard) -> Tint
    static func minimapSaturation(minute: Double, core: PlazaCoreTime = .standard) -> Double
    static func phase(minute: Double, core: PlazaCoreTime = .standard) -> Phase
    @MainActor static func clockText(_ date: Date, calendar: Calendar = .current, core: PlazaCoreTime = .standard) -> String
}
extension PlazaWeather {
    enum Period: String, CaseIterable, Sendable { case day, week, month }
    static func kind(on date: Date, calendar: Calendar = .current, period: Period = .day) -> Kind
}
```
- **Daylight keys** for core `s…e`, in minutes: `(0, night) ((s-1)*60, night) ((s-1)*60+30, dawn) (s*60, none) (e*60, none) (e*60+30, dusk) ((e+1)*60, night) (1440, night)`. `look()` must tolerate zero-length segments, for example `s = 1` or `e = 23` gives duplicate minutes; never divide by zero.
- **Phase:** dawn `[(s-1)h, s h)`, day `[s h, e h)`, dusk `[e h, (e+1)h)`, otherwise night.
- **Weather period numbers:**
  - day: `dayNumber`;
  - week: `floorDiv(dayNumber + 3, 7)`, so weeks start Monday (1970-01-01 was a Thursday);
  - month: `year * 12 + month - 1`.

  Each is reduced mod 4 into `cycle`.

- [ ] **Step 1: Failing tests.**
  - Existing daylight and weather tests stay unchanged; they use the default core and period.
  - Add to `PlazaDaylightTests`:
    - `testCustomCoreTimeMovesTheGlows`: with core 9–18:
      - `tint(8*60+30) == dawn`, `tint(9*60) == .none`, `tint(18*60+30) == dusk`, `tint(19*60) ≈ night`, `tint(8*60) == night`;
      - phases: 8:00 dawn, 9:00 day, 17:59 day, 18:00 dusk, 19:00 night.
    - `testEdgeCoreTimesStayInsideTheDay`: core 1–23 and 1–2. No NaN, every minute finite. For 1–23, `tint(0)` is night, `tint(30) == dawn` and `tint(23*60+30) == dusk`.
    - `testCoreTimeRejectsBadRanges`: `PlazaCoreTime(start: 0, end: 5)`, `(5, 5)`, `(6, 5)` and `(22, 24)` are nil; `(22, 23)` and `(1, 2)` are valid.
    - `testClockTextUsesTheCoreTime`: core 9–18, 08:30 → "아침 08:30", 17:30 → "낮 17:30".
  - Add to `PlazaWeatherTests`:
    - `testWeeklyPeriodChangesOnMonday`: 2026-11-09 (Mon) to 2026-11-15 (Sun) share one kind; 11-08 (Sun) and 11-16 (Mon) differ from it.
    - `testMonthlyPeriodChangesOnTheFirst`: all of November 2026 is one kind, and Oct 31 and Dec 1 differ from it.
    - `testEveryPeriodShowsLeavesOn20261105`.
    - `testConsecutivePeriodsDiffer`: 30 consecutive weeks and 24 consecutive months, each different from the previous.
- [ ] **Step 2:** Run `swift test --filter "PlazaDaylightTests|PlazaWeatherTests"` and expect compile failures.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `swift test --filter "PlazaDaylightTests|PlazaWeatherTests|PlazaCampfire|PlazaPhotoTests|TeamLocalizationTests"` and expect it to pass.
- [ ] **Step 5:** Commit `feat(team): let the plaza core time and weather period vary`.

### Task 2: The shared schedule (storage, wire, sync)

**Files:**
- Create: `Sources/PokeTokenBar/Team/PlazaSchedule.swift`
- Modify: `Sources/PokeTokenBar/Team/TeamWire.swift` (`TeamPresence`), `Sources/PokeTokenBar/Team/TeamSettings.swift`, `Sources/PokeTokenBar/Team/TeamSession.swift` (`makePresence`, `.presence` handling, `applySettings`)
- Test: `Tests/PokeTokenBarTests/TeamWireTests.swift`, `Tests/PokeTokenBarTests/TeamSettingsTests.swift`, `Tests/PokeTokenBarTests/TeamSessionTests.swift`. Use its two- and three-node `FakeTransportHub` patterns.

**Interfaces (Consumes):** `PlazaCoreTime`, `PlazaWeather.Period` (Task 1).
**Interfaces (Produces):**
```swift
struct PlazaSchedule: Codable, Equatable, Sendable {
    var coreStart: Int, coreEnd: Int
    var seasonPeriod: String            // "day" | "week" | "month"; unknown reads as .day
    var changedAt: Date
    var changedBy: String               // member ID
    var changedByName: String           // nickname at the time
    var coreTime: PlazaCoreTime { get } // .standard when the stored range is invalid
    var period: PlazaWeather.Period { get }
    func isNewer(than other: PlazaSchedule?) -> Bool
}
// TeamPresence
var schedule: PlazaSchedule?            // omitted when nil
// TeamSettings (persisted as JSON under "team.schedules", keyed by the normalized team code)
var schedule: PlazaSchedule? { get }    // the current team's, nil when never changed or no team
func changeSchedule(coreStart: Int, coreEnd: Int, period: PlazaWeather.Period, now: Date)  // clamps: start into 1...22, end into (start+1)...23
@discardableResult func adoptSchedule(_ s: PlazaSchedule, now: Date) -> Bool               // the LWW rule; true when stored
```
- `changeSchedule` does nothing when there is no team code.
- `TeamSession`:
  - `makePresence()` includes `settings.schedule`.
  - On `.presence`, if `presence.schedule` is present and `settings.adoptSchedule(_, now: clock())` returns true, broadcast my presence.
  - `applySettings()`, when running and the code is unchanged, also broadcasts presence when `settings.schedule` differs from the last sent value, in the same way as `sentNickname`/`sentNameColor`.

- [ ] **Step 1: Failing tests.**
  - **Wire:**
    - presence without a schedule has no `schedule` key;
    - a round trip keeps every field;
    - a JSON with `"seasonPeriod":"season"` decodes and reads `.day`.
  - **Settings:**
    - `changeSchedule` stamps `changedAt`, `changedBy` and `changedByName`;
    - it clamps, so (16, 10) gives 16–17, (0, 30) gives 1–23 and (23, 23) gives 22–23;
    - it persists across a new `TeamSettings` on the same defaults;
    - values are kept per team code, and switching code returns the other team's value or nil;
    - `adoptSchedule` takes newer, ignores older, breaks ties by `changedBy`, rejects `changedAt > now + 600` and rejects an invalid core range.
  - **Session, two nodes:**
    - A changes, and B's `settings.schedule == A's`.
    - B makes an older change via `adoptSchedule` with an older stamp, which is not adopted, and A stays.
    - Both change a second apart, and both end on the later one.
  - **Session, three nodes:** C connects after A changed, and C gets the value.
  - **Session, old peer:** a peer whose presence has no schedule leaves mine unchanged.
- [ ] **Step 2:** Run `swift test --filter "TeamWireTests|TeamSettingsTests|TeamSessionTests"` and expect failures.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run the same filter, plus `PlazaGroupPhotoTests|PlazaFocusTests|TeamRuntimeTests`, which share presence. Expect it to pass.
- [ ] **Step 5:** Inject defects and check each one fails a test:
  - drop the tie-break;
  - drop the +600 s guard;
  - drop the re-broadcast after adopt (the three-node test should fail).

  Revert each after checking.
- [ ] **Step 6:** Commit `feat(team): share the plaza schedule with the whole team`.

### Task 3: Plaza wiring, settings UI, docs, full gate

**Files:**
- Modify:
  - `Sources/PokeTokenBar/Team/Plaza/PlazaScene.swift`: `var coreTime: PlazaCoreTime`, `var weatherPeriod: PlazaWeather.Period`, `daylightTint`, and the `weatherLayer.update` call;
  - `PlazaWeatherLayer.swift`: `update(... period:)`, with the cache keyed by day interval and period;
  - `PlazaMinimap.swift`: `PlazaMinimapModel.coreTime`;
  - `UI/PlazaMinimapView.swift`;
  - `UI/PlazaClockView.swift`: `PlazaClock(model: PlazaMinimapModel)`;
  - `PlazaWindowController.swift`: init `schedule: @escaping () -> PlazaSchedule? = { nil }`, and `func applySchedule()` called from `prepareScene` and by the runtime;
  - `TeamRuntime.swift`: `observeSettings` tracks `settings.schedule` and calls `plaza?.applySchedule()`;
  - `PokeTokenBarApp.swift`: pass `schedule: { teamSettings.schedule }`;
  - `UI/TeamSettingsSection.swift`;
  - `TeamLocalization.swift`;
  - `TEAM.md`.
- Test: a new `Tests/PokeTokenBarTests/PlazaScheduleWiringTests.swift`, plus updates where signatures changed.

**Settings UI (spec §3.4):**
- Two hour pickers labelled with `L` strings such as "10시".
  - The start options are 1...22.
  - The end options are (start + 1)...23.
  - Changing the start calls `changeSchedule` with the current end, and the clamp pushes the end when needed.
- A segmented period picker.
- A caption: "모든 팀원에게 같이 적용돼요 · 앞뒤 1시간은 노을이 져요" when there is no schedule, otherwise "모든 팀원에게 같이 적용돼요 · {name}님이 {M월 d일 HH:mm}에 바꿨어요".

- [ ] **Step 1: Failing tests.**
  - `applySchedule` with core 9–18 makes a scene at 08:30 show the dawn tint; with nil, 08:30 is night.
  - With period `week`, `scene.weatherKind` on 2026-11-09 equals the kind on 2026-11-15.
  - The minimap model gets the core time.
  - A runtime test: changing `settings.changeSchedule` while the plaza scene exists updates the scene's `coreTime` without reopening. Follow `TeamRuntimeTests`' setup.
  - Localization strings are exact.
- [ ] **Step 2:** Run the new filter and expect failures. **Step 3:** Implement.
- [ ] **Step 4:** Update TEAM.md:
  - the clock row: time table in terms of core time, default 10–16;
  - the weather row: the rotation, period choices and default;
  - a new row on the shared setting: anyone can change it, everyone follows the latest change, the settings caption shows who changed it, and teammates on v2.5.617 or earlier keep their own fixed schedule.
- [ ] **Step 5:** Run `scripts/test-gate.sh` once (the full suite with coverage). Then run `git checkout -- default.profraw`.
- [ ] **Step 6:** Commit `feat(team): set the plaza schedule from team settings`.
