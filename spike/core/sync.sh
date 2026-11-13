#!/bin/bash
# Copies the files listed in sources.txt / tests.txt from the repo into this package.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; root="$here/../.."
rm -rf "$here/Sources" "$here/Tests"; mkdir -p "$here/Sources/PokeTokenBar" "$here/Tests/PokeTokenBarTests"
while IFS= read -r f; do [ -z "$f" ] && continue; cp "$root/$f" "$here/Sources/PokeTokenBar/$(echo "$f" | sed 's|Sources/PokeTokenBar/||; s|/|_|g')"; done < <(tr -d "\r" < "$here/sources.txt")
while IFS= read -r f; do [ -z "$f" ] && continue; cp "$root/$f" "$here/Tests/PokeTokenBarTests/$(basename "$f")"; done < <(tr -d "\r" < "$here/tests.txt")
for f in "$here"/Sources/PokeTokenBar/*.swift "$here"/Tests/PokeTokenBarTests/*.swift; do [ -e "$f" ] || continue
  sed -i.bak -E 's/^([[:space:]]*)import CryptoKit[[:space:]]*$/\1import Crypto/' "$f"; rm -f "$f.bak"
  perl -0pi -e 's/^[ \t]*import CoreGraphics[ \t]*$/#if canImport(CoreGraphics)\nimport CoreGraphics\n#else\nimport Foundation\n#endif/mg' "$f"; done
[ -d "$here/Stubs" ] && cp "$here"/Stubs/*.swift "$here/Sources/PokeTokenBar/" || true
