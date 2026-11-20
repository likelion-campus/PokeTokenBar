# Windows Port, Stage 7 (The Windows Popover) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Windows teammate clicks the tray icon and gets the app's main surface: today's usage and limits, the companion with its growth and celebrations, every setting the Mac has that means something on Windows, and the team setup (create, join with a code, nickname, schedule) without the command line. Later in the stage come the activity chart, the recap, session keys, backup and transfer, and dark mode; the shop, bag, Pokédex and floating pet are listed with estimates for the user to schedule. The popover costs nothing while closed and nothing while it is open and nothing on it changes. The Mac does not change.

**Architecture:** The popover is the one surface kept as two copies (spec §8). The Mac keeps its SwiftUI popover untouched. Windows gets a native one with the same functions:
- **Logic stays shared.** What the Mac views compute inline (which limit rows show, their texts, colours and markers; what the companion header says; what each setting does) is rebuilt in shared, test-covered *view models* under a new fork-owned directory `Sources/PokeTokenBar/Popover/`. Pure helpers trapped in Mac-only `UI/` files get shared *twins*, proven equal to the originals by Mac tests and held equal by a source scan.
- **Presentation is Windows-only** (`Sources/PokeTokenBar/Platform/Windows/Popover/`, `#if os(Windows)`). One `WS_POPUP` tool window, anchored to the tray icon, light-dismissed. Every interactive control is a Win32 common control (comctl32 v6: buttons, check boxes, combo boxes, edits, trackbars, up-downs, a tab control, tooltips). Keyboard navigation, IME, password masking, high contrast and Narrator come with them.
- **Drawn parts** (sprites, badges, limit bars, charts, the recap card, celebrations) are shared *parts* that render a `PlazaPanelDrawing` through the stage 6 canvas and DirectWrite engine. A Windows host shows them with `AlphaBlend` and turns their accessibility items into real child controls.
- **A parity scan** fails when the Mac popover gains a string, a store member, a setting key, a view section or a changed twin that the Windows copy does not account for.

**Tech Stack:** Swift 6.3.2 on `windows-latest` (VS 2026), SwiftPM, XCTest, `WinSDK` (user32, comctl32 v6, uxtheme, dwmapi, shell32; crypt32 and `TaskDialogIndirect` through `WinDynamic`), the stage 6 `CPlazaD2D` canvas and text (CPU WIC target, DirectWrite, bundled fonts), `CWinShim` (gains a COM file dialog), Segoe UI Variable / Segoe UI and Segoe Fluent Icons / Segoe MDL2 Assets (Windows' own fonts). Nothing new ships on the Mac.

**Spec:** `docs/superpowers/specs/2026-11-13-windows-port-design.md` (Korean): §1 and §2 (G6, the failure conditions incl. idle), §5 (fonts, emoji), §7 (secret store row), §8 (popover: two copies, native controls, drawn parts only where controls cannot, the parity check), §10 step 7, §11, §13. Host rules: `docs/superpowers/plans/2026-11-14-windows-port-track-b-windows-app.md` D2 ("How stages 6 and 7 host their windows"), D3 (Claude limits row: "Wording is stage 7's job"), D5 (manifest: comctl32 v6 "for stage 7"), D8 (idle). Stage 6 contract: `docs/superpowers/plans/2026-11-15-windows-port-stage6-plaza-renderer.md` D9 (canvas), D10 (text), D11 (codecs), D12 (sprites), D15 (symbols), D16 (STA). Ledgers: `.superpowers/sdd/2026-11-14-windows-port-track-b-windows-app/progress.md` (+ `pc-defects-1-report.md`, `status-burst-report.md`, task 5/6/9/10/12/19 reports) and `.superpowers/sdd/2026-11-15-windows-port-stage6-plaza-renderer/progress.md`.

**Base:** `windows-port` at `2a03608`. Stage 6 Tasks 1–5, 8 and 9 are merged; Tasks 6, 7 and 10–17 are not. Stage 7 needs from stage 6 only what is merged (canvas, text engine, codecs, sprite fetcher, `PlazaPanelDrawing`). Stage 6 Task 11 (`WM_IME_CHAR` re-dispatch) is *not* a prerequisite: popover text goes through `IsDialogMessageW` (D5). The two stages run side by side; collisions are listed under Order.

---

## Facts this plan rests on (read in source at `2a03608`)

| # | Fact | Where | Consequence |
|---|---|---|---|
| P1 | The Mac popover is 360 pt wide (`PopoverMetrics`). Under an optional update banner come a segmented tab bar (Home, Shop, Bag, Collection) and an open-plaza button. Content is fixed at 520 pt (Home scrolls; Shop, Bag and Collection scroll inside). Settings and Recap replace the content in place, never as a sheet ("orphaned sheet blocks clicks"). Settings is 460 pt tall. | `UI/PopoverView.swift` 4–207; `UI/SettingsView.swift` 66–114 | Windows keeps the same sizes in DIP and the same in-place page swaps: one window, never a second one for Settings. |
| P2 | Opening resets navigation to Home but keeps the provider and Claude-account tabs. The hosting tree is built on open and freed on close (idle). Opening also calls `requestNotificationAuthorizationIfNeeded()` and `updater.check()` (30-minute cooldown). A click on the status item toggles. Right click or Control-click opens `StatusItemMenu`. | `PokeTokenBarApp.swift` 684–770; `PopoverNavigation.reset` | Windows creates the window on open and destroys it on close. It resets the same state, makes the same two calls and toggles on the icon. |
| P3 | The Mac needs `OutsideClickMonitor` (a global mouse monitor while open) because other menu bar popups do not deactivate the app. | `PokeTokenBarApp.swift` 772–786; `OutsideClickMonitor.swift` | On Windows another tray flyout, the taskbar, Start or any window takes activation, so `WM_ACTIVATE(WA_INACTIVE)` is enough. No global hook, so no idle cost (D3). |
| P4 | The Mac popover files reference **376 distinct `L` strings** and about **249 distinct store, navigation, team and updater members**. | grep over `UI/*.swift` + `Team/UI/TeamSettingsSection.swift` | Too many to keep in step by hand: the parity scan (D9) is a machine check. |
| P5 | Pure logic is trapped in Mac-only `UI/` files: `PopoverNavigation`; `DailyTrendMetrics`, `DailyTrendHover`, `DailyTrendColumn`, `WrappingHStack`; `ActivityHeatmapMetrics` (except its colours); `LimitProgressBar.markerFraction`; `StreakBadge.isShown`; `MonthDailyTrend.readout`/`shouldShowSurface`; `CompanionHeader.progressDetail` and its `statusLine` switch; the `EvoLineView` statics; `SpriteView.frameTaskID`/`needsReload`/`framesToApply`; `SpriteSubject` (on `NSImage`); `DexScrollPager` (on `NSEvent.Phase`); `PokemonDetailView.formPickerColumns`; `DifficultyDraft`; `RecapContent`; `SettingsView.exportedAtText`. Private view logic too: `selectedProviderHasLimits`, `limitPercentText`, `resetClockSuffix`, `paceHelp`, `grokProductName`, `statusColor`, `PaceTier.color`/`percentColor`, `rarityColor`, `PokemonType.hex`, the trend palette and the heatmap greens. | the files named | Upstream-owned files may only get one-line call sites, so these cannot be moved out. They get shared twins with Mac equivalence tests and a text-drift scan (D8). |
| P6 | `TeamSettingsSection` is fork-owned (`Team/UI/`), and its rules are static functions: `join(_:into:)`, `committedDraft(_:into:)`, and `masked` (private). The team UI is Korean only (`L(.ko)`). | `Team/UI/TeamSettingsSection.swift` | These rules **move** to shared `Team/TeamSetup.swift`; the Mac view calls them, with the same behaviour. Windows shows the team section in Korean whatever the app language is, as the Mac does. |
| P7 | The claude.ai session key is **not** in the Keychain on the Mac. It is a plaintext JSON file (`session-key.json`, per-account `session-key-<hash>.json`) written owner-only (0600) in the app state folder, by shared `Core/SessionKeyLimitsProvider.swift` (`SessionKeyStore`). The settings note says "stored … as an owner-only file (not encrypted)". | `Core/SessionKeyLimitsProvider.swift` 60–125; `Localization.swift` 564 | Session keys already work on Windows through shared code (`%LOCALAPPDATA%\PokeTokenBar`). Only the UI is missing. Whether to encrypt them with DPAPI is D14. |
| P8 | Foundation on Windows: `Locale.current` is always `en_001` and `Calendar.current.firstWeekday` is always 2. `RelativeDateTimeFormatter` is missing (`CompanionTests+Mac` is parked for it). The time zone is published from the OS (PC defects 1). | `pc-defects-1-report.md`; `Tests/PokeTokenBarTests/mac-only.txt` | Number grouping (`TokenFormatter.grouped`), the heatmap's and the recap's first weekday, and relative-time texts need Windows sources (D11). |
| P9 | `WinMessageHook` already sends messages for registered windows and their children through `IsDialogMessageW` (`registerDialogWindow`, never exercised). Otherwise it re-dispatches `WM_CHAR` in Unicode. | `Platform/Windows/WinMessageHook.swift` 26–52 | Tab order, Enter/Escape and Unicode text in the popover's edits come from this path (D5). There is no unregister yet (Task 3 adds it). |
| P10 | The tray uses `NOTIFYICON_VERSION_4`. Today `NIN_SELECT`, `NIN_KEYSELECT`, `WM_LBUTTONUP` and `WM_CONTEXTMENU` all open the menu. `anchorRect()` wraps `Shell_NotifyIconGetRect`. `WinPopupMenu` calls `SetForegroundWindow` and wraps the menu loop in `WinModalPump`. | `Platform/Windows/WinTray.swift`, `WinTrayHost.swift` | Left click and keyboard select open the popover; right click opens the menu (D2, open question 2). The v4 `wParam` gives the click point when the rect is unavailable (overflow, D2). |
| P11 | The app manifest already asks for comctl32 v6 and PerMonitorV2. `comctl32` is linked (stage 6 Task 2). The main thread is STA (stage 6 D16). | `Sources/PokeTokenBarWin/app.manifest`; `Package.swift` Windows branch | Common controls v6, `TaskDialogIndirect` and COM file dialogs work without manifest or apartment changes. |
| P12 | `UpdateChecker` is shared. On Windows `WindowsUpdates.checker` feeds it from `InstallerReleaseFeed`. `applyUpdate()` opens the release page until stage 8. | `Core/UpdateChecker.swift`; `Platform/Windows/WindowsShell.swift` | The update banner and the Settings update rows work on Windows as on the Mac. Installing the update is stage 8 (J). |
| P13 | Stage 6 left: `WinPlazaCanvas` (Direct2D on a WIC bitmap, CPU, any thread), `WinPlazaTextEngine` (DirectWrite: Galmuri, Pretendard, Segoe UI Emoji), `PlazaStoreSpriteFetcher` (front/back, shiny, form, egg; the Mac's cache files), `PlazaGIFDecoder.framesWithDelays` (the Mac's delays), `PlazaPanelDrawing` / `PlazaAccessibilityItem` / `PlazaTooltip`, `PlazaAnimationClock`, `ptb_capture_screen`, `--selftest --dump-ui`. | `Team/Plaza/HUD/*`, `Platform/Windows/Plaza/*`, `WinUIDump.swift` | The drawn parts reuse all of this; no new graphics stack and no GPU device in the popover (D7). |
| P14 | Keychain-only UI on the Mac: the "Disable Keychain access" toggle, "Refresh limit token" ("reads Keychain only when pressed"), the Claude Keychain help popover ("macOS resets the Keychain 'Always Allow'…"), the session key hint ("…with no Keychain pop-up") and the storage note ("this Mac"). On Windows a user refresh with no credentials file throws `keychainAccessDisabled`, which the store turns into "Couldn't fetch Claude limits. Please try again shortly." (wrong advice). | `SettingsView.swift` 754–817; `PopoverView.swift` 899–930; `Platform/OAuthKeychainUnavailable.swift`; `UsageStore.friendlyLimitError` | Windows hides the Keychain toggle and uses its own wording (D13). The missing-file error becomes "No Claude credential found…" through a fork-owned Platform change, not a Core edit (Task 6). |
| P15 | `selectedProviderHasLimits` shows the Antigravity section when `!disableKeychainAccess`. On Windows the Antigravity limits are a stub (unavailable). | `PopoverView.swift` 398–412; `WindowsLimitsProviders.swift` | The shared predicate takes platform facts. On Windows a provider with no limits source shows no section (D8). |
| P16 | The floating pet is reached from the popover's footer eye button, a Settings group (enable, size, bubbles, agent activity) and "Animation quality" (menu bar sprite + pet). The tray icon is static on Windows. | `PopoverView.swift` 1150–1159; `SettingsView.swift` 232–245, 351–397 | Until the pet exists on Windows (tier 3), those controls are not shown; showing a switch that does nothing would be dishonest. "Back view" applies to the popover sprite and the tray icon, so it ships in tier 1. |
| P17 | The menu bar shows today's tokens, cost, growth and limit percentages, coloured by mode (`showTokensInMenu` …, `menuLimitColorMode`). A tray icon shows no text. | `SettingsView.swift` 301–333; `MenuBarContent` | That group has no Windows meaning (open question 6). The tray tooltip keeps today's tokens and cost (Track B). |
| P18 | Persisted settings: 22 `UsageStore` keys (`refreshInterval` … `disableKeychainAccess`, plus `disabledProviderIDs`, `customScanRoots.*`, `claudeTrackedAccount`, `additionalClaudeConfigDirs`). Also `growthDifficulty`/`shopDifficulty` (companion), `team.*` (9 keys), `skippedUpdateVersion`, and the language in the companion state. | grep `forKey:` | D12 maps every one. The parity scan fails on a new key (D9). |
| P19 | Track B Task 4 deferred UNC and mixed-separator custom scan roots "to stage 7", because the only input is Settings. | Track B plan, Task 4 | When the custom-roots field ships (Task 14), that input exists: the defect protocol's reachability check now says yes. |
| P20 | Source scans run on the Mac only (`SharedSourcesScanTests`, `WindowsSeamScanTests`, `AppWiringDriftScanTests` are in the test `mac-only.txt`). | `Tests/PokeTokenBarTests/mac-only.txt` | The parity scan is a Mac-side scan too. It reads Windows sources as text. |
| P21 | Idle numbers to keep (Track B Task 12 and the status-burst fix): idle 120 s with 5 main-thread context switches; refresh window ≤ 280 cs/min and 3 M cycles/s. Measured with cycles and context switches, never `GetProcessTimes`. | Track B ledger | The popover budgets (D18) add on top of these, with the same tool (`measure-idle.ps1`). |

---

## Global Constraints

- **Speed rules (user decision, 2026-11-14) — these override any stricter wording below.**
  1. No per-task full Mac gate. A task is verified on the Mac by the filtered suites for what it touched, `./scripts/shared-check.sh` and `swift test --filter 'ScanTests'`. The full gate `./scripts/test-gate.sh` runs only at milestones (stage 7: after Tasks 2, 6 and 14) and before `windows-port` goes to `main`.
  2. Do not wait for Windows CI before merging a task into `windows-port`: merge, let the push run CI, fix forward when it is red. Windows-only tasks still read their run, but batch several changes per push.
  3. Tasks marked **[most capable]** keep an independent review. The session lead reads the others.

  The cost accepted: a break found at a milestone is harder to trace to its task. `windows-port` is not released, so nothing reaches users in between.
- **The Mac app must not change.** `UI/**`, `Core/**`, `PokeTokenBarApp.swift` and `OutsideClickMonitor.swift` are upstream-owned. They get no edits beyond one-line call sites routed through `Platform/PlatformCompat.swift` (the non-Windows branch is exactly the old expression). Each such line is listed in the PR and pinned by a Mac test. This stage plans three: `Core/UsageRecap.swift:140` (Task 1) and two in `Core/SessionKeyLimitsProvider.swift` (Task 14, only if open question 5 says DPAPI). `Team/UI/TeamSettingsSection.swift` is fork-owned. Task 1 moves its rules out; the Mac's behaviour is pinned by `TeamSettingsTests` plus a new equivalence test. Track A rules apply where `Team/Plaza/**` or `Team/UI/**` is touched: `plaza-render-compare.sh` prints `RENDER: identical`.
- Work in `.worktrees/<task-branch>` cut from `origin/windows-port`. Never edit the main checkout. No bare `git stash`. Every `gh` call passes `--repo likelion-campus/PokeTokenBar`.
- **One PR per task into `windows-port`, merged with a merge commit.** `git merge --no-ff origin/main` into the task branch at the start of every task. English Conventional Commits title. The body follows `.agents/skills/prepare-pr/SKILL.md` and `.github/PULL_REQUEST_TEMPLATE.md`.
  - **Visible changes carry images.** Before: "no Windows popover existed" (first PR of each page), or the previous CI capture. After: the runner's capture of the real popover, labelled "Sample-data capture, Windows CI runner". Put it next to the Mac's render of the same page and data where one exists (the Mac rendering tests, `ImageRenderer`, offscreen). Upload through the team's PR-image route (memory: PR images via gist).
- **One `swift build` / `swift test` / `shared-check.sh` / `plaza-render-compare.sh` at a time on this Mac.** Before each, `pgrep -x swift-build; pgrep -x swift-test; pgrep -x xctest` must print nothing; otherwise wait. Never run the full suite while another session's release gate runs. **Wait in chunks of at most ~150 s per Bash call**, for the Mac build slot and CI runs alike (COMMON-RULES "Waiting, corrected"). Never end a turn waiting for a notification.
- **Windows is verified by pushing and reading the CI run** (`gh workflow run windows.yml|windows-app.yml --ref <branch>`, `gh run view <id> --log`, `gh run download`).
  - Work branches run `windows-app` at the light level. Ask for `-f level=full` only when a task changes idle cost (Tasks 4, 8, 10, 12) or the installer.
  - Aim for ≤ 5 round trips per task. Every selftest check prints one greppable `PASS|FAIL name: detail` line with measured values.
  - Windows CI does not block merges. CI pair fixed: `windows-latest` + Swift `6.3.2-RELEASE`.
- **Where code goes.**
  - Windows-only Swift: `Sources/PokeTokenBar/Platform/Windows/Popover/**`, each file wrapped whole in `#if os(Windows)`. `WinSDK`, `CWinShim` and `CPlazaD2D` are imported only inside that wrap.
  - Shared popover logic: `Sources/PokeTokenBar/Popover/**`, a new fork-owned directory. It is compiled and tested on both OSes, imports nothing Apple-only, uses explicit `import Observation`, and has no body-level `#if`. The Mac app does not call it.
  - Shared seams go in `Platform/*.swift`. Body-level `#if os` only under `Platform/`.
  - C++ (the file dialog) goes only in the existing Windows-only `CWinShim`, as a new file. `Package.swift` is **not** edited: new system libraries load through `WinDynamic` or `#pragma comment(lib, …)`. If one edit proves unavoidable, it is in the Windows branch only and named in the PR.
  - Windows-only tests: `Tests/PokeTokenBarTests/WindowsPopover*Tests.swift`, wrapped whole. A new `mac-only.txt` entry has a `# why` line above it.
- **Main thread (Track B F4, F16):** every popover window and control lives on the main thread, made through `WinSinkWindow`'s general init (Track B rule: every text-input window of ours). WndProcs enter app code through `MainActor.assumeIsolated`. Background work (sprite fetch and decode, PokéAPI, validation) hops back with `DispatchQueue.main.async`. Timers are `Timer(fire:interval:repeats:)` only (scan). Exits go only through `WindowsApp.exit` (scan).
- **Focus:** only `WinPopover.present(…)` activates (`SetForegroundWindow`, `ShowWindow(SW_SHOW)`), and only from a user action: a tray click or key-select, the tray menu, or a second launch from Start (D4). A Windows scan (Task 4) fails on activation calls anywhere else in `Platform/Windows/Popover/`.
- **Idle cost is a failure condition (spec §2).** A closed popover leaves no window, timer, hook, GDI object or thread behind. An open popover with nothing changing (Settings, or Home with a still sprite) has no timer at all; the relative-time clock runs only while a relative text is on screen. Every timer added states what arms it, its period and what stops it. Measurements use cycles and context switches (Track B F20).
- **No code-drawn game art.** Sprites, eggs and item icons come from the sprite store and PokéAPI cache. UI glyphs come from system icon fonts (stage 6 D15). Emoji come from Segoe UI Emoji. Chart bars, badges, the recap shell and progress bars are UI chrome (rectangles, capsules, text), drawn as the Mac draws them. Test fixtures built from bytes are labelled as fixtures.
- **Nothing published, nothing uploaded to third parties, no signing.**
- **Honest stubs and failures.** A setting that has no effect on Windows is not shown (D12). A provider without a limits source shows no section. A failed file dialog, secret store or sprite says so in the log once and in the UI where the Mac would. Never a plausible "working" value.
- Tests: `UserDefaults` only through `TestDefaults.make(suite:)`; every `UsageStore(` passes `providers:`; tests in a `@MainActor` class that run on Windows are `async`; never force-unwrap an async result; no test shows UI that needs a person; `SendInput` only when `CI` is set. Window behaviour is checked in `--selftest` on the runner, not in XCTest. **No test puts a window on the Mac's window server**: Mac renders are offscreen (`ImageRenderer`, `CGPlazaCanvas`).
- Defects follow the defect protocol in `CLAUDE.md`: root cause including why tests missed it; a class sweep after reading `docs/reference/defect-log.md`; a trigger-branch test after a reachability check; fault injection; a permanent capture. "Green on the Mac, wrong on Windows" (locale, formatter, path) is the defect class most likely here.
- Model per role (user rule): implementers `sonnet`; tasks marked **[most capable]** use `opus` for implementation and review; mechanical commands `haiku`.
- No date, weather or chance gate on any feature without asking. Mac-side probes never activate the app.

---

## Design decisions (later tasks rely on them)

**D1. UI technology: Win32 common controls for everything interactive, shared drawn parts for pixel art and charts.** Three options were weighed with this codebase in hand.

| | (1) Direct2D window + the shared panel system | (2) Win32 common controls + drawn parts (**chosen**) | (3) WinUI 3 / XAML islands |
|---|---|---|---|
| Accessibility (Narrator) | Drawn panels expose nothing until a UI Automation fragment provider is written (stage 6 deferred it; an L task). Every control role would need provider code. | Native controls are read by Narrator through the MSAA proxy. Drawn parts add real child controls for their items (D7). No provider to write. | Good (XAML) |
| Keyboard, focus rings | The panel system has no focus model, no Tab order and no key activation; all new code. | `IsDialogMessageW` gives Tab, Shift+Tab, arrows in groups, Enter/Escape and focus cues. | Good |
| Text entry (IME, selection, paste, masking) | A native `EDIT` over the composition anyway (stage 6 D13, R1). | `EDIT`, `ES_PASSWORD`, `EM_SETCUEBANNER`; IME and paste built in. | Good |
| Controls the Mac uses (toggle, menu picker, slider, stepper, segmented, tabs, scroll) | Each drawn and hit-tested by hand: the "UI toolkit of 9,000 lines" spec §8 rejected. | All exist (check box, combo box, trackbar, up-down, push-like radio group, tab control, scroll bars). | All exist |
| High contrast, DPI | Manual. | System colours and per-DPI fonts. The rest is our layout code. | Good |
| Dark mode | Easy (own drawing). | Partial: needs theme names and custom colours (Task 16). | Good |
| Idle cost | A swap chain, a device and loss handling for a short-lived window. | A GDI window with no device. Paints only on invalidation. | WinUI's dispatcher loop next to our CF loop; unknown cost. |
| Binary size and dependencies | none new | none new (system DLLs) | Windows App SDK runtime (tens of MB), a projection generator (The Browser Company's `swift-winrt`/`swift-winui`), not proven with Swift 6.3.2 or CF's ANSI pump |
| Look versus the Mac | Could be pixel-close | Native Windows look; same layout, order and sizes; pixel-art parts drawn as on the Mac | Fluent look |
| Effort | Highest: a toolkit plus a UIA provider | Medium: Win32 interop is verbose but mechanical, isolated in one kit (Task 3) | Unknown; packaging and runtime risk |

Option (2) is what spec §8 already chose (**[설계자 판단]**, user heard it). Stage 6's work is reused where it fits: the canvas, the text engine, sprites and the drawing and accessibility types for the drawn parts. The panel system's focus-free interaction model is not reused. Option (3) is rejected: no maintained Swift projection proven here, a large runtime, and its own event loop beside the one Track B proved.

**D2. The window and where it appears.**
- Class `PokeTokenBarPopover`, made through `WinSinkWindow`'s general init.
  - Styles: `WS_POPUP | WS_CLIPCHILDREN`, ex `WS_EX_TOOLWINDOW | WS_EX_CONTROLPARENT`, owned by the hidden sink window. So: no taskbar button, not in Alt+Tab. Class style `CS_DROPSHADOW`.
  - On Windows 11, `DWMWA_WINDOW_CORNER_PREFERENCE = DWMWCP_ROUND`. A 1 px border in the system's border colour.
  - Not topmost: it is the foreground window while it exists.
- **Lifetime:** created on open, destroyed on close (P2). Destroying it frees fonts, bitmaps, tooltips, the dialog registration and the observation generation. A stale `onChange` after close is a no-op, checked by generation.
- **Size:** 360 DIP wide. Home 600 DIP tall (banner, tab row, 520 content, footer: the Mac's stack). Settings 460 DIP. Recap fits its content. If the work area is smaller, the height is clamped and the content scrolls.
- **Anchor:** `Shell_NotifyIconGetRect` (`WinTray.anchorRect()`), else the click point from the v4 callback's `wParam`, else the cursor position (the icon is in the overflow flyout, or Explorer cannot say). For a second launch with no rect: the bottom-right corner of the primary work area (where Windows 11 flyouts open).
- **Placement:** the pure shared `PopoverPlacement.frame(…)`.
  - Monitor = `MonitorFromRect(anchor)`. The taskbar edge is where `rcWork` is cut from `rcMonitor`; with an auto-hidden taskbar, `SHAppBarMessage(ABM_GETTASKBARPOS)`.
  - Taskbar at the bottom: above the icon, right edges aligned to the icon centre plus half the width, clamped into the work area with a 12 DIP margin. Top: below. Left or right: beside it, top-aligned to the icon. Flipped when it would leave the work area.
  - Tested on both OSes with the four edges, two monitors, negative coordinates, auto-hide, and a work area smaller than the popover.
- **DPI:** the window is created at the DPI of the anchor's monitor (`GetDpiForMonitor`, then sized with `AdjustWindowRectExForDpi`). `WM_DPICHANGED` while open (a scale change) rebuilds the page in place at the new DPI, keeping the navigation state.

**D3. Dismissal and the toggle.**
- Closes on:
  - `WM_ACTIVATE(WA_INACTIVE)`, unless the window being activated is owned by the popover (our task dialog or file dialog, D17; a `TrackPopupMenu` does not change activation);
  - `WM_ACTIVATEAPP(FALSE)`;
  - Escape on Home;
  - session lock (activation moves to the secure desktop);
  - the plaza opening;
  - Quit.
- Escape on Settings, Recap or a sub-page means Back (the Mac's `.keyboardShortcut(.cancelAction)`).
- **The toggle race:** clicking the icon while open first deactivates the popover (the taskbar takes activation), which closes it, and only then does `NIN_SELECT` arrive. Shared `PopoverToggleGuard` remembers "closed by deactivation at t, with the cursor inside the anchor rect". A select within 500 ms of that does not reopen. The result is a toggle, as on the Mac.
- No global mouse hook, no polling (P3).

**D4. Activation and who may open it.**
- Opens from:
  - a tray left click (`NIN_SELECT`) or keyboard select (`NIN_KEYSELECT`: Win+B, arrows, Enter);
  - tray menu items "설정…/Settings…" and, later, "Dex";
  - a second launch (Start menu or desktop shortcut while running). The second process calls `AllowSetForegroundWindow(<running pid>)` before posting `WinSingleInstance.showMessage`. The running instance opens the popover instead of today's "already running" balloon (open question 3).
- Explorer grants the tray owner the foreground right on a click, the same right the tray menu already uses (`SetForegroundWindow` before `TrackPopupMenu`, P10). A refused `SetForegroundWindow` (the window shows but is not active) is detected by `GetForegroundWindow() != hwnd` right after `present`. Then the window is destroyed and the tray menu opens instead, with one log line. A visible popover that would not light-dismiss is worse than a menu.
- Teammates, timers, balloons and refreshes never open it. The scan from Task 4 and a selftest check (`popover.noSelfOpen`) enforce this.

**D5. Keyboard and text.**
- The popover registers with `WinMessageHook.registerDialogWindow` and unregisters on destroy (new `unregisterDialogWindow`).
- `IsDialogMessageW` handles every message for the popover and its children. That gives Tab and Shift+Tab in creation order (which is visual order), arrow keys inside radio groups, Space/Enter on buttons and focus rectangles after keyboard use. Keys and characters reach edits in their Unicode form, `WM_IME_*` included, so popover text input does not depend on stage 6 Task 11.
- Enter in a single-line edit commits that field (the Mac's `onSubmit`; the edit is subclassed for `VK_RETURN`). Escape is handled per D3. Ctrl+Tab / Ctrl+Shift+Tab switch the main tabs once there are several.
- Text fields:

  | Field | Kind |
  |---|---|
  | Team code | `EDIT` with a cue banner. Paste is trimmed of white space and newlines before `TeamCode(parsing:)`, as the Mac's parser accepts. |
  | Nickname, team name | `EDIT`. Committed on Enter, focus loss and page close (`EN_KILLFOCUS`, destroy): the Mac's three commit points. |
  | Session keys | `EDIT` with `ES_PASSWORD`. Cleared after a successful save; never logged; `EM_SETPASSWORDCHAR` default bullet. |
  | Custom roots, additional Claude folders | Multi-line `EDIT` (`ES_MULTILINE \| ES_AUTOVSCROLL`, no `ES_WANTRETURN`). Ctrl+Enter makes a new line; Enter commits; focus loss commits. |
  | Dex search (tier 3) | `EDIT` with a cue banner and a clear button. |

- No access-key underlines (`&`): translated strings carry none (as the tray menu).

**D6. Layout, fonts, metrics.**
- All metrics are the Mac's points used as DIP: width 360, padding 14, scroller lane 12, row minimum 38, card radius 8, section spacing 18. Times DPI/96.
- Fonts: Segoe UI Variable Text (Windows 11), else Segoe UI, created per DPI. Sizes are the Mac's text styles in DIP, measured once on the Mac into `Tests/PopoverParity/mac-text-styles.json` by Task 3 (`.caption`, `.caption2`, `.callout`, `.headline`, `.title3`, 28 pt bold, monospaced digits). Hangul in native controls comes through GDI font linking (Malgun Gothic). Digits use Segoe UI's tabular figures where the Mac asks for `monospacedDigit`.
- The kit (Task 3) lays out top to bottom.
  - A page is a `WinStack` of sections. A section is a card with an uppercase caption, rows separated by 1 px dividers (the Mac's inset-grouped look).
  - A row is a label on the left and a control on the right, or label + hint stacked.
  - Visibility changes re-run the stack's layout. Nothing else moves controls.
- Scrolling: a child container with `WS_VSCROLL`. Wheel and touchpad scroll it (`WM_MOUSEWHEEL`, `SPI_GETWHEELSCROLLLINES`). Tab into a control scrolls it into view. A thumb drag (the scroll bar's modal loop) runs inside `WinModalPump.begin/end("scroll")`, so team links keep their heartbeats.

**D7. Drawn parts.**
- **What:** a shared `PopoverPart` renders a `PlazaPanelDrawing` (layers + accessibility items + tooltips; the stage 6 types) through `PlatformPlaza.graphics`: `CGPlazaCanvas` on the Mac (tests and PR images only), `WinPlazaCanvas` on Windows. Parts are headless and tested on both OSes like the stage 6 panels.
- **Parts:** limit bar (with pace marker), growth bar, badges (rarity, type, boost, guarantee), companion header art (sprite slot, overlays), evolution line, trend bars, heatmap, recap card, page dots.
- **Host:** `WinDrawnView`, a child window. `WM_PAINT` uses `AlphaBlend` of a premultiplied 32-bpp DIB made from the layers' `PlazaBitmap`s. Images are rasterized at the window's DPI, so they blit 1:1. Sprites are scaled nearest by the canvas (`setInterpolationNone`), as the Mac's `.interpolation(.none)`.
- **Accessibility and keys:**
  - Each `PlazaAccessibilityItem` becomes a real child control at its frame. A `button` item is an owner-drawn `BUTTON` (`WS_TABSTOP`, its label as window text) that draws only a focus rectangle (`ODS_FOCUS`) over the picture; a press reports the item's `action` hit. A `staticText` item is an invisible `STATIC` with the text.
  - So Narrator reads drawn parts, Tab reaches their buttons, and Enter/Space press them. No UI Automation provider is written.
  - Tooltips become `tooltips_class32` rect tools, with the delay at 600 ms (the Mac app's `NSInitialToolTipDelay`).
- **Sprite slots:** a part leaves a slot (frame, subject, bob) instead of drawing the sprite. The host draws the current frame into the slot. Only the slot's rect is invalidated per frame (D16).
- **Text in parts:** the canvas's `.system(size:weight:)`, which is Pretendard on Windows (stage 6 D10) and the system font on the Mac. Parts that need monospaced digits (the recap LCD) use a new `PlazaFont.mono(size:weight:)`: SF Mono on the Mac, Cascadia Mono, else Consolas, on Windows (Task 13; the plaza never uses it, so the render compare is identical). Native controls stay Segoe UI (a listed difference).

**D8. Shared view models and twins.** The rule for every Mac popover behaviour (P5):
- **Logic in a shared store or type** (`UsageStore`, `CompanionStore`, `TeamSettings`, `UpdateChecker`, `TokenFormatter`, `UsageCost.text`, `PaceTier.tier/gauge/roundedDelta`, `DailyTrendStack`, `UsageRecap`, `L`): the view model calls it. Nothing to copy.
- **Logic in a fork-owned Mac file** (`TeamSettingsSection`): moved to shared code; the Mac calls the moved code (Task 1).
- **Logic in an upstream `UI/` file:** a shared *twin* with a distinct name (e.g. `PopoverTrendMetrics` for `DailyTrendMetrics`). It lives in `Popover/`, is compiled and tested on both OSes, and is held to the original two ways:
  - a Mac-only equivalence test (`PopoverTwinEquivalenceTests+Mac`) drives the original and the twin over a corpus and compares outputs;
  - a text-drift scan (D9) compares the original's normalized source with the twin's, so a new upstream branch the corpus misses still fails.
  Why twins and not moves: moving would edit upstream files far beyond one line. Why not only a text copy: the equivalence test proves behaviour, the scan only catches change.
- **View-local logic in a SwiftUI body** (`selectedProviderHasLimits`, `quotaRow`, the status line, the footer rules): rewritten into the view models, one function per Mac private func, named after it in a doc comment. Inventory rows name them (D9), so a new Mac section shows up as a missing row.
- **Platform facts** the Mac views assume are explicit input: `PopoverPlatformFacts` = `hasKeychain`, `antigravityLimitsAvailable`, `floatingPetAvailable`, `regionLocale`, `regionCalendar`. The Mac fact set reproduces the Mac's predicates exactly (equivalence test); the Windows set hides what has no source.
- Colours are roles (`PopoverColorRole`: `systemBlue`, `teal`, `green`, `yellow`, `orange`, `red`, `gray`, `accent`, `primary`, `secondary`, `tertiary`, plus the fixed palettes). Windows maps roles to the Mac's light-appearance sRGB values, measured on the Mac into `Tests/PopoverParity/mac-colors.json` (Task 2), with the accent from Windows (D15).

**D9. The parity scan (`PopoverParityScanTests`, Mac-side, Task 1).** Data files live outside the test target (no SwiftPM "unhandled file" warning), in `Tests/PopoverParity/`:

| File | One row per | Statuses |
|---|---|---|
| `inventory.txt` | every Swift file in `UI/` and `Team/UI/TeamSettingsSection.swift`; every `struct …: View`, `ViewModifier`, `NSViewRepresentable`, and every `private func/var … some View` in the popover files (`file#symbol`) | `win <windows file>` · `tier2` · `tier3` · `n/a: <reason>` |
| `strings.txt` | every `L` member referenced by the popover files | `win` · `replaced: <windows member>` · `tier2`/`tier3` · `n/a: <reason>` |
| `members.txt` | every `store.`, `companion.`, `updater.`, `team.`, `nav.`, `feed.`, `session.` member referenced by the popover files | same |
| `settings.txt` | every `forKey:` key written by `UsageStore`, `CompanionStore`, `TeamSettings`, `UpdateChecker` | `win <section>` · `tier2`/`tier3` · `n/a: <reason>` |
| `twins.txt` | `mac file#symbol ⇄ shared file#symbol` + rename map | — |

Rules (each fails with a message saying what to do):
1. An extracted name with no row fails, so a new upstream string, member, key or section is never silently missing.
2. A row whose name no longer exists on the Mac side fails, so the files stay exact.
3. A `win` or `replaced` row must be referenced somewhere in `Popover/**`, `Platform/Windows/Popover/**`, `Platform/TrayMenuModel.swift` or `Platform/WindowsPopoverStrings.swift`.
4. A twin's normalized body (comments and white space dropped, renames applied) must equal the original's.
5. `tier2`/`tier3` rows are allowed, but counted and printed in every run (`PARITY: 0 missing, 41 tier2, 187 tier3`), so the gap is visible until it is closed. When stage 7 ends, `tier2` must be zero.

The extractor's unit tests feed it synthetic sources, and every rule is fault-injected once: add `l.fooBar`, delete a row, change a twin. Upstream-sync PRs (merging `main`) run the scan and list "popover changes → Windows" in the body (spec §8). CONTRIBUTING gains the procedure (Task 18).

**D10. Data flow and refresh.**
- Each page builds its model inside `withObservationTracking`. `onChange` schedules one rebuild per main-queue turn (coalesced, like `PlazaHUD`'s flush). The rebuild compares the new model with the last. Changed sections apply their deltas: `SetWindowTextW` only for changed text, show/hide plus relayout only for visibility changes, re-render only for changed parts.
- No new polling. The data changes when the store refreshes (its 120 s timer, the footer's refresh button, a limits retry), as on the Mac. Opening the popover calls `store.requestNotificationAuthorizationIfNeeded()` (a no-op on Windows) and `WindowsUpdates.menuOpened()` (the Mac's `updater.check()` behind its cooldown).
- **Relative texts** ("Updated 3 min", resets "in 2 hr, 5 min", the stale badge) come from shared `RelativeTimeText`, because SwiftUI's `Text(date, style: .relative)` does not exist here and `RelativeDateTimeFormatter` is missing on Windows (P8).
  - It uses `Duration.UnitsFormatStyle` (swift-foundation, ICU), wide, at most two units, in the app language, if Task 1's first Windows push shows it works there. Otherwise unit words come from `L` in 8 languages.
  - A popover clock (`PopoverClock`) arms one `Timer(fire:)` at the earliest instant any visible relative text changes: per second while one shows seconds, else at the next minute boundary. It stops when no relative text is visible or the window closes.
  - The wording may differ from SwiftUI's (a listed difference).
- Pace markers move only with refreshes and reopening, as on the Mac (no timer, `LimitProgressBar` comment).

**D11. Locale and formatting on Windows.**

| Seam (`PlatformCompat`, shared) | Mac (exactly today's) | Windows |
|---|---|---|
| `regionLocale` | `Locale.current` | `Locale(identifier:)` from `GetUserDefaultLocaleName` (e.g. `ko-KR`), else `Locale.current` |
| `firstWeekday` | `Calendar.current.firstWeekday` | `GetLocaleInfoEx(LOCALE_NAME_USER_DEFAULT, LOCALE_IFIRSTDAYOFWEEK)`: 0 = Monday … 6 = Sunday, converted to Calendar's 1 = Sunday … 7 = Saturday |
| `regionCalendar(timeZone:)` | gregorian, `firstWeekday`, `.current` | the same from the two above |

- Pure conversions are in shared `Platform/RegionFormat.swift`, tested on both OSes.
- Uses:
  - number grouping: `TokenFormatter.grouped(n, locale: PlatformCompat.regionLocale)` from Windows code; Core untouched;
  - the heatmap's weeks and weekday labels, and the weekend ticks (Task 12);
  - the recap: one upstream line, `Core/UsageRecap.swift:140`, `calendar.firstWeekday = PlatformCompat.firstWeekday` (Mac branch `Calendar.current.firstWeekday`, pinned).
- Date texts follow the **app language** (`language.displayLocale`), as on the Mac: the day stamp (`MdE`), reset clocks (`HHmm`, `EEEEdHHmm`, always 24 h), export dates (`.medium`/`.short`).
- Selftest `locale.region` prints the seam values next to Windows' own `GetNumberFormatEx` result. Task 1's Windows tests check `setLocalizedDateFormatFromTemplate` outputs for ko, en, ja, fr against Mac goldens.

**D12. Every Mac setting on Windows.**

| Mac setting (group) | Windows | Tier / task |
|---|---|---|
| Language (General) | combo box; `companion.setLanguage` + `store.localizationLanguage`; an explicit choice is kept (PC defects 1 migration runs once) | 1 / T6 |
| Representative Pokémon (General) | needs the Pokédex | 3 / T20 |
| Refresh interval (General) | combo box, `UsageStore.intervalPresets` | 1 / T6 |
| Animation quality (General) | not shown until the floating pet exists (P16) | 3 / T22 |
| Limit display used/remaining (General) | push-like radio pair | 1 / T6 |
| Daily trend period (General) | combo box | 2 / T12 |
| Tracked Claude account (General, with ≥ 2 accounts) | combo box | 2 / T14 |
| Launch at login (General) | check box over `WindowsLoginItem`; "disabled in Task Manager" as its hint; Mac-only "bundled only" and "approval" hints dropped | 1 / T6 |
| Difficulty: growth, shop (Difficulty) | trackbars over `PokemonBalance.difficultyPosition`, value text, low/high labels, Save when changed (twin of `DifficultyDraft`) | 2 / T15 |
| Menu bar: tokens, cost, growth %, limit %, limit colour | not applicable: the tray shows no text (P17, open question 6) | n/a |
| Tracked providers | one check box per `registeredProviders` | 1 / T6 |
| Floating pet: enable, size, bubbles, agent activity | with the pet | 3 / T22 |
| Back view (floating pet group; applies everywhere) | check box in General, since the pet group is not there yet | 1 / T6 |
| Team (all of `TeamSettingsSection`) | D5 fields; masked code + Copy (`CF_UNICODETEXT`) + Leave; switch menu; saved teams; notifications; core time and season combos; captions; incompatible-peer warning | 1 / T6 |
| Notifications: limit alerts, warn and critical sliders, companion, status checks | check boxes and trackbars (50–95 and 80–100, step 5) | 1 / T6 |
| Updates: notifications, Check now, offer/skipped/up-to-date rows | as the Mac, over `WindowsUpdates.checker` | 1 / T6 |
| Backup & transfer: export, import, snapshot, history, restore | D17 dialogs | 2 / T15 |
| Advanced: session key, org picker, per-account keys | `ES_PASSWORD`, D14 storage | 2 / T14 |
| Advanced: disable Keychain access | not applicable (no Keychain); not shown; the value stays false | n/a |
| Advanced: refresh limit token | "Claude 로그인 정보 다시 읽기"-style Windows wording (re-reads `~/.claude/.credentials.json`); enabled always | 2 / T14 |
| Advanced: additional Claude folders, custom scan roots + match count | multi-line edits; UNC and mixed separators handled (P19) | 2 / T14 |
| About: report a problem, show log file, links, version | `mailto:` through the shell (allowed scheme added), Explorer `/select,`, `WindowsInstall.version` | 1 / T6 |

**D13. Strings on Windows.**
- The Windows copy uses the Mac's `L` members wherever the words are right.
- Where they name Mac things (Keychain, Finder, "this Mac", macOS), it uses new members in a shared `extension L` in `Platform/WindowsPopoverStrings.swift`, in all 8 languages, the pattern of `TrayMenuModel.swift`. They are named `win…` and recorded as `replaced:` rows (D9).
- No upstream string changes.
- The team section stays Korean (P6).
- The Mac's `reportMailBody(os:)` gets the Windows version string from `ProcessInfo.operatingSystemVersionString`. Task 6 checks it for Mac-only words.

**D14. Session keys at rest on Windows: DPAPI (recommended; open question 5).**
- `PlatformCompat.writeSecret(_:to:)` and `readSecret(at:)` are routed from the two file calls in `SessionKeyStore.save`/`load`: two one-line upstream call sites. The Mac branches are exactly today's `data.write(to: fileURL, options: .atomic)` and `Data(contentsOf: fileURL)`.
- On Windows: `CryptProtectData` / `CryptUnprotectData` (current user, no UI flag, an app-specific entropy constant) through `WinDynamic` on `crypt32.dll`, written with `WinAtomicWrite`.
- Why: Windows' per-user secret store has no prompts and no code-signature ACLs, so the reason the Mac avoided the Keychain (#58) does not apply. It protects copies of the file (backups, a disk read from another account or offline). Other processes of the same user can still read it, as on the Mac.
- A file that does not unprotect (another user's copy, a reset profile) reads as no key, with one log line; the user enters it again.
- A plaintext file (written before this change, or by hand) is read and re-protected at the next save.
- The Windows storage note says "encrypted for your Windows account; logging out in the browser invalidates it".
- If the user declines: no upstream line, the same plaintext file as on the Mac. The per-user `%LOCALAPPDATA%` ACL is checked by a selftest (`secrets.acl`: no `Users`/`Everyone` ACE).
- `Platform.secrets` stays the stub; nothing calls it (Track B ruling 2 still holds).

**D15. Colours, appearance, high contrast.**
- 7.1–7.2 are light: window `COLOR_WINDOW`, cards one step darker, text `COLOR_WINDOWTEXT`, secondary and tertiary text at the Mac's opacities over the card.
- Drawn parts use the Mac's light values (`mac-colors.json`), including the heatmap's light greens.
- Accent = the user's Windows accent (`HKCU\Software\Microsoft\Windows\DWM\AccentColor`), else systemBlue. Today markers and selected capsules use it, as the Mac uses its accent.
- **High contrast** (`SPI_GETHIGHCONTRAST`): no colour is overridden; controls draw themselves; drawn parts switch to system colours (bars `COLOR_WINDOWTEXT`, today `COLOR_HIGHLIGHT`, cards `COLOR_WINDOW` with `COLOR_WINDOWTEXT` borders). Sprites are pictures and stay.
- **Dark mode** (follow `AppsUseLightTheme`; `WM_SETTINGCHANGE` "ImmersiveColorSet") is Task 16, if open question 1 says yes:
  - `SetWindowTheme(L"DarkMode_Explorer")` for buttons and scroll bars, `L"DarkMode_CFD"` for combo boxes and edits;
  - our own `WM_CTLCOLOR*` brushes;
  - check-box labels as separate statics (themed check-box text cannot be recoloured);
  - drawn parts with the Mac's dark values.

**D16. The companion sprite and animation.**
- Source: `PlazaStoreSpriteFetcher` (shared, stage 6 D12): front, or back when `facesBack`; shiny; form; the egg; cropped as the Mac. Frames and delays from `PlazaGIFDecoder.framesWithDelays`. Decoded off the main thread; frames cached per subject and DPI while the popover is open; freed on close.
- Placeholder: the cached still frame; else 🥚 drawn with Segoe UI Emoji (Mac: the 🥚 glyph).
- **One clock for all sprites** (`PopoverAnimationClock`): a single `Timer(fire:)` re-armed for the earliest next frame due across visible animated slots, at the GIF's own delays (the Mac popover's `minFrameDelay: 0`). Each tick invalidates only the changed slots' rects; `WM_PAINT` blits the pre-scaled frame.
  - The bob (static fallback) is a 0.9 s ease-in-out up/down of 3 DIP, drawn as two pre-rendered offsets on the same clock.
  - Stopped when no animated slot is visible (another tab, Settings), on close, and while `WindowsSystemEvents` says the display is off.
- **Celebrations**, with the Mac's timings and one-shot contract:
  - hatch/evolve: white flash 0.85 → 0 over 0.8 s, spring scale 0.6 → 1;
  - shiny ✨ and Ditto 🎭 bursts for 2.6 s;
  - candy "+N XP" capsule for 1.3 s;
  - mint sparkles for 0.9 s;
  - the egg wiggle (±5° at 0.35 s) while hatching is imminent.

  They run on the same clock at up to 60 Hz only while an effect is running. The popover calls `consumeCelebration()` / `consumeCandyFeedback()` / `consumeMintFeedback()` exactly when it plays one, as the Mac's header does, so an effect plays once on whichever surface shows it first.
- The Mac has **no sound** in the popover. Neither does Windows.

**D17. Dialogs and files.**
- Confirmations and results use `TaskDialogIndirect` through `WinDynamic` (comctl32 v6), owned by the popover:
  - import and restore confirmations have the Cancel button as the default (`ImportConfirmPolicy`'s rule: Enter must not replace progress);
  - export, snapshot and error results.
- Files: `IFileSaveDialog` / `IFileOpenDialog` (COM, STA main thread) in a new `CWinShim/filedialog.cpp` behind `ptb_file_dialog(owner, save, title, defaultName, *.json filter, out path)`.
- Every modal loop runs inside `WinModalPump.begin/end("dialog")` (Track B: modal loops starve the main queue).
- **The popover stays open** while its own dialog is up (D3's owned-window rule). The Mac's transient popover closes then and shows results in alerts; Windows keeps the same alerts and returns to the same page (a listed improvement, no behaviour lost).
- After an export, Explorer selects the file (`SHOpenFolderAndSelectItems`); the Mac reveals in Finder.

**D18. Idle and cost budgets** (guesses; first runs record numbers in the PR; tightened after the PC numbers).

| State | CI (runner, release, `measure-idle.ps1`, 30 s settle + 120 s) | PC (10 min) |
|---|---|---|
| never opened | Track B Task 12 budgets unchanged | stage 4/5 numbers within noise |
| opened then closed | the same as never opened after 10 s; handles within +10, GDI objects within +5, private bytes within +15 MB | the same |
| open, Settings, nothing changing | popover adds 0 timers; main thread ≤ 2 cs per 120 s beyond the idle baseline | CPU = closed within noise |
| open, Home, sprite still (egg or no GIF), relative texts at minutes | 2 main cs per minute (the minute tick) | the same |
| open, Home, animated sprite | main cs/s ≤ the sprite's frame rate + 2; ≤ 0.5 ms main-thread time per frame; GDI and USER objects flat over 120 s | CPU ≤ 1 % of total; GPU 0 % (no device) |
| celebration | ≤ 60 frames/s for at most 2.6 s, then back to the row above | — |

The idle gate in `windows-app.yml` (full level) gains the windows above. A `--selftest-popover-park <home|settings|closed-after-open>` helper (Task 10) opens the popover, parks it on a page and holds still for the measurement.

**D19. What runs where.**
- **Shared view models, parts and twins** run in XCTest on both OSes: Windows CI executes them with fixture stores (`UsageStore(providers:)`, `TestDefaults`, `URLProtocol` stubs for limits).
- **The Mac** also runs the twin equivalence tests, the parity scan and the colour/text-style goldens.
- **The window, controls, focus, placement, dismissal and drawing** are checked by `--selftest` groups on the runner: `popover.*`, `ui.kit.*`, `home.*`, `settings.*`, `companion.*`. Synthetic input only when `CI` is set.
- **Captures** (`--dump-ui`, extended): each page as PNG via `PrintWindow(PW_RENDERFULLCONTENT)` plus a screen capture, and a control-tree JSON (class, text, DIP rect, visible, enabled, tab stop, focus order).
  - The selftest asserts on the tree: every interactive control is inside the window and reachable by Tab; no two visible controls overlap; a label's text fits its width unless it is an ellipsis style; Hangul text has no missing glyphs (`GetGlyphIndicesW` with `GGI_MARK_NONEXISTING_GLYPHS` on the linked font).
  - The implementer downloads the artifact and **opens** the PNGs before describing them.
- **The PC** checks only what needs a person: what it looks like at 100/125/150 %, a real tray and overflow, Narrator, a Korean IME, light-dismiss against other flyouts, idle with real data.

**D20. Minimum Windows: 10 22H2 and 11**, as G1.
- Segoe UI Variable and Segoe Fluent Icons exist only on 11 (Segoe UI / MDL2 fallbacks).
- `DWMWA_WINDOW_CORNER_PREFERENCE` is 11-only (ignored on 10).
- Everything else exists on 10: `TaskDialogIndirect`, `IFileDialog`, DPAPI, PerMonitorV2, cue banners.
- CI is Server 2025, so Windows 10 is checked only on a Windows 10 PC (stage 6 open question 4 ruling: target 10 and 11, 10 marked untested).

---

## Inventory: the Mac popover → the Windows popover

Tier 1 = the minimal popover (usage, companion, settings including team setup). Tier 2 = the rest of this stage. Tier 3 = listed with estimates for the user to schedule. "Logic" says where the rules live today: **S** shared (call it), **M** moved by this plan from a fork-owned file, **T** a twin of a pure helper in an upstream `UI/` file, **V** rewritten from a SwiftUI body into a shared view model, **–** none. Every row becomes an `inventory.txt` row (D9).

### App shell and tray (`PokeTokenBarApp.swift`, `StatusItemMenu.swift`, `OutsideClickMonitor.swift`)

| ID | Function | Data | Actions | Tier | Logic | Windows |
|---|---|---|---|---|---|---|
| A1 | Status item: animated sprite, 1–4 text lines (tokens, cost, growth %, limit % coloured), tooltip | `menuLines`, `menuToolTip`, `menuLimitColorRuns`, representative subject | — | done (stage 4) / n/a | S | static tray icon + tooltip (Track B ruling 1); text lines n/a (P17) |
| A2 | Popover open/close: click toggles, reset to Home, build on open / free on close, activate, outside-click close, notification permission and update check on open, menu animation paused while open | navigation, stores | toggle, `reset`, route | 1 / T4 | S + V | D2–D4, `PopoverToggleGuard`, `PopoverState.reset` |
| A3 | Right-click menu: summary; Refresh; Dex; Plaza (+unread); Settings…; floating pet show/hide; Back view (checked); Quit | `todayTotalTokens`, cost, `floatingPetEnabled`, `alwaysFacesBack`, `isReady`, `unreadCount` | each action | 1 (Settings…, Back view) / 3 (Dex, pet) / T4 | S (`StatusItemMenu.entries` is AppKit-free values) | `TrayMenuModel` gains `.openSettings`, `.toggleBackView`; Windows extras kept (teammates, login, log folder, update); a drift scan compares action sets with an allow-list |
| A4 | `poketokenbar://agent` URL events → floating pet | — | — | 3 / T23 | S (`AgentActivityEvent`) | HKCU URL protocol registration with the pet |
| A5 | Edit menu so ⌘C/⌘V reach fields; tooltip delay 600 ms; legacy TokenMac folder migration | — | — | n/a | – | `EDIT` has Ctrl+C/V; tooltips at 600 ms (D7); no legacy folder on Windows |
| A6 | Second launch yields to the running instance | — | — | 1 / T4 | – | opens the popover (D4, open question 3) |

### Main popover (`UI/PopoverView.swift`)

| ID | Function | Data | Actions | Tier | Logic | Windows |
|---|---|---|---|---|---|---|
| P1 | Update banner: "vX available (current vY)", Skip this version, Update; "Updating…" spinner | `updater.available/isUpdating/currentVersion`, `updateNotificationsEnabled` | `skipCurrent`, `applyUpdate` | 1 / T5 | S | over `WindowsUpdates.checker`; Update opens the release page until stage 8 |
| P2 | Tab bar Home/Shop/Bag/Collection | `nav.tab` | select | 1 (Home) / 3 | V | `SysTabControl32` shown only once a second tab exists; Ctrl+Tab |
| P3 | Open-plaza button with unread red dot, tooltip | `teamSettings.isReady`, `feed.unreadCount` | `nav.onOpenPlaza` (close popover, `plaza.show`) | 1 / T5 | S | glyph button (Fluent "Map"), drawn dot |
| P4 | Home scroll area 520 pt, scroller lane | — | scroll | 1 / T5 | – | D6 scroll container |
| P5 | Today header: caption, compact total (28 pt bold), grouped digits when ≥ 1,000, cost | `todayTotalTokens`, `showsCost`, `todayUsageCost` | — | 1 / T2, T5 | S | `grouped` with `regionLocale` (D11) |
| P6 | Week and month totals with cost; wraps to two lines when narrow | `weekTotalTokens`, `monthTotalTokens`, costs | — | 1 / T5 | S + V | the stack wraps per measured width |
| P7 | Streak badge: flame + days from 2 days, orange when today counts, tooltip | `currentStreak` | — | 2 / T12 | T (`StreakBadge.isShown`) | drawn badge part |
| P8 | Recap button (chart icon + "Details") | — | `nav.showingRecap = true` | 2 / T13 | – | glyph + text button |
| P9 | Activity panel: click cycles the visualization; tooltip; page dots | `activityVisualization` | `.next` | 2 / T12 | S + V | drawn part; the click is its button item |
| P10 | Monthly bars: window menu (7/14/21 days, month), today readout, peak, provider-stacked bars + legend, hover card (day, tokens, cost, per provider), weekend ticks, axis labels, future days | `dailyTrendTotals`, `monthDailyTotals`, `trendProviders`, `registeredProviderIDs`, `dailyTrendWindow`, `hasDailyTrendHistory`, `showsCost` | set window; hover | 2 / T12 | T (`DailyTrendMetrics`, `DailyTrendHover`, `DailyTrendColumn`, `WrappingHStack`, `readout`, palette) + S (`DailyTrendStack`) | drawn part; the window menu is a `TrackPopupMenu`; hover via `TrackMouseEvent` |
| P11 | 16-week heatmap: weekday labels from the region's first weekday, 5 green levels, today outline, hover readout, peak | `dailyLedger`, `monthDailyTotals` | hover | 2 / T12 | T (`ActivityHeatmapMetrics`) | `regionCalendar` (D11) |
| P12 | Provider tabs (capsules, scroll when wide) when > 1 snapshot | `snapshots`, `nav.providerID` | select | 1 / T5 | S (`snapshot(preferring:)`) | push-like radio group in a horizontally scrolling strip |
| P13 | Provider row: name, today tokens, cost when it reports one, input/output/cache-write/cache-read, per-model lines (> 1 model, sorted, last path part, middle truncation) | `ProviderSnapshot.today` | — | 1 / T2, T5 | V | statics; `SS_PATHELLIPSIS`-style middle ellipsis computed in the model |
| P14 | Provider status banner: coloured dot, indicator label, description (only with an incident) | `providerStatus(for:)` | — | 1 / T5 | S + V (`statusColor`) | dot drawn; text static |
| P15 | Limits caption "Official limits" + Claude Keychain help (?) popover with "register session key" | `sessionKeyConfigured` | open help, `openSessionKeySettings` | 1 (caption) / 2 (help) | V | help replaced by a Windows credentials-file note (D13); its key button with T14 |
| P16 | Section gate `selectedProviderHasLimits` per provider | many | — | 1 / T2 | V + platform facts (P15) | `PopoverPlatformFacts` |
| P17 | Session-key-expired notice (key icon, title, Settings button, hint) | `limitsAuthExpiry` | `openSessionKeySettings` | 2 / T14 | V | opens Settings with Advanced expanded, scrolled and focused |
| P18 | Claude auth-expired notice with Retry (spinner) and hint | `limitsAuthExpired`, `isRefreshingLimitToken` | `refreshLimitTokenFromKeychain` | 1 / T5 | V | Windows wording for the hint (D13) |
| P19 | Claude refresh row: "tap to load" or "stale · relative", Refresh (spinner), error message | `limits`, `claudeLimitsStale/Missing`, `additionalLimitsPending/Stale`, `limitTokenRefreshMessage` | `refreshLimitTokenFromKeychain` | 1 / T5 | V | P14: missing-file error wording fixed in T6 |
| P20 | Claude account tabs (title, help = account, dot on the tracked one) + "unattributed usage" note | `claudeAccounts`, `trackedClaudeAccount`, `unattributedClaudeUsage` | `nav.claudeAccountID` | 1 / T5 | S + V | radio strip as P12 |
| P21 | Per-account block: expired additional-account notice (key or retry), stale badge, plan, account label, account usage today/month (+cost), dimmed when expired | `ClaudeAccountLimits`, `claudeAccountUsage` | retry | 1 / T5 | V | — |
| P22 | Claude rows: 5 h (not-started hint) + forecast (tracked account) + weekly + weekly Opus + weekly Sonnet + scoped entries + current 5 h block (tokens, reset relative + clock) | `LimitStatus`, `fiveHourForecast`, `claudeCurrentBlock(for:)` | — | 1 / T2, T5 | V + S | forecast time `HH:mm` |
| P23 | Quota row (all providers): name, detail, reset relative + clock suffix (HH:mm within 6 h or today, else weekday-day-time, app language, 24 h), idle hint, percent (used or remaining + "left"), percent colour, progress bar + pace marker, tooltip (tier, delta, pace hint) | `limitDisplayMode`, `warnThreshold`, `critThreshold`, `paceFraction` | — | 1 / T2, T5 | V + T (`limitPercentText`, `resetClockSuffix`, `paceHelp`, `markerFraction`, `PaceTier.color/percentColor`) + S (`PaceTier`) | limit bar = drawn part with tooltip and accessible value |
| P24 | Codex: plan, "limit reached" (red), stale badge; per bucket (label when > 1): primary and secondary windows, personal spend limit (used/limit) | `codexLimits`, `codexLimitsStale/UpdatedAt` | — | 1 / T5 | V | — |
| P25 | Antigravity: auth-expired + Retry, refresh row, groups of buckets | `antigravityLimits…` | `refreshAntigravityLimitsFromKeychain` | n/a until a token path exists | V | hidden by facts (P15); row stays in the inventory |
| P26 | Cursor: auth-expired notice, stale, message, monthly included (used %, cycle end), remaining spend, auto and API usage | `cursorLimits…` | — | 1 / T5 (shows what the store has) | V + S (`TokenFormatter.cost`) | whether they load on Windows: T17 |
| P27 | OpenCode Go: auth-expired, stale, 5 h / weekly / monthly | `openCodeGoLimits…` | — | 1 / T5 | V | T17 |
| P28 | Grok: auth-expired, stale, credit period row, used products line (product name map) | `grokLimits…` | — | 1 / T5 | V + T (`grokProductName`) | T17 |
| P29 | Footer: Refresh (Home only), "Updated <relative>", error triangle with tooltip; pet eye toggle; Settings; Quit | `lastUpdated`, `lastErrorDescription`, `lastErrorMessage(l)`, `floatingPetEnabled` | `refresh()`, `showSettings`, quit | 1 / T5 (eye: 3) | V | Quit → `WindowsApp.exit(0, .menu)` |
| P30 | Navigation state: tabs, settings, recap, collection segment, dex detail, provider and account tabs (kept), expand-advanced, open plaza, routes (`openSessionKeySettings`, `openDexEntry`, `openRepresentativeDex`) | — | — | 1 / T1 | T (`PopoverNavigation`) | `PopoverState` |
| P31 | Locale environment = app language for dates and relative texts | `companion.language` | — | 1 / T1 | S | D10, D11 |

### Companion header (`UI/CompanionView.swift`: `CompanionHeader`, `SpriteView`, `SpriteSubject`, `EvoLineView`, `LabeledProgressBar`, `DexEntryLink`; `UI/Badge.swift`, `UI/PokemonNameLabel.swift`)

| ID | Function | Data | Actions | Tier | Logic | Windows |
|---|---|---|---|---|---|---|
| C1 | Sprite 76 pt: animated GIF at native delays, bob on static fallback, shiny, form, back, egg sprite, 🥚 fallback, rounded backdrop | `currentSpeciesID`, `currentIsShiny`, `currentForm`, `facesBack` | — | 1 / T8 | T (`SpriteSubject`, `frameTaskID`, `needsReload`, `framesToApply`, on `PlazaImage`) + S (fetcher) | D16 |
| C2 | Sprite opens its Pokédex page (hand cursor, hover highlight, tooltip) | `dexLinkTargets` | `openDexEntry` | 3 / T20 | S | inert until the Collection exists (the Mac's `onOpenDexEntry: nil`) |
| C3 | Name, ✨, rarity badge | `displayName`, `rarity` | — | 1 / T9 | S + T (`rarityColor`) | badge part |
| C4 | Type badges with localized type names (loaded async) | `pokemonDetailsByID`, `PokemonNameDisplayStore` | `loadPokemonDetails` | 1 / T9 | S + T (`PokemonType.hex`) | re-render when names arrive |
| C5 | Default-form data note | `currentForm` | — | 1 / T9 | S | — |
| C6 | Stage + nature; growth boost badge | `stageText`, `currentNature`, `growthMultiplier` | — | 1 / T9 | S | — |
| C7 | Growth bar; hovering 300 ms expands it to "X / Y · Z%" | `progress`, `state.active.usedAtStage`, `threshold` | hover | 1 / T9 | T (`progressDetail`) | bar part; the detail is its tooltip and accessible value, not an expanding animation (listed difference) |
| C8 | "N to next evolution / to graduation" | `tokensToNext`, `isFinalStage` | — | 1 / T9 | S | — |
| C9 | Egg: incubating / imminent (orange), guarantee badge, egg bar with detail, hatch delayed, tokens to hatch, first-run hint | `isEgg`, `eggProgress`, `eggGuarantee`, `isHatchRetryDelayed`, `eggTokensToHatch`, `eggStarted`, `eggHatchThreshold` | — | 1 / T9 | S + T | — |
| C10 | Status line (egg, idle, working, focus, tired, sleep, sulk, evolved or grew) | `displayState`, `justEvolvedTo` | — | 1 / T9 | T (`statusLine`) | — |
| C11 | Evolution line: done/current/future, current dot, arrows, "?" node; horizontal scroll with edge fade and page chevrons when wider than the content | `lineNodes` | chevrons; node links (3) | 1 / T9 | T (`rowWidth`, `needsScroll`, `scrollAffordance`, `pageTarget`, `dexLinkTarget`) | part with chevron button items |
| C12 | "Graduated: X" line | `justGraduated` | — | 1 / T9 | S | — |
| C13 | Load details and form names on subject change | — | `loadPokemonDetails`, `loadActiveFormNames` | 1 / T9 | S | — |
| C14 | Celebrations: flash + spring, ✨, 🎭, +XP, mint sparkles, egg wiggle; one-shot consume | `celebration(Seq)`, `candyFeedback…`, `mintFeedback…` | `consume…` | 1 / T9 | S + V | D16 |

### Collection (`UI/CompanionView.swift`: `CollectionView`, `DexGridView`, `DexSpeciesCell`, `DexEntryRow`, `DexSummaryHeader`, `RarityTally`, `RegionTally`, `DexBadgeMedal`, `DexPageButton`, `DexScrollPager`, `ScrollWheelPager`, `RepresentativeFooterButton`, `PokemonDetailView`) — all tier 3

| ID | Function | Data | Actions | Logic | Windows |
|---|---|---|---|---|---|
| D1 | Empty state: animated Pikachu, title, hint | `dexEntries` | — | S | T20 |
| D2 | Segment Pokédex / Catch log | `nav.showingCollectionLog` | select | S | radio pair |
| D3 | Filter bar: search (placeholder, clear), shiny-only toggle, sort menu (dex or log options, checkmarks, accent when custom) | local state | filter, sort | S (`filteredDexSpecies`, `filteredDexEntries`, sort options) | `EDIT` + glyph buttons + popup menu |
| D4 | Dex header: title, species total, earned medals (🌍 🔤 ✨) with tooltips, region chips (progress, ✨/🏅, filter, disabled at 0), rarity chips | `dexSpecies`, `dexCompletions`, `earnedDexBadges` | filter | S + T (`rarityDisplayOrder`, medal emoji) | chip parts with button items |
| D5 | 4 × 4 page grid; wheel/touchpad paging; cells (#id in rarity colour, representative star, static 56 pt sprite, name + form count, ✨, RAISING badge, representative backdrop, selected border, hover lift, tooltip, context menu); footer (selection line, representative button, page arrows "n / m"); Back restores the page | `dexSpecies`, `isRepresentative`, `collectedForms` | select, page, set representative | T (`DexScrollPager` on Windows wheel deltas, page math) | owner-drawn buttons; `WM_CONTEXTMENU` |
| D6 | Catch log: summary header (total, rarity chips), lazy list rows (rarity, RAISING/RELEASED, ✨, nature, chain sprites with names, caught relative time), scroll to top on filter change, Back restores the row | `dexEntries`, `dexStoredChainNames`, `dexResolveChainNames` | open entry | S | virtualized owner-drawn list (`LBS_OWNERDRAWVARIABLE`) |
| D7 | Detail page: Back, #id; form grid (collected x of y, disabled uncollected, representative backdrop, selected border); appearance normal/✨; identity header (104 pt animated sprite, name, rarity, types, form note, shiny, raising, representative); individual picker; individual section (level, gender, nature, prayers, ability (+hidden), computed stats with IV, moves) or base stats; species data (height, weight, BST, abilities); full move list; unavailable + Retry; loading | `formSpecies`, `pokemonIndividuals`, `pokemonDetailsByID`, `PokemonStatCalculator` | select, retry, set representative | S + T (`formPickerColumns`) | T21 |
| D8 | Representative: set or follow current (grid footer, context menu, detail, Settings) | `representativeSpeciesID` | `setRepresentativeSpeciesID(_:form:)` | S | T20 |

### Shop and Bag (`UI/ShopView.swift`, `UI/BagView.swift`, `ItemIconView`) — all tier 3

| ID | Function | Data | Actions | Logic | Windows |
|---|---|---|---|---|---|
| H1 | Wallet: spendable tokens, hint | `availableTokens` | — | S | T19 |
| H2 | Item cards: icon (PokéAPI item sprite, emoji fallback), name, owned count, quantity stepper to `maxBuyCount`, description, "owned" for passive items, price × quantity, Buy → inline confirm (Buy ×n / Cancel), "not enough tokens" | `shopEntries`, `price(of:)`, `canBuy`, `itemCount` | `buy(_:count:)` | S | up-down + inline button swap (no dialog, as the Mac) |
| H3 | Egg cards: egg sprite, tier badge, description, release note, price, disabled Buy + locked hint as an egg, confirm, second warning for shiny/legendary (orange), then Home | `canBuyEgg`, `isHighValueCompanion` | `buyEgg` | S | — |
| B1 | Empty bag: animated Snorlax, title, "Shop" button | `ownedItems` | tab shop | S | — |
| B2 | Item cards: icon, ×count, candy stepper to `maxRareCandyUseCount`, description, candy preview (graduates, discarded XP orange, carry-over), passive effect, Use → confirm (Use ×n) → Home; disabled reasons | `planRareCandyUse`, `canUseRareCandy`, `canUseMint` | `useRareCandy`, `useMint` | S | the item icon needs a shared port of `SpriteLoader.itemImage` |

### Recap (`UI/UsageRecapView.swift`) — tier 2 / T13

| ID | Function | Data | Actions | Logic | Windows |
|---|---|---|---|---|---|
| R1 | Recap page: Back (Esc), week/month/year segments (reset offset), previous / current / next period (`canGoBack`, offset ≤ 0) | `RecapScope` | navigate | S (`UsageRecap`, `RecapPeriod`) | radio group + buttons |
| R2 | Recap card (Pokédex shell, lens, LEDs, period title, LCD total, unit, ▲▼ delta chip, 8-block meters per bucket with labels, current highlighted, per-bucket tooltip and accessibility, best day / best streak / active days / graduates, strip with the current companion and up to 4 graduates with ✨) | `RecapContent` | hover | T (`RecapContent`) | drawn part (fixed colours, as the Mac), `PlazaFont.mono` |
| R3 | Best-day line, "compared so far" note; backfill dex names | `recap` | — | S | statics |

### Settings (`UI/SettingsView.swift`, `UI/DifficultySettingsSection.swift`, `Team/UI/TeamSettingsSection.swift`)

| ID | Function | Data | Actions | Tier | Logic | Windows |
|---|---|---|---|---|---|---|
| G0 | Page: header Back (Esc) + title; scroll; footer version · GitHub · website · ♥ sponsor | `appVersion` | back, open links | 1 / T6 | – | `WindowsInstall.version`; links through `PlatformShell` |
| G1–G8 | General: language, representative, refresh interval, animation quality, limit display, trend period, tracked account, launch at login | see D12 | see D12 | per D12 | S | D12 |
| G9 | Difficulty sliders + Save | `growthDifficulty`, `shopDifficulty` | `setGrowthDifficulty`, `setShopDifficulty` | 2 / T15 | T (`DifficultyDraft`) | trackbars |
| G10 | Menu bar group + "all off" hint | `showTokensInMenu` … `menuLimitColorMode` | toggles | n/a | S | open question 6 |
| G11 | Tracked providers + hint | `registeredProviders`, `isProviderEnabled` | `setProviderEnabled` | 1 / T6 | S | check boxes |
| G12 | Floating pet group (enable, back view, size, bubble alerts, agent activity) | pet keys | toggles, slider | 1 (back view) / 3 | S | D12 |
| G13 | Team: enable; masked code + Copy + Leave; team name (commit rules); switch menu (saved teams, step out); create; join (invalid error; open the plaza when ready, else after the nickname); saved teams "enter"; nickname (commit rules, invalid error); team notifications; core time (start 1–22, end start+1–23) and season, caption (default or "changed by X on date"); incompatible-peer warning | `TeamSettings`, `TeamSession.hasIncompatiblePeer` | all of them | 1 / T6 | M (`join`, `committedDraft`, `masked`) + S | D5 fields; Korean wording |
| G14 | Notifications: limit alerts, warn and critical sliders with %, companion alerts, status checks + hint | `limitNotifications`, thresholds, `companionNotifications`, `statusChecksEnabled` | toggles, sliders | 1 / T6 | S | balloons are the delivery (Track B) |
| G15 | Updates: notifications toggle, Check now (spinner; forced), offer / skipped (show again, update) / up to date | `updater.settingsNotice` | `check(minInterval: 0)`, `applyUpdate`, `showSkippedAgain` | 1 / T6 | S | — |
| G16 | Backup & transfer: export (save dialog, reveal, error alert), import (open dialog, decode, confirm with both summaries, Cancel default, apply, done/error), create snapshot (+alert), snapshot history disclosure with rows (28 pt sprite, date, dex + tokens, Restore → confirm → done/error) | `suggestedExportFileName`, `exportedSaveData`, `transferSummary`, `availableSnapshots` | `applySave`, `createManualSnapshot`, `restoreSnapshot`, `refreshSnapshots` | 2 / T15 | S (`SaveTransfer`, `SaveSummary`, `ImportConfirmPolicy`) + T | D17 |
| G17 | Advanced disclosure (opens expanded, scrolled and focused from a session-key notice): session key (badge expired/saved, hint (+per-account note), masked field, Save (validating), Delete, org picker when > 1, error or storage note; orgs refreshed on expand); per-account keys; disable Keychain (n/a); refresh limit token + hint + message; additional Claude folders (detected list, field, found count; commit rules); custom scan roots (provider picker, field, match count with 250 ms debounce off-main; commit on provider change, focus loss, collapse, close); aggregation note | session-key members, `additionalClaudeConfigDirs`, `customScanRoots(for:)`, `detectedClaudeConfigDirs` | `saveSessionKey`, `clearSessionKey`, `selectSessionOrganization`, `refreshSessionOrganizations`, `saveAccountSessionKey`, `clearAccountSessionKey`, `setCustomScanRoots`, `refreshLimitTokenFromKeychain` | 2 / T14 | S + V | D5, D13, D14 |
| G18 | About & support: report a problem (mail with version and OS; fallback address, selectable), show log file | `SupportMail` | open mail, reveal log | 1 / T6 | S | `mailto:` via the shell; Explorer `/select,`; the fallback address in a read-only `EDIT` (selectable) |

### Floating pet (`UI/FloatingPetPanel.swift`) — tier 3 / T22–T23

| ID | Function | Windows |
|---|---|---|
| F1 | Always-on-top borderless pet window, size, saved origin, drag, click → popover (egg: pray), right-click menu (open, hide, back view), low power and display-sleep pauses, reduce motion, `capFrameRate` at the animation-quality floor | `WS_EX_LAYERED \| WS_EX_TOPMOST \| WS_EX_TOOLWINDOW` (Track B D2), `UpdateLayeredWindow` |
| F2 | Speech bubbles (limit alerts, agent activity), hearts after strokes, prayer emoji bursts, agent bob, run to cursor, hover callout | T23 |

### Helper files with no screen

`UI/MenuBarContent.swift`, `UI/MenuLimitColoring.swift`, `UI/StandardEditMenu.swift`: n/a (A1, A5). `UI/SpriteAnimation.swift` (`GIFDecoder`): `PlazaGIFDecoder` (S); `capFrameRate` is a twin for the pet (T22). `UI/SpriteLoader.swift`: `PlazaStoreSpriteFetcher` + `PlazaEggCrop` (S), item images (T19). `UI/UsageCostText.swift`: `UsageCost.text` (S). `UI/ActivityVisualization.swift`: P9.

---

## Interfaces (the contract later tasks rely on)

Signatures, not bodies. Shared files in `Sources/PokeTokenBar/Popover/` unless marked; Windows files in `Sources/PokeTokenBar/Platform/Windows/Popover/`.

```swift
// ---- Shared seams (Platform/, both OSes) ----

// Platform/RegionFormat.swift (Task 1)
enum RegionFormat {
    static func firstWeekday(windowsValue: Int) -> Int?          // LOCALE_IFIRSTDAYOFWEEK 0…6 (Mon…Sun) → 1…7 (Sun…Sat)
    static func locale(windowsName: String?) -> Locale?           // "ko-KR" → ko_KR; empty or invalid → nil
}
extension PlatformCompat {                                         // Task 1 (Mac branches: exactly today's expressions)
    static var regionLocale: Locale { get }
    static var firstWeekday: Int { get }
    static func regionCalendar(timeZone: TimeZone) -> Calendar
    static func writeSecret(_ data: Data, to url: URL) throws     // Task 14, only with DPAPI (D14)
    static func readSecret(at url: URL) -> Data?
}

// Team/TeamSetup.swift (Task 1; moved from Team/UI/TeamSettingsSection.swift, which then calls it)
enum TeamSetup {
    enum JoinResult: Equatable { case invalid, openPlaza, needsNickname }
    @MainActor static func join(_ draft: String, into team: TeamSettings) -> JoinResult
    @MainActor static func committedDraft(_ draft: String?, into team: TeamSettings) -> String?
    static func masked(_ code: TeamCode) -> String                // "PTB-ABCDE-•••••-…"
}

// Platform/WindowsPopoverStrings.swift (Tasks 5, 6, 14): extension L { var win… } in 8 languages (D13)

// ---- Shared popover logic (Popover/, both OSes; the Mac app does not call it) ----

@MainActor @Observable final class PopoverState {                  // Task 1: twin of PopoverNavigation (P30)
    enum Tab: Equatable { case home, shop, bag, collection }
    var showSettings: Bool; var tab: Tab; var showingCollectionLog: Bool; var showingRecap: Bool
    var dexDetailCollectionID: String?; var providerID: String?; var claudeAccountID: String?
    var expandAdvancedOnOpen: Bool; var onOpenPlaza: (() -> Void)?
    func reset(); func openSessionKeySettings(); func openDexEntry(collectionID: String); func openRepresentativeDex()
}

enum RelativeTimeText {                                            // Task 1 (D10)
    static func text(for date: Date, now: Date, language: AppLanguage) -> String
    static func nextChange(for date: Date, now: Date) -> Date
}

struct PopoverPlatformFacts: Equatable {                           // Task 2 (D8)
    var hasKeychain: Bool; var antigravityLimitsAvailable: Bool; var floatingPetAvailable: Bool
    var regionLocale: Locale; var regionCalendar: Calendar
    static let mac: PopoverPlatformFacts
    @MainActor static var current: PopoverPlatformFacts { get }
}
enum PopoverColorRole: Equatable { case systemBlue, systemTeal, systemGreen, systemYellow, systemOrange, systemRed, systemGray,
                                   accent, primary, secondary, tertiary, palette(Int), heatmap(level: Int) }

struct LimitRowModel: Equatable {                                  // Task 2 (P23)
    var name: String; var detail: String?; var reset: Date?; var resetClock: String?; var idleHint: String?
    var percentText: String; var percentColor: PopoverColorRole; var fillPercent: Double; var tint: PopoverColorRole
    var paceMarker: Double?; var help: String?
}
enum LimitsBlock: Equatable {                                      // Task 2: the section, top to bottom, as the Mac's body
    case notice(NoticeModel), refreshRow(RefreshRowModel), accountTabs([CapsuleTab], selected: String?)
    case caption(String, help: HelpModel?), plan(String), accountLabel(String), accountUsage(PeriodPair, PeriodPair)
    case bucketLabel(String), row(LimitRowModel, dimmed: Bool), forecast(ForecastModel), currentBlock(CurrentBlockModel)
    case stale(since: Date), message(String), products(String), unattributed(String)
}
struct HomeModel: Equatable {                                      // Task 2
    var updateBanner: UpdateBannerModel?; var plazaButton: PlazaButtonModel?
    var header: HeaderModel; var providerTabs: [CapsuleTab]; var providerRow: ProviderRowModel?
    var statusBanner: StatusBannerModel?; var limits: [LimitsBlock]?; var footer: FooterModel
    @MainActor static func make(store: UsageStore, companion: CompanionStore, updater: UpdateChecker?, team: TeamSettings,
                                feed: TeamFeedStore?, state: PopoverState, facts: PopoverPlatformFacts, now: Date) -> HomeModel
}
enum PopoverFormat {                                               // Task 2: twins of the private helpers (P5)
    static func limitPercentText(_ utilization: Double, mode: UsageStore.LimitDisplayMode, l: L) -> String
    static func resetClockSuffix(_ reset: Date, now: Date, language: AppLanguage, calendar: Calendar) -> String
    static func paceHelp(pace: Double?, tier: PaceTier?, utilization: Double, mode: UsageStore.LimitDisplayMode, l: L) -> String?
    static func grokProductName(_ product: String?) -> String
    static func paceColor(_ tier: PaceTier) -> PopoverColorRole; static func percentColor(_ tier: PaceTier) -> PopoverColorRole
}

struct SettingsModel: Equatable {                                  // Task 6 (+14, 15): one value per D12 row shown on Windows
    @MainActor static func make(store: UsageStore, companion: CompanionStore, updater: UpdateChecker?, team: TeamSettings,
                                session: TeamSession?, login: TrayMenuModel.LoginState, facts: PopoverPlatformFacts) -> SettingsModel
}

@MainActor protocol PopoverPart: AnyObject {                       // Task 3 (D7)
    func size(width: CGFloat, scale: CGFloat, text: any PlazaTextEngine) -> CGSize
    func render(scale: CGFloat, graphics: any PlazaGraphics) -> PopoverDrawing
    func hit(_ point: CGPoint) -> PlazaPanelHit?
    var onChange: (() -> Void)? { get set }
}
struct PopoverDrawing { var drawing: PlazaPanelDrawing; var spriteSlots: [SpriteSlot] }
struct SpriteSlot: Equatable { var frame: CGRect; var subject: PlazaSpriteSubjectKey?; var bob: Bool; var animated: Bool }

final class LimitBarPart: PopoverPart; final class BadgePart: PopoverPart        // Task 5
final class CompanionHeaderPart: PopoverPart; final class EvoLinePart: PopoverPart; final class GrowthBarPart: PopoverPart  // Task 9
final class TrendBarsPart: PopoverPart; final class HeatmapPart: PopoverPart; final class StreakPart: PopoverPart          // Task 12
final class RecapCardPart: PopoverPart                                                                                     // Task 13

struct CompanionHeaderModel: Equatable { … @MainActor static func make(companion: CompanionStore) -> CompanionHeaderModel
                                         static func progressDetail(used: Int, total: Int) -> String }   // Task 9
enum EvoLineLayout { static func rowWidth…; static func needsScroll…; static func scrollAffordance…; static func pageTarget…
                     static func dexLinkTarget… }                                                        // Task 9 (twins)
struct PopoverSpriteSubject: Equatable { … the SpriteSubject transitions on PlazaImage … }               // Task 8 (twin)
enum PopoverTrendMetrics { … }; enum PopoverTrendHover { … }; enum PopoverHeatmapMetrics { … }           // Task 12 (twins)
struct PopoverRecapContent { … }                                                                         // Task 13 (twin)
struct PopoverDifficultyDraft: Equatable { … }                                                           // Task 15 (twin)

enum PopoverPlacement {                                            // Task 4 (D2)
    enum Edge: Equatable { case bottom, top, left, right }
    static func taskbarEdge(monitor: CGRect, work: CGRect, appBar: CGRect?) -> Edge
    static func frame(anchor: CGRect?, clickPoint: CGPoint?, size: CGSize, monitor: CGRect, work: CGRect,
                      edge: Edge, margin: CGFloat) -> CGRect
}
struct PopoverToggleGuard {                                        // Task 4 (D3)
    mutating func noteClosedByDeactivation(at time: TimeInterval, cursorInAnchor: Bool)
    func opensOnSelect(at time: TimeInterval) -> Bool               // false within 0.5 s of a close caused by a click on the icon
}
@MainActor final class PopoverClock { func setDeadlines(_ dates: [Date]); var onTick: (() -> Void)? }     // Task 5 (D10)
@MainActor final class PopoverAnimationClock { func setDue(_ next: Date?); var onTick: (() -> Void)? }    // Task 8 (D16)

// ---- Windows only (#if os(Windows)) ----

@MainActor final class WinPopover {                                // Task 4
    init(host: WinPopoverHost)
    enum Opener: Equatable { case trayClick(POINT), trayKey, trayMenu, secondLaunch }
    enum CloseReason: Equatable { case deactivated, escape, iconClick, plaza, quit, lock, destroyed }
    func toggle(_ opener: Opener)
    func present(_ opener: Opener, route: (PopoverState) -> Void)   // the only activation site (scan)
    func close(_ reason: CloseReason)
    var isOpen: Bool { get }; var hwndForTesting: HWND? { get }; var stats: WinPopoverStats { get }
}
@MainActor final class WinPopoverHost { init(store:companion:updater:team:session:feed:tray:loginItem:openPlaza:) }  // Task 4
@MainActor final class WinUIContext { let dpi: UINT; let fonts: WinFonts; let colors: WinUIColors; let tooltips: WinTooltips }  // Task 3
@MainActor final class WinStack; final class WinSectionCard; final class WinScrollArea                                   // Task 3
@MainActor final class WinDrawnView { init(parent: HWND, ctx: WinUIContext); func show(_ drawing: PopoverDrawing)
                                      var onHit: ((PlazaPanelHit) -> Void)?; var sprites: WinSpriteAnimator? }           // Task 3/8
@MainActor enum WinControls {                                                                                           // Task 3
    static func label, button, glyphButton(symbol:label:), checkbox, radioGroup, combo, edit(_: WinEditKind), trackbar,
               stepper, link, tabs
}
enum WinGlyphs { static func codePoint(symbol: String, fluent: Bool) -> UInt16? }   // SF Symbol name → Fluent / MDL2 (Task 3)
@MainActor final class WinSpriteAnimator { func update(slots: [SpriteSlot], in view: WinDrawnView) }                   // Task 8
enum WinSecret { static func protect(_ data: Data) -> Data?; static func unprotect(_ data: Data) -> Data? }           // Task 14
@MainActor enum WinFileDialog { static func save(owner: HWND, title: String, defaultName: String) -> URL?
                                static func open(owner: HWND, title: String) -> URL? }                                  // Task 15
@MainActor enum WinTaskDialog { static func confirm(owner: HWND, title: String, body: String, confirm: String, cancel: String) -> Bool
                                static func inform(owner: HWND, title: String, body: String, close: String, warning: Bool) }  // Task 15
@MainActor enum WinTextClipboard { static func set(_ text: String) -> Bool }                                          // Task 6
extension WinMessageHook { static func unregisterDialogWindow(_ hwnd: HWND) }                                         // Task 3
```

```c
// CWinShim/include: Task 15
int ptb_file_dialog(void *owner, int save, const uint16_t *title, const uint16_t *defaultName,
                    uint16_t *outPath, uint32_t outCap);   // 1 = chosen, 0 = cancelled, < 0 = HRESULT failure (logged by Swift)
```

---

## File Structure

```
Sources/PokeTokenBar/Popover/                                create (shared, fork-owned; the Mac app does not call it)
  PopoverState.swift, RelativeTimeText.swift (T1); PopoverPlatformFacts.swift, PopoverColorRole.swift, PopoverFormat.swift,
  HomeModel.swift, LimitsModel.swift (T2); PopoverPart.swift (T3); PopoverPlacement.swift, PopoverToggleGuard.swift (T4);
  PopoverClock.swift, LimitBarPart.swift, BadgePart.swift (T5); SettingsModel.swift (T6, T14, T15);
  PopoverSpriteSubject.swift, PopoverAnimationClock.swift (T8); CompanionHeaderModel.swift, CompanionHeaderPart.swift,
  EvoLineLayout.swift, EvoLinePart.swift, GrowthBarPart.swift (T9); PopoverTrendMetrics.swift, TrendBarsPart.swift,
  HeatmapPart.swift, StreakPart.swift (T12); PopoverRecapContent.swift, RecapCardPart.swift (T13); PopoverDifficultyDraft.swift (T15)
Sources/PokeTokenBar/Team/TeamSetup.swift                   create (T1)
Sources/PokeTokenBar/Team/UI/TeamSettingsSection.swift      modify (T1): calls TeamSetup (behaviour identical)
Sources/PokeTokenBar/Platform/RegionFormat.swift            create (T1)
Sources/PokeTokenBar/Platform/PlatformCompat.swift          modify (T1 region seams; T14 secret seams): append-only
Sources/PokeTokenBar/Platform/WindowsPopoverStrings.swift   create (T5), grows (T6, T14)
Sources/PokeTokenBar/Platform/TrayMenuModel.swift           modify (T4): .openSettings, .toggleBackView
Sources/PokeTokenBar/Platform/OAuthKeychainUnavailable.swift modify (T6): missing file on a user refresh → credential-missing error
Sources/PokeTokenBar/Core/UsageRecap.swift                  modify (T1): one line, PlatformCompat.firstWeekday
Sources/PokeTokenBar/Core/SessionKeyLimitsProvider.swift    modify (T14, only with DPAPI): two lines, PlatformCompat.read/writeSecret
Sources/PokeTokenBar/Team/Plaza/Draw/PlazaText.swift         modify (T13): PlazaFont.mono (+ Mac CoreText and Windows DirectWrite mapping)
Sources/PokeTokenBar/Platform/Windows/
  Popover/ WinUIContext.swift, WinFonts.swift, WinUIColors.swift, WinControls.swift, WinGlyphs.swift, WinStack.swift,
           WinScrollArea.swift, WinDrawnView.swift, WinTooltips.swift (T3); WinPopover.swift, WinPopoverHost.swift,
           WinPopoverAnchor.swift (T4); WinHomePage.swift, WinLimitsSection.swift (T5); WinSettingsPage.swift,
           WinTeamSection.swift, WinTextClipboard.swift (T6); WinSpriteAnimator.swift (T8); WinCompanionSection.swift (T9);
           WinActivitySection.swift (T12); WinRecapPage.swift (T13); WinAdvancedSection.swift, WinSecret.swift (T14);
           WinTransferSection.swift, WinFileDialog.swift, WinTaskDialog.swift (T15); WinDarkMode.swift (T16)
  WinMessageHook.swift                                       modify (T3): unregisterDialogWindow
  WinTray.swift, WinTrayHost.swift                           modify (T4): left = popover, right = menu; menu items
  WinSingleInstance.swift, WindowsApp.swift                  modify (T4): AllowSetForegroundWindow + popover on second launch; host wiring
  WindowsShell.swift                                         modify (T6): mailto allowed
  WindowsSelftestPopover.swift                               create (T3–T16): ui.kit.*, popover.*, home.*, settings.*, companion.*
  WinUIDump.swift                                            modify (T5, T6, T9, T12, T13): popover pages
Sources/CWinShim/filedialog.cpp (+ header)                   create (T15)
Tests/PopoverParity/{inventory,strings,members,settings,twins}.txt, mac-colors.json, mac-text-styles.json   create (T1, T2, T3)
Tests/PokeTokenBarTests/
  PopoverParityScanTests.swift                               create (T1; Mac-only scan, listed in mac-only.txt with its reason)
  PopoverTwinEquivalenceTests+Mac.swift                      create (T1), grows per twin
  PopoverStateTests, RelativeTimeTextTests, RegionFormatTests, TeamSetupTests (shared, T1); HomeModelTests, LimitsModelTests,
  PopoverFormatTests (T2); PopoverPlacementTests, PopoverToggleGuardTests (T4); LimitBarPartTests, PopoverClockTests (T5);
  SettingsModelTests (T6); PopoverSpriteSubjectTests, PopoverAnimationClockTests (T8); CompanionHeaderModelTests,
  EvoLineLayoutTests (T9); PopoverTrendMetricsTests, HeatmapPartTests (T12); PopoverRecapContentTests (T13)
  PopoverGoldens+Mac.swift                                   create (T2, T3): writes (env-gated) and re-checks the colour and text-style goldens
  WindowsPopover{Kit,Placement,Secret,Dialog}Tests.swift     create (T3, T4, T14, T15)
.github/workflows/windows-app.yml                            modify (T3: popover selftest group; T10: idle windows; dump-ui pages)
scripts/windows/measure-idle.ps1                             modify (T10): popover park modes
docs/reference/defect-log.md, CONTRIBUTING.md, spec §8/§10/§13   modify (T6, T7, T11, T18)
```

## Review Focus

Five ways this could look done and be wrong:

1. **Parity holes.** A Mac branch, string or setting with no Windows counterpart that nothing flags. Typical: logic inside a private view function, a provider branch, a new upstream setting. → The parity scan with per-section inventory rows; Mac equivalence tests for every twin and view model, fed by the Mac's own predicates; `tier2` = 0 at the end of the stage.
2. **Idle cost where nobody looks.** A popover destroyed but its clock, tooltips, fonts, DIBs or dialog registration left behind. A per-second relative clock that never stops. The GIF clock running behind Settings. `WM_PAINT` not validated. A hover tracker left armed. → Selftest counts after open/close × 3 (timers, GDI/USER objects, handles, hook registrations); the idle windows (D18); fault injection (leave the clock armed → the Settings window fails).
3. **Focus and dismissal.**
   - A popover that steals focus by itself, or opens but is not active (so it never closes).
   - It reopens when the icon is clicked to close it, or does not close when another flyout opens.
   - It appears off screen with the taskbar left/top/auto-hidden, on a second monitor, or for an icon in the overflow.
   → `popover.*` selftest checks with synthetic work areas; the activation scan; PC items over RDP and at the console.
4. **Text entry.**
   - Hangul in the nickname or team name through `IsDialogMessageW` inside the hook (typed twice, or `?`).
   - Enter that does not commit, or commits half a syllable.
   - Pasted codes with spaces.
   - A session key left in the field, logged or shown.
   → `ui.kit.text` (posted chars + `WM_IME_CHAR` at ACP 1252), `settings.teamJoin` with a pasted code, a log scan for `sk-ant-`, PC items with a Korean IME.
5. **Locale and time.** Grouping and first weekday still from `en_001`; relative texts from a formatter missing on Windows; reset clocks in the wrong zone; dates in the region language instead of the app language. → Task 1's first Windows push probes the formatters; `locale.region` selftest line; Mac goldens for day stamps; a capture with `--inject-ui-language ko-KR`.

Also check in every review: the Mac is unchanged (the named Mac pins; `RENDER: identical` when `Team/**` or `PlazaText` is touched).

---

### Task 1: Parity inventory, scan and shared seams **[most capable]** — Size M

**Files:**
- Create:
  - `Tests/PopoverParity/{inventory,strings,members,settings,twins}.txt`, `Tests/PokeTokenBarTests/PopoverParityScanTests.swift` (+ `mac-only.txt` entry with reason), `Tests/PokeTokenBarTests/PopoverTwinEquivalenceTests+Mac.swift`;
  - `Popover/PopoverState.swift`, `Popover/RelativeTimeText.swift`;
  - `Platform/RegionFormat.swift`, `Team/TeamSetup.swift`;
  - shared tests `PopoverStateTests`, `RelativeTimeTextTests`, `RegionFormatTests`, `TeamSetupTests`.
- Modify:
  - `Platform/PlatformCompat.swift` (region seams);
  - `Core/UsageRecap.swift` (one line);
  - `Team/UI/TeamSettingsSection.swift` (calls `TeamSetup`);
  - `Platform/Windows/WinUILanguage.swift` (region reads);
  - `Platform/Windows/WindowsSelftestLanguage.swift` (`locale.region` line).

**Interfaces:** Produces D9, D11, `PopoverState`, `RelativeTimeText`, `TeamSetup`, `RegionFormat`.

**Steps:**
- [ ] **First Windows push, the formatter probe:** a Windows test that prints, for ko/en/ja/fr/ru:
  - `Duration.UnitsFormatStyle` (wide, 2 units);
  - `DateComponentsFormatter`;
  - `DateIntervalFormatter` (`dMMMy`);
  - `setLocalizedDateFormatFromTemplate` for `MdE`, `HHmm`, `EEEEdHHmm`;
  - `NumberFormatter` grouping for `de_DE`, `fr_FR`, `ko_KR`.

  `RelativeTimeText` and Task 13's recap use whatever works; the outputs go into the PR.
- [ ] The extractor (regex over the popover files listed in D9) and its unit tests on synthetic text. Generate the first data files from the Mac sources and classify every row by the inventory above (`win` only for what Tasks 2–6 will implement; the rest `tier2`/`tier3`/`n/a` with reasons).
- [ ] Fault-inject each scan rule once (fake string, deleted row, changed twin, stale row), reverting each; record them.
- [ ] `PopoverState` = twin of `PopoverNavigation`. Mac equivalence test: 200 random action sequences on both give equal fields. Shared tests: the Mac's `PopoverNavigationTests` cases, re-run on the twin.
- [ ] `TeamSetup`: move `join`, `committedDraft`, `masked` and call them from the view. Mac: `TeamSettingsTests` + a new test that the masked text equals the old private function's output on 50 generated codes (kept as a copied oracle in the test). Shared tests on both OSes.
- [ ] Region seams and their Windows reads. The one upstream line in `UsageRecap.swift`; Mac pin: `PlatformCompat.firstWeekday == Calendar.current.firstWeekday`. Selftest `locale.region`: `regionLocale`, `firstWeekday`, and the grouping of 1234567 next to `GetNumberFormatEx`.
- [ ] `RelativeTimeText` + `nextChange`, tested on both OSes (seconds and minutes boundaries, future and past, 8 languages non-empty).
- [ ] Verify (below).
- [ ] **PR `feat(popover): pin the Mac popover's surface and add the shared seams for Windows`**.

**Verify:** `swift test --filter 'PopoverParity|PopoverTwin|PopoverState|RelativeTimeText|RegionFormat|TeamSetup|TeamSettings|UsageRecap|ScanTests'`; `shared-check.sh`; `plaza-render-compare.sh` → identical (`Team/UI` touched); Windows CI green with the shared suites executed and the probe output. **Size:** M. **PC:** no.

---

### Task 2: Home view models in shared code **[most capable]** — Size L

Milestone: full Mac gate after this task.

**Files:**
- Create:
  - `Popover/{PopoverPlatformFacts,PopoverColorRole,PopoverFormat,HomeModel,LimitsModel}.swift`;
  - `Tests/PopoverParity/mac-colors.json`;
  - `Tests/PokeTokenBarTests/PopoverGoldens+Mac.swift`;
  - shared `HomeModelTests`, `LimitsModelTests`, `PopoverFormatTests`.
- Modify: `PopoverTwinEquivalenceTests+Mac.swift`, the parity files.

**Interfaces:** Produces `HomeModel`, `LimitsBlock`, `LimitRowModel`, `PopoverFormat`, `PopoverPlatformFacts`, `PopoverColorRole`; consumes Task 1.

**Steps:**
- [ ] One model function per Mac private func of `PopoverView` (P1, P3, P5, P6, P12–P24, P26–P29), named in a doc comment. Inventory rows switch to `win HomeModel.swift`.
- [ ] Twins of `limitPercentText`, `resetClockSuffix`, `paceHelp`, `grokProductName`, `markerFraction`, `PaceTier.color`/`percentColor` (as roles), `statusColor`.
  - Mac equivalence tests over utilizations 0…120 × both display modes × 9 pace values × 2 thresholds.
  - Resets at −1 min…9 days in 4 time zones × 8 languages.
  - Every `ProviderStatusIndicator`.
- [ ] `PopoverPlatformFacts.mac` reproduces `selectedProviderHasLimits` exactly. Mac test: for 64 store states (each flag on/off), the facts-based gate equals a copied oracle of the Mac's predicate. Windows facts: Antigravity hidden, no Keychain.
- [ ] `mac-colors.json`: written on the Mac (env-gated writer, always-on checker). It holds the SwiftUI system colours and default accent in light (and dark, for Task 16) as sRGB, the trend palette, the heatmap greens, the rarity and type colours. The checker fails when a macOS update changes a value.
- [ ] Fixture-store tests on both OSes: zero usage, one provider, three providers, Claude with two accounts (one expired), Codex two buckets, stale limits, rate-limited refresh message, update offer, team ready with unread.
- [ ] **PR `feat(popover): the Home view models in shared code`**. Body: the twin list with the Mac test that pins each.

**Verify:** filtered suites on the Mac + milestone `test-gate.sh`; Windows CI green with the shared model tests executed. **Size:** L. **PC:** no.

---

### Task 3: The Win32 popover kit **[most capable]** — Size L

**Files:**
- Create:
  - `Platform/Windows/Popover/{WinUIContext,WinFonts,WinUIColors,WinControls,WinGlyphs,WinStack,WinScrollArea,WinDrawnView,WinTooltips}.swift`;
  - `Popover/PopoverPart.swift`;
  - `Tests/PopoverParity/mac-text-styles.json` (+ writer in `PopoverGoldens+Mac.swift`);
  - `Tests/PokeTokenBarTests/WindowsPopoverKitTests.swift`;
  - `Platform/Windows/WindowsSelftestPopover.swift`.
- Modify: `WinMessageHook.swift` (`unregisterDialogWindow`), `.github/workflows/windows-app.yml` (selftest group + `ui-kit` capture).

**Interfaces:** Produces D5, D6, D7 hosts, the control factory, `WinGlyphs`, `PopoverPart`.

**Steps:**
- [ ] **First push, the risky path (R1):** a kit test window (selftest only) holding an `EDIT`, a check box, a combo box and a button, registered as a dialog window.

  | Check | What it proves |
  |---|---|
  | `ui.kit.tabOrder` | `SendInput` Tab × 4 visits them in order |
  | `ui.kit.text` | posted `WM_CHAR` "Aa" + `WM_IME_CHAR` U+D55C at ACP 1252 arrive once each, whole |
  | `ui.kit.enterEscape` | Enter reaches the edit's commit, Escape reaches the window |
  | `ui.kit.unregister` | after destroy the hook holds no stale entry |

  If `IsDialogMessageW` inside the hook misbehaves, the fallback is calling it from our own `WM_KEYDOWN` subclass for Tab/Enter/Escape only; the PR records which path shipped.
- [ ] Controls: label, push button, glyph button (owner-drawn; window text = accessible label; Fluent/MDL2 glyph; focus rect), check box, push-like radio group, combo box (drop list), edit kinds (D5), trackbar + value label, up-down stepper, link, tab control; tooltips (600 ms).
- [ ] Fonts per DPI from `mac-text-styles.json` sizes. Light colours (D15). High-contrast switch (no overrides).
- [ ] `WinStack` / `WinSectionCard` / `WinScrollArea`: D6 layout; wheel; focus-into-view; thumb drag inside `WinModalPump`.
- [ ] `WinDrawnView`: D7, with layers → DIB → `AlphaBlend`; accessibility items → child controls; tooltips → rect tools; hits → `onHit`.
- [ ] `WinGlyphs`: every SF Symbol the Mac popover uses (inventory) → Fluent/MDL2 code points; nil means the caller falls back to text. Test: every symbol in `inventory.txt` maps or is marked.
- [ ] Windows unit tests (no window): glyph table, font size table, the DIB conversion of a fixture `PlazaBitmap` (premultiplied BGRA, row order).
- [ ] Selftest `ui.kit.capture`: a sample page of every control at 100 % and with a synthetic 144 dpi context, captured, tree-dumped, opened by the implementer, put in the PR.
- [ ] Fault-inject: skip the dialog registration → `ui.kit.tabOrder` fails; revert.
- [ ] **PR `feat(windows): the native control kit for the popover`**. Images: the kit sample page (labelled capture).

**Verify:** `windows-app` (light) green with `ui.kit.*` PASS; Windows tests green. **Size:** L. **PC:** no.

---

### Task 4: The popover window, tray clicks and dismissal **[most capable]** — Size M

**Files:**
- Create: `Platform/Windows/Popover/{WinPopover,WinPopoverHost,WinPopoverAnchor}.swift`, `Popover/{PopoverPlacement,PopoverToggleGuard}.swift`, shared `PopoverPlacementTests`, `PopoverToggleGuardTests`.
- Modify:
  - `WinTray.swift` (left/keyboard select → popover, right → menu, the v4 click point);
  - `WinTrayHost.swift` (menu items `.openSettings`, `.toggleBackView`; open-state refresh);
  - `Platform/TrayMenuModel.swift` + `TrayMenuModelTests` (both OSes);
  - `WinSingleInstance.swift`, `WindowsApp.swift` (host, second launch);
  - `WindowsSeamScanTests` (activation scan);
  - `AppWiringDriftScanTests` (tray actions versus `StatusItemMenu`);
  - `WindowsSelftestPopover.swift`.

**Interfaces:** Produces D2, D3, D4, `WinPopover`, `PopoverPlacement`, `PopoverToggleGuard`.

**Steps:**
- [ ] Shared tests first. Placement: 4 edges × 2 monitors (one at negative x) × auto-hide × a work area smaller than the popover × a missing anchor (click point, then corner). Toggle guard: close-then-select at 100 ms (no open) and at 700 ms (open); a deactivation with the cursor elsewhere (open).
- [ ] Window and lifetime: create on present at the anchor monitor's DPI with an empty page (Task 5 fills Home); destroy on close; dialog (un)registration; generation guard.
- [ ] Selftest group `popover.*`:

  | Check | What it does |
  |---|---|
  | `popover.open` | a synthetic `NIN_SELECT` with a CI-granted foreground → visible, foreground, inside the work area |
  | `popover.placement` | the four edges by synthetic work areas (window rect read back) |
  | `popover.dismissOnActivate` | another window activated → destroyed within 200 ms |
  | `popover.toggle` | click on the icon while open → closed, not reopened |
  | `popover.escape` | Escape closes |
  | `popover.noSelfOpen` | a refresh, a balloon and a team event in a row → never opened |
  | `popover.refusedForeground` | `SetForegroundWindow` stubbed false → no window, menu fallback logged |
  | `popover.openClose3` | three open/close cycles: windows, GDI and USER objects, handles and timers back to start (+10 handles, +5 GDI at most) |
  | `popover.secondLaunch` | the selftest's second process → popover open and foreground |

- [ ] Fault-inject twice, reverting each: drop the owned-window exception → a later Task 15 dialog would close the popover (simulate with an owned test window → `popover.ownedKeepsOpen` fails); drop the guard → `popover.toggle` fails.
- [ ] Defect protocol for the left-click change? Not a defect; it is a user-visible change: list it in the PR and the Task 7 checklist (open question 2).
- [ ] **PR `feat(windows): open a popover from the tray icon`**. Images: an empty popover anchored at the runner's tray (labelled capture), the four placements (synthetic).

**Verify:** `windows-app` full (idle unchanged after open/close) green; shared placement tests on both OSes; Mac scan suites green. **Size:** M. **PC:** no (Task 7).

---

### Task 5: The Home page on Windows — Size L

**Files:**
- Create:
  - `Platform/Windows/Popover/{WinHomePage,WinLimitsSection}.swift`;
  - `Popover/{PopoverClock,LimitBarPart,BadgePart}.swift`;
  - `Platform/WindowsPopoverStrings.swift` (first `win…` strings: the credentials-file help);
  - shared `LimitBarPartTests`, `PopoverClockTests`.
- Modify: `WinPopover.swift`, `WinUIDump.swift`, `WindowsSelftestPopover.swift`, the parity files.

**Interfaces:** Consumes Tasks 2–4. Produces the Home page (P1, P3–P6, P12–P24, P26–P29) and the relative-time clock.

**Steps:**
- [ ] Failing shared tests:
  - `LimitBarPart` pixels at scale 1 and 2: fill width from `fillPercent`, tint role, a marker 2.5 × 10 pt centred on the 6 pt track and clamped at both ends; drawn identically by `CGPlazaCanvas` (Mac, for the PR image) and `WinPlazaCanvas` within ±2.
  - `PopoverClock` deadlines: minutes, seconds, none → no timer.
- [ ] The page, built from `HomeModel` with D10's delta apply. Limit rows: labels, percent text in its colour, the bar part with tooltip and the accessible value `"<name> <percent>"`.
- [ ] Fixture limits for captures: `--dump-ui` builds the stores with fixture providers and a `URLProtocol`-free canned `LimitsProviderFactory` (selftest only).
  - Pages: zero usage; 3 providers with Claude two accounts; Codex buckets; stale + rate-limited; update offer; Korean (`--inject-ui-language ko-KR`).
  - The tree checks (D19) pass for each.
- [ ] Footer actions: refresh, settings (Task 6 page; a placeholder until it lands), quit. Plaza button opens the plaza and closes the popover.
- [ ] Selftest:
  - `home.updatesOnRefresh`: a store change re-renders only the changed rows (render counts);
  - `home.relativeClock`: armed at the minute boundary, stopped on close.
- [ ] **PR `feat(windows): the popover's usage and limits page`**. Images: each fixture page, Windows capture next to the Mac's render of the same fixture (the Mac rendering tests' harness, offscreen).

**Verify:** `windows-app` green with `home.*` PASS; shared tests on both OSes; the parity counts move (`win` up). **Size:** L. **PC:** no.

---

### Task 6: Settings essentials and team setup on Windows — Size L

Milestone: full Mac gate after this task.

**Files:**
- Create: `Platform/Windows/Popover/{WinSettingsPage,WinTeamSection,WinTextClipboard}.swift`, `Popover/SettingsModel.swift`, shared `SettingsModelTests`.
- Modify: `Platform/WindowsPopoverStrings.swift`, `WindowsShell.swift` (`mailto:`), `Platform/OAuthKeychainUnavailable.swift` (P14), the parity files, `WinUIDump.swift`, `WindowsSelftestPopover.swift`, `docs/reference/defect-log.md`.

**Interfaces:** Produces the D12 tier-1 rows (G0, G1, G3, G5, G8, G11, G12 back view, G13, G14, G15, G18).

**Steps:**
- [ ] Failing shared tests for `SettingsModel`:
  - the D12 visibility per facts (Mac facts show the Keychain row and the menu bar group; Windows facts do not);
  - the team rows for no code / a code / saved teams / an invalid nickname / an incompatible peer;
  - the schedule caption.
- [ ] Team section: D5 fields with the Mac's commit points, the masked code + Copy (`WinTextClipboard`), Leave, the switch menu (`TrackPopupMenu` inside `WinModalPump`), create, join with `TeamSetup.join`, and opening the plaza when ready or after the nickname.
  - Selftest:
    - `settings.teamJoin`: a pasted `" PTB-…\r\n"` joins;
    - `settings.nicknameHangul`: posted Hangul nickname, committed on focus loss;
    - `settings.openPlazaAfterNickname`.
- [ ] Defect protocol for P14 (the misleading "try again shortly" when no credentials file exists):
  - root cause, and why no test saw it (the Windows test pinned the error *kind*, not the user's text);
  - reachability: yes, a Windows user without Claude Code presses Refresh;
  - fix: the user-refresh path throws the credential-missing error. Check every `UsageStore` branch on that error, including `isKeychainPromptDeclined` and additional accounts;
  - a test of the shown text, a fault injection, and a `defect-log.md` line under the Windows Foundation class.
- [ ] Windows wording rows (D13): help text, the "Explorer" button, storage note placeholder for Task 14, the report-mail body checked for Mac-only words.
- [ ] Launch at login: check box over `WindowsLoginItem`, the Task Manager hint, read on page open.
- [ ] Captures: Settings top, scrolled to Team (no code / joined), Notifications, Updates (offer, up to date), Korean.
- [ ] **PR `feat(windows): settings and team setup in the popover`**. Images: each capture next to the Mac's Settings render.

**Verify:** `windows-app` green with `settings.*` PASS; Mac filtered suites + milestone gate; parity: every tier-1 row of G is `win`. **Size:** L. **PC:** no.

---

### Task 7: Milestone 7.1 on the user's PC — setup without the command line — Size S

**Files:** spec §10 (7.1 row), `docs/reference/defect-log.md`.

**Steps:**
- [ ] The lead sends the installer link and this checklist (Korean wording is the lead's). The companion is not in the popover yet (said up front).
  1. `winver`, display scale(s), whether over RDP or at the console. Taskbar position.
  2. Left click on the tray icon (also from the ^ overflow) → the popover opens above the icon and is active; click the icon again → closes; click the desktop, another app, Start, the clock or Wi-Fi flyout → closes; Escape closes. Right click → the menu.
  3. Start menu → PokeTokenBar while it runs → the popover opens.
  4. Today/week/month numbers and grouping look right for the PC's region (e.g. `1,234,567`); limits show if Claude Code is signed in; "Refresh" works; "Updated … ago" ticks.
  5. Settings: change language (the popover and the tray menu follow), refresh interval, limit display; turn launch at login on/off (Task Manager → Startup shows it).
  6. Team: create a team or paste a Mac teammate's code, type a Korean nickname with the IME, the plaza opens, the Mac sees the member. Leave and join again.
  7. Keyboard only: Tab through Home and Settings, Space/Enter toggles, Escape goes back from Settings.
  8. Narrator (Win+Ctrl+Enter): it reads the tabs, buttons, check boxes and limit rows.
  9. 125 % and 150 % scale: crisp text, nothing cut off.
  10. `--selftest` → send `st.json` (`popover.*`, `locale.region`).
- [ ] Record the answers; each failure goes through the defect protocol in its own fix PR before Task 9.
- [ ] **PR `docs: record the first Windows popover check`**.

**Size:** S. **PC:** **yes**.

---

### Task 8: Sprites and animation in the popover — Size M

**Files:**
- Create: `Platform/Windows/Popover/WinSpriteAnimator.swift`, `Popover/{PopoverSpriteSubject,PopoverAnimationClock}.swift`, shared tests.
- Modify: `WinDrawnView.swift`, `WindowsSelftestPopover.swift`, `PopoverTwinEquivalenceTests+Mac.swift`.

**Interfaces:** Produces D16's sprite path and clock.

**Steps:**
- [ ] Twin of `SpriteSubject` on `PlazaImage`, with `frameTaskID`, `needsReload` and `framesToApply` (P5). Mac equivalence over the Mac's `SpriteSubjectTests` cases. Shared tests for cancellation (a cancelled load changes nothing; an egg → species → egg sequence never shows the old species).
- [ ] `PopoverAnimationClock`: next-due scheduling across slots; tests with an injected scheduler (3 slots with 0.05/0.1/0.07 s delays → tick times; a hidden slot → no ticks; none → no timer).
- [ ] `WinSpriteAnimator`: fetch through `PlazaStoreSpriteFetcher` off the main thread; pre-scale frames nearest at the view's DPI; invalidate only slot rects; bob; 🥚 fallback; frames freed on close.
- [ ] Selftest:
  - `companion.spriteFrames`: over 3 s with the fixture GIF, ticks equal the GIF's frame count ± 2, paint area per tick = slot area;
  - `companion.clockStops`: the Settings page → 0 ticks in 3 s; close → no timer.
- [ ] Fault-inject: invalidate the whole window per frame → the paint-area check fails; revert.
- [ ] **PR `feat(windows): animated sprites in the popover`**. Images: frames of the fixture sprite at 100 % and 150 % (capture).

**Verify:** `windows-app` full green; shared tests on both OSes. **Size:** M. **PC:** no.

---

### Task 9: The companion header **[most capable]** — Size L

**Files:**
- Create: `Popover/{CompanionHeaderModel,CompanionHeaderPart,EvoLineLayout,EvoLinePart,GrowthBarPart}.swift`, `Platform/Windows/Popover/WinCompanionSection.swift`, shared tests.
- Modify: `WinHomePage.swift`, `WinUIDump.swift`, the parity files, `PopoverTwinEquivalenceTests+Mac.swift`.

**Interfaces:** Produces C1, C3–C14 (dex links inert).

**Steps:**
- [ ] Shared model and twins: `progressDetail`, `statusLine`, the egg texts, badges, the `EvoLineView` statics. Mac equivalence: the Mac's `ProgressDetailTests`, `EvoLineLayoutTests` corpora and every `CompanionDisplayState`.
- [ ] Parts:
  - the header art (sprite slot 76 pt, backdrop, badges inline, the growth bar with tooltip detail and accessible value);
  - the evolution line (nodes at 40 pt, arrows from the glyph font, "?" node, current dot, future dimmed; chevron button items and edge fade when wider than 320 pt).
- [ ] Celebrations per D16 with the consume contract. Shared test: a celebration is consumed once even when the popover opens twice; the Mac contract test is re-run with the Windows driver.
- [ ] Selftest:
  - `companion.celebrate`: a fixture hatch plays (≤ 60 fps for ≤ 2.6 s, then back to the GIF rate);
  - `companion.consumedOnce`.
- [ ] Captures: egg (incubating, imminent wiggle frame, guarantee), hatched (shiny, types in Korean), evolving flash frame, Eevee's long line scrolled, final stage, graduated. Opened, next to the Mac's `CompanionHeader` renders of the same fixtures.
- [ ] **PR `feat(windows): the companion in the popover`**.

**Verify:** `windows-app` green with `companion.*` PASS; shared tests on both OSes. **Size:** L. **PC:** no.

---

### Task 10: The popover idle gate — Size S

**Files:** `.github/workflows/windows-app.yml`, `scripts/windows/measure-idle.ps1` (popover park modes), `WindowsSelftestPopover.swift` (`--selftest-popover-park <closed-after-open|settings|home-still|home-animated>`), `CONTRIBUTING.md` (Windows popover budgets).

**Steps:**
- [ ] The D18 windows on the installed app with fixture data and `refreshInterval = 0`; record the first numbers in the PR.
- [ ] Assert:
  - closed-after-open equals never-opened within noise, and object counts are back;
  - Settings adds 0 timers;
  - animated ≤ frame rate + 2 cs/s;
  - GDI/USER objects flat.
- [ ] Fault-inject: leave the relative clock armed on Settings → the Settings window fails; revert.
- [ ] **PR `ci(windows): gate the popover's idle cost`**.

**Verify:** `windows-app` full green within budget. **Size:** S. **PC:** no.

---

### Task 11: Milestone 7.2 on the user's PC — the companion — Size S

**Steps:**
- [ ] Checklist (Korean wording is the lead's):
  1. The companion animates smoothly in the popover; the egg wiggles near hatching; back view turns it around (tray icon too).
  2. A hatch or evolution while watching (or a candy later): the flash and the sparkle play once.
  3. Types and names in Korean; the long evolution line scrolls with the arrows.
  4. 10 min `measure-idle.ps1`: popover closed / open on Settings / open on Home. Task Manager CPU while open on Home.
  5. Does the drawn text (Pretendard) next to the native text (Segoe UI) look acceptable (D7)?
- [ ] Record; failures through the defect protocol.
- [ ] **PR `docs: record the Windows companion check`**.

**Size:** S. **PC:** **yes**.

---

### Task 12: The activity panel and the streak — Size L

**Files:** `Popover/{PopoverTrendMetrics,TrendBarsPart,HeatmapPart,StreakPart}.swift`, `Platform/Windows/Popover/WinActivitySection.swift`, shared tests, twins and equivalence tests, `WinUIDump.swift`, the parity files.

**Steps:**
- [ ] Twins of `DailyTrendMetrics`, `DailyTrendHover`, `DailyTrendColumn`, `WrappingHStack` (legend layout), `MonthDailyTrend.readout`/`shouldShowSurface`, `ActivityHeatmapMetrics` (geometry; colours as roles), `StreakBadge.isShown`. Mac equivalence over the Mac's `MonthDailyTrendTests`, `DailyTrendStackTests`, `ActivityVisualizationTests` corpora plus 3 months × 4 windows × 4 time zones × both first weekdays.
- [ ] Parts:
  - bars: today in accent, stacked segments in the palette, empty days dimmed, future days blank, weekend ticks from the region calendar, axis labels, legend;
  - the hover card (no delay) via `TrackMouseEvent` while the pointer is over the part only;
  - heatmap: 16 weeks, weekday letters from the app language starting at the region's first weekday, levels 0–4 light greens, today outline, hover readout;
  - page dots;
  - the whole panel is one button item ("<readout>, switch view").
- [ ] Trend window menu (popup) and the Settings combo (G6).
- [ ] Selftest:
  - `home.activityCycle`: click cycles and persists;
  - `home.heatmapWeekStart`: with `firstWeekday` 1 and 2 → the first row label differs as expected.
- [ ] Captures: bars (one provider, three stacked, quiet month), heatmap (Monday and Sunday starts), Korean; next to the Mac renders.
- [ ] **PR `feat(windows): the activity chart and streak in the popover`**.

**Verify:** Windows green; Mac equivalence green. **Size:** L. **PC:** no.

---

### Task 13: The recap — Size M

**Files:** `Popover/{PopoverRecapContent,RecapCardPart}.swift`, `Platform/Windows/Popover/WinRecapPage.swift`, `Team/Plaza/Draw/PlazaText.swift` (+ Mac CoreText, Windows DirectWrite mapping for `.mono`), tests, `WinUIDump.swift`.

**Steps:**
- [ ] Twin of `RecapContent`. Period labels use the formatter Task 1's probe proved; if `DateIntervalFormatter` is missing on Windows, a shared fallback joins two `MMMd`/`dMMMy` template dates with the language's dash, and the Mac test pins it against `DateIntervalFormatter` for the 8 languages.
- [ ] `PlazaFont.mono`: Mac → monospaced system font; Windows → Cascadia Mono, else Consolas. `plaza-render-compare.sh` → identical (the plaza never uses it).
- [ ] `RecapCardPart` with fixed colours (always light, as the Mac's `.environment(\.colorScheme, .light)`); per-bucket accessibility items and tooltips.
- [ ] The page: Back (Escape), scope radio group (resets the offset), previous/current/next; best-day line; the "so far" note.
- [ ] Captures: week, month, year, an empty ledger, Korean; next to the Mac renders.
- [ ] **PR `feat(windows): the usage recap in the popover`**.

**Verify:** Windows green; Mac render compare identical; Mac equivalence green. **Size:** M. **PC:** no.

---

### Task 14: Session keys and advanced settings **[most capable]** — Size L

Milestone: full Mac gate after this task.

**Files:**
- Create: `Platform/Windows/Popover/{WinAdvancedSection,WinSecret}.swift`, `Tests/PokeTokenBarTests/WindowsPopoverSecretTests.swift`.
- Modify:
  - `Platform/PlatformCompat.swift` (secret seams);
  - `Core/SessionKeyLimitsProvider.swift` (two lines, if DPAPI);
  - `Popover/SettingsModel.swift`, `Popover/HomeModel.swift` (P15 help → session key, P17 notice);
  - `Platform/WindowsPopoverStrings.swift`;
  - the parity files.

**Steps:**
- [ ] **First push:** `WinSecret` round trip through `WinDynamic` on `crypt32.dll`; a tampered blob → nil; a different entropy → nil (R7).
- [ ] D14 seams. Mac pins: `writeSecret` equals `data.write(.atomic)` byte for byte and keeps 0600; `readSecret` equals `Data(contentsOf:)`.
  - Windows tests: a protected save, a plaintext read then re-protected, an undecryptable file reads as no key with one log line.
  - If the user declines DPAPI: no seam, and the selftest `secrets.acl` instead.
- [ ] Advanced section (G17, Windows rows):
  - session key: masked field, Save with validation spinner, Delete, org combo, error / storage note;
  - per-account keys;
  - "Reload Claude sign-in" + message;
  - additional Claude folders and custom scan roots: multi-line edits, the match count debounced off the main thread, the commit rules.
- [ ] Defect protocol for P19: UNC (`\\server\share\…`) and mixed-separator roots are now reachable. Write a failing test through `CustomScanRoots` with the Windows path forms, fix it in the shared path normalizer (a `PlatformCompat` seam if Core needs it; Mac unchanged), add a `defect-log.md` line.
- [ ] Tracked account combo (G7).
- [ ] Home: the session-key-expired notice opens Settings with Advanced expanded, scrolled and the key field focused (`openSessionKeySettings`). The help (?) gets its "register session key" button.
- [ ] Log scan test: no `sk-ant-` substring in `AppLog` output after save, validate, delete and an invalid key.
- [ ] **PR `feat(windows): session keys and advanced settings in the popover`**. Body: the two upstream lines and their pins.

**Verify:** Windows green; Mac filtered + milestone gate. **Size:** L. **PC:** item in Task 18 (a real key).

---

### Task 15: Difficulty, backup and transfer — Size M

**Files:**
- Create: `Popover/PopoverDifficultyDraft.swift`, `Platform/Windows/Popover/{WinTransferSection,WinFileDialog,WinTaskDialog}.swift`, `Sources/CWinShim/filedialog.cpp` (+ header), `Tests/PokeTokenBarTests/WindowsPopoverDialogTests.swift`.
- Modify: `SettingsModel.swift`, the parity files.

**Steps:**
- [ ] Difficulty (G9): twin of `DifficultyDraft` + Mac equivalence; trackbars; Save appears only when changed.
- [ ] `ptb_file_dialog` (COM; `#pragma comment(lib)` for ole32/shell32/uuid); `WinTaskDialog` through `WinDynamic` (Cancel default for import and restore). Both run inside `WinModalPump("dialog")`; the popover stays open (D3).
- [ ] Export (Explorer selects the file), import (decode, confirm with both summaries, apply, done/error), create snapshot, history disclosure with rows and Restore.
- [ ] Selftest, CI only:
  - `settings.exportImport`: the dialog driven by posted keys to a temp path, then import of that file → confirm → summary equal;
  - `settings.dialogKeepsPopover`;
  - `settings.importCancelDefault`: Enter on the confirmation does not replace.
- [ ] **PR `feat(windows): difficulty, backup and transfer in the popover`**.

**Verify:** Windows green. **Size:** M. **PC:** no (Task 18).

---

### Task 16: Dark mode and high contrast — Size M

The high-contrast half is always done. The dark half only if open question 1 says yes.

**Files:** `Platform/Windows/Popover/WinDarkMode.swift`, `WinUIColors.swift`, the parts' colour roles, `WindowsSelftestPopover.swift`.

**Steps:**
- [ ] High contrast: drawn parts switch to system colours (D15). Selftest `ui.highContrast` with `SPI_SETHIGHCONTRAST` in CI (restored after), captured.
- [ ] Dark: read `AppsUseLightTheme` at open and on `WM_SETTINGCHANGE("ImmersiveColorSet")` while open; theme names per D15; drawn parts with the Mac's dark values from `mac-colors.json`. Captures of every page in dark.
- [ ] **PR `feat(windows): follow high contrast (and dark mode) in the popover`**.

**Verify:** Windows green; captures opened. **Size:** M. **PC:** Task 18.

---

### Task 17: Other providers' limits on Windows — Size M

The ledger's open item "limits for other providers". The popover shows whatever the store has (P26–P28); this task makes the store have it.

**Files:** per `docs/reference/provider-extension.md`: the providers' credential locations through their root lists and `PlatformCompat` only. No `== "cursor"` branches in general paths.

**Steps:**
- [ ] For Cursor, Grok and OpenCode Go: find the Windows location of the auth data the Mac reads (documented layouts first, then the PC), add the location through the provider's own root list, test with fixtures.
- [ ] Their HTTP requests go through `PlatformCompat.oneShotData` (WinHTTP), not `URLSession`: the status-burst report's open item (1.7–6.6 k cs per refresh with credentials).
- [ ] Antigravity stays unavailable unless its token location is found; the inventory row says why.
- [ ] **PR `feat(windows): load Cursor, Grok and OpenCode Go limits on Windows`**.

**Verify:** Windows green; PC item in Task 18. **Size:** M. **PC:** yes (in Task 18).

---

### Task 18: Milestone 7.3 on the user's PC; docs — Size S

**Files:**
- spec §8 (as built: native controls, drawn parts, the parity scan), §10 step 7 (done, deviations, tier 3 status), §13;
- `docs/reference/defect-log.md`;
- `CONTRIBUTING.md`: the upstream-sync procedure: run `PopoverParityScanTests`; for each failure update the Windows copy or mark the row; the PR body lists "popover changes → Windows".

**Steps:**
- [ ] Checklist (Korean wording is the lead's):
  1. The activity bars and heatmap (the week starts on the PC's first weekday), hover, click to switch.
  2. The recap: week, month, year; back with Escape.
  3. A real claude.ai session key: save, limits load, Delete. The storage note says what D14 decided.
  4. Export a save, import it back (the confirmation numbers), make a snapshot, restore it.
  5. Dark mode on and off (if built); high contrast on.
  6. Cursor/Grok/OpenCode Go limits if the PC uses them.
  7. A custom scan root on a network share (`\\…`), if one exists.
  8. 10 min idle again (closed / Settings / Home).
- [ ] Record; failures through the defect protocol. `PARITY: … 0 tier2` in the scan output.
- [ ] **PR `docs: record the Windows popover`**. Report to the user in Korean: what works, the listed differences, the idle numbers, the tier 3 list with estimates.

**Size:** S. **PC:** **yes**.

---

### Tier 3 (estimates; scheduled or deferred by the user — open question 4)

| # | Task | Inventory | Size | Notes |
|---|---|---|---|---|
| 19 | Shop and Bag | H1–H3, B1–B2 | M | a shared port of `SpriteLoader.itemImage` (item sprites in the sprite store); inline confirms (no dialogs, as the Mac); steppers |
| 20 | Collection: Pokédex grid and catch log, filters, representative, tray "Dex", Settings representative row, Home dex links | D1–D6, D8, C2, G2, A3 Dex | L | owner-drawn cells as buttons with a context menu; a virtualized owner-drawn list; a `DexScrollPager` twin on Windows wheel deltas |
| 21 | Pokémon detail page | D7 | M | forms grid, stats bars, moves; async names |
| 22 | Floating pet window **[most capable]** | F1, G4, G12, P29 eye, A3 pet | L | layered topmost tool window; `UpdateLayeredWindow`; drag and saved origin; click/right-click; `capFrameRate` twin; animation quality |
| 23 | Pet bubbles, hearts, prayers, agent activity, URL protocol | F2, A4 | M | HKCU `poketokenbar:` protocol registration (installer + app) |
| 24 | Tier 3 PC check | — | S | — |

Total tier 3: 6 tasks (2 L, 3 M, 1 S), about 20–25 Windows CI round trips.

---

## Order

- **Prerequisites:** none beyond the base. Stage 6 Tasks 8 and 9 (canvas, text) are merged.
- **7.1:**
  - Task 1 (Mac slot) first. Then Task 2 (Mac slot) alongside Task 3 (Windows CI only; needs Task 1's `PopoverPart` stub only).
  - Task 4 needs Task 3. Task 5 needs Tasks 2–4. Task 6 needs Tasks 1, 3 and 4 and can be authored alongside Task 5.
  - Then **Task 7 (PC)**.
- **7.2:** Task 8 (needs 3) can start right after Task 3. Task 9 needs Tasks 5 and 8. Task 10 needs Tasks 5, 6 and 9. Then **Task 11 (PC)**.
- **7.3:** Tasks 12, 13 and 15 are independent of each other (each needs Task 5 or 6). Task 14 needs Task 6. Task 16 needs Tasks 5–15 for its captures. Task 17 is independent (store side). Then **Task 18 (PC)**.
- **Critical path:** 1 → 2 → 5 → 9 → 10 → 11; and 1 → 3 → 4 → 6 → 7.
- **Full Mac gate** after Tasks 2, 6 and 14, and before `windows-port` → `main`.
- Only one Mac build at a time, so "parallel" means one Mac-slot task (1, 2, the shared halves of 5, 6, 9, 12–15) next to one or two CI-only tasks (3, 4, 8, 10, 16).
- **Collisions with stage 6** (running in parallel):

  | File | Stage 6 | Stage 7 | Rule |
  |---|---|---|---|
  | `WinMessageHook.swift` | Task 11: `WM_IME_CHAR` | Task 3: unregister | line-local; merge in time order |
  | `WindowsApp.swift` | — | Task 4 | additive |
  | `WinTray*.swift` | — | Task 4 | tell the stage 6 session when it merges |
  | `WindowsSelftest*.swift`, workflows | new groups | new groups | additive steps |
  | `PlazaText.swift` | stable | Task 13: `.mono` | render compare identical |
  | `PlatformCompat.swift` | — | append-only | — |
  | `mac-only.txt`, `shared-floor.txt` | as before | as before | recount on conflict |
  | `TrayMenuModel.swift` | Task 5 (merged) | Task 4 | additive cases |

- **Estimate:** tiers 1–2 are 18 tasks (7 L, 7 M, 4 S, incl. 3 PC sessions), about 55–70 Windows CI round trips at 15–35 minutes each, plus the Mac-slot work. Tier 3: 6 more tasks. No calendar promise.

## Risks and unknowns (each with the cheapest early check)

- **R1. `IsDialogMessageW` called inside the `WH_GETMESSAGE` hook** (re-entrancy; characters dispatched twice, or `?`; a menu or modal loop confused). Check: Task 3's first push (`ui.kit.tabOrder`, `ui.kit.text`). Fallback: Tab/Enter/Escape from a keyboard subclass, characters through the existing `WM_CHAR` re-dispatch.
- **R2. `SetForegroundWindow` refused** on some click paths (overflow flyout on Windows 11, RDP, a full-screen app), giving a popover that never light-dismisses. Check: Task 4's `popover.open` reads `GetForegroundWindow`; the refused-foreground fallback to the menu (D4); Task 7 items 2–3 at the console and over RDP.
- **R3. The overflow flyout:** `Shell_NotifyIconGetRect` gives a rect inside a flyout that closes as we activate, or fails. Check: Task 4 placement fallbacks (click point, then the corner); Task 7 item 2.
- **R4. Formatters on Windows:** `RelativeDateTimeFormatter` is missing (known). `Duration.UnitsFormatStyle`, `DateComponentsFormatter` and `DateIntervalFormatter` are unknown, and so are the template outputs. Check: Task 1's first push (the probe). Fallbacks named in D10 and Task 13.
- **R5. Text entry assumptions.** Stage 6's R1 (an `EDIT` over a composition surface) does not apply: the popover is a plain redirected GDI window, so controls are ordinary children. Assumed from stage 6 Task 11: posted `WM_IME_CHAR` at ACP 1252 behaves as `WM_CHAR` did in E1; the popover's dialog path does not depend on it. Check: `ui.kit.text`; Task 7 item 6 with a Korean IME.
- **R6. comctl32 controls under PerMonitorV2** keep their creation font after a DPI change. Check: `ui.kit.capture` at a synthetic 144 dpi; D2's rebuild on `WM_DPICHANGED`; Task 7 item 9.
- **R7. DPAPI from Swift** (`crypt32` through `WinDynamic`, `DATA_BLOB` lifetime, `LocalFree`). Check: Task 14's first push round trip.
- **R8. Narrator and the drawn parts' child controls** (invisible statics and focus-only owner-drawn buttons): are they read, and in order? Check: Task 7 item 8; if not, the fallback is `WM_GETOBJECT` with `CreateStdAccessibleProxy` names, still not a UIA provider.
- **R9. Hangul glyphs in GDI controls on the runner** (font linking to Malgun Gothic might be missing on Server 2025, giving empty boxes in captures). Check: the `GGI_MARK_NONEXISTING_GLYPHS` tree check in Task 5's Korean capture; PC captures are the truth.
- **R10. Two copies drift** (spec §8's known cost). Check: the parity scan (D9) runs in every Mac scan pass and in each upstream-sync PR; `tier2` = 0 at the end.
- **R11. Modal loops** (task dialogs, file dialogs, menus, scroll-thumb drags) starve team links. Check: each wrapped in `WinModalPump`; Task 15's `settings.dialogKeepsPopover` also asserts the main queue ran during the dialog.
- **R12. Popover height on small or scaled screens** (600 DIP at 150 % = 900 px plus the taskbar). Check: the placement test with a 720 px work area; the clamp + scroll rule.
- **R13. Sprite decode cost or a stall on open** (GIF decode, PokéAPI fetch). Check: decode is off the main thread; `loop.mainThreadStalls` during open in Task 8; the cached still frame first.
- **R14. Dark mode through undocumented theme names** may look half-dark (check-box text, trackbar). Check: Task 16's captures before committing to it; open question 1 lets the user skip it.
- **R15. RDP** (the user's PC is reached remotely): DPI, foreground rules and tray overflow behave differently in a remote session. Check: Task 7 records RDP versus console; `remoteSession=` is already in the log.
- **R16. Stage 6 and stage 7 share the Mac build slot and a few files.** Check: Order's collision table; tell the other session at each merge.

## What stage 8 (release integration) needs from this stage

- The parity scan green with `tier2` = 0, as part of the release gate. It is a Mac-side scan, so `release.sh`'s Mac test run covers it.
- `UpdateChecker.applyUpdate` on Windows: today it opens the release page (P12). Stage 8 downloads and runs the installer. The popover's banner and Settings rows need no change.
- Screenshots for the README and landing from `--dump-ui` popover pages (labelled), refreshed every release (`CLAUDE.md` release rule).
- The release notes' Windows section: the popover's listed differences from the Mac, and the tier 3 status.
- The Windows idle windows (D18) as part of the Windows release gate.
- The version shown in Settings (`WindowsInstall.version`) stamped by the release build.
- Nothing new in the installer: no new files, fonts or DLLs. The `poketokenbar:` URL protocol comes with tier 3 Task 23.

## Open questions for the session lead

1. **Dark mode.** The Mac popover follows the system appearance. Windows' native controls only partly support dark mode (undocumented theme names plus custom colours).
   - Recommended: ship light first (7.1–7.2) and build dark mode in Task 16, following the Windows "app mode" setting.
   - Cost: one M task, about 3 CI round trips, and a risk that a few controls look half-dark (R14).
   - Alternative: light only (no task; a white popover on dark Windows, like Control Panel).
2. **Left click opens the popover, right click opens the menu.** Today both open the menu.
   - Recommended: yes, as Windows users expect (volume, network, OneDrive flyouts). The menu stays on right click and Shift+F10 as the keyboard fallback.
   - Cost: none extra (Task 4); users of the current build must learn the new left click.
3. **A second launch from the Start menu opens the popover** instead of the "already running" balloon.
   - Recommended: yes. It is how a Windows user finds an app hidden in the overflow.
   - Cost: small (Task 4). The first-run hint balloon stays.
4. **Tier 3 (shop, bag, Pokédex, detail page, floating pet).**
   - Recommended: schedule it right after 7.3, in this order: Shop + Bag (M), Collection (L), detail (M), then the floating pet (L + M) last.
   - Cost: 6 tasks, about 20–25 CI round trips, two more PC checks.
   - Alternative: defer some, and their popover entry points stay hidden.
5. **Session keys encrypted with DPAPI on Windows** (D14).
   - Recommended: yes. Same user experience, the file is useless if copied, no prompts.
   - Cost: two one-line upstream call sites in `SessionKeyLimitsProvider.swift` (Mac byte-identical, pinned) and part of Task 14.
   - Alternative: the same plaintext owner-only file as the Mac, with the folder's per-user ACL checked by a selftest.
6. **The Mac's "Menu bar" settings** (tokens, cost, growth %, limit % next to the icon, limit colours) have no meaning for a tray icon.
   - Recommended: not shown on Windows. The tray tooltip always shows today's tokens and cost.
   - Cost: none.
   - Alternative: map them onto the tooltip's contents (one S task).

## 요약 (사용자용)

- 7단계는 트레이 아이콘을 누르면 뜨는 윈도우 팝오버를 만드는 일입니다. 맥 팝오버(SwiftUI)는 손대지 않고, 윈도우용을 따로 만들되 계산 규칙은 공용 코드로 맞춥니다.
- 모양은 윈도우 기본 컨트롤입니다: 버튼·체크박스·목록 상자·입력칸·슬라이더. 폭 360·순서·묶음은 맥과 같고, 글꼴은 Segoe UI입니다.
- 포켓몬 그림·배지·한도 막대·그래프·리캡 카드처럼 기본 컨트롤로 안 되는 부분만 광장에서 만든 그리기 도구로 그립니다. 그래서 키보드(Tab·Enter·Esc), 한글 입력기, 내레이터, 고대비가 처음부터 됩니다.
- PC에서 보시는 순서는 세 번입니다.
  - (1) 사용량·한도 화면과 설정·팀 설정. 이제 명령줄 없이 팀 코드를 넣고 닉네임을 정할 수 있습니다.
  - (2) 움직이는 포켓몬과 부화·진화 연출. (3) 사용량 그래프, 리캡, 세션 키, 백업·불러오기, 다크 모드(원하시면).
- 상점·가방·도감·떠다니는 펫은 작업 6개로 따로 적어 두었습니다. 언제 할지 정해 주세요.
- 맥과 다른 점: 생김새가 윈도우식이고, "3분 전" 같은 문구가 조금 다를 수 있고, 성장 막대는 늘어나는 대신 숫자 풍선이 뜹니다. 그린 부분의 글꼴은 Pretendard입니다. 메뉴바 표시 설정은 해당이 없어 숨깁니다.
- 팝오버는 닫혀 있으면 아무 비용이 없고, 열려 있어도 바뀌는 것이 없으면 깨어나지 않습니다(PC에서 재서 확인).
- 큰 위험: 키보드 이동 장치가 지금의 메시지 고리 안에서 잘 도는지(첫 CI에서 확인), 트레이 숨김 영역·원격 데스크톱에서 창이 제대로 앞에 오는지, 윈도우에 날짜·시간 문구 도구가 빠져 있을 가능성입니다.
- 맥 팝오버가 바뀔 때 윈도우가 뒤처지는 일은 새 검사(빠진 문구·설정·화면이 있으면 실패)로 막습니다.
- 분량: 작업 18개(큰 것 7, 중간 7, 작은 것 4, 그중 PC 확인 3). 윈도우 CI 왕복은 대략 55~70회. 날짜는 약속하지 않습니다.
- 결정 부탁드릴 것: 다크 모드, 왼쪽 클릭=팝오버, 시작 메뉴 재실행 시 팝오버, 상점·도감·펫 일정, 세션 키 암호화(DPAPI), 메뉴바 설정 숨김. 모두 추천안이 있습니다.
