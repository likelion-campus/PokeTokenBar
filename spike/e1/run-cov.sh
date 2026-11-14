#!/usr/bin/env bash
# Throwaway (Track B experiment E1, P12): which WinSDK APIs import into Swift and link, one executable each.
set -u
cd "$(dirname "$0")"
R="${GITHUB_WORKSPACE:-$PWD}/e1-cov.txt"
: > "$R"
for api in DnsServiceRegister DnsServiceBrowse NotifyNetworkConnectivityHintChange GetLastInputInfo Shell_NotifyIconW \
           CredReadW RegisterPowerSettingNotification RegisterSuspendResumeNotification WSAPoll MiniDumpWriteDump \
           SHGetKnownFolderPath; do
  if swift build -c release --product "cov_$api" > "cov-$api.log" 2>&1; then
    out=$(./.build/release/cov_$api.exe 2>&1 | tr -d '\r')
    echo "E1.P12 PASS $api imports+links run=\"$out\"" | tee -a "$R"
  else
    if grep -qE "lld-link|LNK[0-9]+|undefined symbol|unresolved external" "cov-$api.log"; then kind=link; else kind=compile; fi
    echo "E1.P12 FAIL $api stage=$kind" | tee -a "$R"
    grep -E "error" "cov-$api.log" | tr -d '\r' | head -6 | sed 's/^/    /' | tee -a "$R"
  fi
done
exit 0
