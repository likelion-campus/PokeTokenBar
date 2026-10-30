#!/usr/bin/env bash
#
# plaza-dev.sh [2] — 실제 세이브를 건드리지 않고 개발 빌드로 팀 광장을 써 본다.
# 실제 세이브는 읽기만 하고(복사), 개발 앱은 별도 상태 폴더에서 돈다.
# 인자 2를 주면 두 번째 인스턴스(상태 폴더 ptb-plaza-dev-2)를 띄운다. 터미널 두 개로 각각 실행하면 둘이 동시에 돈다.
# 두 번째 인스턴스의 팀 설정(켜짐, 팀 코드)은 첫 번째에서 복사한다. 첫 번째에 팀이 없으면 먼저 설정하라고 안내하고 멈춘다.
# 스프라이트 이미지 캐시는 상태 폴더와 무관하게 설치된 앱과 공유한다(캐시일 뿐이라 해가 없다).
#
set -euo pipefail

INSTANCE="${1:-1}"
case "$INSTANCE" in
  1|2) ;;
  *) echo "사용법: bash scripts/plaza-dev.sh [2]" >&2; exit 1 ;;
esac

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_DIR="$HOME/Library/Application Support/PokeTokenBar"
TMP_BASE="${TMPDIR:-/tmp}"
TMP_BASE="${TMP_BASE%/}"
DEV_DIR1="$TMP_BASE/ptb-plaza-dev"
DEV_DIR2="$TMP_BASE/ptb-plaza-dev-2"
if [[ "$INSTANCE" == "2" ]]; then DEV_DIR="$DEV_DIR2"; else DEV_DIR="$DEV_DIR1"; fi

# 상태 폴더의 팀 설정 UserDefaults 이름: "ptb.team." + 폴더 경로 SHA-256 앞 12자리 (TeamSettings.suiteName).
suite_for() {
  printf 'ptb.team.%s' "$(printf %s "$1" | shasum -a 256 | cut -c1-12)"
}

mkdir -p "$DEV_DIR"

if [[ "$INSTANCE" == "2" ]]; then
  SUITE1="$(suite_for "$DEV_DIR1")"
  SUITE2="$(suite_for "$DEV_DIR2")"
  CODE="$(defaults read "$SUITE1" team.code 2>/dev/null || true)"
  if [[ -z "$CODE" ]]; then
    echo "첫 번째 인스턴스에 팀 코드가 없습니다."
    echo "먼저 'bash scripts/plaza-dev.sh'로 첫 번째 인스턴스를 띄우고 설정에서 팀을 만든 뒤 다시 실행하세요."
    exit 1
  fi
  ENABLED="$(defaults read "$SUITE1" team.enabled 2>/dev/null || echo 1)"
  defaults write "$SUITE2" team.code -string "$CODE"
  if [[ "$ENABLED" == "0" ]]; then
    defaults write "$SUITE2" team.enabled -bool false
  else
    defaults write "$SUITE2" team.enabled -bool true
  fi
  if ! defaults read "$SUITE2" team.nickname >/dev/null 2>&1; then
    defaults write "$SUITE2" team.nickname -string "팀원2"
  fi
  CODE=""
  echo "첫 번째 인스턴스의 팀 설정을 복사했습니다 (팀 코드는 출력하지 않습니다)."
fi

if [[ -f "$REAL_DIR/companion-state.json" ]]; then
  cp "$REAL_DIR/companion-state.json" "$DEV_DIR/companion-state.json"
  echo "세이브를 복사했습니다 (원본은 그대로)."
else
  echo "실제 세이브가 없어 빈 상태로 실행합니다."
fi

cat <<'MSG'

[광장 개발 실행]
- 메뉴바에 아이콘이 하나 더 생깁니다 (개발 앱).
- 설치된 앱은 그대로 둬도 됩니다.
- 개발 앱의 세이브와 팀 설정은 따로 저장됩니다.
- 스프라이트 이미지 캐시는 설치된 앱과 공유합니다(캐시라 괜찮습니다).
- 광장 창이 바로 열립니다. 닫은 뒤 다시 열려면 이 스크립트를 다시 실행하세요.
- 이름이 비어 있으면 메뉴바 아이콘 → 설정 → 팀에서 켜기, 팀 만들기, 닉네임을 입력하세요.
- 두 번째 인스턴스는 'bash scripts/plaza-dev.sh 2' (다른 터미널에서).
- 종료는 Ctrl+C.

MSG

cd "$REPO_ROOT"
swift build
PTB_STATE_DIR="$DEV_DIR" exec "$REPO_ROOT/.build/debug/PokeTokenBar" --open-plaza
