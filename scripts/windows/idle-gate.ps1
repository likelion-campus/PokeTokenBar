# The idle gate of windows-app.yml (installed app, fixture data), one shard of five per runner: a window is 30 s of start-up plus
# its seconds (the 17 windows of the first gate took ~48 min in one job). Which window runs in which shard: idle-shards.ps1.
# Every window keeps its budget and its verdict; each shard writes
# idle-gate-<n>.json and fails when one of its windows does. Needs the install (silent-install.ps1), PTB_FIXTURE, PTB_VERSION.
param([Parameter(Mandatory)][ValidateRange(1, 5)][int]$Shard)
. "$PSScriptRoot/ci-helpers.ps1"
. "$PSScriptRoot/midnight-guard.ps1"
. "$PSScriptRoot/idle-shards.ps1"
Get-Process PokeTokenBar -ErrorAction SilentlyContinue | Stop-Process -Force
$exe = Join-Path $PtbInstallDir 'PokeTokenBar.exe'
$env:CLAUDE_CONFIG_DIR = Join-Path $env:PTB_FIXTURE 'claude'
# One unmeasured launch first: on a runner that has only just booted the first app window reads about 1.5x the cost of the same
# window in a settled machine (162-200 process cs/min against 113-132, run 44007854843); the shell and the app's first-run files
# settle during this launch. Nothing of it is judged.
$env:PTB_STATE_DIR = Join-Path $env:PTB_FIXTURE 'state-idle-warmup'
New-Item -ItemType Directory -Force -Path $env:PTB_STATE_DIR | Out-Null
$wp, $wh = Start-App $exe
Start-Sleep -Seconds 60
# The first launch keeps the hatch base index in %LOCALAPPDATA%\PokeTokenBar\base-index.json (PokeAPI GraphQL: one request; its
# REST fallback: 649). Every later launch reads it from there; a launch that has to build it does so on worker threads inside its
# window. In run 44143290510 the GraphQL request always failed on Windows (WinHTTP 12044) and a slow PokeAPI kept the REST build
# going through three windows of shard 3 (67 M cycles/s, +504 handles). So the warm-up stays open until the file is there, up to
# 4 more minutes, and the summary says how long it took.
$baseIndex = Join-Path $env:LOCALAPPDATA 'PokeTokenBar\base-index.json'
$extra = 0
while (-not (Test-Path $baseIndex) -and $extra -lt 240) { Start-Sleep -Seconds 5; $extra += 5 }
Close-App $wp $wh
$warmup = if (Test-Path $baseIndex) { "base index on disk, $extra s past the 60 s" } else { "base index NOT on disk after 300 s: every measured launch builds it (PokeAPI slow or unreachable)" }
"warm-up launch done: $warmup"
$verdicts = [ordered]@{}
$summary = [ordered]@{ version = $env:PTB_VERSION; runner = $env:ImageVersion; windows = [ordered]@{} }
$summary.warmup = $warmup

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

# The measured launches count where their main-thread wakes come from (WakeTrace: messages by id, timers, the app's own sources); the warm-up
# launch above did not. Measure-App prints the difference between the snapshot at +28 s and the one at exit, per window.
$env:PTB_WAKE_TRACE = '1'
function ConvertFrom-WakeList([string]$List) {
    $h = @{}
    if ($List) { foreach ($pair in $List.Split(',')) { $k, $v = $pair.Split(':'); if ($k) { $h[$k] = [int]$v } } }
    return $h
}
function Get-WakeDelta([string]$LogFile) {
    $lines = @(Select-String -Path $LogFile -Pattern 'wake trace (start|exit):' -ErrorAction SilentlyContinue | Select-Object -Last 2 | ForEach-Object { $_.Line })
    if ($lines.Count -lt 2 -or $lines[0] -notmatch 'wake trace start:' -or $lines[1] -notmatch 'wake trace exit:') { return $null }
    $rx = 'loops=(\d+) messages_total=(\d+) messages=(\S*) timers=(\S*) sources=(\S*)\s*$'
    $a = [regex]::Match($lines[0], $rx); $b = [regex]::Match($lines[1], $rx)
    if (-not ($a.Success -and $b.Success)) { return $null }
    function Get-WakeDiff($x, $y) {
        $hx = ConvertFrom-WakeList $x; $hy = ConvertFrom-WakeList $y; $out = [ordered]@{}
        foreach ($k in $hy.Keys) { $d = $hy[$k] - $(if ($hx.ContainsKey($k)) { $hx[$k] } else { 0 }); if ($d -gt 0) { $out[$k] = $d } }
        return $out.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { "$($_.Key):$($_.Value)" }
    }
    return [ordered]@{
        loops = [int]$b.Groups[1].Value - [int]$a.Groups[1].Value
        messages = [int]$b.Groups[2].Value - [int]$a.Groups[2].Value
        messageIds = @(Get-WakeDiff $a.Groups[3].Value $b.Groups[3].Value)
        timerIds = @(Get-WakeDiff $a.Groups[4].Value $b.Groups[4].Value)
        sources = @(Get-WakeDiff $a.Groups[5].Value $b.Groups[5].Value)
    }
}
# The worker threads' side (WinHTTPFetch.Trace, the same switch and the same two points): fetches started and ended per host and
# the failed ones by URLError code. A window with refresh off should show none; run 44143290510 would have shown ~500 to pokeapi.co.
function Get-CountDiff([string]$x, [string]$y) {
    $hx = ConvertFrom-WakeList $x; $hy = ConvertFrom-WakeList $y; $out = [ordered]@{}
    foreach ($k in $hy.Keys) { $d = $hy[$k] - $(if ($hx.ContainsKey($k)) { $hx[$k] } else { 0 }); if ($d -gt 0) { $out[$k] = $d } }
    return $out.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { "$($_.Key):$($_.Value)" }
}
function Get-FetchDelta([string]$LogFile) {
    $lines = @(Select-String -Path $LogFile -Pattern 'fetch trace (start|exit):' -ErrorAction SilentlyContinue | Select-Object -Last 2 | ForEach-Object { $_.Line })
    if ($lines.Count -lt 2 -or $lines[0] -notmatch 'fetch trace start:' -or $lines[1] -notmatch 'fetch trace exit:') { return $null }
    $rx = 'started=(\d+) ended=(\d+) hosts=(\S*) failures=(\S*)\s*$'
    $a = [regex]::Match($lines[0], $rx); $b = [regex]::Match($lines[1], $rx)
    if (-not ($a.Success -and $b.Success)) { return $null }
    return [ordered]@{
        started = [int]$b.Groups[1].Value - [int]$a.Groups[1].Value
        ended = [int]$b.Groups[2].Value - [int]$a.Groups[2].Value
        hosts = @(Get-CountDiff $a.Groups[3].Value $b.Groups[3].Value)
        failures = @(Get-CountDiff $a.Groups[4].Value $b.Groups[4].Value)
    }
}

# 2. The installed app, one window per state. Budgets are from the first measured runs, with margin (see the report).
function Measure-App([string]$Label, [int]$Seconds, [string]$Settings, [hashtable]$Budget, [string[]]$AppArgs = @(), [string]$CompanionFixture = '') {
    # Before the launch: the launch and the 30 s settle are part of the measured sequence.
    $null = Wait-PastMidnight $Label ($Seconds + 40)
    Remove-Item -ErrorAction SilentlyContinue $PtbPlist, "$PtbPlist.bak"
    if ($Settings) { Set-Content -Path $PtbPlist -Value $Settings -Encoding utf8NoBOM }
    $state = Join-Path $env:PTB_FIXTURE "state-idle-$Label"
    New-Item -ItemType Directory -Force -Path $state | Out-Null
    $env:PTB_STATE_DIR = $state
    # The page windows start from a companion with a 40-species Pokédex (scripts/windows/fixtures, held by IdleGateFixtureTests).
    if ($CompanionFixture) { Copy-Item (Join-Path $PSScriptRoot "fixtures/$CompanionFixture") (Join-Path $state 'companion-state.json') -Force }
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
    $wake = Get-WakeDelta (Join-Path $env:LOCALAPPDATA 'PokeTokenBar\Logs\PokeTokenBar.log')
    if ($wake) { "WAKES ${Label}: loops=$($wake.loops) messages=$($wake.messages) ids=[$($wake.messageIds -join ' ')] timers=[$($wake.timerIds -join ' ')] sources=[$($wake.sources -join ' ')]" }
    $summary.windows[$Label] = [ordered]@{ wake = $wake; seconds = $Seconds; pass = ($code -eq 0); budget = $Budget; processCycles = $j.processCycles; cyclesPerSec = $j.processCyclesPerSec; cpuSeconds = $j.processCpuSeconds; contextSwitchesPerMin = $j.contextSwitchesPerMin; mainThreadContextSwitches = $j.mainThreadContextSwitches; privateMB = "$($j.privateMBStart) -> $($j.privateMBEnd)"; handles = "$($j.handlesStart) -> $($j.handlesEnd)"; threads = @($j.threads | Where-Object { $_.contextSwitches -gt 0 } | Select-Object tid, main, name, start, contextSwitches, cycles) }
    $fetches = Get-FetchDelta (Join-Path $env:LOCALAPPDATA 'PokeTokenBar\Logs\PokeTokenBar.log')
    if ($fetches) { "FETCHES ${Label}: started=$($fetches.started) ended=$($fetches.ended) hosts=[$($fetches.hosts -join ' ')] failures=[$($fetches.failures -join ' ')]" }
    $summary.windows[$Label].fetches = $fetches
}
$off = '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>refreshInterval</key><real>0</real></dict></plist>'
$offNoStatus = '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>refreshInterval</key><real>0</real><key>statusChecksEnabled</key><false/></dict></plist>'
$noStatus = '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>statusChecksEnabled</key><false/></dict></plist>'
$budget = @{ MaxMainCsPerMin = 6; MaxProcessCsPerMin = 250; MaxProcessCyclesPerSec = 450000; MaxPrivateGrowthMB = 5; MaxHandleGrowth = 10 }
# refreshInterval = 0: nothing is due after the launch refresh (the D8 window), 120 s.
if ((Test-InShard 'manual-refresh-120s' $Shard)) { Measure-App 'manual-refresh-120s' 120 $off $budget }
# The normal app: 120 s polling, status checks on. 300 s from 30 s after launch covers the refreshes at +120 s and +240 s.
# Budgets: 1.5x the worst of 4 runs of the same code (d46c7b3, a78a992; status checks through WinHTTP, PlatformCompat.oneShotData):
# main thread 19-20/min (2.5/min idle + ~40 per refresh), process 166-186 cs/min and 1.39-2.03 M cycles/s (cycles spread ~1.5x
# run to run); private and handles are leak bounds.
# Before (URLSession): every refresh connected afresh and two dispatch threads woke each other 25-50k times a second for the
# whole transfer, 1568-7209 cs/min and 3.3-5.5 M cycles/s, under a budget of 4000 (defect log, "윈도우 URLSession"). One such
# refresh (>= 6k cs) now fails the cs budget on its own.
if ((Test-InShard 'normal-300s' $Shard)) { Measure-App 'normal-300s' 300 '' @{ MaxMainCsPerMin = 30; MaxProcessCsPerMin = 280; MaxProcessCyclesPerSec = 3000000; MaxPrivateGrowthMB = 5; MaxHandleGrowth = 10 } }
# Stage 6 Task 5: the plaza open (the selftest helper opens the app's own plaza; no team, nobody else in it), with
# refresh off as in the first window, so the difference to 'manual-refresh-120s' is the plaza's. On the runner the
# device is WARP (CPU rendering): every drawn frame is CPU time here that a GPU does on a PC.
$logFile = Join-Path $env:LOCALAPPDATA 'PokeTokenBar\Logs\PokeTokenBar.log'
foreach ($mode in 'visible', 'minimized', 'closed', 'covered') {
    $label = "plaza-$mode-120s"
    if (-not (Test-InShard $label $Shard)) { continue }
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
    # closed (opened, then closed after 3 s): the closed app's budget, nothing of the plaza left running. covered (a topmost window over all
    # of it): the cover check parks the frame clock, so the minimized budget.
    $budgetPlaza = if ($mode -eq 'closed') { $budget } elseif ($mode -eq 'minimized' -or $mode -eq 'covered') {
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
if ((Test-InShard 'popover-kit-open-120s' $Shard)) {
    Measure-App 'popover-kit-open-120s' 120 $off $budget @('--popover-kit-idle-probe')
    $summary.windows['popover-kit-open-120s'].kitLog = @(Select-String -Path $logFile -Pattern 'popover kit idle probe' -ErrorAction SilentlyContinue | Select-Object -Last 1 | ForEach-Object { $_.Line })
}
# --- stage 7 Task 3: the popover kit open and still (end) ---
# --- stage 7 Task 8: an animated sprite open (begin) ---
# The fixture GIF (5 frames at 0.1 s) in a drawn part, popover kit window open: the cost of an animating popover. The
# budget is loose (first numbers; Task 8 report): what it must show is that it is bounded and that nothing else wakes.
if ((Test-InShard 'popover-sprite-open-120s' $Shard)) {
    Measure-App 'popover-sprite-open-120s' 120 $off @{ MaxMainCsPerMin = 800; MaxProcessCsPerMin = 6000; MaxProcessCyclesPerSec = 60000000; MaxPrivateGrowthMB = 5; MaxHandleGrowth = 10 } @('--popover-sprite-idle-probe')
    $summary.windows['popover-sprite-open-120s'].spriteLog = @(Select-String -Path $logFile -Pattern 'popover sprite idle probe' -ErrorAction SilentlyContinue | Select-Object -Last 1 | ForEach-Object { $_.Line })
}
# --- stage 7 Task 8: an animated sprite open (end) ---
# Object counts (D18). An open window is held to what it held when the probe had finished its navigation (GDI and USER flat: slack 2;
# kit controls and windows of ours: none). The closed window opens and closes twice: what is held after the first close (the first open
# builds fonts, the Direct2D device and window classes once: +18 GDI and +8 USER were measured against a never-opened popover) must be
# what is held at exit, after the second. A leak shows in every cycle; the one-time cost does not. The never-opened counts and the first
# cycle's are reported next to it. 'info' (the popover closed with a field focused) only reports.
function Test-PopoverObjects([string]$Label, [string[]]$Lines, [string]$Kind) {
    $exitLine = @($Lines | Where-Object { $_ -match 'popover idle probe exit:' }) | Select-Object -Last 1
    $beforeLine = @(Select-String -Path $logFile -Pattern 'popover idle probe before:' -ErrorAction SilentlyContinue | Select-Object -Last 1 | ForEach-Object { $_.Line }) | Select-Object -First 1
    $cycleLine = @(Select-String -Path $logFile -Pattern 'popover idle probe cycle1:' -ErrorAction SilentlyContinue | Select-Object -Last 1 | ForEach-Object { $_.Line }) | Select-Object -First 1
    $openLine = @($Lines | Where-Object { $_ -match 'popover idle probe: mode=' }) | Select-Object -Last 1
    function Get-Counts([string]$l) { $h = @{}; foreach ($k in 'gdi', 'user', 'windows', 'controls') { if ($l -match "\b$k=(\d+)") { $h[$k] = [int]$Matches[1] } }; return $h }
    $fmt = { param($h) (($h.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' ') }
    if (-not $exitLine) { $summary.windows[$Label].objects = 'not logged'; return }
    $b1 = Get-Counts $exitLine
    $text = "at exit $(& $fmt $b1)"
    if ($beforeLine) { $text = "never opened $(& $fmt (Get-Counts $beforeLine)); $text" }
    $ref = $null; $slack = @{ gdi = 2; user = 2; windows = 0; controls = 0 }
    if ($Kind -eq 'cycled' -and $cycleLine) { $ref = Get-Counts $cycleLine; $text = "after the first close $(& $fmt $ref); $text" }
    elseif ($Kind -eq 'open' -and $openLine) { $ref = Get-Counts $openLine; $text = "page reached $(& $fmt $ref); $text" }
    $bad = @()
    if ($ref) { $bad = @($b1.Keys | Where-Object { $ref.ContainsKey($_) -and $b1[$_] -gt $ref[$_] + $slack[$_] }) }
    $summary.windows[$Label].objects = "$text; over slack: $($bad -join ',')"
    $verdicts[$Label] = $verdicts[$Label] -and ($bad.Count -eq 0)
}
# --- stage 7 Task 4: the popover window open and still, and closed after an open (begin) ---
# The real popover (empty page, opened through the tray callback), refresh off: the closed app's budget for both. Closed
# after an open must cost what never opened costs (D18); open and still adds no timer.
foreach ($mode in 'open', 'closed') {
    $label = "popover-$mode-120s"
    if (-not (Test-InShard $label $Shard)) { continue }
    Measure-App $label 120 $off $budget @('--popover-idle-probe', $mode)
    $probeLines = @(Select-String -Path $logFile -Pattern 'popover idle probe' -ErrorAction SilentlyContinue | Select-Object -Last 2 | ForEach-Object { $_.Line })
    $summary.windows[$label].popoverLog = $probeLines
    # The window measured what it says: open and never closed for 'open', closed once for 'closed' (the exit line).
    $exit = @($probeLines | Where-Object { $_ -match 'popover idle probe exit:' }) | Select-Object -Last 1
    $want = if ($mode -eq 'open') { 'open=true opens=1 closes=0' } else { 'open=false opens=2 closes=2' }
    $stateOK = $exit -and $exit -match [regex]::Escape($want)
    $summary.windows[$label].popoverState = if ($stateOK) { "ok: $want" } else { "WRONG: expected '$want' in '$exit'" }
    $verdicts[$label] = $verdicts[$label] -and $stateOK
    Test-PopoverObjects $label $probeLines $(if ($mode -eq 'closed') { 'cycled' } else { 'open' })
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
    if (-not (Test-InShard $label $Shard)) { continue }
    Measure-App $label 120 $off $homeBudgets[$mode] @('--popover-home-idle-probe', $mode)
    $summary.windows[$label].homeLog = @(Select-String -Path $logFile -Pattern 'popover home idle probe' -ErrorAction SilentlyContinue | Select-Object -Last 1 | ForEach-Object { $_.Line })
}
# --- stage 7 Task 5: the Home page open and left alone (end) ---
# --- stage 7 Task 12: the activity chart open and left alone (begin) ---
# A chart is static: opening it adds no timer, so it must cost what the open kit window costs (the closed app's budget).
foreach ($mode in 'bars', 'heatmap') {
    $label = "popover-activity-$mode-120s"
    if (-not (Test-InShard $label $Shard)) { continue }
    Measure-App $label 120 $off $budget @('--popover-activity-idle-probe', $mode)
    $summary.windows[$label].activityLog = @(Select-String -Path $logFile -Pattern 'popover activity idle probe' -ErrorAction SilentlyContinue | Select-Object -Last 1 | ForEach-Object { $_.Line })
}
# --- stage 7 Task 12: the activity chart open and left alone (end) ---
# --- stage 7 Task 13: the recap page open and left alone (begin) ---
# Sample data in a kit window (CI only): a static page, so the closed app's budget. Reported next to the Home page's.
if ((Test-InShard 'popover-recap-open-120s' $Shard)) {
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
    animated = @{ MaxMainCsPerMin = 800; MaxProcessCsPerMin = 6000; MaxProcessCyclesPerSec = 60000000; MaxPrivateGrowthMB = 5; MaxHandleGrowth = 10 }
}
foreach ($mode in 'wiggle', 'animated') {
    $label = "popover-companion-$mode-120s"
    if (-not (Test-InShard $label $Shard)) { continue }
    Measure-App $label 120 $off $companionBudgets[$mode] @('--popover-companion-idle-probe', $mode)
    $summary.windows[$label].companionLog = @(Select-String -Path $logFile -Pattern 'popover companion idle probe' -ErrorAction SilentlyContinue | Select-Object -Last 1 | ForEach-Object { $_.Line })
}
# --- stage 7 Task 9: Home with the companion header open (end) ---
# --- stage 7 idle gates: the popover's pages open and left alone (begin) ---
# The REAL popover of the installed app (opened as the tray does), taken to one page and left alone, refresh off, the companion with a
# 40-species Pokédex. A page standing still adds no timer, so all of them cost what the closed app costs (`$budget`: 6 main-thread
# switches a minute). The focused-field windows: the Collection's search field has the keyboard. Windows' caret blinks only for its
# caret timeout (5 s) after the last input, and the window is measured from 30 s after the launch, so a focused field must cost the same;
# `focus-left` (the keyboard moved to the tab strip) and `focus-closed` (the popover closed with the field focused) are the same budget
# and prove nothing is left running when focus leaves.
foreach ($page in 'settings', 'shop', 'bag', 'collection', 'collection-log', 'detail', 'focus-search', 'focus-left', 'focus-closed') {
    $label = "popover-page-$page-120s"
    if (-not (Test-InShard $label $Shard)) { continue }
    Measure-App $label 120 $off $budget @('--popover-idle-probe', $page) 'idle-companion-state.json'
    $lines = @(Select-String -Path $logFile -Pattern 'popover idle probe|popover page probe' -ErrorAction SilentlyContinue | Select-Object -Last 3 | ForEach-Object { $_.Line })
    $summary.windows[$label].pageLog = $lines
    $exit = @($lines | Where-Object { $_ -match 'popover idle probe exit:' }) | Select-Object -Last 1
    $want = if ($page -eq 'focus-closed') { 'open=false opens=1 closes=1' } else { 'open=true opens=1 closes=0' }
    $stateOK = $exit -and $exit -match [regex]::Escape($want)
    $summary.windows[$label].popoverState = if ($stateOK) { "ok: $want" } else { "WRONG: expected '$want' in '$exit'" }
    $verdicts[$label] = $verdicts[$label] -and $stateOK
    Test-PopoverObjects $label $lines $(if ($page -eq 'focus-closed') { 'info' } else { 'open' })
    # No timer: a page standing still arms none (the Collection's log has its relative-time clock; every other page has no clock at all).
    $w = $summary.windows[$label].wake
    $clocks = if ($w) { @($w.sources | Where-Object { $_ -match '^(popoverClock|animationClock):' }) } else { @() }
    $summary.windows[$label].clockFires = $clocks
    if ($page -ne 'collection-log' -and $clocks.Count -gt 0) { $verdicts[$label] = $false }
}
# --- stage 7 idle gates (end) ---
# --- stage 7 Task 22: the floating pet (begin) ---
# One pet over sample stores (`--pet-idle-probe`, CI only; the app's own pet stays off), refresh off. 'still': an egg, no GIF;
# 'hidden': a pet shown for 3 s and turned off ~25 s before the window: the closed app's budget for both (a pet that is still
# or gone may cost nothing). 'animated': the raised sample's FIXTURE GIF (13 frames once capped) at the default "Power saver"
# floor of 0.4 s, with the runner's "Show animations" off, which stops no GIF of the pet (it follows the Mac's Reduce Motion
# rule, user ruling 2026-11-18; the probe logs the setting). Its budget is from one measured run (scratch
# run 44039613803: main 196/min = 150 frame wakes + 46, process 309 cs/min, 1.59 M cycles/s): main 270/min stays under one wake
# per 0.2 s ("Balanced", 300/min on its own), so a frame floor that is not applied fails; process cs 1.5x, cycles ~1.9x (the
# cycles of one window spread ~1.5x run to run, see normal-300s). Each window checks the probe's own line: what it measured.
$petBudgets = @{
    still = $budget
    animated = @{ MaxMainCsPerMin = 270; MaxProcessCsPerMin = 470; MaxProcessCyclesPerSec = 3000000; MaxPrivateGrowthMB = 5; MaxHandleGrowth = 10 }
    hidden = $budget
}
$petWant = @{
    still = 'mode=still shown=true window=true picture=loaded .* clock armed=false'
    animated = 'mode=animated shown=true window=true picture=loaded gif frames=([2-9]|\d\d+) .* clock armed=true'
    hidden = 'mode=hidden shown=true window=false'
}
# Object counts (D18, as the popover windows): what the app holds at exit against what it held once the pet stood (the probe's line:
# GDI and USER slack 2, windows of ours and kit controls none). A missing line fails: the window would not have been checked.
function Test-PetObjects([string]$Label, [string[]]$Lines) {
    function Get-Counts([string]$l) { $h = @{}; foreach ($k in 'gdi', 'user', 'windows', 'controls') { if ($l -match "\b$k=(\d+)") { $h[$k] = [int]$Matches[1] } }; return $h }
    $fmt = { param($h) (($h.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' ') }
    $stood = @($Lines | Where-Object { $_ -match 'pet idle probe: mode=' }) | Select-Object -Last 1
    $exitLine = @($Lines | Where-Object { $_ -match 'pet idle probe exit:' }) | Select-Object -Last 1
    if (-not $stood -or -not $exitLine) { $summary.windows[$Label].objects = 'not logged'; $verdicts[$Label] = $false; return }
    $ref = Get-Counts $stood; $end = Get-Counts $exitLine
    $slack = @{ gdi = 2; user = 2; windows = 0; controls = 0 }
    $bad = @($end.Keys | Where-Object { $ref.ContainsKey($_) -and $end[$_] -gt $ref[$_] + $slack[$_] })
    $summary.windows[$Label].objects = "pet stood $(& $fmt $ref); at exit $(& $fmt $end); over slack: $($bad -join ',')"
    $verdicts[$Label] = $verdicts[$Label] -and ($bad.Count -eq 0)
}
# Clock fires (the wake attribution's 'animationClock' / 'popoverClock', from +28 s to exit): none for a still or a hidden pet; for the
# animated one the GIF's frames at the 0.4 s floor (at most 2.5 a second over ~125 s: about 310; frames the cap merged last longer),
# 180-400 (an unapplied floor fires at the GIF's own 50-100 ms frames: 1250 or more; the main thread measured 326 wakes in all).
$petClockFires = @{ still = @(0, 0); hidden = @(0, 0); animated = @(180, 400) }
foreach ($mode in 'still', 'animated', 'hidden') {
    $label = "pet-$mode-120s"
    if (-not (Test-InShard $label $Shard)) { continue }
    Measure-App $label 120 $off $petBudgets[$mode] @('--pet-idle-probe', $mode)
    $lines = @(Select-String -Path $logFile -Pattern 'pet idle probe' -ErrorAction SilentlyContinue | Select-Object -Last 2 | ForEach-Object { $_.Line })
    $summary.windows[$label].petLog = $lines
    $line = @($lines | Where-Object { $_ -match 'pet idle probe: mode=' }) | Select-Object -Last 1
    $stateOK = [bool]$line -and $line -match $petWant[$mode]
    $summary.windows[$label].petState = if ($stateOK) { "ok: $($petWant[$mode])" } else { "WRONG: expected /$($petWant[$mode])/ in '$line'" }
    $verdicts[$label] = $verdicts[$label] -and $stateOK
    Test-PetObjects $label $lines
    $w = $summary.windows[$label].wake
    if ($w) {
        $fires = 0
        foreach ($src in $w.sources) { if ($src -match '^(animationClock|popoverClock):(\d+)$') { $fires += [int]$Matches[2] } }
        $range = $petClockFires[$mode]
        $summary.windows[$label].clockFires = "$fires (expected $($range[0])-$($range[1]))"
        if ($fires -lt $range[0] -or $fires -gt $range[1]) { $verdicts[$label] = $false }
    }
}
# --- stage 7 Task 22 (end) ---
# Every window of this shard ran (a label in $IdleShardOf that never got measured would make the gate pass with a hole in it).
$expected = @($IdleShardOf.Keys | Where-Object { $IdleShardOf[$_] -eq $Shard })
$missing = @($expected | Where-Object { -not $verdicts.Contains($_) })
if ($missing.Count -gt 0) { throw "idle gate shard ${Shard}: not measured: $($missing -join ', ')" }
$summary.verdicts = $verdicts
$summary | ConvertTo-Json -Depth 8 | Set-Content "idle-gate-$Shard.json" -Encoding utf8
Get-Content "idle-gate-$Shard.json"
if ($verdicts.Values -contains $false) { throw "idle gate FAILED: $(($verdicts.GetEnumerator() | Where-Object { -not $_.Value } | ForEach-Object Key) -join ', ')" }
"PASS idle gate (shard $Shard of 5: $($expected.Count) windows)"
