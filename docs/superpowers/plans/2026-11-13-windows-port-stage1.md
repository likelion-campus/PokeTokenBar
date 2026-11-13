# Windows Port, Stage 1 (Shared Sources on Windows CI) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The app's logic (`Core` and the non-drawing part of `Team`) builds and passes its tests on a Windows CI runner, with a machine check that keeps it that way, while the Mac app stays byte-for-byte the same in behaviour.

**Architecture:** One Swift module, as today. On macOS `Package.swift` is unchanged in effect: every file compiles into the app. On Windows the manifest builds the same directory as a library and excludes the paths listed in `Sources/PokeTokenBar/mac-only.txt`. A scan test (run on the Mac) fails when a file outside that list imports an Apple-only framework, so the shared set can only grow. OS calls inside shared files go through small protocols in a new team-owned `Platform/` directory; the Mac implementations wrap today's code and the Windows ones are stubs until stage 4.

**Tech Stack:** Swift 6 (Mac: Xcode 16 / macOS 15 CI; Windows: `windows-latest` + Swift 6.3.x), SwiftPM, XCTest, swift-crypto (Windows only), SQLite amalgamation (Windows only), GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-11-13-windows-port-design.md` (Korean) — §4 (structure), §7 (OS services), §9.1 (experiment results), §10 step 1, §11. Experiment code to crib from: branch `spike/windows-port`, `spike/core/` and `spike/RESULTS.md`.

## Global Constraints

- **The Mac app must not change.** No behaviour, timing or UI difference. Every task ends with the full Mac suite green (`./scripts/test-gate.sh`), not a filtered run.
- Work in `.worktrees/<name>` from `origin/main`. Never edit the main checkout. No bare `git stash`. Always `--repo likelion-campus/PokeTokenBar`.
- **All Windows-port work lands on the long-lived branch `windows-port`, not `main`** (user decision, 2026-11-13, to keep it from mixing with releases). One PR per task, targeting `windows-port`, English title (Conventional Commits) and body. `main` is merged into `windows-port` at the start of every task; `windows-port` goes to `main` only when the user says so. Where a step below says "merge", it means into `windows-port`.
- The user is holding new feature work while the port is under way, so `main` should move little. If it does move, the merge into `windows-port` comes first and conflicts are resolved there.
- Windows CI does **not** block PR merges. A red Windows build blocks releases only from stage 8 on; in stage 1 it is informational, and each task still leaves it green.
- CI pair is fixed: `windows-latest` + Swift `6.3.2-RELEASE` (6.1.2 cannot build swift-crypto on that image).
- Upstream-owned files (`Sources/PokeTokenBar/Core/**`, `UI/**`, `PokeTokenBarApp.swift`, `OutsideClickMonitor.swift`) are **not moved or renamed**. Edits to them are the smallest that route an OS call through `Platform`, or a guarded import. Each PR body lists the upstream-owned lines it changed, so the next upstream sync knows where to look.
- Team-owned files (`Team/**`, the new `Platform/**`) may be moved and split freely.
- Body-level `#if os(...)` / `#if canImport(...)` is allowed **only** under `Sources/PokeTokenBar/Platform/`. Elsewhere only the three import guards below are allowed. The scan test enforces this.
- Allowed import guards in shared files, exactly these shapes:
  ```swift
  #if canImport(FoundationNetworking)
  import FoundationNetworking
  #endif
  ```
  ```swift
  #if canImport(CryptoKit)
  import CryptoKit
  #else
  import Crypto
  #endif
  ```
  ```swift
  #if canImport(SQLite3)
  import SQLite3
  #else
  import CSQLite
  #endif
  ```
- Shared files never write `import CoreGraphics`. `CGPoint`, `CGSize`, `CGRect`, `CGFloat`, `CGVector` come through `Foundation` on both systems. A file that needs `CGContext`, `CGImage`, `CGColor`, `CGPath` or CoreText is Mac-only for now (stage 2 deals with drawing).
- Tests create `UserDefaults` suites only through `TestDefaults.make(suite:)` (existing rule, enforced by a scan test).
- New plaza features keep landing from other sessions during this work. A new file that imports an Apple-only framework must be added to `mac-only.txt` in the same PR; the scan test's failure message says so.
- Defects found on the way follow the defect protocol in `CLAUDE.md` (root cause, class sweep, trigger test, `defect-log.md`).

## File Structure

```
Package.swift                                  modify: Windows branch (library + excludes), Mac branch as today
.gitattributes                                 create: LF for scripts and list files
.github/workflows/windows.yml                  create: build + test the shared set on Windows
scripts/shared-check.sh                        create: Mac-side pre-check, builds only the shared set
Sources/PokeTokenBar/mac-only.txt              create: paths (files or directories) excluded on Windows
Tests/PokeTokenBarTests/mac-only.txt           create: test files excluded on Windows
Tests/PokeTokenBarTests/SharedSourcesScanTests.swift   create: the import rule
Sources/CSQLite/                               create (Task 5): SQLite amalgamation, Windows only
Sources/PokeTokenBar/Platform/
  Platform.swift                               create: the protocols and `Platform.current`
  PlatformCompat.swift                         create: small Foundation gaps (kill, tilde path, zlib, activity)
  Mac/…                                        create: Mac implementations (listed in mac-only.txt)
  Windows/…                                    create: Windows stubs, each file wrapped in `#if os(Windows)`
```

## Review Focus

1. **A Mac regression hidden behind a protocol.** Routing notifications, sleep/wake observers or the keychain through `Platform` can change ordering or threading. → Tasks 4 and 6 each add a test that the Mac implementation is called with the same arguments, on the main actor, as before.
2. **The scan test passes while the list is wrong.** A typo in `mac-only.txt` silently excludes nothing or everything. → Task 1 tests that every listed path exists and that an injected `import AppKit` in a shared file fails the scan.
3. **Windows-only behaviour differences that tests don't see:** path separators, drive letters, `~`, case-insensitive paths, CRLF in read files. → Task 7 adds Windows-run tests for `BinaryLocator`, home-relative roots and a CRLF JSONL fixture.
4. **A stub that lies.** A Windows stub returning "ok" for keychain or notifications would make later stages think a feature works. → Task 3 fixes the stub contract: stubs return "unavailable" values and log once; a test asserts it.
5. **Uncompressed cache on Windows read back wrongly.** Task 2 turns zlib off on Windows by returning nil. → Task 2 tests the round trip through `LocalUsageCache` with compression unavailable.

---

### Task 1: Manifest split, lists, scan test, Windows CI — on the 18 files that already build

**Files:**
- Modify: `Package.swift`
- Create: `.gitattributes`, `.github/workflows/windows.yml`, `scripts/shared-check.sh`
- Create: `Sources/PokeTokenBar/mac-only.txt`, `Tests/PokeTokenBarTests/mac-only.txt`
- Test: `Tests/PokeTokenBarTests/SharedSourcesScanTests.swift`

**Interfaces:**
- Produces: `mac-only.txt` format — one path per line relative to the list's directory, `#` comments, a trailing `/` marks a directory. Produces `SharedSources.macOnly(listURL:) -> Set<String>` and `SharedSources.sharedFiles(root:listURL:) -> [URL]` as test helpers in the scan test file. Produces `scripts/shared-check.sh` (exit 0 when the shared set builds on this Mac as a library).

- [ ] **Step 1: Write the failing scan test**

```swift
final class SharedSourcesScanTests: XCTestCase {
    static let appleOnly = ["AppKit", "SwiftUI", "SpriteKit", "CoreGraphics", "CoreText", "QuartzCore", "ImageIO",
                            "UniformTypeIdentifiers", "Network", "Security", "LocalAuthentication", "ServiceManagement",
                            "UserNotifications", "Darwin", "Metal", "Combine"]

    func testEveryListedPathExists()                 // each line of both lists names an existing file or directory
    func testSharedFilesImportNothingAppleOnly()     // failure message: "<file> imports <X>. Add it to mac-only.txt, or route the call through Platform."
    func testOnlyTheThreeImportGuardsAppearOutsidePlatform()   // any other `#if os(` / `#if canImport(` in a shared file fails
    func testTheScanCatchesAnInjectedImport()        // run the scanner over a temp dir holding one file with `import AppKit` → reports it
    func testSharedSetDoesNotShrink()                // shared line count >= the number stored in `shared-floor.txt`
}
```

`CryptoKit` and `SQLite3` are allowed only inside their guard shapes.

- [ ] **Step 2: Run it, expect FAIL** (`swift test --filter SharedSourcesScanTests`): the lists don't exist.

- [ ] **Step 3: Create the lists.** `Sources/PokeTokenBar/mac-only.txt` = everything except the 18 files in `spike/core/closure-sources.txt` on the spike branch (write directories where a whole directory is Mac-only: `UI/`, `Team/UI/`). `Tests/PokeTokenBarTests/mac-only.txt` = every test file except the 14 in `spike/core/closure-tests.txt`. `shared-floor.txt` = the current shared line count.

- [ ] **Step 4: Split `Package.swift`.** Read the list in the manifest (`import Foundation`, path from `#filePath`). Under `#if os(Windows)`: a `.target` named `PokeTokenBar` (same `path`), `exclude:` from the list plus `Resources` handling as today, and the test target with its own exclude list. Otherwise: today's manifest, unchanged.

- [ ] **Step 5: `scripts/shared-check.sh`.** Builds the shared set on the Mac the way Windows will see it: copies nothing, runs `swift build` with env `PTB_SHARED_ONLY=1`, which the manifest treats like the Windows branch. Step 4's condition becomes `#if os(Windows)` **or** that env var.

- [ ] **Step 6: `.gitattributes`** — `*.sh`, `*.txt`, `*.swift`, `*.json`, `*.jsonl` as `text eol=lf`.

- [ ] **Step 7: `.github/workflows/windows.yml`.** On push to `main` and `windows-port`, and on PRs. `windows-latest`, `compnerd/gha-setup-swift` with `swift-6.3.2-release` / `6.3.2-RELEASE`, `swift build`, `swift test`, upload the log. Not a required check.

- [ ] **Step 8: Verify.** `swift test --filter SharedSourcesScanTests` → PASS. `./scripts/shared-check.sh` → exit 0. `./scripts/test-gate.sh` → green. Push the branch; the Windows run → green (expect 82 tests; record which fail and move those test files to the test list with a `# why` comment — Task 7 brings them back).

- [ ] **Step 9: Fault-inject once.** Add `import AppKit` to a shared file → scan test fails with the message from Step 1. Revert.

- [ ] **Step 10: Commit, PR `ci: build the shared sources on Windows`, merge. Tell the peer session** (SendMessage) about the scan test and what its failure asks for.

---

### Task 2: Import guards and the small Foundation gaps

**Files:**
- Create: `Sources/PokeTokenBar/Platform/PlatformCompat.swift`
- Modify: the 14 files that use `URLSession`/`URLRequest`; `Team/TeamCode.swift`, `Team/TeamSettings.swift`, `Core/ClaudeAccountRoots.swift`, `Core/CursorUsageAPI.swift` (CryptoKit guard); `Core/ProcessRunner.swift`; `Core/LocalUsageCache.swift`; `Core/UsageStore.swift:1103` and `Team/TeamRuntime.swift:190` (activity); `Core/ClaudeAccountRoots.swift:308` (tilde)
- Modify: `Package.swift` (Windows branch: swift-crypto dependency)
- Test: `Tests/PokeTokenBarTests/PlatformCompatTests.swift`

**Interfaces:**
- Produces, in `PlatformCompat.swift` (the one file besides `Platform/Windows` that may branch on OS):
  ```swift
  enum PlatformCompat {
      static func forceKill(pid: Int32)
      static func abbreviatingWithTilde(_ path: String) -> String
      static func zlibCompressed(_ data: Data) -> Data?      // nil when unavailable (Windows)
      static func zlibDecompressed(_ data: Data) -> Data?    // nil when unavailable or not zlib
      static func beginActivity(reason: String) -> AnyObject?   // nil on Windows
      static func endActivity(_ token: AnyObject?)
  }
  ```

- [ ] **Step 1: Failing tests.** `testTildeAbbreviatesTheHomeDirectory`, `testZlibRoundTripsWhereAvailable`, `testCacheRoundTripsWhenCompressionIsUnavailable` (drive `LocalUsageCache` save/load with a seam that makes `zlibCompressed` return nil; the loaded entries equal the saved ones), `testForceKillEndsARunningChild`.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement** `PlatformCompat`, then replace the six call sites. Before relying on "nil means store raw", read `LocalUsageCache.swift:559` and `:658` and confirm both already fall back; if `:658` does not, add the fallback and say so in the PR.
- [ ] **Step 4: Add the three import guards** where needed and remove those files from `mac-only.txt`. Run `./scripts/shared-check.sh` after each batch.
- [ ] **Step 5: Verify** — new tests PASS, `test-gate.sh` green, Windows run green, `shared-floor.txt` raised.
- [ ] **Step 6: Commit, PR `refactor: guard imports and Foundation gaps for the shared build`, merge.** PR body lists the upstream-owned lines touched.

---

### Task 3: The `Platform` seam and its stub contract

**Files:**
- Create: `Sources/PokeTokenBar/Platform/Platform.swift`, `Platform/Mac/MacPlatform.swift`, `Platform/Windows/WindowsPlatform.swift`
- Test: `Tests/PokeTokenBarTests/PlatformTests.swift`

**Interfaces:**
- Produces:
  ```swift
  @MainActor protocol LocalNotifying { func requestAuthorization() async -> Bool
                                       func post(id: String, title: String, body: String, sound: Bool) }
  protocol SecretStoring: Sendable { func read(service: String, account: String?) -> Result<Data, SecretError> }
  enum SecretError: Error, Equatable { case notFound, denied, unavailable }
  @MainActor protocol SystemEvents { func onWake(_ f: @escaping () -> Void)
                                     func onScreensSleep(_ f: @escaping () -> Void)
                                     func onScreensWake(_ f: @escaping () -> Void)
                                     func onDayChange(_ f: @escaping () -> Void) }
  protocol IdleClock: Sendable { func secondsSinceLastInput() -> TimeInterval }
  struct Platform { let notifications: LocalNotifying; let secrets: SecretStoring
                    let events: SystemEvents; let idle: IdleClock
                    @MainActor static var current: Platform }
  ```
  The exact method lists are fixed in Tasks 4 and 6 by what the call sites need; add methods there, not speculatively here.
- Stub contract (Windows): `post` does nothing; `requestAuthorization` returns false; `read` returns `.failure(.unavailable)`; event hooks never fire; `secondsSinceLastInput` returns 0. Each logs one line through `AppLog` the first time it is called.

- [ ] **Step 1: Failing test** `testWindowsStubsReportUnavailable` — compiled on every OS against a `StubPlatform` type that the Windows file typealiases, asserting the contract above.
- [ ] **Step 2–4:** run FAIL, implement, run PASS. `MacPlatform` is empty wrappers for now.
- [ ] **Step 5: Commit, PR `refactor: add the platform seam`, merge.**

---

### Task 4: Team logic into the shared set

**Files:**
- Create: `Team/TeamTransporting.swift` (the protocol and its value types, cut out of `TeamTransport.swift`), `Team/TeamFocusTally.swift`
- Modify: `Team/TeamTransport.swift`, `Team/TeamNotifications.swift`, `Team/TeamRuntime.swift:217-219`, `Team/Plaza/PlazaWeather.swift`, `PlazaNameColor.swift`, `PlazaChatLog.swift`, and every `Team` file whose only obstacle is `import CoreGraphics`
- Modify: `mac-only.txt`, `shared-floor.txt`
- Test: `Tests/PokeTokenBarTests/TeamNotifierPlatformTests.swift`

**Interfaces:**
- Consumes: `LocalNotifying`, `IdleClock` from Task 3.
- Produces: `TeamNotifier` takes `notifications: LocalNotifying`; `TeamRuntime` takes `idle: IdleClock`. `MacPlatform` gains the real implementations (today's `UNUserNotificationCenter` and `CGEventSource` code, moved verbatim).

- [ ] **Step 1: Failing test** — with a recording `LocalNotifying`, each existing `TeamNotifier` trigger posts the same id/title/body it posts today (take the expected strings from the existing notification tests). And `testIdleSecondsComeFromTheClock`.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Split and route.** Stay Mac-only after this task: `TeamTransport.swift` (the Bonjour implementation), `Team/UI/`, and the plaza files that draw (`PlazaScene`, `PlazaActor`, `Plaza*Layer`, `Plaza*Art`, `PlazaWindowController`, `PlazaPhotoRenderer`, `PlazaChatBubble`, `PlazaEmoteArt`, `PlazaNamePlate`, `PlazaResources`, `PlazaCharacterLoader`, `PlazaIconLoader`, `PlazaMinimap`, `PlazaTileArt`, `CampfireArt`, `TallGrassArt`, `NestArt`, `SnowSheet`, `GroundShadow`). Everything else in `Team` becomes shared.
- [ ] **Step 4: Verify** — `shared-check.sh` exit 0; `test-gate.sh` green; move the matching test files out of the test list; Windows run green.
- [ ] **Step 5: Fault-inject** — make `MacPlatform.notifications.post` drop the body → the new test fails. Revert.
- [ ] **Step 6: Commit, PR `refactor(team): build the team logic on Windows`, merge.**

---

### Task 5: SQLite on Windows

**Files:**
- Create: `Sources/CSQLite/sqlite3.c`, `Sources/CSQLite/include/sqlite3.h`, `Sources/CSQLite/LICENSE.md` (public domain note, version, download URL and SHA-256)
- Modify: `Package.swift` (Windows branch: `CSQLite` target and dependency), `Core/LocalAdditionalUsageProvider.swift`, `Core/LocalAntigravityUsageReader.swift`, `Core/LocalAsideUsageReader.swift` (import guard only), `mac-only.txt`

- [ ] **Step 1:** Add the amalgamation (same version family as macOS 14's system SQLite or newer). The Mac build does not compile it (`CSQLite` exists only in the Windows branch of the manifest).
- [ ] **Step 2:** Swap `import SQLite3` for the guard shape in the three files; remove them from the list.
- [ ] **Step 3: Verify** — the existing SQLite-reader tests (`LocalAdditionalUsageTests`, the Antigravity and Aside reader tests) leave the test list and pass on the Windows run; `test-gate.sh` green.
- [ ] **Step 4: Commit, PR `build: vendor SQLite for the Windows build`, merge.** The PR body states the file is public domain and not a copyrighted asset.

---

### Task 6: `Core` hubs — keychain, notifications, system events

**Files:**
- Modify: `Core/KeychainAccess.swift`, `Core/OAuthLimitsProvider.swift`, `Core/AntigravityRateLimitsProvider.swift` (Security → `SecretStoring`); `Core/CompanionStore.swift` (3 notification sites), `Core/UsageStore.swift` (4 notification sites, 7 AppKit sites at ~991-1008); `Core/CustomScanRoots.swift` (`import Darwin` → `Foundation`, or its one call through `PlatformCompat`)
- Create: `Platform/Mac/MacSecrets.swift`, `Platform/Mac/MacSystemEvents.swift`
- Modify: `mac-only.txt`, `shared-floor.txt`
- Test: `Tests/PokeTokenBarTests/CorePlatformRoutingTests.swift`

**Interfaces:**
- Consumes: `SecretStoring`, `LocalNotifying`, `SystemEvents`.
- Produces: `KeychainAccess` keeps its current static API and test-injection hook; its body calls `Platform.current.secrets`. `UsageStore` and `CompanionStore` take the platform through their existing initialisers with a default of `Platform.current`.

- [ ] **Step 1: Failing tests.** `testWakeTriggersTheSameRefreshAsBefore`, `testDayChangeRollsTheDayAsBefore`, `testLimitAlertPostsThroughThePlatform`, `testCandyNotificationPostsThroughThePlatform`, `testKeychainReadStillMakesZeroSilentCalls` (the existing "automatic path makes 0 calls" guarantee in `KeychainAccess.swift:24` must still be testable and still hold).
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Route.** Move each OS call into the Mac implementation verbatim; the hub keeps only the protocol call. Do not restructure anything else in these files. Stay Mac-only: `Core/LoginItem.swift`, `Core/SingleInstance.swift`, `Core/CrashReporter.swift`, `Core/UpdateChecker.swift`, `Core/NetworkReachabilityMonitor.swift` — unless nothing shared needs them, they are stage 4's.
- [ ] **Step 4: Check the seam is closed** — none of the 20 symbols in spec §9.1 is defined in a Mac-only file any more (a one-off grep; put the result in the PR).
- [ ] **Step 5: Verify** — `shared-check.sh`, `test-gate.sh`, Windows run green; coverage: `llvm-cov show --show-regions` on the new Mac implementation files shows no `^0` region.
- [ ] **Step 6: Fault-inject** each new routing (drop the wake hook; swallow a notification) → its test fails. Revert.
- [ ] **Step 7: Commit, PR `refactor(core): route OS services through the platform seam`, merge.** List every upstream-owned line changed.

---

### Task 7: Tests on Windows

**Files:**
- Modify: `Tests/PokeTokenBarTests/mac-only.txt`, test files that assume `/`, `:` in PATH, or the repo layout
- Create: `Tests/PokeTokenBarTests/Fixtures/crlf-session.jsonl`
- Test: `Tests/PokeTokenBarTests/WindowsPathTests.swift`

- [ ] **Step 1:** For every test file still in the list whose subject is now shared, remove it and read the Windows run. Sort failures into: real Windows bug in shared code (fix, with the defect protocol), test assumption (fix the test so it holds on both), needs a Mac-only API (keep listed, with a `# why`).
- [ ] **Step 2: New tests that run on both:** `testAugmentedPathUsesThePlatformSeparator` (the known `BinaryLocatorTests` failure), `testHomeRelativeRootsResolveUnderTheUserProfile`, `testJSONLWithCRLFParsesTheSameAsLF`.
- [ ] **Step 3: Verify** — Windows run green with the list as short as it will go; `test-gate.sh` green.
- [ ] **Step 4: Commit, PR `test: run the shared tests on Windows`, merge.**

---

### Task 8: Lock it in and report

**Files:**
- Modify: `docs/superpowers/specs/2026-11-13-windows-port-design.md` (§3 numbers, §4 as built, §13), `CONTRIBUTING.md` (the import rule, three sentences), `docs/reference/defect-log.md` (one entry per defect class met), `CLAUDE.md` reference table (when to read the spec)

- [ ] **Step 1:** Record: shared files and lines, Mac-only files and lines by reason (draws / OS service / UI), tests running on Windows, upstream-owned lines changed in total.
- [ ] **Step 2:** Raise `shared-floor.txt` to the final count.
- [ ] **Step 3:** PR `docs: record the shared-source split`, merge. Report to the user in Korean: what now builds on Windows, what is still Mac-only and which stage takes it.

## Order

1 → 2 → 3 → then 4, 5 and 6 in any order (they touch different files; rebase the list files) → 7 → 8. Task 1 is the only one other sessions must know about the moment it merges.
