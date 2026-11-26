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
# number of hours, so the phase is the same in either.
function Get-FixturePhases([string]$FixtureFile) {
    $text = Get-Content -Raw -Path $FixtureFile
    $phases = [System.Collections.Generic.SortedSet[int]]::new()
    foreach ($m in [regex]::Matches($text, '"caughtAt"\s*:\s*(-?\d+(?:\.\d+)?)')) {
        $seconds = [math]::Floor([double]::Parse($m.Groups[1].Value, [cultureinfo]::InvariantCulture))
        [void]$phases.Add([int](($seconds % 3600 + 3600) % 3600))
    }
    return @($phases)
}

# Seconds to sleep before a measurement that runs for $Seconds from $Now, or 0 when it contains none of the instants at which a fixture text
# steps (one per phase per hour). Sleeps until $PastSeconds after the last instant it contains; a second pass covers an instant that the
# longer wait then reaches (fixtures with several phases). A start within $PastSeconds after an instant needs no wait.
function Get-FixturePhaseWait([datetime]$Now, [int]$Seconds, [int[]]$Phases, [int]$PastSeconds = 15) {
    if (-not $Phases -or $Phases.Count -eq 0) { return 0 }
    $start = [int64][math]::Floor(([datetimeoffset]$Now.ToUniversalTime()).ToUnixTimeSeconds())
    $at = $start
    for ($pass = 0; $pass -le $Phases.Count; $pass++) {
        $last = $null
        foreach ($p in $Phases) {
            $next = $at + ((($p - ($at % 3600)) % 3600 + 3600) % 3600)
            if ($next -le $at + $Seconds -and ($null -eq $last -or $next -gt $last)) { $last = $next }
        }
        if ($null -eq $last) { break }
        $at = $last + $PastSeconds
    }
    return [int]($at - $start)
}

# Sleeps past a fixture phase instant when the window starting now would contain one; prints a line saying so (dry run: $script:FixturePhaseDryRun).
function Wait-PastFixturePhase([string]$Label, [int]$Seconds, [int[]]$Phases, [datetime]$Now = (Get-Date)) {
    $wait = Get-FixturePhaseWait $Now ($Seconds + 30) $Phases
    if ($wait -gt 0) {
        Write-Host ("FIXTURE PHASE GUARD: window '{0}' ({1} s plus launch and margin) from {2:HH:mm:ss}Z would contain a fixture text change (phases past the hour: {3}); sleeping {4} s" -f $Label, $Seconds, $Now.ToUniversalTime(), (($Phases | ForEach-Object { '{0:00}:{1:00}' -f [math]::Floor($_ / 60), ($_ % 60) }) -join ', '), $wait)
        if (-not $script:FixturePhaseDryRun) { Start-Sleep -Seconds $wait }
    }
    return $wait
}
