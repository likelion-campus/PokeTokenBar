# DIAGNOSTIC (branch diag/update-runner-loss-2 only). What the VM looks like after the in-app update step (when the runner lived to
# run this): the process table, TCP by state, the newest System/Application events of the last 40 minutes that are warnings or
# worse, and the environment facts that matter for the update path.
$ErrorActionPreference = 'Continue'
. "$PSScriptRoot/diag-lib.ps1"
'---- env ----'
"SHELL='$env:SHELL' CI='$env:CI' PTB_SELFTEST_RUNNER='$env:PTB_SELFTEST_RUNNER' cores=$([Environment]::ProcessorCount)"
$cs = Get-CimInstance Win32_ComputerSystem; "RAM=$([math]::Round($cs.TotalPhysicalMemory / 1GB, 1))G"
Get-CimInstance Win32_PageFileUsage | ForEach-Object { "pagefile $($_.Name) alloc=$($_.AllocatedBaseSize)MB used=$($_.CurrentUsage)MB peak=$($_.PeakUsage)MB" }
'---- processes ----'
Get-DiagProcessTable
'---- TCP by state ----'
try { [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpConnections() | Group-Object State | ForEach-Object { "$($_.Name)=$($_.Count)" } } catch { "tcp: $($_.Exception.Message)" }
'---- events (level <= 3, last 40 min) ----'
foreach ($logName in 'System', 'Application') {
    Get-WinEvent -FilterHashtable @{ LogName = $logName; Level = 1, 2, 3; StartTime = (Get-Date).AddMinutes(-40) } -MaxEvents 40 -ErrorAction SilentlyContinue |
        ForEach-Object { "$logName $($_.TimeCreated.ToUniversalTime().ToString('HH:mm:ss')) $($_.ProviderName) id=$($_.Id): $("$($_.Message)" -replace '\s+', ' ' | ForEach-Object { $_.Substring(0, [math]::Min(240, $_.Length)) })" }
}
