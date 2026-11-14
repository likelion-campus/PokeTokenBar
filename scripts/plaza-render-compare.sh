#!/usr/bin/env bash
# Offscreen plaza render compare (windows-port Track A). Proves "the Mac plaza looks identical" between a base commit
# and the working tree, and that frame cost did not move.
#
#   scripts/plaza-render-compare.sh [--base <ref>] [--scratch <dir>] [--release] [--runs N]
#
# 1. waits until no other swift build/test is running (one at a time on this Mac)
# 2. checks the base out DETACHED in <scratch>/ptb-render-base (reused, so its builds are incremental), builds its tests
#    and runs the BASE'S OWN harness into <scratch>/plaza-renders/base
# 3. builds the working tree and runs its harness into <scratch>/plaza-renders/head
# 4. PlazaRenderCompareTests compares the two directories
# 5. runs the frame-cost harness alternately base/head N times each (default 9)
# Prints `RENDER: identical (<n> captures ...)` or `RENDER: <k> differ: <scene@frame> ...`, then
# `FRAMECOST: update base <x> head <y> ratio <r> (limit <L>)` and `FRAMECOST: render ...`.
# Exit 0 only when renders are identical and both ratios <= L; 1 on a difference or cost; 2 on usage/setup errors.
# Only same-machine comparisons are valid (GPU output may differ across Macs). Never opens a window.
set -uo pipefail

# Frame-cost limit L = max(1.05, 1 + 2 x the A/A spread measured in Task 1).
LIMIT=1.05

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_REF=""
SCRATCH=""
RELEASE=0
RUNS=9
while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE_REF="$2"; shift 2 ;;
    --scratch) SCRATCH="$2"; shift 2 ;;
    --release) RELEASE=1; shift ;;
    --runs) RUNS="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$SCRATCH" ] || SCRATCH="${PTB_PLAZA_RENDER_SCRATCH:-}"
if [ -z "$SCRATCH" ]; then echo "need --scratch <dir> (or PTB_PLAZA_RENDER_SCRATCH): renders never go into the repo" >&2; exit 2; fi
case "$(cd "$SCRATCH" 2>/dev/null && pwd -P || echo "$SCRATCH")" in
  "$REPO"|"$REPO"/*) echo "scratch must be outside the repo" >&2; exit 2 ;;
esac
mkdir -p "$SCRATCH"
SCRATCH="$(cd "$SCRATCH" && pwd -P)"

cd "$REPO"
if [ -z "$BASE_REF" ]; then BASE_REF="$(git merge-base HEAD origin/windows-port)" || { echo "no merge-base with origin/windows-port; pass --base" >&2; exit 2; }; fi
BASE_SHA="$(git rev-parse --verify "$BASE_REF^{commit}")" || { echo "bad base ref $BASE_REF" >&2; exit 2; }

BASE_TREE="$SCRATCH/ptb-render-base"
OUT="$SCRATCH/plaza-renders"
BASE_OUT="$OUT/base"; HEAD_OUT="$OUT/head"
rm -rf "$BASE_OUT" "$HEAD_OUT"; mkdir -p "$BASE_OUT" "$HEAD_OUT"

SPRITES="$HOME/Library/Application Support/PokeTokenBar/sprites"
if [ -d "$SPRITES" ]; then export PTB_PLAZA_RENDER_SPRITES="$SPRITES"; else unset PTB_PLAZA_RENDER_SPRITES; echo "note: no cached sprites; real-sprites scene skipped"; fi

SWIFT_BUILD_FLAGS=(--build-tests)
SWIFT_TEST_FLAGS=(--skip-build)
if [ "$RELEASE" = 1 ]; then
  SWIFT_BUILD_FLAGS=(-c release --build-tests -Xswiftc -enable-testing)
  SWIFT_TEST_FLAGS=(-c release --skip-build)
fi

wait_idle() {
  # One swift build/test at a time on this Mac, shared with other sessions: wait, never start on top.
  local waited=0
  while pgrep -x swift-build >/dev/null || pgrep -x swift-test >/dev/null || pgrep -x xctest >/dev/null; do
    [ $waited -eq 0 ] && echo "waiting for another swift build/test to finish..."
    sleep 10; waited=$((waited + 10))
    if [ $waited -gt 3600 ]; then echo "gave up waiting for an idle machine" >&2; exit 2; fi
  done
}

in_tree() { # <dir> <cmd...>
  local dir="$1"; shift
  ( cd "$dir" && "$@" )
}

build() { # <dir>
  wait_idle
  in_tree "$1" swift build "${SWIFT_BUILD_FLAGS[@]}" 2>&1 | tail -3
  [ "${PIPESTATUS[0]}" -eq 0 ] || { echo "build failed in $1" >&2; exit 2; }
}

run_test() { # <dir> <filter> [VAR=value ...]
  local dir="$1" filter="$2"; shift 2
  wait_idle
  in_tree "$dir" env "$@" swift test "${SWIFT_TEST_FLAGS[@]}" --filter "$filter" 2>&1
}

# --- base worktree (detached, reused) ---
if [ -e "$BASE_TREE/.git" ]; then
  git -C "$BASE_TREE" checkout -q -f --detach "$BASE_SHA" || { echo "cannot check out $BASE_SHA in $BASE_TREE" >&2; exit 2; }
else
  git worktree add -q --detach "$BASE_TREE" "$BASE_SHA" || { echo "cannot create base worktree" >&2; exit 2; }
fi
if [ ! -e "$BASE_TREE/Tests/PokeTokenBarTests/PlazaRender/PlazaRenderCompareTests.swift" ]; then
  echo "base $BASE_SHA has no render harness (Tests/PokeTokenBarTests/PlazaRender); pick a base that contains it" >&2; exit 2
fi

echo "base: $BASE_SHA ($BASE_REF)  head: $(git rev-parse --short HEAD)$(git diff --quiet HEAD -- 2>/dev/null || echo ' + uncommitted changes')"
echo "== build base"; build "$BASE_TREE"
echo "== render base";  run_test "$BASE_TREE" "PlazaRenderCompareTests/testRenderAllScenes" PTB_PLAZA_RENDER_OUT="$BASE_OUT" | grep -E "error:|Executed .* tests?|PLAZA-RENDER" | tail -5
echo "== build head"; build "$REPO"
echo "== render head"; run_test "$REPO" "PlazaRenderCompareTests/testRenderAllScenes" PTB_PLAZA_RENDER_OUT="$HEAD_OUT" | grep -E "error:|Executed .* tests?|PLAZA-RENDER" | tail -5
[ -f "$BASE_OUT/manifest.tsv" ] && [ -f "$HEAD_OUT/manifest.tsv" ] || { echo "RENDER: harness produced no manifest (see output above)" >&2; exit 2; }

echo "== compare"
CMP_LOG="$OUT/compare.log"
run_test "$REPO" "PlazaRenderCompareTests/testRendersMatch" PTB_PLAZA_RENDER_A="$BASE_OUT" PTB_PLAZA_RENDER_B="$HEAD_OUT" > "$CMP_LOG"
CMP_RC=$?
grep -E "^RENDER:" "$CMP_LOG" | head -1
grep -vE "^(Test |\[|Build|Compiling|Linking|\s*Executed|◇|✔|✘|ℹ)" "$CMP_LOG" | grep -E "px differ|tree diff|differs|present in only" | head -40
RENDER_OK=0
if [ $CMP_RC -eq 0 ] && grep -q "^RENDER: identical" "$CMP_LOG"; then RENDER_OK=1; else
  grep -q "^RENDER:" "$CMP_LOG" || echo "RENDER: compare did not run (see $CMP_LOG)"
  echo "diff images and tree diffs are in $HEAD_OUT (diff-*.png, compare-result.txt)"
fi

# --- frame cost, alternating base/head ---
echo "== frame cost ($RUNS runs each, alternating)"
BASE_COST="$OUT/cost-base.txt"; HEAD_COST="$OUT/cost-head.txt"; rm -f "$BASE_COST" "$HEAD_COST"
for i in $(seq 1 "$RUNS"); do
  run_test "$BASE_TREE" "PlazaFrameCostHarness/testFrameCost" PTB_PLAZA_FRAMECOST_OUT="$BASE_COST" > /dev/null
  run_test "$REPO"      "PlazaFrameCostHarness/testFrameCost" PTB_PLAZA_FRAMECOST_OUT="$HEAD_COST" > /dev/null
done

median() { sort -n | awk '{a[NR]=$1} END{ if (NR%2) print a[(NR+1)/2]; else print (a[NR/2]+a[NR/2+1])/2 }'; }
spread() { sort -n | awk '{a[NR]=$1} END{ printf "%.4f", (a[NR]-a[1])/((NR%2)?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2) }'; }
COST_OK=1
for col in update render; do
  idx=2; [ "$col" = render ] && idx=4
  bm=$(awk -v i=$idx '{print $i}' "$BASE_COST" | median); hm=$(awk -v i=$idx '{print $i}' "$HEAD_COST" | median)
  bs=$(awk -v i=$idx '{print $i}' "$BASE_COST" | spread); hs=$(awk -v i=$idx '{print $i}' "$HEAD_COST" | spread)
  ratio=$(awk -v a="$bm" -v b="$hm" 'BEGIN{printf "%.3f", b/a}')
  echo "FRAMECOST: $col base $bm head $hm ratio $ratio (limit $LIMIT) [run spread base $bs head $hs]"
  awk -v r="$ratio" -v l="$LIMIT" 'BEGIN{exit !(r<=l)}' || COST_OK=0
done

if [ $RENDER_OK = 1 ] && [ $COST_OK = 1 ]; then echo "RESULT: ok"; exit 0; fi
echo "RESULT: FAIL (render ok=$RENDER_OK cost ok=$COST_OK)"; exit 1
