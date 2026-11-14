# Runs the app's --selftest (a GUI-subsystem exe, so it is waited on, not piped), prints one line per check and
# fails unless every check passed.
# Usage: run-selftest.ps1 -Exe bundle\PokeTokenBar.exe -Out st.json [-ExpectStrategy cfRunLoopWithMessages] [-TimeoutSec 600]
param(
    [Parameter(Mandatory)][string]$Exe,
    [Parameter(Mandatory)][string]$Out,
    [string]$ExpectStrategy = "",
    [int]$TimeoutSec = 600
)
$ErrorActionPreference = "Stop"
$Out = [System.IO.Path]::GetFullPath($Out)
$lines = "$Out.lines"
Remove-Item -ErrorAction SilentlyContinue $Out, $lines
$p = Start-Process -FilePath (Resolve-Path $Exe).Path -ArgumentList @("--selftest", "--selftest-out", $Out) -PassThru
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
if ($problems) { Write-Host "::error::selftest: $($problems -join '; ')"; exit 1 }
