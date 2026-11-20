#!/usr/bin/env bash
#
# shared-check.sh — Mac-side pre-check for the Windows build.
# Builds only the shared set (everything not in Sources/PokeTokenBar/mac-only.txt) as a library, the way the
# Windows manifest branch sees it. Uses its own build path so the normal .build is untouched.
#
set -euo pipefail
cd "$(dirname "$0")/.."
# SwiftPM keeps the previous source list in debug.yaml and the manifest cache ignores mac-only.txt edits.
rm -f .build-shared/debug.yaml
PTB_SHARED_ONLY=1 swift build --build-tests --build-path .build-shared --manifest-cache none
