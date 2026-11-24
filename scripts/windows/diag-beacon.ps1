# DIAGNOSTIC (branch diag/update-runner-loss-2 only). One beacon step: waits, samples the VM, and hands the short line to the NEXT
# step's name through GITHUB_ENV (DIAG_BEACON). A step's name is sent when the step starts, so the job's step list keeps the
# samples even when the runner is lost and no log survives. When the detached in-app update script has ended, sets DIAG_DONE=1.
param([int]$Wait = 10, [string]$Dir = 'collected\in-app-update')
$ErrorActionPreference = 'Continue'
. "$PSScriptRoot/diag-lib.ps1"
Start-Sleep -Seconds $Wait
$stateFile = Join-Path $env:RUNNER_TEMP 'diag-beacon-state.xml'
$state = if (Test-Path $stateFile) { Import-Clixml $stateFile } else { @{} }
$since = [datetime]::Parse((Get-Content (Join-Path $Dir 'script.start') -Raw).Trim(), [Globalization.CultureInfo]::InvariantCulture, 'RoundtripKind')
$log = Join-Path $Dir 'script.log'
$s = Get-DiagSample -State $state -ScriptLog $log -Since $since
$state | Export-Clixml $stateFile
Add-Content -Path (Join-Path $Dir 'beacons.log') -Value $s.Long
$s.Long
$scriptPid = [int](Get-Content (Join-Path $Dir 'script.pid') -Raw).Trim()
$alive = [bool](Get-Process -Id $scriptPid -ErrorAction SilentlyContinue)
"DIAG_BEACON=$($s.Short -replace '[\r\n]', ' ')" >> $env:GITHUB_ENV
if (-not $alive) { 'the detached script has ended'; 'DIAG_DONE=1' >> $env:GITHUB_ENV }
# The script's newest lines, so the step log (when it survives) shows the scenario as it went.
if (Test-Path $log) {
    $st = [System.IO.File]::Open($log, 'Open', 'Read', 'ReadWrite, Delete')
    try { $text = ([System.IO.StreamReader]::new($st)).ReadToEnd() } finally { $st.Dispose() }
    ($text -split "`r?`n" | Where-Object { $_ } | Select-Object -Last 6) -join "`n"
}
