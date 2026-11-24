# Runs the app's --selftest (a GUI-subsystem exe, so it is waited on, not piped), prints one line per check and
# fails unless every check passed.
# Usage: run-selftest.ps1 -Exe bundle\PokeTokenBar.exe -Out st.json [-ExpectStrategy cfRunLoopWithMessages] [-TimeoutSec 1200]
param(
    [Parameter(Mandatory)][string]$Exe,
    [Parameter(Mandatory)][string]$Out,
    [string]$ExpectStrategy = "",
    [int]$TimeoutSec = $(if ([int]$env:PTB_SELFTEST_FLAKE_LOOP -gt 0) { 3000 } else { 1200 }),  # 900 -> 1200 (stage 7 Task 22): run 44062168430 hit 900 s with the Shop/Bag and pet groups. Keep it under the calling step's timeout-minutes (windows-app.yml: bundle 25 min, installed 45 min for two tries) or Actions ends the step before the "checks so far" dump
    [string]$DumpUi = ""
)
$ErrorActionPreference = "Stop"
$Out = [System.IO.Path]::GetFullPath($Out)
$lines = "$Out.lines"
Remove-Item -ErrorAction SilentlyContinue $Out, $lines
# The hatch base index (PokeAPIClient.baseSpeciesIndex) is built from PokeAPI when %LOCALAPPDATA%\PokeTokenBar\base-index.json is missing:
# GraphQL fails on Windows (WinHTTP 12044), then 649 REST fetches in rounds of 6 on worker threads that wake the process during the
# selftest's idle probes. The selftest does not depend on the live network for it, so the file is seeded (never over a real one):
# every id 1...649 as a base with capture rate 45 (BaseSpecies id/captureRate; fetchedAt as Foundation's default Date coding,
# seconds since 2001-01-01 UTC, so the 30-day cache is fresh).
$baseIndex = Join-Path $env:LOCALAPPDATA 'PokeTokenBar\base-index.json'
if (-not (Test-Path $baseIndex)) {
    New-Item -ItemType Directory -Force -Path (Split-Path $baseIndex) | Out-Null
    $since2001 = [int64]([DateTime]::UtcNow - [DateTime]::new(2001, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)).TotalSeconds
    $entries = (1..649 | ForEach-Object { '{"id":' + $_ + ',"captureRate":45}' }) -join ','
    Set-Content -Path $baseIndex -Encoding ascii -Value ('{"fetchedAt":' + $since2001 + ',"entries":[' + $entries + ']}')
    Write-Host "seeded $baseIndex (649 bases) so the selftest does not build the base index over the network"
}
# The runner-only checks (real input, clipboard, Run key, High Contrast, a joined team) need PTB_SELFTEST_RUNNER=1, which only the workflows set.
Write-Host "selftest mode: $(if ($env:PTB_SELFTEST_RUNNER -eq '1') { 'runner (runner-only checks run)' } else { "a person's PC (runner-only checks are skipped)" })"
$selftestArgs = @("--selftest", "--selftest-out", $Out)
if ($DumpUi) { $selftestArgs += @("--dump-ui", [System.IO.Path]::GetFullPath($DumpUi)) }
$p = Start-Process -FilePath (Resolve-Path $Exe).Path -ArgumentList $selftestArgs -PassThru
$null = $p.Handle  # keeps ExitCode readable after the process ends
if (-not $p.WaitForExit($TimeoutSec * 1000)) {
    Stop-Process -Id $p.Id -Force
    Write-Host "::error::selftest did not finish in $TimeoutSec s; checks so far:"
    if (Test-Path $lines) { Get-Content $lines }
    exit 1
}
Write-Host "selftest exit code: $($p.ExitCode)"
if (-not (Test-Path $Out)) {
    Write-Host "::error::the selftest wrote no $Out; checks so far:"
    if (Test-Path $lines) { Get-Content $lines }
    exit 1
}
$j = Get-Content $Out -Raw | ConvertFrom-Json
foreach ($c in $j.checks) {
    "{0} {1}: {2}" -f $(if ($c.ok) { "PASS" } else { "FAIL" }), $c.name, $c.detail
}
"result=$($j.result) version=$($j.version) openssl=$($j.openssl)"
$problems = @()
if ($j.result -ne "pass") { $problems += "result $($j.result): " + (($j.checks | Where-Object { -not $_.ok } | ForEach-Object { $_.name }) -join ", ") }
if ($p.ExitCode -ne 0) { $problems += "exit code $($p.ExitCode)" }
if ($j.openssl -notlike "OpenSSL 3.*") { $problems += "openssl $($j.openssl)" }
$loop = @($j.checks | Where-Object { $_.name -like "loop.*" })
if ($loop.Count -lt 8) { $problems += "only $($loop.Count) loop.* checks" }
if ($ExpectStrategy) {
    $s = $j.checks | Where-Object { $_.name -eq "loop.strategy" }
    if (-not $s -or $s.detail -notlike "strategy=$ExpectStrategy *") { $problems += "loop.strategy is not $ExpectStrategy" }
}
if ($env:PTB_SELFTEST_RUNNER -eq '1') {
    # The flag was set, so the runner-only group must have run: a variable lost on the way would otherwise leave CI green while testing less.
    $mode = $j.checks | Where-Object { $_.name -eq "selftest.mode" }
    if (-not $mode -or $mode.detail -ne "runner") { $problems += "PTB_SELFTEST_RUNNER=1 was set but selftest.mode is '$($mode.detail)'" }
}
$lb = $j.checks | Where-Object { $_.name -eq "team.loopbackExchange" }
if (-not $lb -or $lb.detail -like "skipped*") { $problems += "team.loopbackExchange missing or skipped (the path every person's run takes)" }
if ($problems) { Write-Host "::error::selftest: $($problems -join '; ')"; exit 1 }
