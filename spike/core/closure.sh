#!/bin/bash
# Finds the largest set of Core/Team files that builds with portable imports only (run on a Mac).
# Start: no Apple-only framework imports and no CoreGraphics drawing types. Then drop any file that fails to compile
# (it needs a symbol from a dropped file), until the build is clean.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; root="$here/../.."; cd "$root"
hard='^[[:space:]]*(@preconcurrency )?import (AppKit|SwiftUI|SpriteKit|CoreText|QuartzCore|ImageIO|UniformTypeIdentifiers|Network|Security|LocalAuthentication|ServiceManagement|UserNotifications|Darwin|SQLite3)'
draw='CGContext|CGImage|CGColor|CGDataProvider|CGPath|CGBitmapInfo|CTFont|CGAffineTransform'
find Sources/PokeTokenBar/Core Sources/PokeTokenBar/Team -name "*.swift" | sort > "$here/all.txt"
xargs grep -LE "$hard" < "$here/all.txt" | xargs grep -LE "$draw" | sort > "$here/sources.txt"
comm -23 "$here/all.txt" "$here/sources.txt" > "$here/excluded-start.txt"
: > "$here/excluded-coupled.txt"
for round in $(seq 1 30); do
  "$here/sync.sh"
  (cd "$here" && swift build 2>&1) > "$here/build.log"
  grep -E "error:" "$here/build.log" | grep -oE "Sources/PokeTokenBar/[A-Za-z0-9_+]+\.swift" | sort -u | sed 's|Sources/PokeTokenBar/||' > "$here/failing.txt"
  n=$(wc -l < "$here/failing.txt" | tr -d ' ')
  echo "round $round: $(wc -l < "$here/sources.txt" | tr -d ' ') files, $n failing"
  [ "$n" = 0 ] && break
  while IFS= read -r flat; do
    orig=$(grep -E "/$(echo "$flat" | sed 's/^[A-Za-z]*_//; s/^Plaza_//; s/^UI_//')\$" "$here/sources.txt" | head -1)
    [ -n "$orig" ] && echo "$orig" >> "$here/excluded-coupled.txt"
  done < "$here/failing.txt"
  sort -u "$here/excluded-coupled.txt" -o "$here/excluded-coupled.txt"
  comm -23 "$here/sources.txt" "$here/excluded-coupled.txt" > "$here/s2" && mv "$here/s2" "$here/sources.txt"
done
tail -3 "$here/build.log"
echo "kept: $(wc -l < "$here/sources.txt") files, $(xargs cat < "$here/sources.txt" | wc -l) lines"
echo "excluded at start: $(wc -l < "$here/excluded-start.txt") files, $(xargs cat < "$here/excluded-start.txt" | wc -l) lines"
echo "excluded as coupled: $(wc -l < "$here/excluded-coupled.txt") files, $(xargs cat < "$here/excluded-coupled.txt" | wc -l) lines"
