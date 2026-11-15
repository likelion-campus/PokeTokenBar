#!/usr/bin/env bash
# Cross-OS plaza render compare, Mac side (windows-port stage 6 Task 15). Offscreen (SKRenderer into a Metal texture), never opens
# a window, one swift build/test at a time on this Mac.
#
#   scripts/plaza-render-cross.sh --write [--scratch <dir>]
#       Regenerate the committed Mac reference: renders the cross set twice (the test fails if the two renders differ), writes
#       Tests/PlazaCrossReference/mac-reference.tar.gz (block-deduplicated frames + node trees, ~1-2 MB). Run it when a scene, the
#       art or the scene code changes what the plaza draws; the Windows `render` job and the Mac test
#       PlazaCrossRenderCompareMacTests/testCommittedReferenceTreesAreCurrent fail until it is current.
#   scripts/plaza-render-cross.sh --check [--scratch <dir>]
#       Render the cross set and require it to equal the committed reference pixel for pixel (this Mac only: GPU output may
#       differ across Macs).
#   scripts/plaza-render-cross.sh --run <windows run id> [--scratch <dir>]
#       Download the run's `plaza-render-win` artifact, render the Mac set at the run's commit in <scratch>/ptb-render-base (a reused
#       worktree), compare, print `CROSS: ok (<n> captures, <m> allowed differences)` or `CROSS: <k> fail: <scene@frame> <reason>...`.
#       The report and the side-by-side images are in <scratch>/cross-report.
#
# Exit 0 only when the mode succeeded; 1 on a difference; 2 on usage/setup errors.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE=""; RUN_ID=""; SCRATCH="${PTB_PLAZA_RENDER_SCRATCH:-}"
GH_REPO="likelion-campus/PokeTokenBar"
while [ $# -gt 0 ]; do
  case "$1" in
    --write) MODE=write; shift ;;
    --check) MODE=check; shift ;;
    --run) MODE=run; RUN_ID="$2"; shift 2 ;;
    --scratch) SCRATCH="$2"; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$MODE" ] || { sed -n '2,22p' "$0" >&2; exit 2; }
[ -n "$SCRATCH" ] || { echo "need --scratch <dir> (or PTB_PLAZA_RENDER_SCRATCH): renders never go into the repo" >&2; exit 2; }
mkdir -p "$SCRATCH"; SCRATCH="$(cd "$SCRATCH" && pwd -P)"
case "$SCRATCH" in "$REPO"|"$REPO"/*) echo "scratch must be outside the repo" >&2; exit 2 ;; esac
ARCHIVE="$REPO/Tests/PlazaCrossReference/mac-reference.tar.gz"

wait_idle() {
  local waited=0
  while pgrep -x swift-build >/dev/null || pgrep -x swift-test >/dev/null || pgrep -x xctest >/dev/null; do
    [ $waited -eq 0 ] && echo "waiting for another swift build/test to finish..."
    sleep 10; waited=$((waited + 10))
    [ $waited -gt 3600 ] && { echo "gave up waiting for an idle machine" >&2; exit 2; }
  done
}
build() { # <dir>
  wait_idle
  ( cd "$1" && swift build --build-tests 2>&1 | tail -3; exit "${PIPESTATUS[0]}" ) || { echo "build failed in $1" >&2; exit 2; }
}
run_test() { # <dir> <filter> [VAR=value ...]
  local dir="$1" filter="$2"; shift 2
  wait_idle
  ( cd "$dir" && env "$@" swift test --skip-build --filter "$filter" 2>&1 )
}
extract() { # <dest>
  rm -rf "$1"; mkdir -p "$1"
  tar -xzf "$ARCHIVE" -C "$1" || { echo "cannot extract $ARCHIVE" >&2; exit 2; }
}

case "$MODE" in
write)
  OUT="$SCRATCH/cross-write"; rm -rf "$OUT"
  build "$REPO"
  LOG="$SCRATCH/cross-write.log"
  run_test "$REPO" "PlazaCrossRenderCompareMacTests/testWriteCrossReference" PTB_PLAZA_CROSS_OUT="$OUT" > "$LOG"
  grep -E "error:|CROSS-MAC|Executed .* test" "$LOG" | tail -4
  [ -f "$OUT/manifest.tsv" ] || { echo "no reference written (see $LOG)" >&2; exit 2; }
  grep -q "with 0 failures" "$LOG" || { echo "the render was not deterministic or failed (see $LOG)" >&2; exit 1; }
  # Deterministic archive: sorted names, fixed mtimes, no gzip timestamp.
  find "$OUT" -type f -exec touch -t 202001010000 {} +
  mkdir -p "$(dirname "$ARCHIVE")"
  ( cd "$OUT" && COPYFILE_DISABLE=1 tar -cf - $(ls | LC_ALL=C sort) ) | gzip -9 -n > "$ARCHIVE"
  echo "wrote $ARCHIVE ($(wc -c < "$ARCHIVE") bytes, $(wc -l < "$OUT/manifest.tsv" | tr -d ' ') captures)"
  ;;
check)
  extract "$SCRATCH/cross-ref"
  build "$REPO"
  LOG="$SCRATCH/cross-check.log"
  run_test "$REPO" "PlazaCrossRenderCompareMacTests/testCrossReferenceIsFresh" PTB_PLAZA_CROSS_CHECK="$SCRATCH/cross-ref" > "$LOG"
  grep -E "CROSS-MAC" "$LOG" | head -3
  grep -q "CROSS-MAC: reference is current" "$LOG" || { echo "CROSS-MAC: not current (see $LOG)"; exit 1; }
  ;;
run)
  command -v gh >/dev/null || { echo "need gh" >&2; exit 2; }
  SHA="$(gh run view "$RUN_ID" --repo "$GH_REPO" --json headSha --jq .headSha)" || { echo "cannot read run $RUN_ID" >&2; exit 2; }
  WIN="$SCRATCH/win-$RUN_ID"; rm -rf "$WIN"; mkdir -p "$WIN"
  gh run download "$RUN_ID" --repo "$GH_REPO" -n plaza-render-win -D "$WIN" || { echo "run $RUN_ID has no plaza-render-win artifact" >&2; exit 2; }
  [ -f "$WIN/win-reference/manifest.tsv" ] || { echo "artifact has no win-reference/manifest.tsv" >&2; exit 2; }
  cd "$REPO"; git fetch -q origin "$SHA" 2>/dev/null || git fetch -q origin
  BASE_TREE="$SCRATCH/ptb-render-base"
  if [ -e "$BASE_TREE/.git" ]; then git -C "$BASE_TREE" checkout -q -f --detach "$SHA" || { echo "cannot check out $SHA" >&2; exit 2; }
  else git worktree add -q --detach "$BASE_TREE" "$SHA" || { echo "cannot create the worktree at $SHA" >&2; exit 2; }; fi
  echo "windows run $RUN_ID at $SHA"
  build "$BASE_TREE"
  REPORT="$SCRATCH/cross-report-$RUN_ID"; rm -rf "$REPORT"; mkdir -p "$REPORT"
  LOG="$REPORT/mac-compare.log"
  run_test "$BASE_TREE" "PlazaCrossRenderCompareMacTests/testCompareWithAWindowsRun" PTB_PLAZA_CROSS_WIN="$WIN/win-reference" PTB_PLAZA_CROSS_REPORT="$REPORT" > "$LOG"
  grep -E "^CROSS:" "$LOG" | head -3
  grep -qE "^CROSS: ok" "$LOG" || { echo "(details: $REPORT/cross-report/report.md and $LOG)"; exit 1; }
  ;;
esac
