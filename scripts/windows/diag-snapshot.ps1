# DIAGNOSTIC (branch diag/update-runner-loss-2 only). A one-shot snapshot of the VM, posted as a check run on the diagnostic commit,
# so it survives a lost runner (no job log or artifact does). Started by a scheduled task a few minutes into the in-app update step
# (nothing of ours runs meanwhile); the step deletes the tasks when it ends normally. Config (JSON in RUNNER_TEMP): token, repo,
# sha, job label, workspace. Never prints the token; redacts anything token-shaped from what it posts.
param([Parameter(Mandatory)] [string]$Config, [Parameter(Mandatory)] [string]$Label)
$ErrorActionPreference = 'Continue'
$cfg = Get-Content $Config -Raw | ConvertFrom-Json
$out = [System.Text.StringBuilder]::new()
function Add([string]$Text) { [void]$out.AppendLine($Text) }
function Section([string]$Name, [scriptblock]$Body, [int]$Max = 8000) {
    Add "## $Name"
    $text = try { (& $Body | Out-String -Width 400) } catch { "error: $($_.Exception.Message)" }
    if ($text.Length -gt $Max) { $text = $text.Substring(0, $Max) + "`n...(cut)" }
    Add $text
}
$now = Get-Date
$os = Get-CimInstance Win32_OperatingSystem
$procs = Get-CimInstance Win32_Process
$byName = { param($n) @($procs | Where-Object { $_.Name -eq $n }) }
$rl = & $byName 'Runner.Listener.exe'; $rw = & $byName 'Runner.Worker.exe'
$wt = & $byName 'WindowsTerminal.exe'; $oc = & $byName 'OpenConsole.exe'
$ptb = @($procs | Where-Object { $_.Name -like 'PokeTokenBar*' -or $_.Name -like '_unins*' -or $_.Name -eq 'unins000.exe' })
$summary = "$Label $($cfg.job) at $($now.ToUniversalTime().ToString('HH:mm:ss'))Z: Listener=$($rl.Count) Worker=$($rw.Count) WT=$($wt.Count) OpenConsole=$($oc.Count) ptb-family=$($ptb.Count) boot=$($os.LastBootUpTime.ToUniversalTime().ToString('HH:mm:ss')) free=$([math]::Round($os.FreePhysicalMemory / 1MB, 1))G"
Add $summary
Section 'processes (pid <- parent name started ws handles :: command line)' {
    $procs | Sort-Object CreationDate | ForEach-Object {
        $cl = "$($_.CommandLine)"; if ($cl.Length -gt 170) { $cl = $cl.Substring(0, 170) }
        $at = if ($_.CreationDate) { $_.CreationDate.ToUniversalTime().ToString('HH:mm:ss') } else { '?' }
        "$($_.ProcessId) <- $($_.ParentProcessId) $($_.Name) $at ws=$([int]($_.WorkingSetSize / 1MB))M h=$($_.HandleCount) :: $cl"
    }
} 22000
Section 'visible top-level windows' {
    if (-not ([System.Management.Automation.PSTypeName]'DiagWin').Type) {
        Add-Type -TypeDefinition @'
using System; using System.Collections.Generic; using System.Runtime.InteropServices; using System.Text;
public static class DiagWin {
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder sb, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h, StringBuilder sb, int n);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    public static List<string> List() {
        var r = new List<string>(); IntPtr fg = GetForegroundWindow();
        EnumWindows((h, l) => { if (IsWindowVisible(h)) { var c = new StringBuilder(256); var t = new StringBuilder(256); GetClassNameW(h, c, 256); GetWindowTextW(h, t, 256); uint pid; GetWindowThreadProcessId(h, out pid);
            r.Add((h == fg ? "* " : "  ") + pid + " " + c + " '" + t + "'"); } return true; }, IntPtr.Zero);
        return r;
    }
}
'@
    }
    [DiagWin]::List()
} 5000
Section 'runner _diag (newest Runner_ and Worker_ logs, last 50 lines)' {
    $diag = @(Get-ChildItem 'C:\actions-runner' -Recurse -Depth 3 -File -Include 'Runner_*.log', 'Worker_*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime)
    foreach ($kind in 'Runner_', 'Worker_') {
        $f = $diag | Where-Object { $_.Name -like "$kind*" } | Select-Object -Last 1
        if ($f) { "---- $($f.FullName) (written $($f.LastWriteTimeUtc.ToString('HH:mm:ss'))Z)"; Get-Content $f.FullName -Tail 50 | ForEach-Object { if ($_.Length -gt 300) { $_.Substring(0, 300) } else { $_ } } }
        else { "---- no $kind log" }
    }
} 16000
Section 'events since the job began (System/Application, levels 1-3, and crash/WER/power providers)' {
    $since = $now.AddMinutes(-25)
    foreach ($log in 'System', 'Application') {
        Get-WinEvent -FilterHashtable @{ LogName = $log; StartTime = $since } -MaxEvents 400 -ErrorAction SilentlyContinue |
            Where-Object { $_.Level -le 3 -or $_.ProviderName -match 'Application Error|Application Hang|Windows Error Reporting|\.NET Runtime|Kernel-Power|EventLog|User32|Winlogon|RestartManager' } |
            Select-Object -First 60 | ForEach-Object {
                $m = "$($_.Message)" -replace '\s+', ' '; if ($m.Length -gt 260) { $m = $m.Substring(0, 260) }
                "$log $($_.TimeCreated.ToUniversalTime().ToString('HH:mm:ss')) L$($_.Level) $($_.ProviderName) id=$($_.Id): $m"
            }
    }
} 12000
Section 'in-app update progress (collected\in-app-update files, app and setup logs)' {
    $dir = Join-Path $cfg.workspace 'collected\in-app-update'
    Get-ChildItem $dir -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | ForEach-Object { "$($_.LastWriteTimeUtc.ToString('HH:mm:ss')) $($_.Length) $($_.Name)" }
    $logs = Join-Path $env:LOCALAPPDATA 'PokeTokenBar\Logs'
    '---- Logs folder'
    Get-ChildItem $logs -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 12 | ForEach-Object { "$($_.LastWriteTimeUtc.ToString('HH:mm:ss')) $($_.Length) $($_.Name)" }
    '---- app log tail'
    $app = Join-Path $logs 'PokeTokenBar.log'
    if (Test-Path $app) { $s = [System.IO.File]::Open($app, 'Open', 'Read', 'ReadWrite, Delete'); try { (([System.IO.StreamReader]::new($s)).ReadToEnd() -split "`r?`n" | Select-Object -Last 45) } finally { $s.Dispose() } }
    '---- newest setup log tail'
    $setup = Get-ChildItem $logs -File -Filter 'update-*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
    if ($setup) { "$($setup.Name)"; Get-Content $setup.FullName -Tail 25 }
} 12000
Section 'memory, disk, TCP' {
    "commit $([math]::Round(($os.TotalVirtualMemorySize - $os.FreeVirtualMemory) / 1MB, 1))/$([math]::Round($os.TotalVirtualMemorySize / 1MB, 1))G; C free $([math]::Round((Get-PSDrive C).Free / 1GB))G; D free $([math]::Round((Get-PSDrive D).Free / 1GB))G"
    [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpConnections() | Group-Object State | ForEach-Object { "$($_.Name)=$($_.Count)" }
} 2000
$text = $out.ToString() -replace 'gh[pousr]_[A-Za-z0-9]{20,}', '[redacted]' -replace '(?i)(bearer|token)\s+[A-Za-z0-9._-]{20,}', '$1 [redacted]' -replace 'eyJ[A-Za-z0-9._-]{30,}', '[redacted-jwt]'
if ($text.Length -gt 65000) { $text = $text.Substring(0, 65000) }
$body = @{ name = "diag $Label $($cfg.job)"; head_sha = $cfg.sha; status = 'completed'; conclusion = 'neutral'
           output = @{ title = "diag $Label"; summary = $summary; text = $text } } | ConvertTo-Json -Depth 5
$headers = @{ Authorization = "Bearer $($cfg.token)"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
$local = Join-Path $cfg.workspace "collected\diag-$Label.txt"
try { Set-Content -Path $local -Value $text -Encoding utf8NoBOM } catch { }
try {
    $r = Invoke-RestMethod -Method Post -Uri "https://api.github.com/repos/$($cfg.repo)/check-runs" -Headers $headers -Body $body -ContentType 'application/json'
    "posted check run $($r.id) ($($text.Length) chars): $summary"
} catch { "posting failed: $($_.Exception.Message)" }
