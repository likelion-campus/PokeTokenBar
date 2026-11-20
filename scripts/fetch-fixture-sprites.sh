#!/usr/bin/env bash
# Fetch the FIXTURE sprites listed in scripts/fixture-sprites.txt into $1 (the companion header's Mac renders read them
# through PTB_FIXTURE_SPRITES). Public PokeAPI sprite files only; nothing is sent but the GET.
set -euo pipefail
out="${1:?usage: fetch-fixture-sprites.sh <dir>}"
mkdir -p "$out"
here="$(cd "$(dirname "$0")" && pwd)"
grep -v '^#' "$here/fixture-sprites.txt" | while read -r file url; do
  [ -n "$file" ] || continue
  [ -s "$out/$file" ] && continue
  curl -fsSL --retry 3 -o "$out/$file" "$url" || echo "missing: $file ($url)"
done
ls "$out" | wc -l
