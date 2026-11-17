---
summary: "How windows.yml builds incrementally (the seed), when it must build from scratch, how the tests are sharded, who can produce a seed, and what the cache lab proved."
read_when:
  - the Windows unit-test CI is slow, or an incremental build looks wrong (stale result, odd compile errors)
  - changing windows.yml, scripts/windows/seed-*.ps1, restore-mtimes.ps1, test-shards.ps1 or swift-build-args.ps1
  - adding a Swift source file, a C++ file, a resource or a Package.swift setting and wondering what the CI rebuilds
---

# windows.yml: seed, clean builds, test shards

Job graph: `build` (debug `swift build --build-tests`, incremental from the seed; compile errors stop the run here) -> `test` x4
(shards by test class, `swift test --skip-build`) and `render` (plaza harness, no second build) in parallel -> `result`.

## The seed
`build` restores the `.build` folder of an earlier run and builds incrementally. A GitHub cache entry is only visible to its own
branch and `main`, never to `windows-port`, so the "seed" is an **artifact** (`ptb-seed-debug`, 3 days; the repository is public, no
artifact quota): the newest completed push/dispatch run of the same branch, else of `windows-port` (`seed_trunk` input, only to rehearse),
`scripts/windows/seed-restore.ps1`. Contents: `.build` plus `Package.resolved` as a zstd pax tar (357 MB) and `seed-meta.json` (when the
chain of incremental builds started, its length, commit, Swift version, runner image).

Two things make it trustworthy:
- `scripts/windows/restore-mtimes.ps1` stamps every tracked file's mtime from its git blob id (2000-01-01 + 28 bits). llbuild decides by
  recorded size/mtime/inode: an unchanged file looks unchanged on the next runner, a changed one differs, a file that changes back gets
  its old stamp back. A fresh checkout (all mtimes "now") would rebuild everything.
- `--only-use-versions-from-resolved-file` once `Package.resolved` came with the seed (about 30-60 s per swift command otherwise, and
  in a release build a re-resolve even recompiled the whole module).

`Package.resolved` is git-ignored on purpose and nothing pins swift-crypto (`from: "3.0.0"` in the Windows branch of Package.swift; the Mac
manifest on `main` declares no dependency at all). The file is used only inside the seed: the clean build resolves, the seed carries the result.

## When the build is clean (no seed)
- release mode (`release_sha`), branches `kit/*` (also a pull request from one), `clean_build=true`: the Seed step is skipped by an `if:` of the
  workflow itself (`clean` falls back to `true`). `windows-tests.json` carries `cleanBuild: true`; `team_release.py collect` refuses anything else.
- for EVERY consumer (windows-port, other branches, dispatches, pull requests): when the chain behind the seed has 8 incremental builds or
  its last clean build is 24 h old. The clean build that follows becomes the next seed. If windows-port's clean build fails, the over-limit
  seed is simply never used again (every consumer builds clean), it cannot linger.
- a seed built with another Swift version or runner image, a missing seed, and anything wrong with a seed: invalid metadata, an archive that
  breaks the rules below, a download over 5 minutes, a failed unpack (everything it wrote is removed), a seed commit that cannot be fetched.

## Who can produce a seed, and what it may contain (seed-rules.ps1, tested by seed-rules.yml: 46 checks)
- Only completed runs of THIS repository (`head_repository`) started by a `push` or a `workflow_dispatch`, of the same branch or the trunk.
  `branch=` in the runs API matches the head branch by NAME, also on a fork, so the repository and the event are checked as well: a pull
  request from a fork (even from a branch called `windows-port`) can never be a seed source, and no pull_request run is one. A pull_request
  run restores the seed of its BASE branch only and uploads its build under another name (`ptb-handoff-debug`, 1 day) for its own shards.
- The archive may hold `.build/` and `Package.resolved` only (checked with `tar -tf` before anything is extracted); no `..`, drive letters or
  streams, no device nodes or hard links, symbolic links only inside the workspace (the real seed has one: `.build/debug`).
- The metadata is not believed: chain length an integer below the limit, dates ordered and not in the future, a 40-hex commit, same Swift and
  image; `Package.resolved` is kept only while Package.swift is the blob the seed was built with (a PR that adds a dependency resolves normally).
- After the unpack, every file that differs between the seed's commit (fetched by id) and HEAD gets the mtime NOW (`stamp-changed.ps1`):
  llbuild needs the stable blob stamps, swift-driver judges C headers and clang modules by "newer than the last build" and a 2000-2008 stamp
  would say "unchanged". A header change costs a rebuild of the Swift files that import it (about 3.5 min); the lab proves a renamed
  header field fails in its Swift reader and a header the Swift side does not use builds.
- Residual risk: whoever can push a branch can leave a seed for that branch's own later runs and for runs that name it as a trunk (the
  `seed_trunk` dispatch input). Release mode, `kit/*` and `clean_build` never read one, so nothing shipped can contain one.

## What an incremental build does (measured, `cache-lab.yml`, 4 cores)
Unchanged tree 0 files compiled; a leaf or widely used Swift file 1 file (~20 s); a changed `mac-only.txt` changes what is compiled, listed and run (first build on a fresh runner: SwiftPM's package-manifest cache is outside `.build`, a fresh runner has none); an interface change recompiles its users (and breaks
the build where it must); a C++ file ~8 s; a `Package.swift` flag change or a source file added or deleted: the whole module, 3-4 min
(cold build 10 min); a deleted file's object is not linked. Re-run the lab after a Swift or runner-image upgrade (push a change under
`scripts/windows/cache-lab*` on a branch listed in cache-lab.yml, or dispatch it once it is on main).

## Test shards
`build` lists the tests (`swift test list`), `scripts/windows/test-shards.ps1` deals the classes to 4 shards by test count and splits a
shard into chunks of at most 20,000 characters of test names (SwiftPM puts the names on the xctest command line; Windows refuses ~32,000:
error 206). Every shard checks it executed exactly what its filters list, and `result` checks the shards add up to the listed total AND
the floor (`MIN_EXECUTED` in `scripts/team_release.py`, one source): a test dropped or run twice fails the run. Tests must not depend on
another class having run first: the shard step creates `plaza-preview`, `photo-out` and `canvas-out` up front because
`testFetchedSpritesDrawInTheScene` writes into the first without creating it.

## Toolchain install
`.github/actions/windows-swift` normally takes about 1.4 min (a slow download up to 8). Each calling step has `timeout-minutes: 8` and one retry (a hung download once
held a run for 31 min, and a slow swift.org download takes up to 8 min, seen three times; a `uses:` step has no limit of its own).
