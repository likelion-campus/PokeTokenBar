# Prints the extra `swift build` / `swift test` arguments of a build that may have restored a seed (one argument per line):
# (Not --disable-build-manifest-caching: it costs 25-50 s per swift command and does not help. The cache that could hide a changed
# mac-only.txt is SwiftPM's PACKAGE manifest cache, which lives in the user cache folder, not in .build: a fresh runner has none and the
# seed does not carry it. cache-lab scenario "mac-only.txt" runs first, on a fresh runner, to prove that.)
#  --only-use-versions-from-resolved-file   once Package.resolved exists (it came with the seed, and seed-restore.ps1 keeps it only while
#      Package.swift is the file the seed was built with) the dependency versions are taken from it and not re-resolved over the network.
#      Without it a restored release build re-resolved swift-crypto and recompiled the whole PokeTokenBar module with no source change
#      (cache lab, release "no change": 625 s; with the flag 0 files, 70 s). A clean build has no Package.resolved yet and resolves normally.
if (Test-Path Package.resolved) { '--only-use-versions-from-resolved-file' }
