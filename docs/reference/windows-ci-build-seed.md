---
summary: "How the Windows workflows build incrementally (the seed), when they must build from scratch, how the tests are sharded, and what the cache lab proved."
read_when:
  - the Windows CI build is slow, or an incremental build looks wrong (stale result, odd compile errors)
  - changing windows.yml, windows-app.yml, scripts/windows/seed-*.ps1, restore-mtimes.ps1 or test-shards.ps1
  - adding a Swift source file, a C++ file, a resource or a Package.swift setting and wondering what the CI rebuilds
---

# Windows CI: seed, clean builds, test shards

## The seed
`windows.yml` (debug, `swift build --build-tests`) and `windows-app.yml` (release app product) restore the `.build` folder of an earlier
run and build incrementally. A GitHub cache entry is only visible to its own branch and `main`, never to `windows-port`, so the
"seed" is an **artifact** (`ptb-seed-debug`, `ptb-seed-release`, 3 days) of the newest completed run of the same branch, else of
`windows-port` (`scripts/windows/seed-restore.ps1`). It is the `.build` folder plus `Package.resolved` as a zstd tar (357 MB debug, 150 MB
release) and a `seed-meta.json` (when the chain of incremental builds started, its length, commit, Swift version, runner image).

Two things make it trustworthy:
- `scripts/windows/restore-mtimes.ps1` stamps every tracked file's mtime from its git blob id (2000-01-01 + 28 bits). llbuild decides by
  recorded size/mtime/inode: an unchanged file looks unchanged on the next runner, a changed one differs, a file that changes back gets
  its old stamp back. A fresh checkout (all mtimes "now") would rebuild everything.
- `--only-use-versions-from-resolved-file` (`scripts/windows/swift-build-args.ps1`) once `Package.resolved` came with the seed. Without it
  a restored release build re-resolved swift-crypto and recompiled the whole PokeTokenBar module with no source change.

## When the build is clean (no seed)
- release mode (`release_sha`), branches `kit/*` and `clean_build=true`: always. The release manifests carry `cleanBuild: true`
  (`windows-release.json`, `windows-tests.json`); `team_release.py collect` refuses anything else.
- `windows-port`: when the chain behind the seed has 8 incremental builds or its last clean build is 24 h old, and the clean result becomes
  the next seed. A cache-masked breakage cannot live longer than that.
- a seed built with another Swift version or runner image, a missing seed, a damaged seed: automatically.
A release build also removes the exe before linking: the `.res` passed as `-Xlinker` is not tracked by llbuild.

## What an incremental build does (measured, `cache-lab.yml`, 4 cores)
Debug: unchanged tree 0 files compiled; a leaf or widely used Swift file 1 file (~20 s); an interface change recompiles the users (and breaks
the build where it must); a C++ file ~8 s; `Package.swift` flag change, or a source file added or deleted: the whole module, ~3.5-4 min
(cold build 10 min); a deleted file's object is not linked. Release is whole-module: any Swift source change recompiles PokeTokenBar
(~9.5 min, cold 18 min); unchanged sources ~1 min. Re-run the lab (push a change to `scripts/windows/cache-lab*` on branch
`ci/windows-build-cache`, or copy the three files) after a Swift or runner-image upgrade.

## Test shards (`windows.yml`)
`build` lists the tests (`swift test list`), `scripts/windows/test-shards.ps1` deals the classes to 4 shards by test count and splits a shard
into chunks of at most 20,000 characters of test names (SwiftPM puts the names on the xctest command line; Windows refuses ~32,000).
Every shard checks it executed exactly what its filters list, and `result` checks the shards add up to the listed total (a test
dropped or run twice fails the run). Tests must not depend on another class having run first: the shard step creates `plaza-preview`,
`photo-out` and `canvas-out` up front because `testFetchedSpritesDrawInTheScene` writes into the first without creating it.
