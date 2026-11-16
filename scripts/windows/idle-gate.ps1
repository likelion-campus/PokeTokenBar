# The idle gate of windows-app.yml (installed app, fixture data), one shard of three per runner: a window is 30 s of start-up plus
# its seconds, and the 17 windows took ~48 min in one job. -Shard 1: the sleeper baseline, manual-refresh-120s, normal-300s,
# plaza-visible/minimized. -Shard 2: kit, sprite, popover open/closed, Home seconds/minutes. -Shard 3: Home still, activity
# bars/heatmap, recap, companion wiggle/animated. Every window keeps its budget and its verdict; each shard writes
# idle-gate-<n>.json and fails when one of its windows does. Needs the install (silent-install.ps1), PTB_FIXTURE, PTB_VERSION.
param([Parameter(Mandatory)][ValidateRange(1, 3)][int]$Shard)
. "$PSScriptRoot/ci-helpers.ps1"
Get-Process PokeTokenBar -ErrorAction SilentlyContinue | Stop-Process -Force
$exe = Join-Path $PtbInstallDir 'PokeTokenBar.exe'
$env:CLAUDE_CONFIG_DIR = Join-Path $env:PTB_FIXTURE 'claude'
$verdicts = [ordered]@{}
# Which shard measures which window (the sleeper baseline is shard 1's). Every window of the one-job gate is in exactly one.
$shardOf = @{ 'manual-refresh-120s' = 1; 'normal-300s' = 1; 'plaza-visible-120s' = 1; 'plaza-minimized-120s' = 1
             'popover-kit-open-120s' = 2; 'popover-sprite-open-120s' = 2; 'popover-open-120s' = 2; 'popover-closed-120s' = 2; 'popover-home-seconds-120s' = 2; 'popover-home-minutes-120s' = 2
             'popover-home-still-120s' = 3; 'popover-activity-bars-120s' = 3; 'popover-activity-heatmap-120s' = 3; 'popover-recap-open-120s' = 3; 'popover-companion-wiggle-120s' = 3; 'popover-companion-animated-120s' = 3 }
$summary = [ordered]@{ version = $env:PTB_VERSION; runner = $env:ImageVersion; windows = [ordered]@{} }

# 1. A process that only sleeps, and explorer, over the same 120 s, before the app starts.
if ($Shard -eq 1) {
    $ps = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $sleeper = Start-Process -FilePath $ps -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 170' -PassThru
    Start-Sleep -Seconds 5
    ./scripts/windows/measure-idle.ps1 -ProcessId $sleeper.Id -Seconds 120 -Also explorer -Baseline -Label sleeper -Out idle-sleeper.json
    Stop-Process -Id $sleeper.Id -Force -ErrorAction SilentlyContinue
    $base = Get-Content idle-sleeper.json -Raw | ConvertFrom-Json
    $summary.sleeper = [ordered]@{ cyclesPerSec = $base.processCyclesPerSec; contextSwitchesPerMin = $base.contextSwitchesPerMin; explorerCycles = $base.explorerCycles; explorerContextSwitches = ($base.also | Where-Object name -eq 'explorer').contextSwitches }
}

# 2. The installed app, one window per state. Budgets are from the first measured runs, with margin (see the report).
function Measure-App([string]$Label, [int]$Seconds, [string]$Settings, [hashtable]$Budget, [string[]]$AppArgs = @()) {
    Remove-Item -ErrorAction SilentlyContinue $PtbPlist, "$PtbPlist.bak"
    if ($Settings) { Set-Content -Path $PtbPlist -Value $Settings -Encoding utf8NoBOM }
    $state = Join-Path $env:PTB_FIXTURE "state-idle-$Label"
    New-Item -ItemType Directory -Force -Path $state | Out-Null
    $env:PTB_STATE_DIR = $state
    $p, $h = Start-App $exe $AppArgs
    Start-Sleep -Seconds 30
    $m = @{ ProcessId = $p.Id; Seconds = $Seconds; Label = $Label; Out = "idle-$Label.json" }
    foreach ($k in $Budget.Keys) { $m[$k] = $Budget[$k] }
    $global:LASTEXITCODE = 0
    ./scripts/windows/measure-idle.ps1 @m
    $code = $LASTEXITCODE
    Close-App $p $h
    $verdicts[$Label] = ($code -eq 0)
    $j = Get-Content "idle-$Label.json" -Raw | ConvertFrom-Json
    $summary.windows[$Label] = [ordered]@{ seconds = $Seconds; pass = ($code -eq 0); budget = $Budget; processCycles = $j.processCycles; cyclesPerSec = $j.processCyclesPerSec; cpuSeconds = $j.processCpuSeconds; contextSwitchesPerMin = $j.contextSwitchesPerMin; mainThreadContextSwitches = $j.mainThreadContextSwitches; privateMB = "$($j.privateMBStart) -> $($j.privateMBEnd)"; handles = "$($j.handlesStart) -> $($j.handlesEnd)"; threads = @($j.threads | Where-Object { $_.contextSwitches -gt 0 } | Select-Object tid, main, name, start, contextSwitches, cycles) }
}
$off = '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>refreshInterval</key><real>0</real></dict></plist>'
$offNoStatus = '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>refreshInterval</key><real>0</real><key>statusChecksEnabled</key><false/></dict></plist>'
$noStatus = '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>statusChecksEnabled</key><false/></dict></plist>'
$budget = @{ MaxMainCsPerMin = 6; MaxProcessCsPerMin = 250; MaxProcessCyclesPerSec = 450000; MaxPrivateGrowthMB = 5; MaxHandleGrowth = 10 }
# refreshInterval = 0: nothing is due after the launch refresh (the D8 window), 120 s.
if ($shardOf['manual-refresh-120s'] -eq $Shard) { Measure-App 'manual-refresh-120s' 120 $off $budget }
# The normal app: 120 s polling, status checks on. 300 s from 30 s after launch covers the refreshes at +120 s and +240 s.
# Budgets: 1.5x the worst of 4 runs of the same code (d46c7b3, a78a992; status checks through WinHTTP, PlatformCompat.oneShotData):
# main thread 19-20/min (2.5/min idle + ~40 per refresh), process 166-186 cs/min and 1.39-2.03 M cycles/s (cycles spread ~1.5x
# run to run); private and handles are leak bounds.
# Before (URLSession): every refresh connected afresh and two dispatch threads woke each other 25-50k times a second for the
# whole transfer, 1568-7209 cs/min and 3.3-5.5 M cycles/s, under a budget of 4000 (defect log, "윈도우 URLSession"). One such
# refresh (>= 6k cs) now fails the cs budget on its own.
if ($shardOf['normal-300s'] -eq $Shard) { Measure-App 'normal-300s' 300 '' @{ MaxMainCsPerMin = 30; MaxProcessCsPerMin = 280; MaxProcessCyclesPerSec = 3000000; MaxPrivateGrowthMB = 5; MaxHandleGrowth = 10 } }
# Stage 6 Task 5: the plaza open (the selftest helper opens the app's own plaza; no team, nobody else in it), with
# refresh off as in the first window, so the difference to 'manual-refresh-120s' is the plaza's. On the runner the
# device is WARP (CPU rendering): every drawn frame is CPU time here that a GPU does on a PC.
$logFile = Join-Path $env:LOCALAPPDATA 'PokeTokenBar\Logs\PokeTokenBar.log'
foreach ($mode in 'visible', 'minimized') {
    $label = "plaza-$mode-120s"
    if ($shardOf[$label] -ne $Shard) { continue }
    # Budgets: 1.5x the worst of three runs (43697872729, 43702099267, 43706983988; stage 6 Task 5 report). Minimized
    # (main 396-410/min, process 3502-3575 cs/min, 5.3-6.8 M cycles/s): the frame clock is parked and the cover check off;
    # what wakes the app is the shared controller (1 s focus tick, 1 s watchdog, the ditto host's 50-250 ms loop, on the Mac
    # too). Visible, nobody walking (main 5030-9922/min, 64-78 k cs/min, 0.28-0.81 G cycles/s): WARP draws on the CPU here.
    # Visible, re-derived 2026-11-16 after `idle.processCsPerMin 131897 <= 117500` failed in run 43788143040 with the app unchanged:
    # the runner has no GPU, so WARP's rasterizer pool (nine workers, all starting at ntdll.dll+0x845d0) did 108 G of the
    # 130 G cycles and 105 k of the 132 k cs/min; our threads were main 12829 cs/min + 20.6 G cycles, the plaza clock thread
    # 4757 cs/min + 1.3 G (own total 18984 cs/min, 184 M cycles/s). So the process-wide figures measure the runner's software
    # renderer, which varies 2x between identical runs (cycles/s 553, 959, 1181, 959, 1079 M; n=5 plus this run). The app is
    # judged on its OWN threads (everything not starting at the WARP worker routine; main and clock thread are budgeted below at
    # ~2x the one sample, samples to date: main 5030-12829 cs/min over n=8) and the draw/present counts, which the selftest
    # `plaza.idleVisible` judges deterministically. The pool is reported as information. The process-wide bounds stay as a
    # runaway catch only (a URLSession-style storm was 1.5-3 M cs/min, a spinning thread adds ~3 G cycles/s on its own and shows
    # in the own-thread budget first): 3x the worst observed.
    $budgetPlaza = if ($mode -eq 'minimized') {
        @{ MaxMainCsPerMin = 615; MaxProcessCsPerMin = 5360; MaxProcessCyclesPerSec = 10300000; MaxPrivateGrowthMB = 5; MaxHandleGrowth = 10 }
    } else {
        @{ MaxMainCsPerMin = 26000; MaxProcessCsPerMin = 400000; MaxProcessCyclesPerSec = 4000000000; MaxOwnCsPerMin = 40000; MaxOwnCyclesPerSec = 450000000; OwnExcludeStart = 'ntdll.dll+0x845d0'; MaxPrivateGrowthMB = 5; MaxHandleGrowth = 10 }
    }
    Measure-App $label 120 $off $budgetPlaza @('--plaza-idle-probe', $mode)
    $lines = @(Select-String -Path $logFile -Pattern 'plaza idle helper|plaza open at exit|plaza window open|plaza window: not opened' -ErrorAction SilentlyContinue | Select-Object -Last 3 | ForEach-Object { $_.Line })
    $lines
    $summary.windows[$label].plazaLog = $lines
}
# --- stage 7 Task 3: the popover kit open and still (begin) ---
# The kit's gallery page (every control and a drawn part), focus in a field, refresh off: the same budget as the closed
# app's 'manual-refresh-120s' window (an open, idle popover may cost nothing more).
if ($shardOf['popover-kit-open-120s'] -eq $Shard) {
    Measure-App 'popover-kit-open-120s' 120 $off $budget @('--popover-kit-idle-probe')
    $summary.windows['popover-kit-open-120s'].kitLog = @(Select-String -Path $logFile -Pattern 'popover kit idle probe' -ErrorAction SilentlyContinue | Select-Object -Last 1 | ForEach-Object { $_.Line })
}
# --- stage 7 Task 3: the popover kit open and still (end) ---
# --- stage 7 Task 8: an animated sprite open (begin) ---
# The fixture GIF (5 frames at 0.1 s) in a drawn part, popover kit window open: the cost of an animating popover. The
# budget is loose (first numbers; Task 8 report): what it must show is that it is bounded and that nothing else wakes.
if ($shardOf['popover-sprite-open-120s'] -eq $Shard) {
    Measure-App 'popover-sprite-open-120s' 120 $off @{ MaxMainCsPerMin = 2400; MaxProcessCsPerMin = 6000; MaxProcessCyclesPerSec = 60000000; MaxPrivateGrowthMB = 5; MaxHandleGrowth = 10 } @('--popover-sprite-idle-probe')
    $summary.windows['popover-sprite-open-120s'].spriteLog = @(Select-String -Path $logFile -Pattern 'popover sprite idle probe' -ErrorAction SilentlyContinue | Select-Object -Last 1 | ForEach-Object { $_.Line })
}
# --- stage 7 Task 8: an animated sprite open (end) ---
# --- stage 7 Task 4: the popover window open and still, and closed after an open (begin) ---
# The real popover (empty page, opened through the tray callback), refresh off: the closed app's budget for both. Closed
# after an open must cost what never opened costs (D18); open and still adds no timer.
foreach ($mode in 'open', 'closed') {
    $label = "popover-$mode-120s"
    if ($shardOf[$label] -ne $Shard) { continue }
    Measure-App $label 120 $off $budget @('--popover-idle-probe', $mode)
    $probeLines = @(Select-String -Path $logFile -Pattern 'popover idle probe' -ErrorAction SilentlyContinue | Select-Object -Last 2 | ForEach-Object { $_.Line })
    $summary.windows[$label].popoverLog = $probeLines
    # The window measured what it says: open and never closed for 'open', closed once for 'closed' (the exit line).
    $exit = @($probeLines | Where-Object { $_ -match 'popover idle probe exit:' }) | Select-Object -Last 1
    $want = if ($mode -eq 'open') { 'open=true opens=1 closes=0' } else { 'open=false opens=1 closes=1' }
    $stateOK = $exit -and $exit -match [regex]::Escape($want)
    $summary.windows[$label].popoverState = if ($stateOK) { "ok: $want" } else { "WRONG: expected '$want' in '$exit'" }
    $verdicts[$label] = $verdicts[$label] -and $stateOK
}
# --- stage 7 Task 4: the popover window open and still, and closed after an open (end) ---
# --- stage 7 Task 5: the Home page open and left alone (begin) ---
# Sample data in a kit window (CI only): the relative texts moving at 30 s (updated 28.5 s ago), each minute (2 h), and
# nothing relative on screen. Reported next to the popover windows (the real Home page is 'popover-open-120s').
$homeBudgets = @{
    seconds = @{ MaxMainCsPerMin = 12; MaxProcessCsPerMin = 250; MaxProcessCyclesPerSec = 800000; MaxPrivateGrowthMB = 5; MaxHandleGrowth = 10 }
    minutes = @{ MaxMainCsPerMin = 12; MaxProcessCsPerMin = 250; MaxProcessCyclesPerSec = 800000; MaxPrivateGrowthMB = 5; MaxHandleGrowth = 10 }
    still = $budget
}
foreach ($mode in 'seconds', 'minutes', 'still') {
    $label = "popover-home-$mode-120s"
    if ($shardOf[$label] -ne $Shard) { continue }
    Measure-App $label 120 $off $homeBudgets[$mode] @('--popover-home-idle-probe', $mode)
    $summary.windows[$label].homeLog = @(Select-String -Path $logFile -Pattern 'popover home idle probe' -ErrorAction SilentlyContinue | Select-Object -Last 1 | ForEach-Object { $_.Line })
}
# --- stage 7 Task 5: the Home page open and left alone (end) ---
# --- stage 7 Task 12: the activity chart open and left alone (begin) ---
# A chart is static: opening it adds no timer, so it must cost what the open kit window costs (the closed app's budget).
foreach ($mode in 'bars', 'heatmap') {
    $label = "popover-activity-$mode-120s"
    if ($shardOf[$label] -ne $Shard) { continue }
    Measure-App $label 120 $off $budget @('--popover-activity-idle-probe', $mode)
    $summary.windows[$label].activityLog = @(Select-String -Path $logFile -Pattern 'popover activity idle probe' -ErrorAction SilentlyContinue | Select-Object -Last 1 | ForEach-Object { $_.Line })
}
# --- stage 7 Task 12: the activity chart open and left alone (end) ---
# --- stage 7 Task 13: the recap page open and left alone (begin) ---
# Sample data in a kit window (CI only): a static page, so the closed app's budget. Reported next to the Home page's.
if ($shardOf['popover-recap-open-120s'] -eq $Shard) {
    Measure-App 'popover-recap-open-120s' 120 $off $budget @('--popover-recap-idle-probe')
    $summary.windows['popover-recap-open-120s'].recapLog = @(Select-String -Path $logFile -Pattern 'popover recap idle probe' -ErrorAction SilentlyContinue | Select-Object -Last 1 | ForEach-Object { $_.Line })
}
# --- stage 7 Task 13: the recap page open and left alone (end) ---
# --- stage 7 Task 9: Home with the companion header open (begin) ---
# Sample data in a kit window (CI only), nothing relative on the page: 'wiggle' = the imminent egg with animation on (the
# bob, one wake per pixel step of the Mac's eased swing, and the wiggle's eased steps), 'animated' = Bulbasaur's GIF
# with animation on (loose, as Task 8's sprite window). The header standing still is popover-open-120s (the real Home,
# the runner's animations off); the bob alone measured 216.5 main cs/min in run 43889052204 (Task 9 report).
$companionBudgets = @{
    wiggle = @{ MaxMainCsPerMin = 2400; MaxProcessCsPerMin = 6000; MaxProcessCyclesPerSec = 60000000; MaxPrivateGrowthMB = 5; MaxHandleGrowth = 10 }
    animated = @{ MaxMainCsPerMin = 2400; MaxProcessCsPerMin = 6000; MaxProcessCyclesPerSec = 60000000; MaxPrivateGrowthMB = 5; MaxHandleGrowth = 10 }
}
foreach ($mode in 'wiggle', 'animated') {
    $label = "popover-companion-$mode-120s"
    if ($shardOf[$label] -ne $Shard) { continue }
    Measure-App $label 120 $off $companionBudgets[$mode] @('--popover-companion-idle-probe', $mode)
    $summary.windows[$label].companionLog = @(Select-String -Path $logFile -Pattern 'popover companion idle probe' -ErrorAction SilentlyContinue | Select-Object -Last 1 | ForEach-Object { $_.Line })
}
# --- stage 7 Task 9: Home with the companion header open (end) ---
# Every window of this shard ran (a label in $shardOf that never got measured would make the gate pass with a hole in it).
$expected = @($shardOf.Keys | Where-Object { $shardOf[$_] -eq $Shard })
$missing = @($expected | Where-Object { -not $verdicts.Contains($_) })
if ($missing.Count -gt 0) { throw "idle gate shard ${Shard}: not measured: $($missing -join ', ')" }
$summary.verdicts = $verdicts
$summary | ConvertTo-Json -Depth 8 | Set-Content "idle-gate-$Shard.json" -Encoding utf8
Get-Content "idle-gate-$Shard.json"
if ($verdicts.Values -contains $false) { throw "idle gate FAILED: $(($verdicts.GetEnumerator() | Where-Object { -not $_.Value } | ForEach-Object Key) -join ', ')" }
"PASS idle gate (shard $Shard of 3: $($expected.Count) windows)"
