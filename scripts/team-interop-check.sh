#!/usr/bin/env bash
# The Mac's team TLS-PSK (Network.framework) against the OpenSSL command line set up exactly like the Windows side
# (Sources/CTeamTLS/CTeamTLS.c: TLS 1.2 only, PSK-AES128-GCM-SHA256, identity ptb-team-v1, no session tickets, no
# renegotiation, no session cache), both directions, on loopback only: no Bonjour, no app window, nothing leaves
# 127.0.0.1. The check is Tests/PokeTokenBarTests/TeamOpenSSLInteropTests.swift; this script waits for a free build
# slot, runs that suite and prints its INTEROP lines.
#
#   scripts/team-interop-check.sh                 run the check (needs OpenSSL 3: Homebrew's, or PTB_OPENSSL=<path>)
#   scripts/team-interop-check.sh --fingerprint   read a team code on stdin, print the key fingerprint
#
# The fingerprint is what the Windows probe (PokeTokenBar.exe --team-probe) prints as key_fingerprint: 8 hex digits of
# SHA-256 over the derived PSK. Equal on both machines = the same team code. The code itself is never printed, and
# never passed to a command line (it goes through stdin only):
#   pbpaste | scripts/team-interop-check.sh --fingerprint
set -euo pipefail

find_openssl() {
  for c in "${PTB_OPENSSL:-}" /opt/homebrew/bin/openssl /usr/local/bin/openssl; do
    [ -n "$c" ] && [ -x "$c" ] && "$c" version 2>/dev/null | grep -q '^OpenSSL 3' && { echo "$c"; return 0; }
  done
  echo "no OpenSSL 3 command line found (brew install openssl@3, or set PTB_OPENSSL); macOS's LibreSSL lacks -psk" >&2
  return 1
}

if [ "${1:-}" = "--fingerprint" ]; then
  # The code goes from stdin straight into Python's stdin: it is in no process's arguments or environment (ps shows
  # neither). Same rules as TeamCode(parsing:) and TeamCode.keyFingerprint.
  exec /usr/bin/python3 -I -c '
import hashlib, hmac, re, sys
raw = sys.stdin.readline().strip().upper()
raw = re.sub(r"^PTB[-\s]", "", raw)
code = re.sub(r"[-\s]", "", raw)
if not re.fullmatch(r"[A-Z2-7]{12}|[A-Z2-7]{26}", code):
    sys.stderr.write("not a team code (12 or 26 base32 characters after PTB-)\n")
    sys.exit(2)
key = hmac.new(code.encode(), b"poketokenbar.team.psk.v1", hashlib.sha256).digest()
print("key_fingerprint=" + hashlib.sha256(key).hexdigest()[:8])
'
fi

cd "$(dirname "$0")/.."
openssl=$(find_openssl)
echo "openssl: $openssl ($("$openssl" version))"
# One swift build at a time on this Mac (other sessions share it).
while pgrep -x swift-build >/dev/null || pgrep -x swift-test >/dev/null || pgrep -x xctest >/dev/null; do
  echo "waiting for another swift build/test to finish..."
  sleep 20
done
log=$(mktemp -t team-interop)
set +e
PTB_OPENSSL="$openssl" swift test --filter TeamOpenSSLInteropTests 2>&1 | tee "$log" | grep -E '^INTEROP|error:|failed|Executed'
status=${PIPESTATUS[0]}
set -e
echo "full log: $log"
if [ "$status" -eq 0 ] && grep -q "INTEROP s_client" "$log" && grep -q "INTEROP Mac dial" "$log"; then
  echo "RESULT PASS: the Mac and OpenSSL with the Windows options agree in both directions"
else
  echo "RESULT FAIL (exit $status): see the INTEROP lines above and $log"
  exit 1
fi
