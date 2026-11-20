# Windows Port, Stage 6 (The Windows Plaza Window and Renderer) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Windows teammate opens the plaza from the tray (or a team notification) and stands in the same room as the Mac teammates, with every plaza feature: the map and seasons, characters and teammates, emotes, name plates and bubbles, every HUD panel including the roster, chat log, board and card, the chat field with Korean IME, photos to the clipboard, the hidden-background mode. It is drawn by the shared scene, the shared HUD panels and the shared controller from Track A, through a Direct2D / DirectWrite / WIC implementation of the drawing interface. A visible idle plaza costs little, a hidden or covered one almost nothing, a closed one exactly what it costs today. The Mac does not change.

**Architecture:** Track A left one shared node tree (`PlazaNode` and friends) that the Mac mirrors into SpriteKit, one shared canvas/text interface (`PlazaCanvas`, `PlazaTextEngine`) that the Mac implements over CoreGraphics/CoreText, and one shared controller that talks to a `PlazaWindowShell`. Stage 6 implements the same seams on Windows, all in `Sources/PokeTokenBar/Platform/Windows/Plaza/` (Swift, `#if os(Windows)`) over a new Windows-only C++ target `CPlazaD2D` (flat C header, COM inside):
- **Scene:** a Windows stage (`WinPlazaStage`) whose node mirrors only mark the frame dirty; a renderer walks `PlazaDrawOrder.flatten` and draws the items with a Direct2D 1.1 device context into a frame bitmap, which a DirectComposition swap chain presents in the plaza window. A vblank-driven frame clock thread posts one tick message per frame while the plaza is visible and parks otherwise.
- **Canvas and text:** Direct2D on WIC bitmaps (the CPU rasterizer, identical on the runner and on a PC) and DirectWrite with the bundled fonts as a private collection. Line breaking, rounded-corner geometry and premultiplication are shared Swift pinned by goldens measured on the Mac.
- **Window:** one top-level window (`WinPlazaWindow`) made through `WinSinkWindow`, drawing the scene and all panels in one frame in the Mac's z order, with a native `EDIT` child for the chat line above the composition.

**Tech Stack:** Swift 6.3.2 on `windows-latest` (VS 2026), SwiftPM, XCTest, `WinSDK`, a C++17 target (`d2d1`, `dwrite`, `d3d11`, `dxgi`, `dcomp`, `windowscodecs`, `dwmapi`, `ole32`, `dxguid`), Windows' own fonts for emoji and icons, Pretendard (OFL) committed for name plates. On the Mac: the existing SpriteKit render harness for goldens and comparisons. Nothing new ships on the Mac.

**Spec:** `docs/superpowers/specs/2026-11-13-windows-port-design.md` (Korean) — §2 (G1, G3, failure conditions incl. the three idle states), §5 (drawing interface, fonts, 1–2 px text tolerance), §6 (overlays, the chat field exception), §9.1 (Experiment 3), §10 step 6, §11, §13. Contract: the "Interfaces" section of `docs/superpowers/plans/2026-11-14-windows-port-track-a-plaza.md` as updated by Tasks 14–17, plus what the code grew since (read `Team/Plaza/Draw/*.swift`, `Team/Plaza/HUD/PlazaPanel.swift`, `PlazaHUD.swift`, `PlazaWindowShell.swift`, `Platform/PlatformPlaza.swift`). Host rules: `docs/superpowers/plans/2026-11-14-windows-port-track-b-windows-app.md` D2 ("How stages 6 and 7 host their windows"), D8, F14–F20, and `.superpowers/sdd/2026-11-14-windows-port-track-b-windows-app/menu-pump-report.md` ("Stage-6 plaza window must"). Experiment code: `origin/spike/windows-port:spike/draw/` (the D2D/DirectWrite/WIC shim, 200 lines).

**Base:** `windows-port` at `bfefdc9`. Prerequisite for Tasks 5 and 16: Track B Task 12 (packaging, installer, `measure-idle.ps1`, idle gate) is on `origin/feat/windows-packaging` (`761a159`) and is **not** merged at this base; it must be merged first. Track A Task 19 (lock-in, deleting `Tests/PokeTokenBarTests/Legacy/`) may run before or alongside Task 1; Task 1 must not depend on `Legacy/`.

---

## Facts this plan rests on (read in source at `bfefdc9`)

| # | Fact | Where | Consequence |
|---|---|---|---|
| S1 | The scene uses exactly: node `position`, `zPosition`, `alpha`, `isHidden`, `xScale`/`yScale` (negative x for facing; the camera's `setScale(1/zoom)`), `zRotation` (only the character: dance tilt + wobble); sprite `texture` (incl. cut textures, a cut of a cut is a part of the whole image), `unscaledSize`, `anchorPoint`, `color`, `colorBlendFactor` (only the ghost: 0.3 toward the pond water colour on a textured sprite; and the daylight node: 1 on an untextured sprite), `blendMode` (`.multiply` daylight; `.multiplyX2` campfire light, an opaque `noneSkipLast` bitmap where 0.5 is neutral, and firework lights); one `PlazaCropNode` per actor; one camera with screen-space children (daylight at camera z 5) | `PlazaScene.swift` 465–495, 2118; `PlazaActor.swift` 30, 104–105, 354; `PlazaFireworkLayer.swift` 46 | The renderer needs nearest bitmap draws under affine transforms, colour rects, alpha, axis-aligned clips, SpriteKit's colour-blend and the two multiply modes. Nothing else. |
| S2 | `PlazaDrawOrder.flatten(root:camera:)` already yields SpriteKit's order (global z, crop subtrees as one unit, exact ties in tree order, camera children screen-space in the same z space), accumulated alpha, and a transform from the unit square of the sprite's rect to root or camera space; Track A proved it equal to SpriteKit's own order on 12 harness scenes | `Team/Plaza/Draw/PlazaDrawOrder.swift`; Track A task-10 report §4 | The Windows renderer is one loop over `flatten`; no second scene graph. |
| S3 | The scene's only clock is `PlazaStageDelegate.stageUpdate(_:)`; it reads `stage.backingScale ?? 2` for device-pixel snapping and plate rendering, and must not hear its own pause writes back | `PlazaStage.swift`; `SpriteKitStage.isWritingPause`; `PlazaScene.swift` 1966, 2097 | The Windows stage brings the clock, an exact backing scale (fractional on Windows) and the same no-echo rule. |
| S4 | Canvas operations used: every method of `PlazaCanvas` (state stack, CTM, alpha, 3 blends, fill/stroke colour, device gray, line width/join/cap, shadow, 3 antialias flags, interpolation none, 2 text modes, rect/rounded/uneven clips, fills of rects/ellipses/paths/rounded/uneven rects, strokes of ellipses/paths/rounded/uneven rects, image draws, line and paragraph draws, image bounds, `withPixels`, `makeImage`). Non-normal blends only in `PlazaPhotoRenderer`; an aliased canvas only in the chat bubble; stroke text with round join under a blurred shadow only in the name plate; continuous and uneven rounded rects only in panels | `PlazaCanvas.swift`; grep of callers | Task 8 implements the full protocol; each case has a named user. |
| S5 | Fonts: `.plaza(.small)` = Galmuri11 12 pt, `.plaza(.body)` = Galmuri14 15 pt; `.system(size:weight:)` in bold (plate), semibold (plate title) and regular (card ★ 12 pt); `.emoji(12)` (💧). `wrappedLines` (TextKit `.standard`: Korean words whole) for panels; `paragraph` (CTFramesetter: breaks between syllables) for bubbles | `PlazaText.swift`, `CoreTextPlazaEngine.swift`, `PlazaNamePlate.swift`, `PlazaChatBubble.swift` | Pretendard Regular, SemiBold and Bold are needed; two breaking rules. |
| S6 | The Windows build excludes `Resources` (no `Bundle.module` on Windows). Bundled: Galmuri11/14 (5.4 / 5.6 MB), tile, tall-grass, ice crack and gloss PNGs, the ice GIF, the water balloon. Pretendard is not in the repo (the spike downloaded 1.3.9 at build time) | `Package.swift`; `Resources/Plaza/` | Stage 6 ships and finds resources itself (D11). |
| S7 | Every bundled PNG decodes as 8-bit sRGB with straight alpha; the Mac's `pixels` premultiply through a CoreGraphics draw, which changes bytes for the tiles (55,638), the balloon and the cracks | Track A task-3 report | Byte-equal art across OSes needs CoreGraphics' premultiply rounding in shared code (D11). |
| S8 | The controller's HUD holds the 8 canvas panels; the roster, chat log, board and card panels exist (17a–d) but the Mac shows SwiftUI views built from `PlazaOverlayBindings`, which carries every model and action those panels need | `PlazaWindowController.swift` 123, 338; `PlazaMacWindow.swift` | Windows builds the four content panels in its shell from the bindings, like the Mac shell builds its SwiftUI views (D8). No controller change, the Mac decision stays open. |
| S9 | `WinSinkWindow`'s general init routes a window's messages and makes the hook re-dispatch `WM_CHAR`/`WM_SYSCHAR`/dead chars as Unicode for windows it owns and their children; `WM_IME_*` are only observed. `WinModalPump` must be begun and ended from the plaza window's own `WM_ENTERSIZEMOVE`/`WM_EXITSIZEMOVE` | `WinMessageHook.swift` 53–69; menu-pump report | The window is a `WinSinkWindow`; `WM_IME_CHAR` joins the re-dispatched set (D13). |
| S10 | `CWinShim` calls `CoInitializeEx(MTA)` on the calling thread (`wic.cpp` 70, 265); the tray decodes its icon on the main thread, so the UI thread may become MTA | `Sources/CWinShim/wic.cpp` | TSF, the IME and the emoji panel expect an STA UI thread; Task 2 makes it STA first (D16). |
| S11 | While the plaza is open the controller runs a 1 s focus tick and a 1 s render watchdog (`Task.sleep`), hidden or visible, on both OSes | `PlazaWindowController.swift` 1524, 2229 | The "open but hidden" budget allows two wakeups a second (D19). |
| S12 | The Mac draws 60 frames a second while the plaza is visible and none while hidden or covered (live check, Track A ledger); SpriteKit does not draw during a live resize (the watchdog skips it) | Track A progress.md; `checkRendering` | Windows keeps the visible/hidden rule; it keeps drawing during a resize (D4). |
| S13 | `PlazaGIFDecoder` (pure Swift, equal to ImageIO on 1,228 files / 99,000 frames) returns no frame delays; `PlazaSpriteFetching` needs them | `PlazaGIFDecoder.swift` 3–6; `PlazaCharacterLoader.swift` 22 | Task 2 adds delays exactly as `UI/GIFDecoder` computes them. |
| S14 | `windows.yml` fails under 2400 executed tests (3062 at the base); the runner (Server 2025) has an interactive desktop, WARP, and `ptb_capture_screen` exists in `CWinShim` | `.github/workflows/windows.yml`; Track B F18 | Window checks run in the app's `--selftest` on the runner and read the screen back. |

---

## Global Constraints

- **Speed rules (user decision, 2026-11-14) — these override any stricter wording below.** (1) No per-task full Mac gate: a task is verified on the Mac by the filtered suites for what it touched, `./scripts/shared-check.sh`, and (for any change to shared plaza code) the render compare; the full gate `./scripts/test-gate.sh` runs only at milestones (stage 6: after Tasks 3, 11 and 14) and before `windows-port` goes to `main`. (2) Do not wait for Windows CI before merging a task into `windows-port`: merge, let the push run CI, and fix forward if it is red. Tasks whose only proof is Windows CI (Windows-only code) still read their run, but batch several changes per push. (3) Reviews: tasks marked **[most capable]** keep an independent review; other tasks are read by the session lead. The cost accepted: a break found at a milestone is harder to trace to its task; `windows-port` is not released, so nothing reaches users in between.
- **The Mac app must not change.** Every edit to a shared file keeps the Mac byte-identical: `./scripts/plaza-render-compare.sh` prints `RENDER: identical` on every PR that touches `Team/Plaza/**`, `Platform/PlatformPlaza.swift`, `Platform/Mac/Plaza/**` or `Team/UI/**`, and the Mac test that pins the old value is named in the PR. Shared additions used only by Windows (new panels, the line breaker) are tested on the Mac too.
- Work in `.worktrees/<task-branch>` cut from `origin/windows-port`. Never edit the main checkout. No bare `git stash`. Every `gh` call passes `--repo likelion-campus/PokeTokenBar`.
- **One PR per task into `windows-port`, merged with a merge commit.** `git merge --no-ff origin/main` into the task branch at the start of every task. English Conventional Commits title and body per `.agents/skills/prepare-pr/SKILL.md` and `.github/PULL_REQUEST_TEMPLATE.md`. **Visible changes carry images:** before = "no Windows plaza window existed" (first PR of each view) or the previous CI render; after = the Windows CI render (WARP, labelled "Sample-data render, Windows CI (WARP)") next to the Mac harness render of the same scene, or the runner's screen capture of the real window (labelled). Uploaded through the team's PR-image route.
- **One `swift build` / `swift test` / `shared-check.sh` / `plaza-render-compare.sh` at a time on this Mac.** Before each, `pgrep -x swift-build; pgrep -x swift-test; pgrep -x xctest` prints nothing, else wait. Never run the full suite while another session's release gate runs. **Wait in chunks of at most ~150 s per Bash call** (Mac build slot and CI runs alike; COMMON-RULES "Waiting, corrected"); never end a turn waiting for a notification.
- **Windows is verified by pushing and reading the CI run** (`gh workflow run … --ref <branch>`, `gh run view <id> --log`, `gh run download`). Aim for ≤ 5 round trips per task; make every selftest check print one greppable `PASS|FAIL name: detail` line with measured values. Windows CI does not block merges into `windows-port`; it is run on the merged tree after each merge. CI pair fixed: `windows-latest` + Swift `6.3.2-RELEASE`.
- **Where code goes.** Windows-only Swift: `Sources/PokeTokenBar/Platform/Windows/Plaza/**`, each file wrapped whole in `#if os(Windows)`; `WinSDK` and `CPlazaD2D` imported only inside it. C++: only in the Windows-only target `Sources/CPlazaD2D/`, declared under `onWindows` in `Package.swift`; `Package.swift` is edited once (Task 2) and only in its `onWindows` parts; the Mac branch and the `PTB_SHARED_ONLY` pre-check see none of it. Shared files import nothing Apple-only (scan-enforced) and need explicit `import Observation`. Body-level `#if os` only under `Platform/`; on the shared side only `Platform/PlatformPlaza.swift` changes its selection lines. Windows-only tests: `Tests/PokeTokenBarTests/WindowsPlaza*Tests.swift`, wrapped whole. A new `mac-only.txt` entry has a `# why` line above it.
- **Main thread (Track B F4, F16):** every window, WndProc and Direct2D window object lives on the main thread; WndProcs enter app code through `MainActor.assumeIsolated`. The frame clock thread touches no Swift main-actor state: it only calls `PostMessageW` (scan: no `assumeIsolated` and no `DispatchQueue.main` in `WinFrameClock.swift`). Pool-thread callbacks hop with `DispatchQueue.main.async`. Timers: `Timer(fire:interval:repeats:)` only (scan). Exits only through `WindowsApp.exit` (scan). Every window of ours is made through `WinSinkWindow`'s general init.
- **Focus:** only `WinPlazaWindow.bringToFront()` activates (`SetForegroundWindow`, `ShowWindow` with an activating command); it runs only from `show()`, i.e. a user action (tray, notification click, `--open-plaza`). A Windows scan (Task 5) fails on those calls anywhere else in `Platform/Windows/Plaza/`. The shared `testWhatTeammatesAndTimersTriggerNeverBringsThePlazaForward` stays green.
- **Idle cost is a failure condition (spec §2).** Every thread, timer, hook or poll added says what wakes it and how often; a closed plaza costs exactly what it costs today; measurements use cycles and context switches, never `GetProcessTimes` (Track B F20).
- **No code-drawn game art.** Map, characters, effects and icons come from the bundled sheets or the PokéAPI cache; UI glyphs come from system icon fonts (D15). Test fixtures built from bytes are labelled as fixtures.
- **Nothing published, nothing uploaded to third parties** (no VirusTotal or similar), no signing. Pretendard is committed from the official 1.3.9 release with its SHA-256 recorded; nothing is downloaded at build time.
- **Honest stubs and failures:** what is not available reports unavailable and logs once (no UI Automation tree in this stage: one log line; a device that cannot be made: the window says so in the log and the plaza stays closed — never a black window that looks alive).
- Tests: `UserDefaults` only through `TestDefaults.make(suite:)`; every `UsageStore(` passes `providers:`; tests in a `@MainActor` class that run on Windows are `async`; never force-unwrap an async result; no test shows UI that needs a person; `SendInput` only when `CI` is set (Track B rule). Window behaviour is checked in `--selftest` on the runner, not in XCTest.
- Defects follow the defect protocol in `CLAUDE.md` (root cause incl. why tests missed it, class sweep after reading `docs/reference/defect-log.md`, a trigger-branch test after a reachability check, fault injection, a permanent capture). "Green on the Mac, broken on Windows" and "green on WARP, broken on a GPU" are logged as defect classes when met.
- Model per role (user rule): implementers `sonnet`; tasks marked **[most capable]** use `opus` for implementation and review; mechanical commands `haiku`.
- No date, weather or chance gate on any feature without asking (memory note). Mac-side probes never activate the app; renders are offscreen (memory notes "no focus-stealing probes", "offscreen plaza render").

---

## Design decisions (later tasks rely on them)

**D1. Device and presentation: a Direct2D 1.1 device context over DirectComposition, not `ID2D1HwndRenderTarget`.**
- Device chain: `D3D11CreateDevice(HARDWARE, BGRA_SUPPORT)` → `ID2D1Device` → `ID2D1DeviceContext` (single-threaded factory, main thread). WARP when hardware creation fails, or when `PTB_PLAZA_DEVICE=warp` (CI). The adapter's description is logged once and reported by the selftest.
- Window surface: `IDXGIFactory2::CreateSwapChainForComposition` (flip sequential, 2 buffers, `B8G8R8A8_UNORM`, `DXGI_ALPHA_MODE_PREMULTIPLIED`, `SCALING_STRETCH`, `FRAME_LATENCY_WAITABLE_OBJECT`, max latency 1) shown through `DCompositionCreateDevice` → `CreateTargetForHwnd(hwnd, topmost: FALSE)` on a `WS_EX_NOREDIRECTIONBITMAP` window.
- Why not the HWND render target: it cannot show per-pixel transparency (the hidden-background mode makes the plaza see-through on the Mac), has no effects on a snapshot of what was drawn (multiply), and composes no native child above itself; `topmost: FALSE` puts the composition *behind* the window's child controls, which is where the chat `EDIT` must be (D13).
- Every frame is drawn into an offscreen **frame bitmap** (`D2D1_BITMAP_OPTIONS_TARGET`, client size), then blitted to the back buffer and presented with `Present(1, 0)`. The same draw path renders offscreen for the CI harness (no swap chain, read back through a CPU-readable copy). The main thread never blocks on the GPU: a tick whose frame-latency waitable is not signalled skips its draw (counted).
- Units: `D2D1_UNIT_MODE_PIXELS`; all math in device pixels = points × `backingScale`, `backingScale = GetDpiForWindow / 96` exactly (1, 1.25, 1.5, 1.75, 2…), per-monitor DPI v2 (the manifest already declares it).
- **Device loss:** `D2DERR_RECREATE_TARGET` from `EndDraw`, `DXGI_ERROR_DEVICE_REMOVED/RESET` from `Present`/`ResizeBuffers` → rebuild device, context, swap chain and DComp target; bump the device generation; textures re-upload lazily from their `PlazaBitmap`; one log line per loss; three losses within 10 s switch to WARP with a log line. A fault-injection switch in the shim (debug and selftest only) proves the path in CI; the PC proves it with Win+Ctrl+Shift+B (driver reset).

**D2. How the shared tree maps to Direct2D.** One loop over `PlazaDrawOrder.flatten(root:camera:)` builds a flat command array (`PTBDrawCmd`), passed to C++ in one call per frame.

| Shared tree | Direct2D |
|---|---|
| order, ties, crop units, hidden, alpha | `flatten`'s order and accumulated alpha; hidden subtrees are already skipped |
| `transform` (unit square → root or camera space) | world items: × the camera view (translate by −camera position, scale by 1/camera scale, then the viewport centre); screen items: translate to the viewport centre; then y-flip (SpriteKit y up, D2D y down) and × `backingScale`. Without a camera: origin bottom-left (`anchorPoint = .zero`, `.resizeFill`). |
| texture | the image's bitmap with source rect `x = rect.minX·w`, `y = (1 − rect.maxY)·h`, size `rect·(w, h)`; `DrawBitmap(…, D2D1_INTERPOLATION_MODE_NEAREST_NEIGHBOR)` under the item's transform; the context's antialias mode is `ALIASED` (quad edges by pixel centre, as Metal rasterizes) |
| untextured sprite | `FillRectangle` of the unit square in `color` × alpha |
| `colorBlendFactor` on a textured sprite | `ColorMatrix` effect on the source with the coefficients of the formula Task 1 measures from SpriteKit (expected: straight colour mixed toward `color` by the factor, alpha kept) |
| `.alpha` | source-over |
| `.multiply` | `Blend` effect (`MULTIPLY`) of the item over a GPU copy of the frame-bitmap region under it, drawn back with `D2D1_COMPOSITE_MODE_SOURCE_COPY` into that region; formula checked against Task 1's swatches (incl. alpha < 1) |
| `.multiplyX2` | `ArithmeticComposite` (C1 = 2, others 0 unless Task 1 shows SpriteKit adds a destination term) over the same region copy |
| `PlazaCropNode.maskRect` | `PushAxisAlignedClip(aliased)` with the item's clip (already the bounding box in root/camera space) mapped to pixels |
| `backgroundColor`, transparent mode | `Clear(backgroundColor)`; transparent: `Clear(0,0,0,0)` |

Textures: `PlazaImage.backendCache` holds a `WinBitmapRef` (bitmap handle + device generation; release in `deinit`); the image uploads once. `PlazaTexture.nativeCache` holds the source rect into its root parent's bitmap, so cut textures (a swimmer cuts two per frame, Track A task-10 note) never upload. Bitmaps upload from the `PlazaBitmap` bytes as `DXGI_FORMAT_R8G8B8A8_UNORM` premultiplied (`noneSkipLast` as `ALPHA_MODE_IGNORE`); colour space: both `sRGB` and `deviceRGB` are treated as sRGB (the one device-RGB fill, the placeholder gray, is handled by `setFillGray`).

**D3. Dirty frames.** The Windows mirror (`WinNodeMirror`, a `PlazaNodeMirror` subclass installed on every node attached under the stage root) overrides every setter and `insertChild`/`removeFromParent` with one store to `stage.needsDraw = true`. The HUD host, resizes, DPI and background/transparency changes, and device rebuilds also set it. Every tick runs `stageUpdate`; draw and present happen only when something changed. The pixels are the ones a draw-every-frame loop would make; only the cost differs (a standing plaza changes ~10 times a second for the idle animation, not 60).

**D4. The scene clock (`WinFrameClock`).** One thread per open plaza window:
- It loops `IDXGIOutput::WaitForVBlank()` on the output containing the window (re-read on `WM_DISPLAYCHANGE`, a monitor change on `WM_WINDOWPOSCHANGED`, `WM_DPICHANGED`). On every N-th vblank, N = max(1, ⌊refresh / 60⌋) (60 → 60 fps, 75 → 75, 120 → 60, 144 → 72, 165 → 82, 240 → 60), it posts `WM_PTB_PLAZA_FRAME` to the plaza window unless a tick is still pending (atomic flag). Aligning to vblank avoids the judder a strict 60 on a 144 Hz panel would show; the cap keeps fast panels near 60.
- Fallback when there is no output or `WaitForVBlank` fails or returns in < 2 ms five times in a row (WARP, RDP, some hybrid GPUs, display off): a high-resolution waitable timer (`CREATE_WAITABLE_TIMER_HIGH_RESOLUTION`) at 1/60 s. The source in use is logged and reported.
- Stopped means parked on an event with an infinite wait: zero wakeups. It runs only while the window is open and neither `renderLoop.isPaused` nor `stage.isPaused`.
- The main thread's WndProc handles the tick: `QueryPerformanceCounter` seconds (monotonic, process-relative) → `stage.tick(at:)` → `delegate.stageUpdate` → `renderer.drawIfNeeded`.
- Because the tick is a posted window message, Win32's modal loops (window drag and resize, the tray menu, a message box) dispatch it: the plaza keeps animating and drawing while its window is dragged or resized. `isInLiveResize` therefore reports false on Windows (the watchdog keeps watching). `WinModalPump` still runs during size/move (registered on this window) for main-queue work such as the HUD's coalesced renders and the controller's ticks.

**D5. Visible or not → `setRendering(visible:)`.** `visible = shown ∧ ¬minimized ∧ ¬cloaked ∧ session unlocked ∧ displays awake ∧ ¬covered`, reported only on change.

| Mac | Windows signal |
|---|---|
| miniaturize / deminiaturize | `WM_SIZE` `SIZE_MINIMIZED` / `SIZE_RESTORED`, `SIZE_MAXIMIZED` |
| occlusion: other Space | `EVENT_OBJECT_CLOAKED`/`UNCLOAKED` (`SetWinEventHook` limited to our process id) + `DwmGetWindowAttribute(DWMWA_CLOAKED)` |
| screens asleep, lock | `WindowsSystemEvents` display state (existing); `WTSRegisterSessionNotification` → `WM_WTSSESSION_CHANGE` lock/unlock |
| occlusion: covered by windows | a geometric check: our client rect ∩ the monitors' union, minus the extended frame bounds of every visible, uncloaked, non-minimized, non-layered top-level window above ours (`EnumWindows` z order, stop at ours); empty = covered. Run at 1 Hz only while the window is shown and not minimized/cloaked/locked/display-off, and at once on `EVENT_SYSTEM_FOREGROUND` (rare, system-wide) and on our own `WM_WINDOWPOSCHANGED`/`WM_ACTIVATE` |

Why the 1 Hz check: DXGI reports no occlusion for flip-model swap chains, and a system-wide location-change hook would wake us on every mouse move anywhere. Cost: one wakeup a second and ~0.1 ms while the window is open and shown. Consequence: uncovering by moving another window away resumes within ≤ 1 s; activation resumes at once.

**D6. The window (`WinPlazaWindow: PlazaWindowShell, PlazaPanelHost`).**
- Made through `WinSinkWindow(className: "PokeTokenBarPlaza", …)`: `WS_OVERLAPPEDWINDOW`, `WS_EX_NOREDIRECTIONBITMAP`, created hidden in `open`, shown only by `bringToFront` (`ShowWindow(SW_SHOWNORMAL or the saved maximized state)` + `SetForegroundWindow`).
- Default content 960 × 640 DIP centred in the primary work area (the Mac centres). Minimum content 600 × 372 DIP (`PlazaWindowController.minContentSize`) through `WM_GETMINMAXINFO` with `AdjustWindowRectExForDpi`. Title from the controller.
- Frame autosave: key `plaza.windowPlacement` in the app's `WinSyncingDefaults` (normal rect in DIP, monitor device name, maximized flag), written on `WM_EXITSIZEMOVE` and close, restored when the rect intersects a monitor's work area (else centred). After restoring, one `contentHeightDidChange` (what `restoreFrame` does on the Mac). Maximize yes; no full-screen mode in this stage.
- Messages: `WM_PAINT` validated with `BeginPaint`/`EndPaint` (an unvalidated paint loop would spin); `WM_ERASEBKGND` → 1; `WM_SETCURSOR` → arrow; `WM_ENTERSIZEMOVE`/`WM_EXITSIZEMOVE` → `WinModalPump.begin/end("sizemove")`; `WM_SIZE` → `ResizeBuffers`, `stage.size`, `hud.setViewport`, an immediate draw; `WM_DPICHANGED` → `SetWindowPos(suggested)`, new `backingScale`, viewport and buffers; `WM_ACTIVATE` → `didBecomeKey`/`didResignKey` (not when focus only moves to our own child); `WM_CLOSE` → `events.handleClose()` (the controller then calls `stopPresenting` and `dismantle`, which destroys the window inside its own WndProc). Alt+F4 reaches `WM_CLOSE` through `DefWindowProc`.
- `requestClose` sends `WM_CLOSE` (so `handleClose` runs before it returns, as AppKit's `performClose`). The window's `WM_CLOSE` never reaches the sink's app-exit handlers (separate handler list).
- `setTransparent(true)` clears to transparent (the desktop shows through the client area). The title bar and shadow stay, and clicks on transparent pixels still go to the plaza (both differ from the Mac; open question 6).
- IME: `ImmAssociateContextEx(hwnd, nil, 0)` on the window, so walking keys never turn into `VK_PROCESSKEY` while the Korean IME is in Hangul mode; the chat `EDIT` keeps the default context.
- `isFrontmost`: `GetForegroundWindow() == hwnd`. `diagnostics`: (D5's `visible`, `isFrontmost`). `renderLoop`: the `WinPlazaView` that owns the clock.

**D7. Input mapping (`WinPlazaInput`).**
- Key identity: the scan code (`lParam` bits 16–23, extended bit 24) → the macOS virtual key number by position (as `kVK_ANSI_*` are positional), covering every `PlazaKeyCode` plus the keys the scene matches by `characters` ("-", "=", "+"). `characters` from `ToUnicodeEx` with flag 0x4 (no keyboard-state change; Windows 10 1607+) at `WM_KEYDOWN`; dead keys give nil. `isRepeat` = `lParam` bit 30.
- Modifiers (from `GetKeyState`, also for the per-frame poll `PlatformPlaza.currentModifiers()`, the one seam the scene reads; `WinPlazaStage.currentModifiers()` returns the same): Shift → `.shift`; Ctrl → `.command ∪ .control` (Ctrl+W closes, a Ctrl chord blocks emotes and walking, as ⌘ does); Alt → `.option`; the Windows key → nothing (open question 9).
- `WM_SYSKEYDOWN` (Alt chords) goes to the scene too, except Alt+F4 and Alt+Space, which go to `DefWindowProc`; `WM_SYSCHAR` is swallowed (no beep). Focus loss → `didResignKey` (the controller releases held keys).
- Mouse: `WM_LBUTTONDOWN`/`UP` (with `SetCapture` while pressed), `WM_MOUSEMOVE`, `WM_MOUSELEAVE` (`TrackMouseEvent` only while a drawing that `tracksMouse` is under the cursor), `WM_MOUSEWHEEL`/`WM_MOUSEHWHEEL` → `PlazaMouseEvent` in window points, origin top-left, routed by D8.
- Wheel: dy = delta / 120 × `SPI_GETWHEELSCROLLLINES` × 10 pt (10 pt is the Mac host's line step), positive = wheel away from the user, as AppKit's `scrollingDeltaY`; dx from the horizontal wheel with its sign flipped (Windows positive = right). A precision touchpad's small deltas scale the same way.

**D8. Panels: drawn in the same frame, in the Mac's z order, from two kinds of HUD.**
- After the scene, the window draws the shown drawings of this fixed list, bottom first — `PlazaMacWindow`'s subview order: `roster, board, card, photoFrame, menu, pills, chatLog, minimap, clock, shortcuts, backgroundToggle, nameColorPicker, chatBar`.
- The controller's `hud` supplies its eight panels. The shell builds a second `PlazaHUD` from `PlazaOverlayBindings`: `PlazaRosterPanel(model: rosterModel)`, `PlazaBoardPanel(model: overlayModel, feed:, myMemberID:)` (only when `feed` exists), `PlazaCardPanel(model: overlayModel)`, `PlazaChatLogPanel(log: chatLog)`. Its `onAction` calls the binding closures exactly as 17c/d specify: `("roster","select")` → `walkToMember(entry.id)`, `previous`/`next` → `turnRosterPage(∓1)`, `("board","react")` → `react(eventID, kind)`, `("chatLog","toggle")` → `toggleChatLog()`; inert hits are ignored. The chat input (D13) owns a third, the chat bar.
- All three use the window as their `PlazaPanelHost`; the window keeps `[PlazaPanelID: (drawing, frame, scale, owner HUD)]`. Clicks go to the top-most shown panel whose owner reports a hit (`hud.hit(at:in:)`), then `handleMouse(_:in:)` on that owner; a click no panel takes goes nowhere (the scene takes no mouse).
- Image layers upload once per `PlazaImage` and draw 1:1 at `frame × scale` (nearest); colour layers are `FillRectangle`s.
- `setHUDHidden` hides exactly the Mac's `hudViews` set: roster, chatLog, minimap, clock, shortcuts, backgroundToggle, nameColorPicker. `setChatLogAboveInput` sets the chat log panel's `inputHeight` from the chat bar's height.
- Tooltips: one comctl32 v6 tooltip window with one rect tool per `PlazaTooltip`, rebuilt only when a drawing's tooltips or frame change.
- Accessibility items stay in the drawings; no UI Automation tree in this stage (one log line; open question 2). The native `EDIT` is accessible by itself.
- Why one frame and not child surfaces per panel: the scene redraws in the same frame anyway, panels are a handful of small bitmaps, z order is one list, and there are no extra composition surfaces to keep in sync during a resize.

**D9. The canvas (`WinPlazaCanvas`): Direct2D on a WIC bitmap.**
- `ID2D1Factory::CreateWicBitmapRenderTarget` on a multi-threaded factory, queried for `ID2D1DeviceContext` (effects).
- Why: the CPU rasterizer gives the same bytes on the runner and on the user's PC; `withPixels` is a lock, not a GPU readback (Track A ledger note); canvases can be made off the main actor, as art builders do.
- Format: 32bpp premultiplied RGBA when Direct2D accepts it for a WIC target, else PBGRA with a swizzle in `withPixels` and `makeImage` (Task 8's first test decides).
- CG conventions: the base transform flips y once; images and text get a local un-flip about their own rect or baseline so they are upright.
- Swift keeps CoreGraphics' state stack (CTM, alpha, blend, fill and stroke colour, line width, join, cap, shadow, the three antialias flags, interpolation, text mode); clips pushed since the last `saveState` are popped by `restoreState`.
- Each operation's mapping is in Interfaces. `makeImage` returns `PlazaImage(bitmap:origin:)`.

**D10. Text (`WinPlazaTextEngine`): DirectWrite.**
- Fonts: a private collection (`IDWriteFactory5` font set builder) from the bundled files: Galmuri11/14 for `.plaza`, Pretendard Regular / SemiBold / Bold for `.system`. `.emoji` = Segoe UI Emoji. Anything a font lacks falls back through the system font fallback (emoji in a Galmuri line → Segoe UI Emoji; Hanja/kana → the system's CJK fonts).
- Metrics: the font's own `hhea` ascender / descender / line gap × size / unitsPerEm. These are the values CoreText reports for Galmuri (pinned by Task 1's golden); DirectWrite's default metrics come from other tables and could differ.
- Lines: an `IDWriteTextLayout` per line with no wrapping. Its width is the line's width; ascent and descent are the font metrics, as `CTLineGetTypographicBounds`. Runs keep their own colour (per-range brush drawing effect).
- Truncation: drop end clusters until text + "…" fits (as `CTLineCreateTruncatedLine(.end)`; nil when even "…" does not fit).
- Wrapping, for both `wrappedLines` (rule `.swiftUIText`: Korean words whole, TextKit `.standard`) and `paragraph` (rule `.coreTextFrame`): DirectWrite cluster metrics plus its UAX #14 break opportunities, fed to the shared `PlazaLineBreaker`, whose rules are pinned against TextKit and CTFramesetter on the Mac with Galmuri (same font file, so the same advances).
- RTL: base direction from the first strong character (Hebrew/Arabic/Syriac/Thaana/NKo ranges and presentation forms = RTL).
- Drawing: colour glyphs with `D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT`; grayscale antialiasing, or `ALIASED` where the canvas turned antialiasing off (the chat bubble); never ClearType (transparent canvases, as CG does).
- Stroke mode (the plate outline): the glyph run's outline geometry stroked with the canvas's stroke colour, width and join; runs in a colour font are skipped in stroke mode (Apple's bitmap emoji draw no stroke either). Shadow: D9. `imageBounds`: `GetGlyphRunWorldBounds` relative to the origin.
- Parity target: line breaks, line counts, `suggestedSize`, `visibleLength` and frames identical to the Mac for the Galmuri corpus; Pretendard against the Mac system font differs by decision (spec §5) and is reported, not failed; glyph pixels may differ.

**D11. Images, codecs, resources.**
- On Windows every image is a `PlazaBitmap`; there is no Windows `PlazaNativeImage`.
- PNG decode: WIC → straight RGBA8 → shared `PlazaPremultiply` with CoreGraphics' rounding, so `pixels` are byte-equal to the Mac's for every bundled PNG (Task 1 golden).
- GIF: the shared `PlazaGIFDecoder` (proven equal to ImageIO), extended with frame delays (Task 2). WIC's GIF frames are uncomposited sub-frames, so WIC would mean writing disposal again.
- PNG encode: WIC from `PlazaPremultiply.straight` (CoreGraphics' un-premultiply).
- Resources are not SwiftPM resources on Windows. `assetURL` searches, in order: the `;`-separated directories in `PTB_PLAZA_RESOURCES` (tests and CI; allow-listed in `UsageEnvironmentTests`), then `<exe folder>\Resources\Plaza`. `package.ps1` copies `Sources/PokeTokenBar/Resources/Plaza/*` and `windows/resources/Plaza/*` (Pretendard + its OFL text) there.
- `CREDITS.md` gains the Pretendard line; `windows/licenses/map.txt` gains the font files.

**D12. Sprites and icons come from `SpriteStore`, in shared code.**
- `PlazaStoreSpriteFetcher` ports `LivePlazaSpriteFetcher` + the `SpriteLoader` paths it uses (front GIF; back GIF shiny then plain; still PNG with shiny → plain → front fallbacks; 404-is-final for back sprites) over `SpriteStore.shared` (already shared, uses `FoundationNetworking`) + `graphics.decodeImage` + `PlazaGIFDecoder.framesWithDelays`.
- `PlazaEggCrop` ports `SpriteLoader.cropToContent` over `PlazaBitmap`. `PlazaStoreIconSource` ports `PlazaIconLoader` (cache file `icon-<id>.png` in the sprite folder; the URL constant moves to shared `PlazaIconStore`, which the Mac file then reads).
- The Mac keeps its own loaders (Track A ruling 5); Mac tests prove the shared ports give the same pixels and delays on the same cache files.

**D13. The chat line: a native `EDIT` child over the composition; chrome drawn as a shared panel.**
- Text area: an `EDIT` (`ES_AUTOHSCROLL`, single line) child of the plaza window, placed on the chat bar panel's field rect (pixels). It is visible because the composition sits behind children (D1 `topmost: FALSE`). Task 11's first CI check reads the screen: if a plain child is not composed over a `WS_EX_NOREDIRECTIONBITMAP` parent, the `EDIT` goes into a `WS_EX_LAYERED` child container; if neither shows, the fallback is an owned popup (`WS_POPUP`, owned by the plaza, kept on the field rect on every move and size, `WM_NCACTIVATE` keeping the plaza's title active).
- Font: Galmuri14 at 15 pt × scale through a private GDI font (`AddFontResourceExW(FR_PRIVATE)`); white text on the bar colour (`WM_CTLCOLOREDIT`); the placeholder through `EM_SETCUEBANNER` (shown while focused; system gray instead of white 60 % — a listed difference). Emoji typed into the field show monochrome (GDI); the sent bubble is in colour (open question 5).
- Chrome: shared `PlazaChatBarPanel` (bar fill `1D4F5C` α 0.95, 2 pt border white 50 % or orange `F08A24` when loud, radius 6, the 😀 button, the 10 × 4 emoji grid of `PlazaChatEmojis.all` above the field when open), drawn in its own HUD at the top of D8's list; a grid pick inserts with `EM_REPLACESEL` and focus stays in the field (our panel area is not a window).
- Keys (subclassed `EDIT`): Enter → when an IME composition is open (`ImmGetCompositionStringW(GCS_COMPSTR)` non-empty) complete it (`ImmNotifyIME(NI_COMPOSITIONSTR, CPS_COMPLETE)`) and do not send, as the Mac does; a repeated Enter (bit 30) does nothing; else `onSubmit(text)` and close when accepted. Tab / Shift+Tab → `isLoud.toggle()`. Esc → close.
- Focus: `EN_KILLFOCUS` to another window of ours closes the chat; deactivating the app does not.
- IME: the `EDIT` keeps the thread's IME context. `WinMessageHook` re-dispatches `WM_IME_CHAR` (0x0286) like `WM_CHAR`, because CF's ANSI pump would turn Hangul into "?" on an English-locale PC (Track B F15). Win+. (the emoji panel) inserts through the same path. PC checks on a Korean-locale and an English-locale Windows.

**D14. Clipboard (`WinImageClipboard: ImageClipboarding`).** One `OpenClipboard(sink)` (retried 5 × 20 ms) / `EmptyClipboard` / `SetClipboardData` for the registered `"PNG"` format (the bytes, read by browsers, Office, Slack, Discord) and `CF_DIBV5` (32-bpp `BI_BITFIELDS` with alpha, decoded from the same PNG, read by Paint and older apps; Windows synthesizes `CF_DIB`/`CF_BITMAP`). False and one log line on failure.

**D15. Symbols.** `PlatformPlaza.symbolImage` on Windows draws `eye` → U+E890 (View) and `eye.slash` → U+ED1A (Hide) from Segoe Fluent Icons (Windows 11) or Segoe MDL2 Assets (Windows 10) at the point size, tinted, and returns the glyph's layout size; other names → nil (the panel's own fallback). The chevrons are already paths.

**D16. COM.** `WindowsApp` initializes the UI thread as STA (`CoInitializeEx(COINIT_APARTMENTTHREADED)`) before anything touches COM; the shim's later `CoInitializeEx(MTA)` there returns `RPC_E_CHANGED_MODE`, which it already tolerates, and WIC works in an STA. Other threads that use WIC get MTA once per thread (a `thread_local` guard in `CPlazaD2D`).

**D17. What tests get on Windows.**
- Real in tests too, as the Mac's tests use CoreGraphics: `PlatformPlaza.graphics` (`WinPlazaGraphics`), `clipboard`, `symbolImage`, `spriteFetcher` and `iconSource` (both over a test sprite folder where a test needs pictures).
- Real only after the app calls `WinPlazaLive.install(…)` at launch: `makeStage`, `makeShell` and `makeChatInput`. XCTest keeps `PlazaHeadlessStage`, `PlazaHeadlessShell` and `PlazaStubChatInput`.
- The selection lines become `#if os(Windows)` → Windows, `#elseif PTB_SHARED_ONLY` → today's stubs, else the Mac.
- `windows.yml` sets `PTB_PLAZA_RESOURCES` to the checkout's two resource folders. `testBundledPlazaArtIsFoundOnWindows` fails on CI when the art is missing.

**D18. The four content panels are used on Windows from day one** (D8). Nothing in the pending Mac decision (keep SwiftUI or switch) blocks it. When the Mac switches, the panels move from the two shells into the controller's HUD in one shared change.

**D19. Idle and cost budgets** (guesses; the first runs record numbers in the PR; tightened after the PC numbers; spec §2 failure condition).

| State | CI (runner, release build; selftest + `measure-idle.ps1`) | PC (user's laptop, 10 min each) |
|---|---|---|
| closed (never opened; opened then closed) | Track B Task 12 budgets unchanged; after a close: no plaza thread, handles within +10 of before, private bytes within +20 MB after 10 s | equal to the stage 4/5 numbers within noise |
| open, minimized / covered / locked / display off | frame-clock thread 0 context switches; main ≤ 150 cs/min (two 1 s controller ticks + the 1 Hz cover check); 0 presents | CPU ≤ closed + 0.3 % of total; GPU 3D 0 % |
| open, visible, nobody moving | ticks 60 ± 3/s on a 60 Hz output (fallback timer on the runner); draws ≤ 20/s; our main-thread code ≤ 1.0 ms per drawn frame and ≤ 0.1 ms per undrawn tick | CPU ≤ 3 % of total and GPU 3D ≤ 5 % on an integrated GPU; the Mac's visible idle plaza measured side by side |
| open, `rush-hour` (12 teammates moving, snow, fireworks, campfire) | update + flatten + command building ≤ 4 ms per frame; WARP raster time reported separately (WARP is CPU rendering) | ≥ 55 frames/s; CPU and GPU reported |
| memory | 12 teammates open: private growth ≤ 250 MB; close: back within 30 MB in 10 s | the same, plus GPU dedicated memory reported |

**D20. Minimum Windows: 10 22H2 x64 (build 19045)**, as G1. Every API used exists there:
- DirectComposition and `DWMWA_CLOAKED`: Windows 8.
- `IDWriteFactory5` font sets and per-monitor DPI v2: 1703.
- High-resolution waitable timers: 1803.
- `ToUnicodeEx` flag 0x4: 1607.
- Segoe Fluent Icons exists only on 11, so MDL2 is the fallback.

CI runs Server 2025 (the Windows 11 code base), so Windows 10 is checked only on a Windows 10 PC (open question 4).

---

## Interfaces (the contract later tasks rely on)

Signatures, not bodies. Shared files in `Sources/PokeTokenBar/Team/Plaza/…`; Windows files in `Sources/PokeTokenBar/Platform/Windows/Plaza/`; C in `Sources/CPlazaD2D/`.

```swift
// ---- Shared (both OSes build and test these) ----

// Draw/PlazaImage.swift (Task 1): where an image came from, for the cross-OS compare. No pixel effect.
enum PlazaImageOrigin: Sendable { case pixels, canvas, canvasWithText }
final class PlazaImage { init(bitmap: PlazaBitmap, origin: PlazaImageOrigin = .pixels); init(native: any PlazaNativeImage, origin: PlazaImageOrigin = .pixels)
                         let origin: PlazaImageOrigin }   // CGPlazaCanvas.makeImage and WinPlazaCanvas.makeImage set .canvas / .canvasWithText

// Draw/PlazaPremultiply.swift (Task 1)
enum PlazaPremultiply {
    /// Straight RGBA8 (row 0 top) → premultiplied, with CoreGraphics' rounding (Task 1 golden over every bundled PNG).
    static func bitmap(straight: [UInt8], width: Int, height: Int) -> PlazaBitmap
    /// The inverse CoreGraphics applies when ImageIO writes a PNG.
    static func straight(_ bitmap: PlazaBitmap) -> [UInt8]
}

// Draw/PlazaContinuousCorners.swift (Task 1): SwiftUI's `.continuous` corners as Bézier elements, canvas coordinates
enum PlazaCurveElement: Equatable, Sendable { case move(CGPoint), line(CGPoint), curve(to: CGPoint, c1: CGPoint, c2: CGPoint), close }
enum PlazaContinuousCorners {
    static func roundedRect(_ rect: CGRect, radius: CGFloat) -> [PlazaCurveElement]
    static func unevenRoundedRect(_ rect: CGRect, radii: PlazaCornerRadii) -> [PlazaCurveElement]   // top = maxY, as the canvas
}

// Draw/PlazaLineBreaker.swift (Task 1 rules + goldens; Task 9 feeds it)
struct PlazaBreakCluster: Equatable, Sendable {
    var utf16: Range<Int>; var width: CGFloat
    var isWhitespace: Bool, isNewline: Bool
    var canBreakAfter: Bool      // the engine's UAX #14 opportunity
    var isHangul: Bool           // the cluster's first scalar is a Hangul syllable or jamo
}
enum PlazaLineBreaker {
    enum Rule: Sendable { case swiftUIText /* TextKit .standard: Korean words whole */, coreTextFrame /* CTFramesetter */ }
    /// Line ranges (UTF-16), trailing white space dropped; an empty text is one empty line; a word wider than `width`
    /// breaks between clusters.
    static func lines(_ clusters: [PlazaBreakCluster], width: CGFloat, rule: Rule) -> [Range<Int>]
}

// Draw/PlazaGIFDecoder.swift (Task 2)
extension PlazaGIFDecoder { static func framesWithDelays(from data: Data) -> [(bitmap: PlazaBitmap, delay: TimeInterval)] }   // delays as UI/GIFDecoder

// PlazaStoreSpriteFetcher.swift, PlazaStoreIconSource.swift, PlazaEggCrop.swift, PlazaIconStore.swift (Task 3)
struct PlazaStoreSpriteFetcher: PlazaSpriteFetching { init(store: SpriteStore = .shared, graphics: any PlazaGraphics = PlatformPlaza.graphics) }
@MainActor final class PlazaStoreIconSource: PlazaIconSource { init(store: SpriteStore = .shared, graphics: any PlazaGraphics = PlatformPlaza.graphics,
                                                                     fetch: @escaping (URL) async -> Data? = PlazaIconStore.download) }
enum PlazaEggCrop { static func square(_ image: PlazaImage) -> PlazaImage }   // SpriteLoader.cropToContent
enum PlazaIconStore { static func url(speciesID: Int) -> URL; static func fileName(speciesID: Int) -> String
                      static func download(_ url: URL) async -> Data? }   // the Mac's PlazaIconLoader reads url/fileName from here

// HUD/PlazaChatBarPanel.swift (Task 11); PlazaPanelID gains .chatBar
enum PlazaChatEmojis { static let all: [String]; static let columns = 10; static let cell: CGFloat = 32 }   // moved from PlazaChatInput (the Mac reads it)
@MainActor final class PlazaChatBarPanel: PlazaPanel {
    init(fieldHeight: CGFloat)                       // the Galmuri body line height, rounded up (the Mac's fieldHeight)
    var isOpen: Bool; var isLoud: Bool; var isEmojiOpen: Bool
    var fieldRect: CGRect { get }                    // panel points, top-left: where the native field goes
    // hits: ("emoji") the 😀 button, ("pick", i) a grid cell, ("bar") the rest of the plate; anchor .bottomLeading, offset (16, 16), width PlazaChatLog.width
}

// ---- Windows only (#if os(Windows)) ----

@MainActor enum WinPlazaLive {
    static private(set) var isInstalled: Bool
    static func install(sink: WinSinkWindow, defaults: WinSyncingDefaults, events: WindowsSystemEvents?)   // WindowsAppDelegate.launch
}
final class WinPlazaGraphics: PlazaGraphics, @unchecked Sendable {
    static let shared: WinPlazaGraphics                // PlatformPlaza.graphics on Windows
    let text: any PlazaTextEngine                      // WinPlazaTextEngine
    func makeCanvas(width:height:colorSpace:) -> (any PlazaCanvas)?; func assetURL(_:ext:) -> URL?
    func decodeImage(at:) -> PlazaImage?; func decodeImage(_:) -> PlazaImage?; func decodeImageFrames(at:) -> [PlazaImage]; func encodePNG(_:) -> Data?
    static func resourceDirectories(environment: [String: String], executableDirectory: URL) -> [URL]
}
final class WinPlazaCanvas: PlazaCanvas            // D9; one WIC bitmap + D2D target per canvas
struct WinPlazaTextEngine: PlazaTextEngine          // D10; lines carry a WinTextLineRef (C handle, released on deinit) in `native`
struct WinImageClipboard: ImageClipboarding         // D14
enum WinPlazaSymbols { static func image(named: String, pointSize: CGFloat, weight: PlazaFontWeight, scale: CGFloat, color: PlazaColor) -> (image: PlazaImage, size: CGSize)? }
enum WinPlazaInput {
    static func macKeyCode(scanCode: UInt32, extended: Bool) -> UInt16?
    static func keyEvent(wParam: WPARAM, lParam: LPARAM) -> PlazaKeyEvent?
    @MainActor static func currentModifiers() -> PlazaModifiers
    static func wheel(delta: Int32, horizontal: Bool, linesPerNotch: Int) -> (dx: CGFloat, dy: CGFloat)
}
@MainActor final class WinPlazaStage: PlazaStage {
    init(size: CGSize)
    var backingScale: CGFloat? { get }; func setBackingScale(_ s: CGFloat)    // set by the window (DPI) or the harness
    private(set) var needsDraw: Bool; func didDraw()                          // D3
    func tick(at seconds: TimeInterval)                                       // the clock's tick: stageUpdate unless paused
    func key(down e: PlazaKeyEvent); func key(up keyCode: UInt16)             // from the window
}
@MainActor final class WinPlazaRenderer {
    init(surface: WinGfxSurface)
    func drawIfNeeded(stage: WinPlazaStage, panels: [WinPanelDraw], transparent: Bool) -> WinDrawResult   // .drawn, .clean, .gpuBusy, .deviceLost
    private(set) var stats: WinRenderStats                                    // ticks, draws, skips, CPU per frame (cycles), WARP time
}
final class WinFrameClock: @unchecked Sendable {
    enum Source: Equatable { case vblank(refreshHz: Double), timer60 }
    init(window: HWND, message: UINT)
    func setRunning(_ on: Bool)                       // main thread; parks the thread when off
    var source: Source { get }; var ticksPosted: Int { get }
}
@MainActor final class WinPlazaView: PlazaPausableView { var isPaused: Bool }   // owns the clock; the controller's renderLoop
@MainActor final class WinPlazaVisibility { var visible: Bool { get }; var onChange: ((Bool) -> Void)?   // D5
                                            func start(window: HWND, events: WindowsSystemEvents?); func stop(); var coverChecks: Int { get } }
@MainActor final class WinPlazaWindow: PlazaWindowShell, PlazaPanelHost {
    init(placementKey: String = "plaza.windowPlacement", defaults: UserDefaults, allowActivation: Bool = true)
    // PlazaWindowShell + PlazaPanelHost as in the contract; selftest reads: hwndForTesting, frameBitmapForTesting(), stats
}
@MainActor final class WinPlazaChatInput: PlazaChatInputHost { let bar: PlazaChatBarPanel; let hud: PlazaHUD   // D13
                                                               func attach(to window: WinPlazaWindow); func detach() }
@MainActor final class WinPlazaTooltips { init(owner: HWND); func set(_ tips: [(rect: CGRect, text: String)]) }   // D8
enum WinPlazaPlacement { static func restore(…) -> RECT?; static func save(…) }                                 // D6
```

`Platform/PlatformPlaza.swift` selection (Task 2 for graphics/clipboard/symbols, Task 3 sprites/icons, Task 5 stage/shell, Task 11 chat input):

```swift
#if os(Windows)      // WinPlazaGraphics.shared, WinImageClipboard(), WinPlazaInput.currentModifiers(),
                     // WinPlazaLive.isInstalled ? WinPlazaStage/WinPlazaWindow/WinPlazaChatInput : the headless ones,
                     // WinPlazaSymbols.image, PlazaStoreSpriteFetcher(), PlazaStoreIconSource()
#elseif PTB_SHARED_ONLY   // today's stubs, unchanged (the Mac checking the shared set)
#else                // the Mac, unchanged
#endif
```

`CPlazaD2D.h` (plain C; opaque handles; every function returns an `HRESULT`-like int unless noted; `ptb_plaza_last_error()` gives text):

```c
typedef struct PTBGfxDevice PTBGfxDevice; typedef struct PTBGfxSurface PTBGfxSurface;
typedef struct PTBCanvas PTBCanvas; typedef struct PTBText PTBText; typedef struct PTBTextLine PTBTextLine;

// device and scene (main thread)
PTBGfxDevice *ptb_gfx_device_create(int forceWarp, uint16_t *adapter, uint32_t adapterCap);
uint32_t ptb_gfx_device_generation(PTBGfxDevice *);
PTBGfxSurface *ptb_gfx_surface_window(PTBGfxDevice *, void *hwnd, uint32_t w, uint32_t h);   // composition swap chain + DComp target (topmost FALSE)
PTBGfxSurface *ptb_gfx_surface_offscreen(PTBGfxDevice *, uint32_t w, uint32_t h);
int ptb_gfx_surface_resize(PTBGfxSurface *, uint32_t w, uint32_t h);
uint32_t ptb_gfx_bitmap(PTBGfxDevice *, const uint8_t *rgba, uint32_t w, uint32_t h, uint32_t stride, int opaque);   // 0 = failed
void ptb_gfx_bitmap_release(PTBGfxDevice *, uint32_t handle);
typedef struct { uint8_t kind /*bitmap, colour*/, blend /*alpha, multiply, multiplyX2*/, hasClip, pad;
                 uint32_t bitmap; float src[4]; float m[6] /*to target pixels*/; float opacity; float color[4] /*straight*/;
                 float colorBlend; float clip[4] /*target pixels*/; } PTBDrawCmd;
int ptb_gfx_frame(PTBGfxSurface *, const float clear[4], const PTBDrawCmd *cmds, uint32_t n);   // into the frame bitmap
int ptb_gfx_present(PTBGfxSurface *);          // S_FALSE: skipped, GPU behind (waitable not signalled)
int ptb_gfx_read(PTBGfxSurface *, uint8_t *rgba, uint32_t stride);    // the frame bitmap (harness, selftest)
int ptb_gfx_wait_vblank(PTBGfxSurface *, double *refreshHz);          // the clock thread only
void ptb_gfx_inject_fault(PTBGfxDevice *, int kind);                  // selftest/debug: next EndDraw reports RECREATE_TARGET
void ptb_gfx_release(void *);                                         // device or surface

// canvas (any thread; WIC + multi-threaded D2D factory)
PTBCanvas *ptb_canvas_create(uint32_t w, uint32_t h);
// primitives take the full state from Swift: transform, colour, opacity, antialias, line width/join/cap, composite mode
int ptb_canvas_fill_rect / fill_ellipse / stroke_ellipse / fill_path / stroke_path (… PlazaCurveElement-like arrays …);
int ptb_canvas_draw_bitmap(PTBCanvas *, const uint8_t *rgba, uint32_t w, uint32_t h, uint32_t stride, const float m[6], const float dst[4], float opacity, int nearest);
int ptb_canvas_draw_line(PTBCanvas *, PTBTextLine *, const float m[6], const float rgba[4], int stroke, float lineWidth, int roundJoin, int aliased);
int ptb_canvas_push_clip_rect / push_clip_path / pop_clip;  int ptb_canvas_begin_shadow / end_shadow(offset, blur, rgba);
int ptb_canvas_lock(PTBCanvas *, uint8_t **bytes, uint32_t *stride); int ptb_canvas_unlock(PTBCanvas *);   // withPixels
int ptb_canvas_copy_rgba(PTBCanvas *, uint8_t *out, uint32_t stride);                                     // makeImage

// text (any thread)
PTBText *ptb_text_create(const uint16_t *const *fontPaths, uint32_t n);
int ptb_text_font_metrics(PTBText *, int family /*galmuri11, galmuri14, pretendard, emoji*/, int weight, float size, float out[3]);   // hhea
PTBTextLine *ptb_text_line(PTBText *, const uint16_t *utf16, uint32_t len, const PTBRun *runs, uint32_t nRuns, int rtl, float out[4]);
int ptb_text_line_clusters(PTBTextLine *, PTBCluster *out, uint32_t cap);     // width, flags (whitespace, newline, canBreakAfter)
int ptb_text_line_ink_bounds(PTBTextLine *, float out[4]);
void ptb_text_line_release(PTBTextLine *);
// codecs (any thread; COM per thread)
int ptb_wic_decode_straight_rgba(const uint8_t *data, size_t len, uint32_t *w, uint32_t *h, uint8_t **rgba);
int ptb_wic_encode_png_straight_rgba(const uint8_t *rgba, uint32_t w, uint32_t h, uint8_t **png, size_t *len);
```

**Canvas operation mapping (D9)** — what Task 8 implements and tests one by one:

| `PlazaCanvas` | Windows |
|---|---|
| `saveState`/`restoreState` | Swift state stack; pop the clips pushed at this level |
| `translate`/`scale`/`rotate` | CTM in Swift (CG order: the new transform first) |
| `setAlpha` | opacity × every brush and bitmap draw (per call, as CG) |
| `setBlend(.normal/.sourceAtop/.multiply)` | normal: source-over; sourceAtop: the primitive as a command list drawn with `D2D1_COMPOSITE_MODE_SOURCE_ATOP`; multiply: `Blend(MULTIPLY)` over a copy of the region, drawn back with `SOURCE_COPY` |
| `setFillColor`/`setStrokeColor` | solid brushes (straight sRGB → premultiplied by D2D) |
| `setFillGray(g)` | the byte CoreGraphics writes for device gray `g` (0.55 → 158), per the Task 1 golden |
| `setLineWidth`/`setLineJoin`/cap | `ID2D1StrokeStyle` (miter / round join; butt / round cap) |
| `setShadow` | the primitives between this and the next `setShadow` record into a command list; `Shadow` effect (σ = blur / 2 — calibrated against Task 1's plate golden) at the offset (device pixels, y flipped), drawn under the content |
| `setShouldAntialias`/`setAllowsAntialiasing` | `ALIASED` unless both are on (CG's rule) |
| `setShouldSmoothFonts` | grayscale vs grayscale (no ClearType on transparent canvases; recorded for parity, no visible effect, as CG without AA) |
| `setInterpolationNone` | nearest for later `draw(image)`; default linear |
| `setTextDrawingMode` | fill → glyph run draw; stroke → outline geometry stroke (D10) |
| `clip(to:)`, `clip(toRoundedRect:)`, `clip(toUnevenRoundedRect:)` | `PushAxisAlignedClip` when the CTM is axis-aligned, else `PushLayer` with the geometry mask; rounded ones use `PlazaContinuousCorners` geometry |
| `fill`, `fillEllipse`, `strokeEllipse`, `fillPath` (winding), `strokePath` | `FillRectangle`, `FillEllipse`, `DrawEllipse`, path geometries |
| `fill/strokeRoundedRect`, `fill/strokeUnevenRoundedRect` | path geometry from `PlazaContinuousCorners`; strokes centred |
| `draw(_:in:)` | `DrawBitmap` with a local un-flip about the rect |
| `draw(_ line:at:)`, `draw(_ paragraph:in:)` | D10; the paragraph lays out from the rect's top, line height = ascent + descent + leading, centred when asked, lines past the height dropped |
| `imageBounds(of:)` | D10 |
| `withPixels` | `EndDraw`, lock the WIC bitmap (swizzle if PBGRA), body, unlock, `BeginDraw` |
| `makeImage` | copy to `PlazaBitmap` → `PlazaImage(bitmap:origin:)` |

---

## File Structure

```
Package.swift                                         modify (T2): CPlazaD2D target + PokeTokenBar links (imm32, dwmapi, wtsapi32, comctl32) — onWindows parts only
Sources/CPlazaD2D/include/CPlazaD2D.h                 create (T2), grows T4, T8, T9
Sources/CPlazaD2D/{codec.cpp (T2), device.cpp (T4), canvas.cpp (T8), text.cpp (T9)}   create
Sources/CWinShim/wic.cpp                              untouched (STA is set by WindowsApp before it runs)
Sources/PokeTokenBar/Team/Plaza/Draw/
  PlazaImage.swift                                    modify (T1): origin
  PlazaPremultiply.swift, PlazaContinuousCorners.swift, PlazaLineBreaker.swift   create (T1)
  PlazaGIFDecoder.swift                               modify (T2): framesWithDelays
Sources/PokeTokenBar/Team/Plaza/
  PlazaStoreSpriteFetcher.swift, PlazaStoreIconSource.swift, PlazaEggCrop.swift, PlazaIconStore.swift   create (T3)
  HUD/PlazaPanel.swift (+ .chatBar), HUD/PlazaChatBarPanel.swift, PlazaChatEmojis.swift                 modify/create (T11)
Sources/PokeTokenBar/Platform/PlatformPlaza.swift      modify (T2, T3, T5, T11): selection lines only
Sources/PokeTokenBar/Platform/Mac/Plaza/CGPlazaCanvas.swift   modify (T1): makeImage sets origin (one line)
Sources/PokeTokenBar/Team/UI/PlazaIconLoader.swift, PlazaChatInput.swift   modify (T3, T11): read the moved constants (byte-identical behaviour)
Sources/PokeTokenBar/Platform/Windows/
  WindowsApp.swift                                    modify (T2: STA; T5: WinPlazaLive.install, plaza wiring, tray/notification/--open-plaza)
  WinMessageHook.swift                                modify (T11): WM_IME_CHAR re-dispatched
  WindowsSelftest*.swift                              modify/create (T5, T16): plaza.* checks (WindowsSelftestPlaza.swift)
  Plaza/ WinPlazaGraphics.swift, WinPlazaCodecs.swift, WinPlazaAssets.swift (T2); WinPlazaGfx.swift (device/surface/bitmap refs),
         WinPlazaRenderer.swift, WinNodeMirror.swift, WinPlazaStage.swift (T4); WinFrameClock.swift, WinPlazaView.swift,
         WinPlazaWindow.swift, WinPlazaVisibility.swift, WinPlazaPlacement.swift, WinPlazaLive.swift (T5); WinPlazaInput.swift (T6);
         WinPlazaCanvas.swift (T8); WinPlazaTextEngine.swift (T9); WinPlazaSymbols.swift, WinPlazaTooltips.swift, WinPlazaPanels.swift (T10);
         WinPlazaChatInput.swift (T11); WinImageClipboard.swift (T12)
Sources/PokeTokenBar/Platform/TrayMenuModel.swift      modify (T5): .openPlaza item while the team is ready (shared, both OSes test it)
windows/resources/Plaza/{Pretendard-Regular.otf, Pretendard-SemiBold.otf, Pretendard-Bold.otf, Pretendard-OFL.txt}   create (T2)
windows/licenses/map.txt, Sources/PokeTokenBar/Resources/Plaza/CREDITS.md   modify (T2)
scripts/windows/package.ps1                           modify (T2): Resources\Plaza in the bundle
scripts/plaza-render-cross.sh                         create (T15): download a Windows render artifact, render the Mac set, compare
.github/workflows/windows.yml                         modify (T2: PTB_PLAZA_RESOURCES; T14: floor; T15: render job + artifact)
.github/workflows/windows-app.yml                     modify (T5, T16): plaza selftest group, plaza idle windows
Tests/PlazaParityGoldens/                             create (T1): small JSON + a few tiny PNGs (≤ 200 KB total), outside the test target
Tests/PokeTokenBarTests/
  PlazaParityGoldens+Mac.swift                        create (T1): writes (env-gated) and re-checks the goldens on the Mac
  PlazaPremultiplyTests, PlazaContinuousCornersTests, PlazaLineBreakerTests (shared, T1); PlazaGIFDelayTests (T2);
  PlazaStoreSpriteFetcherTests, PlazaEggCropTests (shared, T3) + PlazaStoreSpriteParityTests+Mac (T3); PlazaChatBarPanelTests (T11)
  PlazaRender/PlazaTreeDump.swift                     create (T1): the shared-tree dump (SK dump format); shared from T15
  PlazaRenderScenes.swift                             modify (T15): shared (fixtures from PlazaBitmap)
  PlazaRender/PlazaCrossRenderCompareTests+Mac.swift  create (T15)
  WindowsPlaza{Graphics,Renderer,Input,Canvas,Text,Panels,Clipboard,RenderHarness}Tests.swift   create (T2–T15)
  mac-only.txt, shared-floor.txt                      every task as needed
docs/reference/defect-log.md, CONTRIBUTING.md, spec §5/§6/§9.1/§10/§13   modify (T7, T13, T17)
```

## Review Focus

Five ways this could look done and be wrong:

1. **Right on WARP in CI, wrong on a GPU, at 125 %, or after a device loss.** Nearest sampling at half pixels, `ColorMatrix`/`Blend` precision, a stale texture after a rebuild, a swap chain left at the old DPI. → Task 1 swatch goldens checked on WARP *and* on the PC (`plaza.gpuParity`: hardware against WARP on the same scene); a synthetic `WM_DPICHANGED` in the selftest; injected device loss in CI and Win+Ctrl+Shift+B on the PC; renders at 1.25 and 1.5 in the harness.
2. **Idle burned where nobody looks.** A clock thread whose `WaitForVBlank` returns at once while the display is off (a busy loop), an unvalidated `WM_PAINT` loop, a cover check left running after close, a DComp `Commit` or `Present` per tick with nothing changed, the tooltip or WinEvent hooks left installed. → D19 windows in CI per state, measured by thread (clock thread at 0 when hidden); the fallback rule for early-returning vblanks has a test; `Present` count equals draw count; close → thread exited, hooks off (selftest).
3. **Text "parity" that holds only for the stub or only for Galmuri.** Korean broken between syllables, emoji fallback widths, Pretendard metrics read from the wrong table, a plate cut too early. → Breaks and metrics against Mac goldens for Galmuri; Pretendard and emoji differences reported per case in the PR (with images); `wrappedLines` tests with Korean, Latin, mixed, emoji, ZWJ, RTL on both OSes.
4. **Input and focus.** Walking dead while the IME is in Hangul mode, Hangul turned into "?" in the chat field on an English-locale PC, Enter sending half a syllable, `didResignKey` firing when focus moves to our own `EDIT`, the plaza coming forward by itself, Ctrl+W doing nothing. → `ImmAssociateContextEx` on the scene window (selftest: posted `VK_PROCESSKEY`-free arrows with the IME context check), `WM_IME_CHAR` re-dispatch, the focus scan, `WM_ACTIVATE` own-child test, PC checks on two locales.
5. **Lifecycle.** Window closed but the clock thread, DComp target, textures or tooltip window alive; reopening leaks; the scene released while presented (frozen and swallowing keys, Track A task-10 note); shell calls after `dismantle`. → Selftest open → close → reopen × 3 with thread/handle/private-byte counts; the shared `testTheSceneOutlivesItsPresentation` keeps passing; every shell call after `dismantle` is a no-op (test).

Also check in every review: no Mac-visible difference (render compare identical; the named Mac pin).

---

### Task 1: Parity goldens from the Mac, the shared tree dump, image origin — Size M

The Mac measures, once, everything Windows must match, and commits it as small goldens. Windows tests read them through `#filePath` (the Windows test target excludes non-Swift files; `Tests/PlazaParityGoldens/` sits outside it, so SwiftPM warns about nothing).

**Files:**
- Create: `Team/Plaza/Draw/{PlazaPremultiply,PlazaContinuousCorners,PlazaLineBreaker}.swift`, `Tests/PlazaParityGoldens/*.json` (+ ≤ 10 tiny PNGs), `Tests/PokeTokenBarTests/PlazaParityGoldens+Mac.swift`, `Tests/PokeTokenBarTests/PlazaRender/PlazaTreeDump.swift`, shared tests `PlazaPremultiplyTests`, `PlazaContinuousCornersTests`, `PlazaLineBreakerTests`
- Modify: `Team/Plaza/Draw/PlazaImage.swift` (origin), `Platform/Mac/Plaza/CGPlazaCanvas.swift` (`makeImage` sets `.canvas` / `.canvasWithText`), `Tests/PokeTokenBarTests/mac-only.txt`

**Interfaces:** Produces `PlazaImageOrigin`, `PlazaPremultiply`, `PlazaContinuousCorners`, `PlazaCurveElement`, `PlazaLineBreaker`, `PlazaBreakCluster`, `PlazaTreeDump.lines(root:camera:)`; goldens:
- `spritekit-swatches.json`: an 8 × 8 synthetic texture with known premultiplied pixels drawn by `SKRenderer` under `colorBlendFactor` {0, 0.3, 0.5, 1} × 3 colours × node alpha {1, 0.5}; `.multiply` and `.multiplyX2` over 4 known backgrounds with source alpha {1, 0.5, 0}; an untextured colour sprite with `.multiply` at factor 1; nearest sampling of a 2 × 2 texture at scale 3 and at x offsets 0, 0.25, 0.5, 0.75 device pixels; a sprite rotated 7° (edge pixels). Each case: the scene description + the resulting pixels.
- `premultiply.json`: SHA-256 of `PlazaImage.pixels` for every bundled PNG and the ice GIF frames, plus the straight→premultiplied byte table CoreGraphics produces (256 × 256).
- `fill-gray.json`: device-gray fills 0…1 in steps of 0.05 → bytes.
- `font-metrics.json`: CoreText ascent / descent / leading for Galmuri11 12 pt and Galmuri14 15 pt, and hhea values read from the TTFs (to prove they are the source).
- `breaks.json`: for ~80 texts (Korean sentences and long words, Latin, mixed, emoji, ZWJ, RTL, URLs, punctuation, spaces runs) × widths {40, 80, 120, 200, 340} × both Galmuri sizes: TextKit's `.standard` line ranges (as `CoreTextPlazaEngine.breaks`), and CTFramesetter's line ranges, `suggestedSize` and `visibleLength` for the chat bubble's frame.
- `corners.json`: `Path(roundedRect:cornerRadius:style: .continuous)` and `UnevenRoundedRectangle` elements for rects 4…400 pt wide × radii 0…30 incl. radius > half a side.
- `canvas-script/*.png`: the Track A Task 3 scripted canvas sequence at 64 × 48 (every method), and a name plate, a bubble and an emote at scale 1 and 2.

**Steps:**
- [ ] `PlazaTreeDump`: the harness's SK dump line format, produced from the shared tree. Mac test over every harness capture: shared dump == SK dump (proves the dump is the same fact; Task 15 compares shared dumps across OSes).
- [ ] Write the generator `testWriteParityGoldens` (env `PTB_PLAZA_GOLDENS_WRITE=1`) and the checker `testParityGoldensStillHoldOnThisMac` (always): a `main` merge that changes SpriteKit-visible behaviour, fonts or SwiftUI corners fails here first. Fault-inject: change one swatch value → the checker fails; revert.
- [ ] `PlazaPremultiply` reproduces CoreGraphics' bytes: shared test against the golden table; Mac test over every bundled PNG (straight bytes from the `CGImage` data provider → equals `pixels`).
- [ ] `PlazaContinuousCorners` equals SwiftUI's elements within 1e-9 for the whole matrix (Mac test reads SwiftUI directly; shared test reads the golden).
- [ ] `PlazaLineBreaker` with CoreText clusters (per-cluster advances from a `CTLine`, break opportunities from `CFStringTokenizer` line-break units) equals TextKit's breaks (`.swiftUIText`) and CTFramesetter's (`.coreTextFrame`) for the whole corpus. Where TextKit does something the simple rule does not (e.g. moving a lone last word down, `.pushOut`), the rule implements it and the case is named in the test. Shared tests run the golden clusters on both OSes.
- [ ] `PlazaImage.origin` and the one-line `CGPlazaCanvas.makeImage` change: render compare identical (origin has no pixel effect).
- [ ] Verify: `swift test --filter 'PlazaParity|PlazaPremultiply|PlazaContinuousCorners|PlazaLineBreaker|PlazaRender|ScanTests'`; `shared-check.sh`; `plaza-render-compare.sh` → `RENDER: identical`; Windows CI green with the three shared suites executed.
- [ ] **PR `test(plaza): pin what the Windows renderer must match`**. Body: each golden, how it was measured, the measured SpriteKit colour-blend and multiply formulas in one line each.

**Verify:** as above. **Size:** M. **PC:** no.

---

### Task 2: Windows graphics foundation — target, STA, resources, codecs — Size M

**Files:**
- Modify: `Package.swift` (`onWindows`: `CPlazaD2D` target, C++17, links `d2d1 dwrite d3d11 dxgi dcomp windowscodecs dwmapi ole32 dxguid`; `PokeTokenBar` depends on it and also links `imm32 dwmapi wtsapi32 comctl32`), `Platform/Windows/WindowsApp.swift` (STA first), `Platform/PlatformPlaza.swift` (graphics, clipboard placeholder stays stub until Task 12, symbols nil until Task 10), `Team/Plaza/Draw/PlazaGIFDecoder.swift`, `scripts/windows/package.ps1`, `.github/workflows/windows.yml` (`PTB_PLAZA_RESOURCES`), `windows/licenses/map.txt`, `Resources/Plaza/CREDITS.md`, `Tests/PokeTokenBarTests/UsageEnvironmentTests.swift` allow-list
- Create: `Sources/CPlazaD2D/{include/CPlazaD2D.h, codec.cpp}`, `Platform/Windows/Plaza/{WinPlazaGraphics,WinPlazaCodecs,WinPlazaAssets}.swift` (canvas and text: the stub's until Tasks 8–9), `windows/resources/Plaza/` (Pretendard 1.3.9 Regular/SemiBold/Bold OTF + OFL, SHA-256 in CREDITS), `Tests/PokeTokenBarTests/{WindowsPlazaGraphicsTests,PlazaGIFDelayTests}.swift`

**Interfaces:** Produces `WinPlazaGraphics` (assets, codecs), `PlazaGIFDecoder.framesWithDelays`, the codec part of `CPlazaD2D.h`.

**Steps:**
- [ ] Failing tests. Windows: `testBundledPlazaArtIsFoundOnWindows`; `testDecodedArtMatchesTheMacBytes` (every bundled PNG's `pixels` SHA-256 == `premultiply.json`); `testIceGifFramesMatchTheMac`; `testPNGRoundTripKeepsPixels` (encode → decode within un-premultiply rounding, alpha 0 rows kept); `testResourceDirectoriesOrder` (env first, then exe folder). Shared: `testGifDelaysMatchGIFDecoder` (hand-built fixtures with 0, 0.01, 0.02, 0.1 s delays; Mac adds `PlazaGIFDecoderParityTests+Mac` delays against `UI/GIFDecoder` and the env-gated sprite-cache pass).
- [ ] STA: `WindowsApp` calls `CoInitializeEx(COINIT_APARTMENTTHREADED)` before the tray's first WIC decode; selftest check `com.uiThreadSTA` (`CoGetApartmentType` = STA) and the existing `tray.icon` still passes.
- [ ] Implement; package: `Resources\Plaza\` in the bundle, every file mapped in `windows/licenses/map.txt` (the script already fails on unmapped files).
- [ ] Defect protocol for S10 (the MTA UI thread): root cause, why no test saw it (no check read the apartment), the sweep over every `CoInitializeEx` in `Sources/`, the selftest check as the capture, a `defect-log.md` line under the Windows-Foundation entry.
- [ ] Verify: Mac `swift build`, `shared-check.sh`, `swift test --filter 'PlazaGIF|ScanTests|UsageEnvironmentTests'`; Windows both workflows green; `st.json` has `com.uiThreadSTA` PASS.
- [ ] **PR `feat(windows): decode plaza art and ship its resources on Windows`**.

**Verify:** as above. **Size:** M. **PC:** no.

---

### Task 3: Sprites and icons from the sprite store, in shared code — Size M

Milestone: full Mac gate after this task.

**Files:**
- Create: `Team/Plaza/{PlazaStoreSpriteFetcher,PlazaStoreIconSource,PlazaEggCrop,PlazaIconStore}.swift`, shared tests `PlazaStoreSpriteFetcherTests`, `PlazaEggCropTests`, Mac `PlazaStoreSpriteParityTests+Mac.swift`
- Modify: `Team/UI/PlazaIconLoader.swift` (reads `PlazaIconStore.url`/`fileName`; behaviour identical), `Platform/PlatformPlaza.swift` (Windows: `spriteFetcher()`, `iconSource()`)

**Interfaces:** Produces D12's types.

**Steps:**
- [ ] Failing shared tests over a temporary `SpriteStore(directory:)` filled with fixture files (no network): front frames with delays; back shiny → back plain → front fallback; a 404 back is final, a transient failure is not (the fetch closure is injected); still PNG fallbacks; egg cropped to a centred square; icons from `icon-<id>.png`, a failed icon retried once after 5 s by `PlazaPictureCache` (existing).
- [ ] Mac parity: the same cache files through `LivePlazaSpriteFetcher`/`MacPlazaIcons` and through the shared ports with `MacPlazaGraphics` → equal `pixels` and delays per frame (synthetic GIFs written with `CGImageDestination`; env-gated pass over `PTB_PLAZA_RENDER_SPRITES`).
- [ ] Verify: filtered Mac suites, `shared-check.sh`, render compare identical (the Mac keeps its loaders), milestone `test-gate.sh`; Windows CI green with the new shared suites.
- [ ] **PR `feat(plaza): load plaza sprites and icons from the sprite store in shared code`**.

**Verify:** as above. **Size:** M. **PC:** no.

---

### Task 4: The scene renderer on Direct2D (offscreen first) **[most capable]** — Size L

**Files:**
- Create: `Sources/CPlazaD2D/device.cpp`, `Platform/Windows/Plaza/{WinPlazaGfx,WinPlazaRenderer,WinNodeMirror,WinPlazaStage}.swift`, `Tests/PokeTokenBarTests/WindowsPlazaRendererTests.swift`

**Interfaces:** Consumes Tasks 1–2. Produces D1 (device, offscreen surface), D2, D3, `WinPlazaStage`, `WinPlazaRenderer`, `WinBitmapRef`/texture refs.

**Steps:**
- [ ] Failing Windows tests (offscreen, WARP, no window):
  - `testSwatchesMatchSpriteKit`: every `spritekit-swatches.json` case built as a shared tree on a `WinPlazaStage` and drawn; per channel |Δ| ≤ 1 (≤ 2 for `.multiplyX2`).
  - `testNearestSamplingAndEdges`: the sampling and rotation cases.
  - `testDrawOrderIsFlattensOrder`: overlapping sprites with ties, crop units, camera children.
  - `testCutTexturesDoNotUpload`: upload count stays 1 after 100 cut textures of one image.
  - `testCleanTicksDoNotDraw`: unchanged tree → `.clean`; one alpha write → `.drawn`.
  - `testDeviceLossRebuildsAndRedraws`: inject → same pixels after the rebuild.
  - `testFractionalBackingScale`: 1.25 and 1.5 keep tile seams closed when positions are on the device grid.
- [ ] Implement device, offscreen surface, bitmap table, command building, effects for colour blend and the two multiplies (region copy), clips, clear, readback, fault injection, the mirror.
- [ ] Harness preview (full harness is Task 15): render `base-noon`, `dusk`, `campfire-lit-night`, `pond-swim`, `dance` with the stub text (plates are transparent until Task 9) and upload PNGs as an artifact; put them next to the Mac renders in the PR.
- [ ] Measure on the runner (release): `rush-hour` update + flatten + build ≤ D19's 4 ms (record), WARP raster time.
- [ ] Fault-inject: drop the y-flip for screen-space items → `testDrawOrderIsFlattensOrder` and the dusk preview fail; revert.
- [ ] **PR `feat(windows): draw the shared plaza tree with Direct2D`**.

**Verify:** Windows CI green with `WindowsPlazaRendererTests`; artifact images in the PR. **Size:** L. **PC:** no.

---

### Task 5: The plaza window, its clock and visibility, wired into the app **[most capable]** — Size L

Needs Track B Task 12 merged.

**Files:**
- Create: `Platform/Windows/Plaza/{WinFrameClock,WinPlazaView,WinPlazaWindow,WinPlazaVisibility,WinPlazaPlacement,WinPlazaLive}.swift`, `Platform/Windows/WindowsSelftestPlaza.swift`
- Modify: `Sources/CPlazaD2D/device.cpp` (window surface, vblank), `Platform/PlatformPlaza.swift` (stage, shell), `Platform/Windows/WindowsApp.swift` (`WinPlazaLive.install`; the `PlazaWindowController` built with the Mac's arguments; `teamRuntime.plaza = plaza`; the notifier's `isPlazaFrontmost`/`showInPlaza` as on the Mac; the Mac's observers for character, nickname, team name, my roster entry; `--open-plaza`), `Platform/TrayMenuModel.swift` (`.openPlaza` while the team is ready), the balloon click (team kinds → open the plaza, guarded by `teamSettings.isReady` as the Mac's `openPlaza`), `Tests/PokeTokenBarTests/AppWiringDriftScanTests.swift` (the plaza wiring pairs), `WindowsSeamScanTests` (focus scan, clock-thread scan), `.github/workflows/windows-app.yml`

**Interfaces:** Consumes Tasks 3–4. Produces D1 (window surface), D4, D5, D6, `WinPlazaLive`, the shell.

**Steps:**
- [ ] Failing selftest group `plaza.*` (runner desktop, the controller with in-memory settings, no session, the placeholder sprite):
  - `plaza.window`: created hidden, shown only by `bringToFront`, title, min size at 100 % and at a synthetic 144 dpi.
  - `plaza.frames`: in 3 s, ticks 60 ± 5/s, draws ≤ ticks, presents = draws.
  - `plaza.capture`: `ptb_capture_screen` of a map tile region equals the frame bitmap within ±2. This proves DComp composition on the runner. **First push decides R3.**
  - `plaza.minimize` and `plaza.restore`: clock thread 0 context switches in 5 s, then resumed.
  - `plaza.cover`: an opaque test window above → paused within 1.5 s; moved away → resumed within 1.5 s.
  - `plaza.lock`: synthetic `WM_WTSSESSION_CHANGE`.
  - `plaza.displayOff`: synthetic display state.
  - `plaza.dpi`: synthetic `WM_DPICHANGED` → backing 1.5, buffers resized, panels re-rendered later.
  - `plaza.deviceLoss`: injected → redrawn.
  - `plaza.close`: thread exited, hooks off, handles within +10, three open/close cycles.
  - `plaza.dragDraws`: posted size-move messages around 1 s of ticks.
  - `plaza.focus`: no activation without `bringToFront`.
- [ ] Windows scans: activation calls only in `bringToFront`; no `assumeIsolated`/`DispatchQueue.main` in `WinFrameClock.swift`.
- [ ] Shared tests (both OSes): `TrayMenuModel` shows "광장 열기" only while ready.
- [ ] Mac: `AppWiringDriftScanTests` pairs updated; the Mac's wiring untouched.
- [ ] Implement in this order: the window (made through `WinSinkWindow`) → surface → stage hookup → clock → visibility → placement → app wiring.
- [ ] Record in the PR: the clock source on the runner (expected: the timer fallback), tick-interval percentiles, and the cover check cost.
- [ ] Fault-inject twice, reverting each: leave `WM_PAINT` unvalidated → `plaza.frames` / idle numbers fail; skip the clock park → `plaza.minimize` fails.
- [ ] **PR `feat(windows): open the plaza in a Direct2D window`**. Images: the runner's screen capture of the window (labelled; no plates yet).

**Verify:** `windows-app` green with every `plaza.*` PASS; Windows tests green; Mac drift/scan suites green. **Size:** L. **PC:** no (Task 7).

---

### Task 6: Keyboard and mouse — Size M

**Files:**
- Create: `Platform/Windows/Plaza/WinPlazaInput.swift`, `Tests/PokeTokenBarTests/WindowsPlazaInputTests.swift`
- Modify: `WinPlazaWindow.swift` (key, mouse, wheel messages; IME off on the window), `Platform/PlatformPlaza.swift` (`currentModifiers`), `WindowsSelftestPlaza.swift`

**Interfaces:** Produces D7.

**Steps:**
- [ ] Failing Windows tests:
  - `testEveryPlazaKeyCodeHasAScanCode` (table round trip for every `PlazaKeyCode` + "-", "=", "+").
  - `testRepeatBit`.
  - `testCtrlIsCommandAndControl`.
  - `testWheelNotchIsThreeLinesOfTenPoints`; `testHorizontalWheelSign`.
  - `testCharactersDoNotEatDeadKeys` (`ToUnicodeEx` flag 0x4 leaves the state).
- [ ] Failing selftest checks (CI only, `SendInput`):
  - `plaza.walk`: arrows and WASD move the walker; Shift runs.
  - `plaza.ctrlW`: closes.
  - `plaza.imeOff`: the scene window has no IME context, so a Korean-IME-on-key stays a VK.
  - `plaza.resignReleasesKeys`: activating another window mid-hold stops walking.
  - `plaza.click`: a click on the toggle panel's rect reaches `hud.onAction`; a click elsewhere reaches nothing.
- [ ] Mouse routing per D8 (z list, owner HUD, capture, leave tracking only for `tracksMouse`); the cursor is an arrow.
- [ ] **PR `feat(windows): plaza keys, mouse and wheel`**.

**Verify:** Windows green; selftest `plaza.walk`… PASS. **Size:** M. **PC:** no.

---

### Task 7: Milestone 1 on the user's PC — the map, my Pokémon, teammates, walking — Size S

**Files:** spec §9.1 (stage 6 M1 row), `docs/reference/defect-log.md`.

**Steps:**
- [ ] The lead sends the installer artifact link and this checklist (Korean wording is the lead's). Name plates, bubbles and panels are **not** there yet (said up front).
  1. `winver`, display scale(s) (100/125/150 %), refresh rate, GPU (Task Manager → Performance).
  2. Tray → 광장 열기: the window appears in front only then. A Mac teammate, a timer or a notification never brings it forward.
  3. The map looks like the Mac's (side by side with a Mac screenshot of the same spot).
  4. My Pokémon animates. Teammates appear and walk smoothly while a Mac teammate walks.
  5. Arrows, WASD and Shift walk and run, with the Korean IME in Hangul mode too. The Mac sees me move.
  6. Resize, maximize, drag to another monitor (and between scales): the drawing keeps going while dragging. Crisp at 100 %; at 125 % and 150 %, does panning shimmer (R11)?
  7. Minimize, cover with another window, lock (Win+L), display off: the log shows `rendering visible=false` lines and back.
  8. Close and reopen three times.
  9. Win+Ctrl+Shift+B (driver reset) with the plaza open: it redraws within a second.
  10. `PokeTokenBar.exe --selftest` → send `st.json` (incl. `plaza.gpuParity` hardware against WARP).
  11. `measure-idle.ps1` 10 min each: plaza never opened / open and minimized / open, visible, nobody moving. Task Manager GPU column for the plaza.
- [ ] Record the answers; each failure goes through the defect protocol in its own fix PR before Task 13.
- [ ] **PR `docs: record the first Windows plaza check`**.

**Size:** S. **PC:** **yes**.

---

### Task 8: The canvas on Direct2D and WIC — Size L

**Files:**
- Create: `Sources/CPlazaD2D/canvas.cpp`, `Platform/Windows/Plaza/WinPlazaCanvas.swift`, `Tests/PokeTokenBarTests/WindowsPlazaCanvasTests.swift`
- Modify: `WinPlazaGraphics.makeCanvas`

**Interfaces:** Consumes Task 1 (corners, gray, canvas-script goldens). Produces D9 and the canvas table.

**Steps:**
- [ ] Failing Windows tests:
  - `testPixelFormatAndWithPixelsAreRowTopRGBA` (decides PRGBA vs PBGRA).
  - `testCanvasScriptLooksLikeTheMac`: the Task 1 script against `canvas-script/script.png`. Shapes: |Δ| ≤ 2 except antialiased edges (≤ 1 % of pixels over 2). Fills inside shapes exact.
  - One test per operation in the table: state stack and clips across save/restore; CTM order; alpha per call; each blend on known backgrounds against CG's formulas; device gray 158; strokes centred; joins and caps; shadow offset, blur and colour against the golden plate shadow; aliased vs antialiased; interpolation none; continuous and uneven corners match `PlazaContinuousCorners`; even-odd vs winding.
  - `testCanvasesWorkOffTheMainThread` (8 threads × 50 canvases).
  - `testMakeImageOrigin`.
- [ ] Implement.
- [ ] Turn on real Windows art builders that need no text: placeholder, light texture, firework glyphs, emote fills. Shared art tests now run with the real canvas on Windows: triage any failure (bug / test assumption / Mac-only reason).
- [ ] **PR `feat(windows): the plaza canvas on Direct2D`**. Images: the script, a bubble frame and an emote, Windows next to Mac.

**Verify:** Windows green; the shared art suites pass with the real canvas. **Size:** L. **PC:** no.

---

### Task 9: The DirectWrite text engine **[most capable]** — Size L

**Files:**
- Create: `Sources/CPlazaD2D/text.cpp`, `Platform/Windows/Plaza/WinPlazaTextEngine.swift`, `Tests/PokeTokenBarTests/WindowsPlazaTextTests.swift`
- Modify: `WinPlazaCanvas.swift` (line and paragraph draws, stroke mode, image bounds), `WinPlazaGraphics.text`

**Interfaces:** Consumes Tasks 1, 8. Produces D10.

**Steps:**
- [ ] Failing Windows tests:
  - `testGalmuriMetricsAreCoreTexts` (golden, exact).
  - `testWrappedLinesAreTheMacsForTheCorpus` (`.swiftUIText`, exact ranges).
  - `testBubbleParagraphIsTheMacs` (`.coreTextFrame`: line ranges, `suggestedSize`, `visibleLength` exact for the Galmuri corpus).
  - `testTruncationAddsAnEllipsisAndFits`.
  - `testRunsKeepTheirColours`.
  - `testEmojiFallBackToSegoeAndDrawInColour` (a colour pixel inside the glyph box).
  - `testPretendardWeightsLoad` (three distinct widths).
  - `testRTLBaseDirection`.
  - `testStrokeModeSkipsColourGlyphs`.
  - `testImageBoundsAreInk`.
  - `testPrivateFontsAreNotInstalled` (the system collection does not list Galmuri).
- [ ] Implement.
- [ ] The shared text-art and panel suites run with the real engine on Windows: triage (Mac-font assertions stay `+Mac`; everything else passes on both).
- [ ] Report per corpus case where Pretendard differs from the Mac system font (plate width/height deltas) and where emoji widths change a break, with images.
- [ ] Fault-inject: read DirectWrite's default metrics instead of hhea → `testGalmuriMetricsAreCoreTexts` fails; revert.
- [ ] **PR `feat(windows): plaza text with DirectWrite`**. Images: plates (Latin, Hangul, emoji, title, truncation), bubbles (wrap, 60 chars), the chat log rows, Windows next to Mac.

**Verify:** Windows green; differences listed. **Size:** L. **PC:** no.

---

### Task 10: HUD panels in the window, content panels, tooltips, eye glyphs — Size M

**Files:**
- Create: `Platform/Windows/Plaza/{WinPlazaPanels,WinPlazaTooltips,WinPlazaSymbols}.swift`, `Tests/PokeTokenBarTests/WindowsPlazaPanelsTests.swift`
- Modify: `WinPlazaWindow.swift` (host, z list, shell content HUD, `setHUDHidden`, `setChatLogAboveInput`), `WinPlazaRenderer.swift` (panel layers), `Platform/PlatformPlaza.swift` (`symbolImage`)

**Interfaces:** Consumes Tasks 5, 6, 8, 9. Produces D8, D15, D18.

**Steps:**
- [ ] Failing Windows tests:
  - `testZListIsTheMacsSubviewOrder`.
  - `testTheShellBuildsTheContentPanelsFromTheBindings` (roster, board only with a feed, card, chat log).
  - `testContentActionsCallTheBindings` (select, previous/next, react, toggle; inert hits ignored).
  - `testHUDHiddenHidesTheMacsSet`.
  - `testClicksGoToTheTopMostPanelWithAHit`.
  - `testTooltipsFollowDrawings` (count, rects, rebuilt only on change).
  - `testEyeGlyphs` (Fluent, MDL2 fallback, nil for others).
  - `testPanelsRenderNothingWhileHidden` (`hud.renderCount` unchanged while `setRendering(false)`).
- [ ] Selftest checks:
  - `plaza.panels`: every panel shows in a scripted state (banner, guide unfolded, menu, roster with 3 members, board, card, chat log with lines); a capture is in the artifact.
  - `plaza.wheel`: scrolling the board moves it; a wheel at its end goes on.
  - `plaza.hover`: tooltip text after a rest, through `TTM_GETTEXT`.
- [ ] **PR `feat(windows): show every plaza panel in the Windows window`**. Images: each panel, Windows CI against the Mac harness/panel renders.

**Verify:** Windows green; selftest panel checks PASS. **Size:** M. **PC:** no.

---

### Task 11: The chat line with the Korean IME **[most capable]** — Size L

Milestone: full Mac gate after this task.

**Files:**
- Create: `Team/Plaza/HUD/PlazaChatBarPanel.swift`, `Team/Plaza/PlazaChatEmojis.swift`, `Platform/Windows/Plaza/WinPlazaChatInput.swift`, shared `PlazaChatBarPanelTests`
- Modify: `Team/Plaza/HUD/PlazaPanel.swift` (`.chatBar`), `Team/UI/PlazaChatInput.swift` (reads `PlazaChatEmojis`; identical), `Platform/Windows/WinMessageHook.swift` (`WM_IME_CHAR`), `Platform/PlatformPlaza.swift` (`makeChatInput`), `WinPlazaWindow.swift`, `WindowsSelftestPlaza.swift`

**Interfaces:** Consumes Tasks 6, 10. Produces D13, `PlazaChatBarPanel`, `PlazaChatEmojis`.

**Steps:**
- [ ] **First push, the composition check:** a plain `EDIT` child over the composition; selftest `plaza.chatChildVisible` captures the screen over the field after typing "Aa한" through posted chars. If it fails, the layered container goes in; if that fails too, the owned popup. The PR states which one shipped and why.
- [ ] Failing shared tests: bar size and place (closed, open, emoji open; the Mac's constants), loud border, hits, field rect, emoji grid order = `PlazaChatEmojis.all`.
- [ ] Failing selftest checks (CI only):
  - `plaza.chatOpenClose`: T/Enter opens, Esc closes, focus returns to the scene.
  - `plaza.chatSubmit`: posted "hello 안녕" + Enter → `onSubmit` text exact; a repeated Enter does nothing.
  - `plaza.chatTab`: loud toggles.
  - `plaza.chatEmojiGrid`: a click inserts at the caret, focus stays.
  - `plaza.chatFocusOwnChild`: no `didResignKey` when the field takes focus.
  - `plaza.chatCloseOnFocusMove`.
  - `plaza.imeChar`: a posted `WM_IME_CHAR` U+D55C arrives whole at ACP 1252.
- [ ] Shared `PlazaChatTests` run with `WinPlazaChatInput` semantics where they used the stub.
- [ ] Defect check: `WinMessageHook` gains `WM_IME_CHAR` with a test that failed before (posted `WM_IME_CHAR` at ACP 1252 → "?").
- [ ] **PR `feat(windows): the plaza chat line with the native edit control`**. Images: the bar closed / open / loud / emoji grid, Windows capture.

**Verify:** Windows green; Mac render compare identical (the Mac chat input unchanged), milestone `test-gate.sh`. **Size:** L. **PC:** no (Task 13).

---

### Task 12: Photos, PNG and the clipboard — Size S

**Files:**
- Create: `Platform/Windows/Plaza/WinImageClipboard.swift`, `Tests/PokeTokenBarTests/WindowsPlazaClipboardTests.swift`
- Modify: `Platform/PlatformPlaza.swift` (`clipboard`)

**Interfaces:** Produces D14.

**Steps:**
- [ ] Failing Windows tests:
  - `testPhotoGoesOnTheClipboardAsPNGAndDIBV5` (read back both formats; DIB alpha and orientation).
  - `testABusyClipboardFailsHonestly` (another window holds it → false + one log line).
  - `testPhotoBytesLookLikeTheMacs`: the 9 harness photo inputs rendered on Windows against the Mac's photo PNGs. Within ±2 outside plate rects; plates report-only.
- [ ] Selftest `plaza.photo`: P → shutter → the clipboard holds a PNG of the photo frame's size.
- [ ] **PR `feat(windows): put plaza photos on the Windows clipboard`**.

**Verify:** Windows green. **Size:** S. **PC:** no.

---

### Task 13: Milestone 2 on the user's PC — text, panels, chat, photos — Size S

**Files:** spec §9.1 (M2 row), `defect-log.md`.

**Steps:**
- [ ] Checklist (Korean wording is the lead's):
  1. Name plates, titles and the campfire timer in Pretendard, Hangul and emoji. Bubbles in Galmuri with colour emoji; a 60-character Korean chat wraps at word boundaries in panels and like the Mac in bubbles.
  2. HUD: banner, countdown, hint, clock, minimap, shortcut guide fold, the eye toggle (hides the map: the window becomes see-through), the name-colour picker, member and campfire menus. The pressed look on buttons.
  3. Roster: click a teammate (walks there), page arrows, hover tooltip. Board: wheel and touchpad scroll, reactions (my own inert). Card: dex scroll, cell tooltips.
  4. Chat with the Korean IME on a Korean-locale PC, and if possible an English-locale one:
     - composition shows inside the field;
     - Enter during composition only completes it;
     - "안녕하세요" + Enter sends the whole word (watch the last syllable);
     - Tab gives the loud border; Esc closes; Win+. inserts an emoji; the 😀 grid inserts too;
     - the Mac sees the bubble.
  5. P → photo → paste into Paint, a browser and the team messenger.
  6. Idle again: open, visible, nobody moving, 10 min `measure-idle.ps1` + Task Manager GPU column.
- [ ] Record; failures through the defect protocol.
- [ ] **PR `docs: record the second Windows plaza check`**.

**Size:** S. **PC:** **yes**.

---

### Task 14: Bring the parked Mac-only plaza tests to Windows — Size M

Milestone: full Mac gate after this task.

**Files:** `Tests/PokeTokenBarTests/mac-only.txt`, `.github/workflows/windows.yml` (floor), and the parked files: `PlazaStartleControllerTests`, `PlazaGroupPhotoTests+Mac`, `PlazaPhotoModeTests+Mac`, `PlazaPullUnderTests+Mac`, `PlazaSeasonTests+Mac`, `PlazaSnowSceneTests+Mac`, `PlazaTallGrassSceneTests+Mac`, `PlazaTallGrassLayerTests+Mac`, `PlazaIceLayerTests+Mac`, `PlazaIceArtTests+Mac`, `PlazaSnowSheetTests+Mac`, `PlazaTallGrassArtTests+Mac`, `PlazaTileArtTests+Mac`, `PlazaPondLayerTests+Mac`, `PlazaCampfireSceneTests+Mac`, `PlazaPhotoTests`, `PlazaPhotoTestSupport`, `PlazaResourcesTests`, and the pixel-read parts of `PlazaDance/Daylight/Emote/Items/Pray/Snowball/SwimLowerHalf/WeatherTests+Mac`.

**Steps:**
- [ ] For each file, one of three outcomes, recorded in a PR table (file → tests now executed on Windows, assertions kept Mac-only with the reason):
  - The bundled art or codec is now there: the test moves as is.
  - The assertion read a `CGImage`: rewrite it on `PlazaImage.pixels`, same expected values. Mac-font or AppKit assertions stay in `+Mac`.
  - The assertion depends on a font: it stays in `+Mac` with that reason.
- [ ] `PlazaPhotoTestSupport.renderCG` becomes a shared `render(_:) -> PlazaBitmap` over `PlazaPhotoRenderer.render`.
- [ ] Triage each Windows failure: shared bug (defect protocol) / test assumption / Mac-only.
- [ ] Raise the `windows.yml` floor to the new executed count minus 2 %.
- [ ] **PR `test(plaza): run the art, photo and codec tests on Windows`**.

**Verify:** Mac milestone gate green; Windows green with the new count. **Size:** M. **PC:** no.

---

### Task 15: The render harness on Windows and the cross-OS compare — Size M

**Files:**
- Modify: `Tests/PokeTokenBarTests/PlazaRenderScenes.swift` (shared: fixtures through `PlazaImage(bitmap:)`, no AppKit), `mac-only.txt`, `.github/workflows/windows.yml` (a `render` job: `PTB_PLAZA_RENDER_OUT`, WARP, artifact `plaza-render-win` (7 days))
- Create: `Tests/PokeTokenBarTests/WindowsPlazaRenderHarnessTests.swift`, `Tests/PokeTokenBarTests/PlazaRender/PlazaCrossRenderCompareTests+Mac.swift`, `scripts/plaza-render-cross.sh`

**Interfaces:** `scripts/plaza-render-cross.sh --run <windows run id> [--scratch <dir>]`. It downloads the artifact, renders the Mac set at the run's commit in the reused base worktree, runs the comparer, and prints `CROSS: ok (<n> captures, <m> allowed differences)` or `CROSS: <k> fail: <scene@frame> <reason>…`.

**Steps:**
- [ ] Move the scenes to shared code. The Mac compare must stay `RENDER: identical` (the fixtures are the same bytes; the compare proves it).
- [ ] Windows harness: every scene except `real-sprites` (no cache on the runner; no Pokémon assets committed) at backing 1 and 2 (+ `base-noon` at 1.25 and 1.5). Outputs: PNG, the shared dump (`PlazaTreeDump`), the manifest, the photos. A/A: two runs of the harness give identical manifests.
- [ ] Comparer rules:
  - Tree: every field of every node is equal. The only allowed differences trace to text and are printed with their reason:
    - (a) `.canvasWithText` textures: size and hash;
    - (b) positions of the same actor's nodes that the actor places from its plate or emote size (plate, emote, wet mark, bubble), bounded by that actor's text-size delta + 1 pt;
    - (c) `.canvas` textures without text: hash only, never size.
  - Pixels: per channel |Δ| ≤ 3 and ≤ 0.1 % of pixels above 3, outside the on-screen rects of (a)–(c) dilated by 2 px. Inside them: report-only (counts + diff image). Photos: the same rule with plate rects.
  - Any other difference fails.
- [ ] Fault-inject twice on the Windows side, reverting each: a 1-pixel camera offset → the comparer names every capture; colour blend 0.3 → 0.4 → `pond-swim` fails.
- [ ] Record the WARP harness time on the runner.
- [ ] **PR `test(windows): compare the Windows plaza renders with the Mac's`**. Body: the allowed-difference summary per scene.

**Verify:** `CROSS: ok`; Mac compare identical; Windows render job green. **Size:** M. **PC:** no.

---

### Task 16: The idle and cost gate for the plaza — Size M

**Files:** `.github/workflows/windows-app.yml`, `scripts/windows/measure-idle.ps1` (per-thread labels for the frame clock), `Platform/Windows/WindowsSelftestPlaza.swift` (`--selftest-plaza-park <state>` helper modes), `CONTRIBUTING.md` (Windows plaza: renderer, harness, cross compare, budgets).

**Steps:**
- [ ] Workflow windows on the installed app, fixture data, `refreshInterval = 0` (Track B D8 shape), each measured after 30 s for 120 s:
  - closed;
  - opened then closed;
  - open and minimized;
  - open and covered;
  - open, visible, idle;
  - `rush-hour` (a helper drives 12 synthetic teammates through a loopback session).
- [ ] Assert D19's CI budgets: clock thread 0 when hidden; presents = draws; handles and private bytes after close.
- [ ] Record the first numbers in the PR. The budgets are tightened only after Tasks 7, 13 and 17 report PC numbers.
- [ ] `plaza.gpuParity` in the selftest: hardware against WARP on one scene, informational on the runner (WARP only).
- [ ] Fault-inject: the cover check left running after close → the "opened then closed" window fails; revert.
- [ ] **PR `ci(windows): gate the plaza's idle cost`**.

**Verify:** `windows-app` green within budget. **Size:** M. **PC:** no.

---

### Task 17: Final stage 6 check on the user's PC; docs — Size S

**Files:** spec §5 (as built: fonts, emoji, eye glyphs), §6 (content panels on Windows from the shell; the chat line), §9.1, §10 step 6 (done + deviations), §13; `docs/reference/defect-log.md`; `CONTRIBUTING.md`.

**Steps:**
- [ ] Checklist (Korean wording is the lead's):
  1. 10 min idle with three or more teammates, then 10 min of everyone moving, emoting, snowballs, fireworks at night. CPU, GPU and memory compared with the Mac app over the same 10 min (spec §2: the three states side by side).
  2. Sleep and wake with the plaza open; Wi-Fi off and on.
  3. Driver reset again; RDP into the PC once if available (timer fallback).
  4. A monitor unplugged while the plaza is on it (the placement comes back on a visible monitor).
  5. A group photo started from the Mac (countdown on Windows); Ditto; tall grass startle; pond swim and dive; seasons as the date gives them.
  6. The Narrator item as decided (open question 2).
  7. Windows 10, if a PC exists (open question 4).
- [ ] Record; failures through the defect protocol.
- [ ] **PR `docs: record the Windows plaza`**. Report to the user in Korean: what works, the listed differences from the Mac, the measured idle numbers, what stage 7 inherits (popover, floating pet; Narrator if deferred).

**Size:** S. **PC:** **yes**.

---

## Order

- **Prerequisites:** Track B Task 12 merged (before Task 5); Track A Task 19 merged or coordinated (Task 1 does not depend on `Legacy/`).
- **Start in parallel:** Task 1 (Mac build slot) and Task 2 (Windows CI only).
- **Then:**
  - Task 3 (Mac slot; its Windows half needs Task 2) alongside Task 4 (Windows CI; needs Task 1's swatches and Task 2).
  - Task 8 needs Tasks 1 and 2 and can be authored alongside Task 4; Task 9 follows Task 8.
- **First visible:** 5 (needs 3, 4) → 6 → **7 (PC, milestone 1)**.
- **Second visible:** 10 (needs 5, 6, 8, 9) → 11 → 12 (needs 8, 2, 5; can go before 11) → **13 (PC, milestone 2)**.
- **Closing:** 14 (needs 2, 8, 9, 12), 15 (needs 1, 4, 8, 9), 16 (needs 5–12 and Track B Task 12), then **17 (PC, final)**.
- **Critical path:** 2 → 4 → 5 → 6 → 7; then 8 → 9 → 10 → 11 → 13 → 16 → 17.
- **Full Mac gate** after Tasks 3, 11 and 14, and before `windows-port` → `main`.
- Only one Mac build at a time, so "parallel" means one Mac-slot task (1, 3, 11's shared half, 14, 15's Mac half) next to one or two CI-only tasks.
- **Collisions:**
  - `PlatformPlaza.swift` selection lines (Tasks 2, 3, 5, 10, 11, 12): merge in task order, line-local.
  - `WinPlazaWindow.swift` (Tasks 5, 6, 10, 11): one task at a time.
  - `windows.yml` and `windows-app.yml`: additive steps.
  - `mac-only.txt` and `shared-floor.txt`: as before (recount on conflict).
  - Track B's files touched here (`WindowsApp.swift`, `WinMessageHook.swift`, `TrayMenuModel.swift`, the drift scan): tell the Track B session when each merges.
- **Estimate:** 17 tasks (4 L, 8 M, 5 S incl. 3 PC sessions); about 45–55 Windows CI round trips at 13–16 minutes each, plus the Mac-slot work. No calendar promise.

## Risks and unknowns (each with the cheapest early check)

- **R1. A child `EDIT` is not composed over a `WS_EX_NOREDIRECTIONBITMAP` window.** Check: Task 11's first push (screen read over the field); fallbacks in D13. If all three fail, the cost is a chat field in its own popup with focus tricks.
- **R2. `WaitForVBlank` returns early or blocks oddly** (display off, RDP, hybrid GPUs, mixed refresh rates). Check: Task 5 records the source and interval percentiles on the runner; the five-early-returns rule; PC items in Tasks 7 and 17.
- **R3. GDI screen capture does not see DirectComposition content on Server 2025.** Check: Task 5's first push (`plaza.capture`). Fallback evidence: read the presented back buffer (proves rendering, not composition); PC eyes.
- **R4. DirectWrite private fonts from files via the shim.** Low (the spike did it). Check: Task 9's first test (`testPrivateFontsAreNotInstalled`, metrics golden).
- **R5. Metrics or breaks differ from CoreText even for the same Galmuri file** (hhea vs OS/2, kerning, shaping features). Check: Task 1 records hhea next to CoreText's numbers; Task 9's first push compares.
- **R6. WARP and the user's GPU differ** (effect precision, nearest sampling). Check: `plaza.gpuParity` in the first PC run (Task 7); the swatches are the measure.
- **R7. The UI thread's COM apartment** (TSF, the IME and the emoji panel expect STA; today it may be MTA). Check: Task 2's `com.uiThreadSTA`; Task 13 IME items.
- **R8. Hangul through CF's ANSI pump in the chat field** (`WM_IME_CHAR`, ordering of the committed syllable and Enter). Check: Task 11's posted `WM_IME_CHAR` test at ACP 1252; Task 13 on two locales.
- **R9. Cover detection is wrong** (a layered or transparent window counted as covering, a window on another monitor) or costs more than measured. Check: `plaza.cover` and the cost line in Task 5; Task 7 item 7.
- **R10. Resources not found in tests or in the bundle** (SwiftPM resources are not used). Check: `testBundledPlazaArtIsFoundOnWindows` (CI), `packaged.*` checks.
- **R11. Fractional scales (125/150 %) shimmer while panning** with nearest sampling at true device pixels. Check: Task 15 renders `base-noon` at 1.25/1.5; Task 7 item 6. The fix, if the user dislikes it, is open question 1's alternative.
- **R12. Windows 10 vs 11** (Fluent icons, emoji fonts, DComp details). The minimum assumed is 10 22H2 (D20); CI is Server 2025. Check: a Windows 10 PC (open question 4).
- **R13. The visible idle cost on an integrated-GPU laptop.** Check: Task 7's first numbers; the dirty-frame rule (D3) is the main lever, the 60 cap the second.
- **R14. Device loss in practice** (driver update, sleep with a dGPU off, RDP). Check: injected in CI (Task 4/5), Win+Ctrl+Shift+B on the PC (Task 7).
- **R15. Memory** (four season maps × 3.5 MB, sprites per teammate, panel images). Check: Task 16's memory windows.
- **R16. Track B's packaging is not merged.** Check: before Task 5 (`git merge-base --is-ancestor 761a159 origin/windows-port`).
- **R17. Shared tests that silently relied on the Windows stub** (plain grass, transparent text) start failing once real graphics are on. Expected and wanted. Check: Tasks 8, 9 and 14 triage, each failure classified.
- **R18. WARP makes the full harness slow** on the runner. Check: Task 4's preview timing; if over ~10 min, the render job runs on `workflow_dispatch` and on milestone merges only.

## Open questions for the session lead

1. **Fractional display scale (125 %, 150 %).** Recommended: draw at the true device pixels with nearest sampling. It is crisp and cheapest, and the scene already snaps to that grid. Some world pixels are one device pixel wider than others, which can shimmer while panning. The alternative: draw at the next whole scale and filter down, as macOS does in its scaled modes. That looks softer and costs more GPU. Task 7 shows the user both renders if they want to choose.
2. **Narrator (UI Automation) for the drawn panels.** Recommended: defer to stage 7 or 8, logged as unavailable. The chat field is native and readable now. Adding it in stage 6 is one more L task (a UIA fragment provider over the existing accessibility items).
3. **Idle budgets on the PC** (D19: visible idle ≤ 3 % CPU of the machine and ≤ 5 % GPU; hidden ≈ closed + 2 wakeups/s). Recommended: accept as the starting line and tighten after the first PC numbers, as Track B did.
4. **Windows 10.** Only a Windows 11 PC is known. Recommended: keep "Windows 10 22H2 and 11" as the target, but mark Windows 10 untested until someone runs Task 17 on one. Or narrow G1 to Windows 11 now.
5. **Emoji in the chat field show monochrome while typing** (the native `EDIT`); the sent bubble is in colour. Recommended: accept. A RichEdit field would show colour but costs a task and more IME risk.
6. **The see-through mode on Windows** keeps the window frame and shadow, and clicks on transparent parts still go to the plaza. Recommended: accept (removing the frame changes how the window is moved and closed).
7. **Pretendard committed to the repo** (about 5 MB, OFL, pinned 1.3.9 with its hash). Recommended: commit it rather than download it at build time (reproducible, no network in the build).
8. **Ctrl acts as ⌘ on Windows** (Ctrl+W closes, a Ctrl chord blocks emotes and walking), Alt as ⌥, the Windows key as nothing (Track A open question 6). Recommended: accept.
9. **The Mac's own content-panel decision** (keep SwiftUI or switch) does not block stage 6: Windows builds those panels in its shell. Recommended: no action now; when the Mac switches, both shells hand the panels to the controller in one shared change.

## 요약 (사용자용)

- 6단계는 윈도우에서 광장 창을 여는 일입니다. 맥과 같은 공용 장면·패널·컨트롤러를 그대로 쓰고, 그리는 부분만 윈도우의 Direct2D·DirectWrite로 새로 만듭니다. 맥 화면은 바뀌지 않습니다(PR마다 맥 렌더 비교로 확인).
- PC에서 보시는 순서는 세 번입니다.
  - (1) 트레이 → '광장 열기'로 창이 뜨고, 지도와 내 포켓몬, 팀원이 보이고 걸을 수 있습니다. 이 단계에는 이름표·말풍선·패널이 아직 없습니다.
  - (2) 이름표·말풍선·모든 패널(명단·대화 기록·소식판·카드 포함), 채팅 입력과 한글 입력기, 사진 클립보드가 들어갑니다.
  - (3) 여러 명과 오래 켜 두고 CPU·GPU·메모리를 맥과 나란히 재는 마지막 확인입니다.
- 한 번 확인에 10~30분 정도 걸리는 체크리스트를 미리 드립니다.
- 숨겨진 창(최소화·가려짐·잠금·화면 꺼짐)은 그리지 않습니다. 보이는 동안에도 바뀐 것이 있을 때만 다시 그려 노트북 부담을 줄입니다. 닫힌 광장의 비용은 지금과 같습니다.
- 맥과 다른 점(미리 알려 드림):
  - 이름표 글꼴은 Pretendard, 이모지는 Segoe입니다.
  - 채팅 입력칸 안의 이모지는 흑백입니다(보낸 말풍선은 컬러).
  - 배경 숨기기 모드에서도 창 테두리가 남습니다.
- 큰 위험은 다섯 가지입니다.
  - 채팅 입력칸이 그림 위에 제대로 보이는지: 첫 CI에서 확인하고, 안 되면 대안이 정해져 있습니다.
  - 한글 입력기와 엔터 처리.
  - 125%·150% 배율에서 픽셀이 조금 울렁이는지.
  - 가려진 창을 정확히 알아채는지.
  - 아직 머지되지 않은 Track B 설치 파일 작업에 기대는 점.
- 분량은 작업 17개(큰 것 4, 중간 8, 작은 것 5, 그중 PC 확인 3)입니다. 윈도우 CI 왕복은 대략 45~55회(회당 13~16분)로 봅니다. 날짜는 약속하지 않습니다.
- 결정을 부탁드릴 것은 위 "Open questions"의 1~4번입니다: 소수 배율의 모양, 내레이터 지원 시기, PC 유휴 기준, 윈도우 10 지원 여부. 나머지는 추천대로 진행해도 됩니다.
