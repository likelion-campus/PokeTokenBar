# Windows Port, Stage 0 (Experiments) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Answer the four questions in §9 of the spec with throwaway code, and write the answers back into the spec so stages 1–8 can be planned.

**Architecture:** All experiment code lives on one branch, `spike/windows-port`, which is never merged. A workflow on that branch builds and runs things on a GitHub Actions Windows runner and uploads results as artifacts. Experiment 2 also produces a zip the user runs on a real Windows PC. Only the spec update (Task 5) goes to `main`, through the existing `docs/windows-port-design` branch.

**Tech Stack:** Swift 6 (macOS 15 / Xcode 16 locally; `windows-latest` with the swift.org toolchain on CI), SwiftPM, Win32 `windns.h` DNS-SD, Schannel, Direct2D / DirectWrite / WIC, SpriteKit (Mac side of experiment 4), XCTest.

**Spec:** `docs/superpowers/specs/2026-11-13-windows-port-design.md` (Korean). Section numbers (§9 etc.) point into it.

## Global Constraints

- Experiment code is throwaway: no tests beyond what the experiment itself measures, no review loop, no PR to `main`. Never merge `spike/windows-port`.
- Work in `.worktrees/windows-port-spike`, created from `origin/main`. Never edit the main checkout.
- Always pass `--repo likelion-campus/PokeTokenBar` to `gh`. Never touch `chattymin/PokeTokenBar`.
- Commits in English. No bare `git stash`.
- Target: Windows 10 22H2 and Windows 11, x64 only.
- The wire must not change: service `_ptbteam._tcp`, TLS 1.2, `TLS_PSK_WITH_AES_128_GCM_SHA256`, PSK identity `ptb-team-v1`, key = `TeamCode.pskKey` (HKDF, info `poketokenbar.team.psk.v1`), frames = 4-byte big-endian length + JSON. The Mac reference is `scripts/team-probe.swift` and `BonjourTeamTransport.parameters(code:)`.
- A Windows teammate must not need admin rights, a Group Policy change, or a separate install (e.g. Apple's Bonjour). An experiment that only works with one of those counts as "no".
- The Mac plaza must not change. Experiment 4 passes only on a pixel-identical render.
- Nothing here runs a release, bumps a version, or changes `Package.swift` on `main`.
- Each experiment ends with a short result note in `spike/RESULTS.md` on the spike branch: the question, yes/no, the evidence (CI run URL, artifact name, numbers), and what it changes in the spec.

## Review Focus

These are the ways an experiment can say "yes" and still be wrong. Each is pinned to a step below.

1. **CI runners are administrators.** Schannel PSK or the firewall may work on the runner and fail for a normal user. → Task 2 step 6 requires the real-PC run under a standard (non-admin) account.
2. **Loopback is not the LAN.** mDNS on one machine proves the API, not Mac↔Windows discovery. → Task 2 step 6 requires both directions against a Mac on the office Wi-Fi.
3. **"It compiles" with files excluded.** Experiment 1 could pass by dropping every hard file. → Task 1 step 4 records the excluded files and each blocking API, and counts lines kept vs. dropped.
4. **A GPU-less runner draws differently.** The WARP software renderer may differ from a real GPU. → Task 3 step 5 has the user's PC render the same scene for comparison (folded into the Task 2 zip).
5. **Pixel-identical on one scene only.** Experiment 4 could match at noon and differ at night or on a snow day. → Task 4 step 3 renders three named conditions.

---

### Task 1: Does the shared logic compile and test on Windows?

**Files (spike branch only):**
- Create: `.github/workflows/spike-windows.yml`
- Create: `spike/core/Package.swift`
- Create: `spike/RESULTS.md`

**Interfaces:**
- Produces: the workflow `spike-windows` (trigger: `push` to `spike/**`), with one job per experiment; later tasks add jobs. Produces `spike/RESULTS.md`.

- [ ] **Step 1: Create the worktree and branch**

```bash
cd /Users/simu/Documents/GitHub/PokeTokenBar
git fetch origin && git worktree add .worktrees/windows-port-spike -b spike/windows-port origin/main
```

- [ ] **Step 2: Add `spike/core/Package.swift`**

A package with one library target `PTBShared` whose `path` is `../../Sources/PokeTokenBar` and whose `sources` lists files explicitly. Start with every file under `Core/` and `Team/` that imports only `Foundation` and `Observation` (about 14k lines; find them with `grep -L` on the Apple-only imports listed in the spec §3). Add a test target pointing at the test files that import none of AppKit, SwiftUI, SpriteKit. Add SQLite the way chattymin#114 did (a `CSQLite` target with the public-domain amalgamation) only if a listed file needs it; otherwise leave SQLite-using files out and record that.

- [ ] **Step 3: Add the workflow job `core`**

`runs-on: windows-latest`. Install the current swift.org release toolchain (`compnerd/gha-setup-swift`, release branch matching Swift 6.1 or newer). Run `swift build` then `swift test` in `spike/core`, with `continue-on-error` off, and upload the full log as artifact `core-log`.

- [ ] **Step 4: Iterate until it builds, recording every obstacle**

Push, read the log (`gh run view --log-failed --repo likelion-campus/PokeTokenBar`), and for each error either fix it in the spike (smallest change) or drop the file from `sources`. Keep a table in `spike/RESULTS.md`: file, blocking API, fix applied or "excluded", lines.

Pass: `swift build` and `swift test` exit 0 on the runner.
Record: lines compiled vs. excluded; number of tests run and failed; each blocking API (expected candidates: `CryptoKit` → swift-crypto, `import Darwin`, `Observation` availability, file-path assumptions, `DispatchSource`).

- [ ] **Step 5: Commit and write the result note**

```bash
git add -A && git commit -m "spike: build the shared logic on Windows"
```

---

### Task 2: Can a Mac and a Windows PC find each other and talk over TLS-PSK?

**Files (spike branch only):**
- Create: `spike/probe/Package.swift`, `spike/probe/Sources/ptbprobe/main.swift`
- Create (if needed): `spike/probe/Sources/CWinShim/` (C shim for Win32 / Schannel headers)
- Modify: `.github/workflows/spike-windows.yml` (job `probe`)
- Create: `spike/probe/README-ko.md` (how the user runs it, in Korean)

**Interfaces:**
- Consumes: `scripts/team-probe.swift` as the Mac peer and the reference for exact wire values.
- Produces: `ptbprobe.exe` with the same commands as the Mac probe:
  `ptbprobe serve <code>`, `ptbprobe browse <code>`, `ptbprobe browse <code> --host <host> --port <port>`.
  It prints one line per stage: `ADVERTISED`, `FOUND <name>`, `TCP OK`, `TLS OK <ciphersuite>`, `FRAME OK`, or `FAIL <stage> <error code>`.
  Produces the artifact `ptbprobe-win-x64.zip` (the exe plus the Swift runtime DLLs it needs, so it runs on a PC with nothing installed).

- [ ] **Step 1: Discovery.** Implement advertise and browse with `DnsServiceRegister` / `DnsServiceBrowse` / `DnsServiceResolve` from `windns.h` for `_ptbteam._tcp.local`. No Apple Bonjour SDK.

- [ ] **Step 2: Plain TCP.** `serve` listens on an ephemeral port and advertises it; `browse` resolves and connects with Winsock. This isolates firewall problems from TLS problems.

- [ ] **Step 3: TLS-PSK with Schannel.** Wrap the socket with Schannel using `SCH_USE_PRESHAREDKEY_ONLY`, TLS 1.2 only, PSK identity `ptb-team-v1`, key derived exactly as `TeamCode.pskKey` does (port that HKDF with swift-crypto; assert in a unit check that a fixed code gives the same key bytes as the Mac — print the key's SHA-256 on both sides and compare).

- [ ] **Step 4: One frame each way.** After the handshake send and receive one frame in the app's format (4-byte big-endian length + JSON `{"probe":true}`), matching what `scripts/team-probe.swift` exchanges.

- [ ] **Step 5: CI job `probe`.** Build on `windows-latest`, run `serve` and `browse` against each other on the runner's loopback, and upload `ptbprobe-win-x64.zip`. This only proves the APIs link and run; it is not the answer.

- [ ] **Step 6: The real run (needs the user).** Write `spike/probe/README-ko.md` with exact steps, then ask the user to run on their Windows PC, logged in as a standard (non-admin) user, on the office Wi-Fi, against a Mac running `swift scripts/team-probe.swift`:

| Run | Windows | Mac |
|---|---|---|
| A | `ptbprobe serve <code>` | `browse <code>` |
| B | `ptbprobe browse <code>` | `serve <code>` |
| C | the real Mac app in the same team (code from its settings) | `ptbprobe browse <code>` sees the app's service |

The README tells them what to do at the firewall prompt and to paste the printed lines back. The zip also contains the Task 3 renderer (`ptbdraw.exe`), so one PC session covers both.

Pass: A and B both reach `FRAME OK` with no admin prompt beyond the standard firewall "allow on private networks" dialog, and C prints `FOUND`.

- [ ] **Step 7: If Schannel PSK fails for a standard user** (`FAIL TLS …`): repeat steps 3–6 with a TLS library linked into the exe that supports PSK suites (first choice: BoringSSL via `swift-nio-ssl`'s vendored copy, or OpenSSL from vcpkg, whichever builds on the runner). Record which one worked, its binary size, and its licence.

- [ ] **Step 8: If discovery fails but `--host/--port` works:** record it as "mDNS blocked or incompatible", capture which direction fails, and stop. That outcome goes back to the user (spec §9: a transport change is theirs to decide).

- [ ] **Step 9: Commit and write the result note**, including the Windows build number and whether security software was running.

---

### Task 3: Can Swift draw the plaza with Direct2D, on screen and headless?

**Files (spike branch only):**
- Create: `spike/draw/Package.swift`, `spike/draw/Sources/ptbdraw/main.swift`, `spike/draw/Sources/CD2DShim/` (C/C++ shim over the COM interfaces)
- Modify: `.github/workflows/spike-windows.yml` (job `draw`)

**Interfaces:**
- Produces: `ptbdraw.exe <out.png> [--window]`. Without `--window` it renders offscreen and writes a PNG. With it, it also opens a window showing the same frame.
- Produces artifact `draw-png` (the CI render) and, from the user's PC, a second PNG.

- [ ] **Step 1: Offscreen target.** Create a WIC bitmap render target (software), 960×640.

- [ ] **Step 2: Draw one fixed scene** from the real resources in `Sources/PokeTokenBar/Resources/Plaza/`:
  - a 20×12 block of tiles from `plaza-tiles.png` at 3× with nearest-neighbour scaling;
  - one sprite on top, drawn twice: normal, and flipped horizontally with 50% alpha;
  - a rectangle blended with multiply over half the scene (the daylight tint);
  - the text `광장 Plaza 123` in Galmuri11 at its native size, loaded from `Galmuri11.ttf` as a private font (not installed), aliased;
  - a name plate `시무` in Pretendard Bold (download the OFL release in the workflow; do not commit it) on a rounded rectangle;
  - the emoji `🎉` with colour-font rendering.

- [ ] **Step 3: Save as PNG through WIC.**

- [ ] **Step 4: CI job `draw`.** Build, run headless on `windows-latest`, upload `draw-png`. View the PNG (Read tool) and check: tiles are crisp (no blur between pixels), Hangul renders in both fonts, the multiply tint darkens, the emoji is in colour.

- [ ] **Step 5: Real-GPU comparison (needs the user, same session as Task 2).** The user runs `ptbdraw.exe out.png --window` and sends back `out.png`. Compare with the CI PNG pixel by pixel; record the count of differing pixels and where (text edges are the expected place).

Pass: the headless PNG is correct by the checks in step 4. A difference in step 5 is recorded, not a failure.
Record: how COM was reached from Swift (shim size in lines), exe size, and whether headless output is usable for PR images.

- [ ] **Step 6: Commit and write the result note.**

---

### Task 4: Does a Mac plaza layer behind a drawing interface look and cost the same?

**Files (spike branch only):**
- Create: `Sources/PokeTokenBar/Team/Plaza/SpikeDraw.swift` (the minimal interface and its SpriteKit implementation)
- Modify: `Sources/PokeTokenBar/Team/Plaza/PlazaPondLayer.swift`
- Create: `Tests/PokeTokenBarTests/SpikePondRenderTests.swift`

**Interfaces:**
- Produces (spike only, names not binding on stage 2):
  `protocol DrawNode: AnyObject` with `position`, `zPosition`, `alpha`, `isHidden`, `addChild(_:)`, `removeFromParent()`;
  `protocol DrawSprite: DrawNode` with `texture`, `size`, `anchorPoint`;
  `protocol DrawFactory` with `makeNode() -> DrawNode`, `makeSprite(texture: DrawTexture) -> DrawSprite`, `makeTexture(rgba: Data, width: Int, height: Int) -> DrawTexture`;
  `final class SpriteKitDrawFactory: DrawFactory`.
  Only what `PlazaPondLayer` needs. Do not design the full interface here.

- [ ] **Step 1: Capture the baseline before touching anything.** In `SpikePondRenderTests`, render the production `PlazaScene` offscreen with `SKRenderer` (the method in the `offscreen-plaza-render` memory; an existing render test shows the setup) and write PNGs for three conditions: noon, night, and a snow day, each with one diver in the pond. Save them outside the repo.

- [ ] **Step 2: Move `PlazaPondLayer` behind the interface.** It must no longer `import SpriteKit`; the scene hands it a `DrawFactory`.

- [ ] **Step 3: Render the same three conditions again and compare** byte-for-byte per pixel.

Pass: 0 differing pixels in all three.

- [ ] **Step 4: Measure frame cost.** Run the scene's `update` 600 times offscreen before and after, with `ContinuousClock`, three runs each. Record the medians.

Pass: the after-median is within run-to-run noise of the before-median (report both; do not round away a real difference).

- [ ] **Step 5: Run the existing pond tests** (`swift test --filter Pond`). Record how many needed changes to compile and why. This number feeds the stage 2–3 estimate for moving tests.

- [ ] **Step 6: Commit and write the result note.**

---

### Task 5: Write the results into the spec and size stages 1–8

**Files:**
- Modify: `docs/superpowers/specs/2026-11-13-windows-port-design.md` (on `docs/windows-port-design`)

- [ ] **Step 1: Add a "§9 결과" block** under each of the four experiments: yes/no, the evidence, and the decision it settles (TLS: Schannel or bundled library and which; drawing: confirmed stack and headless-PNG method; build: the list of blocking APIs).

- [ ] **Step 2: Fix every spec statement the results contradict.** In particular §3's line counts, §7's TLS and discovery rows, §5's Windows stack, and §13.

- [ ] **Step 3: Replace §13's "전체 분량" with a per-stage size estimate** built from the measured numbers (lines excluded in Task 1, shim sizes, tests needing change in Task 4).

- [ ] **Step 4: If any experiment ended "no", stop here** and bring the user the result and the options, in Korean, before changing the design's direction.

- [ ] **Step 5: Open the docs PR** (English title and body, `docs(team): …`), merge it, and tell the user what the four answers were and what stage 1 will be.

- [ ] **Step 6: Keep the spike branch** pushed for reference; delete the local worktree.

---

## Order and parallelism

Tasks 1, 3 and 4 need no one but the agent and can run in any order or in parallel (1 and 3 share the workflow file: add jobs, don't rewrite). Task 2's steps 1–5 are also agent-only. Task 2 step 6 and Task 3 step 5 wait on the user's Windows PC; prepare the zip and README first so that one sitting covers both. Task 5 comes last.
