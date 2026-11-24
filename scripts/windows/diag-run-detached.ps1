# DIAGNOSTIC (branch diag/update-runner-loss-2 only). Runs in-app-update.ps1 unchanged, every output line (all streams) appended to
# -LogFile with a timestamp as it comes (the file is opened and closed per line: what was written survives anything).
param([Parameter(Mandatory)] [string]$LogFile, [Parameter(Mandatory)] [string]$Version, [Parameter(Mandatory)] [string]$NextVersion)
function Out-Line([string]$Text) { [System.IO.File]::AppendAllText($LogFile, ('{0} {1}' -f (Get-Date).ToUniversalTime().ToString('HH:mm:ss.fff'), $Text) + [Environment]::NewLine) }
Out-Line "detached pid $PID parent $((Get-CimInstance Win32_Process -Filter "ProcessId=$PID").ParentProcessId)"
try {
    & (Join-Path $PSScriptRoot 'in-app-update.ps1') -Version $Version -NextVersion $NextVersion *>&1 | ForEach-Object { Out-Line "$_" }
    Out-Line "SCRIPT END ok"
} catch {
    Out-Line "SCRIPT THREW: $($_.Exception.Message)"
    Out-Line "SCRIPT END threw"
}
