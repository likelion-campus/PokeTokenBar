# DIAGNOSTIC (branch diag/update-runner-loss-2 only). Samples the VM every -Interval seconds into -LogFile (opened per line) until
# -Seconds pass; every 10th sample adds the process table (parents, command lines). Watches nothing and ends nothing.
param([Parameter(Mandatory)] [string]$LogFile, [int]$Interval = 4, [int]$Seconds = 3300, [string]$ScriptLog = '')
$ErrorActionPreference = 'Continue'
. "$PSScriptRoot/diag-lib.ps1"
$state = @{}
$start = Get-Date
$i = 0
while ((Get-Date) -lt $start.AddSeconds($Seconds)) {
    try {
        $s = Get-DiagSample -State $state -ScriptLog $ScriptLog -Since $start
        $text = $s.Long
        if ($i % 10 -eq 0) { $text += [Environment]::NewLine + ((Get-DiagProcessTable) -join [Environment]::NewLine) }
        [System.IO.File]::AppendAllText($LogFile, $text + [Environment]::NewLine)
    } catch { [System.IO.File]::AppendAllText($LogFile, "sampler error: $($_.Exception.Message)" + [Environment]::NewLine) }
    $i++
    Start-Sleep -Seconds $Interval
}
