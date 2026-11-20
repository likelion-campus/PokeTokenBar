---
summary: "How the team fork releases the Mac zip and the Windows installer as one release: the one command, exit codes, rehearsal, rollback, the docs gates and the post-release checks."
read_when:
  - you release a version of the team fork (the natural-language triggers in CLAUDE.md, "배포해줘")
  - team-release.sh stopped and you must decide what to do next
  - the docs gate (team_docs_check.py) blocks a release, or the Windows captures need refreshing
  - you coordinate a release with another session working on main
---

# Releasing the team fork (Mac and Windows together)

The fork (`likelion-campus/PokeTokenBar`) releases with **`scripts/team-release.sh`**. One release carries both builds: the
Mac `PokeTokenBar.zip` and the Windows `PokeTokenBar-Setup-<version>-win-x64.exe`, with the same version. There is no
Mac-only release: if the Windows half fails, nothing is published.

**`scripts/release.sh` is upstream's** (it publishes to the chattymin repository and pushes `main`). **Never run it on the
fork.** `CLAUDE.md`'s release rules (version words, notes format, docs and screenshots every release) still apply; this file
is the how.

## The one command

```sh
./scripts/team-release.sh <notes-file>            # a release, from main
./scripts/team-release.sh --rehearse <notes-file> # everything except building and publishing
```

Run it from a clean `main` at `origin/main`, after the version-bump PR is merged. It pushes nothing and tags nothing itself.
The notes follow `docs/reference/team-release-notes-template.md` (English; the Windows SHA-256 is the one value filled in
during the run).

**How the agent runs it:** in the background, reading its log. A release takes about **50 minutes** (the full Windows run is
the long part; the Mac gate runs meanwhile). Start the Windows runs early to save time: right after the bump PR merges, run
`python3 scripts/team_release.py start --sha <main HEAD> --version <x.y.z>`; `team-release.sh` reuses those runs. Never
end a turn waiting for it: poll the log in chunks. Stop a background release through its process group (a signal to the
script's PID alone waits for the running step).

Steps (banner `[N/10]` with elapsed time): 0 arguments, branch, clean tree, HEAD, no existing tag or release, signing leaf;
1 helper self-tests, notes check, **docs gate**; 2 start the Windows runs; 3 Mac test gate and cfprefsd guard; 4 Mac build,
zip, universal check; 5 collect and verify the Windows installer (manifest, hash); 6 fill the notes; 7-8 publish (draft,
checks, public, checks); 9 Homebrew team tap; 10 start the post-release smoke run.

## Exit codes and what to do

| Exit | Meaning | Next |
|---|---|---|
| 0 | released; the smoke run was started | read the smoke run |
| 1 | stopped; the last `남은 것:` line says what is left (nothing, Windows runs, /Applications, a draft, public) and what to run next | follow that line |
| 3 | `--rehearse` only: it ran to the end but a real release would have stopped (today: the docs gate); the reasons are on the last line | fix the reason, rehearse again |
| 130 / 143 / 129 | INT / TERM / HUP; same `남은 것:` line | as printed |

Per step: a docs-gate stop (step 1, exit 2 of the checker) ends a real release before anything is built. A failed Windows run
stops at step 2 or 5 and leaves only CI runs behind: read the run, fix and merge, or for a known flake
`team_release.py start ... --new failed` (or `--new windows-app.yml` / `--new windows.yml` when a green run cannot be used:
expired artifact, re-run attempt, manifest mismatch), then run again. Publish exit 5: not published, tap untouched (delete a
leftover draft it names, run again). Publish exit 6: public or maybe public, **do not run again**; check by hand, set the
tap only if the zip's digest matches, run smoke. Publish exit 7: someone else's public version; nothing was created, never
set the tap from this run's zip. Step 9 failing means the release is public and verified: set `version` and `sha256` in the
tap by hand (the values are printed), then run `team_release.py smoke --version <x.y.z>`.

## `--rehearse`

Allowed on any branch whose `HEAD` equals `origin/<branch>`. It runs steps 0-2, 5 and 6 (the only GitHub write is the
Windows runs' dispatch, which is CI), prints `SKIPPED` for the Mac gate, build, publish, tap and smoke, and prints the exact
publish command as a comment (never run it by hand). Use it on a merge candidate and before the first release of a new
setup.

## Rollback

- **Normal case: fix forward** with the next patch release; both systems install it in-app (including a Windows PC whose new
  build installed but misbehaves).
- **A Windows build that cannot start** (so it cannot update itself): the user runs the previous release's installer from the
  releases page (Inno allows an older version over the same app). Settings and state live outside the app folder and stay.
- **Stopping the spread while a fix is built** (only with the user's approval each time): delete only the Windows asset of
  the bad release (`gh release delete-asset`). The update feed then answers "no installer" and no further PC takes it; Macs are
  unaffected. Windows is then one version behind until the fix, a recorded exception to "the same timeline".
- The scripts never delete a published release and never move a tag.

## Docs gates and refreshing the Windows captures

`python3 scripts/team_docs_check.py [--since TAG]` (run by step 1; exit 0 pass, 2 hard stop, 1 usage) looks at changes since
the last `v*` tag:

- **Hard stop:** a `feat` commit touched a group's paths and no capture was *added* for that group. Mac group: UI, Team/UI,
  Platform/Mac; assets outside `assets/windows/`. Windows group: the popover, plaza, tray, `CPlazaD2D`, `installer/`; assets in
  `assets/windows/`. `Team/Plaza/` and `Popover/` (shared) count for both. Make the capture; "another commit type" only helps
  for future commits.
- **Warning:** a group's paths changed but none of its assets did.
- **`assets/windows/SHOTS.txt`:** every listed file exists, every PNG is listed, every label says "Windows CI runner".

Windows captures come from the real app with fixture data, made by the CI runner (`--selftest --dump-ui`); nothing is drawn
on top of the pixels and no real user's data is used. To refresh them: take the newest successful `windows-app` run for
the release commit (the full run the release already needs works) and run
`scripts/import-windows-shots.sh <run-id>`. It downloads the artifacts into a temporary directory, copies exactly the files
of `assets/windows/SHOT-LIST.txt`, rewrites their `SHOTS.txt` lines (file, run, command, label) and refuses anything not on
the list. Add a line to `SHOT-LIST.txt` for a new capture. A Mac capture for the Mac group is made offscreen (the plaza
render harness, e.g. `PTB_PLAZA_HUD_OUT=<dir> swift test --filter PlazaHUDControlRenderTests/testWriteControlImages`; no
window on the window server), labelled sample data. Refresh `TEAM.md`'s images and `docs/reference/windows-differences.md`
in the same change.

## After the release

1. **Mac:** on a Mac with the previous version from the team tap, `brew upgrade --cask likelion-campus/tap/poke-token-bar-team`
   (or the in-app update button) lands on the new version and the app starts.
2. **Smoke:** `windows-release-smoke.yml` (started by step 10) downloads the published installer the way the app does, checks
   its size and SHA-256 against what GitHub reports for the asset, installs it silently, checks the installed version, runs
   the installed app's own selftest from the install folder with a stripped Path, uninstalls and confirms the folder is gone;
   read its result (it never writes a release).
3. **PC checklist** (the user, on a real Windows PC): install from the release page (SmartScreen "More info" then "Run
   anyway", no administrator prompt; tray, popover and plaza work); at the **next** release the update arrives in-app, the app
   restarts on the new version and settings and team are kept; behaviour behind the office network's proxy; Defender on the
   first start after an update.
4. The first release that installs updates in-app is **v2.5.635** (2026-11-20); the notes template's Windows Upgrade line
   and `TEAM.md`'s update section name it.

## Coordinating with another session on `main`

Another session may release from `main` too. Before merging into `main` or starting a release: check that `VERSION` on
`origin/main` is a published tag `v<version>` and that no bump PR is open (`gh pr list --repo likelion-campus/PokeTokenBar
--state open --search 'bump the team version'`); otherwise wait. Tell the other session when `main` gains something that
changes its release (for example a release that now takes about 50 minutes and builds Windows too). `team-release.sh` pins
its own commit, but a fresh clone made after a merge would release the merged tree. Never run a release while another is
unfinished.
