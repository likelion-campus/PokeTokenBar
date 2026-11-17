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
