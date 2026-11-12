#!/usr/bin/env bash
#
# team-release.sh — 팀 포크(likelion-campus/PokeTokenBar) 전용 릴리스.
#
# 사용:  ./scripts/team-release.sh <notes-file>
#
# 이 스크립트는 푸시하지 않는다. 버전 범프와 병합은 PR로 먼저 끝내 두고, main 에서 실행한다.
# 모든 확인은 빌드보다 앞에 있다. 확인에서 멈추면 /Applications 는 그대로다.
# 빌드는 build-app.sh 가 하고, 그 스크립트가 /Applications 에도 설치한다.
# 랜딩, Pages 단계는 없다. Homebrew 는 팀 탭만 갱신한다.
#
set -euo pipefail
cd "$(dirname "$0")/.."

SIGN_IDENTITY="PokeTokenBar Local"
# "PokeTokenBar Local" leaf SHA-1. 인증서를 다시 만들거나 바꾸면 PR로 갱신한다.
TEAM_EXPECTED_LEAF="67CE3D908138668379D07A70A9986B97FE0201CF"
ZIP="build/PokeTokenBar.zip"
TAP_REPO="likelion-campus/homebrew-tap"
CASK_PATH="Casks/poke-token-bar-team.rb"
BINARY="build/PokeTokenBar.app/Contents/MacOS/PokeTokenBar"

fail() {
  echo "중단: $1" >&2
  exit 1
}

# ── 1. 인자 ────────────────────────────────────────────────
NOTES_FILE="${1:-}"
[[ -n "$NOTES_FILE" ]] || fail "릴리스 노트 파일을 넘기세요. 예: ./scripts/team-release.sh notes.md"
[[ -s "$NOTES_FILE" ]] || fail "릴리스 노트 파일이 없거나 비어 있습니다: $NOTES_FILE"

command -v gh >/dev/null 2>&1 || fail "gh(GitHub CLI)가 없습니다. 설치하고 gh auth login 을 한 뒤 다시 실행하세요."
gh auth status >/dev/null 2>&1 || fail "gh 에 로그인되어 있지 않습니다. gh auth login 을 한 뒤 다시 실행하세요."

# ── 2. 버전 ────────────────────────────────────────────────
VERSION=$(grep -oE '^VERSION="[0-9]+\.[0-9]+\.[0-9]+"' scripts/build-app.sh | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)
[[ -n "$VERSION" ]] || fail "scripts/build-app.sh 에서 VERSION 을 읽지 못했습니다."
echo "=== 팀 릴리스 v$VERSION ==="

# ── 3. git 상태 (빌드 전) ───────────────────────────────────
BRANCH=$(git rev-parse --abbrev-ref HEAD)
[[ "$BRANCH" == "main" ]] || fail "main 브랜치에서 실행하세요(현재: $BRANCH). 버전 범프 PR을 병합한 뒤 main 으로 옮겨 오세요."

[[ -z "$(git status --porcelain)" ]] || fail "커밋하지 않은 변경이 있습니다. 커밋하거나 되돌린 뒤 다시 실행하세요."

ORIGIN_URL=$(git remote get-url origin 2>/dev/null || true)
case "$ORIGIN_URL" in
  https://github.com/likelion-campus/PokeTokenBar|https://github.com/likelion-campus/PokeTokenBar.git|git@github.com:likelion-campus/PokeTokenBar|git@github.com:likelion-campus/PokeTokenBar.git) ;;
  *) fail "origin 이 likelion-campus/PokeTokenBar 가 아닙니다. 팀 포크를 clone 한 폴더에서 실행하세요." ;;
esac

git fetch --quiet --tags origin || fail "origin 을 가져오지 못했습니다. 네트워크를 확인하고 다시 실행하세요."
LOCAL_HEAD=$(git rev-parse HEAD)
REMOTE_HEAD=$(git rev-parse origin/main)
[[ "$LOCAL_HEAD" == "$REMOTE_HEAD" ]] || fail "로컬 main 이 origin/main 과 다릅니다. git pull 로 맞춘 뒤 다시 실행하세요(이 스크립트는 푸시하지 않습니다)."

# ── 4. 태그와 릴리스가 이미 있는지 ─────────────────────────
if git show-ref --verify --quiet "refs/tags/v$VERSION"; then
  fail "태그 v$VERSION 이 이미 있습니다. 버전을 올리는 PR을 먼저 병합하세요."
fi
if VIEW_OUT=$(gh release view "v$VERSION" --repo likelion-campus/PokeTokenBar 2>&1); then
  fail "릴리스 v$VERSION 이 이미 있습니다. 버전을 올리는 PR을 먼저 병합하세요."
elif [[ "$VIEW_OUT" != *"release not found"* ]]; then
  fail "릴리스가 있는지 확인하지 못했습니다(네트워크나 권한 문제일 수 있습니다). gh auth status 와 연결을 확인하고 다시 실행하세요."
fi

# ── 5. 서명 신원 ───────────────────────────────────────────
LEAF=$(security find-identity -v -p codesigning | awk -v id="\"$SIGN_IDENTITY\"" '$0 ~ id {print $2; exit}')
[[ -n "$LEAF" ]] || fail "서명 신원 '$SIGN_IDENTITY' 이 없습니다. ./scripts/create-signing-cert.sh 를 직접 실행한 뒤 다시 시도하세요(이 스크립트는 인증서를 만들지 않습니다)."

if [[ -z "$TEAM_EXPECTED_LEAF" ]]; then
  echo "현재 인증서 leaf: $LEAF" >&2
  fail "첫 릴리스입니다. 위 leaf 를 이 스크립트의 TEAM_EXPECTED_LEAF 에 적고 PR로 병합한 뒤 다시 실행하세요."
fi
[[ "$LEAF" == "$TEAM_EXPECTED_LEAF" ]] || fail "인증서 leaf 가 다릅니다(현재 $LEAF, 기대 $TEAM_EXPECTED_LEAF). 인증서를 바꾼 게 맞다면 TEAM_EXPECTED_LEAF 를 PR로 고치고, 아니면 원래 Mac 에서 실행하세요."
echo "  확인: 서명 신원 '$SIGN_IDENTITY' leaf=$LEAF"

# ── 6. 테스트 게이트 ───────────────────────────────────────
echo "▶ 테스트 게이트"
./scripts/test-gate.sh || fail "테스트 게이트가 실패했습니다. 위 출력을 확인하세요. 릴리스는 만들지 않았습니다."

# ── 7. 빌드 (여기부터 /Applications 가 바뀐다) ──────────────
export PTB_REQUIRE_STABLE_SIGN=1
export CODESIGN_IDENTITY="$SIGN_IDENTITY"
echo "▶ 빌드 + /Applications 설치"
./scripts/build-app.sh || fail "빌드가 실패했습니다. 위 출력을 확인하세요. 릴리스는 만들지 않았습니다."

# ── 8. 빌드된 앱의 서명 leaf 확인 → zip + universal 검사 ───
CERT_DIR=$(mktemp -d)
trap 'rm -rf "$CERT_DIR"' EXIT
codesign -d --extract-certificates="$CERT_DIR/cert" build/PokeTokenBar.app >/dev/null 2>&1 || fail "빌드된 앱의 서명을 읽지 못했습니다. 릴리스는 만들지 않았습니다."
BUILT_LEAF=$(/usr/bin/openssl x509 -inform der -in "$CERT_DIR/cert0" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g' | tr 'a-f' 'A-F')
[[ "$BUILT_LEAF" == "$TEAM_EXPECTED_LEAF" ]] || fail "빌드된 앱의 서명 leaf($BUILT_LEAF)가 고정값과 다릅니다. 릴리스는 만들지 않았습니다. 서명 신원을 확인하세요."
rm -f "$ZIP"
ditto -c -k --keepParent build/PokeTokenBar.app "$ZIP"
lipo "$BINARY" -verify_arch arm64 x86_64 || fail "universal(arm64 + x86_64) 바이너리가 아닙니다. 릴리스는 만들지 않았습니다."

# ── 9. 릴리스 ──────────────────────────────────────────────
echo "▶ GitHub 릴리스 v$VERSION"
gh release create "v$VERSION" "$ZIP" --repo likelion-campus/PokeTokenBar --target "$LOCAL_HEAD" --title "v$VERSION" --notes-file "$NOTES_FILE"

# ── 10. Homebrew 탭 ────────────────────────────────────────
# 릴리스는 이미 공개됐으므로 여기서 실패하면 되돌리지 않고 고칠 값을 알려 준다.
echo "▶ Homebrew 탭 갱신"
ZIP_SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
TAP_FAILED="릴리스는 공개됐지만 Homebrew 탭을 갱신하지 못했습니다. $TAP_REPO 의 $CASK_PATH 에서 version 을 $VERSION, sha256 을 $ZIP_SHA 로 고치세요."
CASK_BLOB=$(gh api "repos/$TAP_REPO/contents/$CASK_PATH" --jq '.sha') || fail "$TAP_FAILED"
OLD_CASK=$(gh api "repos/$TAP_REPO/contents/$CASK_PATH" --jq '.content' | base64 -d) || fail "$TAP_FAILED"
NEW_CASK=$(printf '%s\n' "$OLD_CASK" | perl -pe "s/^  version \".*\"/  version \"$VERSION\"/; s/^  sha256 \".*\"/  sha256 \"$ZIP_SHA\"/")
[[ "$NEW_CASK" == *"version \"$VERSION\""* && "$NEW_CASK" == *"sha256 \"$ZIP_SHA\""* ]] || fail "$TAP_FAILED"
gh api -X PUT "repos/$TAP_REPO/contents/$CASK_PATH" -f message="cask: poke-token-bar-team $VERSION" \
  -f content="$(printf '%s\n' "$NEW_CASK" | base64)" -f sha="$CASK_BLOB" --silent || fail "$TAP_FAILED"
echo "완료: v$VERSION"
echo "   앱은 Spotlight·Finder·Launchpad 에서 직접 다시 열어라."
echo "   에이전트(Claude Code/Codex) 셸에서 open 으로 띄우면 앱이 설정에 접근하지 못해 팀 광장 등 설정이 사라진다."
