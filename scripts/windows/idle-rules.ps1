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

# Fires of the named WakeTrace sources in a window.
function Get-SourceFires($Wake, [string[]]$Names) {
    $fires = 0
    foreach ($src in @($Wake.sources)) {
        $at = $src.LastIndexOf(':')
        if ($at -gt 0 -and $Names -contains $src.Substring(0, $at)) { $fires += [int]$src.Substring($at + 1) }
    }
    return $fires
}

# A window that animates on a timer of its own (the floating pet: its GIF clock, the working agent's bob) judged on the work: the attributed
# fires within their band, at most two messages a fire + 10, and the main thread at most $CsPerFire switches a fire + $CsSlack over the
# window (one switch a fire is the work itself; a second timer, unattributed, adds switches without fires). Cycles are left to the
# runaway catch (pet-working read 3.09 M cycles/s against a budget of 2.6 M with its usual 145 main switches a minute: 44315731795).
function Test-TimerWork($Wake, [string[]]$Sources, [int]$MinFires, [int]$MaxFires, [int]$MainCs, [double]$CsPerFire = 1.5, [int]$CsSlack = 60) {
    if (-not $Wake) { return @{ ok = $false; detail = 'no wake attribution: the window could not be judged' } }
    $fires = Get-SourceFires $Wake $Sources
    $maxMessages = 2 * $fires + 10
    $maxCs = [math]::Floor($CsPerFire * $fires + $CsSlack)
    $bad = @()
    if ($fires -lt $MinFires -or $fires -gt $MaxFires) { $bad += "fires $fires outside $MinFires-$MaxFires" }
    if ($Wake.messages -gt $maxMessages) { $bad += "messages $($Wake.messages) > $maxMessages (2 per fire + 10)" }
    if ($MainCs -gt $maxCs) { $bad += "main cs $MainCs > $maxCs ($CsPerFire per fire + ${CsSlack}: work that is not the timer's)" }
    $text = "$($Sources -join '+') fires $fires (allowed $MinFires-$MaxFires), messages $($Wake.messages) (at most $maxMessages), main cs $MainCs (at most $maxCs)"
    if ($bad.Count -gt 0) { return @{ ok = $false; detail = "$text; FAILED: $($bad -join '; ')" } }
    return @{ ok = $true; detail = $text }
}

# The real Home page, open and left alone (`popover-open-120s`), judged on the work the app did, not on how the runner scheduled it. It was
# a main-thread budget of 6 a minute (12 in 120 s), and the same work reads 6-7 cs in 14 of 18 windows, 12-13 in 3 and 15 in 1 (18 windows in
# 18 runs, 2026-11-20..26: run 45744414650 failed at 15 = 7.5/min, 45542265924 at 13 = 6.5/min; 44868486165 and 45368918777 sat on 12). The
# work was identical in all 18: loops 7, messages 6 (PokeTokenBarPane 3, Static 2, the close PokeTokenBarSink 1), popoverClock 3 (the
# updated-ago text steps at +30 s, 2 s after the +28 s snapshot the window is diffed from). So:
# - popoverClock fires $MinFires-$MaxFires (3 in 18 of 18: a clock that stopped, or that fires on a second timer, leaves the band);
# - at most two messages per fire + 1 (the pane's repaint and the label's; 6 of 7 allowed at 3 fires);
# - message ids only from the three window classes the page has (a message to anything else is new work);
# - at most messages + 2 loop passes (a main-queue block or a posted message each adds a pass: 7 of 8 allowed);
# - main-thread switches only as a runaway catch at $MaxMainCsPerMin (2 x the highest seen, 7.5/min, N=18).
# What this does NOT see: a Foundation timer of its own (no message, no pass) that runs only while Home is open, with a period of about
# 5 s or more: it adds under 15 switches to a window whose floor is 6-13. Every other window (the app-wide ones, 20 of them) still carries the
# 6/min budget, and PR 4's unattributed-wake rule is what closes this one.
# Returns @{ ok; detail }. A missing attribution fails: the window would not have been judged.
function Test-StillWork($Wake, [double]$MainCsPerMin, [double]$MaxMainCsPerMin, [int]$MinFires = 2, [int]$MaxFires = 4,
                        [string[]]$AllowedClasses = @('PokeTokenBarPane', 'Static', 'PokeTokenBarSink')) {
    if (-not $Wake) { return @{ ok = $false; detail = 'no wake attribution: the window could not be judged' } }
    $fires = Get-SourceFires $Wake @('popoverClock')
    $maxMessages = 2 * $fires + 1
    $maxLoops = $Wake.messages + 2
    $strangers = @()
    foreach ($id in @($Wake.messageIds)) {
        $at = $id.LastIndexOf(':'); $name = if ($at -gt 0) { $id.Substring(0, $at) } else { $id }
        $class = if ($name.Contains('@')) { $name.Substring($name.IndexOf('@') + 1) } else { $name }
        if ($AllowedClasses -notcontains $class) { $strangers += $id }
    }
    $bad = @()
    if ($fires -lt $MinFires -or $fires -gt $MaxFires) { $bad += "popoverClock fires $fires outside $MinFires-$MaxFires" }
    if ($Wake.messages -gt $maxMessages) { $bad += "messages $($Wake.messages) > $maxMessages (2 per fire + 1)" }
    if ($strangers.Count -gt 0) { $bad += "messages to other windows: $($strangers -join ' ')" }
    if ($Wake.loops -gt $maxLoops) { $bad += "loop passes $($Wake.loops) > $maxLoops (messages + 2)" }
    if ($MainCsPerMin -gt $MaxMainCsPerMin) { $bad += "main cs/min $MainCsPerMin > $MaxMainCsPerMin (runaway)" }
    $text = "popoverClock fires $fires (allowed $MinFires-$MaxFires), messages $($Wake.messages) (at most $maxMessages), loops $($Wake.loops) (at most $maxLoops), message classes only $($AllowedClasses -join '/'), main cs/min $MainCsPerMin (runaway over $MaxMainCsPerMin)"
    if ($bad.Count -gt 0) { return @{ ok = $false; detail = "$text; FAILED: $($bad -join '; ')" } }
    return @{ ok = $true; detail = $text }
}

# A window's cycles split by whose they are (measure-idle.ps1). QueryProcessCycleTime counts the threads that have exited too, so the process
# figure is the sum of the threads alive at the end (read one by one: those are the app's own, judged against MaxLiveCyclesPerSec) and the rest,
# which are cycles of threads that were gone by the end (or could not be opened): one part of the process figure the gate cannot attribute.
# Run 44873075438: plaza-closed read 486,741 cycles/s against 450,000 with live threads at a normal 134,564/s and 352,178/s in 18 threads that
# exited during the window (22 -> 4 threads; the other 17 plaza-closed windows: 66-139 k/s gone).
# $ThreadCycles: the cycle deltas of the threads alive at the end. Returns @{ live; gone } in cycles per second.
function Get-CycleSplit([uint64]$ProcessCycles, [uint64[]]$ThreadCycles, [int]$Seconds) {
    $live = [uint64]0
    foreach ($c in @($ThreadCycles)) { $live += $c }
    $gone = if ($ProcessCycles -gt $live) { $ProcessCycles - $live } else { [uint64]0 }
    return @{ live = [math]::Round($live / $Seconds); gone = [math]::Round($gone / $Seconds) }
}

# The clock sources (`popoverClock`, `animationClock`) that fired in a window, as the WakeTrace lines name them. A page window standing still has
# none: the idle gate fails any window of the Collection's log (after the fixture phase guard) and every other page that has one.
function Get-PageClockSources($Wake) {
    if (-not $Wake) { return @() }
    return @($Wake.sources | Where-Object { $_ -match '^(popoverClock|animationClock):' })
}
