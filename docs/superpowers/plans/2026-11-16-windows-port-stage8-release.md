# Windows Port, Stage 8 (Release Integration) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One release command, `scripts/team-release.sh`, ships the Mac zip and the Windows installer as one GitHub release. Both have the same version and come from the same commit. Nothing becomes public until both builds have passed their gates. The installed Windows app finds that release, downloads the installer, checks it, installs it and comes back on the new version, as the Mac does through Homebrew. `TEAM.md` and the README describe both systems, with Windows captures the CI runner made from the real app. Then `windows-port` merges into `main` through one merge PR that passed every gate on the exact merged tree, and the long-lived branch is retired.

**Architecture:**
- **The Mac half stays as it is.** `team-release.sh` builds, signs and checks the universal app on the release Mac.
- **The Windows half runs only on GitHub's Windows runner.** The release script dispatches `windows-app.yml` and `windows.yml` in a new *release mode*, pinned to the exact release commit (`release_sha`). They run at level full and report through a manifest artifact. CI keeps `contents: read` and never touches a release.
- **One writer.** A new fork-owned Python helper, `scripts/team_release.py`, is the only code that writes a release. It finds or starts the Windows runs, waits for them, downloads their results and recomputes the hashes. Then it creates a **draft** release with both assets, checks the draft against the local hashes, publishes it, and checks `releases/latest` and the tag. Its logic is unit-tested with a fake `gh`.
- **In-app update.**
  - The shared update feed learns the installer asset's address, size and SHA-256 digest. Pure checks decide whether that asset may be installed.
  - The Windows runner downloads it through the WinHTTP seam and checks the size and the digest. It writes the file under `%LOCALAPPDATA%\PokeTokenBar\Updates`, starts the Inno installer silently and exits.
  - The installer starts the new app afterwards. If the install fails, it starts the old one again.
  - The Mac path is byte-for-byte unchanged.
- **Docs.**
  - `TEAM.md` gets a Windows section, and the README gets a short pointer to it in each of en, ko and ja.
  - The Windows captures come from the runner.
  - A docs gate per OS stops a release whose new visible feature has no new capture.

**Tech Stack:** bash 3.2 (`team-release.sh`), Python 3.9 standard library only (the helpers and their `unittest` tests; the Command Line Tools' `python3`), GitHub CLI, GitHub Actions (`windows-latest` with Swift `6.3.2-RELEASE`; `ubuntu-latest` for the helper tests), Swift 6.3.2, Inno Setup 6, PowerShell 7 on the runner. Both apps stay as they are, except the Windows app's update installer.

**Spec:** `docs/superpowers/specs/2026-11-13-windows-port-design.md` (Korean, binding): §2 (G1, G5, failure conditions), §10 step 8, §11 ("윈도우 빌드·테스트가 깨져 있으면 릴리스가 나가지 않는다. 그동안 맥 배포도 같이 멈춘다"), §12 (배포), §13. Earlier plans: Track B D5, Tasks 10 and 12 (`2026-11-14-windows-port-track-b-windows-app.md` lines 236–248, 969–1091); stage 7 "What stage 8 needs from this stage" (`2026-11-16-windows-port-stage7-popover.md` lines 1223–1231). Ledgers: `.superpowers/sdd/2026-11-14-windows-port-track-b-windows-app/` (`task-10-report.md`, `task-12-report.md`, `pc-defects-1-report.md`, `progress.md`), `…/2026-11-15-windows-port-stage6-plaza-renderer/progress.md`, `…/2026-11-16-windows-port-stage7-popover/progress.md`.

**Base:** `windows-port` at `c4016c9`. That is `origin/main` `8f050c9` (v2.5.634) plus 471 commits; `main` has no commit that `windows-port` lacks. Stage 6 is merged through Task 6 (Task 7, the PC milestone, is next). Stage 7 has started (Tasks 1–3 briefed).

---

## Facts this plan rests on (read in source at `c4016c9` and from GitHub on 2026-11-16)

| # | Fact | Where | Consequence |
|---|---|---|---|
| F1 | **The team fork releases with `scripts/team-release.sh`, not `release.sh`.** The script: reads `VERSION` (37); requires `main`, a clean tree and `HEAD == origin/main` (42–56); requires that tag and release do not exist yet (59–66); checks the signing leaf (69–77); runs `test-gate.sh` (81); runs `build-app.sh`, which also installs into `/Applications` (89); checks the built leaf, zips and checks for a universal binary (94–99); runs `gh release create … --target "$LOCAL_HEAD"` (103); then updates the team tap (108–115). It never pushes (7) and has no landing or Pages step (10). Bumps arrive as `chore(release): bump the team version to x.y.z` PRs; the script runs from a fresh clone (memory "Lean release flow"). | `scripts/team-release.sh` | Stage 8 extends `team-release.sh`. |
| F2 | `scripts/release.sh` is upstream's: `REPO="chattymin/PokeTokenBar"` (15), `git push origin main` (149), `gh release create … --repo "$REPO"` (152), the chattymin tap (155–163). Its `doc_check` (21–77) warns on stale screenshots (36–47) and hard-fails when a `feat` commit touched UI but no asset was *added* (52–65). | `scripts/release.sh` | Never run on the fork. Its asset-gate rule is ported into a fork-owned check (D14). The fork's `CLAUDE.md` still names `release.sh` and `RELEASE.md` (lines 11, 58, 105). Task 10 adds a pointer. |
| F3 | Team notes are only checked for being non-empty (`team-release.sh` 31). `release-metadata.py check-notes` demands the chattymin brew lines (24–26), so it cannot check team notes. The v2.5.634 notes use New / Fixed / Other / Contributors plus team Install/Upgrade lines (`brew install --cask likelion-campus/tap/poke-token-bar-team`). | `gh release view v2.5.634 --repo likelion-campus/PokeTokenBar` | A fork-owned team template and checker (Task 3). |
| F4 | `TeamReleaseScriptTests` (text checks) pin the script. There is exactly one `gh release create`, with `--repo likelion-campus/PokeTokenBar` and `--target "$LOCAL_HEAD"`. The only gh calls allowed are `gh auth status`, `gh release create/view` and the tap's `gh api` (31–59, 61–72). There is no `git push/tag/commit` (74–79). Every check sits above the build (83–127). `TEAM.md` and the script contain no `@` and no `.local` (167–178). | `Tests/PokeTokenBarTests/TeamReleaseScriptTests.swift` | Task 7 rewrites these together with the script. The script may not contain `$@`, and `TEAM.md` may not contain an `@handle`. |
| F5 | The REST answer of `releases/latest` gives each asset `name`, `size`, `state`, `browser_download_url` and **`digest: "sha256:<64 hex>"`**. The download URL 302-redirects to `release-assets.githubusercontent.com`. | `gh api repos/likelion-campus/PokeTokenBar/releases/latest`; `curl -sI` on v2.5.634's zip | The Windows app checks the download against the digest in the same API answer it already fetches (D9). The download follows one cross-origin HTTPS redirect. |
| F6 | **Mac updates:** shared `UpdateChecker` reads `releases/latest` of `likelion-campus/PokeTokenBar` (47, 107–118). It applies a 30-minute cooldown after a successful check (73–84) and compares versions numerically (178–187). `applyUpdate` (157–173): with the team cask, a detached `brew update; brew upgrade --cask poke-token-bar-team`, reopen (221–243), terminate; otherwise it opens the release page (167–170). No Sparkle, no appcast. | `Core/UpdateChecker.swift` (upstream-owned, already routed through `PlatformShell` by Track B Task 10) | The Mac path is not changed. Windows hooks the "no brew" branch with one line (D8). |
| F7 | **Windows updates today:** `WindowsUpdates` builds the shared checker with `currentVersion: WindowsInstall.version ?? "0.0.0"` and the `InstallerReleaseFeed` fetch, and passes no `brewLocator` (`WindowsShell.swift` 29–37). It checks at launch and when the tray menu opens (35, 56–59). A "no installer" answer starts a 30-minute cooldown (43–50; `InstallerReleaseFeed.swift` 63–68). The feed offers a release only when an asset named `PokeTokenBar-Setup-<anything>-win-x64.exe` exists (15–32), and it returns the release *page* (24). The tray's update item opens that page (`WinTrayHost.swift` 112–113). | `Platform/InstallerReleaseFeed.swift`, `Platform/Windows/WindowsShell.swift`, `WinTrayHost.swift` | Stage 8 adds the asset's URL, size and digest, the version-in-name check and the install. |
| F8 | `WindowsInstall.version` is the trimmed text of `PokeTokenBar.version` next to the exe (23–28). | `Platform/Windows/WindowsInstall.swift` | The comparison base on Windows. Without the file, the app is not an installed copy. |
| F9 | **Version stamping today:** one source, `VERSION="x.y.z"` in `build-app.sh` (6). `build-resources.ps1` writes `VERSIONINFO` x.y.z.0 (7–19). `package.ps1` writes `PokeTokenBar.version` (38) and fails unless the exe's FileVersion is x.y.z.0 (42–45). ISCC gets `/DAppVer` from the version file (`windows-app.yml` 541–553), which sets `AppVersion` and the file name (iss 17, 31). The workflow checks the file name (557) and the installed version file (576). The setup exe itself carries no version info (no `VersionInfoVersion` in `[Setup]`). | as named | Release mode adds the setup exe's version info and asserts every stamp against the release version (Task 1). |
| F10 | **The installer:** per-user install (`PrivilegesRequired=lowest`, `{localappdata}\Programs\PokeTokenBar`; iss 20–23) with a fixed `AppId` (15). Changing the `AppId` breaks upgrades (Task 12 report). `ArchitecturesAllowed=x64compatible` (24–25), `MinVersion=10.0` (26). It closes a running app with `WM_CLOSE` to its sink window and waits 15 s (72–94), and starts the app after the install, also in silent mode (52). It is unsigned: SmartScreen shows "More info → Run anyway", with no UAC prompt (Task 12 report; user's PC, 2026-11-15). | `installer/PokeTokenBar.iss` | D8, D11, D12. |
| F11 | **`windows-app.yml`:**<br>- Levels light and full (2–10, 60). Full runs on `windows-port` pushes or with `-f level=full`.<br>- Triggers: push to `windows-port`, PRs on Windows paths, dispatch (12–49).<br>- `permissions: contents: read` (50–51). Concurrency cancels runs on work branches (52–54).<br>- The upgrade test, idle gate and uninstall check run only at full (592, 669, 817).<br>- The installer is a 3-day artifact: "nothing is attached to a release" (853–860).<br>- Measured: full on `windows-port` takes **44–48 min** (runs 43717157900, 43732838551); light takes 23–33 min. | `.github/workflows/windows-app.yml`; `gh run list` | Release mode is full plus a pinned SHA plus a manifest (Task 1). The release waits for the full run (D3). |
| F12 | **`windows.yml`** runs on pushes to `main` and `windows-port`, on every PR, and on dispatch (3–7). It fails under 2400 executed tests (37) and takes 14–21 min. **`ci.yml`** runs on `macos-15` (Xcode 16), on PRs into `main` and pushes to `main` only (3–7, 19), and takes 14–16 min. The release Mac builds with Swift 6.3.2. | workflows; `swift --version` | `ci.yml` has never built `windows-port` code, because its PRs target `windows-port`. The first `macos-15` build of the port is the merge PR (Task 11, risk K1). |
| F13 | The WinHTTP seam caps a body at **32 MB** ("the largest answers are under 1 MB", `WinHTTPFetch.swift` 39, 63) and a fetch at 300 s (64). **The installer has been 31.6 MB since stage 6 Task 2** (stage 6 ledger). Redirects drop `Authorization`, never go from HTTPS to HTTP, and may cross origins when no `Cookie` is set (33–37). Real hosts are refused outside the packaged app (192–197). | `Platform/Windows/WinHTTPFetch.swift` | The download needs its own cap and deadline (D19). A near-miss for the defect log (Task 6). |
| F14 | **Scans:**<br>- On Windows, only the seam may send requests. Routed sites are counted per file; `InstallerReleaseFeed.swift: 1` (`WindowsSeamScanTests` 324–346).<br>- The `Process()` launch sites are pinned (`ToolLaunchArgumentScanTests` 31–33).<br>- Windows leaves only through `WindowsApp.exit` (`WindowsSeamScanTests` 200–222; `ExitReason` in `WindowsApp.swift` 74). | tests named | The download goes through a seam overload. The installer is started with Win32 `CreateProcessW`, not `Process()`. The exit gains `ExitReason.update`. |
| F15 | **Docs:**<br>- The fork has no landing page: `git ls-remote origin gh-pages` is empty, and `team-release.sh` line 10 says so.<br>- `README*.md` are upstream's: their last 6 commits are upstream's (e.g. `54f6fab`), and they point at chattymin's tap.<br>- `TEAM.md` (Korean, text only, no images) is the team's install guide (5–35: Mac install and update). | git, files | D14. |
| F16 | **The repository** is public and not part of a GitHub fork network. Merge commits are allowed. `main` and `windows-port` are unprotected. The release Mac's gh token has the `repo` and `workflow` scopes. | `gh api repos/likelion-campus/PokeTokenBar`, `…/branches/*`, `gh auth status` | Windows runners cost no money, and the release Mac can dispatch workflows and download artifacts. |
| F17 | `windows-port` and `main` differ in 738 files. 42 upstream-owned files in `Core/`, `UI/` and `PokeTokenBarApp.swift` differ (839+/772−). The team shipped 5 releases between 2026-11-13 06:13 and 2026-11-14 15:28 (v2.5.630–634). | `git diff --stat`, `gh release list` | The merge plan (D16) and its PR body list the upstream-owned lines. |
| F18 | **What stage 7 hands over** (plan 1223–1231):<br>- the parity scan, green inside the Mac gate;<br>- `applyUpdate` on Windows to download and run the installer;<br>- captures from `--dump-ui` popover pages;<br>- for the notes' Windows section: the popover differences and the tier 3 status;<br>- the popover idle windows in the Windows gate;<br>- `WindowsInstall.version` shown in Settings;<br>- nothing new in the installer (the URL protocol comes with tier 3 Task 23). | stage 7 plan | Tasks 6, 8 and 10 consume these. |
| F19 | **From the ledgers:**<br>- The first run of an unsigned installer shows SmartScreen, and Defender may scan the first start (Task 12 report).<br>- The tray icon lands in the `^` overflow on Windows 11 (PC check, 2026-11-15).<br>- The firewall asks once when the team starts; allow it on Private (Track B progress, Task 19 notes). | ledgers | Content for `TEAM.md`'s Windows section. |

---

## Global Constraints

- **Speed rules (user decision, 2026-11-14) — these override any stricter wording below.**
  1. There is no per-task full Mac gate. A task is verified by the filtered suites for what it touched, `./scripts/shared-check.sh` and `swift test --filter 'ScanTests'`. The full gate `./scripts/test-gate.sh` runs after Task 6 (milestone) and in Task 11 (before the merge).
  2. Do not wait for Windows CI before merging a task into `windows-port`. Merge, let the push run CI, and fix forward. Tasks whose proof *is* a CI run (1, 5, 6, 8, 9) still read their own run before asking for review.
  3. Tasks marked **[most capable]** keep an independent review.
- **Nothing is published while stage 8 is being built.** No `gh release create/edit/delete/upload/delete-asset`, no tags, no tap writes, no signing, and no uploads to any third party (no VirusTotal or similar). Workflow dispatches, run reads and artifact downloads are allowed: they are CI, not publication. The helper's `publish` is exercised only against a fake `gh` in tests. The first real publish is Task 12. It is triggered by the user's natural-language release request, after the version and notes have been shown once (`CLAUDE.md` §릴리스).
- **Repositories.** Every `gh` call passes `--repo likelion-campus/PokeTokenBar` (or names `repos/likelion-campus/PokeTokenBar/…`). Upstream `chattymin/*` is never touched. These upstream-owned files are not edited: `scripts/release.sh`, `RELEASE.md`, `scripts/release-metadata.py`, `docs/reference/release-notes-template.md` and `docs/reference/release-workflow.md`.
- **Worktrees and PRs.** Work in `.worktrees/<task-branch>` cut from `origin/windows-port`, never in the main checkout, and never run a bare `git stash`. Each task starts with `git merge --no-ff origin/main`. Each task is one PR into `windows-port`, merged with a merge commit. Titles are English Conventional Commits. Bodies follow `.agents/skills/prepare-pr/SKILL.md` and `.github/PULL_REQUEST_TEMPLATE.md`. Visible changes carry images through the team's PR-image route (tray state in Task 6, captures in Task 8, docs in Task 10).
- **The Mac build slot.** Only one `swift build` / `swift test` / `shared-check.sh` / `plaza-render-compare.sh` runs at a time on this Mac. Before each, `pgrep -x swift-build; pgrep -x swift-test; pgrep -x xctest` must print nothing. Wait in chunks of at most ~150 s per Bash call, for the build slot and CI runs alike. Never end a turn waiting for a notification.
- **Scripts.**
  - `team-release.sh` stays bash 3.2: `set -euo pipefail`, no `declare -A`, `mapfile` or `readarray`. It contains no `@` character (F4).
  - Helpers are Python 3.9 with the standard library only. Every `gh` and `git` call goes through one injectable runner, and every rule has a `unittest` test in `scripts/tests/` that uses a fake runner. No test calls the real `gh`.
- **Windows code rules (Track B, stage 7).**
  - Windows-only Swift lives under `Sources/PokeTokenBar/Platform/Windows/`, each file wrapped whole in `#if os(Windows)`. Shared seams go in `Platform/*.swift`.
  - Upstream-owned files (`Core/**`, `UI/**`) get only one-line call sites, each listed in the PR and pinned by a Mac test. This stage has one: `Core/UpdateChecker.swift` (Task 4).
  - Exits go only through `WindowsApp.exit`. Requests go only through the seam. Work on the main actor stays bounded: hashing and file writes happen off it.
- **Idle cost is a failure condition (spec §2).** This stage adds no timer, no polling and no background download. The updater does nothing until a user clicks "Update".
- **The defect protocol** in `CLAUDE.md` applies: root cause including why tests missed it, a class sweep after reading `docs/reference/defect-log.md`, a trigger-branch test after a reachability check, fault injection and a permanent capture.
- **Models per role (user rule).** `opus` for release-gate logic and for the update and installer security path (Tasks 1, 2, 4, 5, 6, 7, 12); `sonnet` for the rest (3, 8, 9, 10, 11, 13); `haiku` for single mechanical commands.

---

## Design decisions (later tasks rely on them)

Each decision below is the planner's call (spec silent). Where the spec decides, it is cited. Questions only the user can answer are under "Open questions".

**D1. One command, same trigger.**
- A natural-language release ("배포해줘", "패치 배포") still runs `scripts/team-release.sh <notes>` on `main` from a fresh clone, as today (F1). Version words keep their meaning (`CLAUDE.md` §릴리스).
- The run now takes about 50 minutes. The agent starts it with `run_in_background`, reads its log in chunks of at most 150 s, and never ends a turn waiting.
- `release.sh` stays upstream's and is never run on the fork (F2).

**D2. Build where, publish where.**
- The Mac half is built locally, as today. The Windows half is built only on GitHub's Windows runner (spec §12), dispatched by the release on the exact release commit.
- The workflows keep `contents: read` and never touch a release. `scripts/team_release.py publish`, run by the release Mac, is the only writer.
- Rejected: "the workflow uploads to the release itself". That needs a write token in CI and splits one publish decision across two machines. It also lets a Windows asset reach GitHub before the Mac build has passed.

**How the commit is pinned:**
- `gh workflow run windows-app.yml --ref main -f release_sha=<40 hex> -f release_version=x.y.z`, and the same for `windows.yml`. `workflow_dispatch` takes a branch, not a SHA, so the SHA travels as an input.
- `actions/checkout` uses `ref: release_sha`. The first step asserts three things:
  - `git rev-parse HEAD` equals `release_sha`;
  - `VERSION` in `scripts/build-app.sh` equals `release_version`;
  - the workflow file and `.github/actions/windows-swift/` are identical at `release_sha` and at the dispatching ref (`github.sha`). If `main` moved and changed the workflow in between, the run fails with "start the release again".
- `run-name: release <version> <sha>` makes the run findable.
- The concurrency group is `<workflow>-release-<sha>` and is never cancelled, so a later push to `main` cannot cancel a release run.
- The manifest (Interfaces) records the SHA, version, level, every gate's outcome, file names, sizes and SHA-256 values. The helper recomputes the hash after downloading.

**D3. Gate order: nothing public until both systems pass.** Times are from F11 and F12 and the stage 6 milestone gate (17.6 min).

| Step | What | Time | |
|---|---|---|---|
| 0 | Arguments, gh, `VERSION`, `main`/clean/`HEAD == origin/main`, no tag or release yet, signing leaf | seconds | existing |
| 1 | Helper self-tests, notes check, docs gate | seconds | new |
| 2 | Start Windows: reuse a running or successful release run for this SHA, else dispatch both workflows | < 1 min | new |
| 3 | Mac test gate + cfprefsd guard | 10–18 min | existing |
| 4 | Mac build (`/Applications` updated, as today), built-leaf check, zip, universal check | minutes | existing |
| 5 | Wait for both Windows runs, download, verify the manifests and recompute the hashes | the rest of 44–49 min | new |
| 6 | Fill the notes (installer SHA-256) | seconds | new |
| 7 | Draft release with both assets; verify the draft (asset set, digests, target) | 1–2 min | new; replaces the direct `gh release create` |
| 8 | Publish (`--draft=false --latest`); verify `releases/latest` and the tag | seconds | new |
| 9 | Team tap | seconds | existing |
| 10 | Dispatch the post-release smoke and print its URL | seconds | new; not waited for, the agent reads it before reporting |

- A release takes **about 50–55 minutes of wall clock**, against about 25–30 today. The Windows full run dominates; the Mac steps 3–4 overlap it.
- If the agent starts the Windows runs as soon as the bump PR merges (`python3 scripts/team_release.py start …`, documented in Task 10), the script reuses them and the release takes about 30 minutes.
- The Mac build slot is held only for steps 3–4, as today.

**D4. What the Windows gate is.**
- `windows.yml`: the shared XCTest suites on Windows, at least 2400 executed and 0 failures.
- `windows-app.yml` at level full: bundle selftests, installer build, silent install, installed selftest, upgrade over a running instance, idle gate and uninstall.
- Two release-time additions that also run in every full run:
  - an upgrade from the previous published Windows release (Task 1);
  - the in-app update end to end, against a loopback feed (Task 6).
- Why full: the idle gate is a spec failure condition (§2), and after the merge nothing else runs full on every commit. Open question 2 asks whether a lighter gate is wanted.

**D5. When something fails.**
- **A Windows run fails or times out (100 min).** The script stops before anything is public and prints the run URL. The release Mac's `/Applications` already holds the new build; that is today's behaviour for any failure after step 4. Nothing to roll back.
- **The Mac gate fails.** The script stops. The dispatched Windows run finishes by itself, and the next attempt on the same SHA reuses it.
- **A fix is needed.** Merge the fix and run again with the same `VERSION`: no tag exists yet, so no new bump is needed. The release SHA becomes the new `HEAD`, and runs for the old SHA are ignored.
- **No automatic retry of a failed Windows run.** A flake hidden by a retry is a defect nobody sees. The agent reads the failure. For a known flake, it starts a new run explicitly (`team_release.py start --new`), and the flake goes through the defect protocol.
- **A draft fails a check or an upload.** The helper re-reads `isDraft`, deletes the draft it created and stops. A draft is not public and creates no tag.
- **The tap update fails after publishing.** As today: a message with the values to fix by hand.

**D6. Release assets.** Every release has exactly two assets: `PokeTokenBar.zip` and `PokeTokenBar-Setup-<v>-win-x64.exe`.
- The helper refuses any other set, on the draft and again after publishing.
- Each asset's `state` must be `uploaded`, and its `digest` must equal the local SHA-256.
- The notes carry the installer's SHA-256 for anyone checking a browser download with `Get-FileHash`.
- A Mac-only release can no longer be made.

**D7. Version stamping: one number, every place.**
- **`VERSION` in `build-app.sh` is stamped into:**
  - the Mac `Info.plist` (existing);
  - the exe's `VERSIONINFO` x.y.z.0 and `PokeTokenBar.version` (existing);
  - the installer file name, `AppVersion` and so the Uninstall `DisplayVersion` (existing);
  - **new:** the setup exe's own version info (`VersionInfoVersion={#AppVer}.0`, `VersionInfoProductVersion={#AppVer}`, `VersionInfoDescription=PokeTokenBar Setup`).
- **Release mode asserts every stamp** equals `release_version` and records them in the manifest.
- **The feed on Windows:**
  - the tag goes through `UpdateChecker.normalizedReleaseVersion`;
  - the asset must be named `PokeTokenBar-Setup-<that version>-win-x64.exe`;
  - an offer needs `isNewer(tag, than: WindowsInstall.version)`;
  - without a version file (a bare build), the offer still shows but the in-app install is refused (D8 step 2).

**D8. The update path on Windows, end to end.** The Mac's brew branch gets a Windows twin, behind the same banner, Settings rows and "Updating…" spinner.
1. **Find.** The request is unchanged: `releases/latest` with a 15 s timeout, at launch and when the tray menu or popover opens, with the 30-minute cooldowns. The feed now also parses the installer asset into `InstallerReleaseFeed.Installer` (version, name, URL, size, SHA-256), and `WindowsUpdates` keeps the last one.
2. **Offer.** The offer shows as today when the asset exists. "Update" installs in-app only when the asset passes every check and the app is an installed copy:
   - the name is exactly the one for the tag's version;
   - the URL is exactly `https://github.com/likelion-campus/PokeTokenBar/releases/download/v<v>/<name>`;
   - `state` is `uploaded`;
   - the size is 1–200 MB;
   - the digest is `sha256:` plus 64 lowercase hex.

   Otherwise "Update" opens the release page, as today, with one log line that names the reason.
3. **Download.** Only on a user click: the tray item, or the popover banner and Settings, all through `UpdateChecker.applyUpdate`.
   - It goes through the seam overload (D19): WinHTTP over Schannel, TLS 1.2 or later, revocation checked, no certificate check relaxed (F13).
   - The cap is the asset's size and the deadline is 15 minutes.
   - The final URL must be HTTPS on `github.com` or a `*.githubusercontent.com` host.
   - `isUpdating` stays true during the download, so the spinner shows.
4. **Verify.** The status must be 200, the length must equal `size`, and the SHA-256 must equal the digest. The hash is computed off the main actor. Any failure writes nothing, opens the release page and logs the reason, never the bytes or a URL query.
5. **Write.** The file goes to `%LOCALAPPDATA%\PokeTokenBar\Updates\PokeTokenBar-Setup-<v>-win-x64.exe` through a temp file and a rename. Older files in the folder are removed first.
6. **Run.** `CreateProcessW` (no shell, no `runas`, not elevated) with `/SILENT /SUPPRESSMSGBOXES /NORESTART /CURRENTUSER /PTBRELAUNCHONFAIL=1 /LOG="<Logs>\update-<v>.log"`. The app saves the pending marker `windows.pendingUpdate = {version, at}`, flushes it, and calls `WindowsApp.exit(0, .update)`.
7. **Installer.**
   - `InitializeSetup` finds the mutex released, or posts `WM_CLOSE` and waits 15 s (F10).
   - It installs, and `[Run]` starts the new app.
   - If the install fails or is cancelled after our app closed, `DeinitializeSetup` starts `{app}\PokeTokenBar.exe` again, because `/PTBRELAUNCHONFAIL=1` was passed.
   - Inno rolls back the files it replaced when an install is aborted; Task 5 proves it on the runner.
8. **Next start.** The marker is read once.
   - If the version now equals the marker's: log "update to v… done".
   - If not: a log line with the installer log's path and one balloon in every app language ("업데이트를 설치하지 못했어요. 릴리스 페이지에서 직접 설치해 주세요."). The offer stays.

   Either way, the downloaded file is deleted and the marker cleared.
- There is no timer and no background download, so nothing changes while idle.
- The Mac is unchanged: `PlatformShellService.installUpdate`'s default returns `false`, so the Mac's existing branch runs exactly as before.

**D9. What is checked without a signature, and what is not.**
- **Checked:**
  - TLS to `api.github.com` and to the download hosts, with Windows' certificate and revocation checks (F13);
  - the release JSON's shape and the exact URL pattern;
  - that the asset's version equals the tag and is newer than the installed one;
  - the size;
  - the SHA-256, against GitHub's own digest of the uploaded file (F5).
  - On the release side, the helper checked that this digest equals the hash of the CI artifact whose manifest names the release commit.
- **Not checked: who published.** Whoever controls the team's GitHub account or its Actions (a stolen token, say) can publish an installer with a matching digest, and the app would install it. A teammate gives a manual download from the release page the same trust today. Signing (open question 1) or an independently signed manifest would close this gap.
- A process of the same Windows user could swap the file between the write and the start. That account is already compromised.
- Defender still scans the installer when it starts.

**D10. No Mark-of-the-Web on the in-app download.**
- A file our process writes carries no `Zone.Identifier`, so SmartScreen does not prompt on an in-app update. With the mark, SmartScreen would stop the silent install of an unsigned file every time.
- The SHA-256 check replaces that prompt.
- The first install (a browser download) still shows SmartScreen once, and `TEAM.md` explains "More info → Run anyway".

**D11. Rollback.**
- **Normal case:** fix forward with the next patch release. Both systems install it in-app, including PCs whose new build installed but misbehaves.
- **A Windows build that cannot start** (so it cannot update itself): the user runs the previous release's installer from the releases page. Inno allows an older version over the same `AppId`. Settings and state live outside the app folder and are kept (uninstall check, `windows-app.yml` 842).
- **Stopping the spread while a fix is built** (only with the user's approval each time; open question 6): delete only the Windows asset from the bad release (`gh release delete-asset`). The feed then answers "no installer" and no further PC takes it; Macs are unaffected. Windows is then one version behind until the fix — a deliberate, recorded exception to "the same timeline".
- The scripts never delete a published release and never move a tag.

**D12. Minimum Windows and architectures (spec G1).**
- Windows 10 22H2 (build 19045) and Windows 11, x64. Windows 10 is marked untested: there is no Windows 10 PC.
- The installer's `MinVersion` goes from 10.0 to `10.0.19045`, so an older Windows 10 gets Setup's own clear refusal instead of an app that may not work.
- **ARM64:** `x64compatible` already lets the x64 build install on Windows 11 on ARM, which runs it under emulation. That is untested and is documented as such. Windows 10 on ARM has no x64 emulation, so Setup refuses. There is no native ARM64 build.

**D13. Release notes.**
- **The template:** a new fork-owned `docs/reference/team-release-notes-template.md`.
  - New / Fixed / Other / Contributors, as today.
  - An Install / Upgrade block for both systems, with the tokens `{{VERSION}}` and `{{WINDOWS_SHA256}}`.
  - A "Windows differences" line: stage 7's listed popover differences and the tier 3 status.
- **`scripts/team_notes.py check`** runs before any build. The sections must be non-empty, and the Windows block and each token must appear exactly once.
- **`fill`** replaces the tokens after the Windows verification and refuses any leftover token.
- The user sees the version and the notes before the run, as today. The summary says that the installer's SHA-256 is the one value filled in during the run.

**D14. Docs and captures.**
- **`TEAM.md`** (Korean) gets a Windows section, with images from `assets/windows/`:
  - requirements;
  - download and install (SmartScreen steps, no administrator rights);
  - first start (the tray `^` overflow, the firewall prompt: choose Private);
  - updates (in-app; manual the first time);
  - "업데이트가 잘못됐을 때" (D11);
  - uninstall and what stays behind;
  - checking the SHA-256 by hand;
  - the ARM64 and Windows 10 notes;
  - known differences from the Mac.
- **`README.md`, `.ko`, `.ja`** get one short `### Windows (team fork)` subsection after "Manual install" that links `TEAM.md`. That keeps the conflict surface for upstream syncs small. The fork has no landing page (F15), so there is nothing to update there (open question 4).
- **Captures** are made by the real app on the runner with fixture data (`--dump-ui`, the plaza window capture), with no code-drawn art. They are labelled "Sample-data capture, Windows CI runner" in alt text and in `assets/windows/SHOTS.txt`, which lists each file, the run and the command that made it.
- **Asset gates.** The fork-owned `scripts/team_docs_check.py` runs before the build and looks at changes since the last `v*` tag:

  | Group | Paths | Assets that count |
  |---|---|---|
  | Mac | `Sources/PokeTokenBar/UI/`, `Sources/PokeTokenBar/Team/UI/`, `Sources/PokeTokenBar/Platform/Mac/`, `Sources/PokeTokenBar/PokeTokenBarApp.swift` | `assets/` outside `assets/windows/` |
  | Windows | `Sources/PokeTokenBar/Platform/Windows/Popover/`, `…/Platform/Windows/Plaza/`, `…/Platform/Windows/WinTray*.swift`, `Sources/CPlazaD2D/`, `installer/` | `assets/windows/` |
  | Shared (counts for both) | `Sources/PokeTokenBar/Team/Plaza/`, `Sources/PokeTokenBar/Popover/` | both groups |

  - **Hard stop (exit 2, no bypass):** a `feat` commit touched a group's paths and no file was *added* to that group's assets. To get past it, make the capture, or record the judgement with another commit type. This is `release.sh` 52–65 per OS.
  - **Warning:** a group's paths changed but none of its assets changed. It is printed and does not block, because `team-release.sh` asks nothing interactively.
  - **SHOTS.txt check:** every listed file exists, every `assets/windows/*.png` is listed, and every label says "Windows CI runner".
  - Open question 3 asks whether the Mac group should stay in the gate.

**D15. CI on `main` after the merge.**

| Event | Workflows | Wall clock | Runner minutes |
|---|---|---|---|
| Push to `main` | `ci.yml` (macos-15, test gate) | 14–16 min | ~15 |
| | `windows.yml` | 14–21 min | ~20 |
| | `windows-app.yml` at **light** (new on `main`) | 23–33 min | ~30 |
| PR into `main` | `ci.yml`; `windows.yml` (every PR, as now); `windows-app.yml` light when Windows paths change | as above | |
| Release | `windows.yml` + `windows-app.yml` full, dispatched for the SHA | 44–49 min | ~65 |
| After a release | `windows-release-smoke.yml` | ~15 min | ~15 |
| PR or push touching `scripts/**` | `release-tools.yml` (ubuntu, the helper tests) | < 1 min | ~1 |

- This costs no money (a public repository, F16).
- None of these blocks a merge (spec §11).
- A push to `main` cancels a superseded push run of the same workflow. Release runs are never cancelled.

**D16. The merge.**
- **One PR** from `windows-port` into `main`, merged with a merge commit. That keeps the 471 task commits for blame and the defect log; a squash would collapse them.
- **Gates on the exact merge candidate**, a branch `merge/windows-port-into-main` that is `origin/main` plus `origin/windows-port` and nothing else:
  - the full Mac `test-gate.sh` and `shared-check.sh`;
  - `ci.yml` on the PR (the first `macos-15` build, F12);
  - `windows.yml` and `windows-app.yml` full, dispatched on the branch;
  - `team-release.sh --rehearse` (the Windows half, the notes and the docs gate; no Mac build, no publish);
  - `plaza-render-compare.sh` identical against `windows-port`.

  All must be green before the merge.
- **Not while a release is pending.** Right before merging, the lead checks that `v$VERSION` (the `VERSION` on `origin/main`) is a published tag and that no bump PR is open. Otherwise the lead waits. The peer's `team-release.sh` pins its commit, but a fresh clone made after the merge would release the merged tree.
- **Before merging,** the lead sends a coordination message to the peer session (text in Task 12).
- **For later upstream syncs,** the merge PR body lists the 42 upstream-owned files that differ (F17), with their one-line call sites. Upstream-sync PRs resolve against that list.

**D17. Retiring `windows-port`.**
- **When:** after the merge and one successful release of both systems.
- **What changes:**
  - `windows-port` comes out of the workflows' triggers, level and concurrency expressions;
  - `CLAUDE.md`'s spec row loses "(`windows-port` 브랜치)";
  - spec §4 and §11 wording becomes history;
  - `CONTRIBUTING.md` drops the levels note for `windows-port`.
- **The branch:** deleted two weeks later. The history is in `main` through the merge commit, so no archive tag is needed. Worktrees on it are pruned.

**D18. Signing: none now (open question 1).**
- Everything above works unsigned.
- Adding Authenticode later changes only the installer build step (signtool on the runner with a cloud key).
- It would also add a publisher check (`WinVerifyTrust`) to D8 step 4.

**D19. The download seam.**
- A new overload, `PlatformCompat.oneShotDownload(for:maxBytes:deadline:)`, is appended to `PlatformCompat.swift`.
  - Mac branch: `URLSession.shared.data(for:)`. It is never called on the Mac.
  - Windows branch: `WinHTTPFetch.data(…, maxBodyBytes: maxBytes)`, with a configuration whose `timeoutIntervalForResource` is the deadline.
- The body is held in memory: at most 200 MB, 31.6 MB today. A streaming download to disk would be a new WinHTTP path and is not needed at this size.
- `WinHTTPFetch.defaultMaxBodyBytes` (32 MB) stays as it is for API answers.

---

## Interfaces (the contract later tasks rely on)

### Workflows (Task 1)

```yaml
# windows-app.yml and windows.yml: workflow_dispatch.inputs, added
release_sha:     { description: 'Release mode: the 40-hex commit to build (set by team_release.py)', default: '' }
release_version: { description: 'Release mode: the x.y.z that commit carries in scripts/build-app.sh', default: '' }
# run-name in release mode: "release <version> <sha>" (other runs keep their default title; check how an empty run-name renders)
# concurrency in release mode: group "<workflow>-release-<sha>", cancel-in-progress false
# windows-app in release mode: level full; diagnostics, fast, stall_hunt and net_burst forced off
```

Artifacts in release mode, kept 7 days:
- `windows-app.yml` → `windows-release`: `PokeTokenBar-Setup-<v>-win-x64.exe` and `windows-release.json`.
- `windows.yml` → `windows-tests`: `windows-tests.json`.

```jsonc
// windows-release.json, schema 1. Written only by a successful release-mode run (last step, if: success())
{ "schema": 1, "sha": "<release_sha>", "workflowSha": "<github.sha>", "version": "2.5.640", "level": "full",
  "runId": 0, "runAttempt": 1, "runnerImage": "<ImageVersion>", "swift": "6.3.2",
  "installer": { "name": "PokeTokenBar-Setup-2.5.640-win-x64.exe", "size": 0, "sha256": "<64 hex>",
                 "fileVersion": "2.5.640.0", "productVersion": "2.5.640",
                 "isccDefines": ["SrcDir", "AppVer", "OutDir"] },
  "app": { "fileVersion": "2.5.640.0", "versionFile": "2.5.640", "uninstallDisplayVersion": "2.5.640" },
  "gates": { "bundleSelftest": "success", "install": "success", "upgrade": "success", "installedSelftest": "success",
             "idle": "success", "uninstall": "success", "upgradeFromRelease": "success|first",
             "failedUpdateRelaunch": "success", "inAppUpdate": "success" } }
// windows-tests.json, schema 1
{ "schema": 1, "sha": "<release_sha>", "version": "2.5.640", "executed": 0, "skipped": 0, "failures": 0 }
```

`gates` lists the gate steps the workflow has at that commit. The helper keeps a constant, `REQUIRED_GATES`, and refuses a manifest that lacks one of them or reports anything but `success` (`upgradeFromRelease` may also be `first`). Task 1 starts the set with the gates that exist today; Tasks 5 and 6 each add their gate's name to both the workflow and `REQUIRED_GATES` in the same PR. So a rehearsal before Tasks 5 and 6 still passes, and a release after them cannot skip their steps.

### Python helpers (Tasks 2, 3)

```
scripts/team_release.py   (Task 2; every gh call through Gh.run, which appends --repo likelion-campus/PokeTokenBar)
  start   --sha SHA --version V [--ref main] [--new]
          prints WINDOWS_APP_RUN=<id> and WINDOWS_TESTS_RUN=<id>; writes build/windows-release/runs.json
          exit 0; 3 = the newest release run for SHA failed (and no --new)
  collect --sha SHA --version V --out DIR [--timeout-min 100]
          prints INSTALLER=<path> and SHA256=<hex>
          exit 0; 4 = a run failed or timed out, or a manifest or hash mismatch
  publish --sha SHA --version V --zip PATH --installer PATH --notes PATH
          exit 0 = published and verified; 5 = stopped before publishing (its own draft removed); 6 = published, a later check failed
  smoke   --version V   prints the run URL (or "no smoke workflow yet", exit 0)

scripts/team_notes.py      (Task 3)
  check --in NOTES                                       exit 0 / 1 with the reason
  fill  --in NOTES --version V --sha256 HEX --out OUT     refuses a leftover {{…}}

scripts/team_docs_check.py (Task 3)
  [--since TAG]   exit 0 (warnings printed) / 2 hard stop
```

### Swift (Tasks 4 and 6)

```swift
// Platform/InstallerReleaseFeed.swift (shared), additions. parse / isInstallerName / Outcome keep their meaning.
extension InstallerReleaseFeed {
    struct Installer: Equatable, Sendable {
        let version: String   // "2.5.640" (normalized tag)
        let name: String      // "PokeTokenBar-Setup-2.5.640-win-x64.exe"
        let url: URL          // https://github.com/likelion-campus/PokeTokenBar/releases/download/v2.5.640/<name>
        let size: Int         // bytes, from the asset
        let sha256: String    // 64 lowercase hex, from the asset's "digest"
    }
    static let releaseDownloadPrefix = "https://github.com/\(UpdateChecker.releaseRepo)/releases/download/"
    static func expectedName(version: String) -> String
    /// nil unless exactly one installer asset passes every D8-step-2 check. `downloadPrefix` is replaced only by the CI selftest.
    static func installer(in data: Data, downloadPrefix: String = releaseDownloadPrefix) -> Installer?
    /// One request; `outcome()` becomes `fetch().outcome`.
    static func fetch(repo: String = UpdateChecker.releaseRepo, session: URLSession = .shared) async -> (outcome: Outcome, installer: Installer?)
}

// Platform/UpdateDownloadCheck.swift (shared, pure)
enum UpdateDownloadCheck {
    enum Refusal: Equatable, CustomStringConvertible {
        case notPackaged, notNewer, status(Int), insecure, finalHost(String), length(expected: Int, got: Int), digest
    }
    static func isAllowedFinalHost(_ host: String) -> Bool          // "github.com" or a "*.githubusercontent.com" host
    static func sha256Hex(_ data: Data) -> String
    static func refusal(status: Int, finalURL: URL?, body: Data, for installer: InstallerReleaseFeed.Installer,
                        allowedHost: (String) -> Bool = isAllowedFinalHost, allowHTTP: Bool = false) -> Refusal?
}

// Platform/PlatformShell.swift
@MainActor protocol PlatformShellService {
    func open(_ url: URL)
    func terminate()
    /// true: the installer is starting and the app is leaving. false: not handled here, so the caller opens the release page.
    func installUpdate(version: String) async -> Bool
}
extension PlatformShellService { func installUpdate(version: String) async -> Bool { false } }   // Mac, LoggingShell, test shells

// Core/UpdateChecker.swift (upstream-owned): ONE line, first in applyUpdate's no-brew branch (F6, line 167):
//     if await PlatformShell.current.installUpdate(version: update.version) { return }

// Platform/PlatformCompat.swift (append-only)
static func oneShotDownload(for request: URLRequest, maxBytes: Int, deadline: TimeInterval) async throws -> (Data, URLResponse)

// Platform/Windows/WindowsUpdateInstaller.swift
@MainActor enum WindowsUpdateInstaller {
    static let pendingKey = "windows.pendingUpdate"                // ["version": String, "at": Double]
    static func updatesFolder() -> URL                             // %LOCALAPPDATA%\PokeTokenBar\Updates
    static func arguments(logFile: URL) -> [String]                // D8 step 6, in that order
    /// nil = launched (then `onLaunched`, which exits by default); otherwise why nothing was started.
    static func install(_ installer: InstallerReleaseFeed.Installer, currentVersion: String?, defaults: UserDefaults,
                        fetch: @escaping (URLRequest) async throws -> (Data, URLResponse),
                        launch: (URL, [String]) -> Bool = WinProcess.launchDetached,
                        onLaunched: @MainActor () -> Void = { WindowsApp.exit(0, .update) }) async -> UpdateDownloadCheck.Refusal?
    static func reportAtLaunch(defaults: UserDefaults, currentVersion: String?, balloons: WinBalloonPresenter?)
}
// Platform/Windows/WinProcess.swift: static func launchDetached(_ exe: URL, _ args: [String]) -> Bool   (CreateProcessW, quoted)
// WindowsShell.installUpdate(version:) → WindowsUpdates.install(version:) → WindowsUpdateInstaller.install(…)
// WindowsUpdates.start passes brewLocator: { nil }; WindowsApp.ExitReason gains `.update`.
// CI-only selftest flags (need CI=true and the installed layout):
//   --selftest-update-from <http://127.0.0.1:port/…>   a loopback feed; downloads only from that prefix (Task 6)
//   --selftest-update-live                             one live check + applyUpdate against the real feed (Task 9)
```

### Inno (Tasks 1 and 5)

```
[Setup] VersionInfoVersion={#AppVer}.0  VersionInfoProductVersion={#AppVer}  VersionInfoDescription=PokeTokenBar Setup   (Task 1)
        MinVersion=10.0.19045                                                                                           (Task 5)
/PTBRELAUNCHONFAIL=1   DeinitializeSetup starts {app}\PokeTokenBar.exe again when setup did not finish                 (Task 5)
#ifdef PTBTestFailInstall   test builds only: fail after the app was closed, before any file is replaced               (Task 5)
```

---

## File Structure

```
.github/workflows/windows-app.yml              modify (T1 release mode, levels, main push; T5 failed-update step; T6 in-app update step; T8 docs-shots)
.github/workflows/windows.yml                  modify (T1 release mode, windows-tests.json)
.github/workflows/release-tools.yml            create (T2) ubuntu: python3 -m unittest discover -s scripts/tests
.github/workflows/windows-release-smoke.yml    create (T9)
scripts/team-release.sh                        modify (T7)
scripts/team_release.py                        create (T2)
scripts/team_notes.py, scripts/team_docs_check.py   create (T3)
scripts/tests/test_team_release.py             create (T2)
scripts/tests/test_team_notes.py, test_team_docs_check.py   create (T3)
scripts/test-gate.sh                           modify (T4) LOGIC_CORE += the two shared update files
scripts/windows/release-manifest.ps1, upgrade-from-release.ps1   create (T1)
scripts/windows/ci-helpers.ps1                 modify (T5, T6) helpers only
scripts/windows/update-feed-server.ps1         create (T6) loopback HttpListener
scripts/windows/docs-shots.ps1                 create (T8)
scripts/windows/release-smoke.ps1              create (T9)
scripts/import-windows-shots.sh                create (T8)
installer/PokeTokenBar.iss                     modify (T1 version info; T5 MinVersion, relaunch, test define)
Sources/PokeTokenBar/Platform/InstallerReleaseFeed.swift   modify (T4)
Sources/PokeTokenBar/Platform/UpdateDownloadCheck.swift    create (T4)
Sources/PokeTokenBar/Platform/PlatformShell.swift          modify (T4)
Sources/PokeTokenBar/Core/UpdateChecker.swift              modify (T4) one line
Sources/PokeTokenBar/Platform/PlatformCompat.swift         modify (T6) append oneShotDownload
Sources/PokeTokenBar/Platform/TrayMenuModel.swift          modify (T6) updating state
Sources/PokeTokenBar/Platform/Windows/
  WindowsUpdateInstaller.swift, WinProcess.swift, WindowsSelftestUpdate.swift   create (T6)
  WindowsShell.swift                           modify (T4 cache + brewLocator; T6 installUpdate)
  WindowsApp.swift                             modify (T6) ExitReason.update, reportAtLaunch, flag dispatch
  WinTrayHost.swift                            modify (T6) .openRelease → applyUpdate; "업데이트 중…" item
  WindowsSelftestShell.swift                   modify (T6) update.feed expectations
Tests/PokeTokenBarTests/
  InstallerReleaseFeedTests.swift, UpdateCheckerTests.swift   modify (T4)
  UpdateDownloadCheckTests.swift               create (T4) (shared)
  WindowsUpdateInstallerTests.swift            create (T6) (Windows, wrapped whole)
  WindowsSeamScanTests.swift                   modify (T6) routed sites
  TrayMenuModelTests (existing file)           modify (T6)
  TeamReleaseScriptTests.swift                 modify (T7, T10)
docs/reference/team-release-notes-template.md  create (T3)
docs/reference/team-release.md                 create (T10)
docs/reference/defect-log.md                   modify (T6, T10)
assets/windows/SHOTS.txt (+ PNGs)              create (T3 header; T8 files)
TEAM.md, README.md, README.ko.md, README.ja.md, CLAUDE.md, CONTRIBUTING.md   modify (T10; T13 for the branch wording)
docs/superpowers/specs/2026-11-13-windows-port-design.md   modify (T10 §10/§12/§13 as built; T13 §4/§11)
```

## Review Focus

Seven ways this could look done and be wrong:

1. **A release built or published from the wrong bytes.** A moving branch built instead of the release commit; a stale artifact; a run of another workflow or event; a workflow file that changed between dispatch and checkout. → The pinned checkout with its three assertions; `run-name` matching; manifest fields checked; the hash recomputed on the Mac; digests compared on the draft and after publishing; fault injection in Task 1 (wrong version, changed workflow) and Task 2 (every mismatch).
2. **Something public before both gates pass.** A tag created early; a release published while an upload is still running; a draft left behind and later published by hand; the tap updated before the release. → The draft → verify → publish order inside one helper; Python tests with injected failures at every step; `TeamReleaseScriptTests` order checks; `--rehearse` never reaches `publish`.
3. **The update path runs unverified bytes or loses the app.** An installer from an unexpected URL; a missing digest treated as fine; the 32 MB cap; hashing on the main actor; an app that exited before a failed install and never comes back; settings or `memberID` lost. → Pure checks tested on both OSes; the tampered and short-body selftests; the in-app e2e step and the failed-update relaunch step in every full run; fault injection on the digest check and on the relaunch.
4. **Windows never offers the update, or offers the wrong one.** An asset version different from the tag; a cooldown that hides a new release; a cached installer for an older version; an offer to a bare build. → Feed tests with real API-shaped JSON; the `update.feed` selftest updated; `reportAtLaunch` tests.
5. **The gate quietly gets lighter.** A release accepted from a light run, a skipped idle gate, a rerun until green. → The manifest records the level and every gate outcome, and `collect` refuses anything but full and all-success; there is no automatic retry; `inputs.fast` is ignored in release mode.
6. **Docs drift.** A Windows UI change ships without a new capture; captures are drawn by code or edited; `TEAM.md` and the notes disagree on the minimum Windows. → The per-OS docs gate; `SHOTS.txt` provenance; text tests for the guide's Windows strings.
7. **The merge breaks `main` or the peer's release.** The `macos-15` toolchain fails on the port's code; the merge lands between the peer's bump and its tag; `main` CI turns red for the peer. → Task 11's rehearsal of every gate on the exact merge candidate; the pending-release check; the coordination message before the merge.

Also check in every review: the Mac app is unchanged except the one `UpdateChecker` line, and the default `installUpdate` returns false on the Mac.

---

## Tasks at a glance

| # | Task | Model | Size | Can start now | Needs |
|---|---|---|---|---|---|
| 1 | Release mode in the Windows workflows | opus | M | **yes** | — |
| 2 | The release helper: Windows runs, publishing and its checks | opus | L | **yes** | Task 1's manifest schema (fixed above); checked against Task 1's real artifact before merge |
| 3 | Team release notes and the per-OS docs gate | sonnet | M | **yes** | — |
| 4 | Update feed: the installer asset and its checks (shared) | opus | M | **yes** | — |
| 5 | Installer: minimum Windows, relaunch after a failed update | opus | S | **yes** | — |
| 6 | In-app update on Windows: download, check, install, come back | opus | L | **yes**, after 4 | Task 4; its e2e step needs Task 5 |
| 7 | `team-release.sh`: one command for both systems | opus | M | **yes**, after 1–3 | Tasks 1, 2, 3 |
| 8 | Windows captures for the docs, made on the runner | sonnet | M | **partly**: tray and plaza now; popover pages wait | stage 7 Tasks 5–6 for the popover pages |
| 9 | Post-release smoke on a clean runner | sonnet | S | **yes** | Task 1 (artifact mode); Task 6 for the live-update half |
| 10 | Docs for both systems | sonnet | M | no | Tasks 6, 7, 8; stage 7 tiers 1–2 (Task 18) |
| 11 | Merge rehearsal on the merged tree | sonnet | M | no | Tasks 1–10; stage 6 and 7 as the user decides (open question 7); the user's go |
| 12 | The merge and the first release of both systems | opus (lead) | M | no | Task 11; the user's word |
| 13 | Retire `windows-port` | sonnet | S | no | Task 12 and one good release of both systems |

---

### Task 1: Release mode in the Windows workflows **[most capable]** — Size M — opus — can start now

**Files:**
- Modify:
  - `.github/workflows/windows-app.yml`;
  - `.github/workflows/windows.yml`;
  - `installer/PokeTokenBar.iss` (the three `VersionInfo*` lines in `[Setup]` only);
  - `CONTRIBUTING.md` ("Building the Windows app": release mode, levels on `main`).
- Create: `scripts/windows/release-manifest.ps1`, `scripts/windows/upgrade-from-release.ps1`.

**Interfaces:** Produces the workflow inputs, `run-name`, concurrency, artifacts and both manifest schemas (Interfaces). Consumed by Tasks 2, 7, 9 and 11.

**Steps:**
- [ ] Add the inputs `release_sha` and `release_version` to both workflows, plus `run-name` and the release concurrency group (D2). Push and PR groups stay as they are. In release mode, `actions/checkout` gets `ref: ${{ inputs.release_sha }}` and fetches `github.sha` too, so the workflow can be compared.
- [ ] First job step **"Release pin"** (release mode only):
  - [ ] `release_sha` is 40 hex characters, and `git rev-parse HEAD` equals it;
  - [ ] `VERSION` in `scripts/build-app.sh` equals `release_version`;
  - [ ] `git diff --quiet "$GITHUB_SHA" "$RELEASE_SHA" -- <this workflow> .github/actions/windows-swift`, else fail with "main moved and changed the workflow; start the release again";
  - [ ] one summary line.
- [ ] **Levels:**
  - full when: a push to `windows-port`, `inputs.level == 'full'`, or release mode;
  - in release mode, force `diagnostics`, `fast`, `stall_hunt` and `net_burst` off, so a release run never skips the idle gate;
  - add `main` to `windows-app.yml`'s push branches at level light. That is inactive until the merge (D15).
- [ ] **Version stamps:**
  - [ ] the `.iss` `VersionInfo*` lines;
  - [ ] in the ISCC step, assert `(Get-Item <setup>).VersionInfo.FileVersion -eq "$v.0"` and `ProductVersion -eq $v`;
  - [ ] in the install step, assert the Uninstall `DisplayVersion` equals `$v`. Today it is only printed.
- [ ] **`upgrade-from-release.ps1`** (full level, after the uninstall step, as step id `upgrade-from-release`):
  - [ ] find the newest published release older than this version that has a Windows installer asset, through the public API with `GITHUB_TOKEN` for the rate limit;
  - [ ] download it and check its size and digest;
  - [ ] on a fresh profile, install it, start it, write a setting and close it;
  - [ ] install this run's installer over it, and assert: the version file, `memberID` and the setting are kept, and the app is relaunched;
  - [ ] uninstall.

  When there is no earlier Windows release, print `PASS upgrade.fromRelease: first (no earlier Windows release)`. Downloading from github.com is a read, not an upload.
- [ ] **`release-manifest.ps1`** (release mode only, last step, `if: success()`):
  - [ ] write `windows-release.json` per the schema; the gate outcomes come from `steps.<id>.outcome`;
  - [ ] assert the shipped installer's ISCC defines are exactly `SrcDir`, `AppVer`, `OutDir`;
  - [ ] upload the artifact `windows-release` (the installer and the manifest, 7 days).

  In `windows.yml`, write `windows-tests.json` from the executed, skipped and failure counts in `test.log`, and upload the artifact `windows-tests`.
- [ ] **Fault injection** on a scratch branch, deleted afterwards. Record the run URLs.
  - [ ] Dispatch with a wrong `release_version` → "Release pin" fails.
  - [ ] Dispatch with a `release_sha` whose workflow file differs from the branch's → it fails.
  - [ ] Break one installed-selftest check → the job fails and there is no `windows-release` artifact.
- [ ] **Verify on the task branch:**
  - [ ] `gh workflow run windows-app.yml --ref <branch> -f release_sha=$(git rev-parse HEAD) -f release_version=<VERSION> --repo likelion-campus/PokeTokenBar` → success;
  - [ ] `gh run download <id> -n windows-release --repo likelion-campus/PokeTokenBar` → every manifest field is right, and `shasum -a 256` of the installer equals the manifest;
  - [ ] the same for `windows.yml` → `windows-tests.json` shows at least 2400 executed and 0 failures;
  - [ ] run the release dispatch twice more on the same SHA and record each wall time and result. That is the flake-rate check for risk K2.
- [ ] **PR `ci(windows): build a release from a pinned commit and report it`**.

**Verify:** the dispatched runs above, green, with their artifacts. **Size:** M. **PC:** no.

---

### Task 2: The release helper: Windows runs, publishing and its checks **[most capable]** — Size L — opus — can start now

**Files:**
- Create: `scripts/team_release.py`, `scripts/tests/test_team_release.py`, `.github/workflows/release-tools.yml`.

**Interfaces:** Produces the `team_release.py` CLI (Interfaces). Consumes Task 1's manifests. Consumed by Tasks 7, 9 and 11.

**Steps:**
- [ ] **The runners.**
  - [ ] A `Gh` class runs `gh <args> --repo likelion-campus/PokeTokenBar`; `gh api` paths name `repos/likelion-campus/PokeTokenBar/…` explicitly. A `Git` runner does the same for `git ls-remote origin`.
  - [ ] Tests use fakes that record the calls and return canned JSON and exit codes.
  - [ ] A test scans the module's own call sites. There is never `git push`, `gh release delete` without a fresh `isDraft == true` read just before it, `--cleanup-tag`, `gh api -X DELETE`, or another repository.
- [ ] **`start`.**
  - [ ] For each workflow, `gh run list --workflow <w> --json databaseId,displayTitle,status,conclusion,event,createdAt --limit 50`.
  - [ ] Match `displayTitle == "release <V> <S>"` with event `workflow_dispatch`, and take the newest.
  - [ ] Queued, in progress or success → reuse it. Failure → exit 3 unless `--new`.
  - [ ] None → `gh workflow run <w> --ref <ref> -f release_sha=S -f release_version=V`, then poll up to 60 s in 5 s steps for the new run to appear.
  - [ ] Write `build/windows-release/runs.json`.
- [ ] **`collect`.**
  - [ ] Poll `gh run view <id> --json status,conclusion,event,workflowName` every 60 s up to the timeout, printing one line per 5 minutes. Both runs must conclude `success`.
  - [ ] Download the artifacts `windows-release` and `windows-tests` with `gh run download`.
  - [ ] Check every manifest field:
    - sha, version and level `full`;
    - every gate `success`, except `upgradeFromRelease`, which may also be `first`;
    - the installer name;
    - the ISCC defines are exactly the three;
    - the tests: `executed >= 2400` and `failures == 0`.
  - [ ] Recompute the installer's SHA-256 and size. Print `INSTALLER=` and `SHA256=`.
- [ ] **`publish`.**
  - [ ] No release `vV` may exist yet; a leftover draft is reported, not reused.
  - [ ] `gh release create vV <zip> <installer> --draft --target S --title vV --notes-file N`.
  - [ ] Verify the draft:
    - `isDraft` is true and `targetCommitish` is S;
    - the assets are exactly `{PokeTokenBar.zip, <expected installer name>}`;
    - each is `uploaded`, with a digest equal to the local SHA-256.
  - [ ] `gh release edit vV --draft=false --latest`.
  - [ ] Verify after publishing: `gh api repos/likelion-campus/PokeTokenBar/releases/latest` names `vV` with the same assets and digests, and `git ls-remote origin refs/tags/vV` points at S.
  - [ ] **Before the edit, any failure:** re-read `isDraft`. If it is still true, `gh release delete vV --yes`, then exit 5. **After the edit:** exit 6 with what to check. A published release is never deleted.
  - [ ] Before relying on them, check gh's draft behaviour in its help and source: a draft found by tag in `view`/`edit`, no tag before publishing, the tag created at `--target` on publish. Write the assumptions into the fakes and into the PR (risk K3).
- [ ] **`smoke`:** `gh workflow run windows-release-smoke.yml --ref main -f version=V`, then print the run URL. If the workflow does not exist yet, print "no smoke workflow yet" and exit 0.
- [ ] **Tests (fake runner):**
  - [ ] `start`: reuse a green run; reuse a running one; refuse a failed one; dispatch when there is none; a dispatched run that never appears.
  - [ ] `collect`:
    - [ ] success, a failed conclusion, a timeout;
    - [ ] a manifest with another sha, another version, level light, a failed gate, an extra ISCC define;
    - [ ] after the download, a hash or size mismatch.
  - [ ] `publish`:
    - [ ] the happy path's exact call order;
    - [ ] an upload failure → the draft is deleted and nothing is published;
    - [ ] a digest mismatch on the draft → deleted;
    - [ ] an extra asset → deleted;
    - [ ] `releases/latest` is not `vV` after publishing → exit 6, nothing deleted;
    - [ ] `isDraft` reads false at cleanup time → not deleted;
    - [ ] a release that already exists → refused before `create`.
- [ ] **Fault injection:** remove the digest comparison → the mismatch test fails; remove the `isDraft` re-read → the "not deleted" test fails. Revert both.
- [ ] **`release-tools.yml`:** `ubuntu-latest`, `python3 -m unittest discover -s scripts/tests -v`, on PRs and pushes that touch `scripts/**` or this workflow.
- [ ] **Read-only run against GitHub:** `start` and `collect` on Task 1's branch run (`--ref <branch>`). `publish` is never run against GitHub in this task.
- [ ] **PR `build(release): a helper that gates and publishes both builds`**.

**Verify:** `python3 -m unittest discover -s scripts/tests -v` (no Mac build slot needed); `release-tools.yml` green; the read-only `start`/`collect` log. **Size:** L. **PC:** no.

---

### Task 3: Team release notes and the per-OS docs gate — Size M — sonnet — can start now

**Files:**
- Create:
  - `docs/reference/team-release-notes-template.md`;
  - `scripts/team_notes.py`, `scripts/team_docs_check.py`;
  - `scripts/tests/test_team_notes.py`, `scripts/tests/test_team_docs_check.py`;
  - `assets/windows/SHOTS.txt` (a header that defines the line format; no files yet).

**Interfaces:** Produces the `team_notes.py` and `team_docs_check.py` CLIs and the template tokens. Consumed by Tasks 7, 8 and 10.

**Steps:**
- [ ] **The template** (English, D13):
  - [ ] New / Fixed / Other / Contributors with v2.5.634's guidance;
  - [ ] Mac Install / Upgrade: v2.5.634's team-tap lines;
  - [ ] Windows Install: download `PokeTokenBar-Setup-{{VERSION}}-win-x64.exe`; Windows 10 22H2 or 11, x64; no administrator rights; SmartScreen "More info → Run anyway", because the installer is not code-signed;
  - [ ] Windows Upgrade: in-app from the first version that can install updates (filled in Task 12); earlier builds run the installer once;
  - [ ] `SHA-256 (Windows installer): {{WINDOWS_SHA256}}`;
  - [ ] a `Windows differences:` line.
- [ ] **`team_notes.py`:**
  - [ ] `check`: the four sections non-empty after removing comments; the Windows Install and Upgrade lines present; each token exactly once;
  - [ ] `fill`: replace the tokens, then refuse any remaining `{{`;
  - [ ] tests for each rule, both ways.
- [ ] **`team_docs_check.py`** (D14):
  - [ ] the path groups are data at the top of the file;
  - [ ] "since" is the last `v*` tag reachable from `HEAD` (`git describe --tags --match 'v*' --abbrev=0`);
  - [ ] `feat` detection is `^(feat|feature)[(:!]` on `git log --format=%s <tag>..HEAD -- <paths>`;
  - [ ] added assets come from `git diff --name-only --diff-filter=A`, changed assets without the filter;
  - [ ] the `SHOTS.txt` check.
- [ ] **Docs-gate tests** in a temporary git repository (init, commit, tag, then the case):
  - [ ] Windows `feat` + no new `assets/windows/` file → 2;
  - [ ] a new Mac-group asset does not satisfy the Windows group;
  - [ ] a shared path needs both groups;
  - [ ] `fix` → a warning only;
  - [ ] redrawing an existing capture does not count as added;
  - [ ] a PNG missing from `SHOTS.txt` → 2;
  - [ ] a label without "Windows CI runner" → 2.
- [ ] **Fault injection:** count modified files as added → the "redrawn" test fails. Revert.
- [ ] **The backlog:** run `python3 scripts/team_docs_check.py --since v2.5.634` on `windows-port`. It is expected to stop with exit 2 (Windows and shared `feat` commits without captures). Record the list in the PR: it is what Tasks 8 and 10 must clear before Task 12.
- [ ] **PR `build(release): team release notes for both systems and a docs gate per OS`**.

**Verify:** `python3 -m unittest discover -s scripts/tests -v`; the backlog printout. **Size:** M. **PC:** no.

---

### Task 4: Update feed: the installer asset and its checks (shared) **[most capable]** — Size M — opus — can start now

**Files:**
- Modify:
  - `Sources/PokeTokenBar/Platform/InstallerReleaseFeed.swift`;
  - `Platform/PlatformShell.swift`;
  - `Core/UpdateChecker.swift` (one line);
  - `Platform/Windows/WindowsShell.swift`:
    - keep the last `Installer`;
    - pass `brewLocator: { nil }`;
    - add `WindowsUpdates.install(version:)` returning false until Task 6;
  - `Tests/PokeTokenBarTests/InstallerReleaseFeedTests.swift`, `UpdateCheckerTests.swift`;
  - `scripts/test-gate.sh` (`LOGIC_CORE`).
- Create: `Sources/PokeTokenBar/Platform/UpdateDownloadCheck.swift`, `Tests/PokeTokenBarTests/UpdateDownloadCheckTests.swift`.

**Interfaces:** Produces `InstallerReleaseFeed.Installer`, `installer(in:)`, `fetch()`, `UpdateDownloadCheck` and `PlatformShellService.installUpdate`. Consumed by Tasks 6 and 9.

**Steps:**
- [ ] **Failing tests first** (shared, so both OSes). The fixture is the real v2.5.634 JSON shape (F5) plus an installer asset.
  - [ ] Accepted: one valid installer.
  - [ ] Rejected (nil):
    - [ ] the name for another version;
    - [ ] a tag that is not plain x.y.z;
    - [ ] a URL with another repository, tag, host or scheme;
    - [ ] `state` other than `uploaded`;
    - [ ] a size of 0, over 200 MB, or not an integer;
    - [ ] a digest that is missing, not `sha256:`, the wrong length or not lowercase hex;
    - [ ] two installer assets.
  - [ ] `parse` and the offer keep today's meaning.
- [ ] **`fetch()`:** one request returns `(outcome, installer)`, and `outcome()` becomes `fetch().outcome`. The existing outcome tests keep their meaning.
- [ ] **`UpdateDownloadCheck`:**
  - [ ] every `Refusal` case;
  - [ ] allowed final hosts: `github.com`, `release-assets.githubusercontent.com`, `objects.githubusercontent.com`;
  - [ ] refused: `githubusercontent.com.evil.test`, `evilgithubusercontent.com`, `api.github.com`, IP literals;
  - [ ] `http` → `.insecure` unless `allowHTTP`;
  - [ ] SHA-256 known answers for `""` and `"abc"`.
- [ ] **`PlatformShellService`:** add the requirement with its default extension. The existing shells (`MacShell`, `LoggingShell`, `WindowsShell`, test doubles) compile unchanged.
- [ ] **The upstream line** in `UpdateChecker.applyUpdate`, first in the no-brew branch, *before* `isUpdating = false`: `if await PlatformShell.current.installUpdate(version: update.version) { return }`.
  - [ ] Mac pin: the whole `UpdateCheckerTests` suite runs unchanged.
  - [ ] New tests with recording shells: `installUpdate` returns false → the page opens once and `isUpdating` ends false; it returns true → no page and `isUpdating` stays true.
  - [ ] A Mac test asserts `MacShell().installUpdate` and `LoggingShell().installUpdate` return false. That is safe: neither opens or ends anything.
- [ ] **Coverage:** add the two shared files to `LOGIC_CORE`. Check `xcrun llvm-cov show … --show-regions` for `^0` in the new branches (`CLAUDE.md`).
- [ ] **Fault injection:** accept any digest length → a test fails; check the host with `hasSuffix("githubusercontent.com")` without the leading dot → the "evil" test fails. Revert both.
- [ ] **PR `feat(update): read the Windows installer's address and digest from the release`**. The body lists the upstream line and its pins.

**Verify:** `swift test --filter 'InstallerReleaseFeed|UpdateDownloadCheck|UpdateChecker|ScanTests'`; `./scripts/shared-check.sh`; `windows.yml` green with the new tests executed. **Size:** M. **PC:** no.

---

### Task 5: Installer: minimum Windows, relaunch after a failed update **[most capable]** — Size S — opus — can start now

**Files:**
- Modify:
  - `installer/PokeTokenBar.iss`;
  - `.github/workflows/windows-app.yml` (a full-level step "A failed update brings the old app back", step id `failed-update-relaunch`);
  - `scripts/windows/ci-helpers.ps1` (helpers).

**Interfaces:** Produces `/PTBRELAUNCHONFAIL=1` and the `PTBTestFailInstall` define (Interfaces). Consumed by Task 6's arguments and e2e step.

**Steps:**
- [ ] **`MinVersion=10.0.19045`**, with a comment: x64 and ARM64 Windows 11 run the x64 build; Windows 10 on ARM is refused (D12).
- [ ] **The relaunch on failure:**
  - [ ] a global flag set in `CurStepChanged(ssDone)`;
  - [ ] `DeinitializeSetup`: when `{param:PTBRELAUNCHONFAIL|0}` is `1`, the flag is not set and `{app}\PokeTokenBar.exe` exists, `ExecAsOriginalUser` it with `ewNoWait`;
  - [ ] log both branches.
- [ ] **`#ifdef PTBTestFailInstall`:** fail after `InitializeSetup` closed the app and before any file is replaced. `PrepareToInstall` returning a message is the first candidate. Check in the setup log that `DeinitializeSetup` still runs and no file was replaced.
- [ ] **The CI step** (full level):
  - [ ] build `installer-fail` from `bundle-next` with `/DPTBTestFailInstall=1`;
  - [ ] with the installed vN running, run it with D8's arguments → Setup exits non-zero; the old app was closed, then started again with the same version and `memberID`;
  - [ ] control: the same with `/PTBRELAUNCHONFAIL=0` → no relaunch;
  - [ ] Task 1's manifest proves the shipped installer was built without the define.
- [ ] **Fault injection:** drop the `DeinitializeSetup` relaunch → the step fails. Revert.
- [ ] **PR `build(windows): the installer brings the app back when an update fails`**.

**Verify:** `windows-app` full on the branch, green, with the step's `PASS` lines. **Size:** S. **PC:** no.

---

### Task 6: In-app update on Windows: download, check, install, come back **[most capable]** — Size L — opus — can start now, after Task 4

Milestone: run the full Mac gate after this task.

**Files:**
- Create:
  - `Platform/Windows/WindowsUpdateInstaller.swift`;
  - `Platform/Windows/WinProcess.swift`;
  - `Platform/Windows/WindowsSelftestUpdate.swift`;
  - `Tests/PokeTokenBarTests/WindowsUpdateInstallerTests.swift`;
  - `scripts/windows/update-feed-server.ps1`.
- Modify:
  - `Platform/PlatformCompat.swift` (append `oneShotDownload`);
  - `Platform/Windows/WindowsShell.swift` (`installUpdate` → `WindowsUpdates.install`);
  - `Platform/Windows/WindowsApp.swift` (`ExitReason.update`, `reportAtLaunch` after the tray exists, the two selftest flags);
  - `Platform/Windows/WinTrayHost.swift` (`.openRelease` → `WindowsUpdates.checker?.applyUpdate()`; a disabled `l.updating` item while `isUpdating`);
  - `Platform/TrayMenuModel.swift` and its tests;
  - `Platform/Windows/WindowsSelftestShell.swift` (`update.feed`);
  - `Tests/PokeTokenBarTests/WindowsSeamScanTests.swift` (routed sites);
  - `.github/workflows/windows-app.yml` (the e2e step, step id `in-app-update`);
  - `docs/reference/defect-log.md`.

**Interfaces:** Produces `WindowsUpdateInstaller`, `WinProcess.launchDetached`, the seam overload, `ExitReason.update` and the two CI-only flags. Consumes Tasks 4 and 5.

**Steps:**
- [ ] **Windows unit tests** (no network, no process):
  - [ ] `arguments(logFile:)` is exact and quoted;
  - [ ] `updatesFolder()`;
  - [ ] the pending marker round-trips;
  - [ ] `reportAtLaunch`: success; failure (one balloon, marker cleared, file deleted); no marker.
- [ ] **`install` with an injected fetch and launch:**
  - [ ] good bytes → the file is written with exactly those bytes, `launch` gets the path and arguments, the marker is saved and flushed, and `onLaunched` is called;
  - [ ] one tampered byte → `.digest`, nothing written, no launch, the page opens;
  - [ ] a short body → `.length`;
  - [ ] a final `http` URL → `.insecure`;
  - [ ] a final host off the list → `.finalHost`;
  - [ ] no version file → `.notPackaged`;
  - [ ] the same version → `.notNewer`.
- [ ] **Off the main actor:** hashing and the file write run in `Task.detached`. The selftest `update.hashMs` hashes a 32 MB buffer and prints the time; `loop.mainThreadStalls` is unaffected.
- [ ] **The seam overload (D19).** Find out what `URLResponse.url` holds after WinHTTPFetch followed a redirect.
  - If it is the final hop, check it directly.
  - If it is the first URL, report that. Then take the final host from what WinHTTPFetch followed, or ask the lead before touching `WinHTTPFetch.swift`.

  Update the routed-site count in `WindowsSeamScanTests`.
- [ ] **Wiring:** the tray item and the popover's banner and Settings rows (stage 7, unchanged) all go through `applyUpdate`. Put the tray capture with "업데이트 중…" in the PR, labelled as a sample-data capture from the Windows CI runner.
- [ ] **In-process selftest checks** (CI): `update.refusesTampered`, `update.refusesWrongSize`, `update.refusesOffPatternURL`, `update.markerReport`, `update.hashMs`.
- [ ] **The e2e CI step** (full level; needs Task 5 merged):
  - [ ] `update-feed-server.ps1` serves on `127.0.0.1` a release JSON for vN+1 (`installer-next`'s name, size and digest, with a loopback download URL) and the bytes;
  - [ ] start the installed vN with `CI=true` and `--selftest-update-from http://127.0.0.1:<port>/releases/latest`;
  - [ ] assert:
    - [ ] the old process exits 0 with `reason=update` within 120 s;
    - [ ] `update-<vN+1>.log` shows success;
    - [ ] a new process runs from the install folder with version vN+1;
    - [ ] `memberID` and a setting are kept;
    - [ ] the log has "update to vN+1 done" after the relaunch;
    - [ ] the `Updates` folder is empty;
    - [ ] the server logged exactly one JSON request and one download;
  - [ ] the tampered variant: the server flips one byte → the app logs the refusal, does not exit, and the version is unchanged.
- [ ] **Fault injection:** skip the digest check → `update.refusesTampered` and the tampered e2e fail. Revert.
- [ ] **Defect-log entry** (in the log's language): the class "a default cap sized for API answers silently blocks a larger download". The installer is 31.6 MB and the seam's cap is 32 MB (F13). Rule: every new download names its own cap and deadline. The guard is this task's length test plus the seam signature.
- [ ] **PR `feat(windows): install updates from the tray and the popover`**. The body includes the tray image and the e2e run URL.

**Verify:**
- `swift test --filter 'WindowsUpdate|InstallerReleaseFeed|UpdateDownloadCheck|UpdateChecker|TrayMenuModel|ScanTests'`;
- `./scripts/shared-check.sh`;
- `windows.yml` green; `windows-app` full green with the `in-app-update` and `failed-update-relaunch` lines;
- the milestone `./scripts/test-gate.sh`.

**Size:** L. **PC:** a real update on the PC at the second release of both systems (Task 12).

---

### Task 7: `team-release.sh`: one command for both systems **[most capable]** — Size M — opus — can start now, after Tasks 1–3

**Files:** Modify `scripts/team-release.sh`, `Tests/PokeTokenBarTests/TeamReleaseScriptTests.swift`.

**Interfaces:** Consumes Tasks 1–3. Produces the release flow of D3 and `--rehearse`. On `windows-port` this is inert: `main` keeps today's script until the merge.

**Steps:**
- [ ] **The order of D3**, with step numbers in the banner lines.
- [ ] **New pre-checks, all above the build:**
  - [ ] `command -v python3`;
  - [ ] `python3 -m unittest discover -s scripts/tests -p 'test_team_*.py'` (quiet unless it fails);
  - [ ] `python3 scripts/team_notes.py check --in "$NOTES_FILE"`;
  - [ ] `python3 scripts/team_docs_check.py` (exit 2 stops the release).
- [ ] **`start`** right after the pre-checks and before `./scripts/test-gate.sh`.
- [ ] **After the built-leaf check, zip and `lipo`:**
  - [ ] `collect` → read `INSTALLER` and `SHA256`;
  - [ ] `team_notes.py fill` → `build/release-notes.md`;
  - [ ] `publish --sha "$LOCAL_HEAD" --version "$VERSION" --zip "$ZIP" --installer "$INSTALLER" --notes build/release-notes.md`;
  - [ ] the tap (unchanged; it runs only after `publish` exits 0);
  - [ ] `smoke`.

  Exit codes 3–6 print what they mean and what to do.
- [ ] **`--rehearse <notes>`:**
  - [ ] allowed on any branch whose `HEAD` equals its `origin` branch;
  - [ ] runs the pre-checks, `start --ref <branch>`, `collect` and `fill`, and prints the `publish` command it would run;
  - [ ] prints SKIPPED for the test gate, the build, `publish`, the tap and `smoke`, then `exit 0`;
  - [ ] makes no gh write besides the workflow dispatch.
- [ ] Keep the `trap` for `CERT_DIR`. No `$@`, and no `@` anywhere in the file.
- [ ] **Rewrite `TeamReleaseScriptTests`:**
  - [ ] no `gh release create` line in the script;
  - [ ] exactly one `team_release.py publish` line, with `--sha "$LOCAL_HEAD"` and `--version "$VERSION"`;
  - [ ] `start` before `./scripts/test-gate.sh`;
  - [ ] `collect`, `fill` and `publish` after `lipo` and before the tap's `gh api -X PUT`;
  - [ ] `smoke` after the tap;
  - [ ] the new pre-checks before the build;
  - [ ] still no `git push`, `git tag` or `git commit`;
  - [ ] gh calls in the script are limited to `gh auth status`, `gh release view` (the existence check) and the tap's `gh api`;
  - [ ] the rehearse branch's `exit 0` comes before the `publish` line.
- [ ] **Rehearsal:** in a fresh clone of the fork at `windows-port` `HEAD` (in the scratchpad), `./scripts/team-release.sh --rehearse <notes>`. It should dispatch and collect the Windows runs for that `HEAD` and fill the notes. Record its wall time.
- [ ] **Fault injection:** in a scratch copy, move `publish` above `collect` → the order test fails. Revert.
- [ ] **PR `build(release): one release command for the Mac and Windows builds`**.

**Verify:** `swift test --filter TeamReleaseScript`; `python3 -m unittest discover -s scripts/tests`; the rehearsal log. **Size:** M. **PC:** no.

---

### Task 8: Windows captures for the docs, made on the runner — Size M — sonnet — can start partly now

**Files:**
- Create: `scripts/windows/docs-shots.ps1`, `scripts/import-windows-shots.sh`, `assets/windows/*.png`.
- Modify:
  - `.github/workflows/windows-app.yml` (a `docs-shots` step at light and full; artifact `windows-docs-shots`, 7 days);
  - `assets/windows/SHOTS.txt`.

**Steps:**
- [ ] **The shot list** (en, ko and ja where the text differs):
  - [ ] the tray menu with an update offer (`--dump-ui` with `--inject-ui-language`);
  - [ ] the plaza window with sample teammates (stage 6's window capture path);
  - [ ] the Setup welcome page, if a window capture of it is reliable;
  - [ ] once stage 7 Tasks 5–6 have merged: popover Home and Settings (stage 7's `--dump-ui` pages).
- [ ] **Each PNG** comes from the real app with fixture data, cropped to its window. Nothing is drawn on top: labels go in `SHOTS.txt` and the alt text, never into the pixels.
- [ ] **`import-windows-shots.sh <run-id>`:**
  - [ ] runs `gh run download <id> -n windows-docs-shots --repo likelion-campus/PokeTokenBar`;
  - [ ] copies the files into `assets/windows/`;
  - [ ] writes their `SHOTS.txt` lines (file, run id, command, "Sample-data capture, Windows CI runner");
  - [ ] refuses a file that is not on the shot list.
- [ ] Do a first import from a `windows-port` run (tray and plaza), and import again when the popover pages exist.
- [ ] **PR `docs(windows): runner-made captures for the team guide`**, with the captures as its images.

**Verify:** the `windows-app` light run has the artifact; `python3 scripts/team_docs_check.py` passes its `SHOTS.txt` part. **Size:** M. **PC:** no. **Can start now:** the tray and plaza shots; the popover shots wait for stage 7 Tasks 5–6.

---

### Task 9: Post-release smoke on a clean runner — Size S — sonnet — can start now

**Files:** Create `.github/workflows/windows-release-smoke.yml`, `scripts/windows/release-smoke.ps1`.

**Steps:**
- [ ] **Inputs:**
  - `version` (x.y.z);
  - `source`: `release` by default, or `artifact`;
  - `run_id`: the `windows-release` artifact of a release-mode run, used with `source=artifact`.

  `permissions: contents: read`. The workflow never writes a release.
- [ ] **`source=release`:**
  - [ ] check out tag `v<version>` for the scripts and fixtures;
  - [ ] read `releases/tags/v<version>`, then the installer asset's size and digest;
  - [ ] download it the way the app does, and check `Get-FileHash` and the size;
  - [ ] silent install, then the installed selftest (`run-selftest.ps1`).
- [ ] **The live in-app update:**
  - [ ] find the newest earlier release that has a Windows asset and a version at or above `FIRST_INAPP_VERSION` (an `env` constant, empty until Task 12 sets it);
  - [ ] on a fresh profile, install that release;
  - [ ] run it with `CI=true --selftest-update-live`;
  - [ ] assert: it lands on `<version>`, it relaunches, and `memberID` and a setting are kept.

  With no such release, print `SKIP update.live: no earlier release with the in-app updater`.
- [ ] **`source=artifact`:** the same install and selftest half, from Task 1's artifact. That is how the workflow is proven before any release of both systems exists.
- [ ] **Verify now:**
  - [ ] `source=artifact` with Task 1's run → green;
  - [ ] `source=release` with `version=2.5.634` → it fails with "no Windows installer in v2.5.634" (the expected negative path).
- [ ] **PR `ci(windows): check a published release on a clean runner`**.

**Verify:** the two runs above. **Size:** S. **PC:** no.

---

### Task 10: Docs for both systems — Size M — sonnet — waits (Tasks 6–8; stage 7 tiers 1–2)

**Files:**
- `TEAM.md` (the Windows section of D14);
- `README.md`, `README.ko.md`, `README.ja.md` (`### Windows (team fork)` after "Manual install", 3–5 lines each, linking `TEAM.md`);
- `docs/reference/team-release.md` (new, English, frontmatter `summary`/`read_when`);
- `CLAUDE.md`:
  - a row in the reference table;
  - in §릴리스, one line: "팀 포크의 릴리스는 `scripts/team-release.sh` 로 한다(맥 zip + 윈도우 설치 파일). 절차는 `docs/reference/team-release.md`";
  - the spec row's "(`windows-port` 브랜치)" stays until Task 13;
- `TeamReleaseScriptTests.testTeamGuideCreditsAssets` (add the Windows strings: `PokeTokenBar-Setup-`, the SmartScreen wording, `Get-FileHash`, "업데이트가 잘못됐을 때");
- `docs/reference/defect-log.md`:
  - extend the entry "원본 릴리스의 게이트를 포크 스크립트로 옮길 때 빠뜨리지 않는다" with "the Windows gate is part of the one release; no Mac-only release";
  - add "a build from a moving ref" as a release-class rule with its guard (Task 1);
- spec §10 step 8, §12 and §13 (as built);
- `CONTRIBUTING.md` (release mode and the team release pointer).

**Content of `team-release.md`:**
- when to read it;
- the one command;
- how the agent runs it: in the background, reading the log, about 50 minutes, and the early-start trick;
- what each exit code means;
- `--rehearse`;
- rollback (D11);
- the docs gates and refreshing the captures (Task 8);
- the post-release checks: the Mac `brew upgrade`; the smoke run; the PC checklist;
- the rule for coordinating with the peer session;
- "`release.sh` is upstream's: never run it on the fork".

**Steps:**
- [ ] Write the docs. Watch F4: no `@` and no `.local` in `TEAM.md`.
- [ ] `python3 scripts/team_docs_check.py` passes: Task 8's captures clear Task 3's backlog.
- [ ] `swift test --filter TeamReleaseScript`.
- [ ] **PR `docs: install, update and release on Mac and Windows`**. The images are the captures the docs use, labelled.

**Verify:** as above. **Size:** M. **PC:** no.

---

### Task 11: Merge rehearsal on the merged tree — Size M — sonnet — waits (Tasks 1–10, stage 6 and 7 as decided, the user's go)

**Files:** none in product code. A branch `merge/windows-port-into-main`, and a **draft** PR from it into `main` so that `ci.yml` runs. The draft is never merged by this task.

**Steps:**
- [ ] **The branch:** `origin/main` plus `git merge --no-ff origin/windows-port`. Resolve `VERSION` to `main`'s; record any other conflict and its resolution.
- [ ] **On the Mac, in the build slot:**
  - [ ] `./scripts/test-gate.sh` (full, about 18 min);
  - [ ] `./scripts/shared-check.sh`;
  - [ ] `./scripts/plaza-render-compare.sh` against `origin/windows-port` → `RENDER: identical`.

  The Mac plaza's differences from `main` (stage 6's shared panels) are the ones the user accepted (spec §6). List them in the PR body.
- [ ] **`ci.yml` on `macos-15`** (Xcode 16) through the draft PR. If the toolchain fails on the port's Swift 6.3 code: fix on `windows-port`, or pin the job to a newer Xcode on the image. Record the decision (risk K1).
- [ ] **Windows:** dispatch `windows.yml` and `windows-app.yml -f level=full` on the branch → green.
- [ ] **The release rehearsal:** in a fresh clone at the branch, `./scripts/team-release.sh --rehearse <notes>` → the release runs for the branch `HEAD` are collected and verified, and the notes are filled.
- [ ] **Draft the real merge PR body:**
  - the upstream-owned lines, gathered from the stage PRs (F17);
  - the CI changes on `main` (D15);
  - what the peer session must know (Task 12's message).

**Verify:** every run above green; the rehearsal log; the draft PR's `ci.yml` result. **Size:** M. **PC:** no.

---

### Task 12: The merge and the first release of both systems — lead — opus — waits (Task 11, the user's word)

**Steps:**
- [ ] Send the coordination message below to the peer session (through the user or the session channel), and wait for an acknowledgement or a quiet period.
- [ ] **The pending-release check:**
  - [ ] `VERSION` on `origin/main` has a published tag `v$VERSION`;
  - [ ] `gh pr list --repo likelion-campus/PokeTokenBar --state open --search 'bump the team version'` is empty.

  Otherwise, wait.
- [ ] **Bring in new commits:** if `main` moved, merge it into the branch again. Re-run the filtered suites, `windows.yml` and the full Mac gate if code changed.
- [ ] **The merge:** only with the user's word (memory "windows-port branch": the branch reaches `main` only when the user says so), mark the PR ready and merge it with a **merge commit**.
- [ ] **Watch `main`'s first push CI:** `ci.yml`, `windows.yml` and `windows-app` light.
- [ ] **The first release of both systems**, when the user asks for one:
  - [ ] the bump PR;
  - [ ] notes from the team template, shown to the user once;
  - [ ] `team-release.sh` in the background;
  - [ ] read the smoke run;
  - [ ] a small PR that sets `FIRST_INAPP_VERSION` in the smoke workflow and the "first in-app version" in the notes template.
- [ ] **PC check by the user** (the lead translates):
  1. Install from the release page: SmartScreen "More info → Run anyway" and no administrator prompt; the app starts; the tray, popover and plaza work.
  2. At the **next** release: the update arrives in-app, the app restarts on the new version, and settings and team are kept.
  3. On the office network: through the proxy, if there is one.
  4. Defender's behaviour on the first start after an update.

**Coordination message** (the lead translates):

> From <date/time>, `main` contains the Windows port (merge PR #N). What changes for you:
> (1) Every team release now also builds and checks the Windows app on GitHub. `team-release.sh` takes about 50 minutes instead of about 25. If Windows fails, it stops before publishing: the Mac build does not go out alone. Run it in the background and read its log; `docs/reference/team-release.md` has the steps.
> (2) Notes use `docs/reference/team-release-notes-template.md`. It has a Windows block, and the script fills in the installer's SHA-256.
> (3) A feature that changes what Windows (or the Mac) shows needs a new capture. Windows captures go in `assets/windows/`, made by CI (`scripts/import-windows-shots.sh`). Without one, the docs gate stops the release.
> (4) PRs into `main` now also run `windows.yml` (about 20 minutes) and, for Windows paths, `windows-app.yml`. Neither blocks a merge.
> (5) New plaza features go into shared code only (spec §10 step 3). A Mac popover change needs its Windows copy; the parity scan fails otherwise.
> Please do not merge a version bump until I confirm the merge is in. If you have a bump merged without its release, tell me and I will wait.

**Size:** M (mostly waiting). **PC:** yes (items above).

---

### Task 13: Retire `windows-port` — Size S — sonnet — waits (Task 12 and one good release of both systems)

**Files:**
- the workflows: drop `windows-port` from triggers, the level expression and the concurrency expressions; the push level on `main` stays light;
- `CLAUDE.md`: the spec row;
- the spec: §4 ("작업은 오래 가는 `windows-port` 브랜치에 쌓고") and §11 (the `windows-port` wording) become history;
- `CONTRIBUTING.md`: the levels note.

**Steps:**
- [ ] **PR into `main`, `ci: retire the windows-port branch`**.
- [ ] Two weeks later, the lead checks that no open PR targets the branch, then runs `git push origin --delete windows-port` and prunes the worktrees on it. The lead also updates the session memory note on `windows-port` (outside the repository).

**Size:** S. **PC:** no.

---

## Order

- **Wave A — now, side by side with stages 6 and 7:**
  - CI only, no Mac build slot: Tasks 1, 5, 9 and the tray/plaza part of 8.
  - Python only, no Mac build slot: Tasks 2 and 3.
  - Mac build slot (filtered suites): Task 4.

  So one Mac-slot task runs next to several CI-only or Python-only tasks.
- **Wave B:**
  - Task 6 after Task 4. Its e2e step needs Task 5 merged, and it ends with the milestone full Mac gate.
  - Task 7 after Tasks 1–3.
  - Task 9's live half after Task 6.
- **Wave C, after the stage 6 and 7 milestones:**
  - Task 10 after Tasks 6–8 and stage 7 Task 18 (tiers 1–2 recorded).
  - Task 8's popover shots after stage 7 Tasks 5–6.
- **Wave D, with the user's go:** Task 11, then Task 12, then (after one good release) Task 13.
- **Critical path:**
  - 4 → 6 → (milestone gate) → 10 → 11 → 12;
  - 1 → 2 → 7 → 11.
- **Collisions with stages 6 and 7:**

  | File | Stage 6 / 7 | Stage 8 | Rule |
  |---|---|---|---|
  | `windows-app.yml` | new selftest groups and idle windows (stage 7 T3, T10; stage 6) | T1, T5, T6, T8 | additive steps; T1's level and concurrency lines merge first and are announced |
  | `WinTrayHost.swift`, `WinTray.swift`, `TrayMenuModel.swift` | stage 7 T4 (left click opens the popover, menu items) | T6 (`.openRelease`, updating item) | T6 lands after stage 7 T4 or rebases on it; tell the stage 7 session |
  | `WindowsApp.swift` | stage 7 T4 wiring | T6 (`ExitReason`, `reportAtLaunch`, flags) | additive; time order |
  | `WindowsShell.swift` | stage 7 T6 (`mailto`) | T4, T6 | line-local |
  | `installer/PokeTokenBar.iss` | stage 7 tier 3 T23 (URL protocol) | T1, T5 | different sections |
  | `PlatformCompat.swift` | stage 7 T1, T14 (append-only) | T6 (append-only) | append-only |
  | `WindowsSelftestShell.swift` | — | T6 | — |
  | `CLAUDE.md`, `CONTRIBUTING.md`, spec | stage 7 T18 | T1, T10, T13 | separate paragraphs |

- **Estimate:** 13 tasks (2 L, 7 M, 4 S). About 20–25 Windows CI round trips: full runs take 44–49 min, light runs 23–33 min. Add the Mac-slot work of Tasks 4, 6 and 11, and the PC checks in Task 12. No calendar promise.

## Risks and unknowns (each with the cheapest early check)

- **K1. The port's Swift 6.3 code on `ci.yml`'s `macos-15` (Xcode 16).** It was never built there (F12). Check: Task 11's draft PR. It could be opened earlier as a never-merged draft, if the lead accepts that the peer session sees it.
- **K2. A flaky Windows step now blocks Mac releases** (spec §11: "그동안 맥 배포도 같이 멈춘다"). `tray.menuKeys` and the idle gate have flaked before (Track B ledger). Check: Task 1's three release runs on one SHA; every flake goes through the defect protocol before Task 12.
- **K3. gh's draft behaviour:** creating a draft with assets, finding a draft by tag in `view`/`edit`, no tag before publishing, the tag created at `--target`, and `--latest`. Check: gh's help and source in Task 2, with the assumptions written into the fakes. The first real publish (Task 12) is watched step by step.
- **K4. The real download path:** the cross-origin redirect to `release-assets.githubusercontent.com` (F5); which URL WinHTTPFetch reports after a redirect; office proxies (PAC, NTLM). Check: Task 6's seam step; Task 9's `source=release` run, which takes GitHub's real redirect on the runner; the PC check.
- **K5. SmartScreen and Defender on an in-app (unmarked) silent install of an unsigned file** are unverified on a real PC. The runner shows no SmartScreen. Check: the PC check at the second release of both systems.
- **K6. Inno's abort semantics** (rollback, `DeinitializeSetup` in silent mode). Check: Task 5's failed-update step.
- **K7. `releases/latest` ordering.** GitHub's documentation says it sorts by the release commit's date, not the publish time. Two sessions releasing close together could leave the older one "latest". Check: `--latest` on publish, and the post-publish `releases/latest` check (exit 6).
- **K8. The docs gate's first run fails** on the stage 6 and 7 backlog (expected). Check: Task 3 prints it; Tasks 8 and 10 clear it before Task 11.
- **K9. The GitHub API rate limit** (60 requests per hour per IP, unauthenticated) is shared by every team app behind one office IP. This exists already on the Mac. The installer download is not an API request. Check: the PC log counts of `update` lines at the office.

## Open questions for the user

1. **Code signing for the Windows installer.** None exists today. The plan works unsigned (D18).
   - (a) **Stay unsigned.** Document "More info → Run anyway" for the first install. In-app updates show no prompt (D10). Cost: none. **Recommended for now.**
   - (b) **Azure Trusted Signing.** Microsoft-managed keys, a monthly fee (the Basic tier was about US$10 a month at the planner's last knowledge; check before deciding). It needs an identity validation whose eligibility for a Korean organisation or individual must be checked. SmartScreen reputation still builds over time.
   - (c) **An OV certificate.** Roughly a few hundred US$ a year, with the key on a hardware token or cloud HSM; reputation builds slowly.
   - (d) **An EV certificate.** More expensive. Its former instant SmartScreen reputation is no longer guaranteed; check before buying.
   - (e) **winget, later.** It needs a public manifest submitted to Microsoft's repository, which is a third-party publication. Spec §12 puts it out of scope.

   Recommendation: (a) now. Revisit (b) if teammates struggle with SmartScreen, or if D9's "who published" gap matters.
2. **How heavy the Windows release gate is.** Full level (idle gate, upgrade and uninstall): about 50–55 minutes per release, or about 30 with the early start. **Recommended:** the idle gate is a spec failure condition, and after the merge nothing else runs it. The alternative is light level plus the two release steps: about 35–40 minutes per release, with the idle gate only on demand.
3. **The docs gate for Mac-only changes.** The fork's releases have had no screenshot gate so far (F1). With D14, a Mac plaza `feat` also needs a new image. **Recommended:** both systems, which is `CLAUDE.md`'s rule. The alternative is a Windows-only gate.
4. **A landing page.** The fork has none (F15). **Recommended:** none; `TEAM.md` plus the README pointer. The alternative is a team page on GitHub Pages: a new surface to keep in en, ko and ja every release.
5. **What "Update" does on Windows.** **Recommended:** download, check, install silently with a small progress window, and restart, like the Mac's Homebrew path. The alternative is to keep opening the release page and let the user run the installer.
6. **The emergency lever (D11).** If a Windows build is bad, remove only its installer from that release, so no further PC takes it. Windows is then one version behind the Mac until the fix. **Recommended:** allowed, with your OK each time. The alternative is never: fix forward only.
7. **When `windows-port` goes into `main`.** **Recommended:** after stage 7 tiers 1–2 and the PC check 7.3. The Windows popover then has usage, the companion and Settings, as you decided on 2026-11-14. Tier 3 (shop, bag, Pokédex, floating pet) continues on `main` and ships as it lands, listed in each release's "Windows differences". The alternative is after tier 3: Windows ships later, but complete.
