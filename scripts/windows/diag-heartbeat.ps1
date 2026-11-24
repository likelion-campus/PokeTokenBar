# DIAGNOSTIC (branch diag/update-runner-loss-2 only). A heartbeat from a scheduled task (every minute, two tasks 30 s apart): one
# small check run on the diagnostic commit with the time, whether the runner's processes live, the last lines of the runner's own
# _diag log, and how far the in-app update got (its files and the app log). Posted with curl.exe (its own HTTP stack, not .NET or
# WinHTTP) and, as a second check run, with Invoke-RestMethod (.NET HttpClient, the runner's stack): which of them still arrive after
# a runner is lost tells a dead VM or network from a stuck HTTP stack. The token is read from a header file, never a command line.
param([Parameter(Mandatory)] [string]$Config, [string]$Label = 'hb', [string[]]$Via = @('curl'))
$ErrorActionPreference = 'Continue'
$cfg = Get-Content $Config -Raw | ConvertFrom-Json
$now = (Get-Date).ToUniversalTime()
$lines = [System.Collections.Generic.List[string]]::new()
$procs = [System.Diagnostics.Process]::GetProcesses()
function Pids([string]$n) { (@($procs | Where-Object { $_.ProcessName -eq $n }) | ForEach-Object Id) -join ',' }
$os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
$state = "L=$(Pids 'Runner.Listener') W=$(Pids 'Runner.Worker') WT=$(Pids 'WindowsTerminal') OC=$(Pids 'OpenConsole') ptb=$(Pids 'PokeTokenBar') setup=$((@($procs | Where-Object { $_.ProcessName -like 'PokeTokenBar-Setup*' }) | ForEach-Object Id) -join ',') werfault=$(Pids 'WerFault') n=$($procs.Count) free=$(if ($os) { [math]::Round($os.FreePhysicalMemory / 1MB, 1) })G"
$lines.Add("$Label $($cfg.job) $($now.ToString('HH:mm:ss'))Z $state")
$diag = Get-ChildItem 'C:\actions-runner\cached' -Recurse -Depth 2 -File -Filter 'Runner_*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
if ($diag) { $lines.Add("runner log $($diag.Name) written $($diag.LastWriteTimeUtc.ToString('HH:mm:ss'))Z:"); Get-Content $diag.FullName -Tail 6 | ForEach-Object { $lines.Add("  $(if ($_.Length -gt 220) { $_.Substring(0, 220) } else { $_ })") } }
$wdiag = Get-ChildItem 'C:\actions-runner\cached' -Recurse -Depth 2 -File -Filter 'Worker_*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
if ($wdiag) { $lines.Add("worker log written $($wdiag.LastWriteTimeUtc.ToString('HH:mm:ss'))Z:"); Get-Content $wdiag.FullName -Tail 3 | ForEach-Object { $lines.Add("  $(if ($_.Length -gt 220) { $_.Substring(0, 220) } else { $_ })") } }
Get-CimInstance Win32_Process -Filter "Name LIKE 'PokeTokenBar%' OR Name LIKE 'update-feed%'" -ErrorAction SilentlyContinue | ForEach-Object {
    $cl = "$($_.CommandLine)"; if ($cl.Length -gt 140) { $cl = $cl.Substring(0, 140) }
    $lines.Add("  proc $($_.ProcessId)<-$($_.ParentProcessId) $($_.Name) $(if ($_.CreationDate) { $_.CreationDate.ToUniversalTime().ToString('HH:mm:ss') }) :: $cl")
}
$dir = Join-Path $cfg.workspace 'collected\in-app-update'
$newest = Get-ChildItem $dir -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 6
$lines.Add("in-app files: $(($newest | ForEach-Object { "$($_.Name)@$($_.LastWriteTimeUtc.ToString('HH:mm:ss'))" }) -join ' ')")
$app = Join-Path $env:LOCALAPPDATA 'PokeTokenBar\Logs\PokeTokenBar.log'
if (Test-Path $app) {
    $s = [System.IO.File]::Open($app, 'Open', 'Read', 'ReadWrite, Delete')
    try { ([System.IO.StreamReader]::new($s)).ReadToEnd() -split "`r?`n" | Where-Object { $_ } | Select-Object -Last 6 | ForEach-Object { $lines.Add("  app: $(if ($_.Length -gt 200) { $_.Substring(0, 200) } else { $_ })") } } finally { $s.Dispose() }
}
$text = ($lines -join "`n") -replace 'gh[pousr]_[A-Za-z0-9]{20,}', '[redacted]' -replace 'eyJ[A-Za-z0-9._-]{30,}', '[redacted-jwt]'
$summary = $lines[0]
$tmp = Join-Path $env:TEMP "ptb-hb-$PID"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$headerFile = Join-Path $tmp 'h.txt'
Set-Content -Path $headerFile -Value @("Authorization: Bearer $($cfg.token)", 'Accept: application/vnd.github+json', 'X-GitHub-Api-Version: 2022-11-28', 'Content-Type: application/json') -Encoding ascii
foreach ($via in $Via) {
    $body = @{ name = "hb $($cfg.job) $($now.ToString('HH:mm:ss')) $via"; head_sha = $cfg.sha; status = 'completed'; conclusion = 'neutral'
               output = @{ title = "$Label $via"; summary = "$summary via $via"; text = $text } } | ConvertTo-Json -Depth 5
    $bodyFile = Join-Path $tmp "b-$via.json"
    Set-Content -Path $bodyFile -Value $body -Encoding utf8NoBOM
    if ($via -eq 'curl') {
        & "$env:SystemRoot\System32\curl.exe" -sS -m 25 -o NUL -w "%{http_code}" -H "@$headerFile" --data-binary "@$bodyFile" "https://api.github.com/repos/$($cfg.repo)/check-runs" 2>&1 | ForEach-Object { "curl: $_" }
    } else {
        try { $null = Invoke-RestMethod -Method Post -TimeoutSec 25 -Uri "https://api.github.com/repos/$($cfg.repo)/check-runs" -Headers @{ Authorization = "Bearer $($cfg.token)"; Accept = 'application/vnd.github+json' } -Body $body -ContentType 'application/json'; 'dotnet: posted' } catch { "dotnet: $($_.Exception.Message)" }
    }
}
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
