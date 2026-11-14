#!/usr/bin/env bash
# Throwaway (Track B experiment E1): runs every probe in its own process. Each prints greppable `E1.*` lines.
# A probe's failure or crash never fails the job; its exit code is recorded as `E1.EXIT ... code=N`.
set -u
cd "$(dirname "$0")"
EXE=./.build/release/ptbe1.exe
AEXE=./.build/release/ptbe1async.exe
R="${GITHUB_WORKSPACE:-$PWD}/e1-report.txt"
: > "$R"

run() {
  echo "## ptbe1 $*" | tee -a "$R"
  timeout 90 "$EXE" "$@" 2>&1 | tr -d '\r' | tee -a "$R"
  local code=${PIPESTATUS[0]}
  echo "E1.EXIT ptbe1 $* code=$code" | tee -a "$R"
}

echo "E1.ENV $(cmd //c ver | tr -d '\r\n') | $(swift --version 2>&1 | head -1 | tr -d '\r')" | tee -a "$R"
echo "E1.ENV explorer: $(tasklist //FI "IMAGENAME eq explorer.exe" //NH 2>&1 | tr -d '\r' | head -2 | tr '\n' ' ')" | tee -a "$R"

run symbols
run timers
for m in cf cfhook dhc; do run text "$m"; done
for s in cf cur dh dhc; do run p2 "$s"; done
for v in toplevel direct pump timer dispatch task bg; do run p3 "$v"; done
for v in plain rl dq plainkeys rlkeys dqkeys; do run modal "$v"; done
run tray
run facts
run pchild e1.k.nosynckill nosync-kill
run pchild e1.k.synckill sync-kill
run pchild e1.k.nosyncexit nosync-exit
run pchild e1.k.nosyncrl nosync-runloop-kill
run pread e1.k.nosynckill=absent e1.k.synckill=present e1.k.nosyncexit=info e1.k.nosyncrl=absent
run process
run net

echo "## ptbe1async" | tee -a "$R"
timeout 60 "$AEXE" 2>&1 | tr -d '\r' | tee -a "$R"
echo "E1.EXIT ptbe1async code=${PIPESTATUS[0]}" | tee -a "$R"

# P4: idle cost, all strategies at once (CPU time is per process, so they do not disturb each other's numbers).
IDLE_SECS=${IDLE_SECS:-60}
for s in baseline cf dh dhc poll; do
  ( timeout 200 "$EXE" idle "$s" "$IDLE_SECS" > "idle-$s.txt" 2>&1; echo "E1.EXIT ptbe1 idle $s code=$?" >> "idle-$s.txt" ) &
done
wait
for s in baseline cf dh dhc poll; do echo "## ptbe1 idle $s" | tee -a "$R"; tr -d '\r' < "idle-$s.txt" | tee -a "$R"; done

echo "================ summary"
grep -E " (PASS|FAIL) |E1\.EXIT" "$R"
exit 0
