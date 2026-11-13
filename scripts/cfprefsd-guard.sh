#!/usr/bin/env bash
#
# cfprefsd-guard.sh — 테스트 게이트 뒤에 cfprefsd 가 막혔는지 보고, 막혔으면 재시작한다.
#
# 사용:  ./scripts/cfprefsd-guard.sh        (team-release.sh 가 테스트 게이트 직후 호출한다)
#
# cfprefsd 는 존재하는 plist 마다 디렉터리 fd 를 하나씩 쥔다(~508 에서 막힌다). 테스트가 plist 를
# 너무 많이 남기면 파일을 지워도 안 풀려서, 앱이 설정을 못 읽고 팀 리스너 없이 뜬다.
# 정상이면 1~2개다. LIMIT(100)을 넘으면 agent 를 죽이고(launchd 가 되살린다) 내려갈 때까지 기다린다.
#
# 테스트용 대체: CFPREFSD_FDS_CMD(fd 수를 출력하는 명령), CFPREFSD_KILL_CMD(재시작 명령),
# CFPREFSD_WAIT_SECONDS(회복 대기 한도). 설정하면 실제 cfprefsd 를 건드리지 않는다.
#
set -euo pipefail

LIMIT=100
WAIT_SECONDS="${CFPREFSD_WAIT_SECONDS:-30}"

dir_fds() {
  if [[ -n "${CFPREFSD_FDS_CMD:-}" ]]; then
    eval "$CFPREFSD_FDS_CMD"
    return
  fi
  local pid
  pid=$(pgrep -u "$USER" -x cfprefsd | head -1 || true)
  [[ -n "$pid" ]] || { echo 0; return; }
  lsof -p "$pid" 2>/dev/null | awk '$5=="DIR"' | wc -l | tr -d ' '
}

restart_agent() {
  if [[ -n "${CFPREFSD_KILL_CMD:-}" ]]; then
    eval "$CFPREFSD_KILL_CMD"
    return
  fi
  # agent(사용자 세션) 만 죽인다. launchd 가 새로 띄운다.
  pkill -u "$USER" -f 'cfprefsd agent' || true
}

fds=$(dir_fds)
if [[ "$fds" -le "$LIMIT" ]]; then
  echo "  확인: cfprefsd 디렉터리 fd $fds 개"
  exit 0
fi

echo "경고: 테스트 뒤 cfprefsd 가 막혔습니다 (디렉터리 fd $fds 개, 한도 $LIMIT). 설정을 못 읽으면 앱이 팀 리스너 없이 뜹니다. cfprefsd 를 재시작합니다." >&2
restart_agent
for ((i = 0; i < WAIT_SECONDS; i++)); do
  sleep 1
  fds=$(dir_fds)
  if [[ "$fds" -le "$LIMIT" ]]; then
    echo "  확인: cfprefsd 회복 (디렉터리 fd $fds 개)"
    exit 0
  fi
done
echo "중단: cfprefsd 가 재시작 뒤에도 회복하지 않았습니다 (디렉터리 fd $fds 개). 릴리스는 만들지 않았습니다. 로그아웃/로그인 또는 재부팅 후 다시 실행하세요." >&2
exit 1
