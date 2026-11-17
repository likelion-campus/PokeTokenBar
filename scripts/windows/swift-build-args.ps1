# Prints the extra `swift build` / `swift test` arguments of a build that may have restored a seed (one argument per line):
#  --disable-build-manifest-caching   the build plan is regenerated each time. Package.swift reads the mac-only.txt lists while it is
#      evaluated; a plan cached by an earlier build would not notice a changed list (a fresh runner always re-plans, which nobody should
#      have to rely on). cache-lab scenario "mac-only.txt".
#  --only-use-versions-from-resolved-file   once Package.resolved exists (it came with the seed, and seed-restore.ps1 keeps it only while
#      Package.swift is the file the seed was built with) the dependency versions are taken from it and not re-resolved over the network.
#      Without it a restored release build re-resolved swift-crypto and recompiled the whole PokeTokenBar module with no source change
#      (cache lab, release "no change": 625 s; with the flag 0 files, 70 s). A clean build has no Package.resolved yet and resolves normally.
'--disable-build-manifest-caching'
if (Test-Path Package.resolved) { '--only-use-versions-from-resolved-file' }
