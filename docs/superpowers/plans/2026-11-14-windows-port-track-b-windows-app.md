# Windows Port, Track B (Stages 4–5: the Windows App and Team Connection) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Revised 2026-11-14 after Experiment E1 (Task 1, done).** The evidence is `spike/RESULTS.md` § "Experiment 5 (E1)" on `origin/spike/windows-port`. The session lead's rulings on the first draft's open questions are folded in (marked *ruling*).

**Goal:** A per-user installed Windows app that starts from the Start menu or at sign-in, sits in the tray with the companion's sprite, and keeps `UsageStore` and `CompanionStore` running on the user's real logs, with real OS services behind `Platform` (stage 4). Then it joins the team over the office Wi-Fi so Mac teammates see the Windows user in their roster and team notices arrive as Windows notifications (stage 5). The Mac app's behaviour does not change.

**Architecture:** Still one Swift module. All Windows-only Swift lives in `Sources/PokeTokenBar/Platform/Windows/`, each file wrapped in `#if os(Windows)` (the scan test already allows body-level conditionals under `Platform/`), so it compiles to nothing on the Mac. Every Win32 API the app needs imports and links from Swift through the `WinSDK` module (E1 P12). Only two needs remain for C:
- `CWinShim` (C/C++), for exactly two jobs Swift does badly: WIC image decoding, which is COM (Task 6), and an allocation-free crash filter (Task 11);
- `CTeamTLS` (C), an OpenSSL 3 TLS-PSK wrapper with OpenSSL linked statically from vcpkg.

The executable `PokeTokenBarWin` is one `main.swift` that calls the module's single `public` entry `WindowsApp.main()`. These three targets exist only when the manifest runs on Windows; the Mac branch of `Package.swift` and the Mac's `PTB_SHARED_ONLY` pre-check see none of them.

The UI thread is the process main thread. `main.swift` stays synchronous. The app touches `RunLoop.main` before it creates any window; on Windows, Foundation's own `RunLoop.main` initializer switches on CoreFoundation's Win32 message mask. Then it loops `RunLoop.main.run(mode: .default, before: .distantFuture)`. That one loop serves Win32 messages, the dispatch main queue (where `@MainActor` work runs) and `RunLoop` timers, with zero wakeups at idle (E1 P2, P4).

CF's message pump is ANSI and cannot be replaced, so a thread-local `WH_GETMESSAGE` hook on the main thread re-dispatches character messages with `DispatchMessageW` (E1 TEXT). The same hook is where stage 7 puts `IsDialogMessageW`.

The Windows team transport keeps all link state on the main actor like `BonjourTeamTransport`. It does socket and TLS work on one I/O thread (`WSAPoll`) and hands events to the main queue in order. The rules both transports share (caps, budgets, framing, naming) move into a shared `TeamTransportRules`, and one contract test suite runs against both transports.

**Tech Stack:** Swift 6.3.2 on `windows-latest` (VS 2026), SwiftPM, XCTest, the `WinSDK` module, two small C/C++ targets (clang through SwiftPM, the pattern proven by `spike/draw/`), OpenSSL 3 static (vcpkg, triplet `x64-windows-static-md`), Windows built-in DNS-SD (`windns.h`, `dnsapi.lib`, called from Swift), Inno Setup 6, GitHub Actions. Nothing new on the Mac.

**Spec:** `docs/superpowers/specs/2026-11-13-windows-port-design.md` (Korean) — §2 (G1, G2, failure conditions), §7 (OS services), §8 (only how the shell must host the popover later), §9.1, §10 steps 4–5, §11, §12. Experiments: branch `spike/windows-port` (`spike/RESULTS.md` incl. Experiment 5 (E1), `spike/e1/`, `spike/probe/ptbprobe.c`, `spike/draw/`, `.github/workflows/spike-windows.yml`). Prior art: chattymin/PokeTokenBar#114 (`WniizMaster/PokeTokenBar:windows-port`, MIT): `WindowsTray.swift` (message loop, tray, mutex), `WindowsAutostart.swift`, `installer/PokeTokenBar.iss`, `scripts/build-win-installer.ps1`. Read it for what works from Swift on Windows. Do not copy its GDI popover.

---

## Facts this plan rests on

F1–F13 were read in source while planning. F14–F21 were observed on the Windows runner in E1 (runs R1–R5, linked from `spike/RESULTS.md`). Each one changes a task.

| # | Fact | Where it was read | Consequence |
|---|---|---|---|
| F1 | On Windows `FileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)` is `%LOCALAPPDATA%` (`FOLDERID_LocalAppData`), **with forward slashes** (`C:/Users/x/AppData/Local`). `.libraryDirectory` is not mapped, so it returns `[]`. `.cachesDirectory` is the temp dir. `NSHomeDirectory()` uses backslashes (`C:\Users\x`). | swift-foundation `release/6.3`, `FileManager+WindowsSearchPaths.swift`, `FileManager+SearchPaths.swift`; observed in E1 P9 | `AppStatePaths` already lands in `%LOCALAPPDATA%\PokeTokenBar` (fine). `AppLog`'s `urls(for: .libraryDirectory…)[0]` **traps** the first time something logs. Today that is hidden only because `AppLog.write` returns early outside a bundle (F3). Task 3. Paths from the two sources differ in separators, so Windows code compares paths normalized and hands shell APIs native ones. |
| F2 | `UserDefaults.set` only calls `CFPreferencesSetAppValue` (marks keys dirty). Disk is written **only** on `synchronize()`. Nothing is written on `TerminateProcess` **or on a normal `exit(0)`**, and nothing after 5 s of `RunLoop.main` (no flush timer). The standard domain is the XML plist `<GetProfilesDirectoryW>\<user name>\AppData\Local\<ProcessInfo.processName>.plist`, and `processName` keeps `.exe`: the shipped app writes **`PokeTokenBar.exe.plist`**. A no-change `synchronize` leaves the file's mtime alone. | corelibs `release/6.3` `UserDefaults.swift`, `CFPreferences.c`, `CFKnownLocations.c`; observed in E1 P9 | Settings, and above all `team.memberID`, are lost on every exit path unless the app synchronizes. Task 5 adds a debounced sync and a sync on every exit path. The settings file name depends on the exe name, so the shipped exe name is frozen. The folder is built from the user *name*, not the profile path (risk R9). |
| F3 | `AppEnv.isBundledApp` = `Bundle.main.bundleIdentifier != nil && bundlePath.hasSuffix(".app")`. That is always false on Windows, and it gates logging, `persistsToUserLocation`, `allowsLiveLimitsFetch`, sprite prefetch and the reachability monitor in `UsageStore.init`. On Windows `bundleIdentifier` is nil, `bundlePath` and `resourcePath` are the exe's folder, and `infoDictionary` is empty. | `Core/AppEnv.swift`, `Core/AppLog.swift`, `Core/UsageStore.swift:1010`; observed in E1 P9 | Without a Windows rule the installed app keeps no logs, saves no companion progress and fetches no limits. Task 3. The version comes from a file next to the exe, not `Info.plist`. |
| F4 | CFRunLoop on Windows waits in `MsgWaitForMultipleObjectsEx(…, rlm->_msgQMask, MWMO_INPUTAVAILABLE)` and handles one message per iteration with the **ANSI** `PeekMessage`/`TranslateMessage`/`DispatchMessage` (CF is not built with `UNICODE`). The mask setter and handler SPI are **not exported** by any DLL, and no CoreFoundation symbol is. They aren't needed: **`RunLoop.main`'s initializer calls `_CFRunLoopSetWindowsMessageQueueMask(main, QS_ALLINPUT, default)` itself on Windows.** The main run loop drains the dispatch main queue. | corelibs `release/6.3` `CFRunLoop.c`, `Sources/Foundation/RunLoop.swift`; observed in E1 P1 (CF symbols MISSING) and P2 (`cf0`: 20/20 posted messages; control `cur`, `RunLoop.main` never touched: 0/20) | Strategy 1 needs no C lookup at all: touch `RunLoop.main`, then run it. A window created before `RunLoop.main` is touched gets no messages, and cross-thread `SendMessageTimeoutW` blocks its sender (E1 P2 m). |
| F5 | `UsageStore` refreshes from a `Timer` added to `RunLoop.main` in `.common` mode (`UsageStore.swift:1030`, `:1048`). `BonjourTeamTransport` uses `RunLoop.main` and `DispatchQueue.main.asyncAfter`. | source | A bare `GetMessageW` loop (what #114 did) would never fire the refresh timer and never run `@MainActor` jobs. |
| F6 | #114 never ran `@MainActor` code under its loop. It blocked the main thread in `GetMessageW`, ran all work in `Task.detached` on a custom `@CompanionActor` (and made `CompanionStore` `@unchecked Sendable`), and posted results back with `PostMessageW`. | #114 `WindowsTray.swift:8–13, 79–131` | Its loop shows nothing about our question, and its shape (all-`@MainActor` stores) can't be reused. |
| F7 | No file watching anywhere: no FSEvents, `DispatchSource` or kqueue in `Sources/`. Usage is polled (default 120 s). | grep | No file-watching port is needed. |
| F8 | The team code, nickname and `memberID` live in `UserDefaults` (`TeamSettings`), not the Keychain. Nothing shared calls `Platform.current.secrets` today. | `Team/TeamSettings.swift`, grep | *Ruling:* no Windows secret store until a caller exists; the stub stays. |
| F9 | Duplicate-link choice and protocol-version refusal live in shared `TeamSession`. The transport only reports `initiatedByMe` and honours `disconnect(_:coveredBy:)` / `refuse(_:)`. `TeamDialPlanner`, `TeamTokenBucket` and `TeamWire.FrameDecoder` are already shared and pure. | `Team/TeamSession.swift:497–520`, `TeamDialPlanner.swift` | The Windows transport re-implements only connection lifecycle and I/O. |
| F10 | PSK = `HMAC-SHA256(key: normalized code, msg: "poketokenbar.team.psk.v1")`, 32 bytes. Identity `ptb-team-v1`. OpenSSL cipher string `PSK-AES128-GCM-SHA256`, TLS 1.2 min = max. This interoperates with Network.framework in both directions on a real PC. | `Team/TeamCode.swift`, `spike/probe/ptbprobe.c`, `spike/RESULTS.md` | Reuse `TeamCode.pskKey` from Swift. The C side only takes 32 bytes. |
| F11 | Uncached `vcpkg install openssl:x64-windows-static` took 4 min 58 s on `windows-latest` (spike run 43383116858, step "OpenSSL (static)"). | `gh api …/runs/43383116858/jobs` | Cache the vcpkg install. Task 2. |
| F12 | Mac CI (`ci.yml`) runs only for `main`. PRs into `windows-port` get no Mac CI. | `.github/workflows/ci.yml` | The Mac proof for each PR is local: filtered suites + `shared-check.sh`, and the full gate at the milestones in the speed rules. |
| F13 | Not proven yet: DNS-SD removal (TTL 0 PTR), Public network profile, firewall rule action. | `spike/RESULTS.md` "STILL OPEN" | These go on the PC checklists (Tasks 13, 20). |
| F14 | corelibs `Timer(timeInterval:repeats:block:)` **fires immediately** on Windows (7.8 ms; repeating at 8, 1006, 2003 ms). It is `init(fire: Date(), …)`. On macOS the same call first fires after the interval (1009 ms). `Timer.scheduledTimer(withTimeInterval:…)` and `Timer(fire: now + i, interval: i, …)` fire after the interval on both. | E1 TIMER (R2); corelibs `Timer.swift` | Shared `UsageStore.reschedule()` and `suspendPolling()` misbehave on Windows. Task 2a fixes the two call sites (Mac-identical), and a scan bans the initializer in shared and Windows code. |
| F15 | CF's pump turns a posted or typed U+D55C into `0x3f` (`?`) for a Unicode window (runner ACP 1252). A thread-local `WH_GETMESSAGE` hook sees every message CF removes (test `wParam & PM_REMOVE`), sees `WM_CHAR` in its Unicode form, and can re-dispatch it with `DispatchMessageW` and turn CF's copy into `WM_NULL`. That delivered `0xd55c` for posted and `SendInput` text. IME composition (`WM_IME_*`) was not tested. | E1 P2 k, P2 l, TEXT (R3, R5) | Task 5 installs the hook. "EDIT controls get IME for free" is false. Hangul IME on a Korean-locale PC (ACP 949) is a PC check. |
| F16 | `MainActor.assumeIsolated` does not trap in a WndProc called by CF's pump, in top-level code before the loop, in `Timer`/`DispatchQueue.main`/`Task` blocks, or in a `WM_TIMER` inside `TrackPopupMenuEx`. It **traps** on a background thread (exit 132). An `async` `main` loses the main thread: after the first `await` main-actor code runs on a pool thread and windows created earlier are destroyed. | E1 P3, P6 | WndProcs and the hook enter app code with `assumeIsolated`. Pool-thread callbacks (DNS-SD, connectivity, socket loop) only hop with `DispatchQueue.main.async`. `main.swift` must stay synchronous (scan, Task 5). |
| F17 | Win32 modal loops (`TrackPopupMenuEx`) hold `Timer`s, `Task { @MainActor }` and `DispatchQueue.main` until they return. A 16 ms `SetTimer` that calls `RunLoop.main.run(mode: .default, before: Date())` keeps both running during the menu. Calling `_dispatch_main_queue_callback_4CF` (exported by `dispatch.dll`) instead runs main-actor work but not timers. Posted keys still drive the menu. | E1 P7 | Not needed for a short tray menu in stage 4; kept as the stage 6 mitigation for window drags (D2). |
| F18 | The GitHub runner has an interactive desktop (session 2, `WinSta0\Default`, `explorer.exe`). `NIM_ADD`, `NIM_SETVERSION`, `NIM_MODIFY` with `NIF_INFO`, and `NIM_DELETE` return TRUE; `Shell_NotifyIconGetRect` returns S_OK. A keyboard-driven `TrackPopupMenuEx` and `SendInput` to a foreground window work. Whether a balloon is *visible* is unknown. | E1 P8, P7, TEXT | Tray, menu and balloon calls are checked in CI (Tasks 6, 8). Only what needs eyes stays on the PC list. |
| F19 | `Process` with a `.cmd` shim: arguments with spaces and quotes arrive intact. `& \| < > ^ %` are interpreted by cmd.exe (`x&y` ran `y`). corelibs quotes only arguments containing space, tab, newline or quote. `isExecutableFile` is true for `.exe` and `.cmd`. Terminating a `.cmd`-launched process may leave its child running (not tested). | E1 P10; corelibs `Process.swift` `quoteWindowsCommandLine` | Batch-shim argument rule (Global Constraints). Task 4 measures the orphan case and fixes it if it is real. |
| F20 | `GetProcessTimes` is too coarse for an idle gate: the same ≈4-wakeups-a-second loop read 140.6, 93.8, 0.0, 46.9 and 62.5 ms per 60 s. Cycle counts (`QueryThreadCycleTime`, `QueryProcessCycleTime`) and wakeup counts are exact. The CF loop's main thread used 0 cycles in every 60 s idle window. The process used 5.5–8.7 M cycles per 60 s, no more than a process that only sleeps (6.1–10.1 M). | E1 P4 | Every idle measurement (Tasks 12, 13, 17, 20) uses cycles and context switches, never `GetProcessTimes`. |
| F21 | The runner loads `dispatch.dll` and `BlocksRuntime.dll` from `Toolchains\6.3.2+Asserts\usr\bin` and the rest of the runtime from `Runtimes\6.3.2\usr\bin`. That is a `Path` artefact a bundled app must not depend on. `URLSession` HTTPS works (200 in 195–283 ms); its completion runs off the main thread. | E1 P1, P11 | Packaging collects DLLs from both folders. The stripped-`Path` selftest proves the bundle is self-contained (Tasks 2, 12). |

**Guesses and their status after E1:**
- G-a (MainActor executor = dispatch main queue): **confirmed**.
- G-b (async `main` exits the main thread): **confirmed**. `main.swift` must stay synchronous.
- G-c (the CF SPI can be found with `GetProcAddress`): **refuted**, and not needed (F4).
- G-d (`assumeIsolated` safe in a WndProc): **confirmed** (F16).
- G-e (balloons show as toasts without an AppUserModelID or shortcut): **open** — PC (Task 13).
- G-f (the runner has a shell tray): **confirmed** (F18).
- G-g (`.cmd` shims): **partly** — spaces and quotes yes, cmd metacharacters no (F19).
- G-h (`-L<dir>` + `.linkedLibrary("libssl")` links vcpkg static libs; fallback `-Xlinker /LIBPATH:`): **open** — Task 2.
- G-i, new: a `UserDefaults` subclass sees every typed setter (`set(_:Bool, forKey:)` etc.) through `set(_:Any?, forKey:)`. **Open** — Task 5 tests it; if it doesn't, the subclass overrides each typed setter.

## Global Constraints

- **Speed rules (user decision, 2026-11-14) — these override any stricter wording below.** (1) No per-task full Mac gate: a task is verified on the Mac by the filtered suites for what it touched, `./scripts/shared-check.sh`, and (Track A) the render compare; the full gate `./scripts/test-gate.sh` runs only at milestones (Track A: after Tasks 7, 10, 13 and 19; Track B: after Tasks 5, 12, 14 and 19) and before `windows-port` goes to `main`. (2) Do not wait for Windows CI before merging a task into `windows-port`: merge, let the push run CI, and fix forward if it is red. Tasks whose only proof is Windows CI (Windows-only code) still read their run, but batch several changes per push. (3) Reviews: tasks marked for the most capable model keep an independent review; other tasks are read by the session lead. The cost accepted: a break found at a milestone is harder to trace to its task; `windows-port` is not released, so nothing reaches users in between.

Carried over from stage 1:
- **The Mac app must not change.** No behaviour, timing or UI difference. Every edit to a shared or upstream-owned file keeps the Mac result byte-identical, and a Mac test pins the old value (named in each task).
- Work in `.worktrees/<name>` cut from `origin/windows-port`. Never edit the main checkout. No bare `git stash`. Every `gh` call passes `--repo likelion-campus/PokeTokenBar`.
- **One PR per task, into `windows-port`, merged with a merge commit.** English Conventional Commits title. The body follows `.github/PULL_REQUEST_TEMPLATE.md` and lists every upstream-owned line changed. `main` is merged into `windows-port` at the start of each task. Experiment code goes to `spike/windows-port` and is never merged.
- **One `swift build` / `swift test` / `shared-check.sh` at a time on this Mac.** Before each one, `pgrep -x swift-build; pgrep -x swift-test; pgrep -x xctest` must print nothing; if it prints, wait. Never run the full suite while another session's release gate is running. The full gate runs only at the milestones named in the speed rules. Mac CI does not run for `windows-port` PRs (F12).
- **Windows is verified by pushing and reading the CI run** (`gh run watch … --exit-status`, `gh run view --log`, `gh run download`). Per the speed rules: merge without waiting, read the run, and fix forward when red.
- CI pair is fixed: `windows-latest` + Swift `6.3.2-RELEASE`.
- Upstream-owned files (`Core/**`, `UI/**`, `PokeTokenBarApp.swift`, `OutsideClickMonitor.swift`) are not renamed. Each edit is the smallest one that routes an OS difference through `Platform`. Track B touches only:
  - `Core/AppEnv.swift`, `Core/AppLog.swift` (Task 3);
  - `Core/UsageStore.swift`, two `Timer` call sites (Task 2a);
  - `Core/BinaryLocator.swift`, `Core/LocalUsageReader.swift`, `Core/LocalAdditionalUsageProvider.swift`, and `Core/ProcessRunner.swift` only if Task 4's orphan test fails (Task 4);
  - `Core/OAuthLimitsProvider.swift` → a verbatim move of its credentials-file half into the new shared `Core/ClaudeOAuthLimitsProvider.swift`, the same method stage 1 used for `Core/LimitsTypes.swift` (Task 9, *ruling*);
  - `Core/UpdateChecker.swift` (Task 10).
- Body-level `#if os` / `#if canImport` only under `Sources/PokeTokenBar/Platform/`. Shared files use only the three import guards. Shared files never write `import CoreGraphics`.
- Tests make `UserDefaults` suites only with `TestDefaults.make(suite:)`. Test classes on the main actor that run on Windows have only `async` tests (scan-enforced). Stores in tests take injected providers.
- Defect protocol (`CLAUDE.md`): root cause including why tests missed it, a class sweep (read `docs/reference/defect-log.md` first), a trigger-branch test after a reachability check, fault injection, and a permanent capture. Findings from planning or E1 (F1–F3, F14, F19, the `Path` key in Task 4) are defects and get the full protocol in their task.

New for Track B:
- **Windows-only Swift goes in `Sources/PokeTokenBar/Platform/Windows/**`** (team transport in `Platform/Windows/Team/`). Each file is wrapped whole in `#if os(Windows)`. `WinSDK`, `CWinShim` and `CTeamTLS` are imported only inside that wrap. **Windows-only tests are `Tests/PokeTokenBarTests/Windows*Tests.swift`**, also wrapped whole. Tests that compile on both systems hold pure shared logic.
- The only `public` symbol added is `WindowsApp.main()`.
- **Main-thread rules (F4, F16):**
  - `Sources/PokeTokenBarWin/main.swift` is synchronous: no `await`, no `async`.
  - `RunLoop.main` is touched before the first window is created.
  - WndProcs and the `WH_GETMESSAGE` hook run only on the main thread and enter app code through `MainActor.assumeIsolated`.
  - Callbacks on other threads (DNS-SD, connectivity hint, socket loop, `URLSession`) hop only with `DispatchQueue.main.async` and never call `assumeIsolated`.

  `WindowsSeamScanTests` enforces the first rule and the ban on `assumeIsolated` in files under `Platform/Windows/Team/` and the callback files.
- **Timers (F14):** never `Timer(timeInterval:repeats:block:)` in shared or Windows code. Use `Timer(fire: Date(timeIntervalSinceNow: i), interval: i, repeats: …, block: …)`. Scan-enforced from Task 2a.
- **Exits (F2):** Windows code leaves the process only through `WindowsApp.exit(_:)`, which synchronizes defaults and flushes the log first. Scan-enforced in `Platform/Windows/**` from Task 5: no other `exit(`, `ExitProcess(` or `TerminateProcess(GetCurrentProcess`.
- **Paths:** paths handed to Win32 shell APIs go through `WinPath.native(_:)` (backslashes). Paths are compared normalized (F1).
- **Batch shims (F19):** a tool resolved to a `.cmd`/`.bat` is launched only with fixed, code-defined arguments that contain none of `& | < > ^ % !` and no newline. Free-form text (paths, user input) is never passed through a batch shim. If a future call needs that, it resolves the shim's target `.exe` or escapes for `cmd.exe /d /s /c` in the same PR. Pinned by a test of today's argument lists (Task 4).
- **No uploads** of builds or binaries to VirusTotal or any other third party (*ruling*).
- **Never touch `Team/Plaza/**` or `Team/UI/**`.** That is Track A. No Track B task edits `Tests/PokeTokenBarTests/SharedSourcesScanTests.swift` (Track A extends it); Track B's scans go in their own files.
- New `Platform` protocols go in new files with their own `.current`, the pattern of `PlatformLimits` / `PlatformNetwork`. `Platform/Platform.swift` is edited exactly once (Task 7, two selector lines).
- `Package.swift`: Track B edits only the `if windowsBuild` branch, and only in Task 2. Windows-only targets are declared only under real `os(Windows)`, never under `PTB_SHARED_ONLY`.
- Model per role (user's `CLAUDE.md`): implementers `sonnet`. Tasks marked **[most capable]** use `opus` (the top tier only if the user asks). Reviews follow the user's table and the speed rules.
- No date, weather or chance gate on any feature without asking (memory: no self-chosen feature gates). Mac-side probes never activate the app (memory: no focus-stealing probes).

## Design

### D1. Target layout

```
Package.swift (if windowsBuild branch; Mac branch untouched)
  CSQLite                (exists)
  PokeTokenBar           .target  (exists)  deps: Crypto, CSQLite  + [CWinShim, CTeamTLS] only when os(Windows)
                         + linkedLibrary dnsapi, iphlpapi, user32, shell32, advapi32, ws2_32, dbghelp only when os(Windows)
  PokeTokenBarTests      .testTarget (exists)
  — declared only when os(Windows) —
  CWinShim               C/C++17. Concrete needs only: WIC PNG decode → BGRA + HICON (COM; Task 6) and the
                         allocation-free unhandled-exception filter + minidump (Task 11). Declared in Task 2 with a
                         placeholder so Package.swift is edited once. Everything else calls WinSDK from Swift (E1 P12).
  CTeamTLS               C: OpenSSL PSK wrapper; -I/-L from env PTB_OPENSSL_DIR
  PokeTokenBarWin        .executableTarget  Sources/PokeTokenBarWin/main.swift  (+ .rc, app.manifest excluded)
                         linker: /SUBSYSTEM:WINDOWS /ENTRY:mainCRTStartup (as #114)
  product .executable("PokeTokenBarWin") — packaged as PokeTokenBar.exe (Task 12; *ruling*)
```

Why this shape:
- One module keeps upstream `Core` symbols internal, the stage 1 reason. A second Swift module would need `public` or `package` on upstream symbols, or `@testable` in release.
- Why `Platform/Windows` and not `Sources/PokeTokenBarWin`: the scan allows body-level `#if` only under `Platform/`. It has to be the same module so that tests (`@testable import PokeTokenBar`) reach the Windows transport and services.
- The executable is a separate target because testable executables on Windows are not certain. `main.swift` is two lines and has no `await` (F16).
- The executable target is named `PokeTokenBarWin` so its outputs cannot collide with the library target's. Packaging renames the exe to `PokeTokenBar.exe`.
  **The shipped name is frozen:** the settings file is `<processName>.plist` and the process name includes `.exe` (F2). Renaming the exe in a later release would lose every setting, `team.memberID` included. CI runs of the unrenamed exe write `PokeTokenBarWin.exe.plist`, a separate file.
- Windows files count toward `shared-floor.txt` because they are not in `mac-only.txt`. Accepted: the floor only guards against shrinking.

### D2. Main thread, run loop and the main actor; how stages 6–7 host windows

**Decision (proven by E1):** `WindowsApp.main()` is synchronous and runs on the process main thread.
- Its first act is `_ = RunLoop.main`. Foundation's initializer turns on CF's message mask; no SPI, no C lookup (F4).
- It then creates windows and installs the hook, and loops `while !done { RunLoop.main.run(mode: .default, before: .distantFuture) }`.
- All windows are created on this thread. Every WndProc is `@convention(c)` and enters app code through `MainActor.assumeIsolated`.
- Background producers (socket I/O thread; DNS-SD and connectivity callbacks on thread-pool threads) hand work to the main thread only with `DispatchQueue.main.async`, which is FIFO, never with free-standing `Task {}`s, whose order isn't guaranteed.

Measured in E1: the main thread used 0 cycles in every 60 s idle window. Posted-message latency was median 0.03–0.08 ms, `DispatchQueue.main` from a thread ≤ 0.10 ms, cross-thread `SendMessageTimeoutW` ≤ 0.20 ms.

**The message hook (`WinMessageHook`, Task 5).** CF's pump is ANSI and cannot be replaced (the handler SPI isn't exported). One thread-local `SetWindowsHookExW(WH_GETMESSAGE, …, nil, GetCurrentThreadId())` on the main thread acts only on messages being removed (`wParam & PM_REMOVE`, not `==`; CF removes with `PM_REMOVE | PM_NOYIELD`):
- `WM_CHAR`, `WM_SYSCHAR`, `WM_DEADCHAR`, `WM_SYSDEADCHAR` for one of our windows → `DispatchMessageW(msg)`, then rewrite CF's copy to `WM_NULL`. E1 proved this for `WM_CHAR`; the other three follow the same path (guess).
- Stage 7 adds: if the target is inside a registered dialog window → `IsDialogMessageW`, and if it is handled, `WM_NULL`.
- Everything else passes untouched.

Hangul through a real IME on a Korean-locale PC is not proven (F15). It is a PC check (Task 13, via `--ime-check`).

**Fallback (diagnostic only, `PTB_WIN_LOOP=dispatch`):** the E1 `dhc` form, which passed every check.
- Our own `MsgWaitForMultipleObjectsEx(QS_ALLINPUT)` on the dispatch main-queue handle, with a `PeekMessageW` pump.
- On wake, `_dispatch_main_queue_callback_4CF`.
- Timers through `RunLoop.current.limitDate(forMode: .default)`; the wait timeout is clamped to 1 ms…60 s.
- The two dispatch symbols come from `dispatch.dll` via `GetProcAddress` and `unsafeBitCast` to `@convention(c)`, so no shim is needed.

Its catch: anything touching `RunLoop.main` (shared `UsageStore` does) turns CF's ANSI pump back on inside `limitDate`. The hook stays installed in this mode too. Polling (strategy 3) is **rejected**: about 4 wakeups a second, 11–16× the cycles, main-queue latency up to 228 ms after idle (E1 P4).

**Known limit (F17):** Win32 modal loops hold main-actor work and timers until they return. Stage 4 accepts this for the short tray menu; the Mac's menu tracking behaves the same. If the stage 6 plaza freezes during a window drag: between `WM_ENTERSIZEMOVE` and `WM_EXITSIZEMOVE`, a 16 ms `SetTimer` calls `_dispatch_main_queue_callback_4CF`. That runs main-actor work without a nested CF run (E1 P7). Timers would wait, and the stage 6 plan decides whether that matters.

**How stages 6 and 7 host their windows** (this plan builds the host, not the windows):
- **Popover (stage 7, minimal first: usage, companion, settings — user decision):** a `WS_POPUP | WS_EX_TOOLWINDOW` window created on open and destroyed on close (Mac parity: the hosting tree is built on open and freed on close, for idle CPU).
  - Placed with `Shell_NotifyIconGetRect` (S_OK on the runner, F18); closes on `WM_ACTIVATE(WA_INACTIVE)`, like `.transient`.
  - Dialog keyboard navigation needs `IsDialogMessageW`, so stage 7 registers the popover with `WinMessageHook`.
  - Text input in `EDIT` controls depends on the hook's `WM_CHAR` re-dispatch. IME composition through CF's ANSI pump is not proven (F15); stage 7 re-checks it on the PC.
- **Plaza (stage 6):** a normal top-level window on the same thread. A frame clock runs only while the plaza is visible: a `Timer(fire:…)` on `RunLoop.main` at the scene's rate, or a DXGI `WaitForVBlank` thread posting to the main queue (stage 6 decides). Rendering is Direct2D to a swap chain, proven offscreen in spike 3 (stage 6 adds its own C++ shim, as spike 3 did). Chat input is an `EDIT` child (spec §6) and has the same IME caveat.
- **Floating pet (stage 7):** `WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW`.
- Every window shares the hidden sink window's message routing (`WinSinkWindow.on(_:_:)`) and the one hook, so new windows add handlers and never a second loop.

### D3. OS services on Windows

"CI" = what the runner checks; it has a real desktop and tray (F18). "PC" = what only the user's PC can show. Every failure is logged once through `AppLog` (the stage 1 stub rule). All APIs below are called from Swift via `WinSDK` unless the boundary column names a C target.

| Service | Windows API | Swift / C boundary | CI | PC | Honest failure |
|---|---|---|---|---|---|
| Loop + main actor | `RunLoop.main` (Foundation sets the mask) + `WH_GETMESSAGE` hook (D2) | Swift | selftest: thread ids for Task, `DispatchQueue.main`, `Timer`, posted message, cross-thread `SendMessageTimeoutW`; posted and `SendInput` U+D55C arrive whole | Hangul IME (`--ime-check`) | `PTB_WIN_LOOP=dispatch` fallback for diagnosis |
| Tray icon | `Shell_NotifyIconW` (uID 1, `NIF_ICON\|NIF_MESSAGE\|NIF_TIP`, `NIM_SETVERSION` 4), `RegisterWindowMessageW("TaskbarCreated")` | Swift | selftest add / setversion / modify / getrect / delete; `TaskbarCreated` re-add | overflow area on Win11, DPI crispness | `NIM_ADD` fails → retry on `TaskbarCreated`; notifications report unavailable |
| Tray image | WIC PNG decode → nearest-neighbour scale → `CreateIconIndirect` (32-bpp DIB) | `CWinShim` (WIC is COM) `ptb_png_to_bgra`, `ptb_icon_from_bgra` | unit: decode a fixture PNG, pixel checks | look | default app icon |
| Tray menu | `CreatePopupMenu` / `TrackPopupMenuEx` (+ `SetForegroundWindow` before, `WM_NULL` after) | Swift | `TrayMenuModel` unit tests (both OSes); selftest drives the menu with posted keys (F17) | look | — |
| Notifications | balloon `NIF_INFO` (shown as toasts), `NIN_BALLOONUSERCLICK/HIDE/TIMEOUT` (*ruling*: balloons now) | Swift + shared `BalloonQueue` | queue unit tests; `NIM_MODIFY`+`NIF_INFO` returns TRUE | the balloon is visible and in Notification Center; Focus Assist | no tray → `isAvailable == false` → callers skip (existing guard); Focus Assist suppresses silently (documented) |
| Secret store | none (*ruling*) | the stage 1 stub stays | stub contract test (exists) | — | `.unavailable`, logged once |
| Wake / will sleep | `RegisterSuspendResumeNotification(hwnd)` → `WM_POWERBROADCAST` `PBT_APMSUSPEND` / `PBT_APMRESUMEAUTOMATIC` | Swift | synthetic messages into `handlePowerBroadcast`; registration non-nil | real sleep, Modern Standby | never fires → periodic timer and session heartbeats still recover (stub semantics) |
| Displays asleep | `RegisterPowerSettingNotification(GUID_CONSOLE_DISPLAY_STATE)` | Swift (imports, E1 P12) | synthetic | display off pauses polling | never fires → polling continues (more CPU while the display is off) |
| Day change | `Timer(fire:)` to the next local midnight + 1 s; re-armed on `WM_TIMECHANGE` and resume; fires at once on resume if the day key changed | shared `DayBoundary` | unit tests | crossing midnight | missed → the next refresh recomputes `todayKey` anyway |
| Idle clock | `GetLastInputInfo` + `GetTickCount` (wrapping subtraction) | Swift | finite, ≥ 0 | 5 min idle → away | returns 0 (never idle) |
| Reachability | `NotifyNetworkConnectivityHintChange` (Win10 2004+), level ≥ LocalAccess = satisfied (mapping is a guess) | Swift + shared `ReachabilityTransition` | registration + initial callback ≤ 5 s | Wi-Fi off/on | never fires → periodic refresh only |
| Single instance | `CreateMutexW("Local\\PokeTokenBar-Team[-<hash>]")`; second instance posts `WM_APP_SHOW` to the sink found by class and exits 3 | Swift | selftest spawns a second process → exit 3; the running one's `NIF_INFO` returns TRUE | the balloon is visible | mutex error → run anyway, log |
| Launch at login | `HKCU\…\Run\PokeTokenBar = "\"<exe>\" --autostart"`; read `…\Explorer\StartupApproved\Run` (first byte `0x03` = disabled; community-known, undocumented). **Off by default** (*ruling*) | Swift | round trip in a test-only subkey; on CI also the real Run key | sign-out/in, Task Manager toggle | write fails → unchecked + log |
| Update check | shared `UpdateChecker` + `InstallerReleaseFeed` (nil unless the release has a Windows installer asset); open = `ShellExecuteW`; only opens the release page until stage 8 (*ruling*) | shared + `PlatformShell` | canned JSON tests | real network, proxy | no banner (Mac behaviour on failure) |
| Crash log | marker file, `SetUnhandledExceptionFilter`, `MiniDumpWriteDump`, stderr → file | filter body in `CWinShim` (must not allocate or lock); the rest Swift | CI crashes on purpose, then the next run reports it | — | filter can't run (stack overflow) → the marker still reports it next launch |
| Claude limits | `%USERPROFILE%\.claude\.credentials.json` + HTTPS (FoundationNetworking/libcurl; works, F21) | the upstream file path, moved verbatim into shared `Core/ClaudeOAuthLimitsProvider.swift` (*ruling*) | `URLProtocol` stub tests on both OSes | real login | no file, automatic path → the Mac's own error (`keychainInteractionNotAllowed` / `credentialMissingAccountOAuth`); user refresh → `keychainAccessDisabled`. Wording is stage 7's job |
| Antigravity limits | token location on Windows unknown | stub stays | — | — | unavailable |
| Codex limits | `codex app-server --stdio` via `Process` (existing shared code); the npm install is `codex.cmd` | shared | arguments are batch-safe (pin test); terminate kills the child (Task 4) | real install | binary not found → no Codex limits (Mac behaviour) |
| Tool dirs | `%APPDATA%\npm`, `%LOCALAPPDATA%\pnpm`, `%LOCALAPPDATA%\Microsoft\WinGet\Links`, `%USERPROFILE%\scoop\shims`, `%USERPROFILE%\.bun\bin`, `%LOCALAPPDATA%\Volta\bin` (likely), `%LOCALAPPDATA%\mise\shims` (likely), `%NVM_SYMLINK%` when set, `%USERPROFILE%\.local\bin`; then the process `Path` with `PATHEXT` | shared `PlatformCompat` | unit tests | — | not found → nil |
| Team discovery | `DnsServiceRegister` / `DnsServiceBrowse` / `DnsServiceResolve` | Swift (imports, E1 P12) | runner loopback register + browse | office Wi-Fi; Public profile blocks mDNS | browse fails → restart after 5 s (Mac rule); register fails → others can't dial us, we still dial them |
| Team TLS | OpenSSL 3 static | `CTeamTLS` (OpenSSL's API is macros the importer can't call) | contract suite, known-answer tests, OpenSSL CLI interop | Mac interop | context fails → listener failed → retry after 5 s (Mac rule) |

**Other tools' logs on Windows.** Researched from documented layouts. Only rows marked known or likely get edits; home-relative roots already resolve under `%USERPROFILE%`.

| Provider | Mac default | Windows | Confidence | Change |
|---|---|---|---|---|
| Claude Code | `~/.claude/projects`, `~/.config/claude/projects` | `%USERPROFILE%\.claude\projects` | known | none (home-relative) |
| Claude Desktop sessions | `~/Library/Application Support/Claude/{local-agent-mode-sessions,claude-code-sessions}` | `%APPDATA%\Claude\…` | base known (`%APPDATA%\Claude` holds `claude_desktop_config.json`); subfolders guess | via `userApplicationSupport(home:)` |
| Codex | `~/.codex/{sessions,archived_sessions}` | `%USERPROFILE%\.codex\…` | known | none |
| Gemini | `~/.gemini/tmp` | `%USERPROFILE%\.gemini\tmp` | known | none |
| Antigravity | `~/.gemini/antigravity*/conversations` | same, home-relative | likely | none |
| Grok | `~/.grok/sessions` | same | guess | none |
| OpenCode | `~/.local/share/opencode` | `%USERPROFILE%\.local\share\opencode` (xdg-basedir behaves the same on Windows) | likely | none |
| Copilot CLI | `~/.copilot` | same | likely | none |
| Cursor | `~/Library/Application Support/Cursor{, Nightly}/User/globalStorage` | `%APPDATA%\Cursor{, Nightly}\User\globalStorage` | known (VS Code layout) | via `userApplicationSupport(home:)` |
| Kiro CLI, Hermes, Devin, Aside, pi, omp | various | unknown | unknown | none; documented as unknown |

### D4. Data, settings and logs on Windows

| What | Mac | Windows | How |
|---|---|---|---|
| App | `/Applications/PokeTokenBar.app` | `%LOCALAPPDATA%\Programs\PokeTokenBar\` (exe, DLLs, `PokeTokenBar.version`, `licenses\`). `Bundle.main.resourcePath` is this folder (F3), so shipped resources sit next to the exe | installer |
| State (companion save, caches, sprites) | `~/Library/Application Support/PokeTokenBar` | `%LOCALAPPDATA%\PokeTokenBar` (Foundation returns it with forward slashes, F1) | Foundation mapping, no change; `PTB_STATE_DIR` override as on the Mac |
| Settings (`UserDefaults.standard`) | cfprefsd | `C:\Users\<user name>\AppData\Local\PokeTokenBar.exe.plist`. CF builds it from `GetProfilesDirectoryW` + the user name + `AppData\Local` + `ProcessInfo.processName` (F2). The CI exe writes `PokeTokenBarWin.exe.plist`. A non-default `PTB_STATE_DIR` adds `ptb.team.<hash>.plist` | CF XML plist; **the app synchronizes** (below) |
| Logs | `~/Library/Logs/PokeTokenBar.log` | `%LOCALAPPDATA%\PokeTokenBar\Logs\PokeTokenBar.log` (+ `.old.log`, `.crash.log`, `.stderr.log`, `*.dmp`, at most 3) | `PlatformCompat.logsDirectory()` (Task 3) |
| Launch at login | SMAppService | `HKCU\Software\Microsoft\Windows\CurrentVersion\Run\PokeTokenBar`, off until the user turns it on | Task 10 |

Uninstall removes the app folder, the Run value and the Start-menu entry. It keeps state, settings and logs (Mac parity: deleting the app keeps Application Support).

**Is `UserDefaults` good enough on Windows?** Yes, with a sync policy; not as it is (F2). The policy (`WinDefaultsSync`, Task 5):
1. **Debounced sync after writes.** The app injects `WinSyncingDefaults`, a `UserDefaults` subclass with `suiteName: nil` (so the same domain as `.standard`), into every shared init that takes `defaults:`: `UsageStore`, `TeamSettings`, `UpdateChecker`. Its `set`/`removeObject` overrides call `WinDefaultsSync.noteWrite()`, which re-arms a `Timer(fire: now + 2 s)` on the main thread. Each write is on disk within about 2 s (G-i decides which setters need overriding).
2. **Safety sync** every 30 s (tolerance 10 s), for code that writes `UserDefaults.standard` directly (`BinaryLocator` overrides and others). A no-change sync doesn't touch the file (F2).
3. **Right after the stores are built,** so a fresh `team.memberID` survives an early crash.
4. **Every exit path**, through `WindowsApp.exit(_:)`, which is scan-enforced as the only exit: Quit, `WM_ENDSESSION`, `WM_CLOSE` from the installer's Restart Manager, selftest exits, the `--selftest-*` helper modes, launch failures.
5. **Fatal errors:** the crash filter makes one best-effort `synchronize()` on a fresh thread and waits at most 500 ms. Calling into CF from a crashed process can deadlock; the wait caps that, and the debounce already bounds the loss to about 2 s.

The whole domain file is rewritten on each dirty sync; fine at this size.

### D5. Installer and what the user downloads

- **Inno Setup 6**, `PrivilegesRequired=lowest`, `DefaultDirName={localappdata}\Programs\PokeTokenBar`, `DisableDirPage=yes`, a fresh `AppId` GUID (not #114's).
  - Start-menu shortcut with `AppUserModelID: "LikelionCampus.PokeTokenBar"` (unused in stage 4, so real toasts can come later without a reinstall).
  - `AppMutex=Local\PokeTokenBar-Team`, `CloseApplications=yes`, launch after install (also in silent mode, so a future auto-update relaunches).
  - **No "launch at login" task** (off by default, *ruling*). `[Registry]` `ValueType: none; Flags: uninsdeletevalue` removes the Run value on uninstall without creating it.
  - Optional desktop shortcut task. Licence page off; the `licenses\` folder ships.
- **Artifact:** `PokeTokenBar-Setup-<version>-win-x64.exe`, unsigned (SmartScreen accepted). Until stage 8 the user downloads it from the `windows-app` workflow run's artifacts. Version comes from `scripts/build-app.sh` `VERSION="x.y.z"` (single source). It is stamped into `PokeTokenBar.version`, the `.rc` `VERSIONINFO` (x.y.z.0) and the installer name.
- **Swift runtime DLLs:** copied app-local. The set is the dependency closure of the exe from `dumpbin /DEPENDENTS`, recursive, not "all `*.dll`" (the spike's quick way). It is looked up in **both** `Runtimes\<ver>\usr\bin` and `Toolchains\<ver>\usr\bin`, because `dispatch.dll` and `BlocksRuntime.dll` live in the latter (F21).
  VC++ runtime DLLs come from the VS redist folder (`VC\Redist\MSVC\*\x64\Microsoft.VC14*.CRT`), not System32.
  The packaging script fails if a closure DLL is neither a known OS DLL nor in the mapped set, or if a shipped DLL has no entry in `windows/licenses/map.txt`. That is the machine check for licences.
- **Licences shipped:** OpenSSL (Apache-2.0), Swift runtime and Foundation (Apache-2.0 with Runtime Library Exception), ICU (Unicode License v3), libcurl (curl licence; inside FoundationNetworking if the closure shows it), swift-crypto and its namespaced BoringSSL (Apache-2.0 / OpenSSL-ISC; swift-crypto prefixes BoringSSL symbols, so they don't clash with OpenSSL), SQLite (public domain note), the app (MIT).
- **Resources:** `Sources/PokeTokenBarWin/PokeTokenBar.rc` with `VERSIONINFO`, `1 ICON assets\AppIcon.ico`, and `1 RT_MANIFEST app.manifest` (PerMonitorV2 DPI, `supportedOS` Win10, common controls v6 for stage 7). Compiled by `rc.exe` in CI and linked with `swift build -c release -Xlinker <abs>\PokeTokenBar.res`. Putting the manifest in the `.rc` avoids depending on lld-link's `/MANIFEST:EMBED`. `assets/AppIcon.ico` is generated once from `assets/icon_1024.png` by `scripts/generate-ico.py` (Pillow; 16/20/24/32/40/48/64/256) and committed.

### D6. Team transport on Windows

- **Threading:** `WindowsTeamTransport` is `@MainActor` and holds the same state as `BonjourTeamTransport`: `links`, `endpoints`, `planner`, `generation`, `wanted` / `running`, timers. All decisions (caps, cooldowns, budget, decode) happen on the main actor, as on the Mac, so floods behave the same.
  `WinSocketLoop` owns every socket and `SSL*` on one thread. It runs non-blocking Winsock in `WSAPoll` with an infinite timeout (zero idle cost), woken by a loopback UDP socket pair. It sends events to a mailbox drained by one `DispatchQueue.main.async` at a time, in order.
  **Receive mirrors Network.framework's pull model:** after `.ready`, the transport calls `receiveNext(id)`. The loop delivers at most one `.data` chunk of ≤ 65,536 bytes per call, then stops reading that socket until the next `receiveNext`. So the Mac's per-chunk budget (`bytes + frames × 1024`) and its TCP back-pressure carry over exactly. The loop calls `SSL_read` until `WANT_READ` before going back to poll, because decrypted bytes can sit in OpenSSL with no socket readiness.
- **OpenSSL:** vcpkg manifest `windows/vcpkg.json` (`openssl`, pinned `builtin-baseline`), triplet `x64-windows-static-md` (static libs, dynamic CRT, matching Swift's `/MD`; the spike's `x64-windows-static` is `/MT` and would clash). Installed by a composite action with `actions/cache` keyed on `hashFiles('windows/vcpkg.json')` + the runner image version. Exports `PTB_OPENSSL_DIR`. Local development needs vcpkg too; there is no Windows developer today. No vendoring (about 600k lines) and no third-party prebuilt (provenance).
  Swift never sees OpenSSL headers: `SSL_CTX_set_min_proto_version` and friends are macros the importer can't call. `CTeamTLS` exposes about ten plain C functions (Task 16).
- **DNS-SD (Swift via WinSDK, E1 P12):** instance `ptb-<12 lowercase hex>` (shared `TeamTransportRules.newInstanceName()`). Registered as `<instance>._ptbteam._tcp.local` on host `<DnsHostname>.local` at the listener port, no TXT. Browse `_ptbteam._tcp.local`: PTR with TTL > 0 → `found(label)`, TTL 0 → `lost(label)` (guess, F13). Own instance filtered. Callbacks arrive on pool threads and hop with `DispatchQueue.main.async` (F16). Resolve happens at dial time inside the dial's 10 s handshake budget (the link is adopted when the dial starts, so the caps count resolving dials). IPv4 first, then IPv6.
- **Listener:** dual-stack `[::]:0`, `IPV6_V6ONLY = 0`, as in the probe. The first listen raises the firewall prompt.
  If inbound ends up blocked, the team still works with Macs: Windows dials the Macs, which needs no inbound rule, and `TeamSession` keeps one link per pair. Only Windows↔Windows pairs would fail. The PC check reads the rule's action and profile (Task 20).
- **Timers:** the redial timer (15 s) and handshake timers use `Timer(fire:…)` or `DispatchQueue.main.asyncAfter`, never `Timer(timeInterval:)` (F14).
- **Wire compatibility** comes from shared code (`TeamCode.pskKey`, `TeamWire`), plus four proofs: known-answer tests for PSK bytes and a frame on both OSes, the contract suite on both transports, OpenSSL-CLI interop on both sides (a neutral third TLS stack), and the real Mac ↔ PC run.

### D7. Verification without a Windows machine here

The runner has a real desktop, tray and explorer (F18), so more than planned runs in CI. CI can prove:
- the library builds and its tests pass (`windows.yml`, floor ≥ 1000 tests);
- the release exe builds;
- `--selftest` from the packaged folder, with `Path` stripped of the Swift toolchain (proves the DLL closure, F21), and again from the silently installed copy (proves the installer, `isBundledApp`, logging, persistence);
- the loop and hook in the shipped loop (F4, F15), tray add/modify/delete, a balloon call, a key-driven tray menu, single instance, the real Run key;
- a deliberate crash followed by a clean relaunch report;
- loopback transport contract tests and runner-local DNS-SD;
- OpenSSL CLI interop;
- an idle sample of `PokeTokenBar.exe` and `explorer.exe` by cycles and context switches (F20);
- silent uninstall.

`--selftest --selftest-out <file>` runs inside the real loop, exercises every service, writes JSON (`{"result":"pass"|"fail","checks":[{"name","ok","detail"}]}`) and exits through `WindowsApp.exit` with 0 or 1. Console output is not needed (GUI subsystem). Checks that type into a window (`SendInput`) run only when `CI` is set, so the user's own selftest run never types anywhere.

The PC proves only what needs a person or a real environment: the tray in the overflow, whether balloons are visible, sleep and wake, the firewall prompt, SmartScreen and Defender, the office network, a real Mac, Hangul IME on a Korean-locale PC, a profile folder named differently from the user name, idle cost with a real tray. The PC checklists are Tasks 13 and 20; the session lead words them in Korean.

### D8. Idle cost (spec §2 failure condition)

Possible burners and how each is kept at zero:
- Tray animation: each frame is a cross-process `NIM_MODIFY`, so explorer.exe redraws and the cost lands outside our process. *Ruling:* stage 4 uses a static icon, updated only when the representative subject changes; animation is decided after the PC idle numbers.
- The loop: CF's blocking wait, 0 main-thread cycles at idle (F20). Polling is rejected.
- The socket loop: `WSAPoll(INFINITE)`.
- Timers: `UsageStore` 120 s and `TeamRuntime` 5 s, both as on the Mac (and no longer firing at once after Task 2a); redial 15 s; defaults safety sync 30 s with 10 s tolerance; the debounce timer only after writes.
- Polling while the display is off: paused through `displaysAreAsleep` (D3).
- DNS-SD: browse started once per transport start, never restarted on a timer.

**Measured with cycles and context switches, never `GetProcessTimes` (F20).** `scripts/windows/measure-idle.ps1` uses inline C# `Add-Type`:
- `QueryProcessCycleTime` for the process;
- `QueryThreadCycleTime` per thread, read only at the window's edges, because a snapshot inside the window was an E1 artefact;
- per-thread `ContextSwitches` from `NtQuerySystemInformation(SystemProcessInformation)` (partly documented, `winternl.h`) as the wakeup count;
- handles and private bytes.

It measures any running PID, so the same script serves CI and the PC, for `PokeTokenBar.exe` and `explorer.exe`.
- **Task 1 (done):** loop-only, 60 s: main thread 0 cycles, process 5.5–8.7 M cycles, at or below a process that only sleeps.
- **Task 12 CI gate.** The installed app runs with fixture data and polling set to manual (`refreshInterval = 0` in the CI profile), so nothing is due; wait 30 s; measure 120 s.
  - Main-thread context switches ≤ 2.
  - Process cycles ≤ 2× a sleeping baseline process measured in the same job.
  - explorer.exe cycles Δ ≤ 2× its own Δ over an equal window measured before the app started.
  - Handle count growth ≤ 20.

  The budgets are guesses: the first runs record their numbers in the PR, and the budgets are tightened after the PC numbers. A second, report-only window of 300 s with the default 120 s polling records the per-refresh cost.
- **Tasks 13 and 20:** on the PC, 10 min idle, then 10 min with three or more teammates connected. Compare with a `ps -o cputime` sample of the Mac app over the same 10 min (read-only).

### D9. Where Track A and Track B could collide

| Shared spot | Track B's footprint | Keeping it small |
|---|---|---|
| `Package.swift` | Task 2 only, inside `if windowsBuild` | Track A, if anything, edits the Mac branch. Different blocks merge cleanly. |
| `Sources/PokeTokenBar/mac-only.txt` | Task 10 removes one line (`Core/UpdateChecker.swift`) | Track A removes plaza lines in another block |
| `Tests/PokeTokenBarTests/mac-only.txt` | Task 9 may remove OAuth test files that only need the file path; Task 10 removes `UpdateCheckerTests.swift` | different lines |
| `Platform/Platform.swift` | Task 7: two selector lines | Track B adds protocols in new files; Track A should do the same (tell the peer session after Task 7 merges) |
| `Platform/PlatformCompat.swift` | Tasks 3, 4, 9 add functions and non-Darwin constants | append-only; Track A rarely edits it |
| `.github/workflows/windows.yml` | Task 2 replaces the setup step with the composite action, once | Track B's own jobs go in the new `windows-app.yml`. If Track A adds a Windows render job, it should use the same composite action. |
| `shared-floor.txt` | raised by tasks that add shared code | single number; on conflict re-measure and take the new count |
| `SharedSourcesScanTests.swift` | not touched | Track B's scans live in `TeamTransportContractScanTests.swift`, `WindowsSeamScanTests.swift`. Task 2a's timer scan covers all shared files, so a future plaza file using `Timer(timeInterval:)` fails it. Tell Track A when it merges. |
| `docs/reference/defect-log.md`, `CONTRIBUTING.md` | append-only sections | distinct headings |

### D10. Risks and the cheapest early experiment for each

1. **Swift concurrency under a Win32 loop** — **resolved by E1** (strategy 1, no SPI). Residual risks: modal loops hold work (F17, stage 6), and the ANSI pump (F15, covered by the hook; IME unproven, PC check).
2. **Toasts from an unpackaged app.** Real WinRT toasts need an AppUserModelID. In the classic model that ID must also sit on a Start-menu shortcut (`System.AppUserModel.ID`); a newer registry route (`…\Software\Classes\AppUserModelId\<AUMID>`) was not tried. Clicks while the app is closed need a COM activator CLSID. *Ruling:* balloons now (`NIF_INFO`; the calls succeed on the runner, F18). The installer still stamps the shortcut's AUMID so toasts can come later. Visibility is the open part: the stage 4 PC check posts one through `--selftest`.
3. **Firewall prompt on the first listen,** standard account. Spike: a rule was created without an admin password; its action and profile were not read. Cheapest: the PC check reads `netsh advfirewall firewall show rule name=all dir=in verbose` filtered to the exe. Blocked inbound still allows Windows-initiated links (D6).
4. **Antivirus and SmartScreen.** Unsigned binary, plus a listener, plus DNS-SD. Cheapest: Defender right-click scan on the PC, and record the SmartScreen flow. *Ruling:* no uploads to VirusTotal or any third party.
5. **OpenSSL build time in CI.** Uncached it is 5 min (F11). Cheapest: Task 2 records cold and warm times. A miss only costs time.
6. **`URLSession` on Windows.** HTTPS works on the runner (F21). Still a guess: libcurl reads proxy settings from environment variables only, not the WinINET or PAC system proxy. Cheapest: the PC check on the office network (do limits and the update check work?).
7. **File watching:** none (F7). No risk.
8. **Foundation-on-Windows silent differences** (F1–F3, F14). Certain. Fixed in Tasks 2a, 3 and 5, captured in `defect-log.md` as one class, with scans.
9. **Settings in a folder the user doesn't own.** CF builds the plist path from the profiles directory plus the user *name* (F2). If the profile folder is named differently (renamed account, `user.DOMAIN` profiles), settings go to a folder that may not exist and are silently never saved. Cheapest: Task 5's selftest `defaults.location` compares CF's path with `FOLDERID_LocalAppData` and fails loudly when they differ; a PC check item. Mitigation is open question 1.
10. **DNS-SD details.** Removal events may never come (then a gone teammate is dialed about once a minute until the browse restarts — harmless). Virtual adapters (WSL, Hyper-V, VPN) may be advertised. A Public network profile blocks mDNS. Cheapest: the stage 5 PC check records the network profile, `ipconfig`, and `--team-probe` output.
11. **Modern Standby** laptops may never send `PBT_APMSUSPEND`. Links then die by TCP and session heartbeat. PC check item.
12. **Win11 hides new tray icons in the overflow.** A first-run balloon tells the user (spec §8).
13. **`.cmd` shims** (Codex via npm's `codex.cmd`). Arguments: today's `app-server --stdio` is safe, and the batch-shim rule keeps it so (F19). The child process may outlive a terminate (untested); Task 4 measures it and fixes it with a tree kill if it is real.
14. **Exe-name-bound settings** (F2). Renaming the shipped exe loses settings. The name is frozen (D1); the installer and package scripts take it from one constant.

## File Structure

```
Package.swift                                   modify (Task 2): Windows-only targets + system libraries in the windowsBuild branch
windows/vcpkg.json                              create (2): openssl, pinned baseline
windows/licenses/                               create (12): licence texts + map.txt (dll → licence)
.github/actions/windows-swift/action.yml        create (2): Swift 6.3.2 + cached vcpkg OpenSSL, exports PTB_OPENSSL_DIR
.github/workflows/windows.yml                   modify (2): use the composite action
.github/workflows/windows-app.yml               create (2), grows (5, 6, 11, 12, 19): release exe, package, selftests, installer, idle gate
installer/PokeTokenBar.iss                      create (12)
scripts/windows/package.ps1                     create (2: plain copy from Runtimes + Toolchains) → (12: dumpbin closure, rc, licences)
scripts/windows/measure-idle.ps1                create (12): cycles + context switches (inline C#)
scripts/generate-ico.py, assets/AppIcon.ico     create (12)
scripts/team-interop-check.sh                   create (19): Mac Network.framework ↔ openssl s_server/s_client
Sources/CWinShim/{include/CWinShim.h, shim.c}   create (2): placeholder; grows: wic.cpp (6), crash.c (11)
Sources/CTeamTLS/{include/CTeamTLS.h, CTeamTLS.c}   create (2), grows (16)
Sources/PokeTokenBarWin/main.swift              create (2): synchronous, two lines
Sources/PokeTokenBarWin/{PokeTokenBar.rc, app.manifest}   create (12)
Sources/PokeTokenBar/Platform/
  PlatformCompat.swift                          modify (3, 4, 9): isBundledApp, logsDirectory, pathVariableKey, executableCandidates,
                                                toolDirectories, userApplicationSupport, searchProcessPath, isBatchSafe,
                                                pid_t and errSecItemNotFound on non-Darwin
  Platform.swift                                modify (7): two selector lines, once
  PlatformShell.swift                           create (10): open(URL), terminate()
  Mac/MacShell.swift                            create (10): the two AppKit calls, verbatim
  OAuthKeychainUnavailable.swift                create (9): `#if os(Windows) || PTB_SHARED_ONLY` stand-ins for the two Keychain helpers
  TrayMenuModel.swift, BalloonQueue.swift, DayBoundary.swift, ReachabilityTransition.swift,
  InstallerReleaseFeed.swift, AppWiring.swift   create: shared, pure, tested on both OSes
  Windows/                                      every file wrapped in #if os(Windows)
    WindowsPlatform.swift                       modify (7): stubs by default; live(...) installed by the app
    WindowsApp.swift (2, 5), WindowsInstall.swift (3), WinPath.swift (3),
    WinMainLoop.swift, WinMessageHook.swift, WinSinkWindow.swift, WinSingleInstance.swift,
    WinDefaultsSync.swift (incl. WinSyncingDefaults), WindowsSelftest.swift, WinImeCheck.swift   create (5)
    WinTray.swift, WinIcon.swift                create (6)
    WindowsSystemEvents.swift, WindowsIdleClock.swift, WindowsReachability.swift   create (7)
    WinBalloonPresenter.swift, WindowsNotifications.swift                       create (8)
    WindowsLimitsProviders.swift                create (9)
    WindowsLoginItem.swift, WindowsShell.swift  create (10)
    WindowsCrashLog.swift                       create (11)
    Team/WinTLS.swift (16), Team/WinSocketLoop.swift (17), Team/WinDNSSD.swift (18),
    Team/WindowsTeamTransport.swift, Team/WindowsTeamProbe.swift (19)
Sources/PokeTokenBar/Team/TeamTransportRules.swift    create (14): constants + TeamLinkReceiver, shared
Sources/PokeTokenBar/Team/TeamTransport.swift         modify (14): uses the rules; behaviour identical
Sources/PokeTokenBar/Core/UsageStore.swift            modify (2a): two Timer call sites (upstream-owned)
Sources/PokeTokenBar/Core/{AppEnv,AppLog}.swift       modify (3): one line each (upstream-owned)
Sources/PokeTokenBar/Core/BinaryLocator.swift         modify (4): path key, candidates, tool dirs, PATH fallback (upstream-owned)
Sources/PokeTokenBar/Core/{LocalUsageReader,LocalAdditionalUsageProvider}.swift   modify (4): Claude Desktop / Cursor base (upstream-owned)
Sources/PokeTokenBar/Core/ProcessRunner.swift         modify (4, only if the orphan test fails): one call through PlatformCompat
Sources/PokeTokenBar/Core/ClaudeOAuthLimitsProvider.swift   create (9): the file-credential half, moved verbatim (upstream-owned area)
Sources/PokeTokenBar/Core/OAuthLimitsProvider.swift   modify (9): keeps only the Keychain half (stays Mac-only)
Sources/PokeTokenBar/Core/UpdateChecker.swift         modify (10): AppKit → PlatformShell (upstream-owned); leaves mac-only.txt
Tests/PokeTokenBarTests/
  TeamTransportContract.swift                   create (15): harness protocol + scenarios (both OSes)
  TeamTransportTests.swift                      modify (15): becomes the Mac wrapper (stays Mac-only)
  TeamSessionLoopbackTests.swift                modify (15): scenario moved into the contract; file becomes a wrapper
  TeamTransportContractScanTests.swift          create (15)
  WindowsSeamScanTests.swift                    create (2a), grows (3, 5): timer ban, library-dir ban, sync main.swift, single exit, assumeIsolated ban
  Windows*Tests.swift                           create (3, 4, 5–11, 16–19), each wrapped in #if os(Windows)
  <shared pure tests>                           create next to their subjects
docs/reference/defect-log.md, docs/reference/provider-extension.md, CONTRIBUTING.md, spec §9.1/§10/§13   modify (2a, 3, 4, 13, 20)
```

## Review Focus

Five ways this could look done and be wrong:

1. **Main-loop work that doesn't run, runs on the wrong thread, runs too early, or arrives garbled — in the real app while XCTest is green.** XCTest drives the run loop its own way. Concrete traps: a window created before `RunLoop.main` is touched gets nothing (F4); `Timer(timeInterval:)` fires at once (F14); CF's ANSI pump turns non-ACP text into `?` (F15).
   → Task 5's selftest asserts, inside the shipped loop: a `Task`, a `DispatchQueue.main` block, a `Timer`, a posted message and a cross-thread `SendMessageTimeoutW` each run on the main thread; posted and typed U+D55C arrive whole; and the first `UsageStore` timer refresh comes no earlier than its interval.
2. **Green on the runner, broken on a clean PC.** Causes: DLLs picked up from the toolchain folders on `Path` (F21); `isBundledApp` false in the CI layout, hiding the log trap and persistence bugs; settings lost on exit because nothing synchronizes (F2); settings written under a user-name folder that isn't the profile (R9); `Path` vs `PATH` duplicated in child environments.
   → A stripped-`Path` selftest from the packaged folder; a selftest of the installed copy; the two-process defaults check through each exit path; `defaults.location`; trigger tests with a real `"Path"` key (Task 4).
3. **Wire compatibility assumed from shared code but broken by the transport.** Examples: instance naming, self-filter, TLS settings, partial `SSL_read`/pending data, a push-model reader that turns an honest sync into a "flood".
   → One contract suite on both transports, pull-model receive (D6), known-answer tests on both OSes, OpenSSL CLI interop on both sides, and the real Mac ↔ PC run.
4. **A service that returns OK and does nothing.** Examples: `NIF_INFO` returns TRUE (it does on the runner) but no balloon is visible; a Run value written but disabled in `StartupApproved`; a firewall rule created as Block; a connectivity hint registered but never called; a `UserDefaults` subclass that misses typed setters (G-i).
   → Each selftest check asserts an observable effect where one exists (initial connectivity callback, registry read-back, a second process exiting 3, the plist read back from disk). The rest are PC items that read the actual state (netsh rule action and profile, StartupApproved byte, Notification Center).
5. **Idle CPU fine by one measure and burned by another or elsewhere:** `GetProcessTimes` reading 0 for a loop that wakes 4 times a second (F20), explorer.exe redraws from tray updates, `WSAPoll` with a timeout, a browse restarted on a timer, a safety sync with no tolerance.
   → All idle measurements use cycles and context switches, and sample both processes. `WSAPoll(INFINITE)` is a review checkpoint in Task 17. The tray is static.

Also check in every review: no Mac-visible difference. Each Mac-touching task names the Mac test that pins the old value.

---

### Task 1: Experiment E1 — the main loop and Foundation-on-Windows facts — **DONE (2026-11-14)**

**Result.** The run is on `spike/windows-port` (`spike/e1/`, jobs `e1` and `e1cov`, runs R1–R5 linked in `spike/RESULTS.md` § Experiment 5). **Strategy 1 works with no SPI at all.** No CoreFoundation symbol is exported (G-c refuted), but `RunLoop.main`'s own initializer switches on CF's Win32 message mask. So `while !done { RunLoop.main.run(mode: .default, before: .distantFuture) }` on the main thread serves Win32 messages, `@MainActor` jobs, `DispatchQueue.main` and `Timer`s on one thread, with 0 main-thread cycles at idle and sub-millisecond latency.

The limits and new facts:
- CF's pump is ANSI and cannot be replaced; a thread-local `WH_GETMESSAGE` hook fixes text (F15).
- An async `main` loses the main thread (G-b confirmed).
- `MainActor.assumeIsolated` is safe in WndProcs and traps off-main (F16).
- Modal loops hold work until they return; a 16 ms drain timer fixes that (F17).
- The runner has a working tray and desktop (F18).
- `.cmd` shims mangle cmd metacharacters (F19).
- `GetProcessTimes` is useless for idle gates (F20).
- `UserDefaults` writes `<processName>.plist` (with `.exe`) only on `synchronize()` and loses changes even on `exit(0)` (F2).
- corelibs `Timer(timeInterval:…)` fires at once (F14).
- All 11 WinSDK APIs the plan needs import from Swift directly.

Fallback: the `dhc` variant (D2). Polling: rejected. Still unproven: IME on a Korean-locale PC, balloon visibility, idle on a real PC.

---

### Task 2: Build skeleton — Windows-only targets, cached OpenSSL, app workflow

**Files:**
- Modify: `Package.swift` (the `windowsBuild` branch only), `.github/workflows/windows.yml` (setup step → composite action)
- Create: `windows/vcpkg.json`, `.github/actions/windows-swift/action.yml`, `.github/workflows/windows-app.yml`, `scripts/windows/package.ps1` (v1: the exe, every DLL from both `Runtimes\…\usr\bin` and `Toolchains\…\usr\bin` (F21), `PokeTokenBar.version`), `Sources/CWinShim/{include/CWinShim.h, shim.c}` (placeholder), `Sources/CTeamTLS/{include/CTeamTLS.h, CTeamTLS.c}`, `Sources/PokeTokenBarWin/main.swift`, `Sources/PokeTokenBar/Platform/Windows/WindowsApp.swift`

**Interfaces:**
- Produces:
  - In the manifest:
    - `let onWindows: Bool` (true only under `#if os(Windows)`);
    - `let opensslDir = env["PTB_OPENSSL_DIR"] ?? "C:/vcpkg/installed/x64-windows-static-md"`;
    - targets `CWinShim` (`cxxLanguageStandard` C++17 for the later WIC file; links `windowscodecs`, `ole32`, `dbghelp`), `CTeamTLS`, `.executableTarget("PokeTokenBarWin")` and product `.executable(name: "PokeTokenBarWin", targets: ["PokeTokenBarWin"])`, all only when `onWindows`;
    - `PokeTokenBar` gains `+ (onWindows ? ["CWinShim", "CTeamTLS"] : [])` and, only when `onWindows`, `linkerSettings: [.linkedLibrary("dnsapi"), .linkedLibrary("iphlpapi"), .linkedLibrary("user32"), .linkedLibrary("shell32"), .linkedLibrary("advapi32"), .linkedLibrary("ws2_32"), .linkedLibrary("dbghelp")]` (E1 P12's set), so no later task edits the manifest.
  - C: `int ptb_shim_abi(void)`, `const char *ptb_tls_openssl_version(void)`.
  - Swift: `public enum WindowsApp { public static func main() -> Int32 }`. In this task it touches `RunLoop.main` first (F4) and handles `--selftest --selftest-out <path>` by writing `{"result":"pass","version":…,"openssl":…}`.
  - `main.swift`: `import PokeTokenBar` / `exit(WindowsApp.main())`. Synchronous; no `await`.
  - Composite action: no inputs; sets `PTB_OPENSSL_DIR`; logs cache hit or miss and the install time.

**Steps:**
- [ ] Write the manifest change. `CTeamTLS` `cSettings: [.unsafeFlags(["-I\(opensslDir)/include"])]` and `linkerSettings: [.unsafeFlags(["-L\(opensslDir)/lib"]), .linkedLibrary("libssl"), .linkedLibrary("libcrypto"), .linkedLibrary("crypt32"), .linkedLibrary("ws2_32"), .linkedLibrary("advapi32"), .linkedLibrary("user32")]`. If G-h fails, use `-Xlinker /LIBPATH:`. The executable links with `/SUBSYSTEM:WINDOWS /ENTRY:mainCRTStartup`.
- [ ] `windows-app.yml`:
  - Triggers (*ruling*): push to `windows-port`; `pull_request` filtered to Windows paths: `Sources/PokeTokenBar/Platform/**`, `Sources/CWinShim/**`, `Sources/CTeamTLS/**`, `Sources/PokeTokenBarWin/**`, `Tests/PokeTokenBarTests/Windows*`, `Package.swift`, `windows/**`, `scripts/windows/**`, `installer/**`, `.github/workflows/windows-app.yml`, `.github/actions/windows-swift/**`. Also `workflow_dispatch`. Concurrency per ref.
  - Steps: composite action → `swift build -c release --product PokeTokenBarWin` → `package.ps1 -Out bundle` → run `bundle\PokeTokenBar.exe --selftest --selftest-out st.json` with `Path` reduced to `C:\Windows\System32;C:\Windows` → assert `result == pass` → upload `bundle` and `st.json`.
- [ ] Mac checks: `swift build` (manifest still valid; the Mac branch is unchanged) and `./scripts/shared-check.sh` (no Windows-only target is declared under `PTB_SHARED_ONLY`).
- [ ] Push. `windows.yml` stays green (≥ 1000 tests). `windows-app.yml` is green; record the cold and warm vcpkg times in the PR.
- [ ] **PR `build: add the Windows app skeleton and cached OpenSSL`**, merge. Tell the Track A session about the composite action and that `Package.swift`'s `windowsBuild` branch now has Windows-only targets.

**Verify:** on the Mac, `swift build` → `Build complete!` and `./scripts/shared-check.sh` → exit 0. On Windows, both workflow runs exit 0, and the `st.json` artifact contains `"openssl":"OpenSSL 3.`. **Size:** M. **PC:** no.

---

### Task 2a: Timers that fire at once on Windows (F14)

A defect in shared upstream code that E1 found. It can start now.

**Files:**
- Modify: `Core/UsageStore.swift` (upstream-owned: `reschedule()` ~line 1030 and `suspendPolling()` ~line 1048), `docs/reference/defect-log.md`
- Create: `Tests/PokeTokenBarTests/WindowsSeamScanTests.swift`
- Test (both OSes): `Tests/PokeTokenBarTests/UsageStoreTimerTests.swift`

**Interfaces:**
- Call-site edits (Mac-identical; Darwin's `Timer(timeInterval:repeats:block:)` already first fires after the interval, E1 TIMER on this Mac):
  - `Timer(timeInterval: refreshInterval, repeats: true) { … }` → `Timer(fire: Date(timeIntervalSinceNow: refreshInterval), interval: refreshInterval, repeats: true) { … }`
  - `Timer(timeInterval: Self.suspendedProbeInterval, repeats: true) { … }` → the same shape with `Self.suspendedProbeInterval`.

  `tolerance`, `RunLoop.main.add(_, forMode: .common)` and the block bodies stay unchanged.
- Produces: `WindowsSeamScanTests.testNoTimerIntervalInitializerInSharedOrWindowsCode`. It fails on `Timer(timeInterval:` or `Timer.init(timeInterval:` in any file outside `mac-only.txt`, with "fires at once on Windows; use Timer(fire: Date(timeIntervalSinceNow: i), interval: i, …)". The file grows in Tasks 3 and 5.

**Steps:**
- [ ] **Root cause (for the PR):** corelibs implements `init(timeInterval:repeats:block:)` as `init(fire: Date(), …)` (F14).
  - On Windows the polling timer refreshes at once on every `reschedule()` (launch, every interval change); with `autoRefresh`, that is a double refresh at launch.
  - The display-off probe runs at once instead of after 300 s, parsing logs while the display is off.
  - **Why tests missed it:** no test waits on the timer's first fire; the Windows suite runs `UsageStore` with injected providers and never measures timing.
  - **Reachability:** every Windows launch (`reschedule()` in `UsageStore.init`), and the probe from Task 7 on (display-off events).
- [ ] Failing test on Windows, passing on the Mac before and after: `testPollingTimerFirstFiresAfterTheInterval`.
  - `UsageStore(providers: [counting stub], autoRefresh: false, defaults: TestDefaults.make(suite:))` with `refreshInterval = 0.5` stored before init.
  - Asserts 0 fetches at +0.25 s and ≥ 1 by +1.0 s.

  For the probe: read `runSuspendedPollingProbe()` and assert on what it touches within 0.3 s of `suspendPolling()`. If it touches nothing observable, the scan below is its guard; say so in the PR.
- [ ] Class sweep: `grep -rn "Timer(timeInterval" Sources`. Today: `UsageStore.swift` ×2 (shared), `PokeTokenBarApp.swift` and `Team/TeamTransport.swift` (both Mac-only, untouched). Also check `Timer.scheduledTimer(withTimeInterval:)` (fine on both, F14) and `asyncAfter` (fine).
- [ ] Fix the two call sites. Add the scan; fault-inject by re-adding `Timer(timeInterval:` in a shared file → fails. Revert.
- [ ] `defect-log.md`: start the Windows-Foundation class entry ("Foundation on Windows differs silently: timers, search paths, bundle, defaults"); Tasks 3 and 5 add to it.
- [ ] `swift test --filter "UsageStoreTimerTests|WindowsSeamScanTests|UsageStore"`, then `./scripts/shared-check.sh`. Push → Windows run: the new test passes (it failed before the fix — record the failing run in the PR).
- [ ] **PR `fix(windows): start the usage timers after their interval`**, merge. The body lists the two upstream lines. Tell Track A about the scan.

**Verify:** as above. **Size:** S. **PC:** no.

---

### Task 3: Foundation-on-Windows seams — bundled-app rule, the log folder, native paths

The fix for F1 + F3, in the same defect class as Task 2a.

**Files:**
- Modify: `Platform/PlatformCompat.swift`, `Core/AppEnv.swift` (1 line), `Core/AppLog.swift` (1 expression), `Tests/PokeTokenBarTests/WindowsSeamScanTests.swift`, `docs/reference/defect-log.md`
- Create: `Platform/Windows/WindowsInstall.swift`, `Platform/Windows/WinPath.swift`, `Tests/PokeTokenBarTests/WindowsFoundationTests.swift`
- Test (both OSes): additions to `PlatformCompatTests.swift`

**Interfaces:**
- Produces:
  ```swift
  extension PlatformCompat {
      /// Mac: `Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")`, verbatim, computed per call.
      /// Windows: `WindowsInstall.isPackagedLayout`, computed once (bundleIdentifier is always nil there, F3).
      static var isBundledApp: Bool { get }
      /// Mac: `FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs")`, verbatim.
      /// Windows: `<applicationSupport>/PokeTokenBar/Logs` (= %LOCALAPPDATA%\PokeTokenBar\Logs).
      static func logsDirectory() -> URL
  }
  enum WindowsInstall {                                      // Windows only
      static let versionFileName = "PokeTokenBar.version"
      static let shippedExecutableName = "PokeTokenBar.exe"  // frozen: the settings file is named after it (F2)
      static func isPackagedLayout(executableDirectory: URL) -> Bool   // version file present and non-empty
      static var isPackagedLayout: Bool { get }              // Bundle.main.bundlePath = the exe folder (F3)
      static var version: String? { get }                    // trimmed file contents
  }
  enum WinPath {                                             // Windows only
      static func native(_ url: URL) -> String               // backslashes, no trailing slash, for Win32 shell APIs
      static func sameFile(_ a: URL, _ b: URL) -> Bool       // case- and separator-insensitive (F1)
  }
  ```
  `AppEnv.isBundledApp` returns `PlatformCompat.isBundledApp`. `AppLog.url` uses `PlatformCompat.logsDirectory()`.

**Steps:**
- [ ] **Root cause (for the PR):** `AppLog` indexes `[0]` on a search path that Windows doesn't map (F1). Tests never saw it because `AppLog.write` returns early outside a bundle, and on Windows nothing is a bundle (F3). The same gate hid persistence and live limits.
  **Class sweep:** every `urls(for:in:)[0]` in `Sources`. Six use `.applicationSupportDirectory` (mapped, safe); `AppLog` and the Mac-only `CrashReporter` use `.libraryDirectory`. List them in the PR.
  **Reachability:** after this task `isBundledApp` is true in the packaged layout, so the trap becomes reachable and is fixed in the same PR.
- [ ] Failing tests:
  - `testBundledAppRuleOnTheMacIsUnchanged`, `testLogsDirectoryOnTheMacIsLibraryLogs` (Mac: each equals the old expression);
  - `testLibraryDirectoryIsUnmappedOnWindows` (Windows: count 0; documents F1);
  - `testLogsDirectoryIsUnderLocalAppData` (Windows, compared with `WinPath.sameFile`, because Application Support has forward slashes and `NSHomeDirectory()` backslashes);
  - `testNotBundledUnderSwiftTest` (both);
  - `testPackagedLayoutNeedsTheVersionFile` (Windows: temp dir with, without and with an empty file);
  - `testNativePathUsesBackslashes` (Windows).
- [ ] Capture: `WindowsSeamScanTests.testSharedFilesDoNotAskForTheLibraryDirectory`. A shared file outside `Platform/` that contains `.libraryDirectory` fails, with "use PlatformCompat.logsDirectory()". Fault-inject once by adding a `.libraryDirectory` use → fails.
- [ ] Implement. Run `swift test --filter "PlatformCompatTests|WindowsSeamScanTests|LiveCredentialCallGateTests"`, then `./scripts/shared-check.sh`.
- [ ] `defect-log.md`: add search paths and bundle to the class entry.
- [ ] **PR `fix(windows): give the Windows app a bundled-app rule and a log folder`**, merge. The body lists the two upstream lines.

**Verify:** Mac filters pass; Windows run green with the new Windows tests counted. **Size:** S. **PC:** no.

---

### Task 4: Tool directories, log roots and tool launching on Windows

**Files:**
- Modify: `Platform/PlatformCompat.swift`; `Core/BinaryLocator.swift` (`augmentedEnvironment`, `commonToolDirectories`, `commonNodeToolPaths`, `locate`); `Core/LocalUsageReader.swift` (the Claude Desktop line); `Core/LocalAdditionalUsageProvider.swift` (Cursor roots in `defaultCursorRoots` and `cursorRoots`); `Core/ProcessRunner.swift` (one call, only if the orphan test fails); `docs/reference/provider-extension.md` (the D3 table and the batch-shim rule); `docs/reference/defect-log.md`
- Test: `Tests/PokeTokenBarTests/WindowsPathTests.swift` (extend), `BinaryLocatorTests.swift` (Mac pins), `WindowsProcessTests.swift` (Windows), `ToolLaunchArgumentTests.swift` (both)

**Interfaces:**
- Produces:
  ```swift
  extension PlatformCompat {
      /// Mac: "PATH". Windows: the key already in `env` that equals "PATH" ignoring case ("Path" in practice), else "Path".
      static func pathVariableKey(in env: [String: String]) -> String
      /// Mac: [path]. Windows: path + each PATHEXT extension in order (.exe first if PATHEXT is unset: .exe, .cmd, .bat, .com).
      static func executableCandidates(_ path: String) -> [String]
      /// Mac: `posix`, unchanged. Windows: the tool directories of D3 that exist in the environment.
      static func toolDirectories(posix: [String]) -> [String]
      /// Mac: home/Library/Application Support. Windows: home/AppData/Roaming.
      static func userApplicationSupport(home: URL) -> URL
      /// Mac: nil (the Mac keeps its login-shell lookup). Windows: the first candidate found in `environment`'s Path entries.
      static func searchProcessPath(_ binary: String, environment: [String: String]) -> String?
      /// True when `arg` can pass through cmd.exe unchanged: none of & | < > ^ % ! and no newline (F19).
      static func isBatchSafe(_ arg: String) -> Bool
      /// Only if the orphan test fails — Mac: `process.terminate()`, verbatim. Windows: end the process and its descendants
      /// (Toolhelp32 parent-pid walk + TerminateProcess), so a .cmd shim's child does not outlive it.
      static func terminate(_ process: Process)
  }
  ```
  Upstream edits, each Mac-identical:
  - `augmentedEnvironment` reads and writes `base[PlatformCompat.pathVariableKey(in: base)]`.
  - `commonToolDirectories()` returns `PlatformCompat.toolDirectories(posix: [<today's literal list>])`.
  - `commonNodeToolPaths` is `flatMap { PlatformCompat.executableCandidates("\($0)/\(binary)") }`.
  - `locate` step 2 is `PlatformCompat.searchProcessPath(binary, environment: ProcessInfo.processInfo.environment) ?? shellResolve(binary)`.
  - Desktop and Cursor bases go through `userApplicationSupport(home:)`.
  - Conditionally, `ProcessRunner`'s timeout path calls `PlatformCompat.terminate(process)` instead of `process.terminate()`.

**Steps:**
- [ ] **Defect (found by reading):** on Windows the process environment's key is `Path`. `augmentedEnvironment` reads `base["PATH"]` (nil) and writes `env["PATH"]`, so child processes get both keys (which one wins is undefined).
  **Why stage 1 missed it:** `testAugmentedPathUsesThePlatformSeparator` injects `["PATH": …]`, not the `Path` key a real Windows process has.
  **Reachability:** every child process spawned with `augmentedEnvironment` (Codex limits, the shell lookup).
- [ ] Failing tests:
  - `testAugmentedEnvironmentKeepsOnePathKey`. Base `["Path": "C:\\a;C:\\b"]`. Windows: exactly one key matching PATH case-insensitively, containing `C:\a` and the tool dirs. Mac: the output equals today's for the same base (pins the Mac).
  - Mac pins: `testCommonNodeToolPathsOnTheMacAreUnchanged` (equals today's literal list), `testCursorRootsOnTheMacAreUnchanged`, `testClaudeDesktopRootOnTheMacIsUnchanged`.
  - Windows: `testExecutableCandidatesPreferExe`, `testSearchProcessPathFindsACmdShim` (temp dir with `codex.cmd`, env `Path=<dir>`), `testCursorRootsAreUnderRoamingAppData`, `testClaudeDesktopRootIsUnderRoamingAppData`.
- [ ] **Batch-shim rule (F19).**
  - `ToolLaunchArgumentTests.testEveryLaunchedToolArgumentIsBatchSafe` (both): reads the argument lists the code passes today (Codex `["app-server", "--stdio"]`; each other `ProcessRunner` call site found by grep) and asserts `isBatchSafe` on each. A future free-form argument fails here with the rule from Global Constraints.
  - `testBatchSafetyRejectsCmdMetacharacters` (both).
  - Reachability: no free-form argument reaches a shim today, so no runtime guard is added (defect protocol step 3).
- [ ] **Orphaned children (F19, untested in E1).** `WindowsProcessTests.testTerminatingACmdShimEndsItsChild`: a temp `.cmd` starts `powershell -c Start-Sleep 30`, then `ProcessRunner`'s timeout path runs (or `Process.terminate()` directly). Assert the child is gone within 3 s.
  - If it is gone: record that and do nothing else.
  - If it survives, it is a reachable defect (Codex `app-server` timeouts): add `PlatformCompat.terminate(_:)`, route the `ProcessRunner` call, keep the Mac path verbatim, and list the upstream line.
- [ ] Implement. Fault-inject: on Windows make `pathVariableKey` return `"PATH"` → the trigger test fails. Revert.
- [ ] Unknown rows stay unchanged and are documented as unknown in `provider-extension.md`, together with the batch-shim rule.
  UNC and mixed-separator custom roots are deferred to stage 7. Reachability: custom roots come only from Settings, which doesn't exist on Windows yet. A differently cased `CLAUDE_CONFIG_DIR` duplicates a scan but doesn't change totals.
- [ ] `swift test --filter "BinaryLocatorTests|WindowsPathTests|CustomScanRootsTests|ToolLaunchArgumentTests|ProcessRunner"`, then `shared-check.sh`. Push → Windows green.
- [ ] **PR `fix(windows): find and launch tools the Windows way`**, merge. The body lists the upstream lines.

**Verify:** as above. **Size:** M. **PC:** no.

---

### Task 5: App core — loop, message hook, sink window, single instance, defaults sync, stores, selftest **[most capable]**

Milestone: run the full Mac gate after this task (speed rules).

**Files:**
- Create (all `Platform/Windows/`): `WinMainLoop.swift`, `WinMessageHook.swift`, `WinSinkWindow.swift`, `WinSingleInstance.swift`, `WinDefaultsSync.swift`, `WindowsSelftest.swift`, `WinImeCheck.swift`
- Create: `Platform/AppWiring.swift` (shared)
- Modify: `WindowsApp.swift`, `Tests/PokeTokenBarTests/WindowsSeamScanTests.swift`, `.github/workflows/windows-app.yml` (fixture env)
- Create: `Tests/PokeTokenBarTests/Fixtures/windows-selftest/claude/projects/p/s.jsonl`
- Test: `Tests/PokeTokenBarTests/WindowsShellTests.swift` (Windows), `AppWiringTests.swift` (both), `AppWiringDriftScanTests.swift` (Mac)

**Interfaces:**
- Consumes: Task 3's `WindowsInstall`, `WinPath`; Task 2a's fixed timers.
- Produces:
  ```swift
  enum WinMainLoop {
      enum Strategy: String, Equatable { case cfRunLoopWithMessages, dispatchHandle }   // polling rejected (E1 P4)
      static func prepare(environment: [String: String] = ProcessInfo.processInfo.environment) -> Strategy
          // touches RunLoop.main first; .dispatchHandle only when PTB_WIN_LOOP=dispatch (diagnostics); logs once
      static func run(_ strategy: Strategy, until done: @escaping @MainActor () -> Bool)
  }
  @MainActor enum WinMessageHook {
      static func install() -> Bool                                // SetWindowsHookExW(WH_GETMESSAGE, proc, nil, GetCurrentThreadId())
      static var redispatchedChars: Int { get }                    // selftest counter
      static func registerDialogWindow(_ hwnd: HWND)               // for stage 7's IsDialogMessageW; unused in stage 4
  }
  @MainActor final class WinSinkWindow {                           // hidden top-level window (not HWND_MESSAGE:
      static let className = "PokeTokenBarSink"                    // broadcasts like WM_POWERBROADCAST, WM_ENDSESSION
      init() throws                                                // and TaskbarCreated reach only top-level windows)
      var hwnd: HWND { get }
      func on(_ message: UINT, _ handler: @escaping @MainActor (WPARAM, LPARAM) -> LRESULT?)
      func onRegistered(_ name: String, _ handler: @escaping @MainActor () -> Void)
  }
  enum WinSingleInstance {
      enum Outcome: Equatable { case acquired, yielded }
      static func mutexName(stateDirectory: URL, defaultDirectory: URL) -> String   // "Local\\PokeTokenBar-Team" or with "-<6 hex>"
      static func acquire(name: String) -> Outcome                 // on .yielded, posts WM_APP_SHOW to the running sink
  }
  final class WinSyncingDefaults: UserDefaults {                   // suiteName nil = the standard domain (F2)
      override func set(_ value: Any?, forKey defaultName: String) // + removeObject; + typed setters if G-i fails
  }
  @MainActor enum WinDefaultsSync {
      static let debounce: TimeInterval = 2, safetyInterval: TimeInterval = 30
      static func start()                                          // safety Timer(fire:), tolerance 10 s
      nonisolated static func noteWrite()                          // any thread → DispatchQueue.main.async → re-arm the debounce
      static func flushNow()                                       // UserDefaults.standard.synchronize()
      static func expectedPlistURL() -> URL                        // <GetProfilesDirectoryW>\<GetUserNameW>\AppData\Local\<processName>.plist
  }
  enum AppWiring {                                                 // shared; the Mac keeps its own copy in AppDelegate
      @MainActor static func updateCompanion(_ companion: CompanionStore, from store: UsageStore)
      @MainActor static func storeRefreshed(_ companion: CompanionStore, _ store: UsageStore)
  }
  @MainActor final class WindowsAppDelegate {
      init(arguments: [String])
      func launch() -> Bool                                        // false = yielded or failed (logged)
      private(set) var store: UsageStore!; private(set) var companion: CompanionStore!; let teamSettings: TeamSettings
  }
  extension WindowsApp {
      enum ExitReason { case menu, endSession, closeRequest, selftest, helper, launchFailed }
      @MainActor static func exit(_ code: Int32, _ reason: ExitReason) -> Never
          // the only exit: flushNow(), AppLog.writeAndFlush, tray remove, then exit(code)
  }
  enum WindowsSelftest {
      struct Check: Codable, Equatable { let name: String; let ok: Bool; let detail: String }
      @MainActor static func run(_ app: WindowsAppDelegate) async -> [Check]
      static func write(_ checks: [Check], to url: URL) throws
  }
  ```
  Process flags:
  - `--selftest`, `--selftest-out <path>`;
  - internal: `--selftest-second`, `--selftest-defaults-writer <syncing|standard|raw> <exit|kill> <key> <value>`;
  - `--ime-check` (a small window with an `EDIT` control; logs the code points it receives; for the PC);
  - `--autostart`, `--version`.

**Steps:**
- [ ] Launch order (mirrors `AppDelegate.applicationDidFinishLaunching`):
  1. `_ = RunLoop.main` (F4; before any window);
  2. single instance (before anything that writes);
  3. crash log hook (a no-op until Task 11);
  4. `SetProcessDpiAwarenessContext(PER_MONITOR_AWARE_V2)`;
  5. `WinMainLoop.prepare()`;
  6. sink window;
  7. `WinMessageHook.install()`;
  8. `Platform.current = WindowsPlatform.live(window:)` (stubs until Tasks 7–9 fill parts);
  9. `let defaults = WinSyncingDefaults()`;
  10. `UsageStore(defaults: defaults)`, `CompanionStore()`, `Task { await companion.preparePokemonProfiles() }`, `store.localizationLanguage = companion.language`, `store.onRefresh = { AppWiring.storeRefreshed(companion, store) }`;
  11. `TeamSettings(defaults: defaults)` when `TeamSettings.suiteName(...)` is nil, else its suite wrapped the same way;
  12. `WinDefaultsSync.flushNow(); WinDefaultsSync.start()`;
  13. `observeStore`, the same `withObservationTracking` shape as the Mac (no tray yet; it calls `AppWiring.updateCompanion`);
  14. `WinMainLoop.run`.

  `WM_ENDSESSION(TRUE)` and `WM_CLOSE` on the sink → `WindowsApp.exit(0, .endSession / .closeRequest)`.
- [ ] `AppWiring` copies `updateCompanion` / `onStoreRefreshed` from `PokeTokenBarApp.swift:375–392`. `AppWiringDriftScanTests` (Mac) extracts the argument labels of `companion.update(` and the `grantCandies(` call from both files and asserts they are equal. Fault-inject by dropping a label → fails.
- [ ] Scans in `WindowsSeamScanTests`:
  - `testWindowsMainIsSynchronous` (`main.swift` has no `await`/`async`; F16);
  - `testWindowsCodeExitsOnlyThroughWindowsAppExit` (no `exit(`, `ExitProcess(`, `TerminateProcess(GetCurrentProcess` in `Platform/Windows/**` outside `WindowsApp.exit`);
  - `testNoAssumeIsolatedInPoolThreadCallbacks` (no `MainActor.assumeIsolated` in `Platform/Windows/Team/**` and the connectivity file).

  Fault-inject each once.
- [ ] Failing tests:
  - `testMutexNameIsFixedForTheDefaultStateFolder`, `testMutexNameDiffersPerStateFolder` (pure; Windows);
  - `testAppWiringPassesEveryUsageInput` (both; injected providers via `UsageStore(providers:…)`, `TestDefaults.make(suite:)`);
  - `testSyncingDefaultsSeesTypedSetters` (Windows; G-i: `set(true, forKey:)`, `set(1, …)`, `set(2.0, …)`, `set("s", …)` each call `noteWrite`).
- [ ] Selftest checks (each in the shipped loop):
  - **Loop:**
    - `loop.strategy` (`cfRunLoopWithMessages` unless overridden);
    - `loop.mainActorTask`, `loop.mainQueue`, `loop.runLoopTimer`, `loop.postedMessage` (main thread id each; posted latency < 50 ms);
    - `loop.crossThreadSend` (`SendMessageTimeoutW` from a thread returns OK in < 50 ms; fails if `RunLoop.main` was touched late, F4);
    - `loop.postedUnicodeChar` (post `WM_CHAR` U+D55C to the sink → the WndProc gets `0xD55C`, `redispatchedChars` ≥ 1);
    - `loop.typedUnicodeChar` (`CI` only: `SendInput(KEYEVENTF_UNICODE)` to a shown foreground test window, with E1's synthetic Alt press to lift the foreground lock).
  - **Paths:** `paths.state` (under `%LOCALAPPDATA%` or `PTB_STATE_DIR`, compared with `WinPath.sameFile`), `paths.logs`.
  - **Log:** `log.writes` (`AppLog.writeAndFlush` then read back; only when `isBundledApp`, otherwise recorded as `skipped: not packaged`).
  - **Defaults** (each writer is a child process; the parent parses `WinDefaultsSync.expectedPlistURL()` with `PropertyListSerialization`):
    - `defaults.persist.debounce`: `syncing kill` — set via `WinSyncingDefaults`, wait 3 s, `TerminateProcess` → present;
    - `defaults.persist.exit`: `standard exit` — set via `.standard`, leave through `WindowsApp.exit` → present;
    - `defaults.control`: `raw exit` — set, then a raw `exit(0)` in the helper only → **absent**. Informational: it documents F2. If Foundation ever starts saving here, the line says so and nothing fails;
    - `defaults.location`: `expectedPlistURL()`'s folder equals `FOLDERID_LocalAppData` (`WinPath.sameFile`), else FAIL with both paths (R9);
    - the plist name is `<ProcessInfo.processName>.plist`, `.exe` included.
  - **Single instance:** `singleInstance.second`: spawn `--selftest-second` → exit code 3.
  - **Store:**
    - `store.refresh`: CI sets `CLAUDE_CONFIG_DIR` to the fixture and `PTB_STATE_DIR` to a temp dir; after `await store.refresh()`, `todayTotalTokens` equals the fixture's sum. The fixture's timestamps are written at run time by the workflow step so they are "today".
    - `store.timer` (can't pass through F14): set `refreshInterval = 2`, whose `didSet` reschedules (`UsageStore.swift:79`). The first timer-driven refresh after that must arrive at ≥ 1.8 s and ≤ 3.5 s. With the bug it arrives at about 8 ms. Then restore the value.
  - **Companion:** `companion.update`: the companion saw `hasUsageData == true`.
- [ ] Push. `windows-app.yml` runs the bundle selftest with the fixture env, so every check passes or is skipped as stated.
- [ ] **PR `feat(windows): run the stores in a Windows app loop`**, merge. Then run the milestone `./scripts/test-gate.sh`.

**Verify:** the `windows-app` `st.json` has `"result":"pass"`, `loop.strategy == cfRunLoopWithMessages` and every `loop.*` check passing. On the Mac: `swift test --filter "AppWiring|WindowsSeamScanTests"`, `shared-check.sh`, then the milestone gate. **Size:** L. **PC:** Task 13 (`--ime-check`, `defaults.location`).

---

### Task 6: Tray icon and menu

**Files:**
- Create: `Platform/Windows/WinTray.swift`, `Platform/Windows/WinIcon.swift`, `Platform/TrayMenuModel.swift` (shared), `Sources/CWinShim/wic.cpp` (CWinShim's first real job: WIC is COM)
- Modify: `WindowsApp.swift`; `Team/TeamLocalization.swift` (only strings `StatusItemMenu` doesn't already have: "Launch at login", "Disabled in Task Manager", "Open log folder", the first-run tray hint, "Already running")
- Test: `TrayMenuModelTests.swift` (both), `WindowsTrayTests.swift` (Windows)

**Interfaces:**
- Produces:
  ```swift
  @MainActor final class WinTray {
      init(window: WinSinkWindow)
      func add() -> Bool; func remove()                                  // add also sets NOTIFYICON_VERSION_4
      func setIcon(_ icon: WinIcon?); func setTip(_ text: String)          // clipped to 127 UTF-16 units
      func showBalloon(title: String, body: String, sound: Bool) -> Bool   // used by Task 8
      func anchorRect() -> RECT?                                         // Shell_NotifyIconGetRect; stage 7 places the popover with it
      var onActivate: (() -> Void)?; var onContextMenu: ((POINT) -> Void)?
      var onBalloonEvent: ((BalloonEvent) -> Void)?; enum BalloonEvent { case clicked, hidden, timedOut }
      var isPresent: Bool { get }
  }
  final class WinIcon { init?(png: Data, size: Int); deinit /* DestroyIcon */ }
  struct TrayMenuModel: Equatable {                                        // shared
      enum Action: Equatable { case none, toggleLaunchAtLogin, openLogFolder, openRelease, refresh, quit }
      struct Item: Equatable { let title: String; let enabled: Bool; let checked: Bool; let action: Action }
      enum LoginState: Equatable { case on, off, disabledByUser, unavailable }
      static func items(l: L, todayTokens: Int, todayCost: UsageCost?, teammatesOnline: Int?,
                        login: LoginState, update: UpdateChecker.Available?) -> [Item?]   // nil = separator
  }
  // CWinShim
  int ptb_png_to_bgra(const uint8_t *png, size_t len, uint32_t *w, uint32_t *h, uint8_t **bgra);   // caller frees with ptb_free
  void *ptb_icon_from_bgra(const uint8_t *bgra, uint32_t w, uint32_t h, uint32_t size);            // nearest-neighbour, returns HICON
  ```

**Steps:**
- [ ] Icon (*ruling*: static in stage 4):
  - The egg comes from `SpriteStore.shared.eggData()`; after hatching, the representative subject's static PNG from `SpriteStore.shared.data(speciesID:animated: false, shiny:form:back:)`.
  - Size = `GetSystemMetricsForDpi(SM_CXSMICON, dpi)`. Re-rendered on `WM_DPICHANGED`/`WM_SETTINGCHANGE`.
  - Observation copies `observeCompanionSprite`'s tracked keys (subject, `facesBack`), without frames. The tooltip tracks `store.menuToolTip`.
- [ ] Menu:
  - Left click opens it (no popover yet); right click opens it too.
  - Items: today's tokens (and cost when `store.showsCost`), separator, "Refresh", "Launch at login" (Task 10 fills its state; `unavailable` until then), "Open log folder" (`ShellExecuteW` on `WinPath.native(PlatformCompat.logsDirectory())`), "Update available…" when set (Task 10), separator, "Quit" (→ `WindowsApp.exit(0, .menu)`).
  - On open: `store.requestNotificationAuthorizationIfNeeded()` and `Task { await updater?.check() }`, as the Mac does on popover open.
  - No drain timer during the menu (F17; stage 4 accepts the hold).
- [ ] `TaskbarCreated` → `add()` again. `WM_APP_SHOW` from a second instance → balloon "Already running". First run (defaults key `windows.trayHintShown`) → balloon with the overflow hint.
- [ ] Tests:
  - `testMenuShowsTodayTokensAndCostOnlyWhenShown`, `testLoginItemStatesMapToChecksAndTitles`, `testUpdateItemAppearsOnlyWithAnUpdate` (both);
  - `testPNGDecodesToTheRightSizeAndAlpha` (Windows; fixture PNG with known corner pixels);
  - `testIconMakesAnHICON` (Windows);
  - selftest, moved here from the PC list because the runner has a real tray (F18):
    - `tray.add` (with `NIM_SETVERSION`), `tray.modify`, `tray.anchorRect` (S_OK), `tray.remove`;
    - `tray.reAddOnTaskbarCreated` (send the registered message to the sink → `NIM_ADD` again → TRUE);
    - `tray.menuKeys` (open the menu from a timer, post `VK_DOWN`/`VK_RETURN`, assert "Refresh" ran: a store refresh starts).
- [ ] **PR `feat(windows): show the companion and today's usage in the tray`**, merge. `UI changes`: a screenshot of the tray icon and the open menu taken on the runner's desktop (`System.Drawing` `CopyFromScreen` in the workflow; F18), and the icon PNG at 16/24/32 px.

**Verify:** Windows run green with every `tray.*` check passing. Mac `swift test --filter TrayMenuModel`. **Size:** M. **PC:** Task 13 (look, overflow, crispness).

---

### Task 7: System events, idle clock, reachability

**Files:**
- Create: `Platform/Windows/WindowsSystemEvents.swift`, `Platform/Windows/WindowsIdleClock.swift`, `Platform/Windows/WindowsReachability.swift`, `Platform/DayBoundary.swift`, `Platform/ReachabilityTransition.swift`
- Modify: `Platform/Platform.swift` (the two selectors, once), `Platform/Windows/WindowsPlatform.swift`
- Test: `DayBoundaryTests.swift` (both), `ReachabilityTransitionTests.swift` (both), `ReachabilityParityTests.swift` (Mac-only: imports Network; listed), `WindowsSystemEventsTests.swift` (Windows)

**Interfaces:**
- Produces:
  ```swift
  @MainActor final class WindowsSystemEvents: SystemEvents {
      init(window: WinSinkWindow?, clock: @escaping @Sendable () -> Date = { Date() }, calendar: Calendar = .current)
      func onWillSleep(_ f: @escaping @Sendable () -> Void)          // Windows extra, used by the transport (Task 19)
      func handlePowerBroadcast(event: UInt32, displayState: UInt32?) // PBT_APMSUSPEND / PBT_APMRESUMEAUTOMATIC / PBT_POWERSETTINGCHANGE
      func handleTimeChange()
      // SystemEvents: onWake, onScreensSleep, onScreensWake, onDayChange, displaysAreAsleep
  }
  enum DayBoundary {
      static func nextLocalMidnight(after: Date, calendar: Calendar) -> Date
      static func dayKey(_ date: Date, calendar: Calendar) -> String
  }
  struct ReachabilityTransition {                                     // Bool form of NetworkReachabilityMonitor.shouldTriggerReconnect
      init(cooldown: TimeInterval = 5)
      mutating func update(isSatisfied: Bool, now: Date) -> Bool      // true = report a reconnect
  }
  final class WindowsReachabilityMonitor: ReachabilityMonitoring, @unchecked Sendable {
      init(cooldown: TimeInterval = 5, clock: @escaping @Sendable () -> Date = { Date() })
      var onReconnected: (@Sendable () -> Void)?; func start(); func stop()
  }
  struct WindowsIdleClock: IdleClock { func secondsSinceLastInput() -> TimeInterval }
  enum WindowsPlatform {
      @MainActor static func make() -> Platform                       // stubs: what swift test sees
      @MainActor static func live(window: WinSinkWindow, notifications: LocalNotifying? = nil) -> Platform
      nonisolated(unsafe) static var limitsFactory: any LimitsProviderFactory   // stub until the app sets it (Task 9)
      nonisolated(unsafe) static var networkWatching: any NetworkWatching       // stub until the app sets it (this task)
  }
  ```
  `Platform.swift`: under `#if os(Windows)`, `PlatformLimits.current` and `PlatformNetwork.current` read `WindowsPlatform.limitsFactory` / `.networkWatching`. `#elseif PTB_SHARED_ONLY` stays the stub; the Mac branch is unchanged. Both are `static let`, built on first access, so the app sets the live values before building any store (asserted by selftest `platform.liveBeforeStores`).

**Steps:**
- [ ] Failing tests:
  - `testNextMidnightAcrossDSTAndMonthEnd`, `testDayKeyMatchesLocalUsageReaderTodayKey` (both);
  - `testColdStartNeverTriggers`, `testOfflineToOnlineTriggersOnce`, `testFlappingInsideTheCooldownIsSuppressed` (both);
  - `testTransitionAgreesWithTheMacMonitorOnEveryPair` (Mac: a table over `NWPath.Status` × history against `NetworkReachabilityMonitor.shouldTriggerReconnect`; catches drift);
  - Windows: `testSuspendCallsWillSleepThenResumeCallsWake`, `testDisplayOffAndOnMapToScreensSleepAndWake`, `testDisplayStateIsReadBack`, `testTimeChangeReArmsTheDayTimer`, `testResumeAfterMidnightFiresDayChangeOnce`, `testIdleSecondsAreFiniteAndNonNegative`.
- [ ] Implement (all Swift via WinSDK, E1 P12):
  - Registrations in `WindowsPlatform.live`: `RegisterSuspendResumeNotification(hwnd, DEVICE_NOTIFY_WINDOW_HANDLE)` and `RegisterPowerSettingNotification(hwnd, &GUID_CONSOLE_DISPLAY_STATE, …)`; `WM_TIMECHANGE` on the sink.
  - The day timer is `Timer(fire:…)` (F14).
  - Connectivity: `NotifyNetworkConnectivityHintChange(…, initialNotification: true)`. The callback is on a pool thread and hops with `DispatchQueue.main.async`, never `assumeIsolated` (F16).
  - Selftest: `events.registered`, `reachability.initialCallback` (≤ 5 s), `idle.value`, `platform.liveBeforeStores`.
- [ ] Fault-inject: swap the suspend and resume branches → the Windows test fails. Drop the cooldown → the shared test fails.
- [ ] `swift test --filter "DayBoundary|ReachabilityTransition|ReachabilityParity|PlatformTests"`, then `shared-check.sh`. Push → Windows green.
- [ ] **PR `feat(windows): wake, sleep, display, day change, idle and network events`**, merge. Tell the Track A session that `Platform.swift` was edited once and new protocols go in new files.

**Verify:** as above. **Size:** M. **PC:** Task 13 (sleep, display off, Wi-Fi).

---

### Task 8: Notifications as tray balloons

*Ruling:* balloons now.

**Files:**
- Create: `Platform/BalloonQueue.swift` (shared), `Platform/Windows/WinBalloonPresenter.swift`, `Platform/Windows/WindowsNotifications.swift`
- Modify: `WindowsApp.swift` (pass `WindowsNotifications` into `WindowsPlatform.live`)
- Test: `BalloonQueueTests.swift` (both), `WindowsNotificationsTests.swift` (Windows)

**Interfaces:**
- Consumes: `WinTray.showBalloon`, `WinTray.onBalloonEvent` (Task 6).
- Produces:
  ```swift
  struct BalloonQueue {                                                // shared, pure
      enum Kind: Equatable { case app, team }
      struct Item: Equatable { let id: String; let title: String; let body: String; let sound: Bool; let kind: Kind }
      static let titleLimit = 63, bodyLimit = 255                      // NOTIFYICONDATAW szInfoTitle/szInfo minus NUL
      init(capacity: Int = 5)
      mutating func offer(_ item: Item) -> Item?                       // the item to show now, or nil (queued; oldest pending dropped at capacity)
      mutating func finished() -> Item?                                // after clicked/hidden/timedOut: the next to show
      static func clipped(_ s: String, limit: Int) -> String           // grapheme-safe, appends "…"
  }
  @MainActor final class WinBalloonPresenter {
      init(tray: WinTray)
      func post(_ item: BalloonQueue.Item)
      var onClick: ((BalloonQueue.Kind) -> Void)?
  }
  @MainActor final class WindowsNotifications: LocalNotifying {
      init(presenter: WinBalloonPresenter, tray: WinTray)
      var isAvailable: Bool { get }                                    // tray.isPresent
      func requestAuthorization() async -> Bool                        // true: balloons have no OS consent step
      func post(id: String, title: String, body: String, sound: Bool)  // kind .app
  }
  ```
  `WindowsTeamNotificationPoster: TeamNotificationPosting` is added in Task 19 on the same presenter. It is a separate type because `requestAuthorization()` has a different signature in each protocol.

**Steps:**
- [ ] Failing tests:
  - `testFirstItemShowsAtOnce`, `testSecondWaitsUntilTheFirstFinishes`, `testCapacityDropsTheOldestPending`, `testClippingKeepsKoreanGraphemesWhole` (both);
  - `testPostCallsShellNotifyIconWithInfo` (Windows: returns TRUE on the runner, F18; `NIIF_NOSOUND` when `sound == false`; `NIIF_RESPECT_QUIET_TIME` always).
- [ ] Implement. Selftest `notify.post` posts "PokeTokenBar self-test" and asserts the call returned TRUE. Whether it is *visible* is the PC check.
- [ ] **PR `feat(windows): post notifications through the tray`**, merge.

**Verify:** Windows green; Mac `swift test --filter BalloonQueue`. **Size:** M. **PC:** Task 13 (visible, in Notification Center; Focus Assist behaviour).

---

### Task 9: Claude limits — move the credentials-file path out of the Keychain file

*Ruling:* move the upstream code verbatim into a shared file, the same method stage 1 used for `Core/LimitsTypes.swift`; no duplicate, no drift scan. No Windows secret store (the stub stays, F8).

**Files:**
- Create: `Core/ClaudeOAuthLimitsProvider.swift` (shared; upstream-owned area, created like `LimitsTypes.swift`; its name ends in `LimitsProvider.swift` so `LiveCredentialCallGateTests`' scan keeps covering the network call), `Platform/OAuthKeychainUnavailable.swift`, `Platform/Windows/WindowsLimitsProviders.swift`
- Modify: `Core/OAuthLimitsProvider.swift` (upstream: keeps only the Keychain half; stays in `mac-only.txt`), `Platform/PlatformCompat.swift` (add `errSecItemNotFound: OSStatus = -25300` to the existing `#if !canImport(Darwin)` block), `WindowsApp.swift` (set `WindowsPlatform.limitsFactory` before the stores), `Tests/PokeTokenBarTests/mac-only.txt` (remove any OAuth test file that needed only the moved code)
- Test: `ClaudeOAuthFileCredentialTests.swift` (both; `URLProtocol` stub + `AppEnv.allowLiveFetchForTesting` reset in `defer`)

**Interfaces:**
- Moved verbatim, without behaviour change, from `Core/OAuthLimitsProvider.swift` to `Core/ClaudeOAuthLimitsProvider.swift`:
  - `struct OAuthLimitsProvider` (with `fetch`, `fetchStatus` and its `AppEnv.allowsLiveLimitsFetch` gate);
  - `actor OAuthProfileCache`, `enum OAuthProfileData`;
  - `actor OAuthAccessTokenCache` with its stored properties, `init`, `forConfigRoot`, `defaultCredentialsFileURL`, `accessToken(allowKeychainPrompt:bypassCache:)`, `firstUsableCredential`, `planInfo`, `invalidate`, `credentialsFileIsAccountOAuthMissing`, `readClaudeCredentialsFile`.

  The new file's imports are `Foundation` + the FoundationNetworking guard. The only edits: the two Keychain helpers `accessToken` calls lose `private` (`private` → internal), because they now live in another file.
- Stays in `Core/OAuthLimitsProvider.swift` (Mac-only, `import Security`):
  - `extension OAuthAccessTokenCache { static func readClaudeKeychainSilently(services:) -> OAuthCredentialData.Credential?; static func readClaudeKeychain(service:allowKeychainPrompt:) throws -> OAuthCredentialData.Credential }`;
  - `extension OAuthCredentialData { claudeKeychainAccountsQuery, claudeKeychainDataQuery, accountNames, prioritizedAccountNames, priority }`.
- Produces:
  ```swift
  // Platform/OAuthKeychainUnavailable.swift — the whole file is `#if os(Windows) || PTB_SHARED_ONLY`
  extension OAuthAccessTokenCache {
      static func readClaudeKeychainSilently(services: [String]) -> OAuthCredentialData.Credential?        // nil: no Keychain here
      static func readClaudeKeychain(service: String, allowKeychainPrompt: Bool) throws -> OAuthCredentialData.Credential
          // throws LimitsError.keychainAccessDisabled
  }
  struct WindowsLimitsProviders: LimitsProviderFactory {
      func claudeOAuth(configRoot: URL?) -> any ClaudeLimitsProviding    // the same body as MacLimitsProviders.claudeOAuth
      func antigravity() -> any AntigravityLimitsProviding               // UnavailableAntigravityLimits (location unknown)
  }
  ```
  On Windows:
  - **Automatic path:** the file's live token, else the Mac's own errors (`credentialMissingAccountOAuth` when the file has no account OAuth, `keychainInteractionNotAllowed` otherwise).
  - **User refresh:** the file, else `keychainAccessDisabled`.

  The Keychain wording of those errors is stage 7's job (no popover yet); note it in the PR.

**Steps:**
- [ ] Move with `git mv`-style evidence: the PR shows `git diff -M --color-moved=zebra` with the moved blocks unchanged except the two access modifiers. Every line of the old file is accounted for (moved, kept, or one of the two `private` removals).
- [ ] Mac pins: the existing OAuth suites on the Mac pass unchanged (`CredentialSwitchCacheTests`, `KeychainAutoPathTests`, `LiveCredentialCallGateTests`, the OAuth/limits tests). The "automatic path makes 0 Keychain calls" guarantee (`KeychainReader.queryCount == 0`) still holds.
- [ ] Failing tests (both OSes, moved code under test):
  - `testFileTokenIsUsedWithoutTheKeychain`, `testExpiredFileTokenIsNotUsed`, `testAccountOAuthMissingAsksForRelogin`, `test401RereadsTheFileOnce`, `test429CarriesRetryAfter`, `testGateClosedUnderSwiftTestWithoutTheTestingFlag`;
  - Windows: `testUserRefreshWithoutAFileReportsKeychainAccessDisabled`.
- [ ] Selftest `limits.claude`: `OAuthLimitsProvider(accessTokenCache: .forConfigRoot(fixtureRoot))` with a fixture credentials file.
  - Not packaged → `.liveFetchNotPermitted`, which proves the file was read up to the network boundary.
  - Installed (gate open) → the fixture token gets 401 → recorded, not failed.
- [ ] `swift test --filter "ClaudeOAuthFileCredential|LiveCredentialCallGate|KeychainAutoPath|CredentialSwitchCache|OAuth"`, then `shared-check.sh` (the moved file now builds in the shared set). Push → Windows green.
- [ ] **PR `refactor(core): share the Claude credentials-file limits path`**, merge. The body lists the moved ranges, the two access changes and the new constant.

**Verify:** as above. **Size:** M. **PC:** Task 13 (a real login shows limits in the tooltip and log).

---

### Task 10: Launch at login and the update check

**Files:**
- Create: `Platform/PlatformShell.swift`, `Platform/Mac/MacShell.swift`, `Platform/Windows/WindowsShell.swift`, `Platform/Windows/WindowsLoginItem.swift`, `Platform/InstallerReleaseFeed.swift` (shared)
- Modify: `Core/UpdateChecker.swift` (upstream: `import AppKit` → `import Foundation` + the FoundationNetworking guard; `NSApp.terminate(nil)` → `PlatformShell.current.terminate()`; `NSWorkspace.shared.open(u)` → `PlatformShell.current.open(u)`), `Platform/PlatformCompat.swift` (`typealias pid_t = Int32` in the existing `#if !canImport(Darwin)` block, if the Windows build needs it), `Sources/PokeTokenBar/mac-only.txt` (−1 line), `Tests/PokeTokenBarTests/mac-only.txt` (−`UpdateCheckerTests.swift`), `WindowsApp.swift`, `TrayMenuModel` wiring
- Test: `UpdateCheckerTests.swift` (now both), `InstallerReleaseFeedTests.swift` (both), `WindowsLoginItemTests.swift` (Windows)

**Interfaces:**
- Produces:
  ```swift
  @MainActor protocol PlatformShellService { func open(_ url: URL); func terminate() }
  enum PlatformShell { @MainActor static var current: any PlatformShellService }   // Mac: MacShell; Windows: WindowsShell; shared-only: a logging stub
  enum InstallerReleaseFeed {
      static func parse(_ data: Data) -> UpdateChecker.LatestRelease?  // nil unless an asset named PokeTokenBar-Setup-*-win-x64.exe exists; url = html_url
      static func latest(repo: String = UpdateChecker.releaseRepo, session: URLSession = .shared) async -> UpdateChecker.LatestRelease?
  }
  @MainActor struct WindowsLoginItem {
      init(runKey: String = #"Software\Microsoft\Windows\CurrentVersion\Run"#,
           approvedKey: String = #"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"#,
           valueName: String = "PokeTokenBar", command: String = WindowsLoginItem.defaultCommand)
      var state: TrayMenuModel.LoginState { get }
      func setEnabled(_ on: Bool) -> Bool
      static var defaultCommand: String                               // "\"<exe path>\" --autostart"
  }
  ```
  - `WindowsShell.terminate()` is `WindowsApp.exit(0, .menu)`. `WindowsShell.open(_:)` is `ShellExecuteW` with `WinPath.native` for file URLs.
  - Windows builds `UpdateChecker(currentVersion: WindowsInstall.version ?? "0.0.0", defaults: WinSyncingDefaults(), fetchLatest: { await InstallerReleaseFeed.latest() })`.
  - The feed returns nil until releases carry the installer (stage 8), so Windows never offers a Mac-only release. *Ruling:* until then an update only opens the release page; `applyUpdate` on Windows reaches its existing non-brew branch (no `brew` on `Path`).
  - **Launch at login is off by default** (*ruling*): first run leaves the Run key alone; only the tray toggle writes it.

**Steps:**
- [ ] Failing tests:
  - existing `UpdateCheckerTests` now run on both;
  - `testFeedIgnoresAReleaseWithoutTheWindowsInstaller`, `testFeedTakesTheReleasePageURL` (both);
  - `testApplyOpensTheReleasePageWhenBrewIsMissing` (both, with a recording `PlatformShellService`);
  - Windows: `testEnableWritesTheQuotedCommand`, `testDisableRemovesOnlyOurValue`, `testDisabledInTaskManagerIsReported`, `testFirstRunLeavesLaunchAtLoginOff`. These use test-only keys `Software\PokeTokenBarTests\<uuid>\…`, deleted in `tearDown`.
  - Selftest `login.realKey` (`CI` only): enable → read back → disable → gone, on the real Run key of the throwaway runner profile.
- [ ] Mac pin: `MacShell`'s two lines are copied verbatim (not testable without terminating the app), and the Mac `UpdateCheckerTests` run unchanged. State this in the PR.
- [ ] Wire into the tray menu: the "Launch at login" check state and toggle; "Update available vX" opens the page.
- [ ] `swift test --filter "UpdateChecker|InstallerReleaseFeed"`, then `shared-check.sh`. Windows green.
- [ ] **PR `feat(windows): launch at login and check for updates`**, merge. The body lists the upstream lines.

**Verify:** as above. **Size:** M. **PC:** Task 13 (sign out/in, Task Manager toggle).

---

### Task 11: Crash logging

**Files:**
- Create: `Platform/Windows/WindowsCrashLog.swift`, `Sources/CWinShim/crash.c`. CWinShim's second job: the filter body must not allocate or take locks, which C guarantees and Swift does not. `SetUnhandledExceptionFilter` and `MiniDumpWriteDump` themselves import into Swift (E1 P12).
- Modify: `WindowsApp.swift` (install right after single instance; `markClean` inside `WindowsApp.exit`), `windows-app.yml` (crash then relaunch)
- Test: `WindowsCrashLogTests.swift` (Windows)

**Interfaces:**
- Produces:
  ```swift
  enum WindowsCrashLog {
      static let markerName = "PokeTokenBar.running", crashLogName = "PokeTokenBar.crash.log",
                 stderrName = "PokeTokenBar.stderr.log", keptDumps = 3
      static func install(version: String, logsDirectory: URL = PlatformCompat.logsDirectory(),
                          log: @escaping (String) -> Void = { AppLog.write($0) })
      static func markClean(logsDirectory: URL = PlatformCompat.logsDirectory())
  }
  // C (preformatted buffers, WriteFile on a pre-opened HANDLE)
  typedef void (*ptb_crash_hook)(void);
  int  ptb_crash_install(const wchar_t *crash_log_path, const wchar_t *dump_dir, ptb_crash_hook before_dump);
  int  ptb_crash_redirect_stderr(const wchar_t *path);   // Swift runtime "Fatal error: …" lines land here (Swift may do this part)
  ```
  Semantics mirror `CrashReporter`:
  - On install, drain the previous `crash.log` into `AppLog`.
  - Marker present → log "previous session did not end cleanly"; write the marker.
  - `markClean` removes it and calls `AppLog.writeAndFlush("clean shutdown")`.
  - The filter writes `[CRASH] exception 0x%08X at 0x%p`. It calls `before_dump`: a best-effort `UserDefaults.standard.synchronize()` on a fresh thread, waited at most 500 ms (D4 item 5). Then it writes a `MiniDumpNormal` dump and returns `EXCEPTION_CONTINUE_SEARCH`.
  - `stderr.log` is cut to 256 KB at launch.

**Steps:**
- [ ] Failing tests (temp logs dir, injected `log`):
  - `testFirstInstallWritesTheMarkerOnly`, `testMarkerLeftBehindIsReportedOnce`, `testMarkCleanRemovesTheMarker`, `testCrashLogIsDrainedThenRemoved`, `testOnlyThreeDumpsAreKept`.
- [ ] CI step: the installed (or bundle) exe runs `--selftest-crash` (sets a defaults key, then `fatalError("selftest crash")`). Then `--selftest` asserts:
  - `crash.previous` (marker reported);
  - `crash.dump` (a `.dmp` exists);
  - `crash.stderr` (`stderr.log` contains `selftest crash`);
  - `crash.defaults` (the key reached the plist — records whether the best-effort sync worked; informational).
- [ ] **PR `feat(windows): leave a trace when the app crashes`**, merge.

**Verify:** Windows run green with the three required `crash.*` checks. **Size:** M. **PC:** no.

---

### Task 12: Packaging, installer, installed selftest, idle gate

Milestone: run the full Mac gate after this task (speed rules).

**Files:**
- Create: `installer/PokeTokenBar.iss`, `scripts/windows/measure-idle.ps1`, `scripts/generate-ico.py`, `assets/AppIcon.ico`, `Sources/PokeTokenBarWin/PokeTokenBar.rc`, `Sources/PokeTokenBarWin/app.manifest`, `windows/licenses/{map.txt, *.txt}`
- Modify: `scripts/windows/package.ps1` (dumpbin closure over `Runtimes` + `Toolchains`, VC redist, licences, rename to `WindowsInstall.shippedExecutableName`, version stamp), `windows-app.yml`, `CONTRIBUTING.md` (Windows build: vcpkg, `PTB_OPENSSL_DIR`, artifacts, the frozen exe name)

**Interfaces:**
- Produces:
  - `package.ps1 -Version <x.y.z> -Res <path.res> -Out <dir>` → `bundle\` with `PokeTokenBar.exe`, the DLL closure, `PokeTokenBar.version`, `licenses\`. Exit 1 on a closure DLL with no source or no licence mapping.
  - `ISCC /DSrcDir=bundle /DAppVer=<x.y.z> /DOutDir=out installer\PokeTokenBar.iss` → `out\PokeTokenBar-Setup-<x.y.z>-win-x64.exe`.
  - `measure-idle.ps1 -ProcessId <pid> -Seconds 120 -Also explorer [-Baseline]` → JSON: `{processCycles, threads:[{tid, cycles, contextSwitches}], mainThreadContextSwitches, explorerCycles, handlesStart, handlesEnd, privateMBEnd}`. Inline C# `Add-Type`: `QueryProcessCycleTime`, `QueryThreadCycleTime`, `NtQuerySystemInformation(SystemProcessInformation)`. Read only at the window's edges (F20).

**Steps:**
- [ ] `.rc`: `VERSIONINFO` (`FileVersion`/`ProductVersion` x.y.z.0, `FileDescription "PokeTokenBar"`, which Windows shows as the notification source), `1 ICON`, `1 RT_MANIFEST`. CI: `rc.exe /nologo /fo PokeTokenBar.res Sources\PokeTokenBarWin\PokeTokenBar.rc`, then `swift build -c release --product PokeTokenBarWin -Xlinker <abs>\PokeTokenBar.res`.
- [ ] The workflow, in order:
  1. build;
  2. package;
  3. stripped-`Path` bundle selftest (F21);
  4. `iscc` (`choco install innosetup` when `iscc` is missing);
  5. silent install `/VERYSILENT /SUPPRESSMSGBOXES /CURRENTUSER /NORESTART /LOG=install.log`;
  6. assert the app dir, the Start-menu `.lnk` (its AUMID via PowerShell `Shell.Application`, guess), the HKCU Uninstall key, and **no** Run value;
  7. installed `--selftest` (now `isBundledApp`: `log.writes`, `defaults.*`, `limits.claude` run in bundled mode; the plist is `PokeTokenBar.exe.plist`);
  8. crash then relaunch (Task 11);
  9. idle gate (D8): a sleeping baseline process (`powershell -c Start-Sleep 150`) measured 120 s; explorer measured 120 s before the app starts; then the installed app with fixture data and `refreshInterval = 0` in this throwaway profile, wait 30 s, measure 120 s; assert the D8 budgets; then a report-only 300 s window with polling at 120 s;
  10. silent uninstall; assert the app dir and Run value are gone and `%LOCALAPPDATA%\PokeTokenBar` is kept;
  11. upload `PokeTokenBar-Setup-*.exe`, `st-*.json`, `idle-*.json`, logs.
- [ ] Record the installer and bundle sizes, and the first idle numbers, in the PR.
- [ ] **PR `build(windows): build a per-user installer in CI`**, merge. Then run the milestone `./scripts/test-gate.sh`.

**Verify:** `gh run watch … --exit-status` → 0; `gh run download … -n windows-installer` → the `.exe` exists; `idle-gate.json` is within budget. **Size:** L. **PC:** Task 13.

---

### Task 13: Stage 4 check on the user's PC; docs

**Files:**
- Modify: spec §9.1 (stage 4 row), §10 step 4 (done + deviations), §13; `docs/reference/defect-log.md`; `CONTRIBUTING.md`

**Steps:**
- [ ] The session lead sends the user the installer artifact link and this checklist (Korean wording is the lead's). Items CI already proves are left out: tray calls, menu keys, single instance, Run key, defaults persistence.
  1. `winver` build, account type (standard/admin), **`echo %USERNAME%` and `echo %USERPROFILE%`** (does the profile folder name equal the user name? R9), and the system locale / ACP (`chcp`).
  2. SmartScreen on the installer: did "Windows protected your PC" appear, and did More info → Run anyway work without an admin prompt?
  3. Install: no UAC; `%LOCALAPPDATA%\Programs\PokeTokenBar`; a Start-menu entry; listed in Apps.
  4. After install the app runs. Is the tray icon visible (maybe in the ^ overflow) and crisp; was the first-run hint balloon **visible**? Drag the icon onto the taskbar.
  5. The tooltip and menu show today's tokens. Compare with Claude Code usage on that PC if it is used.
  6. "Open log folder" opens an Explorer window and `PokeTokenBar.log` has lines; Quit makes the icon disappear.
  7. Launch at login: off after install; turn it on → sign out/in → running. Task Manager → Startup apps shows it. Disable it there → the menu says "disabled in Task Manager".
  8. Start-menu relaunch while running: no second icon; the "already running" balloon is **visible**.
  9. Quit, then run `PokeTokenBar.exe --selftest --selftest-out %TEMP%\st.json` from PowerShell. The "self-test" notification is **visible** (also in Notification Center); send back `st.json` (it includes `defaults.location`).
  10. **Hangul IME:** `PokeTokenBar.exe --ime-check` → type 한글 and an emoji with the Korean IME into the box → the log line lists the code points; send it back (F15).
  11. Sleep 1 min, wake: the log has a wake refresh line. Display off 2 min: a "polling paused" line.
  12. With Claude Code logged in: the tooltip and log show 5-hour/weekly limits (and the update check works on the office network: proxy).
  13. Shut down the PC with the app running → next launch: no "did not end cleanly" line.
  14. Install a newer CI build over it: the app closes and relaunches; companion progress and `team.memberID` are unchanged (log line).
  15. Uninstall: app and Run value gone; `%LOCALAPPDATA%\PokeTokenBar` and `PokeTokenBar.exe.plist` kept.
  16. Defender: right-click the installer → Scan → result.
  17. `scripts/windows/measure-idle.ps1 -ProcessId <pid> -Seconds 600 -Also explorer` with the app idle → send back the JSON (decides tray animation, *ruling*).
- [ ] Record the answers in spec §9.1. Every failure goes through the defect protocol in its own fix PR before Task 20.
- [ ] **PR `docs: record the Windows app check`**, merge.

**Size:** S. **PC:** **yes**.

---

### Task 14: Shared transport rules (Mac refactor, behaviour identical) — review with the most capable model

Milestone: run the full Mac gate after this task (speed rules).

**Files:**
- Create: `Team/TeamTransportRules.swift`
- Modify: `Team/TeamTransport.swift`
- Test: `TeamTransportRulesTests.swift` (both)

**Interfaces:**
- Produces:
  ```swift
  enum TeamTransportRules {
      static let serviceType = "_ptbteam._tcp"
      static let handshakeTimeout: TimeInterval = 10, redialInterval: TimeInterval = 15, listenerRetryDelay: TimeInterval = 5
      static let maxUnfinishedInbound = 32, maxUnfinishedOutbound = 32, maxLinks = 128
      static let receiveBurst = 4.0 * 1_048_576, receivePerSecond = 256.0 * 1024, frameCost = 1024
      static let maxReadChunk = 65_536
      static func newInstanceName(_ uuid: UUID = UUID()) -> String     // "ptb-" + 12 lowercase hex, as begin() does today
      static func admitsInbound(linkCount: Int, unfinishedInbound: Int, linkLimit: Int) -> Bool
      static func dialRoom(unfinishedOutbound: Int, linkCount: Int, linkLimit: Int) -> Int
  }
  struct TeamLinkReceiver {
      enum Outcome: Equatable { case messages([TeamMessage]), badFrame(String), flood }
      init()
      mutating func receive(_ chunk: Data, now: Date) -> Outcome      // decode first (throw → badFrame), then budget (bytes + frames × frameCost)
  }
  ```
  `BonjourTeamTransport` keeps `static let serviceType`, `maxUnfinishedInbound`, `maxUnfinishedOutbound`, `maxLinks`, `receiveBurst`, `receivePerSecond`, `frameCost` as aliases of the rules (tests and `team-probe` keep compiling). It uses `TeamLinkReceiver` in `receive`. Log lines stay byte-identical. Its Mac-only `Timer(timeInterval:)` redial timer is left as it is: Darwin is correct and the file stays Mac-only.

**Steps:**
- [ ] Failing tests:
  - `testInstanceNameShape`, `testInboundAdmissionAtEachCap`, `testDialRoomNeverNegative`;
  - `testReceiverDeliversInOrder`, `testReceiverReportsABadFrameBeforeSpending`, `testReceiverDropsATinyFrameFlood`, `testReceiverLetsAFullSyncThrough` (the byte and frame counts of `testASyncAndARunAreNotDropped`).
- [ ] Refactor. The existing 20 `TeamTransportTests` + `TeamSessionLoopbackTests` pass unchanged.
- [ ] Fault-inject: swap decode and budget order in `TeamLinkReceiver` → `testReceiverReportsABadFrameBeforeSpending` fails. Revert.
- [ ] `swift test --filter "TeamTransport|TeamSessionLoopback|TeamTransportRules"`, then `shared-check.sh`, then the milestone `./scripts/test-gate.sh`. Windows green (the rules file is shared).
- [ ] **PR `refactor(team): share the transport rules`**, merge. Review with the most capable model: "is any Network.framework callback now handled in a different order?"

**Verify:** as above. **Size:** M. **PC:** no.

---

### Task 15: The transport contract suite (Mac first)

**Files:**
- Create: `Tests/PokeTokenBarTests/TeamTransportContract.swift` (compiles on both OSes; no Network import), `Tests/PokeTokenBarTests/TeamTransportContractScanTests.swift`
- Modify: `Tests/PokeTokenBarTests/TeamTransportTests.swift` (becomes the Mac harness and wrappers; stays Mac-only), `TeamSessionLoopbackTests.swift` (wrapper)

**Interfaces:**
- Produces:
  ```swift
  @MainActor protocol TeamTransportHarness: AnyObject {
      associatedtype Transport: TeamTransporting
      associatedtype Endpoint
      func make(linkLimit: Int) -> Transport                                       // advertise: false; stopped in tearDown()
      func loopbackEndpoint(of t: Transport) async throws -> Endpoint              // 127.0.0.1:<listener>, waits ≤ 5 s
      func listenerPort(of t: Transport) -> UInt16?
      func connect(_ t: Transport, to e: Endpoint)
      func injectDiscovered(_ t: Transport, name: String, endpoint e: Endpoint)
      func plannedDials(_ t: Transport, now: Date) -> [String]
      func linkCount(_ t: Transport) -> Int
      func sendRaw(_ t: Transport, _ data: Data, to peer: TeamPeerID)
      func willSleep(_ t: Transport); func didWake(_ t: Transport); func restart(_ t: Transport)
      func failDiscovery(_ t: Transport)
      func silentSink() async throws -> (endpoint: Endpoint, close: () -> Void)   // TCP that never speaks TLS
      func plainTCP(toPortOf t: Transport, count: Int) async throws -> () -> Void  // connections that never handshake
      func rawTLS(to e: Endpoint, code: TeamCode) async throws -> (send: (Data) -> Void, close: () -> Void)
      func tearDown()
  }
  enum TeamTransportContract { static func <scenario><H: TeamTransportHarness>(_ h: H) async throws }
  ```
  Scenarios. 1–20 are today's tests, names kept; 21–26 are new, derived from `TeamTransport.swift`:
  1. `sameCodePeersExchangeMessagesOverLoopback`
  2. `differentCodeNeverDeliversMessages`
  3. `malformedFrameDisconnects` (now also asserts `onPeerBadFrame` fires before `onPeerDisconnected`, same id)
  4. `stopSilencesCallbacks`
  5. `disconnectIsSilentAndUnknownPeerIsNoOp`
  6. `sleepReportsDisconnectsAndWakeRestartsOnlyRunningTransport`
  7. `ownerStoppingInsideDisconnectCallbackPreventsRestart`
  8. `failedDiscoveryRestartsLikeAFailedListener`
  9. `unfinishedInboundLinksAreCapped`
  10. `dialsToRogueServicesAreCapped`
  11. `aFloodOfNamesCostsLittleOnceTheDialsAreFull`
  12. `dialsLeaveRoomForTheLinkLimit`
  13. `inboundLinksStopAtTheLinkLimit`
  14. `aFinishedLinkDoesNotUseUpADialSlot`
  15. `aLinkPouringInBytesIsDropped`
  16. `aLinkPouringInTinyFramesIsDropped`
  17. `aSyncAndARunAreNotDropped`
  18. `failedDialIsClosedAndWaitsForCooldown`
  19. `disconnectCoveredByKeptConnectionStopsRedialUntilKeptEnds`
  20. `laterVersionFramesNeitherDropTheLinkNorLoseTheGoodItems`
  21. `anUnfinishedHandshakeEndsAfterTheTimeout` (silent sink; `linkCount` 0 within 12 s; due again after the 60 s cooldown)
  22. `remoteStopIsReportedOnce`
  23. `sendToAnUnreadyOrUnknownPeerIsDropped`
  24. `ownerDisconnectInsideOnMessageStopsTheBatch` (two frames in one write)
  25. `refusedPeerWaitsForTheRefusalCooldown` (not due at +61 s, due at +301 s)
  26. `restartReportsLiveLinksThenComesBack`

**Steps:**
- [ ] Move each test body into its scenario with no change in what it asserts; write the Mac harness from today's helpers (`silentSink`, `loopback`, raw `NWConnection`). Keep the Mac-only `testAHealthyBrowserChangesNothing` (`browserStateChanged(.ready)`).
- [ ] Add scenarios 21–26. **If one fails on the Mac, the Mac is the contract:** rewrite the scenario to describe what the Mac does and note it in the PR. Never change the Mac transport here.
- [ ] Fault-inject each of 21–26 once on the Mac (e.g. remove the handshake timer) → fails. Revert.
- [ ] `TeamTransportContractScanTests.testEveryScenarioHasAWrapperPerTransport`: lists the `static func` names in the contract, then requires `TeamTransportContract.<name>(` in `TeamTransportTests.swift` and, from Task 19 on (constant `windowsWrapperRequired = true` flipped there), in `WindowsTransportContractTests.swift`. Fault-inject by deleting one wrapper → fails.
- [ ] `swift test --filter "TeamTransport|TeamSessionLoopback"`, then `shared-check.sh`. Windows green (the contract compiles there; no Windows wrapper yet).
- [ ] **PR `test(team): turn the transport tests into a contract any transport must pass`**, merge.

**Verify:** as above. **Size:** M. **PC:** no.

---

### Task 16: TLS-PSK wrapper over OpenSSL

**Files:**
- Modify: `Sources/CTeamTLS/{CTeamTLS.c, include/CTeamTLS.h}`
- Create: `Platform/Windows/Team/WinTLS.swift`
- Test: `WindowsTLSTests.swift` (Windows), `TeamWireKnownAnswerTests.swift` (both)

**Interfaces:**
- Produces:
  ```c
  typedef struct ptb_tls_ctx ptb_tls_ctx; typedef struct ptb_tls ptb_tls;
  enum { PTB_TLS_OK = 0, PTB_TLS_WANT_READ = -2, PTB_TLS_WANT_WRITE = -3, PTB_TLS_CLOSED = -4, PTB_TLS_FAILED = -5 };
  ptb_tls_ctx *ptb_tls_ctx_new(int server, const uint8_t psk[32], const char *identity);   // TLS1.2 only, "PSK-AES128-GCM-SHA256"
  void         ptb_tls_ctx_free(ptb_tls_ctx *);
  ptb_tls     *ptb_tls_new(ptb_tls_ctx *, uintptr_t socket);                              // non-blocking socket, SSL_set_fd
  int          ptb_tls_handshake(ptb_tls *);
  int          ptb_tls_read(ptb_tls *, uint8_t *buf, int cap);                            // > 0 bytes, or a PTB_TLS_* code
  int          ptb_tls_write(ptb_tls *, const uint8_t *buf, int len);                     // partial writes allowed
  int          ptb_tls_pending(ptb_tls *);
  void         ptb_tls_close(ptb_tls *);                                                  // close_notify, no wait, SSL_free
  const char  *ptb_tls_cipher(ptb_tls *); const char *ptb_tls_version_name(ptb_tls *);
  const char  *ptb_tls_last_error(void);
  int          ptb_tls_hmac_sha256(const uint8_t *key, size_t klen, const uint8_t *msg, size_t mlen, uint8_t out[32]);  // for the cross-check
  ```
  ```swift
  final class WinTLSContext { enum Role { case client, server }; init(code: TeamCode, role: Role) throws }   // key = TeamCode.pskKey bytes
  final class WinTLSSession {                                                             // owned by the I/O thread only
      init(context: WinTLSContext, socket: UInt)
      enum Step: Equatable { case done, wantRead, wantWrite, failed(String), closed }
      func handshake() -> Step; func read(max: Int) -> (Data?, Step); func write(_ d: Data) -> (written: Int, Step)
      var cipher: String? { get }; var version: String? { get }; func close()
  }
  ```
  Server PSK callback: identity must equal `ptb-team-v1`, else return 0.

**Steps:**
- [ ] Failing tests:
  - `testPSKBytesMatchAKnownAnswer` (both): `TeamCode(parsing: "PTB-AAAA-BBBB-CCCC")!.pskKey` as hex equals a constant recorded on the Mac first;
  - `testFrameBytesMatchAKnownAnswer` (both): `TeamWire.encode(.profileRequest)` equals a recorded byte string;
  - Windows: `testOpenSSLHMACEqualsSwiftCrypto`, `testSameCodeHandshakesWithThePSKSuite` (socket pair; cipher `PSK-AES128-GCM-SHA256`, version `TLSv1.2`), `testDifferentCodeFailsOnBothSides`, `testWrongIdentityIsRefused`, `testABigWriteIsReadBackWholeThroughPending` (100 KB), `testInteropWithTheOpenSSLCommandLine` (`openssl s_server -psk <hex> -psk_identity ptb-team-v1 -cipher PSK-AES128-GCM-SHA256 -tls1_2 -nocert -accept 0` from Git for Windows; `XCTSkip` when `openssl.exe` is missing).
- [ ] Implement from `spike/probe/ptbprobe.c`. Push → Windows green.
- [ ] **PR `feat(windows): TLS-PSK for the team link through OpenSSL`**, merge.

**Verify:** Windows run: the `WindowsTLSTests` count appears and passes; Mac `swift test --filter TeamWireKnownAnswer`. **Size:** M. **PC:** no.

---

### Task 17: The socket loop **[most capable]**

**Files:**
- Create: `Platform/Windows/Team/WinSocketLoop.swift`
- Test: `WindowsSocketLoopTests.swift` (Windows)

**Interfaces:**
- Consumes: `WinTLSContext`, `WinTLSSession` (Task 16), `TeamTransportRules.maxReadChunk`.
- Produces:
  ```swift
  struct WinConnID: Hashable, Sendable { let raw: UInt64 }                       // unique for the process lifetime
  struct WinSocketAddress: Sendable, Equatable { let host: String; let port: UInt16 }
  enum WinCloseReason: Sendable, Equatable { case handshakeFailed(String), unreachable(Int32), remoteClosed, error(Int32) }
  enum WinSocketEvent: Sendable, Equatable {
      case listening(port: UInt16), listenFailed(Int32)
      case accepted(WinConnID), ready(WinConnID)
      case data(WinConnID, Data)                                                  // ≤ maxReadChunk; then reading pauses until receiveNext
      case closed(WinConnID, WinCloseReason)                                      // never after close(_:) / closeAll()
  }
  final class WinSocketLoop: @unchecked Sendable {
      init(deliver: @escaping @MainActor ([WinSocketEvent]) -> Void)              // batched, in order, via DispatchQueue.main.async
      func start(); func shutdown()                                               // shutdown joins the thread
      func listen(code: TeamCode)                                                 // dual-stack [::]:0
      func stopListening()
      func dial(_ addresses: [WinSocketAddress], code: TeamCode) -> WinConnID     // tries in order; TLS client
      func receiveNext(_ id: WinConnID)
      func send(_ data: Data, on id: WinConnID)
      func close(_ id: WinConnID); func closeAll()                                // silent
  }
  ```
  Internals:
  - one `Thread`; `WSAPoll(INFINITE)`; a loopback UDP pair for wakeups;
  - a command queue under `NSLock`; per-connection `{socket, session, state, outbox, readArmed}`;
  - the mailbox flushes with one `DispatchQueue.main.async` per empty → non-empty transition;
  - never `MainActor.assumeIsolated` (F16, scan).

**Steps:**
- [ ] Failing tests:
  - `testDialAndAcceptReachReadyAndExchangeData`;
  - `testEventsArriveInOrderUnderLoad` (10,000 sends);
  - `testCloseIsSilent`;
  - `testReadingPausesUntilReceiveNext` (the sender writes 1 MB; only one `.data` chunk arrives before `receiveNext`);
  - `testPlainTCPStaysAcceptedNeverReady`;
  - `testRefusedDialReportsUnreachable`;
  - `testDifferentCodeClosesWithHandshakeFailed`;
  - `testIdleLoopDoesNotWake`: 5 s idle; the I/O thread's `QueryThreadCycleTime` Δ is near 0 and its context-switch Δ is 0 (F20; not `GetProcessTimes`);
  - `testShutdownJoinsTheThread`.
- [ ] Review checkpoint (in the PR): no `WSAPoll` timeout other than `INFINITE`; no `SSL*` touched off the loop thread; `ptb_tls_pending` drained before re-polling.
- [ ] Push → Windows green.
- [ ] **PR `feat(windows): a socket loop for team links`**, merge.

**Verify:** Windows run green. **Size:** L. **PC:** no.

---

### Task 18: DNS-SD wrapper

**Files:**
- Create: `Platform/Windows/Team/WinDNSSD.swift` (Swift via WinSDK; `DnsServiceRegister/DeRegister/Browse/Resolve` import and link, E1 P12)
- Test: `WindowsDNSSDTests.swift` (Windows), `DNSSDNameTests.swift` (both, pure)

**Interfaces:**
- Produces:
  ```swift
  enum DNSSDName {                                                       // shared, pure
      static func instanceLabel(fromPTR name: String, serviceType: String = TeamTransportRules.serviceType) -> String?   // "ptb-ab12…._ptbteam._tcp.local" → "ptb-ab12…"
      static func fullName(instance: String, serviceType: String = TeamTransportRules.serviceType) -> String
  }
  final class WinDNSSD: @unchecked Sendable {
      enum Event: Sendable, Equatable { case registered(String), registerFailed(Int32), found(String), lost(String), browseFailed(Int32) }
      init(deliver: @escaping @MainActor (Event) -> Void)                // pool-thread callbacks → DispatchQueue.main.async
      func register(instance: String, port: UInt16); func deregister()
      func browse(); func stopBrowsing()
      func resolve(instance: String, _ done: @escaping @MainActor ([WinSocketAddress]) -> Void)   // IPv4 first; [] on failure
  }
  ```
  Host for registration: `GetComputerNameExW(ComputerNameDnsHostname) + ".local"`. PTR TTL 0 → `.lost`. The request structs and their wide strings stay alive until deregister or cancel.

**Steps:**
- [ ] Failing tests:
  - `testInstanceLabelParsing` (with and without a trailing dot, foreign service, uppercase) (both);
  - Windows: `testRegisterThenBrowseFindsOurOwnInstance` (runner loopback, ≤ 10 s), `testResolveReturnsTheListenerPort`, `testDeregisterThenBrowseNoLongerFinds` (records whether a `.lost` arrives: answers F13 on the runner), `testStopBrowsingStopsEvents`.
- [ ] Push → Windows green. If the runner's mDNS is flaky, the integration tests move into the selftest and are listed in the PR.
- [ ] **PR `feat(windows): find teammates with the built-in DNS-SD`**, merge.

**Verify:** Windows run green. **Size:** M. **PC:** no.

---

### Task 19: The Windows team transport, app wiring and probe mode **[most capable]**

Milestone: run the full Mac gate after this task (speed rules).

**Files:**
- Create: `Platform/Windows/Team/WindowsTeamTransport.swift`, `Platform/Windows/Team/WindowsTeamProbe.swift`, `Tests/PokeTokenBarTests/WindowsTransportContractTests.swift` (Windows harness + wrappers), `scripts/team-interop-check.sh`
- Modify: `WindowsApp.swift` (TeamRuntime + notifier + tray count), `Platform/Windows/WindowsNotifications.swift` (+ `WindowsTeamNotificationPoster`), `TrayMenuModel` (teammates line), `TeamTransportContractScanTests.swift` (`windowsWrapperRequired = true`), `windows-app.yml` (two-transport selftest)

**Interfaces:**
- Consumes: Tasks 7 (`onWillSleep`, `onWake`, `WindowsReachabilityMonitor`), 8, 14, 15, 17, 18.
- Produces:
  ```swift
  enum WinTeamEndpoint: Equatable, Sendable { case service(String), hostPort(String, UInt16) }
  @MainActor final class WindowsTeamTransport: TeamTransporting {
      init(advertise: Bool = true, linkLimit: Int = TeamTransportRules.maxLinks,
           loop: WinSocketLoop? = nil, dnssd: WinDNSSD? = nil,
           events: WindowsSystemEvents? = nil, reachability: (any ReachabilityMonitoring)? = nil)
      // TeamTransporting: callbacks, start, stop, send, disconnect(_:coveredBy:), refuse
      var listenerPort: UInt16? { get }; var linkCount: Int { get }; var peerIDs: [TeamPeerID] { get }
      func connect(to endpoint: WinTeamEndpoint)
      func sendRaw(_ data: Data, to peer: TeamPeerID)
      func injectDiscovered(_ name: String, endpoint: WinTeamEndpoint)
      func plannedDials(now: Date) -> [String]
      func restart(); func handleWillSleep(); func handleDidWake()
      func discoveryFailed(code: Int32)
  }
  @MainActor final class WindowsTeamNotificationPoster: TeamNotificationPosting {
      init(presenter: WinBalloonPresenter); func post(id: String, title: String, body: String); func requestAuthorization()
  }
  enum WindowsTeamProbe { @MainActor static func run(code: TeamCode, host: String?, port: UInt16?, seconds: Int, out: URL) async -> Int32 }
  ```
  Event mapping follows `BonjourTeamTransport.handle(_:of:)` and `receive`:
  - `.ready` → `isReady`, cancel the handshake timer, `onPeerConnected(id, initiatedByMe)`, `receiveNext`.
  - `.data` → `TeamLinkReceiver.receive`: `.badFrame` → log the Mac line, `onPeerBadFrame`, `finish(refused: true)`. `.flood` → the same with the flood line. Messages → deliver while `links[id] != nil`, then `receiveNext`.
  - `.closed(.handshakeFailed / .unreachable)` → `finish(handshakeFailed: initiatedByMe && !isReady)`. `.remoteClosed` or `.error` → `finish(handshakeFailed: false)`.
  - Dial of `.service(name)` = adopt (counts as unfinished) → `resolve` → `loop.dial`. Empty addresses → finish as handshake failed.
  - Listener failure, register failure or browse failure → `scheduleListenerRestart()` (5 s).
  - Redial: `Timer(fire: Date(timeIntervalSinceNow: 15), interval: 15, repeats: true, …)` on `RunLoop.main`, tolerance 3 s (F14). Handshake timers: `DispatchQueue.main.asyncAfter`.

  App: `TeamRuntime(settings:companion:transport: WindowsTeamTransport(events:reachability:))`. `teamRuntime.notifier = TeamNotifier(settings:poster: WindowsTeamNotificationPoster(…), isPlazaFrontmost: { false }, showInPlaza: { _ in })`. `teamRuntime.start()`. A balloon click of kind `.team` does nothing until stage 6 opens the plaza. The tray menu shows "Teammates online: N" when `teamSettings.isReady`.

  Probe: `PokeTokenBar.exe --team-probe <code> [--host h --port p] [--seconds 60] --selftest-out <file>` logs FOUND, DIAL, READY, MSG(kind) and CLOSED(reason) lines.

**Steps:**
- [ ] `WindowsTransportContractTests` wraps all 26 scenarios through a Windows harness (raw TLS via `WinTLSSession` on a blocking socket; plain TCP and silent sink via Winsock).
- [ ] Make the contract pass on Windows CI. Selftest `team.discoverAndExchange`: two in-process transports with `advertise: true` and the same code find each other by DNS-SD, connect once (duplicate resolved by `TeamSession` when run through two `TeamRuntime`s with separate `TeamSettings` suites), and exchange a presence.
- [ ] `scripts/team-interop-check.sh` (Mac, read-only, no app activation): runs `openssl s_server` / `s_client` with the PSK of a given code against `swift scripts/team-probe.swift`. It re-proves on demand that Network.framework and the OpenSSL flags in `CTeamTLS` agree (spike experiment 2). Run once; paste the output into the PR.
- [ ] Fault-inject on Windows: deliver more than one `.data` chunk per `receiveNext` → `aSyncAndARunAreNotDropped` or `aLinkPouringInTinyFramesIsDropped` changes outcome; drop the self-filter → the discovery selftest sees itself. Revert.
- [ ] `swift test --filter TeamTransportContractScan` on the Mac, `shared-check.sh`, then the milestone `./scripts/test-gate.sh`. Windows green.
- [ ] **PR `feat(windows): join the team over the office network`**, merge.

**Verify:** Windows run: contract wrappers 26/26 pass; `team.discoverAndExchange` passes; the installer artifact is updated. **Size:** L. **PC:** Task 20.

---

### Task 20: Stage 5 interop check on the user's PC; docs

**Files:**
- Modify: spec §9.1 (stage 5 row), §10 step 5, §13; `docs/reference/defect-log.md`; `CONTRIBUTING.md` (team on Windows: firewall, network profile)

**Steps:**
- [ ] Checklist for the user (a real Mac teammate on the same Wi-Fi; Korean wording is the lead's):
  1. Network profile of the office Wi-Fi (Settings → Network → Wi-Fi → properties: Private or Public).
  2. First team start: did a firewall prompt appear; did it ask for an admin password; which network types were ticked. Then `netsh advfirewall firewall show rule name=all dir=in verbose | Select-String -Context 0,12 PokeTokenBar` → Action, Profiles, Program.
  3. Join the Mac teammate's team code: the Mac roster shows the Windows nickname within 30 s; the Windows tray says "Teammates online: N".
  4. The Mac teammate sends a heart, a reaction and news → the Windows notification is **visible**. The Windows companion hatches or levels → the Mac feed shows it.
  5. Quit the Windows app → the Mac roster drops it within the heartbeat timeout. Relaunch → back.
  6. Sleep the PC 2 min → the Mac sees the disconnect; wake → back within about 30 s. Wi-Fi off/on → back. Is the PC a Modern Standby laptop (`powercfg /a` shows "Standby (S0 Low Power Idle)")?
  7. If step 2 shows Block: does the link still form (the Windows side dials)? Note the Mac log's refused dials.
  8. `ipconfig` adapters (WSL, Hyper-V, VPN present?) and whether connecting was slow.
  9. On any failure: `PokeTokenBar.exe --team-probe <code> --seconds 60 --selftest-out %TEMP%\probe.json` → send back.
  10. 10 min `measure-idle.ps1` with three or more teammates connected → send back.
  11. Optional: a second Windows PC on the same team.
- [ ] Record the answers. Each failure goes through the defect protocol. The DNS-SD removal behaviour (F13) gets a decision: rely on dial cooldowns, or add a browse restart on a long timer (that is a cost; ask first).
- [ ] **PR `docs: record the Windows team check`**, merge. Report to the user in Korean: what works on Windows now, what stage 6 needs.

**Size:** S. **PC:** **yes**.

## Order

- **Done:** Task 1 (E1).
- **Start now, in parallel with Track A** (no shared files with `Team/Plaza/**` or `Team/UI/**`):
  - Task 2 (Windows manifest branch + CI; Windows-only);
  - Task 2a (the timer fix: two upstream lines + a scan);
  - Tasks 3 and 4 (upstream `Core` lines + `PlatformCompat`);
  - Tasks 14 and 15 (transport rules and contract on the Mac).

  The Mac allows one build or test at a time, so the Mac-verified tasks (2a, 3, 4, 14, 15) run one after another; Task 2 (CI-only) overlaps them. 2a, 3 and 4 all touch `PlatformCompat.swift` or `WindowsSeamScanTests.swift`, so merge them in that order (each is append-only).
- **As soon as Task 2 merges:** Tasks 16 and 18 (they need only the targets; E1 is done). Task 17 follows 16.
- **Stage 4:**
  - 5 needs 2, 2a and 3. Then 6.
  - 7, 9, 10 and 11 need 5 (each adds files plus one wiring block in `WindowsApp.swift`; merge one at a time and rebase). 8 needs 6.
  - 12 needs 6, and is re-run green after 7–11.
  - 13 (the PC check) needs 7–12.
- **Stage 5:** 19 needs 5, 7, 8, 14, 15, 17 and 18. 20 needs 19 and 13.
- **Full Mac gate at the milestones:** after Tasks 5, 12, 14 and 19 (speed rules).
- Critical path: 2 → 5 → 6 → 8 → 19 → 20, with 16 → 17 and 18 alongside.
- Tell the peer (Track A) session at four points:
  - after Task 2 merges: Windows-only targets and the composite action;
  - after Task 2a merges: the timer scan now covers every shared file, including future plaza files;
  - after Task 7 merges: the single `Platform.swift` edit, and new protocols in new files;
  - after Task 15 merges: transport tests are now a contract (only matters if Track A touches `TeamTransportTests`).

## Open questions for the session lead

1. **Settings when the profile folder isn't named after the user** (R9, F2). CF writes the plist to `C:\Users\<user name>\AppData\Local`, which may not be the profile. The plan detects it (`defaults.location` fails, PC item 1). The mitigation is undecided:
   - (a) warn only, in the log and a balloon;
   - (b) at launch, if CF's folder is missing, keep settings in a suite whose name is an absolute path under `FOLDERID_LocalAppData` — needs a check that corelibs accepts absolute suite names (guess), and shared code that uses `.standard` would still miss it;
   - (c) accept the risk until a user hits it.
2. **Crash-path defaults sync:** the plan makes one best-effort `synchronize()` from the exception filter on a helper thread with a 500 ms cap (D4 item 5). CF calls inside a crashed process can deadlock; the cap bounds that, and the debounce already limits the loss to about 2 s. Keep it, or rely on the debounce alone?
3. **Moved OAuth code (Task 9):** the two Keychain helpers have to drop `private` because they move to another file. Every future upstream change to the moved range lands on a different file at sync time (the cost this ruling accepts). Confirm that this is the expected shape of "verbatim".
4. **Idle-gate budgets** (D8: main-thread context switches ≤ 2 per 120 s, process cycles ≤ 2× a sleeping baseline, explorer ≤ 2× its own baseline) are guesses until the first CI runs. Tighten after the PC numbers, or leave them generous until stage 6?

Sources used for the run-loop and toast research (context only; the decisions rest on the source files in "Facts" and on E1): [Combining Windows message loop with Swift's run loop](https://forums.swift.org/t/combining-windows-message-loop-with-swifts-run-loop/64054), [MainActor does not execute when a Swift DLL is called from .NET on Windows](https://forums.swift.org/t/swift-concurrency-mainactor-does-not-execute-when-swift-dll-is-called-from-net-on-windows/88469), [Pitch 3: Custom Main and Global Executors](https://forums.swift.org/t/pitch-3-custom-main-and-global-executors/80638), [Proper Windows notifications on Electron (AUMID + Start-menu shortcut)](https://dev.to/randomengy/proper-windows-notifications-on-electron-38jo), [Send a local toast notification from a WRL C++ desktop app](https://learn.microsoft.com/en-us/windows/apps/design/shell/tiles-and-notifications/send-local-toast-desktop-cpp-wrl).
