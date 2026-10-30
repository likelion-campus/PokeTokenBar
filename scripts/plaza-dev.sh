#!/usr/bin/env bash
#
# plaza-dev.sh — 실제 세이브를 건드리지 않고 개발 빌드로 팀 광장을 써 본다.
# 실제 세이브는 읽기만 하고(복사), 개발 앱은 별도 상태 폴더에서 돈다.
# 스프라이트 이미지 캐시는 상태 폴더와 무관하게 설치된 앱과 공유한다(캐시일 뿐이라 해가 없다).
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_DIR="$HOME/Library/Application Support/PokeTokenBar"
DEV_DIR="${TMPDIR:-/tmp}/ptb-plaza-dev"
DEV_DIR="${DEV_DIR//\/\//\/}"

mkdir -p "$DEV_DIR"

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
- 설정 → 팀에서 켜기, 팀 만들기, 닉네임 입력 후 "광장 열기"를 누르세요.
- 종료는 Ctrl+C.

MSG

cd "$REPO_ROOT"
PTB_STATE_DIR="$DEV_DIR" exec swift run PokeTokenBar
