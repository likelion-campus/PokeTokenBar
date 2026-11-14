# Windows port — stage 0 results

## Experiment 5 (E1): the Windows main loop and Foundation facts — strategy 1 works, with no SPI at all

Setup: `windows-latest` (Windows Server 2025, build 26100), Swift 6.3.2, Swift 6 language mode, release build.
Code: `spike/e1/` (`ptbe1`, `ptbe1async`, the C shim `CE1Shim`, `cov_*`); `spike/e1/run-probes.sh` runs each probe in
its own process; job `e1` (probes) and `e1cov` (P12). Report: artifact `e1-report` → `e1-report.txt`.

- R1 https://github.com/likelion-campus/PokeTokenBar/actions/runs/43557074376
- R2 https://github.com/likelion-campus/PokeTokenBar/actions/runs/43557917873
- R3 https://github.com/likelion-campus/PokeTokenBar/actions/runs/43558416605
- R4 https://github.com/likelion-campus/PokeTokenBar/actions/runs/43558872366
- R5 https://github.com/likelion-campus/PokeTokenBar/actions/runs/43559273826

Each run repeats the whole matrix, so every number below has 2–5 repetitions; ranges are across runs.

Loop variants named in the lines:
`cf` = `while !done { RunLoop.main.run(mode: .default, before: .distantFuture) }` on the process main thread.
`cfh`, `cf0` = the same (R1 only; `cfh` tried to add the SPI pump handler, which does not exist, so all three are one loop).
`cur` = control: the same loop through `RunLoop.current`, with `RunLoop.main` never touched.
`dh` = own `MsgWaitForMultipleObjectsEx(QS_ALLINPUT)` on the dispatch main-queue handle, `PeekMessageW` pump,
`_dispatch_main_queue_callback_4CF`, timers through `RunLoop.main.limitDate(forMode: .default)`, timeout clamped 1 ms–60 s.
`dhc` = `dh` with `RunLoop.current` for timers. `poll` = `GetMessageW` + a 250 ms `SetTimer` that runs
`RunLoop.main.run(mode: .default, before: Date())`.

### The answer in one paragraph

The CF message-queue SPI (`_CFRunLoopSetWindowsMessageQueueMask`, `…Handler`, `CFRunLoopGetMain`,
`kCFRunLoopDefaultMode`) is not exported by any loaded DLL, so the plan's `GetProcAddress` lookup cannot work. It is
also not needed: swift-corelibs-foundation's `RunLoop.main` initializer calls
`_CFRunLoopSetWindowsMessageQueueMask(main, QS_ALLINPUT, kCFRunLoopDefaultMode)` itself on Windows. So running
`RunLoop.main` in `.default` on the main thread already serves Win32 messages, the dispatch main queue (where
`@MainActor` jobs run) and `RunLoop` timers on one thread, with no wakeups at idle. Two limits: CF's built-in pump is
the ANSI one (a posted or typed U+D55C arrives as `?`) and it cannot be replaced; a thread-local `WH_GETMESSAGE`
hook that re-dispatches `WM_CHAR` with `DispatchMessageW` fixes that (proven for posted and `SendInput` text, not for an
IME). Separately, corelibs' `Timer(timeInterval:repeats:block:)` fires immediately, unlike Darwin.

### Per question

| # | Question | Answer | Verdict | Evidence | How known |
|---|---|---|---|---|---|
| P1 | Which DLL exports the SPI | CF: none. `_CFRunLoopSet/GetWindowsMessageQueueMask`, `…Handler`, `CFRunLoopGetMain`, `CFRunLoopGetCurrent`, `CFRunLoopWakeUp`, `CFRunLoopObserverCreate`, `CFRunLoopAddObserver`, `kCFRunLoopDefaultMode`, `kCFRunLoopCommonModes` are MISSING in all modules. Dispatch: `_dispatch_get_main_queue_port_4CF`, `_dispatch_main_queue_callback_4CF`, `dispatch_main` in `dispatch.dll`. `swift_task_enqueueMainExecutor`, `swift_task_asyncMainDrainQueue` in `swift_Concurrency.dll` | FAIL for CF (G-c refuted), PASS for dispatch | R1, R2: `E1.P1 FAIL symbol _CFRunLoopSetWindowsMessageQueueMask MISSING` … `E1.P1 PASS symbol _dispatch_get_main_queue_port_4CF module=…\Toolchains\6.3.2+Asserts\usr\bin\dispatch.dll` | observed |
| — | Why messages are pumped anyway | `RunLoop._mainRunLoop` sets the mask on first use of `RunLoop.main` (Windows only) | — | Source: swift-corelibs-foundation `release/6.3` `Sources/Foundation/RunLoop.swift` (the `_mainRunLoop` initializer). Runtime: `cf0` (we set nothing) delivers 20/20 posted messages; `cur` (`RunLoop.main` never touched) delivers 0/20 — R2 `E1.P2[cur] (e) FAIL PostMessageW-from-thread n=0/20` | source + observed (control) |
| P2 | Strategy 1 (`cf`): everything on the main thread, posted-message latency < 50 ms | Yes. (a) `Task { @MainActor }` from main, (b) `Task.detached` → `MainActor.run`, (c) `DispatchQueue.main.async` from a thread ×20, (d) 200 ms `Timer` in `.common`, (e) `PostMessageW` from a thread ×20, (f) `withObservationTracking` → `Task { @MainActor }`, (g) `Task.sleep(1 s)`, (h) `Task { @MainActor }` from a thread ×20, (j) `asyncAfter(0.5 s)`: all on the main thread | PASS | R2 `E1.P2[cf] (e) PASS PostMessageW-from-thread n=20/20 on_main=20 median_ms=0.03 max_ms=0.10`; `(c) … median_ms=0.01 max_ms=0.04`; `(h) … median_ms=0.02 max_ms=0.12`; `(d) … interval_median_ms=202.84 interval_max_ms=209.63`; `(g)` lateness 3.5 ms; `(j)` lateness 1.9 ms. R1 the same within noise (posted max 0.22 ms) | observed |
| P2 k | Text through CF's pump | Lossy. `PostMessageW(WM_CHAR, 0xD55C)` to a Unicode window reaches the WndProc as `0x3f`; our own `PeekMessageW` pump (`dh`, `dhc`) delivers `0xd55c` | FAIL (`cf`), PASS (`dh`, `dhc`) | R2 `E1.P2[cf] (k) FAIL WM_CHAR-unicode-through-the-pump sent=[0x41,0xd55c] got=["0x41", "0x3f"] IsWindowUnicode=1 ACP=1252`; `E1.P2[dhc] (k) PASS … got=["0x41", "0xd55c"]` | observed; that CF calls the ANSI `PeekMessage`/`DispatchMessage` (CF is not built with `UNICODE`) is inferred from source |
| TEXT | Real typed input (`SendInput` with `KEYEVENTF_UNICODE` → `VK_PACKET` → `TranslateMessage`) to a shown, foreground window | `cf`: `B` → `0x42`, U+D55C → `0x3f`. `cfhook` (CF's pump + a `WH_GETMESSAGE` hook that hands `WM_CHAR` to `DispatchMessageW` and leaves CF a `WM_NULL`): `0x42`, `0xd55c`, and the posted one too. `dhc`: `0x42`, `0xd55c` | FAIL `cf`; PASS `cfhook`, `dhc` | R5 `E1.TEXT[cf] FAIL SendInput-unicode got_rest=["0x42", "0x3f"]`; `E1.TEXT[cfhook] PASS SendInput-unicode got_rest=["0x42", "0xd55c"] … hook_redispatched=3`; `E1.TEXT[dhc] PASS …`. (R4's `cfhook`/`dhc` got no keys: the foreground lock kept them in the background; R5 lifts it with a synthetic Alt press) | observed. IME composition (`WM_IME_*`) not tested |
| P2 l | A hook point inside CF's pump (for `IsDialogMessageW`) | Yes: a thread-local `WH_GETMESSAGE` hook (`SetWindowsHookExW`) sees every message CF's pump removes (it removes with `PM_REMOVE \| PM_NOYIELD` = 3, so test the bit), can rewrite one to `WM_NULL` so the WndProc never gets it, and sees `WM_CHAR` in its Unicode form (`0xd55c`) although the WndProc then gets `0x3f`. So `_CFRunLoopSetWindowsMessageQueueHandler` is not needed for pre-dispatch work | PASS | R3 `E1.P2[cf] (l) PASS WH_GETMESSAGE-hook-sees-and-can-eat install=0 posted_seen=20/20 remove_flags=3 chars_seen=2 last_char=0xd55c eaten=3/3 reached_wndproc=0`. (R2 printed FAIL `posted_seen=0/20` because the hook tested `wParam == PM_REMOVE`; our own pump passes 1) | observed |
| P2 m | Cross-thread `SendMessageTimeoutW` (shell and system callbacks send, not post) | Served on the main thread at once under `cf`, `dh`, `dhc`. Control: under `cur` (no mask) the first send blocks the sender for the whole 2 s timeout | PASS | R3 `E1.P2[cf] (m) PASS cross-thread-SendMessageTimeoutW n=5/5 returned_ok=5 wndproc_on_main=5 max_ms=0.10`; `E1.P2[cur] (m) FAIL … n=1/5 returned_ok=0 … max_ms=2012.41` | observed |
| P3 | `MainActor.assumeIsolated` in a WndProc called by CF's pump | No trap. Also no trap from top-level code before the loop, `SendMessageW` outside the loop, a `Timer`, `DispatchQueue.main`, a `Task`, and a `WM_TIMER` inside a `TrackPopupMenuEx` modal loop. Fault injection: the same call on a background thread traps (exit 132, no "after-assume" line) | PASS (G-d holds) | R1, R2 `E1.P3 pump VALUE after-assume (no trap)`, `E1.EXIT ptbe1 p3 pump code=0`; `E1.P3 bg VALUE before-assume tid=… on_main=false` then `E1.EXIT ptbe1 p3 bg code=132` | observed; source: Swift `lib/Threading/Win32.cpp` `thread_is_main()` compares with the thread that loaded `swiftCore.dll` |
| P4 | Idle cost, 60 s, only a 120 s timer + hidden window | `cf`: 0.00 ms CPU, main thread 0 cycles (no wakeup in 60 s); process 5.90 M cycles = the same as a process that only sleeps (baseline 6.12 M). `dh` 15.62 ms (one tick), 1 wakeup; `dhc` 0.00 ms, 1 wakeup (the 60 s clamp); `poll` 93.75 ms, 236 wakeups (≈4/s) | PASS `cf`, `dh`, `dhc`. `poll`: borderline against the letter (< 50 ms per 30 s: R2 46.9, R1 70.3) and rejected on wakeups and latency | R2 `E1.P4[cf] PASS idle_secs=60 cpu_ms=0.00 … cycles=5902785 main_thread_cycles=0`; `E1.P4[poll] PASS idle_secs=60 cpu_ms=93.75 … cycles=66815058 main_thread_cycles=35735505 loop_wakeups=236` (the line's limit scales to 100 ms per 60 s); R1 `E1.P4[poll] FAIL … cpu_ms=140.62 … loop_wakeups=237`; R3 `E1.P4[cf] PASS … cpu_ms=0.00 … cycles=5494170 main_thread_cycles=0`, `E1.P4[poll] PASS … cpu_ms=0.00 … cycles=84039304 main_thread_cycles=49425782 loop_wakeups=236` — tick accounting can miss ≈4 short wakeups a second entirely, so judge by cycles and wakeups, not `GetProcessTimes`. R1's other numbers carried a measuring artefact (a thread snapshot inside the interval): 15.62 ms for baseline, `cf`, `cfh`, `dh` alike | observed. `GetProcessTimes` ticks are 15.625 ms; cycles are exact |
| P4 | Wake latency after the 60 s idle | `cf`: posted message median 0.08 ms / max 0.09 ms; main-queue block 0.02 / 0.06 ms. `poll`: main-queue 84.6 / 206 ms | PASS `cf`, `dh`, `dhc`; FAIL `poll` | R2 `E1.P4[cf] VALUE wake-after-idle PostMessageW n=3/3 on_main=3 median_ms=0.08 max_ms=0.09`, `E1.P4[poll] FAIL wake-after-idle DispatchQueue.main.async … median_ms=84.64 max_ms=206.11` | observed |
| P5 | Strategy 2 (`dh`, `dhc`), the P2 checks | All pass, latency the same as `cf`. With `RunLoop.main` touched (`dh`), CF's own pump still runs inside `limitDate` and took 2 of 20 posted messages in R1 (`pumped=18`); with `RunLoop.current` (`dhc`) our pump got all of them | PASS | R2 `E1.P2[dhc] (e) PASS PostMessageW-from-thread n=20/20 on_main=20 median_ms=0.04 max_ms=0.11`; R1 `E1.P2[dh] VALUE … pump_calls=18 pumped=18` | observed |
| P6 | Async `main` (G-b) | The code before the first `await` runs on the main thread; after it, main-actor code and `DispatchQueue.main` run on a pool thread. The original main thread is still alive at +0.3 s and gone at +2.8 s, and the window created before the `await` is destroyed | G-b confirmed: `main.swift` must stay synchronous | R2 `E1.P6 VALUE after-first-await tid=6172 on_main=false … ctor_thread_alive=1 isWindow=1`, `E1.P6 VALUE 2.8 s after start … ctor_thread_alive=0 isWindow=0`, `MainActor.run_tid=6172 DispatchQueue.main_tid=6172 ctor_tid=9444` | observed; source: libdispatch `queue.c` `dispatch_main()` → `_endthreadex(0)`, `_dispatch_queue_cleanup2` un-binds the main queue after `sleep(1)` |
| P7 | Modal loop (`TrackPopupMenuEx`, cancelled by `EndMenu` from a 1 s `SetTimer`) | The menu really runs on the runner (`WM_ENTERMENULOOP`, ≈1000 ms). Without help, `Timer`s, `Task { @MainActor }` and `DispatchQueue.main` scheduled before or during the menu all run after it (within 0.6 ms of its return). With a 16 ms `SetTimer` during the menu that calls `RunLoop.main.run(mode: .default, before: Date())`, timers (5) and main-actor work run during the menu; calling `_dispatch_main_queue_callback_4CF` instead runs main-actor/main-queue work but no `Timer`s. Posted `VK_DOWN`+`VK_RETURN` still choose item 1 with either drain | observed as stated | R2 `E1.P7[plain] VALUE m-task total=1 during_menu=0 after_menu=1`; `E1.P7[rl] VALUE m-timer total=12 during_menu=5`; `E1.P7[dq] VALUE m-task … during_menu=1`, `m-timer … during_menu=0`; `E1.P7[rlkeys] PASS menu-receives-keys-posted-at-300ms TrackPopupMenuEx=1` | observed |
| P8 | Tray on the runner (G-f) | The runner has an interactive session (2, `WinSta0\Default`, `Shell_TrayWnd`, `explorer.exe`). `NIM_ADD`, `NIM_SETVERSION`, `NIM_MODIFY` with `NIF_INFO`, `NIM_DELETE` all return TRUE; `Shell_NotifyIconGetRect` S_OK | PASS (G-f holds). Whether a balloon was visible: unknown | R1, R2 `E1.P8 PASS nim_add=1 err=0 add_ms=9.0 nim_setversion=1 err=0 nif_info_modify=1 err=0 getrect_hr=0x00000000 rect=790,720,822,768 nim_delete=1 err=0` | observed |
| P9 | Foundation paths | `urls(.libraryDirectory)` → 0 entries (F1). `.applicationSupportDirectory` → `C:/Users/runneradmin/AppData/Local` (F1; forward slashes). `.cachesDirectory` → `…/AppData/Local/Temp`. `NSHomeDirectory()` → `C:\Users\runneradmin`. `Bundle.main`: `bundleIdentifier` nil, `bundlePath` = the exe's directory, `executablePath` = the exe, `resourcePath` = the exe's directory, `infoDictionary` empty (F3). `ProcessInfo.processName` = `ptbe1.exe` (with `.exe`) | confirmed | R1, R2 `E1.P9 VALUE …` lines | observed |
| P9 | `UserDefaults.standard` plist | `C:\Users\runneradmin\AppData\Local\ptbe1.exe.plist`, XML, created only by `synchronize()` (not by `set`) | confirmed, refines F2: the name is `<processName>.plist` and includes `.exe` | R1, R2 `E1.P9 VALUE plists after set, before synchronize: []`, `… after synchronize: [… "C:\\Users\\runneradmin\\AppData\\Local\\ptbe1.exe.plist" …]` (the other two hits are the legacy junctions `Application Data` and `Local Settings` to the same file) | observed. The folder is built from `GetProfilesDirectoryW` + the user name + `AppData\Local` (source: `CFKnownLocations.c`), not from the known-folder API |
| P9 | Persistence across processes | `set` + `TerminateProcess` → absent. `set` + `synchronize` + `TerminateProcess` → present. `set` + normal `exit(0)` → absent (no exit hook). `set` + 5 s of `RunLoop.main` + `TerminateProcess` → absent (no flush timer). A no-change `synchronize`, and `set` of the same value + `synchronize`, leave the mtime unchanged; a real change moves it | PASS (F2 holds, and also covers a normal exit) | R1, R2 `E1.P9 PASS read-plist-file key=e1.k.nosynckill expect=absent present=false`, `… e1.k.synckill expect=present present=true`, `E1.P9 VALUE read-plist-file key=e1.k.nosyncexit … present=false`, `E1.P9 PASS no-change-synchronize-keeps-mtime … control_changed=true` | observed |
| P10 | `Process` + `.cmd` (G-g) | `isExecutableFile`: `.exe` true, `.cmd` true, `.txt` false. Arguments `a b`, `"q"`, `x&y` reach an `.exe` exactly. Through a `.cmd` shim (`@"…exe" argv %*`), in a plain path and in a path with spaces, `a b` and `"q"` arrive intact but `x&y` is split by cmd.exe (it runs `y`). Plain flags (`a`, `b-c`, `--flag=1`) through the shim are exact | PASS for spaces and quotes, FAIL for cmd metacharacters | R2 `E1.P10 PASS exe-direct …`, `E1.P10 FAIL cmd-shim-path-with-spaces status=1 got=["a b", "\"q\"", "x"] … 'y' is not recognized`, `E1.P10 PASS cmd-shim-plain-args` | observed; source: `Process.swift` `quoteWindowsCommandLine` quotes only arguments with a space, tab, newline or quote |
| P11 | `URLSession` HTTPS GET | 200 in 195–283 ms; the completion runs off the main thread | PASS | R1 `E1.P11 PASS https-get status=200 bytes=6242 ms=282.67 callback_on_main=false`, R2 `ms=194.91` | observed |
| P12 | WinSDK from Swift | All 11 import and link with `import WinSDK` plus `.linkedLibrary`: `DnsServiceRegister`/`DeRegister`, `DnsServiceBrowse`/`Resolve`, `NotifyNetworkConnectivityHintChange`/`GetNetworkConnectivityHint`, `GetLastInputInfo`, `Shell_NotifyIconW`/`Shell_NotifyIconGetRect`, `CredReadW`/`Write`/`Delete`/`Free`, `RegisterPowerSettingNotification` + `GUID_CONSOLE_DISPLAY_STATE`, `RegisterSuspendResumeNotification`, `WSAPoll`, `MiniDumpWriteDump` + `SetUnhandledExceptionFilter`, `SHGetKnownFolderPath` + `FOLDERID_LocalAppData`. None needs `CWinShim` | PASS | R1, R2 `E1.P12 PASS DnsServiceRegister imports+links …` (R2 calls each API under a runtime-false condition so the symbol must link) | observed |
| — | `Timer` first fire (new) | corelibs `Timer(timeInterval: 1, repeats: false)` + `add` fires at 7.8 ms; repeating at 7.9, 1006, 2003 ms. `Timer.scheduledTimer(withTimeInterval:)` and `Timer(fire: now + 1, …)` first fire at 1006 ms. On macOS (Swift 6.3.2, this Mac) the same `Timer(timeInterval: 1, …)` first fires at 1009 ms | Windows differs from Darwin | R2 `E1.TIMER FAIL Timer(timeInterval:1,repeats:false)+add first_fire_ms=7.79`, `E1.TIMER PASS Timer(fire:now+1,interval:1)+add first_fire_ms=1005.95` | observed on both; source: corelibs `Timer.swift` `init(timeInterval:repeats:block:)` = `init(fire: Date(), …)` |

### Recommendation

Use strategy 1, `.cfRunLoopWithMessages`, with no SPI: touch `RunLoop.main` before the loop (that turns on the
message mask) and loop `RunLoop.main.run(mode: .default, before: .distantFuture)` on the process main thread with a
synchronous `main.swift`. Measured over R1–R5: the main thread used 0 cycles in every 60 s idle window (no wakeup at
all); the process used 5.5–8.7 M cycles per 60 s (R2–R5), below the same run's sleeping baseline (6.1–10.1 M), and
`GetProcessTimes` read 0.00 ms. Posted-message latency median 0.03–0.08 ms, max 0.09–0.22 ms; `DispatchQueue.main`
from a thread median 0.01–0.05 ms, max ≤ 0.10 ms; `Task { @MainActor }` from a thread median 0.02–0.07 ms,
max ≤ 0.22 ms; right after 60 s of idle, posted median 0.04–0.11 ms (max ≤ 0.22) and main queue 0.02–0.05 ms.
Cross-thread `SendMessageTimeoutW` ≤ 0.20 ms. For pre-dispatch work (`IsDialogMessageW`, Unicode `WM_CHAR`), add a
thread-local `WH_GETMESSAGE` hook.
Fallback: strategy 2 in its `dhc` form (own `MsgWaitForMultipleObjectsEx` on `_dispatch_get_main_queue_port_4CF`,
a `PeekMessageW` pump, `_dispatch_main_queue_callback_4CF`, timers through `RunLoop.current.limitDate`, timeout 1 ms–60 s):
it passed every check, wakes once per 60 s at idle, delivers non-ANSI text without a hook, and lets us own the pump.
Its catch: anything that touches `RunLoop.main` (shared `UsageStore` does) turns CF's ANSI pump back on.
Strategy 3 (polling) is rejected: 236–238 wakeups per 60 s, 11–16× the CF loop's cycles (R2–R5), main-queue latency
after idle median 44–85 ms and max 228 ms, and up to 445 ms under load.
During Win32 modal loops, a 16 ms `SetTimer` that drains (`RunLoop.main.run(mode: .default, before: Date())`, or only
`_dispatch_main_queue_callback_4CF`) keeps main-actor work running; menus still take their keys.

Not learned here: Hangul/IME input through CF's ANSI pump on a Korean-locale PC (ACP 949), whether a balloon is
visible, and idle cost on a real PC with the tray icon shown.

### What surprised me

1. The CF SPI is not exported, and not needed: Foundation's own `RunLoop._mainRunLoop` initializer sets
   `QS_ALLINPUT` on `kCFRunLoopDefaultMode`. The `cur` control (never touch `RunLoop.main`) gets 0/20 posted messages
   and a `SendMessageTimeoutW` that blocks its sender for the full 2 s.
2. CF's pump is ANSI: a posted `WM_CHAR` U+D55C and a typed one (`SendInput(KEYEVENTF_UNICODE)`) both reach a Unicode
   window as `0x3f` (runner ACP 1252). Our `PeekMessageW` pump delivers `0xd55c`. A `WH_GETMESSAGE` hook sees the
   Unicode form first; re-dispatching it there with `DispatchMessageW` delivers `0xd55c` for posted and typed text.
3. `Timer(timeInterval:repeats:block:)` fires immediately on Windows (7.8–15.7 ms in R2–R3) but after the interval
   on macOS (1009 ms, this Mac, Swift 6.3.2). Shared `UsageStore.reschedule()` and `suspendPolling()` use it.
4. The GitHub runner has a real desktop (session 2, `WinSta0\Default`, `explorer.exe`): tray calls, a keyboard-driven
   `TrackPopupMenuEx`, and `SendInput` to a foreground window all work there.
5. `GetProcessTimes` is too coarse for an idle gate: polling at ≈4 wakeups/s read 140.6, 93.8, 0.0, 46.9 and
   62.5 ms per 60 s in R1–R5, while its cycle count was 11–16× the CF loop's in every clean run. Gate on cycles or
   wakeups.
6. `UserDefaults` loses unsynchronized changes on a normal `exit(0)` too, and the file name keeps the `.exe`.
7. The runner loads `dispatch.dll` and `BlocksRuntime.dll` from `Toolchains\6.3.2+Asserts\usr\bin` and the rest of
   the runtime from `Runtimes\6.3.2\usr\bin` (a `Path` artefact a bundled app must not depend on).

### Plan assumptions (Track B plan, 2026-11-14) that these findings contradict

| Where | Assumption | Found | Suggested change (the session lead decides) |
|---|---|---|---|
| Architecture para, F4, G-c, D1 `CWinShim` "CF/dispatch SPI lookup", D2 decision, D3 "Loop + main actor" | Strategy 1 needs `_CFRunLoopSetWindowsMessageQueueMask` found with `GetProcAddress` | Not exported; `RunLoop.main` already sets the mask | Strategy 1 = touch `RunLoop.main`, loop `RunLoop.main.run(mode: .default, before: .distantFuture)`. Drop the CF part of `CWinShim`; keep the dispatch lookups (exported by `dispatch.dll`) for fallback 2 and modal drains |
| D2; stage 7 popover note | A pump handler drains every message; stage 7 adds `IsDialogMessageW` to it | The handler SPI is not exported. Not needed for throughput (one message per CF iteration, 0.03–0.08 ms median). The working pre-dispatch hook point is a thread-local `WH_GETMESSAGE` hook | Say "`WH_GETMESSAGE` hook on the main thread" instead of "pump handler" |
| D2 "EDIT controls get IME composition for free because the pump calls TranslateMessage" | CF's pump is text-safe | It is ANSI; non-ACP characters become `?` | Stages 6–7 text input: keep strategy 1 and add the `WH_GETMESSAGE` re-dispatch (R5 PASS for posted and `SendInput` text), or strategy 2 `dhc`. Hangul IME on an ACP-949 PC goes on the PC checklist |
| D2 fallback 2 | Timers via `RunLoop.main.run(mode: .default, before: Date())`, clamp 250 ms–60 s | Touching `RunLoop.main` turns CF's ANSI pump on and it takes messages during the timer pass (R1: 2 of 20). A 1 ms floor caused no busy loop | Use `RunLoop.current` on the main thread and a 1 ms floor. Shared `UsageStore` calls `RunLoop.main`, so a fully owned pump also needs that call routed |
| Task 1 Interfaces | `int ptb_cf_enable_message_pump(uint32_t mask)` | Always −1 on 6.3.2 | Drop it |
| Task 5 Interfaces / Files / step 4 | Consumes `ptb_cf_enable_message_pump`, edits `cf_spi.c`, `WinMainLoop.prepare()` picks by Task 1's rule | A "symbol found" rule would always pick a fallback | `prepare()` returns `.cfRunLoopWithMessages` after touching `RunLoop.main`; the selftest's `loop.postedMessage` is the run-time proof |
| Task 5 selftest `store.timer` | `refreshInterval = 2`, expect a second refresh within 5 s | Passes for the wrong reason: the corelibs `Timer(timeInterval:…)` fires at once | New F-row: `UsageStore.swift:1030` and `:1048` fire immediately on Windows. Mac-identical fix: `Timer(fire: Date(timeIntervalSinceNow: i), interval: i, repeats: true, block:)`; assert no fire before the interval |
| D4 Settings row, D1 rename note, Task 5 `defaults.persist` | `%LOCALAPPDATA%\PokeTokenBar.plist` | `<profiles dir>\<user name>\AppData\Local\<processName>.plist`, `processName` keeps `.exe`: `PokeTokenBar.exe.plist` (an unrenamed CI exe: `PokeTokenBarWin.exe.plist`) | Derive the path from `ProcessInfo.processName`. Inferred risk: a profile folder named differently from the user name |
| F2 / D4 sync policy | Lost on crash, kill or logoff | Also lost on a normal `exit(0)` | Every exit path calls `synchronize()`, including selftest and fatal-error exits |
| G-f, Task 6 | Tray selftest only if G-f holds | G-f holds on `windows-latest` | Run tray add / modify / delete in CI |
| G-g, Task 4 | `.cmd` shims take arguments with spaces | Spaces and quotes yes; `& \| < > ^ %` are interpreted by cmd.exe | Today's `app-server --stdio` is safe; never pass free-form strings through a `.cmd` |
| D2 "Known limit" (modal loops) | Jobs and timers wait for the menu; a 16 ms `SetTimer` drain is a guess | Both confirmed; menu keys still work with either drain | Keep as the stage 6 mitigation; the dispatch-only drain avoids nested CF runs |

Confirmed as written: G-a, G-b, G-d, F1, F3, the F2 mechanism, "all windows on the main thread", and that no API in
the P12 list needs `CWinShim`.

Deviations from the brief: code in `spike/e1/`, jobs `e1` and `e1cov` (the session lead's instruction), no docs PR;
`cfh` equals `cf` (the handler does not exist); idle windows of 60 s with the limit scaled to 100 ms.

## Experiment 4: a Mac plaza layer behind a drawing interface — YES

- `PlazaPondLayer` no longer imports SpriteKit. It talks to `DrawFactory`/`DrawNode`/`DrawSprite`/`DrawTexture`
  (`SpikeDraw.swift`, 20 lines); the SpriteKit side is `SpikeDrawSpriteKit.swift` (about 40 lines).
- Offscreen `SKRenderer` render, 640x480, scripted splashes and bubbles, 3 timestamps x 3 conditions
  (plain water, a multiply tint above, a multiplyX2 tint above): 9/9 byte-identical before and after.
  Node-tree dumps (position, z, alpha, hidden, size, texture size, blend) identical 9/9.
- Cost: 6000 scripted frames of the layer, 5 runs. Median before 28.3 ms, after 28.6 ms (other runs of the
  unchanged code ranged 23–29 ms, so the difference is inside the noise).
- Existing tests: `swift test --filter Pond` 85 tests, 0 failures. No test file changed. Four test sites read
  `layer.children`; a 3-line SpriteKit-side extension kept them compiling. In stage 2 such tests should read a
  recording implementation instead.
- Rulings: the render used the layer in a bare `SKScene` rather than the full `PlazaScene` at noon / night /
  snow, because those conditions are other layers above or below the pond nodes and do not change the pond's own
  nodes; blend interaction is covered by the two tint conditions. Textures still come from `CGImage`
  (`PlazaPondArt`); making images without CoreGraphics is experiment 3's subject.
- Not learned here: the cost of a layer with many more nodes per frame (`PlazaScene`, `PlazaActor`).

## Experiment 1: does the shared logic compile and test on Windows — YES for the toolchain, with a real finding about the code

Toolchain
- `windows-latest` (Windows Server 2025, VS 2026) + Swift 6.3.2: builds and runs XCTest.
- `windows-2022` + Swift 6.1.2: also builds.
- `windows-latest` + Swift 6.1.2 does NOT build swift-crypto: the VS 2026 STL requires Clang 20+, and Swift 6.1.2
  ships Clang 19 (`error STL1000`). CI must pin a matching pair. Use `windows-latest` + Swift 6.3.x.
- swift-crypto (`import Crypto`) is a drop-in for `CryptoKit` here.

What compiled
- The largest set of `Core`/`Team` files that builds with portable imports only and needs nothing from a Mac-only
  file: 18 files, 1,444 lines, plus 14 test files (82 tests). It builds on Windows. 82 tests run: 16 fail on
  Windows, 13 of the same fail on the Mac in this cut-down package (they scan the repo layout, which the spike
  flattens). One failure is Windows-only: `BinaryLocatorTests.testAugmentedEnvironmentPrependsToolPaths`
  (PATH uses `;` and drive letters on Windows).
- That set is small because the code is not layered, not because Windows rejects it. 83 files (16,720 lines)
  import nothing Apple-only and use no CoreGraphics drawing, but most of them reference a type that lives in a
  Mac-only file. The seam is 20 symbols in about 12 files:
  `LimitsError`, `AccountIdentity`, `ClaudeLimitsProviding`, `OAuthLimitsProvider`, `OAuthCredentialData`
  (`Core/OAuthLimitsProvider.swift`, imports Security), `CustomScanRoots` (Darwin), `CompanionStore`
  (UserNotifications), `LocalAdditionalUsageReader` and `LocalAntigravityUsageCache` (SQLite3), `UsageStore`
  (AppKit), `TeamTransporting` (declared in `TeamTransport.swift`, which imports Network), `TeamNotifier`,
  `TeamFocusTally` (UserNotifications), `PlazaWeather`, `PlazaNameColor`, `PlazaChatLog`, `PlazaWindowController`,
  `PokemonNameDisplayStore`, `CGEventType`, `CGEventSource`.
  Stage 1 has to cut these: move the protocol or value type out of the file that imports the Apple framework.

Windows-only API gaps found by compiling the 83-file set on Windows (beyond the missing symbols above)
- `URLSession`, `URLRequest`, `HTTPURLResponse`: need `import FoundationNetworking` (mechanical).
- `kill` / `SIGKILL` (`ProcessRunner`): replace with `TerminateProcess` behind a shim.
- `NSData.compressed(using: .zlib)` / `decompressed`: not in Foundation on Windows. Needs a zlib dependency.
- `ProcessInfo.beginActivity` / `endActivity`: not available; make it a no-op or use `SetThreadExecutionState`.
- `NSString.abbreviatingWithTildeInPath`: not available; small helper.
- Files with these gaps also show follow-on type-check errors; the full list will only be final once the seam is cut.
- CRLF: Windows checkouts convert text files. Any script that reads a list file must strip `\r`, or the repo needs
  `.gitattributes`.

Not learned: whether the 15k lines behind the seam hide more gaps. Stage 1 will tell, file by file.

## Experiment 2: Mac <-> Windows discovery and TLS-PSK — YES on CI and on this Mac; the real-PC run is still open

- `spike/probe/ptbprobe.c` (about 230 lines of C): DNS-SD through the built-in `windns` API
  (`DnsServiceRegister` / `DnsServiceBrowse` / `DnsServiceResolve`), Winsock TCP, TLS 1.2 PSK through OpenSSL 3.6
  linked statically (vcpkg `openssl:x64-windows-static`). The exe is 5.3 MB and needs nothing installed.
- On the Windows runner (build 26100): advertise -> browse found it -> resolve -> TCP -> `TLSv1.2
  PSK-AES128-GCM-SHA256` -> one line each way. Key derivation matches the Mac (`CITEST` -> SHA-256 prefix
  `b5ba566299247fc1` on both).
- On this Mac: `openssl s_client` (OpenSSL 3.6, same PSK, identity `ptb-team-v1`) against
  `scripts/team-probe.swift serve` (Network.framework): handshake OK and the line arrived. So the TLS stack the
  Windows probe uses is wire-compatible with the Mac side.
- Ruling: skipped Schannel and went straight to a linked TLS library. Microsoft's docs say no PSK suite is enabled
  by default, which points at a policy change (admin) — a stated failure condition — and the SSPI handshake code
  is several times larger. Cost if wrong: about 5 MB of exe and an Apache-2.0 dependency that Schannel might have
  avoided.
- Ruling: the probe is plain C, not Swift. The question was the protocol, and Swift <-> C on Windows is covered by
  experiment 3.
- Side effect to know: while the Mac probe advertised `_ptbteam._tcp` for about 90 s, seven other machines on the
  office network (teammates' apps) dialled it and were refused (`bad MAC`, different key). Nothing was sent to
  them. The user guide warns about these lines.
- STILL OPEN (needs the user's PC): runs A, B, C in `README-ko` — discovery across two real machines on the office
  Wi-Fi, a standard (non-admin) account, the firewall prompt, and any security software. The CI runner is an
  administrator on one machine, so it cannot answer those.

## Experiment 3: Direct2D from Swift, headless — YES

- Swift 6.3.2 `executableTarget` + a C++ shim target (`CD2D`, about 200 lines) with a plain C header. Swift calls it
  directly; SwiftPM builds the C++ with no extra tooling. `ptbdraw.exe` is 0.6 MB (plus the Swift runtime DLLs).
- Pipeline: D3D11 device (WARP on CI) -> Direct2D device context -> offscreen bitmap -> WIC PNG.
- The CI render (`draw-png` artifact) shows: tiles from `plaza-tiles.png` at 3x, crisp; `Galmuri11.ttf` loaded from
  a file into a private font collection (not installed), Hangul and Latin, aliased, at 12 and 24 px; a name plate in
  Pretendard Bold from a file; colour emoji through Segoe UI Emoji; a multiply tint over half the scene through the
  Direct2D Blend effect.
- So headless PNGs from a Windows runner are usable for PR images and for checks from a Mac session.
- Ruling: no window. `--hardware` renders the same pipeline on the GPU offscreen instead; presenting to a swap
  chain is routine and was left out. Cost if wrong: a presentation problem shows up in stage 6.
- Not covered: `multiplyX2`, rotation, crop nodes, GIF decoding, text measurement, performance.
- STILL OPEN (needs the user's PC): the same render on a real GPU, to compare with the WARP image.

### Experiment 2, real-PC run (2026-11-13, office Wi-Fi) — YES for A and B

- Windows PC `DESKTOP-75RFFUC` (10.10.162.115) and this Mac (10.10.162.132), same Wi-Fi.
- Run A (Windows serves, Mac browses): the Mac found `probe-win-412f._ptbteam._tcp.local.`, connected,
  `TLS-PSK handshake OK`, sent a ping and received the pong.
- Run B (Mac serves, Windows browses): the Mac logged incoming connections from 10.10.162.115,
  `TLS-PSK handshake OK`, and `got: ping DESKTOP-75RFFUC …`. So Windows discovered the Mac service by DNS-SD,
  resolved it and connected, both IPv4.
- Noise as predicted: the Mac probe refused 9 dials from teammates' apps (`bad MAC`).
- Still to hear from the user: Windows version, whether the account was a standard one, whether the firewall
  prompt appeared and asked for an admin password, run C (the real app's service is visible), and the `out.png`
  from `ptbdraw --hardware`.
- User's answers: Windows 11, a standard (non-admin) account. The firewall prompt appeared on run A. Whether it
  asked for an admin password was not answered; run A's inbound connection did succeed. `ptbdraw --hardware`
  saved `out.png`, and by eye it is the same picture as the WARP render (no pixel diff was made; the file was not
  sent back). Run C (the real app's service is visible) was effectively covered by run A's Mac log and by the
  Windows browse reaching the Mac; the Windows-side FOUND lines for teammates' apps were not sent back.
- Follow-up from the user: they are not sure the dialog was the firewall prompt (one alert appeared and went away on
  OK). `netsh advfirewall firewall show rule name=all | findstr /i ptbprobe` on that PC printed a line, so Windows
  did create a firewall rule for the probe from a standard account, with no admin password. The rule's action
  (allow/block) and profile were not read; run A's inbound success implies it allows on that network.
  Stage 4 must still check this from a clean state with the real installer.
