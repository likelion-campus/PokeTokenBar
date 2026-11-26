# The app refreshes once a day at the local midnight (Platform/DayBoundary.swift: local calendar of the machine; the runner's
# zone is UTC). A 120 s idle window that contains it measures that refresh (run 43967277783: popover-home-still-120s, main
# 26.5 cs/min against a budget of 6). Dot-source it; the idle gate calls Wait-PastMidnight before each window.

# Seconds to sleep before a measurement that runs for $Seconds from $Now (launch + settle + window + margin are in $Seconds),
# or 0 when it does not contain the next local midnight. A start within $PastSeconds after a midnight needs no wait.
function Get-MidnightWait([datetime]$Now, [int]$Seconds, [int]$PastSeconds = 15) {
    $midnight = $Now.Date.AddDays(1)
    if ($Now.AddSeconds($Seconds) -lt $midnight) { return 0 }
    return [int][Math]::Ceiling(($midnight.AddSeconds($PastSeconds) - $Now).TotalSeconds)
}

# Sleeps past the midnight when the window starting now would contain it; prints a line saying so. $Seconds is the window
# plus the app's launch and the 30 s settle before it, plus 30 s of margin.
function Wait-PastMidnight([string]$Label, [int]$Seconds, [datetime]$Now = (Get-Date)) {
    $wait = Get-MidnightWait $Now ($Seconds + 30)
    if ($wait -gt 0) {
        Write-Host ("MIDNIGHT GUARD: window '{0}' ({1} s plus launch and margin) from {2:HH:mm:ss} would contain the local midnight; sleeping {3} s until 00:00:15" -f $Label, $Seconds, $Now, $wait)
        if (-not $script:MidnightDryRun) { Start-Sleep -Seconds $wait }
    }
    return $wait
}

# ---- the fixture's own clock (the same class as the midnight, run 45744414650)
# The Collection page's log shows each caught entry's age in whole hours once it is a day old (RelativeTimeText, coarse), so its popover clock
# fires when an entry's text steps: at the seconds past the hour that entry's `caughtAt` has. The fixture (idle-companion-state.json) was
# generated with all 40 entries at 13:20 past the hour (UTC), so a 120 s window that contains an hh:13:20 holds one clock fire and the
# repaint it causes (release run 45744414650, shard 4: 13 loops, 11 messages, popoverClock:1, main thread 24.0 M cycles against 0.9-1.4 M
# in the 17 other windows of 17 runs). The gate waits past that instant, as it does for the midnight, and requires 0 clock fires after.

# The distinct second-of-the-hour values of the fixture's `caughtAt` dates, read from the file (not written down here: a regenerated fixture
# moves them). `caughtAt` is a Foundation Date as JSON: seconds since 2001-01-01 UTC, which is 978307200 s before the Unix epoch, a whole
# number of hours, so the phase is the same in either. Fails loudly (throws) when the file is missing, has no `caughtAt`, or has a `caughtAt` that
# is not a number (an ISO string, a changed encoding): a guard that read nothing would wait 0 s and let the fire back in without a word.
function Get-FixturePhases([string]$FixtureFile) {
    if (-not (Test-Path -LiteralPath $FixtureFile)) { throw "fixture phase guard: the fixture '$FixtureFile' is missing" }
    $text = Get-Content -Raw -Path $FixtureFile
    $keys = [regex]::Matches($text, '"caughtAt"').Count
    $numbers = [regex]::Matches($text, '"caughtAt"\s*:\s*(-?\d+(?:\.\d+)?)\s*[,}\r\n]')
    if ($keys -eq 0) { throw "fixture phase guard: '$FixtureFile' has no caughtAt: the guard would read no phase and wait 0 s" }
    if ($numbers.Count -ne $keys) { throw "fixture phase guard: $($keys - $numbers.Count) of $keys caughtAt values in '$FixtureFile' are not plain numbers (seconds since 2001-01-01); the guard cannot read their phase" }
    $phases = [System.Collections.Generic.SortedSet[int]]::new()
    foreach ($m in $numbers) {
        $seconds = [math]::Floor([double]::Parse($m.Groups[1].Value, [cultureinfo]::InvariantCulture))
        [void]$phases.Add([int](($seconds % 3600 + 3600) % 3600))
    }
    return @($phases)
}

# Seconds to sleep before a measurement that runs for $Seconds from $Now, or 0 when it contains none of the instants at which a fixture text
# steps (one per phase per hour). Sleeps until $PastSeconds after the last instant it contains; further passes cover an instant that the
# longer wait then reaches (fixtures with several phases). A start within $PastSeconds after an instant needs no wait. Throws when $Phases is
# empty (a caller with no fixture does not call it) or when the wait would exceed $MaxWaitSeconds or the passes end with an instant still inside.
function Get-FixturePhaseWait([datetime]$Now, [int]$Seconds, [int[]]$Phases, [int]$PastSeconds = 15, [int]$MaxWaitSeconds = 600) {
    if (-not $Phases -or $Phases.Count -eq 0) { throw 'fixture phase guard: no phases to guard against' }
    $start = [int64][math]::Floor(([datetimeoffset]$Now.ToUniversalTime()).ToUnixTimeSeconds())
    $at = $start
    $settled = $false
    for ($pass = 0; $pass -le $Phases.Count; $pass++) {
        $last = $null
        foreach ($p in $Phases) {
            $next = $at + ((($p - ($at % 3600)) % 3600 + 3600) % 3600)
            if ($next -le $at + $Seconds -and ($null -eq $last -or $next -gt $last)) { $last = $next }
        }
        if ($null -eq $last) { $settled = $true; break }
        $at = $last + $PastSeconds
        if ($at - $start -gt $MaxWaitSeconds) { throw "fixture phase guard: staying clear of the fixture's text changes would take $($at - $start) s, over the cap of $MaxWaitSeconds s" }
    }
    if (-not $settled) { throw "fixture phase guard: after $($Phases.Count + 1) passes the window still contains a fixture text change" }
    return [int]($at - $start)
}

# Both wall-clock guards together: the midnight wait can move the start into a fixture instant's window, and the fixture wait into the midnight's,
# so they repeat until neither wants to wait (at most 6 rounds, and $MaxWaitSeconds in all). Returns the total seconds to sleep; $Phases $null or
# empty: the window has no fixture. Throws when it does not settle. Pure: the caller sleeps.
function Get-GuardsWait([datetime]$Now, [int]$Seconds, [int[]]$Phases, [int]$MaxWaitSeconds = 600) {
    $t = $Now; $total = 0
    for ($round = 0; $round -lt 6; $round++) {
        $p = if ($Phases -and $Phases.Count -gt 0) { Get-FixturePhaseWait $t $Seconds $Phases 15 $MaxWaitSeconds } else { 0 }
        $m = Get-MidnightWait $t $Seconds
        $w = [math]::Max($p, $m)
        if ($w -eq 0) { return $total }
        $total += $w
        if ($total -gt $MaxWaitSeconds) { throw "wall-clock guards: staying clear of the midnight and the fixture's text changes would take $total s, over the cap of $MaxWaitSeconds s" }
        $t = $t.AddSeconds($w)
    }
    throw 'wall-clock guards: the midnight and the fixture phase guards did not settle in 6 rounds'
}

# Sleeps past the local midnight and the fixture's text changes before a window of $Seconds (+30 s margin) that starts now; prints a line saying
# so (dry run: $script:GuardsDryRun). `$Phases` empty: a window without the fixture, only the midnight counts.
function Wait-PastGuards([string]$Label, [int]$Seconds, [int[]]$Phases, [datetime]$Now = (Get-Date)) {
    $wait = Get-GuardsWait $Now ($Seconds + 30) $Phases
    if ($wait -gt 0) {
        $at = if ($Phases -and $Phases.Count -gt 0) { ', fixture text changes at ' + (($Phases | ForEach-Object { '{0:00}:{1:00}' -f [math]::Floor($_ / 60), ($_ % 60) }) -join ', ') + ' past the hour' } else { '' }
        Write-Host ("WALL-CLOCK GUARD: window '{0}' ({1} s plus launch and margin) from {2:HH:mm:ss}Z would contain the local midnight or a fixture text change{3}; sleeping {4} s" -f $Label, $Seconds, $Now.ToUniversalTime(), $at, $wait)
        if (-not $script:GuardsDryRun) { Start-Sleep -Seconds $wait }
    }
    return $wait
}
