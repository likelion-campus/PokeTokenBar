# Windows Port, Track B (Stages 4–5: the Windows App and Team Connection) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A per-user installed Windows app that starts from the Start menu or at sign-in, sits in the tray with the companion's sprite, and keeps `UsageStore` and `CompanionStore` running on the user's real logs, with real OS services behind `Platform` (stage 4). Then it joins the team over the office Wi-Fi so Mac teammates see the Windows user in their roster and team notices arrive as Windows notifications (stage 5). The Mac app's behaviour does not change.

**Architecture:** Still one Swift module. All Windows-only Swift lives in `Sources/PokeTokenBar/Platform/Windows/`, each file wrapped in `#if os(Windows)` (the scan test already allows body-level conditionals under `Platform/`), so it compiles to nothing on the Mac. Three targets exist only when the manifest runs on Windows: `CWinShim` (C/C++: WIC image decode, run-loop SPI lookup, crash filter), `CTeamTLS` (C: an OpenSSL 3 TLS-PSK wrapper; OpenSSL linked statically from vcpkg), and the executable `PokeTokenBarWin` (one `main.swift` that calls the module's single `public` entry `WindowsApp.main()`). The Mac branch of `Package.swift` and the Mac's `PTB_SHARED_ONLY` pre-check see none of them. The UI thread is the process main thread. CoreFoundation's run loop owns it (`RunLoop.main.run`) with its Windows message-queue mask switched on, so Win32 messages, the dispatch main queue (which is where `@MainActor` work runs) and `RunLoop` timers share one loop. Task 1 has to prove this first; two fallbacks are planned. The Windows team transport keeps all link state on the main actor like `BonjourTeamTransport`, does socket and TLS work on one I/O thread (`WSAPoll`), and hands events to the main queue in order. The rules both transports share (caps, budgets, framing, naming) move into a shared `TeamTransportRules`, and one contract test suite runs against both transports.

**Tech Stack:** Swift 6.3.2 on `windows-latest` (VS 2026), SwiftPM, XCTest, the `WinSDK` module, C/C++ shim targets (clang through SwiftPM, the pattern proven by `spike/draw/`), OpenSSL 3 static (vcpkg, triplet `x64-windows-static-md`), Windows built-in DNS-SD (`windns.h`, `dnsapi.lib`), Inno Setup 6, GitHub Actions. Nothing new on the Mac.

**Spec:** `docs/superpowers/specs/2026-11-13-windows-port-design.md` (Korean) — §2 (G1, G2, failure conditions), §7 (OS services), §8 (only how the shell must host the popover later), §9.1, §10 steps 4–5, §11, §12. Experiments: branch `spike/windows-port` (`spike/RESULTS.md`, `spike/probe/ptbprobe.c`, `spike/draw/`, `.github/workflows/spike-windows.yml`). Prior art: chattymin/PokeTokenBar#114 (`WniizMaster/PokeTokenBar:windows-port`, MIT): `WindowsTray.swift` (message loop, tray, mutex), `WindowsAutostart.swift`, `installer/PokeTokenBar.iss`, `scripts/build-win-installer.ps1`. Read it for what works from Swift on Windows. Do not copy its GDI popover.

---

## Facts this plan rests on

Read in source during planning (not run). Each one changes a task.

| # | Fact | Where it was read | Consequence |
|---|---|---|---|
| F1 | On Windows `FileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)` is `%LOCALAPPDATA%` (`FOLDERID_LocalAppData`). `.libraryDirectory` is not mapped, so it returns `[]`. `.cachesDirectory` is the temp dir. | swift-foundation `release/6.3`, `FileManager+WindowsSearchPaths.swift`, `FileManager+SearchPaths.swift` | `AppStatePaths` already lands in `%LOCALAPPDATA%\PokeTokenBar` (fine). `AppLog`'s `urls(for: .libraryDirectory…)[0]` **traps** the first time something logs. Today that is hidden only because `AppLog.write` returns early outside a bundle (F3). Task 3. |
| F2 | `UserDefaults.set` only calls `CFPreferencesSetAppValue` (marks keys dirty). Disk is written only on `synchronize()`. There is no timer and no exit hook in `CFApplicationPreferences.c` / `CFXMLPreferencesDomain.c`. The standard domain is an XML plist at `<profiles>\<user>\AppData\Local\<app>.plist`, where `<app>` is the bundle id, or the process name when there is no bundle. | swift-corelibs-foundation `release/6.3`: `UserDefaults.swift`, `CFPreferences.c`, `CFKnownLocations.c` | Settings, and above all `team.memberID`, are lost on any crash, kill or logoff unless the Windows app synchronizes. Task 5 adds a sync policy and a two-process persistence check. |
| F3 | `AppEnv.isBundledApp` = `Bundle.main.bundleIdentifier != nil && bundlePath.hasSuffix(".app")`. That is always false on Windows, and it gates logging, `persistsToUserLocation`, `allowsLiveLimitsFetch`, sprite prefetch and the reachability monitor in `UsageStore.init`. | `Core/AppEnv.swift`, `Core/AppLog.swift`, `Core/UsageStore.swift:1010` | Without a Windows rule the installed app keeps no logs, saves no companion progress and fetches no limits. Task 3. |
| F4 | CFRunLoop on Windows waits in `MsgWaitForMultipleObjectsEx(handles, timeout, rlm->_msgQMask, MWMO_INPUTAVAILABLE)`. With a non-zero per-mode mask it wakes on Win32 input and runs `rlm->_msgPump` or one `PeekMessage`/`TranslateMessage`/`DispatchMessage`. The setter `_CFRunLoopSetWindowsMessageQueueMask(rl, mask, mode)` is `CF_EXPORT` in `CFPriv.h` and refuses `kCFRunLoopCommonModes`. The main run loop drains the libdispatch main queue (`_dispatch_get_main_queue_port_4CF`) in common modes on the main thread. | swift-corelibs-foundation `release/6.3`: `CFRunLoop.c` (lines ~1194–1264, ~2885–2925, ~3100–3160), `include/CFPriv.h` 653–662 | One loop can serve Win32 messages, `@MainActor` jobs and `Timer`s. Not exposed to Swift, so it needs a C lookup (Task 1 checks the export). |
| F5 | `UsageStore` refreshes from a `Timer` added to `RunLoop.main` in `.common` mode (`UsageStore.swift:1030`, `:1048`). `BonjourTeamTransport` uses `RunLoop.main` and `DispatchQueue.main.asyncAfter`. | source | A bare `GetMessageW` loop (what #114 did) would never fire the refresh timer and never run `@MainActor` jobs. |
| F6 | #114 never ran `@MainActor` code under its loop. It blocked the main thread in `GetMessageW`, ran all work in `Task.detached` on a custom `@CompanionActor` (and made `CompanionStore` `@unchecked Sendable`), and posted results back with `PostMessageW`. | #114 `WindowsTray.swift:8–13, 79–131` | Its loop shows nothing about our question, and its shape (all-`@MainActor` stores) can't be reused. |
| F7 | No file watching anywhere: no FSEvents, `DispatchSource` or kqueue in `Sources/`. Usage is polled (default 120 s). | grep | No file-watching port is needed. |
| F8 | The team code, nickname and `memberID` live in `UserDefaults` (`TeamSettings`), not the Keychain. Nothing shared calls `Platform.current.secrets` today. | `Team/TeamSettings.swift`, grep | The secret store has no caller on Windows yet (open question 3). |
| F9 | Duplicate-link choice and protocol-version refusal live in shared `TeamSession`. The transport only reports `initiatedByMe` and honours `disconnect(_:coveredBy:)` / `refuse(_:)`. `TeamDialPlanner`, `TeamTokenBucket` and `TeamWire.FrameDecoder` are already shared and pure. | `Team/TeamSession.swift:497–520`, `TeamDialPlanner.swift` | The Windows transport re-implements only connection lifecycle and I/O. |
| F10 | PSK = `HMAC-SHA256(key: normalized code, msg: "poketokenbar.team.psk.v1")`, 32 bytes. Identity `ptb-team-v1`. OpenSSL cipher string `PSK-AES128-GCM-SHA256`, TLS 1.2 min = max. This interoperates with Network.framework in both directions on a real PC. | `Team/TeamCode.swift`, `spike/probe/ptbprobe.c`, `spike/RESULTS.md` | Reuse `TeamCode.pskKey` from Swift. The C side only takes 32 bytes. |
| F11 | Uncached `vcpkg install openssl:x64-windows-static` took 4 min 58 s on `windows-latest` (spike run 43383116858, step "OpenSSL (static)"). | `gh api …/runs/43383116858/jobs` | Cache the vcpkg install. Task 2. |
| F12 | Mac CI (`ci.yml`) runs only for `main`. PRs into `windows-port` get no Mac CI. | `.github/workflows/ci.yml` | The Mac proof for each PR is the local `./scripts/test-gate.sh`. |
| F13 | The Windows FS interop facts are not proven: DNS-SD removal (TTL 0 PTR), Public network profile, firewall rule action. | `spike/RESULTS.md` "STILL OPEN" | These go on the PC checklists (Tasks 13, 20). |

**Guesses.** Each one is tested by the named task.
- G-a: on Windows, Swift's `MainActor` executor is the dispatch main queue, as on Linux. Inferred, not read: stage 1's async `@MainActor` XCTests pass on Windows, so something drains main-actor jobs during tests, and forum posts name `DispatchMainExecutor` for non-Darwin. Task 1 P2.
- G-b: an `async` `main` on Windows ends in `dispatch_main()`, which exits the main thread (`_endthreadex`), so windows created there stop getting messages. Source: a forum report about a DLL host. Task 1 P6. **Consequence: `main.swift` must stay synchronous (no top-level `await`).**
- G-c: `_CFRunLoopSetWindowsMessageQueueMask`, `CFRunLoopGetMain` and `kCFRunLoopDefaultMode` can be found with `GetProcAddress` in one of the loaded Foundation DLLs. Task 1 P1.
- G-d: `MainActor.assumeIsolated` does not trap in a WndProc that CF's pump calls on the main thread. Task 1 P3.
- G-e: Shell_NotifyIcon balloons (`NIF_INFO`) show as toasts in Windows 10/11 Notification Center without an AppUserModelID or a Start-menu shortcut. Source: #114 relied on it. Task 13 on the PC.
- G-f: GitHub's Windows runner has a shell tray, so `NIM_ADD` succeeds. Task 1 P8.
- G-g: corelibs `Process` can run a `.cmd` shim (npm's `codex.cmd`) with arguments containing spaces. `isExecutableFile` is true for `.exe` and `.cmd`. Task 1 P10.
- G-h: `-L<dir>` plus `.linkedLibrary("libssl")` links vcpkg's static libs through SwiftPM on Windows. Fallback: `-Xlinker /LIBPATH:<dir>`. Task 2.

## Global Constraints

- **Speed rules (user decision, 2026-11-14) — these override any stricter wording below.** (1) No per-task full Mac gate: a task is verified on the Mac by the filtered suites for what it touched, `./scripts/shared-check.sh`, and (Track A) the render compare; the full gate `./scripts/test-gate.sh` runs only at milestones (Track A: after Tasks 7, 10, 13 and 19; Track B: after Tasks 5, 12, 14 and 19) and before `windows-port` goes to `main`. (2) Do not wait for Windows CI before merging a task into `windows-port`: merge, let the push run CI, and fix forward if it is red. Tasks whose only proof is Windows CI (Windows-only code) still read their run, but batch several changes per push. (3) Reviews: tasks marked for the most capable model keep an independent review; other tasks are read by the session lead. The cost accepted: a break found at a milestone is harder to trace to its task; `windows-port` is not released, so nothing reaches users in between.
Carried over from stage 1:
- **The Mac app must not change.** No behaviour, timing or UI difference. Every edit to a shared or upstream-owned file keeps the Mac result byte-identical, and a Mac test pins the old value (named in each task).
- Work in `.worktrees/<name>` cut from `origin/windows-port`. Never edit the main checkout. No bare `git stash`. Every `gh` call passes `--repo likelion-campus/PokeTokenBar`.
- **One PR per task, into `windows-port`, merged with a merge commit.** English Conventional Commits title. The body follows `.github/PULL_REQUEST_TEMPLATE.md` and lists every upstream-owned line changed. `main` is merged into `windows-port` at the start of each task. Experiment code (Task 1) goes to `spike/windows-port` and is never merged.
- **One `swift build` / `swift test` / `shared-check.sh` at a time on this Mac.** Before each one, `pgrep -x swift-build; pgrep -x swift-test; pgrep -x xctest` must print nothing; if it prints, wait. Never run the full suite while another session's release gate is running. Otherwise run `./scripts/test-gate.sh` once per task before merge when the task changed shared or Mac code. Mac CI does not run for `windows-port` PRs (F12).
- **Windows is verified by pushing and reading the CI run** (`gh run watch … --exit-status`, `gh run view --log`, `gh run download`). Windows CI does not block merges, but each task leaves it green.
- CI pair is fixed: `windows-latest` + Swift `6.3.2-RELEASE`.
- Upstream-owned files (`Core/**`, `UI/**`, `PokeTokenBarApp.swift`, `OutsideClickMonitor.swift`) are not moved or renamed. Each edit is the smallest one that routes an OS difference through `Platform`. Track B touches only `Core/AppEnv.swift`, `Core/AppLog.swift`, `Core/BinaryLocator.swift`, `Core/LocalUsageReader.swift`, `Core/LocalAdditionalUsageProvider.swift` and `Core/UpdateChecker.swift`.
- Body-level `#if os` / `#if canImport` only under `Sources/PokeTokenBar/Platform/`. Shared files use only the three import guards. Shared files never write `import CoreGraphics`.
- Tests make `UserDefaults` suites only with `TestDefaults.make(suite:)`. Test classes on the main actor that run on Windows have only `async` tests (scan-enforced). Stores in tests take injected providers.
- Defect protocol (`CLAUDE.md`): root cause including why tests missed it, a class sweep (read `docs/reference/defect-log.md` first), a trigger-branch test after a reachability check, fault injection, and a permanent capture. A finding from planning (F1–F3, the `Path` key in Task 4) is a defect and gets the full protocol in its task.

New for Track B:
- **Windows-only Swift goes in `Sources/PokeTokenBar/Platform/Windows/**`** (team transport in `Platform/Windows/Team/`). Each file is wrapped whole in `#if os(Windows)`. `WinSDK`, `CWinShim` and `CTeamTLS` are imported only inside that wrap. **Windows-only tests are `Tests/PokeTokenBarTests/Windows*Tests.swift`**, also wrapped whole. Tests that compile on both systems hold pure shared logic.
- The only `public` symbol added is `WindowsApp.main()`.
- **Never touch `Team/Plaza/**` or `Team/UI/**`.** That is Track A. No Track B task edits `Tests/PokeTokenBarTests/SharedSourcesScanTests.swift` (Track A extends it); Track B's scans go in their own files.
- New `Platform` protocols go in new files with their own `.current`, the pattern of `PlatformLimits` / `PlatformNetwork`. `Platform/Platform.swift` is edited exactly once (Task 7, two selector lines).
- `Package.swift`: Track B edits only the `if windowsBuild` branch, and only in Task 2. Windows-only targets are declared only under real `os(Windows)`, never under `PTB_SHARED_ONLY`.
- Model per role (user's `CLAUDE.md`): implementers `sonnet`. Tasks marked **[most capable]** use `opus` (the top tier only if the user asks). Reviews follow the user's table.
- No date, weather or chance gate on any feature without asking (memory: no self-chosen feature gates). Mac-side probes never activate the app (memory: no focus-stealing probes).

## Design

### D1. Target layout

```
Package.swift (if windowsBuild branch; Mac branch untouched)
  CSQLite                (exists)
  PokeTokenBar           .target  (exists)  deps: Crypto, CSQLite  + [CWinShim, CTeamTLS] only when os(Windows)
  PokeTokenBarTests      .testTarget (exists)
  — declared only when os(Windows) —
  CWinShim               C/C++17: WIC decode → BGRA, HICON helper, CF/dispatch SPI lookup, crash filter + minidump,
                         and any WinSDK call the Swift importer cannot reach (decided by Task 1 P12)
  CTeamTLS               C: OpenSSL PSK wrapper; -I/-L from env PTB_OPENSSL_DIR
  PokeTokenBarWin        .executableTarget  Sources/PokeTokenBarWin/main.swift  (+ .rc, app.manifest excluded)
                         linker: /SUBSYSTEM:WINDOWS /ENTRY:mainCRTStartup (as #114)
  product .executable("PokeTokenBarWin") — packaged as PokeTokenBar.exe (Task 12)
```

Why this shape:
- One module keeps upstream `Core` symbols internal, the stage 1 reason. A second Swift module would need `public` or `package` on upstream symbols, or `@testable` in release.
- Why `Platform/Windows` and not `Sources/PokeTokenBarWin`: the scan allows body-level `#if` only under `Platform/`. It has to be the same module so that tests (`@testable import PokeTokenBar`) reach the Windows transport and services.
- The executable is a separate target because testable executables on Windows are not certain. `main.swift` is two lines and has no `await` (G-b).
- The executable target is named `PokeTokenBarWin`, not `PokeTokenBar`, so the `.exe` and its `.lib` cannot collide with the library target's outputs (guess: they might not collide, but nothing is gained). The process name decides the defaults plist name (F2), so packaging renames the exe to `PokeTokenBar.exe`.
- Windows files count toward `shared-floor.txt` because they are not in `mac-only.txt`. Accepted: the floor only guards against shrinking.

### D2. Main thread, run loop and the main actor; how stages 6–7 host windows

**Decision (subject to Task 1):** `WindowsApp.main()` is synchronous and runs on the process main thread. It turns on `_CFRunLoopSetWindowsMessageQueueMask(CFRunLoopGetMain(), QS_ALLINPUT, kCFRunLoopDefaultMode)`, found at runtime through `CWinShim`'s `ptb_cf_enable_message_pump()`. It also installs a pump handler (`_CFRunLoopSetWindowsMessageQueueHandler`) that drains every queued message, not just one. Then it loops on `RunLoop.main.run(mode: .default, before: .distantFuture)` until quit. All windows are created on this thread. Every WndProc is `@convention(c)` and enters app code through `MainActor.assumeIsolated`. Background producers (socket I/O thread, DNS-SD and connectivity callbacks on thread-pool threads) hand work to the main thread only with `DispatchQueue.main.async`, which is FIFO, never with free-standing `Task {}`s, whose order isn't guaranteed.

**Fallbacks, chosen by Task 1's measurements and logged once at launch** (`WinMainLoop.Strategy`):
1. `.cfRunLoopWithMessages` (above).
2. `.dispatchHandle`: our own `MsgWaitForMultipleObjectsEx` on the dispatch main-queue handle (`_dispatch_get_main_queue_port_4CF` from `dispatch.dll`). On wake, `_dispatch_main_queue_callback_4CF`. Timers via `RunLoop.main.run(mode: .default, before: Date())` each pass, with the wait timeout taken from `RunLoop.main.limitDate(forMode:)` and clamped to 250 ms…60 s. The clamp avoids the busy loop on a past-due fire date reported on the Swift forums.
3. `.polling`: `GetMessageW` plus a 250 ms `SetTimer` that runs `RunLoop.main.run(mode: .default, before: Date())`. That is four wakeups a second at idle. If it is the only one that works, report it to the user as a §2 failure-condition risk before going on.

**Known limit:** Win32 modal loops (`TrackPopupMenuEx`, later window move/resize) run their own message loop, so main-queue jobs and `Timer`s wait until they return. The Mac's menu tracking has the same property. A tray menu is held for seconds at most; the 10 s TLS handshake timer can fire late, not early. For stage 6, if the plaza freezes while being dragged: during `WM_ENTERSIZEMOVE`…`WM_EXITSIZEMOVE`, a `SetTimer(16 ms)` drains with `RunLoop.main.run(mode: .default, before: Date())` (a guess; the stage 6 plan decides).

**How stages 6 and 7 host their windows** (this plan builds the host, not the windows):
- **Popover (stage 7):** a `WS_POPUP | WS_EX_TOOLWINDOW` window created on open and destroyed on close (Mac parity: the hosting tree is built on open and freed on close, for idle CPU). It is placed with `Shell_NotifyIconGetRect` and closes on `WM_ACTIVATE(WA_INACTIVE)`, like `.transient`. Dialog keyboard navigation needs `IsDialogMessageW`, so stage 7 extends the pump handler from D2 to call it for the popover's HWND. Win32 `EDIT` controls get IME composition for free because the pump calls `TranslateMessage`.
- **Plaza (stage 6):** a normal top-level window on the same thread. A frame clock runs only while the plaza is visible: a `Timer` on `RunLoop.main` at the scene's rate, or a DXGI `WaitForVBlank` thread posting to the main queue (stage 6 decides). Rendering is Direct2D to a swap chain, proven offscreen in spike 3. Chat input is an `EDIT` child (spec §6).
- **Floating pet (stage 7):** `WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW`.
- Every window shares the hidden sink window's message routing (`WinSinkWindow.on(_:_:)`), so new windows add handlers and never a second loop.

### D3. OS services on Windows

"CI" = what the runner checks headless. "PC" = what only the user's PC can show. Every failure is logged once through `AppLog` (the stage 1 stub rule).

| Service | Windows API | Swift / C boundary | CI | PC | Honest failure |
|---|---|---|---|---|---|
| Loop + main actor | CFRunLoop + message mask (D2) | `CWinShim` `ptb_cf_enable_message_pump()` (GetProcAddress) | selftest: thread ids for Task, `DispatchQueue.main`, `Timer`, posted message; message latency | tray menu feel | fallback strategy, logged |
| Tray icon | `Shell_NotifyIconW` (uID 1, `NIF_ICON\|NIF_MESSAGE\|NIF_TIP`), `RegisterWindowMessageW("TaskbarCreated")` | Swift via WinSDK | selftest add/modify/delete (if G-f holds) | overflow area on Win11, DPI crispness | `NIM_ADD` fails → retry on `TaskbarCreated`; notifications report unavailable |
| Tray image | WIC PNG decode → nearest-neighbour scale → `CreateIconIndirect` (32-bpp DIB) | `CWinShim` `ptb_png_to_bgra`, `ptb_icon_from_bgra` | unit: decode a fixture PNG, pixel checks | look | default app icon |
| Tray menu | `CreatePopupMenu` / `TrackPopupMenuEx` (+ `SetForegroundWindow` before, `WM_NULL` after) | Swift | `TrayMenuModel` unit tests (both OSes) | clicks | — |
| Notifications | balloon `NIF_INFO` (shown as toasts), `NIN_BALLOONUSERCLICK/HIDE/TIMEOUT` | Swift + shared `BalloonQueue` | queue unit tests; `Shell_NotifyIconW` returns TRUE | appears in Notification Center; Focus Assist | no tray → `isAvailable == false` → callers skip (existing guard); Focus Assist suppresses silently (documented) |
| Secret store | Credential Manager `CredReadW(CRED_TYPE_GENERIC)` | Swift (or shim if `wincred.h` doesn't import) | write/read/delete round trip | — | `.notFound` / `.unavailable` |
| Wake / will sleep | `RegisterSuspendResumeNotification(hwnd)` → `WM_POWERBROADCAST` `PBT_APMSUSPEND` / `PBT_APMRESUMEAUTOMATIC` | Swift | synthetic messages into `handlePowerBroadcast` | real sleep, Modern Standby | never fires → periodic timer and session heartbeats still recover (stub semantics) |
| Displays asleep | `RegisterPowerSettingNotification(GUID_CONSOLE_DISPLAY_STATE)` | Swift; GUID from shim if not importable | synthetic | display off pauses polling | never fires → polling continues (more CPU while the display is off) |
| Day change | `Timer` to the next local midnight + 1 s; re-armed on `WM_TIMECHANGE` and resume; fires at once on resume if the day key changed | shared `DayBoundary` | unit tests | crossing midnight | missed → the next refresh recomputes `todayKey` anyway |
| Idle clock | `GetLastInputInfo` + `GetTickCount` (wrapping subtraction) | Swift | finite, ≥ 0 | 5 min idle → away | returns 0 (never idle) |
| Reachability | `NotifyNetworkConnectivityHintChange` (Win10 2004+), level ≥ LocalAccess = satisfied (mapping is a guess) | Swift or shim (Task 1 P12) + shared `ReachabilityTransition` | registration + initial callback ≤ 5 s | Wi-Fi off/on | never fires → periodic refresh only |
| Single instance | `CreateMutexW("Local\\PokeTokenBar-Team[-<hash>]")`; second instance posts `WM_APP_SHOW` to the sink found by class and exits 3 | Swift | selftest spawns a second process → exit 3 | Start-menu relaunch | mutex error → run anyway, log |
| Launch at login | `HKCU\…\Run\PokeTokenBar = "\"<exe>\" --autostart"`; read `…\Explorer\StartupApproved\Run` (first byte `0x03` = disabled; community-known, undocumented) | Swift | round trip in a test-only subkey | sign-out/in, Task Manager toggle | write fails → unchecked + log |
| Update check | shared `UpdateChecker` + `InstallerReleaseFeed` (nil unless the release has a Windows installer asset); open = `ShellExecuteW` | shared + `PlatformShell` | canned JSON tests | real network, proxy | no banner (Mac behaviour on failure) |
| Crash log | marker file, `SetUnhandledExceptionFilter`, `MiniDumpWriteDump`, stderr → file | `CWinShim` `ptb_crash_install`, `ptb_crash_redirect_stderr` | CI crashes on purpose, then the next run reports it | — | filter can't run (stack overflow) → the marker still reports it next launch |
| Claude limits | `%USERPROFILE%\.claude\.credentials.json` + HTTPS (FoundationNetworking/libcurl) | shared `FileCredentialLimitsProvider` | `URLProtocol` stub tests + drift scan | real login | no file → `.keychainAccessDisabled` (limits hidden, as the stub) |
| Antigravity limits | token location on Windows unknown | stub stays | — | — | unavailable |
| Codex limits | `codex app-server` via `Process` (existing shared code) | shared | Task 1 P10 (`.cmd` spawn) | real install | binary not found → no Codex limits (Mac behaviour) |
| Tool dirs | `%APPDATA%\npm`, `%LOCALAPPDATA%\pnpm`, `%LOCALAPPDATA%\Microsoft\WinGet\Links`, `%USERPROFILE%\scoop\shims`, `%USERPROFILE%\.bun\bin`, `%LOCALAPPDATA%\Volta\bin` (likely), `%LOCALAPPDATA%\mise\shims` (likely), `%NVM_SYMLINK%` when set, `%USERPROFILE%\.local\bin`; then the process `Path` with `PATHEXT` | shared `PlatformCompat` | unit tests | — | not found → nil |
| Team discovery | `DnsServiceRegister` / `DnsServiceBrowse` / `DnsServiceResolve` | Swift or shim (Task 1 P12) | runner loopback register + browse | office Wi-Fi; Public profile blocks mDNS | browse fails → restart after 5 s (Mac rule); register fails → others can't dial us, we still dial them |
| Team TLS | OpenSSL 3 static | `CTeamTLS` | contract suite, known-answer tests, OpenSSL CLI interop | Mac interop | context fails → listener failed → retry after 5 s (Mac rule) |

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
| App | `/Applications/PokeTokenBar.app` | `%LOCALAPPDATA%\Programs\PokeTokenBar\` (exe, DLLs, `PokeTokenBar.version`, `licenses\`) | installer |
| State (companion save, caches, sprites) | `~/Library/Application Support/PokeTokenBar` | `%LOCALAPPDATA%\PokeTokenBar` | Foundation mapping (F1), no change; `PTB_STATE_DIR` override as on the Mac |
| Settings (`UserDefaults.standard`) | cfprefsd | `%LOCALAPPDATA%\PokeTokenBar.plist` (process name, F2; exact name printed by Task 1 P9) | CF XML plist; **synced by the app** (below) |
| Logs | `~/Library/Logs/PokeTokenBar.log` | `%LOCALAPPDATA%\PokeTokenBar\Logs\PokeTokenBar.log` (+ `.old.log`, `.crash.log`, `.stderr.log`, `*.dmp`, at most 3) | `PlatformCompat.logsDirectory()` (Task 3) |
| Launch at login | SMAppService | `HKCU\Software\Microsoft\Windows\CurrentVersion\Run\PokeTokenBar` | Task 10 |

Uninstall removes the app folder, the Run value and the Start-menu entry. It keeps state, settings and logs (Mac parity: deleting the app keeps Application Support).

**Is `UserDefaults` good enough on Windows?** Yes, with a sync policy. It is per user, XML, atomic enough, and has CF's locks. It is not good enough as it is (F2). The policy (`WinDefaultsSync`, Task 5): `synchronize()` once right after the stores are built (so `team.memberID` survives the first crash), every 30 s on a `Timer` (guess: CF writes only dirty domains; Task 1 P9 checks the file's mtime does not move when nothing changed), and at every clean exit (Quit, `WM_ENDSESSION`, `WM_CLOSE` from the installer's Restart Manager). The whole domain file is rewritten on each dirty sync; fine at this size.

### D5. Installer and what the user downloads

- **Inno Setup 6**, `PrivilegesRequired=lowest`, `DefaultDirName={localappdata}\Programs\PokeTokenBar`, `DisableDirPage=yes`, a fresh `AppId` GUID (not #114's). Start-menu shortcut with `AppUserModelID: "LikelionCampus.PokeTokenBar"` (unused in stage 4, so real toasts can come later without a reinstall). `AppMutex=Local\PokeTokenBar-Team`, `CloseApplications=yes`, launch after install (also in silent mode, so a future auto-update relaunches). `[Registry]` `ValueType: none; Flags: uninsdeletevalue` removes the Run value on uninstall without creating it. Optional desktop shortcut task. Licence page off; the `licenses\` folder ships.
- **Artifact:** `PokeTokenBar-Setup-<version>-win-x64.exe`, unsigned (SmartScreen accepted). Until stage 8 the user downloads it from the `windows-app` workflow run's artifacts. Version comes from `scripts/build-app.sh` `VERSION="x.y.z"` (single source). It is stamped into `PokeTokenBar.version`, the `.rc` `VERSIONINFO` (x.y.z.0) and the installer name.
- **Swift runtime DLLs:** copied app-local from the toolchain's runtime `bin`. The copy is not "all `*.dll`" (the spike's quick way); it is the dependency closure of the exe from `dumpbin /DEPENDENTS`, recursive. VC++ runtime DLLs come from the VS redist folder (`VC\Redist\MSVC\*\x64\Microsoft.VC14*.CRT`), not System32. The packaging script fails if a closure DLL is neither in System32/known OS DLLs nor in the mapped set, or if a shipped DLL has no entry in `windows/licenses/map.txt`. That is the machine check for licences.
- **Licences shipped:** OpenSSL (Apache-2.0), Swift runtime and Foundation (Apache-2.0 with Runtime Library Exception), ICU (Unicode License v3), libcurl (curl licence; inside FoundationNetworking if the closure shows it), swift-crypto and its namespaced BoringSSL (Apache-2.0 / OpenSSL-ISC; swift-crypto prefixes BoringSSL symbols, so they don't clash with OpenSSL), SQLite (public domain note), the app (MIT).
- **Resources:** `Sources/PokeTokenBarWin/PokeTokenBar.rc` with `VERSIONINFO`, `1 ICON assets\AppIcon.ico`, and `1 RT_MANIFEST app.manifest` (PerMonitorV2 DPI, `supportedOS` Win10, common controls v6 for stage 7). Compiled by `rc.exe` in CI and linked with `swift build -c release -Xlinker <abs>\PokeTokenBar.res`. Putting the manifest in the `.rc` avoids depending on lld-link's `/MANIFEST:EMBED`. `assets/AppIcon.ico` is generated once from `assets/icon_1024.png` by `scripts/generate-ico.py` (Pillow; 16/20/24/32/40/48/64/256) and committed.

### D6. Team transport on Windows

- **Threading:** `WindowsTeamTransport` is `@MainActor` and holds the same state as `BonjourTeamTransport`: `links`, `endpoints`, `planner`, `generation`, `wanted` / `running`, timers. All decisions (caps, cooldowns, budget, decode) happen on the main actor, as on the Mac, so floods behave the same.
  `WinSocketLoop` owns every socket and `SSL*` on one thread. It runs non-blocking Winsock in `WSAPoll` with an infinite timeout (zero idle cost), woken by a loopback UDP socket pair. It sends events to a mailbox drained by one `DispatchQueue.main.async` at a time, in order.
  **Receive mirrors Network.framework's pull model:** after `.ready`, the transport calls `receiveNext(id)`. The loop delivers at most one `.data` chunk of ≤ 65,536 bytes per call, then stops reading that socket until the next `receiveNext`. So the Mac's per-chunk budget (`bytes + frames × 1024`) and its TCP back-pressure carry over exactly. The loop calls `SSL_read` until `WANT_READ` before going back to poll, because decrypted bytes can sit in OpenSSL with no socket readiness.
- **OpenSSL:** vcpkg manifest `windows/vcpkg.json` (`openssl`, pinned `builtin-baseline`), triplet `x64-windows-static-md` (static libs, dynamic CRT, matching Swift's `/MD`; the spike's `x64-windows-static` is `/MT` and would clash). Installed by a composite action with `actions/cache` keyed on `hashFiles('windows/vcpkg.json')` + the runner image version. Exports `PTB_OPENSSL_DIR`. Local development needs vcpkg too; there is no Windows developer today. No vendoring (about 600k lines) and no third-party prebuilt (provenance).
  Swift never sees OpenSSL headers: `SSL_CTX_set_min_proto_version` and friends are macros the importer can't call. `CTeamTLS` exposes about ten plain C functions (Task 16).
- **DNS-SD:** instance `ptb-<12 lowercase hex>` (shared `TeamTransportRules.newInstanceName()`). Registered as `<instance>._ptbteam._tcp.local` on host `<DnsHostname>.local` at the listener port, no TXT. Browse `_ptbteam._tcp.local`: PTR with TTL > 0 → `found(label)`, TTL 0 → `lost(label)` (guess, F13). Own instance filtered. Resolve happens at dial time inside the dial's 10 s handshake budget (the link is adopted when the dial starts, so the caps count resolving dials). IPv4 first, then IPv6.
- **Listener:** dual-stack `[::]:0`, `IPV6_V6ONLY = 0`, as in the probe. The first listen raises the firewall prompt.
  If inbound ends up blocked, the team still works with Macs: Windows dials the Macs, which needs no inbound rule, and `TeamSession` keeps one link per pair. Only Windows↔Windows pairs would fail. The PC check reads the rule's action and profile (Task 20).
- **Wire compatibility** comes from shared code (`TeamCode.pskKey`, `TeamWire`), plus four proofs: known-answer tests for PSK bytes and a frame on both OSes, the contract suite on both transports, OpenSSL-CLI interop on both sides (a neutral third TLS stack), and the real Mac ↔ PC run.

### D7. Verification without a Windows machine here

CI can prove:
- the library builds and its tests pass (`windows.yml`, floor ≥ 1000 tests);
- the release exe builds;
- `--selftest` from the packaged folder, with `Path` stripped of the Swift toolchain (proves the DLL closure), and again from the silently installed copy (proves the installer, `isBundledApp`, logging, persistence);
- a deliberate crash followed by a clean relaunch report;
- loopback transport contract tests and runner-local DNS-SD;
- OpenSSL CLI interop;
- a 180 s idle CPU sample of `PokeTokenBar.exe` and `explorer.exe`;
- silent uninstall.

`--selftest --selftest-out <file>` runs inside the real loop, exercises every service, writes JSON (`{"result":"pass"|"fail","checks":[{"name","ok","detail"}]}`) and exits 0 or 1. Console output is not needed (GUI subsystem).

The PC proves what CI can't: the tray in the overflow, notifications actually shown, sleep and wake, the firewall prompt, SmartScreen and Defender, the office network, a real Mac. The PC checklists are Tasks 13 and 20; the session lead words them in Korean.

### D8. Idle cost (spec §2 failure condition)

Possible burners and how each is kept at zero:
- Tray animation: each frame is a cross-process `NIM_MODIFY`, so explorer.exe redraws and the cost lands outside our process. Stage 4 uses a static icon, updated only when the representative subject changes (open question 1).
- The loop: CF's blocking wait, no polling unless fallback 3 is forced.
- The socket loop: `WSAPoll(INFINITE)`.
- Timers: `UsageStore` 120 s and `TeamRuntime` 5 s, both as on the Mac; redial 15 s; defaults sync 30 s.
- Polling while the display is off: paused through `displaysAreAsleep` (D3).
- DNS-SD: browse started once per transport start, never restarted on a timer.

**Measured:**
- Task 1 P4: loop-only CPU over 30 s.
- Task 12: CI gate. The installed app idles 180 s with fixture data. ΔCPU of `PokeTokenBar.exe` < 1.8 s (1 % of one core) and ΔCPU of `explorer.exe` < 0.5 s (guess budgets; recorded in the PR and tightened after the PC numbers). The handle count does not grow by more than 20.
- Tasks 13 and 20: on the PC, 10 min idle, then 10 min with three or more teammates connected (`scripts/windows/measure-idle.ps1`, which samples `TotalProcessorTime`, private bytes and handles every 10 s and prints the averages), next to a `ps -o cputime` sample of the Mac app over the same 10 min (read-only).

### D9. Where Track A and Track B could collide

| Shared spot | Track B's footprint | Keeping it small |
|---|---|---|
| `Package.swift` | Task 2 only, inside `if windowsBuild` | Track A, if anything, edits the Mac branch. Different blocks merge cleanly. |
| `Sources/PokeTokenBar/mac-only.txt` | Task 10 removes one line (`Core/UpdateChecker.swift`) | Track A removes plaza lines in another block |
| `Tests/PokeTokenBarTests/mac-only.txt` | Task 10 removes `UpdateCheckerTests.swift`; Task 15 adds `TeamSessionLoopbackTests.swift`'s replacement only if renamed (planned: no rename) | different lines |
| `Platform/Platform.swift` | Task 7: two selector lines | Track B adds protocols in new files; Track A should do the same (tell the peer session after Task 7 merges) |
| `.github/workflows/windows.yml` | Task 2 replaces the setup step with the composite action, once | Track B's own jobs go in the new `windows-app.yml`. If Track A adds a Windows render job, it should use the same composite action. |
| `shared-floor.txt` | raised by tasks that add shared code | single number; on conflict re-measure and take the new count |
| `SharedSourcesScanTests.swift` | not touched | Track B's scans live in `TeamTransportContractScanTests.swift`, `WindowsSeamScanTests.swift` |
| `docs/reference/defect-log.md`, `CONTRIBUTING.md` | append-only sections | distinct headings |

### D10. Risks and the cheapest early experiment for each

1. **Swift concurrency under a Win32 loop** (D2, G-a…G-d). Cheapest: Task 1, one throwaway exe on CI, half a day. If all three strategies fail, stop and ask: the stores are `@MainActor` and nothing else works.
2. **Toasts from an unpackaged app.** Real WinRT toasts (`ToastNotificationManager::CreateToastNotifier(aumid)`) need an AppUserModelID. In the classic model that ID must also sit on a Start-menu shortcut (`System.AppUserModel.ID`). Newer guidance for unpackaged apps also lists a registry route (`…\Software\Classes\AppUserModelId\<AUMID>` with `DisplayName`) — not tried. Clicks while the app is closed need a COM activator CLSID. Cheapest path: balloons (`NIF_INFO`), which need none of this, with clicks while running through `NIN_BALLOONUSERCLICK` (G-e). The installer still stamps the shortcut's AUMID so toasts can come later. Experiment: the stage 4 PC check posts one through `--selftest`.
3. **Firewall prompt on the first listen,** standard account. Spike: a rule was created without an admin password; its action and profile were not read. Cheapest: the PC check reads `netsh advfirewall firewall show rule name=all dir=in verbose` filtered to the exe. Blocked inbound still allows Windows-initiated links (D6).
4. **Antivirus and SmartScreen.** Unsigned binary, plus a listener, plus DNS-SD. Cheapest: Defender right-click scan on the PC, and record the SmartScreen flow. A VirusTotal upload shares the binary with a third party (open question 7).
5. **OpenSSL build time in CI.** Uncached it is 5 min (F11). Cheapest: Task 2 records cold and warm times. A miss only costs time.
6. **`URLSession` on Windows.** FoundationNetworking uses libcurl. It reads proxy settings from environment variables only, not the WinINET or PAC system proxy (guess, from libcurl's behaviour), and validates TLS against the Windows certificate store. Cheapest: Task 1 P11 (HTTPS GET from the runner), and the PC check on the office network (do limits and the update check work?).
7. **File watching:** none (F7). No risk.
8. **Foundation-on-Windows silent differences** (F1–F3). These are certain. Fixed in Tasks 3 and 5, captured in `defect-log.md` as a class.
9. **DNS-SD details.** Removal events may never come (then a gone teammate is dialed about once a minute until the browse restarts — harmless). Virtual adapters (WSL, Hyper-V, VPN) may be advertised. A Public network profile blocks mDNS. Cheapest: the stage 5 PC check records the network profile, `ipconfig`, and `--team-probe` output.
10. **Modern Standby** laptops may never send `PBT_APMSUSPEND`. Links then die by TCP and session heartbeat. PC check item.
11. **Win11 hides new tray icons in the overflow.** A first-run balloon tells the user (spec §8).
12. **`.cmd` shims** (Codex limits via `codex.cmd`). Task 1 P10. If corelibs `Process` can't run them, Codex limits stay unavailable on Windows (state it; no workaround in this plan).

## File Structure

```
Package.swift                                   modify (Task 2): Windows-only targets in the windowsBuild branch
windows/vcpkg.json                              create (2): openssl, pinned baseline
windows/licenses/                               create (12): licence texts + map.txt (dll → licence)
.github/actions/windows-swift/action.yml        create (2): Swift 6.3.2 + cached vcpkg OpenSSL, exports PTB_OPENSSL_DIR
.github/workflows/windows.yml                   modify (2): use the composite action
.github/workflows/windows-app.yml               create (2), grows (5, 11, 12, 19): release exe, package, selftests, installer, idle gate
installer/PokeTokenBar.iss                      create (12)
scripts/windows/package.ps1                     create (2: plain copy) → (12: dumpbin closure, rc, licences)
scripts/windows/measure-idle.ps1                create (12)
scripts/generate-ico.py, assets/AppIcon.ico     create (12)
scripts/team-interop-check.sh                   create (19): Mac Network.framework ↔ openssl s_server/s_client
Sources/CWinShim/{include/CWinShim.h, *.c, *.cpp}   create (2), grows (5, 6, 11)
Sources/CTeamTLS/{include/CTeamTLS.h, CTeamTLS.c}   create (2), grows (16)
Sources/PokeTokenBarWin/main.swift              create (2)
Sources/PokeTokenBarWin/{PokeTokenBar.rc, app.manifest}   create (12)
Sources/PokeTokenBar/Platform/
  PlatformCompat.swift                          modify (3, 4): isBundledApp, logsDirectory, pathVariableKey, executableCandidates,
                                                toolDirectories, userApplicationSupport, searchProcessPath, pid_t on Windows
  Platform.swift                                modify (7): two selector lines, once
  PlatformShell.swift                           create (10): open(URL), terminate()
  Mac/MacShell.swift                            create (10): the two AppKit calls, verbatim
  TrayMenuModel.swift, BalloonQueue.swift, DayBoundary.swift, ReachabilityTransition.swift,
  FileCredentialLimitsProvider.swift, InstallerReleaseFeed.swift, AppWiring.swift   create: shared, pure, tested on both OSes
  Windows/                                      every file wrapped in #if os(Windows)
    WindowsPlatform.swift                       modify (7): stubs by default; live(...) installed by the app
    WindowsApp.swift, WinMainLoop.swift, WinSinkWindow.swift, WinSingleInstance.swift,
    WinDefaultsSync.swift, WindowsSelftest.swift, WindowsInstall.swift          create (2, 3, 5)
    WinTray.swift, WinIcon.swift                create (6)
    WindowsSystemEvents.swift, WindowsIdleClock.swift, WindowsReachability.swift   create (7)
    WinBalloonPresenter.swift, WindowsNotifications.swift                       create (8)
    WindowsLimitsProviders.swift, WindowsSecrets.swift                          create (9)
    WindowsLoginItem.swift, WindowsShell.swift  create (10)
    WindowsCrashLog.swift                       create (11)
    Team/WinTLS.swift (16), Team/WinSocketLoop.swift (17), Team/WinDNSSD.swift (18),
    Team/WindowsTeamTransport.swift, Team/WindowsTeamProbe.swift (19)
Sources/PokeTokenBar/Team/TeamTransportRules.swift    create (14): constants + TeamLinkReceiver, shared
Sources/PokeTokenBar/Team/TeamTransport.swift         modify (14): uses the rules; behaviour identical
Sources/PokeTokenBar/Core/{AppEnv,AppLog}.swift       modify (3): one line each (upstream-owned)
Sources/PokeTokenBar/Core/BinaryLocator.swift         modify (4): path key, candidates, tool dirs, PATH fallback (upstream-owned)
Sources/PokeTokenBar/Core/{LocalUsageReader,LocalAdditionalUsageProvider}.swift   modify (4): Claude Desktop / Cursor base (upstream-owned)
Sources/PokeTokenBar/Core/UpdateChecker.swift         modify (10): AppKit → PlatformShell (upstream-owned); leaves mac-only.txt
Tests/PokeTokenBarTests/
  TeamTransportContract.swift                   create (15): harness protocol + scenarios (both OSes)
  TeamTransportTests.swift                      modify (15): becomes the Mac wrapper (stays Mac-only)
  TeamSessionLoopbackTests.swift                modify (15): scenario moved into the contract; file becomes a wrapper
  TeamTransportContractScanTests.swift          create (15)
  WindowsSeamScanTests.swift                    create (3)
  Windows*Tests.swift                           create (3, 5–11, 16–19), each wrapped in #if os(Windows)
  <shared pure tests>                           create next to their subjects
docs/reference/defect-log.md, docs/reference/provider-extension.md, CONTRIBUTING.md, spec §9.1/§10/§13   modify (3, 4, 13, 20)
```

## Review Focus

Five ways this could look done and be wrong:

1. **`@MainActor` work that doesn't run, or runs on the wrong thread, in the real app while XCTest is green.** XCTest drives the run loop its own way, so passing tests say nothing about `WindowsApp`'s loop.
   → Task 1 measures the loop outside XCTest. Task 5's selftest asserts, inside the shipped loop, that a `Task`, a `DispatchQueue.main` block, a `RunLoop` `Timer` and a posted message each ran on the main thread id. The selftest shortens `UsageStore.refreshInterval` and checks the timer actually refreshed.
2. **Green on the runner, broken on a clean PC.** Causes: DLLs picked up from the toolchain on `Path`; `isBundledApp` false in the CI layout, hiding the log trap and persistence bugs; settings lost because nothing synchronizes; `Path` vs `PATH` duplicated in child environments.
   → A stripped-`Path` selftest from the packaged folder; a selftest of the installed copy; a two-process defaults check that kills the writer hard; trigger tests with a real `"Path"` key (Task 4).
3. **Wire compatibility assumed from shared code but broken by the transport.** Examples: instance naming, self-filter, TLS settings, partial `SSL_read`/pending data, a push-model reader that turns an honest sync into a "flood".
   → One contract suite on both transports, pull-model receive (D6), known-answer tests on both OSes, OpenSSL CLI interop on both sides, and the real Mac ↔ PC run.
4. **A service that returns OK and does nothing.** Examples: `NIF_INFO` accepted but suppressed or hidden; a Run value written but disabled in `StartupApproved`; a firewall rule created as Block; a connectivity hint registered but never called.
   → Each selftest check asserts an observable effect where one exists (initial connectivity callback, registry read-back, a second process exiting 3). The rest are PC checklist items that read the actual state (netsh rule action and profile, StartupApproved byte, Notification Center).
5. **Idle CPU fine in our process but burned elsewhere or later:** explorer.exe redraws from tray updates, a fallback polling loop silently chosen, `WSAPoll` with a timeout, a browse restarted on a timer.
   → The strategy is logged and in the selftest JSON. The CI idle gate samples both processes. `WSAPoll(INFINITE)` is a review checkpoint in Task 17. The tray is static.

Also check in every review: no Mac-visible difference. Each Mac-touching task names the Mac test that pins the old value.

---

### Task 1: Experiment E1 — the main loop and Foundation-on-Windows facts **[most capable]**

Throwaway, on `spike/windows-port`. Results are recorded in `spike/RESULTS.md` (§ Experiment 5) and, by a docs PR to `windows-port`, in spec §9.1.

**Files:**
- Create (spike branch): `spike/loop/Package.swift`, `spike/loop/Sources/CLoopShim/{include/CLoopShim.h, CLoopShim.c}`, `spike/loop/Sources/ptbloop/main.swift`, `spike/loop/Sources/ptbloop-async/main.swift`, `spike/loop/Sources/ptbloop/{Probes*.swift}`
- Modify (spike branch): `.github/workflows/spike-windows.yml` (job `loop`)

**Interfaces:**
- Produces a decision record: `WinMainLoop.Strategy` = `.cfRunLoopWithMessages` | `.dispatchHandle` | `.polling(interval:)`, the DLL that exports each symbol, and a WinSDK coverage list (which APIs need `CWinShim`).
- C, for later reuse: `int ptb_cf_enable_message_pump(uint32_t mask)` (0 ok, −1 symbol missing), `void *ptb_dispatch_main_queue_handle(void)`, `void ptb_dispatch_drain_main_queue(void)`.

**Steps** (each probe writes `NAME: PASS|FAIL|VALUE …` to `loop-report.txt`):
- [ ] **P1 symbols.** `GetProcAddress` over the loaded modules (`EnumProcessModules`) for `_CFRunLoopSetWindowsMessageQueueMask`, `_CFRunLoopSetWindowsMessageQueueHandler`, `CFRunLoopGetMain`, `kCFRunLoopDefaultMode`, `_dispatch_get_main_queue_port_4CF`, `_dispatch_main_queue_callback_4CF`. Record the module of each.
- [ ] **P2 strategy 1.** Synchronous `main`. Enable the mask; create a hidden top-level window; then within 5 s of `RunLoop.main.run(mode: .default, before:)`:
  - (a) `Task { @MainActor }` from main;
  - (b) `Task.detached { await MainActor.run {} }`;
  - (c) `DispatchQueue.main.async` from a background `Thread`;
  - (d) a 200 ms repeating `Timer` on `RunLoop.main` `.common`;
  - (e) `PostMessageW` from a background thread;
  - (f) `withObservationTracking` `onChange` → `Task { @MainActor }`;
  - (g) `Task.sleep(1 s)` on the main actor.

  Each records `GetCurrentThreadId() == mainTid` and its latency. PASS = all on the main thread and posted-message latency < 50 ms at idle.
- [ ] **P3 `MainActor.assumeIsolated` in the WndProc,** in a child process (`--p3`), so a trap shows as an exit code.
- [ ] **P4 idle cost.** Only a 120 s timer scheduled; run 30 s; `GetProcessTimes` Δ < 50 ms. Repeat for each strategy that passes.
- [ ] **P5 strategy 2** (if P1 found the dispatch symbols): the same checks as P2.
- [ ] **P6 async main** (`ptbloop-async`): after the first `await`, record the thread id and whether a window created before the `await` still gets posted messages. Records G-b.
- [ ] **P7 modal loop.** `TrackPopupMenuEx` cancelled after 1 s by a `SetTimer` → `EndMenu()`. Record whether a `Timer` or `Task` scheduled during the menu fired during it or after.
- [ ] **P8 tray.** `Shell_NotifyIconW` `NIM_ADD`, `NIF_INFO`, `NIM_DELETE` return values on the runner.
- [ ] **P9 Foundation facts.**
  - The count of `urls(for: .libraryDirectory, in: .userDomainMask)`, the Application Support path, `NSHomeDirectory()`, `Bundle.main.bundleIdentifier/bundlePath/executablePath`, `ProcessInfo.processName`.
  - The plist path `UserDefaults.standard` writes after `synchronize()`.
  - Two-process check: a child sets a key without `synchronize` and is `TerminateProcess`ed → the parent reads the plist → expect absent. With `synchronize` → present. A no-change `synchronize` leaves the mtime unchanged.
- [ ] **P10 Process.** `isExecutableFile` for `.exe`, `.cmd`, `.txt`. Run a temp `echo.cmd` with arguments `a b`, `"q"`, `x&y` through `Process` → captured output equals the arguments.
- [ ] **P11 URLSession.** GET `https://api.github.com/repos/likelion-campus/PokeTokenBar/releases/latest`. Any HTTP status counts as TLS + HTTP OK; record the status and time.
- [ ] **P12 WinSDK coverage.** One tiny file per API (`DnsServiceRegister`, `DnsServiceBrowse`, `NotifyNetworkConnectivityHintChange`, `GetLastInputInfo`, `Shell_NotifyIconW`, `CredReadW`, `RegisterPowerSettingNotification` + `GUID_CONSOLE_DISPLAY_STATE`, `RegisterSuspendResumeNotification`, `WSAPoll`, `MiniDumpWriteDump`, `SHGetKnownFolderPath`). The build log (`swift build -Xswiftc -continue-building-after-errors`) shows which don't import.
- [ ] **Decide.** P1 + P2 + P3 + P4 pass → strategy 1. Else P5 → strategy 2. Else strategy 3: measure its P4 and report to the user before Task 5.
- [ ] **Commit to the spike branch; a docs PR `docs: record the Windows main-loop experiment` into `windows-port`** (spec §9.1 row + the decision). Tell the session lead the strategy.

**Verify:** `gh run watch --repo likelion-campus/PokeTokenBar <id> --exit-status` → the `loop` job exits 0 (probes record FAIL without failing the job), and the artifact `loop-report` has every P-line. **Size:** M. **PC:** no.

---

### Task 2: Build skeleton — Windows-only targets, cached OpenSSL, app workflow

**Files:**
- Modify: `Package.swift` (the `windowsBuild` branch only), `.github/workflows/windows.yml` (setup step → composite action)
- Create: `windows/vcpkg.json`, `.github/actions/windows-swift/action.yml`, `.github/workflows/windows-app.yml`, `scripts/windows/package.ps1` (v1: copy the exe, all runtime DLLs, `PokeTokenBar.version`), `Sources/CWinShim/{include/CWinShim.h, shim.c}`, `Sources/CTeamTLS/{include/CTeamTLS.h, CTeamTLS.c}`, `Sources/PokeTokenBarWin/main.swift`, `Sources/PokeTokenBar/Platform/Windows/WindowsApp.swift`

**Interfaces:**
- Produces:
  - In the manifest: `let onWindows: Bool` (true only under `#if os(Windows)`); `let opensslDir = env["PTB_OPENSSL_DIR"] ?? "C:/vcpkg/installed/x64-windows-static-md"`; targets `CWinShim`, `CTeamTLS`, `.executableTarget("PokeTokenBarWin")` and product `.executable(name: "PokeTokenBarWin", targets: ["PokeTokenBarWin"])`, all only when `onWindows`; `PokeTokenBar` gains `+ (onWindows ? ["CWinShim", "CTeamTLS"] : [])`.
  - C: `int ptb_shim_abi(void)`, `const char *ptb_tls_openssl_version(void)`.
  - Swift: `public enum WindowsApp { public static func main() -> Int32 }`. In this task it handles `--selftest --selftest-out <path>` by writing `{"result":"pass","version":…,"openssl":…}`.
  - `main.swift`: `import PokeTokenBar` / `exit(WindowsApp.main())`. No `await`.
  - Composite action: no inputs; sets `PTB_OPENSSL_DIR`; logs cache hit or miss and the install time.

**Steps:**
- [ ] Write the manifest change. `CTeamTLS` `cSettings: [.unsafeFlags(["-I\(opensslDir)/include"])]` and `linkerSettings: [.unsafeFlags(["-L\(opensslDir)/lib"]), .linkedLibrary("libssl"), .linkedLibrary("libcrypto"), .linkedLibrary("crypt32"), .linkedLibrary("ws2_32"), .linkedLibrary("advapi32"), .linkedLibrary("user32")]`. If G-h fails, use `-Xlinker /LIBPATH:`. `CWinShim` links `windowscodecs`, `ole32`, `dbghelp`, `iphlpapi`, `dnsapi`. The executable links with `/SUBSYSTEM:WINDOWS /ENTRY:mainCRTStartup`.
- [ ] `windows-app.yml`:
  - Triggers: push to `windows-port`; `pull_request` with paths `Sources/**`, `Package.swift`, `windows/**`, `scripts/windows/**`, `installer/**`, `.github/**`; `workflow_dispatch`. Concurrency per ref.
  - Steps: composite action → `swift build -c release --product PokeTokenBarWin` → `package.ps1 -Out bundle` → run `bundle\PokeTokenBar.exe --selftest --selftest-out st.json` with `Path` reduced to `C:\Windows\System32;C:\Windows` → assert `result == pass` → upload `bundle` and `st.json`.
- [ ] Mac checks: `swift build` (manifest still valid; the Mac branch is unchanged) and `./scripts/shared-check.sh` (no Windows-only target is declared under `PTB_SHARED_ONLY`).
- [ ] Push. `windows.yml` stays green (≥ 1000 tests). `windows-app.yml` is green; record the cold and warm vcpkg times in the PR.
- [ ] **PR `build: add the Windows app skeleton and cached OpenSSL`**, merge. Tell the Track A session about the composite action and that `Package.swift`'s `windowsBuild` branch now has Windows-only targets.

**Verify:** on the Mac, `swift build` → `Build complete!` and `./scripts/shared-check.sh` → exit 0. On Windows, both workflow runs exit 0, and the `st.json` artifact contains `"openssl":"OpenSSL 3.`. **Size:** M. **PC:** no.

---

### Task 3: Foundation-on-Windows seams — bundled-app rule and the log folder

The fix for F1 + F3 as one defect class: "Foundation on Windows differs silently".

**Files:**
- Modify: `Platform/PlatformCompat.swift`, `Core/AppEnv.swift` (1 line), `Core/AppLog.swift` (1 expression), `docs/reference/defect-log.md`
- Create: `Platform/Windows/WindowsInstall.swift`, `Tests/PokeTokenBarTests/WindowsSeamScanTests.swift`, `Tests/PokeTokenBarTests/WindowsFoundationTests.swift`
- Test (both OSes): additions to `PlatformCompatTests.swift`

**Interfaces:**
- Produces:
  ```swift
  extension PlatformCompat {
      /// Mac: `Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")`, verbatim, computed per call.
      /// Windows: `WindowsInstall.isPackagedLayout`, computed once.
      static var isBundledApp: Bool { get }
      /// Mac: `FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs")`, verbatim.
      /// Windows: `<applicationSupport>/PokeTokenBar/Logs` (= %LOCALAPPDATA%\PokeTokenBar\Logs).
      static func logsDirectory() -> URL
  }
  enum WindowsInstall {                                      // Windows only
      static let versionFileName = "PokeTokenBar.version"
      static func isPackagedLayout(executableDirectory: URL) -> Bool   // version file present and non-empty
      static var isPackagedLayout: Bool { get }              // for the running exe (GetModuleFileNameW)
      static var version: String? { get }                    // trimmed file contents
  }
  ```
  `AppEnv.isBundledApp` returns `PlatformCompat.isBundledApp`. `AppLog.url` uses `PlatformCompat.logsDirectory()`.

**Steps:**
- [ ] **Root cause (for the PR):** `AppLog` indexes `[0]` on a search path that Windows doesn't map (F1). Tests never saw it because `AppLog.write` returns early outside a bundle, and on Windows nothing is a bundle (F3). The same gate hid persistence and live limits.
  **Class sweep:** every `urls(for:in:)[0]` in `Sources`. Six use `.applicationSupportDirectory` (mapped, safe); `AppLog` and the Mac-only `CrashReporter` use `.libraryDirectory`. List them in the PR.
  **Reachability:** after this task `isBundledApp` is true in the packaged layout, so the trap becomes reachable and is fixed in the same PR.
- [ ] Failing tests:
  - `testBundledAppRuleOnTheMacIsUnchanged` (Mac: equals the old expression);
  - `testLogsDirectoryOnTheMacIsLibraryLogs` (Mac: equals the old expression);
  - `testLibraryDirectoryIsUnmappedOnWindows` (Windows: count 0; documents F1);
  - `testLogsDirectoryIsUnderLocalAppData` (Windows);
  - `testNotBundledUnderSwiftTest` (both);
  - `testPackagedLayoutNeedsTheVersionFile` (Windows: temp dir with, without and with an empty file).
- [ ] Capture: `WindowsSeamScanTests.testSharedFilesDoNotAskForTheLibraryDirectory`. A shared file outside `Platform/` that contains `.libraryDirectory` fails, with "use PlatformCompat.logsDirectory()". Fault-inject once by adding a `.libraryDirectory` use → fails.
- [ ] Implement. Run `swift test --filter "PlatformCompatTests|WindowsSeamScanTests|LiveCredentialCallGateTests"`, then `./scripts/shared-check.sh`, then `./scripts/test-gate.sh`.
- [ ] `defect-log.md`: a new class entry, "Foundation on Windows: unmapped search paths, no bundle, defaults written only on synchronize". Tasks 4 and 5 add to it.
- [ ] **PR `fix(windows): give the Windows app a bundled-app rule and a log folder`**, merge. The body lists the two upstream lines.

**Verify:** Mac filters pass, `test-gate.sh` green; Windows run green with the new Windows tests counted. **Size:** S. **PC:** no.

---

### Task 4: Tool directories and log roots on Windows

**Files:**
- Modify: `Platform/PlatformCompat.swift`; `Core/BinaryLocator.swift` (`augmentedEnvironment`, `commonToolDirectories`, `commonNodeToolPaths`, `locate`); `Core/LocalUsageReader.swift` (the Claude Desktop line); `Core/LocalAdditionalUsageProvider.swift` (Cursor roots in `defaultCursorRoots` and `cursorRoots`); `docs/reference/provider-extension.md` (the D3 table); `docs/reference/defect-log.md`
- Test: `Tests/PokeTokenBarTests/WindowsPathTests.swift` (extend), `BinaryLocatorTests.swift` (Mac pins)

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
  }
  ```
  Upstream edits, each Mac-identical:
  - `augmentedEnvironment` reads and writes `base[PlatformCompat.pathVariableKey(in: base)]`.
  - `commonToolDirectories()` returns `PlatformCompat.toolDirectories(posix: [<today's literal list>])`.
  - `commonNodeToolPaths` is `flatMap { PlatformCompat.executableCandidates("\($0)/\(binary)") }`.
  - `locate` step 2 is `PlatformCompat.searchProcessPath(binary, environment: ProcessInfo.processInfo.environment) ?? shellResolve(binary)`.
  - Desktop and Cursor bases go through `userApplicationSupport(home:)`.

**Steps:**
- [ ] **Defect (found by reading):** on Windows the process environment's key is `Path`. `augmentedEnvironment` reads `base["PATH"]` (nil) and writes `env["PATH"]`, so child processes get both keys (which one wins is undefined).
  **Why stage 1 missed it:** `testAugmentedPathUsesThePlatformSeparator` injects `["PATH": …]`, not the `Path` key a real Windows process has.
  **Reachability:** every child process spawned with `augmentedEnvironment` (Codex limits, the shell lookup).
- [ ] Failing tests:
  - `testAugmentedEnvironmentKeepsOnePathKey`. Base `["Path": "C:\\a;C:\\b"]`. Windows: exactly one key matching PATH case-insensitively, containing `C:\a` and the tool dirs. Mac: the output equals today's for the same base (pins the Mac).
  - Mac pins: `testCommonNodeToolPathsOnTheMacAreUnchanged` (equals today's literal list), `testCursorRootsOnTheMacAreUnchanged`, `testClaudeDesktopRootOnTheMacIsUnchanged`.
  - Windows: `testExecutableCandidatesPreferExe`, `testSearchProcessPathFindsACmdShim` (temp dir with `codex.cmd`, env `Path=<dir>`), `testCursorRootsAreUnderRoamingAppData`, `testClaudeDesktopRootIsUnderRoamingAppData`.
- [ ] Implement. Fault-inject: on Windows make `pathVariableKey` return `"PATH"` → the trigger test fails. Revert.
- [ ] Unknown rows stay unchanged and are documented as unknown in `provider-extension.md`.
  UNC and mixed-separator custom roots are deferred to stage 7. Reachability: custom roots come only from Settings, which doesn't exist on Windows yet. A differently cased `CLAUDE_CONFIG_DIR` duplicates a scan but doesn't change totals.
- [ ] `swift test --filter "BinaryLocatorTests|WindowsPathTests|CustomScanRootsTests"`, then `shared-check.sh`, then `test-gate.sh`. Push → Windows green.
- [ ] **PR `fix(windows): find tools and tool logs where Windows keeps them`**, merge. The body lists the upstream lines.

**Verify:** as above. **Size:** M. **PC:** no.

---

### Task 5: App core — loop, sink window, single instance, defaults sync, stores, selftest **[most capable]**

**Files:**
- Create (all `Platform/Windows/`): `WinMainLoop.swift`, `WinSinkWindow.swift`, `WinSingleInstance.swift`, `WinDefaultsSync.swift`, `WindowsSelftest.swift`
- Create: `Platform/AppWiring.swift` (shared)
- Modify: `WindowsApp.swift`, `Sources/CWinShim/` (`cf_spi.c` from Task 1), `.github/workflows/windows-app.yml` (fixture env)
- Create: `Tests/PokeTokenBarTests/Fixtures/windows-selftest/claude/projects/p/s.jsonl`
- Test: `Tests/PokeTokenBarTests/WindowsShellTests.swift` (Windows), `AppWiringTests.swift` (both), `AppWiringDriftScanTests.swift` (Mac)

**Interfaces:**
- Consumes: Task 1's strategy, `CWinShim` `ptb_cf_enable_message_pump`, Task 3's `WindowsInstall`.
- Produces:
  ```swift
  enum WinMainLoop {
      enum Strategy: String, Equatable { case cfRunLoopWithMessages, dispatchHandle, polling }
      static func prepare() -> Strategy                            // picks by Task 1's rule, logs once
      static func run(_ strategy: Strategy, until done: @escaping @MainActor () -> Bool)
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
  @MainActor enum WinDefaultsSync { static func start(interval: TimeInterval = 30); static func flushNow() }
  enum AppWiring {                                                 // shared; the Mac keeps its own copy in AppDelegate
      @MainActor static func updateCompanion(_ companion: CompanionStore, from store: UsageStore)
      @MainActor static func storeRefreshed(_ companion: CompanionStore, _ store: UsageStore)
  }
  @MainActor final class WindowsAppDelegate {
      init(arguments: [String])
      func launch() -> Bool                                        // false = yielded or failed (logged)
      func quit(_ reason: QuitReason) -> Never                     // flush log, sync defaults, remove tray, exit(0)
      enum QuitReason { case menu, endSession, closeRequest, selftest(Int32) }
      private(set) var store: UsageStore!; private(set) var companion: CompanionStore!; let teamSettings: TeamSettings
  }
  enum WindowsSelftest {
      struct Check: Codable, Equatable { let name: String; let ok: Bool; let detail: String }
      @MainActor static func run(_ app: WindowsAppDelegate) async -> [Check]
      static func write(_ checks: [Check], to url: URL) throws
  }
  ```
  Process flags: `--selftest`, `--selftest-out <path>`, `--selftest-second` (internal), `--selftest-defaults-writer flush|noflush <key> <value>` (internal), `--autostart`, `--version`.

**Steps:**
- [ ] Launch order (mirrors `AppDelegate.applicationDidFinishLaunching`):
  1. single instance (before anything that writes);
  2. crash log hook (a no-op until Task 11);
  3. `SetProcessDpiAwarenessContext(PER_MONITOR_AWARE_V2)`;
  4. `WinMainLoop.prepare()`;
  5. sink window;
  6. `Platform.current = WindowsPlatform.live(window:)` (stubs until Tasks 7–9 fill parts);
  7. `UsageStore()`, `CompanionStore()`, `Task { await companion.preparePokemonProfiles() }`, `store.localizationLanguage = companion.language`, `store.onRefresh = { AppWiring.storeRefreshed(companion, store) }`;
  8. `TeamSettings()`;
  9. `WinDefaultsSync.flushNow(); WinDefaultsSync.start()`;
  10. `observeStore`, the same `withObservationTracking` shape as the Mac (no tray yet; it calls `AppWiring.updateCompanion`);
  11. `WinMainLoop.run`.

  `WM_ENDSESSION(TRUE)` and `WM_CLOSE` on the sink → `quit(.endSession / .closeRequest)`.
- [ ] `AppWiring` copies `updateCompanion` / `onStoreRefreshed` from `PokeTokenBarApp.swift:375–392`. `AppWiringDriftScanTests` (Mac) extracts the argument labels of `companion.update(` and the `grantCandies(` call from both files and asserts they are equal. Fault-inject by dropping a label → fails.
- [ ] Failing tests:
  - `testMutexNameIsFixedForTheDefaultStateFolder` and `testMutexNameDiffersPerStateFolder` (pure; Windows);
  - `testAppWiringPassesEveryUsageInput` (both; injected providers via `UsageStore(providers:…)`, `TestDefaults.make(suite:)`).
- [ ] Selftest checks:
  - `loop.strategy`;
  - `loop.mainActorTask`, `loop.mainQueue`, `loop.runLoopTimer`, `loop.postedMessage` (main thread id each);
  - `paths.state` (under `%LOCALAPPDATA%`, or `PTB_STATE_DIR`), `paths.logs`;
  - `log.writes` (`AppLog.writeAndFlush` then read back; only when `isBundledApp`, otherwise recorded as `skipped: not packaged`);
  - `defaults.persist`: spawn `--selftest-defaults-writer flush k v` → parse the plist → v present. `noflush` → recorded, informational.
  - `singleInstance.second`: spawn `--selftest-second` → exit code 3.
  - `store.refresh`: CI sets `CLAUDE_CONFIG_DIR` to the fixture and `PTB_STATE_DIR` to a temp dir; after `await store.refresh()`, `todayTotalTokens` equals the fixture's sum. The fixture's timestamps are written at run time by the workflow step so they are "today".
  - `store.timer`: set `refreshInterval = 2` and expect a second refresh within 5 s.
  - `companion.update`: the companion saw `hasUsageData == true`.
- [ ] Push. `windows-app.yml` runs the bundle selftest with the fixture env, so every check passes or is skipped as stated.
- [ ] **PR `feat(windows): run the stores in a Windows app loop`**, merge.

**Verify:** `windows-app` `st.json` has `"result":"pass"` and `loop.strategy == cfRunLoopWithMessages` (or Task 1's choice). Mac `swift test --filter AppWiring`, then `test-gate.sh` (new shared file). **Size:** L. **PC:** no.

---

### Task 6: Tray icon and menu

**Files:**
- Create: `Platform/Windows/WinTray.swift`, `Platform/Windows/WinIcon.swift`, `Platform/TrayMenuModel.swift` (shared), `Sources/CWinShim/wic.cpp`
- Modify: `WindowsApp.swift`; `Team/TeamLocalization.swift` (only strings `StatusItemMenu` doesn't already have: "Launch at login", "Disabled in Task Manager", "Open log folder", the first-run tray hint, "Already running")
- Test: `TrayMenuModelTests.swift` (both), `WindowsTrayTests.swift` (Windows)

**Interfaces:**
- Produces:
  ```swift
  @MainActor final class WinTray {
      init(window: WinSinkWindow)
      func add() -> Bool; func remove()
      func setIcon(_ icon: WinIcon?); func setTip(_ text: String)          // clipped to 127 UTF-16 units
      func showBalloon(title: String, body: String, sound: Bool) -> Bool   // used by Task 8
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
- [ ] Icon: the egg from `SpriteStore.shared.eggData()`; after hatching, the representative subject's static PNG from `SpriteStore.shared.data(speciesID:animated: false, shiny:form:back:)`. Size = `GetSystemMetricsForDpi(SM_CXSMICON, dpi)`. Re-rendered on `WM_DPICHANGED`/`WM_SETTINGCHANGE`.
  Observation copies `observeCompanionSprite`'s tracked keys (subject, `facesBack`), but without frames. The tooltip tracks `store.menuToolTip`.
- [ ] Menu:
  - Left click opens it (no popover yet); right click opens it too.
  - Items: today's tokens (and cost when `store.showsCost`), separator, "Refresh", "Launch at login" (Task 10 fills its state; `unavailable` until then), "Open log folder" (`ShellExecuteW` on `PlatformCompat.logsDirectory()`), "Update available…" when set (Task 10), separator, "Quit".
  - On open: `store.requestNotificationAuthorizationIfNeeded()` and `Task { await updater?.check() }`, as the Mac does on popover open.
- [ ] `TaskbarCreated` → `add()` again. `WM_APP_SHOW` from a second instance → balloon "Already running". First run (defaults key `windows.trayHintShown`) → balloon with the overflow hint.
- [ ] Tests:
  - `testMenuShowsTodayTokensAndCostOnlyWhenShown`, `testLoginItemStatesMapToChecksAndTitles`, `testUpdateItemAppearsOnlyWithAnUpdate` (both);
  - `testPNGDecodesToTheRightSizeAndAlpha` (Windows; fixture PNG with known corner pixels);
  - `testIconMakesAnHICON` (Windows);
  - selftest `tray.add`, `tray.modify`, `tray.remove`.
- [ ] **PR `feat(windows): show the companion and today's usage in the tray`**, merge. `UI changes`: the CI renders the tray icon PNG at 16/24/32 px and a menu screenshot taken on the runner (guess: the runner has a desktop; if not, a labelled drawing of the menu).

**Verify:** Windows run green and selftest `tray.*` pass (or recorded as `no shell tray on runner`). Mac `swift test --filter TrayMenuModel`. **Size:** M. **PC:** checked in Task 13.

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
- [ ] Implement:
  - Registrations in `WindowsPlatform.live`: `RegisterSuspendResumeNotification(hwnd, DEVICE_NOTIFY_WINDOW_HANDLE)` and `RegisterPowerSettingNotification(hwnd, &GUID_CONSOLE_DISPLAY_STATE, …)`; `WM_TIMECHANGE` on the sink.
  - Connectivity: `NotifyNetworkConnectivityHintChange(…, initialNotification: true)`; the callback hops with `DispatchQueue.main.async`.
  - Selftest: `events.registered`, `reachability.initialCallback` (≤ 5 s), `idle.value`, `platform.liveBeforeStores`.
- [ ] Fault-inject: swap the suspend and resume branches → the Windows test fails. Drop the cooldown → the shared test fails.
- [ ] `swift test --filter "DayBoundary|ReachabilityTransition|ReachabilityParity|PlatformTests"`, then `shared-check.sh`, then `test-gate.sh` (`Platform.swift` changed). Push → Windows green.
- [ ] **PR `feat(windows): wake, sleep, display, day change, idle and network events`**, merge. Tell the Track A session that `Platform.swift` was edited once and new protocols go in new files.

**Verify:** as above. **Size:** M. **PC:** Task 13 (sleep, display off, Wi-Fi).

---

### Task 8: Notifications as tray balloons

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
  - `testPostCallsShellNotifyIconWithInfo` (Windows: return value recorded; `NIIF_NOSOUND` when `sound == false`; `NIIF_RESPECT_QUIET_TIME` always).
- [ ] Implement. Selftest `notify.post` posts "PokeTokenBar self-test" (the PC check confirms it appears).
- [ ] **PR `feat(windows): post notifications through the tray`**, merge.

**Verify:** Windows green; Mac `swift test --filter BalloonQueue`. **Size:** M. **PC:** Task 13 (it is shown in Notification Center; Focus Assist behaviour).

---

### Task 9: Claude limits from the credentials file; the secret store

**Files:**
- Create: `Platform/FileCredentialLimitsProvider.swift` (shared, team-owned), `Platform/Windows/WindowsLimitsProviders.swift`, `Platform/Windows/WindowsSecrets.swift`
- Modify: `WindowsApp.swift` (set `WindowsPlatform.limitsFactory` before the stores); `Tests/PokeTokenBarTests/LiveCredentialCallGateTests.swift` (the scan also covers `Platform/*LimitsProvider.swift`; Mac-only test)
- Test: `FileCredentialLimitsProviderTests.swift` (both; `URLProtocol` stub + `AppEnv.allowLiveFetchForTesting` reset in `defer`), `OAuthRequestDriftScanTests.swift` (both: text scan), `WindowsSecretsTests.swift` (Windows)

**Interfaces:**
- Produces:
  ```swift
  struct FileCredentialLimitsProvider: ClaudeLimitsProviding, Sendable {
      static let usageURL: URL                                         // == the URL literal in Core/OAuthLimitsProvider.swift
      static let betaHeader: (name: String, value: String)             // == "anthropic-beta" / "oauth-2025-04-20"
      init(credentialsFileURL: URL, session: URLSession = .shared)
      func fetch(allowKeychainPrompt: Bool) async throws -> LimitStatus
  }
  struct WindowsLimitsProviders: LimitsProviderFactory {
      func claudeOAuth(configRoot: URL?) -> any ClaudeLimitsProviding  // file = ClaudeAccountRoots.credentialsFileURL(for:) or ~/.claude/.credentials.json
      func antigravity() -> any AntigravityLimitsProviding             // UnavailableAntigravityLimits (location unknown)
  }
  struct WindowsSecrets: SecretStoring {
      static func targetName(service: String, account: String?) -> String   // "service" or "service/account"
      func read(service: String, account: String?) -> Result<Data, SecretError>
  }
  ```
  `fetch` behaviour:
  - Read the file with `OAuthCredentialData.credential(from:)`. Missing or unreadable → `LimitsError.keychainAccessDisabled` (the stub's error, so the store hides limits as today). Account OAuth missing → `.credentialMissingAccountOAuth`.
  - `guard AppEnv.allowsLiveLimitsFetch`, then GET with `Bearer` + beta header.
  - 429 → `.rateLimited(retryAfter: LimitsHTTP.retryAfterSeconds(http))`. 401/403 → re-read the file once; same token → rethrow `.httpStatus`.
  - Decode `LimitStatus`; set `subscriptionType`/`rateLimitTier` from the credential.
  - No account-identity labelling in stage 4 (the popover is stage 7; noted in the PR).

**Steps:**
- [ ] Failing tests:
  - `testReadsTheTokenFromTheFileAndSendsTheHeaders`, `testMissingFileHidesLimits`, `testAccountOAuthMissingAsksForRelogin`, `test401RereadsTheFileOnce`, `test429CarriesRetryAfter`, `testGateClosedUnderSwiftTestWithoutTheTestingFlag` (both);
  - `testUsageURLAndBetaHeaderMatchTheUpstreamProvider`: reads `Core/OAuthLimitsProvider.swift` as text and finds both literals. Fault-inject by changing one literal → fails;
  - Windows: `testCredentialRoundTrip` (`CredWriteW` / read / `CredDeleteW` with a UUID target), `testMissingCredentialIsNotFound`.
- [ ] Implement. Selftest `limits.claude`: with a fixture credentials file and the gate closed (not packaged) → `.liveFetchNotPermitted` reached, which proves the file was read up to the network boundary. In the installed run the gate is open, so the fixture token gets 401 → recorded, not failed.
- [ ] `swift test --filter "FileCredentialLimits|OAuthRequestDrift|LiveCredentialCallGate"`, then `shared-check.sh`, then `test-gate.sh`. Windows green.
- [ ] **PR `feat(windows): read Claude limits from the credentials file`**, merge.

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
  enum PlatformShell { @MainActor static var current: any PlatformShellService }   // Mac: MacShell; Windows/shared-only: WindowsShell / a logging stub
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
  Windows builds `UpdateChecker(currentVersion: WindowsInstall.version ?? "0.0.0", fetchLatest: { await InstallerReleaseFeed.latest() })`. The feed returns nil until releases carry the installer (stage 8), so Windows never offers a Mac-only release. `applyUpdate` on Windows reaches its existing non-brew branch (no `brew` on `Path`) and opens the release page.

**Steps:**
- [ ] Failing tests:
  - existing `UpdateCheckerTests` now run on both;
  - `testFeedIgnoresAReleaseWithoutTheWindowsInstaller`, `testFeedTakesTheReleasePageURL` (both);
  - `testApplyOpensTheReleasePageWhenBrewIsMissing` (both, with a recording `PlatformShellService`);
  - Windows: `testEnableWritesTheQuotedCommand`, `testDisableRemovesOnlyOurValue`, `testDisabledInTaskManagerIsReported`. These use test-only keys `Software\PokeTokenBarTests\<uuid>\…`, deleted in `tearDown`.
- [ ] Mac pin: `testMacShellCallsAppKitAsBefore` is not testable without terminating the app. Instead, `MacShell`'s two lines are copied verbatim, and the Mac `UpdateCheckerTests` run unchanged through `test-gate.sh`. State this in the PR.
- [ ] Wire into the tray menu: the "Launch at login" check state and toggle; "Update available vX" opens the page.
- [ ] `swift test --filter "UpdateChecker|InstallerReleaseFeed"`, then `shared-check.sh`, then `test-gate.sh`. Windows green.
- [ ] **PR `feat(windows): launch at login and check for updates`**, merge. The body lists the upstream lines.

**Verify:** as above. **Size:** M. **PC:** Task 13 (sign out/in, Task Manager toggle).

---

### Task 11: Crash logging

**Files:**
- Create: `Platform/Windows/WindowsCrashLog.swift`, `Sources/CWinShim/crash.c`
- Modify: `WindowsApp.swift` (install first after single instance; `markClean` in `quit`), `windows-app.yml` (crash then relaunch)
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
  // C (async-signal-style: preformatted buffers, WriteFile on a pre-opened HANDLE)
  int  ptb_crash_install(const wchar_t *crash_log_path, const wchar_t *dump_dir);
  int  ptb_crash_redirect_stderr(const wchar_t *path);   // Swift runtime "Fatal error: …" lines land here
  ```
  Semantics mirror `CrashReporter`:
  - On install, drain the previous `crash.log` into `AppLog`.
  - Marker present → log "previous session did not end cleanly"; write the marker.
  - `markClean` removes it and calls `AppLog.writeAndFlush("clean shutdown")`.
  - The filter writes `[CRASH] exception 0x%08X at 0x%p`, writes a `MiniDumpNormal` dump, and returns `EXCEPTION_CONTINUE_SEARCH`.
  - `stderr.log` is cut to 256 KB at launch.

**Steps:**
- [ ] Failing tests (temp logs dir, injected `log`):
  - `testFirstInstallWritesTheMarkerOnly`, `testMarkerLeftBehindIsReportedOnce`, `testMarkCleanRemovesTheMarker`, `testCrashLogIsDrainedThenRemoved`, `testOnlyThreeDumpsAreKept`.
- [ ] CI step: the installed (or bundle) exe runs `--selftest-crash` (calls `fatalError("selftest crash")`). Then `--selftest` asserts `crash.previous` (marker reported), `crash.dump` (a `.dmp` exists), `crash.stderr` (`stderr.log` contains `selftest crash`).
- [ ] **PR `feat(windows): leave a trace when the app crashes`**, merge.

**Verify:** Windows run green with all three `crash.*` checks. **Size:** M. **PC:** no.

---

### Task 12: Packaging, installer, installed selftest, idle gate

**Files:**
- Create: `installer/PokeTokenBar.iss`, `scripts/windows/measure-idle.ps1`, `scripts/generate-ico.py`, `assets/AppIcon.ico`, `Sources/PokeTokenBarWin/PokeTokenBar.rc`, `Sources/PokeTokenBarWin/app.manifest`, `windows/licenses/{map.txt, *.txt}`
- Modify: `scripts/windows/package.ps1` (dumpbin closure, VC redist, licences, rename to `PokeTokenBar.exe`, version stamp), `windows-app.yml`, `CONTRIBUTING.md` (Windows build: vcpkg, `PTB_OPENSSL_DIR`, artifacts)

**Interfaces:**
- Produces:
  - `package.ps1 -Version <x.y.z> -Res <path.res> -Out <dir>` → `bundle\` with `PokeTokenBar.exe`, the DLL closure, `PokeTokenBar.version`, `licenses\`. Exit 1 on a closure DLL with no source or no licence mapping.
  - `ISCC /DSrcDir=bundle /DAppVer=<x.y.z> /DOutDir=out installer\PokeTokenBar.iss` → `out\PokeTokenBar-Setup-<x.y.z>-win-x64.exe`.
  - `measure-idle.ps1 -Name PokeTokenBar -Seconds 180 -Also explorer` → JSON `{cpuSeconds, explorerCpuSeconds, handlesStart, handlesEnd, privateMBEnd}`.

**Steps:**
- [ ] `.rc`: `VERSIONINFO` (`FileVersion`/`ProductVersion` x.y.z.0, `FileDescription "PokeTokenBar"`, which Windows shows as the notification source), `1 ICON`, `1 RT_MANIFEST`. CI: `rc.exe /nologo /fo PokeTokenBar.res Sources\PokeTokenBarWin\PokeTokenBar.rc`, then `swift build -c release --product PokeTokenBarWin -Xlinker <abs>\PokeTokenBar.res`.
- [ ] The workflow, in order:
  1. build;
  2. package;
  3. stripped-`Path` bundle selftest;
  4. `iscc` (`choco install innosetup` when `iscc` is missing);
  5. silent install `/VERYSILENT /SUPPRESSMSGBOXES /CURRENTUSER /NORESTART /LOG=install.log`;
  6. assert the app dir, the Start-menu `.lnk` (its AUMID via PowerShell `Shell.Application`, guess) and the HKCU Uninstall key;
  7. installed `--selftest` (now `isBundledApp`: `log.writes`, `defaults.persist` and `limits.claude` run in bundled mode);
  8. crash then relaunch (Task 11);
  9. idle: start the installed app with fixture data, wait 30 s, `measure-idle.ps1 -Seconds 180`, assert the D8 budgets, quit;
  10. silent uninstall; assert the app dir and Run value are gone and `%LOCALAPPDATA%\PokeTokenBar` is kept;
  11. upload `PokeTokenBar-Setup-*.exe`, `st-*.json`, `idle.json`, logs.
- [ ] Record the installer size and the bundle size in the PR (expected tens of MB because of ICU; guess).
- [ ] **PR `build(windows): build a per-user installer in CI`**, merge.

**Verify:** `gh run watch … --exit-status` → 0; `gh run download … -n windows-installer` → the `.exe` exists; `idle.json` is under budget. **Size:** L. **PC:** Task 13.

---

### Task 13: Stage 4 check on the user's PC; docs

**Files:**
- Modify: spec §9.1 (stage 4 row), §10 step 4 (done + deviations), §13; `docs/reference/defect-log.md`; `CONTRIBUTING.md`

**Steps:**
- [ ] The session lead sends the user the installer artifact link and this checklist (Korean wording is the lead's):
  1. `winver` build and account type (standard/admin).
  2. SmartScreen on the installer: did "Windows protected your PC" appear, and did More info → Run anyway work without an admin prompt?
  3. Install: no UAC; `%LOCALAPPDATA%\Programs\PokeTokenBar`; a Start-menu entry; listed in Apps.
  4. After install the app runs. Tray icon present (maybe in the ^ overflow); first-run hint balloon seen; drag the icon onto the taskbar.
  5. Tooltip and menu show today's tokens. Compare with Claude Code usage on that PC if it is used.
  6. Menu: Refresh, Open log folder (Explorer opens and `PokeTokenBar.log` has lines), Quit (the icon disappears).
  7. Launch at login: on → sign out/in → running. Task Manager → Startup apps shows it. Disable it there → the menu says "disabled in Task Manager".
  8. Start-menu relaunch while running: no second icon; the "already running" balloon appears.
  9. Quit, then run `PokeTokenBar.exe --selftest --selftest-out %TEMP%\st.json` from PowerShell: the "self-test" notification shows (also in Notification Center); send back `st.json`.
  10. Sleep 1 min, wake: the log has a wake refresh line. Display off 2 min: a "polling paused" line.
  11. With Claude Code logged in: the tooltip and log show 5-hour/weekly limits.
  12. Shut down the PC with the app running → next launch: no "did not end cleanly" line.
  13. Install a newer CI build over it: the app closes and relaunches; companion progress and `team.memberID` are unchanged (log line).
  14. Uninstall: app and Run value gone; `%LOCALAPPDATA%\PokeTokenBar` kept.
  15. Defender: right-click the installer → Scan → result.
  16. `scripts/windows/measure-idle.ps1 -Seconds 600 -Also explorer` with the app idle → send back the JSON.
- [ ] Record the answers in spec §9.1. Every failure goes through the defect protocol in its own fix PR before Task 20.
- [ ] **PR `docs: record the Windows app check`**, merge.

**Size:** S. **PC:** **yes**.

---

### Task 14: Shared transport rules (Mac refactor, behaviour identical) — review with the most capable model

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
  `BonjourTeamTransport` keeps `static let serviceType`, `maxUnfinishedInbound`, `maxUnfinishedOutbound`, `maxLinks`, `receiveBurst`, `receivePerSecond`, `frameCost` as aliases of the rules (tests and `team-probe` keep compiling). It uses `TeamLinkReceiver` in `receive`. Log lines stay byte-identical.

**Steps:**
- [ ] Failing tests:
  - `testInstanceNameShape`, `testInboundAdmissionAtEachCap`, `testDialRoomNeverNegative`;
  - `testReceiverDeliversInOrder`, `testReceiverReportsABadFrameBeforeSpending`, `testReceiverDropsATinyFrameFlood`, `testReceiverLetsAFullSyncThrough` (the byte and frame counts of `testASyncAndARunAreNotDropped`).
- [ ] Refactor. The existing 20 `TeamTransportTests` + `TeamSessionLoopbackTests` pass unchanged.
- [ ] Fault-inject: swap decode and budget order in `TeamLinkReceiver` → `testReceiverReportsABadFrameBeforeSpending` fails. Revert.
- [ ] `swift test --filter "TeamTransport|TeamSessionLoopback|TeamTransportRules"`, then `test-gate.sh`. Windows green (the rules file is shared).
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
- [ ] `swift test --filter "TeamTransport|TeamSessionLoopback"`, then `test-gate.sh`. Windows green (the contract compiles there; no Windows wrapper yet).
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
      init(deliver: @escaping @MainActor ([WinSocketEvent]) -> Void)              // batched, in order, on the main queue
      func start(); func shutdown()                                               // shutdown joins the thread
      func listen(code: TeamCode)                                                 // dual-stack [::]:0
      func stopListening()
      func dial(_ addresses: [WinSocketAddress], code: TeamCode) -> WinConnID     // tries in order; TLS client
      func receiveNext(_ id: WinConnID)
      func send(_ data: Data, on id: WinConnID)
      func close(_ id: WinConnID); func closeAll()                                // silent
  }
  ```
  Internals: one `Thread`; `WSAPoll(INFINITE)`; a loopback UDP pair for wakeups; a command queue under `NSLock`; per-connection `{socket, session, state, outbox, readArmed}`. The mailbox flushes with one `DispatchQueue.main.async` per empty → non-empty transition.

**Steps:**
- [ ] Failing tests:
  - `testDialAndAcceptReachReadyAndExchangeData`;
  - `testEventsArriveInOrderUnderLoad` (10,000 sends);
  - `testCloseIsSilent`;
  - `testReadingPausesUntilReceiveNext` (the sender writes 1 MB; only one `.data` chunk arrives before `receiveNext`);
  - `testPlainTCPStaysAcceptedNeverReady`;
  - `testRefusedDialReportsUnreachable`;
  - `testDifferentCodeClosesWithHandshakeFailed`;
  - `testIdleLoopUsesNoCPU` (5 s idle, `GetProcessTimes` Δ < 20 ms);
  - `testShutdownJoinsTheThread`.
- [ ] Review checkpoint (in the PR): no `WSAPoll` timeout other than `INFINITE`; no `SSL*` touched off the loop thread; `ptb_tls_pending` drained before re-polling.
- [ ] Push → Windows green.
- [ ] **PR `feat(windows): a socket loop for team links`**, merge.

**Verify:** Windows run green. **Size:** L. **PC:** no.

---

### Task 18: DNS-SD wrapper

**Files:**
- Create: `Platform/Windows/Team/WinDNSSD.swift` (+ `Sources/CWinShim/dnssd.c` only if Task 1 P12 showed `windns.h` doesn't import)
- Test: `WindowsDNSSDTests.swift` (Windows), `DNSSDNameTests.swift` (both, pure)

**Interfaces:**
- Produces:
  ```swift
  enum DNSSDName {                                                       // shared, pure
      static func instanceLabel(fromPTR name: String, serviceType: String = TeamTransportRules.serviceType) -> String?   // "ptb-ab12….​_ptbteam._tcp.local" → "ptb-ab12…"
      static func fullName(instance: String, serviceType: String = TeamTransportRules.serviceType) -> String
  }
  final class WinDNSSD: @unchecked Sendable {
      enum Event: Sendable, Equatable { case registered(String), registerFailed(Int32), found(String), lost(String), browseFailed(Int32) }
      init(deliver: @escaping @MainActor (Event) -> Void)                // via DispatchQueue.main.async
      func register(instance: String, port: UInt16); func deregister()
      func browse(); func stopBrowsing()
      func resolve(instance: String, _ done: @escaping @MainActor ([WinSocketAddress]) -> Void)   // IPv4 first; [] on failure
  }
  ```
  Host for registration: `GetComputerNameExW(ComputerNameDnsHostname) + ".local"`. PTR TTL 0 → `.lost`.

**Steps:**
- [ ] Failing tests:
  - `testInstanceLabelParsing` (with and without a trailing dot, foreign service, uppercase) (both);
  - Windows: `testRegisterThenBrowseFindsOurOwnInstance` (runner loopback, ≤ 10 s), `testResolveReturnsTheListenerPort`, `testDeregisterThenBrowseNoLongerFinds` (records whether a `.lost` arrives: answers F13 on the runner), `testStopBrowsingStopsEvents`.
- [ ] Push → Windows green. If the runner's mDNS is flaky, the integration tests move into the selftest and are listed in the PR.
- [ ] **PR `feat(windows): find teammates with the built-in DNS-SD`**, merge.

**Verify:** Windows run green. **Size:** M. **PC:** no.

---

### Task 19: The Windows team transport, app wiring and probe mode **[most capable]**

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
  - Redial: a `Timer` on `RunLoop.main`, 15 s, tolerance 3 s.

  App: `TeamRuntime(settings:companion:transport: WindowsTeamTransport(events:reachability:))`. `teamRuntime.notifier = TeamNotifier(settings:poster: WindowsTeamNotificationPoster(…), isPlazaFrontmost: { false }, showInPlaza: { _ in })`. `teamRuntime.start()`. A balloon click of kind `.team` does nothing until stage 6 opens the plaza. The tray menu shows "Teammates online: N" when `teamSettings.isReady`.

  Probe: `PokeTokenBar.exe --team-probe <code> [--host h --port p] [--seconds 60] --selftest-out <file>` logs FOUND, DIAL, READY, MSG(kind) and CLOSED(reason) lines.

**Steps:**
- [ ] `WindowsTransportContractTests` wraps all 26 scenarios through a Windows harness (raw TLS via `WinTLSSession` on a blocking socket; plain TCP and silent sink via Winsock).
- [ ] Make the contract pass on Windows CI. Selftest `team.discoverAndExchange`: two in-process transports with `advertise: true` and the same code find each other by DNS-SD, connect once (duplicate resolved by `TeamSession` when run through two `TeamRuntime`s with separate `TeamSettings` suites), and exchange a presence.
- [ ] `scripts/team-interop-check.sh` (Mac, read-only, no app activation): runs `openssl s_server` / `s_client` with the PSK of a given code against `swift scripts/team-probe.swift`. It re-proves on demand that Network.framework and the OpenSSL flags in `CTeamTLS` agree (spike experiment 2). Run once; paste the output into the PR.
- [ ] Fault-inject on Windows: deliver more than one `.data` chunk per `receiveNext` → `aSyncAndARunAreNotDropped` or `aLinkPouringInTinyFramesIsDropped` changes outcome; drop the self-filter → the discovery selftest sees itself. Revert.
- [ ] `swift test --filter TeamTransportContractScan` on the Mac, then `test-gate.sh` (shared test and menu model changed). Windows green.
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
  4. The Mac teammate sends a heart, a reaction and news → the Windows notification appears. The Windows companion hatches or levels → the Mac feed shows it.
  5. Quit the Windows app → the Mac roster drops it within the heartbeat timeout. Relaunch → back.
  6. Sleep the PC 2 min → the Mac sees the disconnect; wake → back within about 30 s. Wi-Fi off/on → back.
  7. If step 2 shows Block: does the link still form (the Windows side dials)? Note the Mac log's refused dials.
  8. `ipconfig` adapters (WSL, Hyper-V, VPN present?) and whether connecting was slow.
  9. On any failure: `PokeTokenBar.exe --team-probe <code> --seconds 60 --selftest-out %TEMP%\probe.json` → send back.
  10. 10 min `measure-idle.ps1` with three or more teammates connected → send back.
  11. Optional: a second Windows PC on the same team.
- [ ] Record the answers. Each failure goes through the defect protocol. The DNS-SD removal behaviour (F13) gets a decision: rely on dial cooldowns, or add a browse restart on a long timer (that is a cost; ask first).
- [ ] **PR `docs: record the Windows team check`**, merge. Report to the user in Korean: what works on Windows now, what stage 6 needs.

**Size:** S. **PC:** **yes**.

## Order

- **Start now, in parallel with Track A** (no shared files with `Team/Plaza/**` or `Team/UI/**`):
  - Task 1 (spike branch, CI only);
  - Task 2 (Windows manifest branch + CI);
  - Tasks 3 and 4 (upstream `Core` lines + `PlatformCompat`);
  - Tasks 14 and 15 (transport rules and contract on the Mac).

  The Mac allows one build or test at a time, so the tasks needing a Mac gate (3, 4, 14, 15) run one after another. CI-only work (1, 2) overlaps them.
- **Stage 4:**
  - 5 needs 1, 2 and 3. Then 6.
  - 7, 9, 10 and 11 need 5 (each adds files plus one wiring block in `WindowsApp.swift`; merge one at a time and rebase). 8 needs 6.
  - 12 needs 6, and is re-run green after 7–11.
  - 13 (the PC check) needs 7–12.
- **Stage 5:**
  - 16 needs 2. 17 needs 16 and 1. 18 needs 2 and 1. These can run during stage 4.
  - 19 needs 5, 7, 8, 14, 15, 17 and 18.
  - 20 needs 19 and 13.
- Critical path: 1 → 5 → 6 → 8 → 19 → 20, with 16 → 17 alongside.
- Tell the peer (Track A) session at three points:
  - after Task 2 merges: Windows-only targets and the composite action;
  - after Task 7 merges: the single `Platform.swift` edit, and new protocols in new files;
  - after Task 15 merges: transport tests are now a contract (only matters if Track A touches `TeamTransportTests`).

## Open questions for the session lead

1. **Tray icon static in stage 4** (no measurable cost; every animated frame is an explorer.exe redraw we can't measure on CI). The alternative: animate at the Mac's frame floor now and measure on the PC. My call is static now, animation as a follow-up after the PC idle numbers. Is that acceptable to the user?
2. **Launch at login default:** off, toggled from the tray (Mac parity), or an installer task ticked by default?
3. **Secret store (Credential Manager)** has no caller on Windows today (F8). Build it in Task 9 (small), or drop it until a caller exists (`CLAUDE.md`: nothing speculative)?
4. **Claude limits:** the plan duplicates about 40 lines of the OAuth usage call in a team-owned shared file, guarded by a drift scan. The alternative is splitting the Keychain half out of upstream `OAuthLimitsProvider.swift` (no duplication, larger upstream diff, conflicts on every upstream Keychain fix). Which?
5. **Notifications as balloons** (no AppUserModelID or shortcut needed; one at a time; clicks only while running), or WinRT toasts now (C++ shim, the shortcut AUMID the installer already sets, a COM activator for clicks when closed)?
6. **Windows update apply:** stage 4 only opens the release page, and only for releases that carry a Windows installer, which happens from stage 8. Download-and-run waits for stage 8. Agreed?
7. **Antivirus:** may CI or the user upload builds to VirusTotal? That shares the binary with a third party. Otherwise only a Defender scan on the PC.
8. **CI minutes:** `windows-app.yml` runs on `windows-port` pushes and on path-filtered PRs (about 15 min per run with installer and idle sampling; Windows minutes cost double). Run it on every PR instead, or only on push?
9. **Exe name:** the build product is `PokeTokenBarWin`, renamed to `PokeTokenBar.exe` when packaged (avoids a target/product name clash; the process name decides the settings file name). Fine?
10. **Facts still to settle on the PC** (not questions for the user now): the firewall rule's action from a standard account, the office Wi-Fi's network profile, and whether the user's PC uses Modern Standby.

Sources used for the run-loop and toast research (context only; the decisions rest on the source files in "Facts"): [Combining Windows message loop with Swift's run loop](https://forums.swift.org/t/combining-windows-message-loop-with-swifts-run-loop/64054), [MainActor does not execute when a Swift DLL is called from .NET on Windows](https://forums.swift.org/t/swift-concurrency-mainactor-does-not-execute-when-swift-dll-is-called-from-net-on-windows/88469), [Pitch 3: Custom Main and Global Executors](https://forums.swift.org/t/pitch-3-custom-main-and-global-executors/80638), [Proper Windows notifications on Electron (AUMID + Start-menu shortcut)](https://dev.to/randomengy/proper-windows-notifications-on-electron-38jo), [Send a local toast notification from a WRL C++ desktop app](https://learn.microsoft.com/en-us/windows/apps/design/shell/tiles-and-notifications/send-local-toast-desktop-cpp-wrl).
