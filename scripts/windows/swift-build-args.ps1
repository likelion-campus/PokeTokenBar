# Prints the extra `swift build` / `swift test` arguments of a build that may have restored a seed (one argument per line):
#  --only-use-versions-from-resolved-file   once Package.resolved exists (it came with the seed) the dependency versions are taken from
#      it and not re-resolved over the network. Without it a restored release build re-resolved swift-crypto and recompiled the whole
#      PokeTokenBar module although no source had changed (cache lab, release "no change": 625 s; with the flag 0 files, 70 s).
#      A clean build has no Package.resolved yet and resolves normally; its seed carries the file to the next build.
if (Test-Path Package.resolved) { '--only-use-versions-from-resolved-file' }
