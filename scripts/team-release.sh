#!/usr/bin/env bash
#
# team-release.sh — 팀 포크(likelion-campus/PokeTokenBar) 전용 릴리스. 맥 zip 과 윈도우 설치 파일을 한 릴리스로 낸다.
#
# 사용:  ./scripts/team-release.sh <notes-file>
#        ./scripts/team-release.sh --rehearse <notes-file>
#
# 이 스크립트는 푸시하지 않는다. 버전 범프와 병합은 PR로 먼저 끝내 두고, main 에서 실행한다.
# 랜딩, Pages 단계는 없다. Homebrew 는 팀 탭만 갱신한다.
#
# 순서(stage 8 계획 D3). 두 시스템이 모두 통과하기 전에는 아무것도 공개하지 않는다.
#   0  인자, gh, VERSION, main/깨끗함/HEAD == origin/main, 태그·릴리스 없음, 서명 leaf
#   1  릴리스 도우미 자체 시험, 노트 확인, 문서 게이트
#   2  Windows 실행 시작(이 커밋의 릴리스 실행이 이미 있으면 재사용)
#   3  맥 테스트 게이트 + cfprefsd 확인 (Windows 실행은 그동안 GitHub 에서 돈다)
#   4  맥 빌드(build-app.sh 가 /Applications 에도 설치한다), 빌드된 앱의 leaf, zip, universal 검사
#   5  Windows 실행 두 개를 기다려 결과를 내려받고 매니페스트와 해시를 확인
#   6  노트 채우기(설치 파일 SHA-256)
#   7-8  team_release.py publish: draft 와 자산 두 개 → 확인 → 공개 → releases/latest 와 태그 확인
#   9  Homebrew 팀 탭 (publish 가 0 으로 끝났을 때만)
#   10 릴리스 뒤 smoke 실행 시작
# 0–1 에서 멈추면 아무것도 바뀌지 않는다. 2–3 은 Windows 실행만 남긴다(혼자 끝나고 다시 실행하면 재사용).
# 4 부터는 /Applications 에 새 빌드가 있을 수 있다(지금까지와 같다). 공개는 7–8 의 도우미만 한다.
# 버전 범프 PR 을 병합한 직후 python3 scripts/team_release.py start --sha <main HEAD> --version <x.y.z> 로
# Windows 실행을 먼저 시작해 두면, 이 스크립트는 그 실행을 재사용한다.
#
# --rehearse: origin 과 같은 커밋이면 어느 브랜치에서나. 0–2, 5, 6 을 실행하고(Windows 실행 시작만 쓰기),
# 테스트 게이트, 빌드, publish, 탭, smoke 는 SKIPPED 로 찍는다. 실제 릴리스라면 멈췄을 문서 게이트도 끝까지
# 보고 끝에서 알린다. 아무것도 빌드하거나 공개하지 않는다.
#
set -euo pipefail
cd "$(dirname "$0")/.."
# 도우미 자체 시험(1단계)이 clone 에 __pycache__ 를 남기면, 같은 clone 에서 다시 실행할 때 깨끗한 트리 확인에서 멈춘다.
export PYTHONDONTWRITEBYTECODE=1

SIGN_IDENTITY="PokeTokenBar Local"
# "PokeTokenBar Local" leaf SHA-1. 인증서를 다시 만들거나 바꾸면 PR로 갱신한다.
TEAM_EXPECTED_LEAF="67CE3D908138668379D07A70A9986B97FE0201CF"
ZIP="build/PokeTokenBar.zip"
TAP_REPO="likelion-campus/homebrew-tap"
CASK_PATH="Casks/poke-token-bar-team.rb"
BINARY="build/PokeTokenBar.app/Contents/MacOS/PokeTokenBar"
REPO_URL="https://github.com/likelion-campus/PokeTokenBar"

MODE=release
STEP=0
STEP_AT=$SECONDS
VERSION=""
BRANCH=""
LOCAL_HEAD=""
WINDOWS_RUNS=""
PUBLISH_RC=""
WOULD_STOP=""

# ── 남은 것: 멈춘 단계에서 무엇이 바뀌었는지 ───────────────
zip_sha() {
  shasum -a 256 "$ZIP" | cut -d' ' -f1
}

# GitHub 의 vVERSION: none / draft / public / unknown. 읽기만 한다.
release_state() {
  local out
  if out=$(gh release view "v$VERSION" --repo likelion-campus/PokeTokenBar --json isDraft --jq .isDraft 2>&1); then
    case "$out" in
      true) echo draft ;;
      false) echo public ;;
      *) echo unknown ;;
    esac
  elif [[ "$out" == *"release not found"* ]]; then
    echo none
  else
    echo unknown
  fi
}

left_at_publish() {
  local state
  state=$(release_state)
  case "$state" in
    none)
      echo "  남은 것: GitHub 에 v$VERSION 릴리스가 없습니다(방금 읽음). 공개한 것은 없고 탭은 그대로입니다. /Applications 에는 새 빌드가 있습니다." ;;
    draft)
      echo "  남은 것: v$VERSION draft 가 있습니다(방금 읽음, 공개 아님). $REPO_URL/releases 에서 확인하고, 이 실행이 남긴 것이면 지운 뒤 다시 실행하세요. 탭은 그대로입니다." ;;
    public)
      if [[ "$PUBLISH_RC" == 0 ]]; then
        echo "  남은 것: v$VERSION 이 공개됐고 publish 가 확인까지 마쳤습니다. 탭은 갱신하지 않았습니다: $TAP_REPO 의 $CASK_PATH 에서 version 을 $VERSION, sha256 을 $(zip_sha) 로 고치고, python3 scripts/team_release.py smoke --version $VERSION 을 실행하세요."
      elif [[ "$PUBLISH_RC" == 7 ]]; then
        echo "  남은 것: v$VERSION 은 이 실행 전부터 공개돼 있던 릴리스입니다. 이 실행은 아무것도 만들지 않았습니다. 이 실행의 zip 으로 탭을 고치지 마세요. 그 릴리스와 탭이 맞는지 손으로 확인하세요."
      else
        echo "  남은 것: v$VERSION 이 공개돼 있습니다(방금 읽음). 탭은 갱신하지 않았습니다. $REPO_URL/releases/tag/v$VERSION 에서 자산 두 개, digest, 태그 위치($LOCAL_HEAD)를 손으로 확인하세요. PokeTokenBar.zip 의 digest 가 sha256:$(zip_sha) 일 때만 탭을 version $VERSION, sha256 $(zip_sha) 로 고치고 smoke 를 실행하세요."
      fi ;;
    *)
      echo "  남은 것: 알 수 없음. GitHub 에서 v$VERSION 을 읽지 못했습니다. $REPO_URL/releases 를 손으로 확인하세요. 탭은 갱신하지 않았습니다." ;;
  esac
}

left_behind() {
  if [[ "$MODE" == rehearse ]]; then
    echo "  남은 것: 리허설이라 빌드, 공개, 탭은 하지 않았습니다.${WINDOWS_RUNS:+ Windows 실행($WINDOWS_RUNS)은 GitHub 에서 혼자 끝납니다.}"
    return 0
  fi
  case "$STEP" in
    0|1) echo "  남은 것: 없음. Windows 실행을 시작하지 않았고, 빌드하지 않았고(/Applications 그대로), 공개한 것도 없습니다." ;;
    2) echo "  남은 것: Windows 실행이 시작됐을 수 있습니다(혼자 끝나고, 같은 커밋으로 다시 실행하면 재사용). /Applications 는 그대로이고 공개한 것은 없습니다." ;;
    3) echo "  남은 것: Windows 실행($WINDOWS_RUNS)은 GitHub 에서 혼자 끝나고, 같은 커밋으로 다시 실행하면 재사용합니다. /Applications 는 그대로이고 공개한 것은 없습니다. 테스트가 중간에 끊겼다면 ./scripts/cfprefsd-guard.sh 를 한 번 실행하세요." ;;
    4) echo "  남은 것: /Applications 가 새 빌드로 바뀌었을 수 있습니다(지금까지와 같음). Windows 실행($WINDOWS_RUNS)은 혼자 끝납니다. 공개한 것은 없습니다." ;;
    5|6) echo "  남은 것: /Applications 의 새 빌드(지금까지와 같음)와 Windows 실행($WINDOWS_RUNS). 공개한 것은 없습니다. 같은 커밋으로 다시 실행하면 성공한 Windows 실행은 재사용하고, 실패한 실행이면 2단계에서 멈춥니다." ;;
    7) left_at_publish ;;
    9) echo "  남은 것: 공개된 v$VERSION (자산 두 개, 확인됨). 탭은 갱신되지 않았을 수 있습니다: $TAP_REPO 의 $CASK_PATH 가 version $VERSION, sha256 $(zip_sha) 인지 확인해 아니면 고치고, 그다음 python3 scripts/team_release.py smoke --version $VERSION 을 실행하세요." ;;
    10) echo "  남은 것: 공개된 v$VERSION 과 갱신된 탭. smoke 만 남았습니다: python3 scripts/team_release.py smoke --version $VERSION" ;;
  esac
}

fail() {
  echo "중단: $1" >&2
  left_behind >&2
  exit 1
}

on_signal() {
  local rc=$? code=$2
  trap - INT TERM HUP
  [[ "$STEP" != 7 ]] || PUBLISH_RC=$rc
  echo "" >&2
  echo "중단: $1 신호를 받았습니다([$STEP/10] 단계, 마지막 명령의 코드 $rc)." >&2
  left_behind >&2
  exit "$code"
}
trap 'on_signal INT 130' INT
trap 'on_signal TERM 143' TERM
trap 'on_signal HUP 129' HUP

mmss() {
  printf '%dm%02ds' $(( $1 / 60 )) $(( $1 % 60 ))
}

# 단계 머리줄: 번호(D3), 시작부터 지난 시간, 앞 단계에 걸린 시간.
step() {
  echo ""
  echo "▶ [$2/10] $3  (경과 $(mmss "$SECONDS"), 앞 단계 $(mmss $(( SECONDS - STEP_AT ))))"
  STEP=$1
  STEP_AT=$SECONDS
}

skipped() {
  echo ""
  echo "▶ [$1/10] $2: SKIPPED (리허설)"
}

# 실제 릴리스라면 여기서 멈춘다. 리허설은 적어 두고 계속한다(끝에서 0 이 아닌 코드로 알린다).
would_stop() {
  if [[ "$MODE" == rehearse ]]; then
    echo "  리허설: 실제 릴리스는 여기서 멈춥니다: $1" >&2
    WOULD_STOP="$WOULD_STOP [$STEP/10] $1"
  else
    fail "$1"
  fi
}

# 태그·릴리스가 이미 있음. 리허설은 버전 범프 전이 보통이라 알리기만 한다.
exists() {
  if [[ "$MODE" == rehearse ]]; then
    echo "  리허설: $1 (실제 릴리스는 버전 범프 전이면 여기서 멈춥니다. 리허설은 계속합니다.)"
  else
    fail "$1"
  fi
}

# 도우미가 stdout 에 찍은 KEY=value 줄의 값(마지막 것).
value_of() {
  local line value=""
  while IFS= read -r line; do
    case "$line" in
      "$1="*) value=${line#"$1="} ;;
    esac
  done <<EOF
$2
EOF
  printf '%s' "$value"
}

# ── 0. 인자, gh, 버전, git 상태, 태그·릴리스, 서명 신원 ─────
if [[ "${1:-}" == "--rehearse" ]]; then
  MODE=rehearse
  shift
fi
NOTES_FILE="${1:-}"
[[ -n "$NOTES_FILE" ]] || fail "릴리스 노트 파일을 넘기세요. 예: ./scripts/team-release.sh notes.md (리허설: ./scripts/team-release.sh --rehearse notes.md)"
[[ $# -eq 1 ]] || fail "인자가 너무 많습니다. 사용: ./scripts/team-release.sh [--rehearse] <notes-file>"
[[ -s "$NOTES_FILE" ]] || fail "릴리스 노트 파일이 없거나 비어 있습니다: $NOTES_FILE"

command -v gh >/dev/null 2>&1 || fail "gh(GitHub CLI)가 없습니다. 설치하고 gh auth login 을 한 뒤 다시 실행하세요."
gh auth status >/dev/null 2>&1 || fail "gh 에 로그인되어 있지 않습니다. gh auth login 을 한 뒤 다시 실행하세요."

VERSION=$(grep -oE '^VERSION="[0-9]+\.[0-9]+\.[0-9]+"' scripts/build-app.sh | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)
[[ -n "$VERSION" ]] || fail "scripts/build-app.sh 에서 VERSION 을 읽지 못했습니다."
if [[ "$MODE" == rehearse ]]; then
  echo "=== 팀 릴리스 리허설 v$VERSION (빌드·공개 없음) ==="
else
  echo "=== 팀 릴리스 v$VERSION ==="
fi
echo "▶ [0/10] 인자, gh, 버전, git 상태, 태그·릴리스, 서명 신원"

BRANCH=$(git rev-parse --abbrev-ref HEAD || true)
if [[ "$MODE" == release ]]; then
  [[ "$BRANCH" == "main" ]] || fail "main 브랜치에서 실행하세요(현재: $BRANCH). 버전 범프 PR을 병합한 뒤 main 으로 옮겨 오세요."
else
  [[ -n "$BRANCH" && "$BRANCH" != "HEAD" ]] || fail "리허설은 브랜치에서 실행하세요(지금은 브랜치가 아닌 커밋을 보고 있습니다)."
fi

[[ -z "$(git status --porcelain)" ]] || fail "커밋하지 않은 변경이 있습니다. 커밋하거나 되돌린 뒤 다시 실행하세요."

ORIGIN_URL=$(git remote get-url origin 2>/dev/null || true)
case "$ORIGIN_URL" in
  https://github.com/likelion-campus/PokeTokenBar|https://github.com/likelion-campus/PokeTokenBar.git|git@github.com:likelion-campus/PokeTokenBar|git@github.com:likelion-campus/PokeTokenBar.git) ;;
  *) fail "origin 이 likelion-campus/PokeTokenBar 가 아닙니다. 팀 포크를 clone 한 폴더에서 실행하세요." ;;
esac

git fetch --quiet --tags origin || fail "origin 을 가져오지 못했습니다. 네트워크를 확인하고 다시 실행하세요."
LOCAL_HEAD=$(git rev-parse HEAD || true)
REMOTE_HEAD=$(git rev-parse --verify --quiet "origin/$BRANCH" || true)
[[ -n "$LOCAL_HEAD" && "$LOCAL_HEAD" == "$REMOTE_HEAD" ]] || fail "로컬 $BRANCH 가 origin/$BRANCH 와 다릅니다(로컬 $LOCAL_HEAD, origin ${REMOTE_HEAD:-없음}). git pull 로 맞춘 뒤 다시 실행하세요(이 스크립트는 푸시하지 않습니다). Windows 는 GitHub 에 있는 커밋만 빌드합니다."
echo "  확인: $BRANCH = origin/$BRANCH = $LOCAL_HEAD"

if git show-ref --verify --quiet "refs/tags/v$VERSION"; then
  exists "태그 v$VERSION 이 이미 있습니다(릴리스가 공개되면 생깁니다). 새 릴리스라면 버전을 올리는 PR을 먼저 병합하세요. 직전 실행이 공개 뒤(탭, smoke)에서 멈췄다면 다시 실행하지 말고 그 실행이 알려 준 대로 손으로 마치세요."
fi
case "$(release_state)" in
  none) ;;
  draft) exists "draft 릴리스 v$VERSION 이 있습니다(공개 아님). 직전 실행이 남긴 것이거나 다른 세션이 v$VERSION 을 내는 중입니다. $REPO_URL/releases 에서 확인하고, 남은 것이면 지운 뒤 다시 실행하세요." ;;
  public) exists "릴리스 v$VERSION 이 이미 공개돼 있습니다. 새 릴리스라면 버전을 올리는 PR을 먼저 병합하세요." ;;
  *) fail "릴리스가 있는지 확인하지 못했습니다(네트워크나 권한 문제일 수 있습니다). gh auth status 와 연결을 확인하고 다시 실행하세요." ;;
esac

LEAF=$(security find-identity -v -p codesigning | awk -v id="\"$SIGN_IDENTITY\"" '$0 ~ id {print $2; exit}' || true)
[[ -n "$LEAF" ]] || fail "서명 신원 '$SIGN_IDENTITY' 이 없습니다. ./scripts/create-signing-cert.sh 를 직접 실행한 뒤 다시 시도하세요(이 스크립트는 인증서를 만들지 않습니다)."

if [[ -z "$TEAM_EXPECTED_LEAF" ]]; then
  echo "현재 인증서 leaf: $LEAF" >&2
  fail "첫 릴리스입니다. 위 leaf 를 이 스크립트의 TEAM_EXPECTED_LEAF 에 적고 PR로 병합한 뒤 다시 실행하세요."
fi
[[ "$LEAF" == "$TEAM_EXPECTED_LEAF" ]] || fail "인증서 leaf 가 다릅니다(현재 $LEAF, 기대 $TEAM_EXPECTED_LEAF). 인증서를 바꾼 게 맞다면 TEAM_EXPECTED_LEAF 를 PR로 고치고, 아니면 원래 Mac 에서 실행하세요."
echo "  확인: 서명 신원 '$SIGN_IDENTITY' leaf=$LEAF"

# ── 1. 도우미 자체 시험, 노트 확인, 문서 게이트 ─────────────
step 1 1 "릴리스 도우미 자체 시험, 노트 확인, 문서 게이트"
command -v python3 >/dev/null 2>&1 || fail "python3 가 없습니다. Command Line Tools 를 설치하고 다시 실행하세요(xcode-select --install)."
SELFTEST_OUT=$(python3 -m unittest discover -s scripts/tests -p 'test_team_*.py' 2>&1) || {
  printf '%s\n' "$SELFTEST_OUT" >&2
  fail "릴리스 도우미의 자체 시험이 실패했습니다(위 출력). 이 Mac 의 python3 로 도우미를 믿을 수 없습니다."
}
echo "  확인: 릴리스 도우미 자체 시험"

NOTES_RC=0
python3 scripts/team_notes.py check --in "$NOTES_FILE" || NOTES_RC=$?
case "$NOTES_RC" in
  0) echo "  확인: 릴리스 노트 양식" ;;
  1) fail "릴리스 노트가 팀 양식에 맞지 않습니다(위 이유). docs/reference/team-release-notes-template.md 를 따라 고친 뒤 다시 실행하세요." ;;
  *) fail "team_notes.py check 가 예상하지 못한 코드 $NOTES_RC 로 끝났습니다(위 출력)." ;;
esac

DOCS_RC=0
python3 scripts/team_docs_check.py || DOCS_RC=$?
case "$DOCS_RC" in
  0) echo "  확인: 문서 게이트" ;;
  2) would_stop "문서 게이트가 멈췄습니다(위 STOP 줄): 새로 보이는 기능에 새 캡처가 없습니다. 캡처를 더해 병합한 뒤 다시 실행하세요." ;;
  *) fail "문서 게이트를 실행하지 못했습니다(team_docs_check.py 코드 $DOCS_RC, 위 출력)." ;;
esac

# ── 2. Windows 실행 시작 ───────────────────────────────────
step 2 2 "Windows 실행 시작: 이 커밋의 릴리스 실행을 재사용하거나 windows-app.yml, windows.yml 을 시작"
START_RC=0
START_OUT=$(python3 scripts/team_release.py start --sha "$LOCAL_HEAD" --version "$VERSION" --ref "$BRANCH") || START_RC=$?
case "$START_RC" in
  0) ;;
  3) fail "이 커밋의 가장 최근 Windows 릴리스 실행이 성공하지 못했습니다(위 URL). 실패를 먼저 읽으세요. 고칠 것이면 고쳐 병합하고 다시 실행하세요. 알려진 흔들림(flake)일 때만 python3 scripts/team_release.py start --sha $LOCAL_HEAD --version $VERSION --ref $BRANCH --new failed 로 새로 시작한 뒤 다시 실행하세요." ;;
  1) fail "Windows 실행을 찾거나 시작하지 못했습니다(gh 호출 실패, 또는 시작한 실행이 60초 안에 보이지 않음, 위 출력). 다시 실행하면 이미 시작된 실행을 재사용합니다." ;;
  2) fail "team_release.py start 가 인자를 거부했습니다(이 스크립트의 결함)." ;;
  *) fail "team_release.py start 가 예상하지 못한 코드 $START_RC 로 끝났습니다(위 출력)." ;;
esac
WINDOWS_APP_RUN=$(value_of WINDOWS_APP_RUN "$START_OUT")
WINDOWS_TESTS_RUN=$(value_of WINDOWS_TESTS_RUN "$START_OUT")
[[ -n "$WINDOWS_APP_RUN" && -n "$WINDOWS_TESTS_RUN" ]] || fail "team_release.py start 가 실행 번호를 알려 주지 않았습니다: '$START_OUT'"
WINDOWS_RUNS="$REPO_URL/actions/runs/$WINDOWS_APP_RUN $REPO_URL/actions/runs/$WINDOWS_TESTS_RUN"
echo "  windows-app: $REPO_URL/actions/runs/$WINDOWS_APP_RUN"
echo "  windows:     $REPO_URL/actions/runs/$WINDOWS_TESTS_RUN"

if [[ "$MODE" == rehearse ]]; then
  skipped 3 "맥 테스트 게이트"
  skipped 4 "맥 빌드, 빌드된 앱의 leaf, zip, universal 검사"
else
  # ── 3. 맥 테스트 게이트 ─────────────────────────────────
  step 3 3 "맥 테스트 게이트 + cfprefsd 확인 (Windows 실행은 그동안 GitHub 에서 돕니다)"
  ./scripts/test-gate.sh || fail "테스트 게이트가 실패했습니다. 위 출력을 확인하세요. 릴리스는 만들지 않았습니다."
  # 테스트가 cfprefsd 를 막았으면 앱을 설치하고 띄우기 전에 풀어 둔다(실패하면 릴리스 중단).
  ./scripts/cfprefsd-guard.sh || fail "cfprefsd 를 회복하지 못했습니다. 릴리스는 만들지 않았습니다."

  # ── 4. 빌드 (여기부터 /Applications 가 바뀐다) → leaf, zip, universal ──
  step 4 4 "맥 빌드 + /Applications 설치, 빌드된 앱의 leaf, zip, universal 검사"
  export PTB_REQUIRE_STABLE_SIGN=1
  export CODESIGN_IDENTITY="$SIGN_IDENTITY"
  ./scripts/build-app.sh || fail "빌드가 실패했습니다. 위 출력을 확인하세요. 릴리스는 만들지 않았습니다."

  CERT_DIR=$(mktemp -d) || fail "임시 폴더를 만들지 못했습니다. 릴리스는 만들지 않았습니다."
  trap 'rm -rf "$CERT_DIR"' EXIT
  codesign -d --extract-certificates="$CERT_DIR/cert" build/PokeTokenBar.app >/dev/null 2>&1 || fail "빌드된 앱의 서명을 읽지 못했습니다. 릴리스는 만들지 않았습니다."
  BUILT_LEAF=$(/usr/bin/openssl x509 -inform der -in "$CERT_DIR/cert0" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g' | tr 'a-f' 'A-F' || true)
  [[ "$BUILT_LEAF" == "$TEAM_EXPECTED_LEAF" ]] || fail "빌드된 앱의 서명 leaf($BUILT_LEAF)가 고정값과 다릅니다. 릴리스는 만들지 않았습니다. 서명 신원을 확인하세요."
  rm -f "$ZIP"
  ditto -c -k --keepParent build/PokeTokenBar.app "$ZIP" || fail "zip 을 만들지 못했습니다. 릴리스는 만들지 않았습니다."
  lipo "$BINARY" -verify_arch arm64 x86_64 || fail "universal(arm64 + x86_64) 바이너리가 아닙니다. 릴리스는 만들지 않았습니다."
fi

# ── 5. Windows 결과 ────────────────────────────────────────
step 5 5 "Windows 실행 두 개를 기다려 결과를 내려받고 매니페스트와 해시 확인"
COLLECT_RC=0
COLLECT_OUT=$(python3 scripts/team_release.py collect --sha "$LOCAL_HEAD" --version "$VERSION" --out build/windows-release) || COLLECT_RC=$?
case "$COLLECT_RC" in
  0) ;;
  4) fail "Windows 결과가 이 릴리스의 조건을 통과하지 못했습니다(위 이유와 URL: 실행 실패, 시간 초과, 재실행, 매니페스트나 해시 불일치). 실패를 먼저 읽으세요. 고칠 것이면 고쳐 병합하고 다시 실행하세요. 알려진 흔들림(flake)일 때만 python3 scripts/team_release.py start --sha $LOCAL_HEAD --version $VERSION --ref $BRANCH --new failed 로 새로 시작한 뒤 다시 실행하세요." ;;
  2) fail "team_release.py collect 가 인자를 거부했습니다(이 스크립트의 결함)." ;;
  *) fail "team_release.py collect 가 예상하지 못한 코드 $COLLECT_RC 로 끝났습니다(위 출력)." ;;
esac
INSTALLER=$(value_of INSTALLER "$COLLECT_OUT")
SHA256=$(value_of SHA256 "$COLLECT_OUT")
[[ -n "$INSTALLER" && -n "$SHA256" ]] || fail "team_release.py collect 가 설치 파일이나 SHA-256 을 알려 주지 않았습니다: '$COLLECT_OUT'"
echo "  설치 파일: $INSTALLER"
echo "  SHA-256:   $SHA256"

# ── 6. 노트 채우기 ─────────────────────────────────────────
step 6 6 "릴리스 노트 채우기(설치 파일 SHA-256) → build/release-notes.md"
FILL_RC=0
python3 scripts/team_notes.py fill --in "$NOTES_FILE" --version "$VERSION" --sha256 "$SHA256" --out build/release-notes.md || FILL_RC=$?
case "$FILL_RC" in
  0) echo "  확인: build/release-notes.md" ;;
  1) fail "릴리스 노트를 채우지 못했습니다(위 이유). 노트를 고친 뒤 다시 실행하세요." ;;
  *) fail "team_notes.py fill 이 예상하지 못한 코드 $FILL_RC 로 끝났습니다(위 출력)." ;;
esac

if [[ "$MODE" == rehearse ]]; then
  skipped 7-8 "GitHub 릴리스 v$VERSION (publish)"
  echo "  실제 릴리스라면 실행할 명령:"
  # 명령은 찍기만 한다. publish 를 실행하는 줄은 아래 한 줄뿐이다.
  printf '    python3 scripts/team_release.py %s --sha %s --version %s --zip %s --installer %s --notes %s\n' \
    publish "$LOCAL_HEAD" "$VERSION" "$ZIP" "$INSTALLER" build/release-notes.md
  skipped 9 "Homebrew 탭"
  skipped 10 "smoke"
  echo ""
  if [[ -n "$WOULD_STOP" ]]; then
    echo "리허설 끝(총 $(mmss "$SECONDS")): Windows 결과와 노트는 준비됐지만, 실제 릴리스는 멈췄을 것입니다:$WOULD_STOP" >&2
    left_behind >&2
    exit 1
  fi
  echo "리허설 끝(총 $(mmss "$SECONDS")): v$VERSION ($LOCAL_HEAD) 의 Windows 결과와 노트가 준비됐습니다. 빌드, 공개, 탭은 하지 않았습니다."
  exit 0
fi

# ── 7–8. 릴리스: draft → 확인 → 공개 → 확인 (team_release.py 만 쓴다) ──
step 7 7-8 "GitHub 릴리스 v$VERSION: draft 와 자산 두 개 → 확인 → 공개 → releases/latest 와 태그 확인"
PUBLISH_RC=0
python3 scripts/team_release.py publish --sha "$LOCAL_HEAD" --version "$VERSION" --zip "$ZIP" --installer "$INSTALLER" --notes build/release-notes.md || PUBLISH_RC=$?
case "$PUBLISH_RC" in
  0) ;;
  5) fail "publish 가 공개 전에 멈췄습니다(위 이유). 이 실행은 v$VERSION 을 공개하지 않았고 탭도 그대로입니다. 위 메시지가 남은 draft 를 말하면 releases 에서 확인하세요. 원인을 고친 뒤 같은 VERSION 으로 다시 실행하세요." ;;
  6) fail "v$VERSION 이 공개됐거나 공개됐을 수 있는데, publish 의 확인이 실패했습니다(위 이유). 탭은 갱신하지 않았습니다. 다시 실행하지 말고 손으로 확인하세요." ;;
  7) fail "v$VERSION 은 이 실행 전에 이미 공개돼 있었습니다. 이 실행은 아무것도 만들지 않았고 탭도 그대로입니다." ;;
  2) fail "team_release.py publish 가 인자를 거부했습니다(이 스크립트의 결함). 만든 것은 없습니다." ;;
  *) fail "team_release.py publish 가 예상하지 못한 코드 $PUBLISH_RC 로 끝났습니다(위 출력). 탭은 갱신하지 않았습니다." ;;
esac

# ── 9. Homebrew 탭 ─────────────────────────────────────────
# 릴리스는 이미 공개됐으므로 여기서 실패하면 되돌리지 않고 고칠 값을 알려 준다.
step 9 9 "Homebrew 탭 갱신"
ZIP_SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1) || fail "릴리스는 공개됐지만 $ZIP 의 SHA-256 을 계산하지 못해 탭을 갱신하지 않았습니다."
TAP_FAILED="릴리스는 공개됐지만 Homebrew 탭을 갱신하지 못했습니다. $TAP_REPO 의 $CASK_PATH 에서 version 을 $VERSION, sha256 을 $ZIP_SHA 로 고치세요."
CASK_BLOB=$(gh api "repos/$TAP_REPO/contents/$CASK_PATH" --jq '.sha') || fail "$TAP_FAILED"
OLD_CASK=$(gh api "repos/$TAP_REPO/contents/$CASK_PATH" --jq '.content' | base64 -d) || fail "$TAP_FAILED"
NEW_CASK=$(printf '%s\n' "$OLD_CASK" | perl -pe "s/^  version \".*\"/  version \"$VERSION\"/; s/^  sha256 \".*\"/  sha256 \"$ZIP_SHA\"/") || fail "$TAP_FAILED"
[[ "$NEW_CASK" == *"version \"$VERSION\""* && "$NEW_CASK" == *"sha256 \"$ZIP_SHA\""* ]] || fail "$TAP_FAILED"
gh api -X PUT "repos/$TAP_REPO/contents/$CASK_PATH" -f message="cask: poke-token-bar-team $VERSION" \
  -f content="$(printf '%s\n' "$NEW_CASK" | base64)" -f sha="$CASK_BLOB" --silent || fail "$TAP_FAILED"

# ── 10. 릴리스 뒤 smoke ────────────────────────────────────
step 10 10 "릴리스 뒤 smoke 실행 시작(기다리지 않습니다)"
SMOKE_RC=0
SMOKE_OUT=$(python3 scripts/team_release.py smoke --version "$VERSION") || SMOKE_RC=$?
[[ "$SMOKE_RC" == 0 ]] || fail "v$VERSION 공개와 탭 갱신은 끝났습니다. smoke 실행만 시작하지 못했습니다(team_release.py smoke 코드 $SMOKE_RC, 위 출력)."
echo "  smoke: $SMOKE_OUT"
echo ""
echo "완료: v$VERSION (총 $(mmss "$SECONDS"))"
