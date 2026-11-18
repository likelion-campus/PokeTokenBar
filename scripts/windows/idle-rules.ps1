# The idle gate's rules that work on what the app logged (dot-sourced by idle-gate.ps1; tested by idle-rules.tests.ps1 on fake and
# real lines, CI: .github/workflows/idle-rules.yml). No process, no window, no file but the log passed in.

# One WakeTrace list ("key:n,key:n"): a key may contain spaces (a window class such as "MSCTFIME UI"), never ',' or ':' before the count.
function ConvertFrom-WakeList([string]$List) {
    $h = @{}
    if ($List) {
        foreach ($pair in $List.Split(',')) {
            $at = $pair.LastIndexOf(':')
            if ($at -gt 0) { $h[$pair.Substring(0, $at)] = [int]$pair.Substring($at + 1) }
        }
    }
    return $h
}

# A `wake trace <label>:` line split by its key names. Until run 44297197674's follow-up the fields were matched as \S* each, and the
# IME window's class "MSCTFIME UI" (a space) made every line that named it fail to match: 17 of the gate's 32 windows (all plaza and
# popover-page windows, popover open/closed/kit/sprite) had no attribution in 14 runs of 14, and the page windows' "no clock" rule
# passed with nothing to look at.
function ConvertFrom-WakeLine([string]$Line) {
    $m = [regex]::Match($Line, 'wake trace (start|exit): loops=(\d+) messages_total=(\d+) messages=(.*?) timers=(.*?) sources=(.*?)\s*$')
    if (-not $m.Success) { return $null }
    return @{ label = $m.Groups[1].Value; loops = [int]$m.Groups[2].Value; total = [int]$m.Groups[3].Value
              messages = $m.Groups[4].Value; timers = $m.Groups[5].Value; sources = $m.Groups[6].Value }
}

function Get-WakeDiff([string]$x, [string]$y) {
    $hx = ConvertFrom-WakeList $x; $hy = ConvertFrom-WakeList $y; $out = [ordered]@{}
    foreach ($k in $hy.Keys) { $d = $hy[$k] - $(if ($hx.ContainsKey($k)) { $hx[$k] } else { 0 }); if ($d -gt 0) { $out[$k] = $d } }
    return $out.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { "$($_.Key):$($_.Value)" }
}

# The window's attribution: the difference between the snapshot at +28 s and the one at exit. Null when the pair is not there or does
# not parse (the caller fails the window then: a window measured with the trace on must be attributed).
function Get-WakeDeltaFromLines([string]$StartLine, [string]$ExitLine) {
    $a = ConvertFrom-WakeLine $StartLine; $b = ConvertFrom-WakeLine $ExitLine
    if (-not $a -or -not $b -or $a.label -ne 'start' -or $b.label -ne 'exit') { return $null }
    return [ordered]@{
        loops = $b.loops - $a.loops
        messages = $b.total - $a.total
        messageIds = @(Get-WakeDiff $a.messages $b.messages)
        timerIds = @(Get-WakeDiff $a.timers $b.timers)
        sources = @(Get-WakeDiff $a.sources $b.sources)
    }
}

function Get-WakeDelta([string]$LogFile) {
    $lines = @(Select-String -Path $LogFile -Pattern 'wake trace (start|exit):' -ErrorAction SilentlyContinue | Select-Object -Last 2 | ForEach-Object { $_.Line })
    if ($lines.Count -lt 2) { return $null }
    return Get-WakeDeltaFromLines $lines[0] $lines[1]
}

# The app's clock fires in a window (WakeTrace sources 'animationClock' and 'popoverClock').
function Get-ClockFires($Wake) {
    $fires = 0
    foreach ($src in @($Wake.sources)) { if ($src -match '^(animationClock|popoverClock):(\d+)$') { $fires += [int]$Matches[2] } }
    return $fires
}

# An animating window judged on the work the app did, not on how the runner scheduled it (follow-up of 44295198366: 823.5 main cs a
# minute over a budget of 800 with the same 1198 clock fires and 2397 messages as every other run; 14 runs spread 662-824):
# - the clock fires at most the GIF's own rate over the window (+10 s for the snapshots around it, +5) and at least 80 % of it (a clock
#   that stopped or slowed has nothing left to measure);
# - at most two messages per fire (the drawn part's and the label's WM_PAINT) + 10: a second timer, a repaint of another control per
#   frame or a posted message per frame each add one per fire;
# - main-thread switches only as a runaway catch ($MaxMainCsPerMin, ~1.2x the highest seen).
# Returns @{ ok; detail }. A missing attribution or rate fails: the window would not have been judged.
function Test-AnimatedWork($Wake, [double]$Rate, [int]$Seconds, [double]$MainCsPerMin, [double]$MaxMainCsPerMin) {
    if (-not $Wake) { return @{ ok = $false; detail = 'no wake attribution: the window could not be judged' } }
    if ($Rate -le 0) { return @{ ok = $false; detail = 'no GIF rate in the probe line: the window could not be judged' } }
    $fires = Get-ClockFires $Wake
    $most = [math]::Floor($Rate * ($Seconds + 10) + 5)
    $least = [math]::Ceiling($Rate * $Seconds * 0.8)
    $maxMessages = 2 * $fires + 10
    $bad = @()
    if ($fires -gt $most) { $bad += "clock fires $fires > $most (the GIF's $Rate/s over $Seconds s)" }
    if ($fires -lt $least) { $bad += "clock fires $fires < $least (80 % of the GIF's rate: the clock stopped or slowed)" }
    if ($Wake.messages -gt $maxMessages) { $bad += "messages $($Wake.messages) > $maxMessages (2 per fire + 10)" }
    if ($MainCsPerMin -gt $MaxMainCsPerMin) { $bad += "main cs/min $MainCsPerMin > $MaxMainCsPerMin (runaway)" }
    $text = "clock fires $fires (allowed $least-$most at $Rate/s), messages $($Wake.messages) (at most $maxMessages), main cs/min $MainCsPerMin (runaway over $MaxMainCsPerMin)"
    if ($bad.Count -gt 0) { return @{ ok = $false; detail = "$text; FAILED: $($bad -join '; ')" } }
    return @{ ok = $true; detail = $text }
}
