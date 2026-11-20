# Contributing to PokeTokenBar

**English** · [한국어](CONTRIBUTING.ko.md) · [日本語](CONTRIBUTING.ja.md)

Thanks for your interest in contributing! PokeTokenBar is a small, non-commercial
fan project, and contributions of all sizes are welcome — bug reports, fixes,
new usage providers, translations, and documentation.

Please read the short sections below before opening a pull request.

## Prerequisites

- **macOS 14 (Sonoma) or newer**
- **Swift 6 toolchain** (Xcode 16 or newer) — required by `Package.swift`
  (`swift-tools-version: 6.0`)

## Build & test

The project is a Swift Package. From the repository root:

```bash
swift build             # compile the app target
./scripts/test-gate.sh   # run all tests and enforce logic-core coverage
```

CI runs these same commands on every pull request. The test gate runs
`swift test --enable-code-coverage` and requires at least 75% logic-core line
coverage by default. Run both commands locally before submitting a PR.
Use `swift test --filter <TestCase>` for focused checks during development.

## Contribution workflow

1. Create a feature branch off `main` (fork the repo if you don't have write
   access).
2. Make your change with tests. Keep the change focused.
3. Open a pull request against `main`.
4. Once CI passes and the change is reviewed, it is merged via **squash merge**.

### Language: English first

This repository uses **English as its first language** for collaboration
artifacts:

- **Pull request titles and bodies must be in English.**
- **Commit messages should be in English.**

Because the repository squash-merges, the PR title becomes the commit subject on
`main`, so English PRs keep the public history consistent.

### Commit & PR conventions

- Use [Conventional Commits](https://www.conventionalcommits.org/) style:
  `feat:`, `fix:`, `docs:`, `chore:`, `refactor:`, `test:`, etc.
- Use an English PR title such as `fix(home): retain idle usage history` and fill
  out every applicable section and checklist in the pull request template.
- **Every visible UI change** requires embedded images in `UI changes`, including
  changes caused outside `Sources/PokeTokenBar/UI/`. Actual screenshots, local
  renders of the production UI, and clearly labeled illustrations are accepted.
  Label sample-data renders explicitly. Existing screens need before/after
  images; a new screen needs its image and an explanation that no previous screen
  exists. Text alone is insufficient. If images are missing, coding agents
  generate and attach them as part of the authorized PR work. Try suitable
  generation and attachment alternatives; keep publication pending only if a
  concrete failure still prevents completion. Canonical `assets/` screenshots
  are regenerated at release, not per PR.
- Coding agents use the shared `prepare-pr` skill in `.agents/skills/prepare-pr/`;
  `.claude/skills/prepare-pr` points to the same skill for Claude Code. Before
  publishing, run its local check with the chosen base ref and PR body file:
  `python3 scripts/check-pr.py --base origin/main --title 'docs: clarify PR requirements' --body-file /tmp/pr-body.md`.
  Add `--ui-changes` when visible behavior changes outside the UI directory.

## Sources that also build on Windows

On the `windows-port` branch, `Sources/PokeTokenBar` also builds on Windows minus the paths in `Sources/PokeTokenBar/mac-only.txt` (tests: `Tests/PokeTokenBarTests/mac-only.txt`). To keep it working:

- A new file that imports an Apple-only framework (AppKit, SwiftUI, SpriteKit, CoreGraphics, Security, ...) goes in `mac-only.txt`, or keep that drawing in its own file so the rest stays shared.
- Calls to the OS from shared code go through `Platform` / `PlatformCompat` (under `Sources/PokeTokenBar/Platform/`), the only place for body-level `#if os(...)`.
- Tests in a `@MainActor` class that runs on Windows must be `async`; a synchronous one makes Windows run 0 tests.

Pre-check on the Mac: `./scripts/shared-check.sh` and `swift test --filter SharedSourcesScanTests`.

## Building the Windows app

The Windows app (`PokeTokenBar.exe`) is built and tested in CI (`windows.yml` for the library tests, `windows-app.yml` for the executable, installer and idle gate). There is no Windows developer machine in the loop, so push your branch and run `gh workflow run windows-app.yml --ref <branch> --repo likelion-campus/PokeTokenBar`. If you do build locally you need:

- **Windows 10 or newer, x64**, with **Swift 6.3.2** and a Visual Studio install that provides the C++ tools, the Windows SDK (`rc.exe`) and `dumpbin.exe`.
- **OpenSSL 3, linked statically,** from vcpkg: `vcpkg install --triplet x64-windows-static-md --x-manifest-root=windows`. Point `PTB_OPENSSL_DIR` at the triplet's folder (default `C:/vcpkg/installed/x64-windows-static-md`). No OpenSSL DLL ships.
- **Inno Setup 6** (`ISCC.exe`) for the installer.

The steps, from the repository root in PowerShell (CI runs exactly these):

```powershell
$res = ./scripts/windows/build-resources.ps1 -Out resources | Select-Object -Last 1   # version info, icon, manifest
swift build -c release --product PokeTokenBarWin -Xlinker ($res -replace '\\', '/')
./scripts/windows/package.ps1 -Out bundle                                             # exe + DLL closure + licences
./scripts/windows/run-selftest.ps1 -Exe bundle\PokeTokenBar.exe -Out st.json          # every selftest group must pass
ISCC /DSrcDir=bundle /DAppVer=2.5.634 /DOutDir=out installer\PokeTokenBar.iss        # out\PokeTokenBar-Setup-<version>-win-x64.exe
```

- **The version** comes from `VERSION="x.y.z"` in `scripts/build-app.sh`, the same number the Mac build uses. `package.ps1` stamps it into `PokeTokenBar.version` and the installer name; `build-resources.ps1` stamps it into the exe's version resource; `installer/PokeTokenBar.iss` stamps it into the setup exe's version info (`x.y.z.0`, product version `x.y.z`), and `windows-app.yml` checks every stamp. Do not add a second version number.
- **The executable name is frozen as `PokeTokenBar.exe`** (`WindowsInstall.shippedExecutableName`). The settings file is named after the process (`%LOCALAPPDATA%\PokeTokenBar.exe.plist`), so renaming the exe would orphan every user's settings. `package.ps1` fails on another name and the packaged selftest asserts it. The build target is still called `PokeTokenBarWin` and is renamed at packaging.
- **DLLs and licences:** `package.ps1` ships the dependency closure of the exe (read with `dumpbin /dependents`), not the whole toolchain, and fails when a DLL has no source or no line in `windows/licenses/map.txt`. Adding a dependency that brings a DLL means adding its licence text under `windows/licenses/` and a line in `map.txt`.
- **`assets/AppIcon.ico`** is generated from the existing `assets/AppIcon.icns` by `scripts/generate-ico.py` (Pillow); it does not draw anything.
- **Artifacts:** the `windows-installer` artifact (the setup `.exe`, kept 3 days) and the `windows-app` artifact (bundle, selftest and idle-gate JSON, logs, 7 days) of a run. Download with `gh run download <run-id> -n windows-installer --repo likelion-campus/PokeTokenBar`. Nothing is published to a release by CI, and the installer is unsigned, so Windows SmartScreen warns on first run.
- **Light and full runs:** `windows-app.yml` is `light` by default on work branches (build, bundle selftests, installer build, silent install and installed selftest, about 20 minutes) and always `full` on `windows-port` (adds the upgrade test, the idle gate and the uninstall check). Ask for a full run on a branch with `gh workflow run windows-app.yml --ref <branch> -f level=full --repo likelion-campus/PokeTokenBar`, and add `-f diagnostics=true` for the slow wake-up diagnostics. The job summary names the level that ran and what it skipped; a new push cancels a running work-branch run, but never a running `windows-port` one. On `main` (after the merge) every push runs `light`.
- **Release mode:** a release builds the Windows half from the exact release commit: `scripts/team_release.py` dispatches `gh workflow run windows-app.yml --ref main -f release_sha=<40 hex> -f release_version=<x.y.z> --repo likelion-campus/PokeTokenBar`, and the same for `windows.yml`. The run is named `release <version> <sha>` and is always `full`, with `diagnostics`, `fast`, `stall_hunt` and `net_burst` forced off. Its first step, "Release pin", fails unless the checkout is that commit, `VERSION` in `scripts/build-app.sh` is that version, and the workflow and `.github/actions/windows-swift` are the same at the commit and at the dispatched ref (otherwise: "main moved and changed the workflow; start the release again"). Release runs have their own concurrency group (`<workflow>-release-<sha>`) and are never cancelled by a push. Only a run where every step passed ends with the artifact `windows-release` (the installer and `windows-release.json`: commit, version, level, gate outcomes, the installer's size and SHA-256) or `windows-tests` (`windows-tests.json`: executed, skipped and failed test counts), kept 7 days. CI still never touches a release; the release Mac publishes. The procedure, exit codes, rehearsal, rollback and the docs gates are in [docs/reference/team-release.md](docs/reference/team-release.md); the fork releases with `scripts/team-release.sh` (never upstream's `scripts/release.sh`), and the maintained list of Windows-versus-Mac differences is [docs/reference/windows-differences.md](docs/reference/windows-differences.md). Every full run also upgrades from the newest earlier published Windows release (`scripts/windows/upgrade-from-release.ps1`), or prints `first` while there is none.
- **Idle cost is a failure condition:** the idle gate (`scripts/windows/measure-idle.ps1`) measures the installed app with cycles and context switches. A change that adds a timer or a polling wait has to say what wakes it and how often.
- **The idle gate's windows and budgets** (`scripts/windows/idle-gate.ps1`, five shards of about 15 minutes, each on its own runner; `idle-shards.ps1` maps every window to exactly one shard and throws for a label that is in none). Every window is the installed app with fixture data and `refreshInterval = 0`, measured for 120 s from 30 s after the launch; the unmeasured warm-up launch comes first. A window is judged on the main thread's context switches (`MaxMainCsPerMin`), the process's switches and cycles, and growth of private bytes and handles.

  | Window | Main-thread switches per minute (budget) | What it shows |
  |---|---|---|
  | closed app (`manual-refresh-120s`), `popover-closed-120s`, `plaza-closed-120s` | 6 (measured 2) | nothing runs when closed, also after a popover or plaza was opened and closed |
  | popover open on Home, Settings, Shop, Bag, Collection (grid, log, detail), activity bars/heatmap, recap, kit | 6 (measured 2-3; the open Home page 3: its relative-time clock fires about every 30 s) | an open page standing still adds no timer |
  | focused search field (`focus-search`, `focus-left`, `focus-closed`) | 6 (measured 2) | Windows' caret blinks for its caret timeout (5 s) after the last input only, so a focused field costs nothing in the measured window; moving the focus away or closing the popover leaves nothing running |
  | Home with the relative clock at 30 s / 1 min (`popover-home-seconds/minutes`) | 12 (measured 4-7) | the clock's one one-shot timer per change of a visible text |
  | animated sprite (`popover-sprite-open`, `popover-companion-animated`) | 800 (the GIF's 10 frames/s x 60 = 600, plus 1.2 switches per frame; measured 621-726 in 5 windows over 3 runs: the first budget of (frames/s + 2) x 60 = 720 failed at 726) | one wake per frame, nothing else |
  | `popover-companion-wiggle` | 2400 (measured 810) | the bob and the wiggle's steps |
  | plaza visible / minimized / covered | 26000 / 615 / 615 (measured 22856 per 120 s / 825 / 935) | WARP draws on the runner's CPU; a minimized or covered plaza parks its frame clock |

  Also asserted: GDI and USER objects, kit controls and windows of ours at the end equal what they were when the page was reached (an open page: slack 2 GDI/USER, 0 others); the closed popover opens and closes twice and holds at exit what it held after the first close (the first open builds fonts, the Direct2D device and window classes once: +18 GDI and +8 USER over a never-opened popover were measured; a leak shows in every cycle); a page other than the Collection's log fires no `PopoverClock` or `PopoverAnimationClock`. The gate counts where the main thread's wakes come from when `PTB_WAKE_TRACE=1` (`WakeTrace`: messages removed by the pump by id, timer ids, and the app's own sources: clock fires, page applies, layouts) and prints `WAKES <window>: ...` per window and the same in `idle-gate-<n>.json`; read it before proposing a budget change.

## Code conventions

The app is provider-agnostic by design. When extending it, follow these rules
(they are also enforced by tests):

- **Adding a usage source** (a new AI CLI) = implement the `UsageProvider`
  protocol (`Sources/PokeTokenBar/Core/UsageProvider.swift`) in one new type and
  register it in the default `providers:` array of `UsageStore.init`
  (`Sources/PokeTokenBar/Core/UsageStore.swift`). These are the core entry points,
  not a two-file limit. Depending on the source, also add or update its reader,
  shared cache integration, custom scan roots, and tests. Follow the
  [provider extension guide](docs/reference/provider-extension.md) and the
  [provider contribution checklist](https://github.com/chattymin/PokeTokenBar/issues/115).
- **Generic behavior must aggregate across all providers** (today/week/month
  totals, burn tier, companion rhythm). Do not attach a generic calculation to a
  single provider, and do not add `providerID == "..."` literal branches on
  generic paths. Provider-specific behavior (e.g. official limits) is the only
  thing that may branch on `providerID`.
- **Adding a version manager / install path** = add it to
  `BinaryLocator.commonToolDirectories()` — the single source that discovery and
  child-process `PATH` both share.
- **Adding an append-only SQLite usage store** (rowid/`id` high-water, like Cursor
  or Copilot) = call `LocalAdditionalUsageReader.scanIncrementalStores` with the
  format-specific URL / `MAX` SQL / row query / parse. Do not copy the watermark
  loop.

## Legal / intellectual property

PokeTokenBar is an **unofficial, non-commercial fan project** and is not
affiliated with Nintendo, Game Freak, Creatures Inc., or The Pokémon Company
(see the disclaimer in the [README](README.md#license--disclaimer)). To keep the
project safe to maintain and distribute, contributions **must** follow these
rules:

- **Do not commit or bundle any Pokémon (or other third-party) copyrighted
  assets** — sprites, artwork, audio, fonts, or bulk name/data files. Pokémon
  species data and sprites are fetched **at runtime** from the public
  [PokéAPI](https://pokeapi.co) and cached locally on the user's device; keep it
  that way. This team fork has one exception: non-Pokémon assets under an open
  license may be bundled when `CREDITS.md` and the license text ship with them,
  as the plaza tileset (CC0) and Galmuri font (SIL OFL 1.1) do.
- **Do not add features intended for commercial use**, or features that
  redistribute or export copyrighted assets.
- **Do not commit secrets, credentials, or references to private/internal
  tooling.** Keep everything in the repository generic and public-safe.
- By submitting a contribution, you confirm it is your **own original work** and
  agree that it is licensed under this project's [MIT License](LICENSE). The MIT
  license covers this project's source code only — it does not grant any rights
  to third-party trademarks, artwork, or data.

## Reporting bugs & requesting features

Please use the issue templates. For bugs, include your macOS version, the app
version, which AI CLI(s) you use, and steps to reproduce.

If you are a rights holder with a concern about this project, please open an
issue or contact the maintainer, and we will respond promptly.
