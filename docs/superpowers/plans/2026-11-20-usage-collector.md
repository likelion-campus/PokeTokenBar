# Usage Collector (App Side) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every app with the team feature on sends its daily token counts and weekly plan limits to the company usage sheet about once an hour, on the Mac and on Windows, and says so in Settings and TEAM.md.

**Architecture:**
- All logic lives in a new shared folder, `Sources/PokeTokenBar/Team/UsageReport/`. Windows builds it like any other shared file.
- **Wire** (`UsageReportWire.swift`): the JSON body from `tools/usage-sheet/CONTRACT.md`, the IDs, and the response parser.
- **Ledger** (`UsageReportLedger.swift`): what the device remembers in `UserDefaults`:
  - the device secret and the first day;
  - the periods with the team feature off;
  - the time spent per day per team;
  - what was already sent.
- **Planner** (`UsageReportPlanner.swift`): pure functions that turn the ledger, the store's numbers and the clock into the next body.
- **Reporter** (`UsageReporter.swift`): an `@MainActor @Observable` service.
  - It watches `TeamSettings` and keeps the ledger up to date.
  - It sends after the first refresh after launch, then roughly hourly.
  - It commits what it sent only when the sheet accepts the body.
- **Wiring:** both app delegates create one reporter and call it from their existing refresh hook.
- **Settings:** the Mac team settings and the Windows team section show one caption line.
- **Windows selftest:** a new check proves that the real POST → 302 → GET path answers JSON on WinHTTP.

**Tech Stack:** Swift 6, Foundation, `Observation`, swift-crypto (`Crypto`) or `CryptoKit` behind the existing import guard, and XCTest.

**Spec:** `docs/superpowers/specs/2026-11-16-usage-dashboard-design.md` (Korean).
- It is the binding authority. Sections 4, 4.1, 5, 6, 7, 10, 11 and 12 are the app side.
- The wire contract, `tools/usage-sheet/CONTRACT.md`, is binding for every field and limit.

## Global Constraints

**Workspace and repo**
- Work in `.worktrees/usage-collector` on branch `feat/usage-collector`.
- Never use bare `git stash`.
- Pass `--repo likelion-campus/PokeTokenBar` to every `gh` command.

**Machine rules**
- Run one `swift build` or `swift test` at a time on this Mac: `pgrep -x swift-build`, `pgrep -x swift-test` and `pgrep -x xctest` must all be empty.
- Never run a full suite while another session's release gate runs (`ps -ax | grep team-release.sh`).
- Run filtered suites only, with `swift test --filter <Class>`.

**Shared code**
- Every new source file goes under `Sources/PokeTokenBar/Team/UsageReport/` and is shared, so it is not listed in `mac-only.txt`.
- A shared file imports no Apple-only framework. It may use `#if` only in the three import-guard shapes that `SharedSourcesScanTests` allows. Copy the crypto import from `Team/TeamCode.swift:1-6`.
- Body-level platform branches are not allowed. The app delegates pass the platform string (`"mac"` / `"windows"`) and the app version in.

**Tests**
- New test files go in `Tests/PokeTokenBarTests/` and are shared, so they run on Windows too.
- Every test in an `@MainActor` test class is `async`. `SharedSourcesScanTests.testNoSynchronousMainActorTestRunsOnWindows` enforces this.
- Use only `TestDefaults.make(suite:)` for defaults, with at most 32 names per test.
- No real network. Tests inject a fake `UsageReportTransport`.
- No `Bundle.module`. Fixtures are read through `#filePath` from `tools/usage-sheet/fixtures/`.

**Privacy (spec 2, 4 and 7)**
- The body carries only the fields in CONTRACT.md.
- Never send a team code, an email address (only its domain and a one-way hash), a project path, a Mac name, cost or per-model numbers.
- The device secret goes only to the sheet. It is never sent over the team connection and never synced.
- `AppLog` lines never contain the secret, the email or the team code.

**Behaviour (spec 6)**
- A device sends only while `TeamSettings.isReady`.
- There is no switch to turn sending off, and no alert or window on failure.
- Sending never blocks the main thread.

**Provider rule:** no `== "claude_code"` style branches. Days come from looping over `ProviderSnapshot`. Limits come from one converter per limit type (Claude `LimitStatus`, Codex `CodexRateLimitStatus`).

**Process and language**
- Every new conditional branch gets a test that drives that exact branch, per the CLAUDE.md defect protocol. Look for `^0` in a `--show-regions` coverage view before calling a task done.
- Team UI text is Korean and lives only in `Team/TeamLocalization.swift`; `TeamLocalizationTests` checks this.
- Identifiers, comments and commits are in English. Commits follow Conventional Commits and end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Pinned values (use verbatim)

```swift
enum UsageReportConfig {
    static let endpoint = URL(string: "https://script.google.com/macros/s/AKfycbxyIn2tAUC_fE_HXqLA8VpGLSPwepUZ5_QRujhGot7wF6oyeaheIZY3O8jXgVbnNSfm/exec")!
    static let token = "996c41db62671eaf62a86cf3e18202ee"   // tools/usage-sheet/src/00_config.js SHARED_TOKEN; public by design
    static let version = 1
    static let baseInterval: TimeInterval = 3600            // spec 6: about once an hour
    static let spreadWindow: TimeInterval = 600             // per-member offset in 0..<600 s
    static let presenceCap: TimeInterval = 3900             // longest gap one presence record may count
    static let retentionDays = 45                           // ledger keeps 45 days (> the 21 sent)
    static let maxLimits = 16                               // CONTRACT: limits array holds at most 16
    static let requestTimeout: TimeInterval = 30
}
// UserDefaults keys (the reporter uses the same UserDefaults instance as TeamSettings)
"usageReport.secret"      // String, 43 chars base64url (32 random bytes, no padding); made once
"usageReport.firstDay"    // String "yyyy-MM-dd"; set once, the first time isReady is seen true
"usageReport.offPeriods"  // JSON [OffPeriod]
"usageReport.dayTeams"    // JSON [DayTeamEntry]
"usageReport.sentDays"    // JSON [String: String]  day -> fingerprint
"usageReport.sentLimits"  // JSON [String: Double]  "<account>|<tool>" -> readAt (timeIntervalSince1970)
"usageReport.lastSentAt"  // Double timeIntervalSince1970
// Labels for one-way IDs (must differ from TeamCode's "poketokenbar.team.psk.v1" and "ptb-team-v1")
"poketokenbar.team.usage-id.v1"
```

**Korean copy:**
- sent: `"토큰 사용량을 회사 대시보드로 보내는 중 · 마지막으로 보낸 시각 \(l.teamScheduleDate(date))"`
- never sent: `"토큰 사용량을 회사 대시보드로 보내는 중 · 아직 보내지 않았어요"`

## Review Focus

These are the failure modes most likely to reach a person. Each one has a test in the task named after it.
1. **A day with the team off is never sent.** A user turns the team off, quits, comes back days later and turns it on again. The days fully inside that off period must never be sent, even though `recentDaily` has usage for them. Covered in Task 2 (the ledger records the off period at the moment it happens) and Task 3 (the planner skips those days).
2. **Manual refresh still reports.** With refresh set to manual (`refreshInterval == 0`), `onRefresh` rarely fires, but the hourly loop must still send. Covered in Task 4.
3. **A failed send commits nothing.** A failed send (thrown error, HTML page, `{"ok":false}`, `device_mismatch`) must not mark days or limits as sent. The next attempt sends them again. Covered in Task 4.
4. **The longest-staying team owns the day.** Switching teams mid-day gives the day to the team with the most time. Long gaps such as sleep or a quit app count for at most `presenceCap`. Covered in Task 2.
5. **WinHTTP gets JSON back from the real sheet.** The real Apps Script redirect must return JSON. Loopback tests cannot show this, so Task 6 adds a selftest against the real host.

---

### Task 1: Wire format, IDs and response

**Files:**
- Create: `Sources/PokeTokenBar/Team/UsageReport/UsageReportWire.swift`
- Test: `Tests/PokeTokenBarTests/UsageReportWireTests.swift`

**Interfaces:**
- Produces:
  - `enum UsageReportConfig`: the pinned values above.
  - `struct UsageReportBody: Encodable, Equatable`, holding `v: Int`, `token: String`, `member: Member`, `days: [Day]` and `limits: [Limit]`. Nested types:
    - `Member`: `id`, `secret`, `nickname`, `appVersion`, `platform`, all `String`.
    - `Day`: `date: String`, `team: String`, `teamLabel: String?` (encoded only when non-nil) and `tools: [Tool]`.
    - `Tool`: `tool: String` plus `input`, `output`, `cacheWrite` and `cacheRead`, all `Int`.
    - `Limit`: `tool`, `account`, `domain` and `plan` (`String`); `usedPercent: Double`; `resetsAt`, `readAt` and `team` (`String`).
  - `static func UsageReportBody.encoded(_ body: UsageReportBody) throws -> Data` encodes with `JSONEncoder`, with no `.sortedKeys` needed.
  - `static func UsageReportBody.fingerprint(_ day: Day) -> String`: the first 16 lowercase hex characters of the SHA-256 of `day` encoded with `.sortedKeys`.
  - `enum UsageReportResponse: Equatable { case accepted(days: Int, limits: Int, dropped: Int), rejected(String), notJSON }` and `static func parse(_ data: Data) -> UsageReportResponse`.
  - `enum UsageReportIDs` with these functions:
    - `static func account(email: String?, memberID: String, localAccountID: String) -> String`
    - `static func domain(email: String?) -> String`
    - `static func isoUTC(_ date: Date) -> String`, in the format `yyyy-MM-dd'T'HH:mm:ss'Z'` in UTC
  - `extension TeamCode { var usageTeamID: String }`.

- [ ] **Step 1: Write the failing tests** in `UsageReportWireTests` (a plain `XCTestCase`, not `@MainActor`). The tests:
  - `testTheBodyMatchesTheValidBasicFixture` and `testTheBodyMatchesTheTwoAccountsFixture`:
    - Load `tools/usage-sheet/fixtures/<name>.json` through `URL(fileURLWithPath: #filePath)` (three `deletingLastPathComponent()` calls up to the repo root).
    - Build the same `UsageReportBody` by hand from the fixture's values.
    - Assert `NSDictionary(dictionary: encodedObject).isEqual(to: fixture["body"])`, comparing objects parsed with `JSONSerialization`.
  - `testANilTeamLabelIsLeftOut`: the encoded day has no `teamLabel` key.
  - `testTheAccountIDHashesTheLowercasedEmail`: `account(email: "Someone@LikeLion.net", memberID: "M", localAccountID: "default") == "e_ad270506b0f3b0f7"`.
  - `testAnUnknownEmailFallsBackToMemberAndLocalID`:
    - `account(email: nil, memberID: "8F1C2A4E-3B5D-4C6E-9A7B-1D2E3F4A5B6C", localAccountID: "default") == "m_8F1C2A4E-3B5D-4C6E-9A7B-1D2E3F4A5B6C_default"`.
    - An empty or whitespace email behaves the same.
  - `testTheDomainIsTheLowercasedPartAfterTheAt`: `"A@LikeLion.NET"` gives `"likelion.net"`, and `nil` or `"no-at"` gives `""`.
  - `testTheTeamIDIsStableOneWayAndNotThePSK`. For two generated codes:
    - the ID matches `^t_[0-9a-f]{16}$` and the CONTRACT team regex `^t_[A-Za-z0-9_-]{2,62}$`;
    - the same code gives the same ID;
    - different codes give different IDs;
    - the ID's hex differs from the first 16 hex characters of `pskKey`'s bytes.
  - `testTheResponseParser`:
    - `{"ok":true,"accepted":{"days":2,"limits":1},"dropped":0}` gives `.accepted(2,1,0)`.
    - `{"ok":false,"error":"device_mismatch"}` gives `.rejected("device_mismatch")`.
    - `<html>…` gives `.notJSON`.
    - `{"ok":true}`, which is missing `accepted`, gives `.notJSON`.
  - `testIsoUTCDropsFractionsAndUsesZ`: `Date(timeIntervalSince1970: 1_795_078_800.4)` gives `"2026-11-19T09:00:00Z"`.
- [ ] **Step 2: Run** `swift test --filter UsageReportWireTests`. Expected: the build fails because the types don't exist yet.
- [ ] **Step 3: Implement** `UsageReportWire.swift`.
  - Team ID: `"t_"` + the first 16 hex characters of `HMAC<SHA256>.authenticationCode(for: Data("poketokenbar.team.usage-id.v1".utf8), using: SymmetricKey(data: Data(normalized.utf8)))`. This is the `pskKey` construction with a different label.
  - Account: `"e_"` + the first 16 hex characters of `SHA256(email.trimmed.lowercased())`. The fallback is `"m_" + memberID + "_" + localAccountID`.
- [ ] **Step 4: Run** the same filter. Expected: all pass.
- [ ] **Step 5: Commit** `feat(usage-report): add the wire format, one-way IDs and response parser`.

### Task 2: The on-device ledger

**Files:**
- Create: `Sources/PokeTokenBar/Team/UsageReport/UsageReportLedger.swift`
- Test: `Tests/PokeTokenBarTests/UsageReportLedgerTests.swift`

**Interfaces:**
- Consumes: `UsageReportConfig` (Task 1).
- Produces `@MainActor final class UsageReportLedger`:
  - `init(defaults: UserDefaults, timeZone: TimeZone = .current)`.
  - `var secret: String { get }` makes the secret on first read and stores it.
  - `var firstDay: String? { get }` and `func markReady(now: Date)`. The first call sets `firstDay` to the local day of `now`; later calls change nothing.
  - `func teamTurnedOff(now: Date)` and `func teamTurnedOn(now: Date)`. Turning off opens an off period unless one is already open; turning on closes the open one.
  - `var offPeriods: [OffPeriod] { get }`, where `struct OffPeriod: Codable, Equatable { var start: Date; var end: Date? }`.
  - `func recordPresence(now: Date, team: TeamStamp?)`, where `struct TeamStamp: Equatable { let id: String; let label: String }`.
    - The time since the previous call, capped at `presenceCap`, goes to the team given in the previous call, on the local day of `now`.
    - The anchor (the previous time and team) is kept in memory only. The first call after init counts nothing.
  - `var dayTeams: [DayTeamEntry] { get }`, where `struct DayTeamEntry: Codable, Equatable { var day: String; var team: String; var label: String; var seconds: Double }`.
  - `static func dominantTeam(on day: String, in entries: [DayTeamEntry]) -> TeamStamp?` returns the team with the most seconds that day. A tie goes to the smaller team ID. A day with no entries returns nil.
  - `var sentDays: [String: String] { get }`, `var sentLimits: [String: Double] { get }`, and `var lastSentAt: Date? { get }`.
  - `func commit(days: [String: String], limits: [String: Double], at: Date)` merges into the sent maps, sets `lastSentAt` and prunes.
  - `func prune(now: Date)` drops these entries older than `retentionDays` before today: `dayTeams` and `sentDays` by day, and off periods whose end is that old.

- [ ] **Step 1: Write the failing tests.** Use `@MainActor final class UsageReportLedgerTests`, all tests `async`, with defaults from `TestDefaults.make(suite:)` and `TimeZone(identifier: "Asia/Seoul")!`. The tests:
  - `testTheSecretIsMadeOnceAndMatchesTheContract`: it matches `^[A-Za-z0-9_-]{32,128}$`, and a second ledger on the same defaults reads the same value.
  - `testTheFirstDayIsSetOnce`
  - `testTurningOffTwiceKeepsOnePeriodAndTurningOnClosesIt`
  - `testPresenceGoesToThePreviousTeamAndIsCapped` covers both halves of the rule:
    - Calls at t0 with team A, then t0+600 with team B, then t0+700 with team B give A 600 s and B 100 s.
    - A later call after a 10-hour gap adds only 3900 s.
  - `testTheFirstPresenceAfterLaunchCountsNothing`
  - `testTheDominantTeamIsTheLongestStay`
  - `testCommitMergesAndPrunesOldEntries`: an entry from 46 days ago is gone, and one from 44 days ago stays.
  - `testStateSurvivesANewLedgerOnTheSameDefaults`
- [ ] **Step 2: Run** `swift test --filter UsageReportLedgerTests`. Expected: fail.
- [ ] **Step 3: Implement.**
  - The secret is 32 bytes from `SystemRandomNumberGenerator`, base64url without padding.
  - Days are formatted with `LocalUsageReader.localDayFormatter(timeZone:)`.
  - JSON goes through `JSONEncoder` / `JSONDecoder`.
- [ ] **Step 4: Run** the same filter. Expected: pass.
- [ ] **Step 5: Commit** `feat(usage-report): remember off periods, daily teams and what was sent`.

### Task 3: The planner

**Files:**
- Create: `Sources/PokeTokenBar/Team/UsageReport/UsageReportPlanner.swift`
- Test: `Tests/PokeTokenBarTests/UsageReportPlannerTests.swift`

**Interfaces:**
- Consumes: Task 1 types, plus `OffPeriod`, `TeamStamp`, `DayTeamEntry` and `UsageReportLedger.dominantTeam(on:in:)` from Task 2.
- Produces `enum UsageReportPlanner`:
  - `static func tools(from snapshots: [ProviderSnapshot]) -> [String: [UsageReportBody.Tool]]`.
    - For each snapshot, each `recentDaily` entry with any of the four counts above 0 becomes `Tool(tool: providerID, input:, output:, cacheWrite: cacheCreationTokens, cacheRead: cacheReadTokens)` under its `date`.
    - Each day's tools are sorted by `tool`.
  - `static func dayRange(now: Date, timeZone: TimeZone, firstDay: String?) -> [String]` returns the days from `max(firstDay, today − 20)` through today, oldest first. With `firstDay == nil` it returns `[]`.
  - `static func isFullyOff(_ day: String, periods: [OffPeriod], now: Date, timeZone: TimeZone) -> Bool` is true when one period covers the whole local day, from `startOfDay` to the next `startOfDay`. An open period counts as ending at `now`.
  - `static func days(range: [String], tools: [String: [UsageReportBody.Tool]], dayTeams: [DayTeamEntry], current: TeamStamp, offPeriods: [OffPeriod], now: Date, timeZone: TimeZone) -> [UsageReportBody.Day]`:
    - It skips fully-off days.
    - The team is the day's `dominantTeam`. Otherwise it is the dominant team of the latest earlier day that has entries, which may lie before `range` (the ledger keeps 45 days). Otherwise it is `current`.
    - `teamLabel` is nil when the label is empty.
    - A day without tools gets `tools: []`.
  - `static func changed(_ days: [UsageReportBody.Day], sent: [String: String]) -> [UsageReportBody.Day]` keeps the days whose `fingerprint` differs from `sent[date]`.
  - `static func claudeLimit(_ account: ClaudeAccountLimits, memberID: String, team: String) -> (key: String, readAt: Double, limit: UsageReportBody.Limit)?`:
    - It returns nil when the account `isExpired`, when `updatedAt` is nil, when there is no plan (`status.planDisplay` trimmed, empty), or when there is no weekly window.
    - Weekly window: `status.sevenDay` when both `utilization` and `resetDate` are set. Otherwise the first `status.limits` entry with `kind == "weekly_all"` whose `percent` and `resetDate` are set.
    - Fields:
      - `tool` is `"claude"`.
      - `account` is `UsageReportIDs.account(email: status.accountEmail, memberID:, localAccountID: account.id)`.
      - `domain` comes from the email.
      - `plan` is truncated to 40 characters.
      - `key` is `"\(account)|claude"`.
  - `static func codexLimit(_ status: CodexRateLimitStatus?, readAt: Date?, memberID: String, team: String) -> (key: String, readAt: Double, limit: UsageReportBody.Limit)?`:
    - The window is the first of `rateLimits.primary` and `.secondary` whose `windowSpan == LimitWindowSpan.sevenDay`, with a `resetDate`.
    - `plan` is the raw `rateLimits.planType`. It returns nil when `planType` is nil or empty.
    - `tool` is `"codex"`, and `account` is `account(email: nil, memberID:, localAccountID: "codex")`.
  - `static func newLimits(_ candidates: [(key: String, readAt: Double, limit: UsageReportBody.Limit)], sent: [String: Double]) -> [(key: String, readAt: Double, limit: UsageReportBody.Limit)]` keeps the candidates whose `readAt` is greater than `sent[key] ?? -1`. Then `prefix(UsageReportConfig.maxLimits)`.
  - `static func sendInterval(memberID: String) -> TimeInterval` returns `baseInterval` plus the first two bytes of `SHA256(memberID)`, read as a `UInt16`, mod 600. The result is in [3600, 4200).

- [ ] **Step 1: Write the failing tests.** Use a plain `XCTestCase`, the Seoul time zone and a fixed `now` of `2026-11-16T03:00:00Z`. The tests:
  - `testToolsComeFromEverySnapshotAndSkipZeroDays`: two snapshots, `claude_code` and `codex`, where one day is zero for codex.
  - `testTheRangeStartsAtTheFirstDayAndCoversAtMost21Days`: with `firstDay` today the range is `["2026-11-16"]`; with `firstDay` 30 days ago it has 21 days; with nil it is empty.
  - `testADayInsideATeamOffPeriodIsNotSent` (**Review Focus 1**):
    - A period from 2026-11-12 18:00 KST to 2026-11-15 09:00 KST skips 11-13 and 11-14 and keeps 11-12 and 11-15.
    - An open period that starts 11-14 00:00 KST skips 11-14 and 11-15. It keeps 11-16, because that day is not fully covered by `now`.
  - `testADayWithoutRecordsUsesTheNearestEarlierTeamElseTheCurrent`: include an earlier record 25 days back, outside the range.
  - `testAnEmptyLabelIsLeftOutAndADayWithoutUsageHasNoTools`
  - `testOnlyChangedDaysAreKept`: also, a day whose tool list changed counts as changed.
  - `testTheClaudeLimitUsesSevenDayThenWeeklyAllAndSkipsExpired`. This covers each nil branch:
    - expired;
    - no `updatedAt`;
    - no plan;
    - no weekly data in either source.
  - `testTheCodexLimitPicksTheSevenDayWindow`: the primary window is 300 minutes and the secondary 10080. Also nil when `planType` is nil.
  - `testLimitsAreSentOnlyWhenReadAgainAndCappedAt16`
  - `testTheSendIntervalIsStableAndWithinTheSpread`
- [ ] **Step 2: Run** `swift test --filter UsageReportPlannerTests`. Expected: fail.
- [ ] **Step 3: Implement.** Build `ClaudeAccountLimits`, `LimitStatus` and `CodexRateLimitStatus` test values through their memberwise or decode initializers. If a type has none, decode it from a small JSON literal.
- [ ] **Step 4: Run** the same filter. Expected: pass.
- [ ] **Step 5: Commit** `feat(usage-report): plan which days and limits to send`.

### Task 4: The reporter service

**Files:**
- Create: `Sources/PokeTokenBar/Team/UsageReport/UsageReporter.swift`
- Test: `Tests/PokeTokenBarTests/UsageReporterTests.swift`

**Interfaces:**
- Consumes: Tasks 1–3, plus `TeamSettings` (`isReady`, `code`, `currentTeam?.name`, `nickname`, `memberID` and `TeamSettings.validNickname`).
- Produces:
  - `protocol UsageReportTransport: Sendable { func post(_ body: Data) async throws -> Data }`.
  - `struct HTTPUsageReportTransport: UsageReportTransport`. It sends a POST to `UsageReportConfig.endpoint` with the header `Content-Type: application/json` and `timeoutInterval: requestTimeout`, through `PlatformCompat.oneShotData(for:)`. It returns the body whatever the status; the Mac's URLSession and `WinHTTPFetch.nextHop` both turn the 302 into a GET.
  - `struct UsageReportInputs`, holding `snapshots: [ProviderSnapshot]`, `claudeAccounts: [ClaudeAccountLimits]`, `codex: CodexRateLimitStatus?` and `codexReadAt: Date?`. It has `@MainActor static func from(_ store: UsageStore) -> UsageReportInputs`.
  - `@MainActor @Observable final class UsageReporter`:
    - `init(settings: TeamSettings, defaults: UserDefaults, appVersion: String, platform: String, inputs: @escaping @MainActor () -> UsageReportInputs, transport: any UsageReportTransport = HTTPUsageReportTransport(), now: @escaping @MainActor () -> Date = Date.init, timeZone: TimeZone = .current)`.
    - `private(set) var lastSentAt: Date?` is mirrored from the ledger for the UI.
    - Presence is always recorded with the current team's `TeamStamp(id: code.usageTeamID, label: currentTeam?.name ?? "")` when the team is ready, and with `nil` when it isn't. Time with the team off therefore belongs to no team.
    - `func start()`:
      - It calls `recordPresence`. When the team is ready it calls `teamTurnedOn` (closing any period left open) and `markReady`; otherwise it calls `teamTurnedOff`.
      - It begins observing `settings` with `withObservationTracking` on `isReady` and `code`, re-armed the way `TeamRuntime.observeSettings` does it.
      - It starts the hourly loop when the team is ready.
    - `func storeRefreshed()`: `recordPresence`, then `maybeSend()`.
    - `func tick() async`: `recordPresence`, then `await maybeSend()`. This is what one pass of the hourly loop does, and tests call it directly.
    - `var isLoopRunning: Bool { get }`, for tests.
  - Rules (spec 6):
    - **On a change:**
      - Before a change is applied (`onChange` fires while the old values are still current), record presence for the old team.
      - After it, when the team became not ready, call `teamTurnedOff` and stop the loop. When it became ready, call `teamTurnedOn` and `markReady`, then start the loop.
    - **Loop:**
      - It sleeps `sendInterval(memberID:)` with `Task.sleep(for:tolerance: .seconds(60))`.
      - It holds `self` weakly while it sleeps and takes it back after waking, per defect-log 동시성.
    - **When to send:** `maybeSend` sends only when all of these hold:
      - `settings.isReady`;
      - `TeamSettings.validNickname(settings.nickname)` is non-nil;
      - no send is in flight;
      - no attempt was made this launch, or `now − lastAttemptAt ≥ sendInterval`.
      The first refresh after launch therefore sends at once.
    - **Building the body:**
      - Days are `changed(days(...), sent: ledger.sentDays)`.
      - Limits are `newLimits(...)` from the Claude accounts and Codex.
      - Every row carries the current `code.usageTeamID` as its team.
      - `member.nickname` is the valid nickname.
      - The body is sent even when `days` and `limits` are both empty. The sheet's 사람 tab then shows the app is alive. **[planner's call]**
    - **Results:**
      - `.accepted`: `ledger.commit` with the fingerprints of the days sent and the `readAt` of the limits sent. Update `lastSentAt`. Log `AppLog.write("usage report sent: days=\(n) limits=\(m) dropped=\(d)")`.
      - `.rejected(code)`: log `usage report rejected: \(code)` and commit nothing.
      - `.notJSON` or a thrown error: log the failure and commit nothing.
      - In all three cases `lastAttemptAt = now`.

- [ ] **Step 1: Write the failing tests.**
  - Use `@MainActor final class UsageReporterTests`, all `async`.
  - The fake transport is an actor that records bodies and returns queued answers.
  - The settings are a real `TeamSettings(defaults:)` with a generated code, `isEnabled = true` and a nickname.
  - The clock is a mutable `Date` captured by the `now` closure.
  - The tests:
    - `testTheFirstRefreshAfterLaunchSendsAndTheNextOneWaits`: the second `storeRefreshed()` 2 minutes later sends nothing.
    - `testTheHourlyTickSendsWithoutAnyRefresh` (**Review Focus 2**): no `storeRefreshed` call, then `tick()` after `sendInterval` sends.
    - `testNothingIsSentWhileTheTeamIsOff`
    - `testTurningTheTeamOffAndOnRecordsThePeriodAndTheLoop`. This checks the ledger's off period and `isLoopRunning` false and then true. Use a short `yield` loop with a 2-second deadline for the observation callback; it is not a sleep.
    - `testAFailedSendCommitsNothingAndTheNextAttemptResends` (**Review Focus 3**). Run it once each for a thrown error, `.notJSON`, `rejected("device_mismatch")` and `rejected("bad_member")`, and assert:
      - `sentDays` is unchanged;
      - `lastSentAt` is unchanged;
      - after `sendInterval` the same days go out again.
    - `testAnAcceptedSendCommitsAndUnchangedDaysAreNotResent`
    - `testTheBodyCarriesNoTeamCodeOrEmail`: search the encoded body for the code's `normalized` string and for the test email `someone@likelion.net`.
    - `testTheTeamSwitchMidDayGoesToTheLongerTeam` (**Review Focus 4**, end-to-end through the reporter).
- [ ] **Step 2: Run** `swift test --filter UsageReporterTests`. Expected: fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the same filter. Expected: pass. Then run `swift test --filter UsageReport` to cover all four files, and check `--show-regions` on the four sources for `^0` branches.
- [ ] **Step 5: Commit** `feat(usage-report): send hourly while the team feature is on`.

### Task 5: Wiring and the settings line on both systems

**Files:**
- Modify:
  - `Sources/PokeTokenBar/PokeTokenBarApp.swift` (Mac `AppDelegate`)
  - `Sources/PokeTokenBar/Platform/Windows/WindowsApp.swift`
  - `Sources/PokeTokenBar/Platform/Windows/Popover/WinPopoverHost.swift`
  - `Sources/PokeTokenBar/Platform/Windows/Popover/WinTeamSection.swift`
  - `Sources/PokeTokenBar/Team/UI/TeamSettingsSection.swift`
  - `Sources/PokeTokenBar/Team/TeamLocalization.swift`
  - `Sources/PokeTokenBar/Popover/SettingsModel.swift`
- Test: `Tests/PokeTokenBarTests/SettingsModelTests.swift`

**Interfaces:**
- Consumes: `UsageReporter` (Task 4).
- Produces:
  - `L.teamUsageReportCaption(lastSent: Date?) -> String`, which returns the pinned Korean copy.
  - `@MainActor static func SettingsModel.usageReportCaption(lastSent: Date?, l: L = L(.ko)) -> String`.

- [ ] **Step 1: Write the failing tests** in `SettingsModelTests`, all `async`:
  - `testTheUsageReportCaptionSaysNotYetBeforeTheFirstSend`, which compares against the exact pinned string.
  - `testTheUsageReportCaptionShowsTheLastSendTime`, which compares against the pinned string built with `l.teamScheduleDate(date)`.
- [ ] **Step 2: Run** `swift test --filter SettingsModelTests`. Expected: fail.
- [ ] **Step 3: Implement.**
  - **Mac `AppDelegate`:**
    - Create `usageReporter = UsageReporter(...)` after `teamRuntime.start()`.
    - Pass these arguments:
      - `settings: teamSettings`
      - `defaults: TeamSettings.defaultStore()`
      - `appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"`
      - `platform: "mac"`
      - `inputs: { [unowned self] in UsageReportInputs.from(self.store) }` (the delegate lives as long as the app)
    - Call `start()`. Add `usageReporter.storeRefreshed()` as the last line of `onStoreRefreshed()`. Add `.environment(usageReporter)` next to `.environment(teamSettings)` (line ~695).
  - **Windows `WindowsAppDelegate`:** do the same in `launch()` after `startTeam`, with these differences:
    - `defaults: teamSettingsDefaults`
    - `appVersion: WindowsInstall.version ?? "0"`
    - `platform: "windows"`
    - Add `usageReporter.storeRefreshed()` as the last line of `storeRefreshed()`.
    - Pass `usageReporter:` into `WinPopoverHost`, as a new `let usageReporter: UsageReporter?`.
  - **Mac `TeamSettingsSection`:** add `@Environment(UsageReporter.self) private var reporter: UsageReporter?`. Inside `if team.isEnabled {`, after the `scheduleRows` block and when `team.isReady`, show `Text(SettingsModel.usageReportCaption(lastSent: reporter?.lastSentAt))` with the same font and colour as the schedule caption (`.caption`, `.secondary`).
  - **Windows `WinTeamSection`:**
    - Add `reportRow = section.addRow(nil, hint: …) { _, _ in nil }` after `captionRow`, with `reportRow.hint?.role = .secondary`.
    - In `apply()`, set `reportRow.isVisible = team.isReady`, then `set(reportRow.hint, SettingsModel.usageReportCaption(lastSent: host.usageReporter?.lastSentAt))`.
    - This matches the Mac: same text, same place, no difference to list in `docs/reference/windows-differences.md`.
- [ ] **Step 4: Verify.**
  - `swift test --filter SettingsModelTests` passes.
  - `swift test --filter TeamLocalizationTests` passes.
  - `swift test --filter SharedSourcesScanTests` passes.
  - `swift test --filter AppWiringDriftScanTests` passes.
  - `scripts/shared-check.sh` builds.
  - Windows compiles only on CI. Read `WindowsSelftestSettings.swift` for row-count or row-order assertions that a new row would break, and update them in the same commit.
- [ ] **Step 5: Commit** `feat(usage-report): start the reporter on both systems and show it in team settings`.

### Task 6: Windows selftest for the real redirect

**Files:**
- Create:
  - `Sources/PokeTokenBar/Team/UsageReport/UsageReportProbe.swift` (shared, pure)
  - `Sources/PokeTokenBar/Platform/Windows/WindowsSelftestUsageReport.swift` (`#if os(Windows)`)
- Modify: `Sources/PokeTokenBar/Platform/Windows/WindowsSelftest.swift`. Register the check next to `clientCertificateCheck` (line ~95).
- Test: `Tests/PokeTokenBarTests/UsageReportProbeTests.swift` (shared)

**Interfaces:**
- Produces:
  - `enum UsageReportProbe`:
    - `static let body = Data(#"{"v":0}"#.utf8)`. This is answered with `bad_version` before any lock or write (`20_store.js` `handleReport`), so the probe never touches the sheet.
    - `static func classify(_ outcome: Result<(status: Int, body: Data), URLError>) -> (ok: Bool, detail: String)`.
  - The Windows check `net.usageReportRedirect` follows the model of `WindowsSelftestClientCertificate.swift`:
    - It is skipped when `!PlatformCompat.isBundledApp`.
    - It sends one POST of `UsageReportProbe.body` to `UsageReportConfig.endpoint` through `WinHTTPFetch.data(for:configuration:)`, with a 10 s request timeout and a 15 s resource deadline.
    - It records `classify(...)` with the elapsed time.
- Classify rules:
  - **Pass:** the body parses as a JSON object with a Bool `ok`.
  - **Unverified pass:** URLError codes in `WindowsSelftest.unreachableCodes`, or HTTP status ≥ 500. Detail: `unverified (<reason>)`.
  - **Fail:** any other non-JSON answer. This is what a POST that stayed a POST on the redirect would get.

- [ ] **Step 1: Write the failing tests** `testJSONPasses`, `testHTMLFails`, `testUnreachableIsUnverified` and `testServerErrorIsUnverified`.
  - The test class is a plain `XCTestCase`, so it runs on Mac and Windows.
  - Mirror the unreachable set inside `UsageReportProbe`, because `WindowsSelftest.unreachableCodes` is Windows-only. The Windows file may then use `UsageReportProbe.unreachableCodes` too.
- [ ] **Step 2: Run** `swift test --filter UsageReportProbeTests`. Expected: fail.
- [ ] **Step 3: Implement** both files and the registration.
- [ ] **Step 4: Run** the same filter (pass) and `scripts/shared-check.sh` (builds). The Windows file is checked by Windows CI.
- [ ] **Step 5: Commit** `test(windows): check that the usage report gets JSON through the real redirect`.

### Task 7: Disclosure in TEAM.md and the READMEs

**Files:**
- Modify:
  - `TEAM.md` (section `## 팀에 보이는 것과 보이지 않는 것`, lines ~203-221)
  - `README.md` (Privacy & permissions, lines ~346-349)
  - `README.ko.md` (lines ~347-349)
  - `README.ja.md` (lines ~347-349)

- [ ] **Step 1: TEAM.md.**
  - Add a new subsection right after `팀원에게 보이지 않는 것:`, titled `회사(인사팀·임원)에게 보이는 것:`. It lists:
    - **What is sent**, from spec 4 and 4.1:
      - nickname;
      - app version and system;
      - date;
      - tool;
      - the four token counts;
      - a team ID made one-way from the team code;
      - the team's name;
      - per subscription account: the plan name, the weekly usage percent, the reset time and the email domain only.
    - **Where it goes:** the company Google Sheet.
    - **Who sees it:** HR, executives and the sheet owner.
    - **What is never sent:** prompts or conversation content, project paths or names, the Mac or PC name, account names, the team code, the full email, cost or per-model numbers.
    - **That teammates still can't see each other's usage.**
    - **When it runs:** only while the team feature is on, about once an hour. Days with the feature off are never sent, even later.
    - **That there is no separate off switch.**
    - **The settings line**, quoted with its copy.
  - Change `- 토큰 사용량, 비용, 한도` to `- 토큰 사용량, 비용, 한도 (회사 대시보드로는 아래처럼 갑니다)`.
  - In the paragraph starting `접속 기록은 남기지 않고`, add one sentence. The app keeps, on this device only, which team you were in each day and for how long, so it can pick the day's department. The sheet gets only the day's team ID.
- [ ] **Step 2: READMEs (en, ko, ja).**
  - In the "On-device first" bullet, qualify the no-upload claim: in this team build, when the team feature is on, daily token counts and weekly limit percentages go to the company usage sheet, as described in TEAM.md.
  - In "Outbound requests", raise the host count by two (fifteen → seventeen). List `script.google.com` and `script.googleusercontent.com` (company usage sheet, team feature on only).
  - Keep each language's style.
- [ ] **Step 3: Verify.** Run `python3 scripts/team_docs_check.py` (exit 0, or warnings only), and grep that the three READMEs state the same count.
- [ ] **Step 4: Commit** `docs(team): tell what the usage report sends, to whom and when`.

---

## After the plan (not tasks)

- **PR:** prepare it with `prepare-pr`. Settings changed on the Mac and Windows, so the `UI changes` section needs images:
  - a Mac sample-data render of the team settings section with the new line;
  - a Windows image, either a CI capture or a labelled illustration.
- **Before rollout, on the live sheet:** run the menu item 샘플 데이터 지우기, which removes the samples and the 연결시험 test member. The live sheet's #229 script already accepts contract v1. Moving it to the #286 script stays tied to the Enterprise key.
- **Release:** the release notes must say what goes to whom (spec 10). `team_docs_check.py` will require new Mac and Windows captures, because the feat commit touches `Team/UI/`, `Platform/Windows/Popover/` and `Popover/`.
