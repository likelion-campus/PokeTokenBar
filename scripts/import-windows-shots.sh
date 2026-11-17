#!/usr/bin/env bash
# Imports the Windows doc captures of one CI run into assets/windows/ and records their provenance in SHOTS.txt.
#
#   scripts/import-windows-shots.sh <windows-app run id>
#
# The shot list is assets/windows/SHOT-LIST.txt ("file | artifact | path inside the artifact [| flags]"; flags: crop=..., not-for-docs). Only listed files are
# copied; a listed file the run does not have is reported and skipped; a SHOTS.txt line of the same file is replaced.
# Downloads into a NEW temporary directory (never the repo). Needs gh, logged in. Never writes to GitHub.
set -euo pipefail
REPO_SLUG="likelion-campus/PokeTokenBar"
[ $# -eq 1 ] || { echo "usage: $0 <windows-app run id>" >&2; exit 2; }
RUN="$1"
case "$RUN" in ''|*[!0-9]*) echo "run id must be a number" >&2; exit 2;; esac
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIST="$ROOT/assets/windows/SHOT-LIST.txt"
SHOTS="$ROOT/assets/windows/SHOTS.txt"
[ -f "$LIST" ] || { echo "missing $LIST" >&2; exit 2; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/ptb-win-shots.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
ARTIFACTS="$(grep -v '^#' "$LIST" | awk -F' [|] ' 'NF>=3 {print $2}' | sort -u)"
for a in $ARTIFACTS; do
  mkdir -p "$TMP/$a"
  gh run download "$RUN" --repo "$REPO_SLUG" -n "$a" -D "$TMP/$a" >/dev/null 2>&1 || echo "note: artifact $a is not in run $RUN"
done
copied=0
while IFS= read -r line; do
  case "$line" in ''|'#'*) continue;; esac
  name="$(printf '%s' "$line" | awk -F' [|] ' '{print $1}')"
  art="$(printf '%s' "$line" | awk -F' [|] ' '{print $2}')"
  rel="$(printf '%s' "$line" | awk -F' [|] ' '{print $3}')"
  flags="$(printf '%s' "$line" | awk -F' [|] ' '{print $4}')"
  case "$name" in */*|*..*|*[!A-Za-z0-9._-]*) echo "refusing the name '$name'" >&2; exit 2;; esac
  src="$TMP/$art/$rel"
  if [ ! -f "$src" ]; then echo "skipped $name: $art/$rel is not in run $RUN"; continue; fi
  crop="$(printf '%s' "$flags" | tr ',' '\n' | sed -n 's/^crop=//p')"
  label="Sample-data capture, Windows CI runner"
  case ",$flags," in *,not-for-docs,*) label="$label. NOT FOR USER-FACING DOCS until a capture with real sprites exists";; esac
  if [ -n "$crop" ]; then
    # crop=<srcW>x<srcH>:<x>:<y>:<w>:<h>: fails (nothing copied for this file, exit 2) on another source size or without PIL
    python3 - "$src" "$ROOT/assets/windows/$name" "$crop" <<'PY' || { echo "refusing $name: the crop step failed (a different source size, or python3 with PIL is missing)" >&2; exit 2; }
import sys
from PIL import Image
src, dst, spec = sys.argv[1:4]
size, x, y, w, h = spec.split(":")
im = Image.open(src).convert("RGB")
if "%dx%d" % im.size != size:
    sys.exit("source is %dx%d, the crop was measured on %s" % (im.size[0], im.size[1], size))
im.crop((int(x), int(y), int(x) + int(w), int(y) + int(h))).save(dst)
PY
    label="$label, cropped to the app's own rectangle"
    case ",$flags," in *,en-only,*) label="$label (the run has only the English menu)";; esac
  else
    cp "$src" "$ROOT/assets/windows/$name"
  fi
  grep -v "^$name | " "$SHOTS" > "$SHOTS.new" || true
  mv "$SHOTS.new" "$SHOTS"
  echo "$name | https://github.com/$REPO_SLUG/actions/runs/$RUN | PokeTokenBar.exe --selftest --dump-ui <dir> (windows-app workflow; artifact $art, file $rel) | $label" >> "$SHOTS"
  copied=$((copied + 1))
done < "$LIST"
echo "imported $copied capture(s) from run $RUN"
for f in "$ROOT"/assets/windows/*.png; do
  n="$(basename "$f")"
  grep -q "^$n | " "$LIST" || echo "warning: $n is not on the shot list" >&2
done
