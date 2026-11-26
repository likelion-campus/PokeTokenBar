# Tests of idle-rules.ps1 against real app-log lines and the numbers of 14 full runs (CI: .github/workflows/idle-rules.yml; no app).
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/idle-rules.ps1"
$script:failed = 0; $script:count = 0
function Check([bool]$ok, [string]$what) { $script:count++; if ($ok) { "PASS $what" } else { $script:failed++; "FAIL $what" } }

# ---- the wake attribution parses a line that names a window class with a space (kit/pc-14 run 44297197674, idle shards 2, 3 and 5)
$lines = @{
    'plaza-closed' = @('[2026-11-18T12:08:48Z] wake trace start: loops=1223 messages_total=201 messages=0x8050@PokeTokenBarPlaza:190,0x113@MSCTFIME UI:2,0x113@PokeTokenBarPlaza:2,0x200@PokeTokenBarPlaza:1,0x31f@PokeTokenBarPlaza:1,0x31f@PokeTokenBarSink:1,0x8051@PokeTokenBarPlaza:1,0xc072@PokeTokenBarPlaza:1,0xf@PokeTokenBarPlaza:1,0xf@PokeTokenBarPlazaChatHost:1 timers=id1:2,id1347699472:2 sources=',
        '[2026-11-18T12:10:51Z] wake trace exit: loops=1238 messages_total=202 messages=0x8050@PokeTokenBarPlaza:190,0x113@MSCTFIME UI:2,0x113@PokeTokenBarPlaza:2,0x10@PokeTokenBarSink:1,0x200@PokeTokenBarPlaza:1,0x31f@PokeTokenBarPlaza:1,0x31f@PokeTokenBarSink:1,0x8051@PokeTokenBarPlaza:1,0xc072@PokeTokenBarPlaza:1,0xf@PokeTokenBarPlaza:1,0xf@PokeTokenBarPlazaChatHost:1 timers=id1:2,id1347699472:2 sources=')
    'sprite-open' = @('[2026-11-18T12:11:13Z] wake trace start: loops=456 messages_total=242 messages=0xf@PokeTokenBarDrawn:230,0xf@Static:4,0x60@SystemUserAdapterWindowClass:2,0x113@-:1,0x113@MSCTFIME UI:1,0x31f@PokeTokenBarSink:1,0xf@PokeTokenBarKitTest:1,0xf@PokeTokenBarPane:1,0xf@PokeTokenBarScroll:1 timers=id1:1,id32723:1 sources=animationClock:228,stackLayout:1',
        '[2026-11-18T12:13:15Z] wake trace exit: loops=1683 messages_total=1464 messages=0xf@PokeTokenBarDrawn:1451,0xf@Static:4,0x60@SystemUserAdapterWindowClass:2,0x10@PokeTokenBarSink:1,0x113@-:1,0x113@MSCTFIME UI:1,0x31f@PokeTokenBarSink:1,0xf@PokeTokenBarKitTest:1,0xf@PokeTokenBarPane:1,0xf@PokeTokenBarScroll:1 timers=id1:1,id32723:1 sources=animationClock:1449,stackLayout:1')
    'companion-animated' = @('[2026-11-18T12:21:18Z] wake trace start: loops=755 messages_total=544 messages=0xf@Static:275,0xf@PokeTokenBarDrawn:249,0xf@Button:10,0xf@PokeTokenBarPane:5,0x113@-:2,0x31f@PokeTokenBarSink:1,0xf@PokeTokenBarKitTest:1,0xf@PokeTokenBarScroll:1 timers=id32724:1,id32725:1 sources=animationClock:244,stackLayout:3,activityApply:1,companionApply:1,homeApply:1',
        '[2026-11-18T12:23:20Z] wake trace exit: loops=3149 messages_total=2937 messages=0xf@Static:1471,0xf@PokeTokenBarDrawn:1445,0xf@Button:10,0xf@PokeTokenBarPane:5,0x113@-:2,0x10@PokeTokenBarSink:1,0x31f@PokeTokenBarSink:1,0xf@PokeTokenBarKitTest:1,0xf@PokeTokenBarScroll:1 timers=id32724:1,id32725:1 sources=animationClock:1440,stackLayout:3,activityApply:1,companionApply:1,homeApply:1')
}
Check (($lines['plaza-closed'][0] -match '@MSCTFIME UI:') -and ($lines['sprite-open'][0] -match '@MSCTFIME UI:')) 'the plaza and sprite fixtures name the IME window class with its space'
$oldRx = 'loops=(\d+) messages_total=(\d+) messages=(\S*) timers=(\S*) sources=(\S*)\s*$'
foreach ($k in $lines.Keys) {
    $start, $exit = $lines[$k]
    if ($start -match '@MSCTFIME UI:' -or $exit -match '@MSCTFIME UI:') {
        Check (-not ([regex]::Match($start, $oldRx).Success -and [regex]::Match($exit, $oldRx).Success)) "${k}: the old \S* pattern does not match a line naming 'MSCTFIME UI' (why 17 windows had no attribution)"
    }
    Check ($null -ne (Get-WakeDeltaFromLines $start $exit)) "${k}: the lines parse by their key names"
}
$plaza = Get-WakeDeltaFromLines $lines['plaza-closed'][0] $lines['plaza-closed'][1]
Check ($plaza.loops -eq 15 -and $plaza.messages -eq 1 -and ($plaza.messageIds -join ' ') -eq '0x10@PokeTokenBarSink:1') "plaza-closed: 15 loops, the one message is the close (got loops=$($plaza.loops) messages=$($plaza.messages) ids=$($plaza.messageIds -join ' '))"
$sprite = Get-WakeDeltaFromLines $lines['sprite-open'][0] $lines['sprite-open'][1]
Check ((Get-ClockFires $sprite) -eq 1221 -and $sprite.messages -eq 1222) "sprite-open: 1221 clock fires and 1222 messages (got $(Get-ClockFires $sprite), $($sprite.messages))"
$companion = Get-WakeDeltaFromLines $lines['companion-animated'][0] $lines['companion-animated'][1]
Check ((Get-ClockFires $companion) -eq 1196 -and $companion.messages -eq 2393) "companion-animated: 1196 clock fires and 2393 messages (got $(Get-ClockFires $companion), $($companion.messages))"
Check ((ConvertFrom-WakeList '0x113@MSCTFIME UI:2,id1:3')['0x113@MSCTFIME UI'] -eq 2) 'a list key with a space keeps its count'
Check ($null -eq (Get-WakeDeltaFromLines $lines['sprite-open'][1] $lines['sprite-open'][0])) 'exit before start is no pair'
Check ($null -eq (Get-WakeDeltaFromLines '' $lines['sprite-open'][1])) 'a missing start line is no attribution (the gate fails such a window)'

# ---- the animated windows: all 14 runs of 2026-11-17/18 pass (fires, messages, main cs a minute; GIF rate 10/s, 120 s windows)
$runs = @(
    [pscustomobject]@{ run = '44198847690'; label = 'popover-companion-animated-120s'; fires = 1197; messages = 2395; main = 665.5 }
    [pscustomobject]@{ run = '44198847690'; label = 'popover-sprite-open-120s'; fires = 1222; messages = 1223; main = 624.5 }
    [pscustomobject]@{ run = '44200348337'; label = 'popover-companion-animated-120s'; fires = 1198; messages = 2397; main = 713.5 }
    [pscustomobject]@{ run = '44226306535'; label = 'popover-companion-animated-120s'; fires = 1198; messages = 2397; main = 733.5 }
    [pscustomobject]@{ run = '44226306535'; label = 'popover-sprite-open-120s'; fires = 1221; messages = 1222; main = 658.5 }
    [pscustomobject]@{ run = '44234159408'; label = 'popover-companion-animated-120s'; fires = 1198; messages = 2397; main = 678.5 }
    [pscustomobject]@{ run = '44234159408'; label = 'popover-sprite-open-120s'; fires = 1222; messages = 1223; main = 682.0 }
    [pscustomobject]@{ run = '44234221854'; label = 'popover-companion-animated-120s'; fires = 1198; messages = 2397; main = 799.0 }
    [pscustomobject]@{ run = '44234221854'; label = 'popover-sprite-open-120s'; fires = 1222; messages = 1223; main = 685.0 }
    [pscustomobject]@{ run = '44236491001'; label = 'popover-companion-animated-120s'; fires = 1197; messages = 2395; main = 721.5 }
    [pscustomobject]@{ run = '44236491001'; label = 'popover-sprite-open-120s'; fires = 1222; messages = 1223; main = 760.0 }
    [pscustomobject]@{ run = '44243968506'; label = 'popover-companion-animated-120s'; fires = 1198; messages = 2397; main = 723.5 }
    [pscustomobject]@{ run = '44243968506'; label = 'popover-sprite-open-120s'; fires = 1222; messages = 1223; main = 633.5 }
    [pscustomobject]@{ run = '44260112940'; label = 'popover-companion-animated-120s'; fires = 1198; messages = 2397; main = 666.0 }
    [pscustomobject]@{ run = '44260112940'; label = 'popover-sprite-open-120s'; fires = 1221; messages = 1222; main = 680.0 }
    [pscustomobject]@{ run = '44260120260'; label = 'popover-companion-animated-120s'; fires = 1196; messages = 2393; main = 662.0 }
    [pscustomobject]@{ run = '44260120260'; label = 'popover-sprite-open-120s'; fires = 1221; messages = 1222; main = 706.0 }
    [pscustomobject]@{ run = '44270933756'; label = 'popover-companion-animated-120s'; fires = 1197; messages = 2395; main = 680.0 }
    [pscustomobject]@{ run = '44270933756'; label = 'popover-sprite-open-120s'; fires = 1222; messages = 1223; main = 692.0 }
    [pscustomobject]@{ run = '44273690919'; label = 'popover-companion-animated-120s'; fires = 1198; messages = 2397; main = 672.5 }
    [pscustomobject]@{ run = '44273690919'; label = 'popover-sprite-open-120s'; fires = 1222; messages = 1223; main = 696.0 }
    [pscustomobject]@{ run = '44293514305'; label = 'popover-companion-animated-120s'; fires = 1198; messages = 2397; main = 752.5 }
    [pscustomobject]@{ run = '44293514305'; label = 'popover-sprite-open-120s'; fires = 1221; messages = 1222; main = 671.5 }
    [pscustomobject]@{ run = '44295198366'; label = 'popover-companion-animated-120s'; fires = 1198; messages = 2397; main = 823.5 }
    [pscustomobject]@{ run = '44295198366'; label = 'popover-sprite-open-120s'; fires = 1222; messages = 1223; main = 662.0 }
    [pscustomobject]@{ run = '44297197674'; label = 'popover-companion-animated-120s'; fires = 1196; messages = 2393; main = 692.5 }
    [pscustomobject]@{ run = '44297197674'; label = 'popover-sprite-open-120s'; fires = 1221; messages = 1222; main = 637.0 }
    [pscustomobject]@{ run = '44200348337'; label = 'popover-sprite-open-120s'; fires = 1221; messages = 1222; main = 747.0 }
)
Check ($runs.Count -eq 28) "the table has the 14 runs of both windows (got $($runs.Count))"
foreach ($r in $runs) {
    $wake = @{ messages = $r.messages; sources = @("animationClock:$($r.fires)") }
    $v = Test-AnimatedWork $wake 10 120 $r.main 1000
    Check $v.ok "run $($r.run) $($r.label) passes: $($v.detail)"
}
# ---- and it still fails what it is there for (the wakes of a regression on top of the median run: 1198 fires, 2397 messages, 713 main cs)
function Judge([int]$Fires, [int]$Messages, [double]$Main) { Test-AnimatedWork @{ messages = $Messages; sources = @("animationClock:$Fires") } 10 120 $Main 1000 }
Check (-not (Judge 1198 (2397 + 1200) 713).ok) 'a second timer at the frame rate (one WM_TIMER per frame) fails'
Check (-not (Judge 1198 (2397 + 1198) 713).ok) 'one more control repainted every frame fails'
Check (-not (Judge 2396 4793 900).ok) 'the clock at twice the GIF rate (a 50 ms timer) fails'
Check (-not (Judge 240 479 150).ok) 'a clock that stopped (240 fires in 120 s) fails'
Check (-not (Judge 1198 2397 1200).ok) 'a main thread at 1200 switches a minute fails (runaway)'
Check ((Judge 1198 2397 823.5).ok) 'the failing run 44295198366 (823.5 main cs, the same work) passes'
Check (-not (Test-AnimatedWork $null 10 120 700 1000).ok) 'no attribution fails'
Check (-not (Test-AnimatedWork $companion 0 120 700 1000).ok) 'no GIF rate in the probe line fails'
# the sprite window's own shape (one WM_PAINT a fire): a second timer still fails, two messages a fire are allowed
Check (-not (Judge 1221 (1222 + 1221 + 20) 700).ok) 'sprite-open: a second timer and a little more fails'

# ---- the moving pets (Test-TimerWork): the measured shape passes, a second timer, a double-rate clock and a stopped one fail
function Pet([string]$Source, [int]$Fires, [int]$Cs, [int]$Min, [int]$Max, [int]$Messages = 1) {
    Test-TimerWork @{ messages = $Messages; sources = @("${Source}:$Fires") } @($Source) $Min $Max $Cs
}
# pet-animated in 44315731795: animationClock 300, main 320 in 120 s, 1 message; pet-working: the bob at 0.5 s (about 240 fires), main 291-298
Check ((Pet 'animationClock' 300 320 180 400).ok) 'pet-animated as measured (300 fires, 320 main cs) passes'
Check ((Pet 'petBob' 240 298 192 265).ok) 'pet-working as measured (about 240 bob fires, 298 main cs) passes'
Check (-not (Pet 'animationClock' 300 (320 + 300) 180 400).ok) 'pet-animated: a second timer at the frame rate (unattributed: switches without fires) fails'
Check (-not (Pet 'petBob' 240 (298 + 240) 192 265).ok) 'pet-working: a second timer at the bob rate fails'
Check (-not (Pet 'animationClock' 600 640 180 400).ok) 'pet-animated: the clock at twice the floor rate fails'
Check (-not (Pet 'petBob' 480 540 192 265).ok) 'pet-working: the bob at twice its rate fails'
Check (-not (Pet 'animationClock' 0 4 180 400).ok) 'pet-animated: a stopped clock fails'
Check (-not (Pet 'petBob' 0 4 192 265).ok) 'pet-working: a stopped bob (or one that is not counted) fails'
Check (-not (Pet 'petBob' 240 298 192 265 (2 * 240 + 30)).ok) 'pet-working: a repaint storm (messages over 2 a fire) fails'
Check (-not (Test-TimerWork $null @('petBob') 192 265 298).ok) 'pet: no attribution fails'

# ---- the still windows (PR 3): the release run 45744414650 failed popover-open-120s (main cs 15 = 7.5/min against 6) and popover-page-collection-log-120s
# (452,013 cycles/s against 450,000). Real WAKES lines of that run's shards, read by the same fields the gate reads.
function ConvertFrom-WakesLine([string]$Line) {
    $m = [regex]::Match($Line, 'WAKES (\S+): loops=(\d+) messages=(\d+) ids=\[(.*?)\] timers=\[(.*?)\] sources=\[(.*?)\]\s*$')
    if (-not $m.Success) { return $null }
    return [ordered]@{ loops = [int]$m.Groups[2].Value; messages = [int]$m.Groups[3].Value
        messageIds = @(if ($m.Groups[4].Value) { $m.Groups[4].Value.Split(' ') }); timerIds = @(); sources = @(if ($m.Groups[6].Value) { $m.Groups[6].Value.Split(' ') }) }
}
$openLine = '2026-11-26T03:08:00.0000000Z WAKES popover-open-120s: loops=7 messages=6 ids=[0xf@PokeTokenBarPane:3 0xf@Static:2 0x10@PokeTokenBarSink:1] timers=[] sources=[popoverClock:3]'
$logLine = '2026-11-26T03:13:48.3432824Z WAKES popover-page-collection-log-120s: loops=13 messages=11 ids=[0xf@Button:7 0xf@Static:2 0x10@PokeTokenBarSink:1 0xf@PokeTokenBarDrawn:1] timers=[] sources=[popoverClock:1]'
$quietLine = '2026-11-25T16:44:01.0773150Z WAKES popover-page-collection-log-120s: loops=2 messages=1 ids=[0x10@PokeTokenBarSink:1] timers=[] sources=[]'
$openWake = ConvertFrom-WakesLine $openLine; $logWake = ConvertFrom-WakesLine $logLine; $quietWake = ConvertFrom-WakesLine $quietLine
Check ($openWake.loops -eq 7 -and $openWake.messageIds.Count -eq 3 -and $openWake.sources[0] -eq 'popoverClock:3') 'the real popover-open WAKES line reads as loops 7, three message ids, popoverClock:3'

# popover-open: 18 windows of 18 runs (2026-11-20..26) all did this work; main cs in 120 s were 6 6 12 6 6 6 7 6 7 12 7 6 6 13 6 7 15 6
$openCs = 6, 6, 12, 6, 6, 6, 7, 6, 7, 12, 7, 6, 6, 13, 6, 7, 15, 6
Check ($openCs.Count -eq 18) 'the table has the 18 popover-open windows'
$i = 0
foreach ($cs in $openCs) {
    $i++
    $v = Test-StillWork $openWake ($cs / 2) 15
    Check $v.ok "popover-open window $i (main cs $cs in 120 s) passes the work rule"
}
$release = Test-StillWork $openWake 7.5 15
Check ($release.ok -and $release.detail -match 'main cs/min 7.5') 'the release run 45744414650 window (15 cs = 7.5/min, failed the old 6/min) passes the work rule'
function Still([int]$Fires, [int]$Messages, [int]$Loops, [string[]]$Ids = @('0xf@PokeTokenBarPane:3', '0xf@Static:2', '0x10@PokeTokenBarSink:1'), [double]$Cs = 3) {
    Test-StillWork ([ordered]@{ loops = $Loops; messages = $Messages; messageIds = $Ids; sources = @($(if ($Fires -gt 0) { "popoverClock:$Fires" })) }) $Cs 15
}
Check (Still 3 6 7).ok 'the fake builder reproduces the passing window'
Check (-not (Still 5 10 11).ok) 'popover-open: two fires more than the 3 it always has (5) fail'
Check (-not (Still 120 240 241).ok) 'popover-open: the clock at 1 Hz (120 fires) fails'
Check (-not (Still 1 2 3).ok) 'popover-open: a clock that fired once (a stopped or slowed clock) fails'
Check (-not (Still 0 0 1).ok) 'popover-open: no clock fire at all fails'
Check (-not (Still 3 9 7).ok) 'popover-open: a second paint per fire (9 messages for 3 fires) fails'
Check (-not (Still 3 6 7 @('0xf@PokeTokenBarPane:3', '0xf@Button:2', '0x10@PokeTokenBarSink:1')).ok) 'popover-open: a message to a window class the page does not have (Button) fails'
Check (-not (Still 3 6 10).ok) 'popover-open: three loop passes more than its messages (a main-queue block or a posted message) fail'
Check (-not (Still 3 6 7 -Cs 15.5).ok) 'popover-open: main cs/min over the runaway 15 fails'
Check (-not (Test-StillWork $null 3 15).ok) 'popover-open: no attribution fails'
# boundaries of every bound (each isolates one rule: the others are kept inside theirs)
Check ((Still 2 5 6).ok) 'boundary: 2 fires with the 5 messages and 6 loops they carry (Pane 2, Static 2, close 1) pass: the fire floor and the message bound agree'
Check (-not (Still 2 6 7).ok) 'boundary: 2 fires with the unchanged 6 messages fail (a repaint the clock did not cause)'
Check ((Still 4 8 9).ok) 'boundary: 4 fires (one more than the 3 it always has) pass: the stated slack'
Check (-not (Still 5 11 13).ok) 'boundary: 5 fires fail even with messages (11 = 2 x 5 + 1) and loops (13 = messages + 2) inside their bounds'
Check ((Still 3 7 9).ok) 'boundary: 7 messages (the bound at 3 fires) with 9 loops pass'
Check (-not (Still 3 8 10).ok) 'boundary: 8 messages at 3 fires fail'
Check ((Still 3 6 8).ok) 'boundary: 8 loop passes (messages + 2) pass: one more than the 7 it always has'
Check (-not (Still 3 6 9).ok) 'boundary: 9 loop passes fail'
Check ((Still 3 6 7 -Cs 15).ok) 'boundary: main cs/min 15 passes the runaway (15.5 fails, above)'
$stranger = Still 3 6 7 @('0xf@PokeTokenBarPane:3', '0x113@MSCTFIME UI:2', '0x10@PokeTokenBarSink:1')
Check (-not $stranger.ok -and $stranger.detail -match "class\(es\) 'MSCTFIME UI'") 'a message class off the list is named in the failure (the TSF "MSCTFIME UI" is a known false-fail risk, not allowed without a sighting)'
$button = Still 3 6 7 @('0xf@PokeTokenBarPane:3', '0xf@Button:2', '0x10@PokeTokenBarSink:1')
Check (-not $button.ok -and $button.detail -match "class\(es\) 'Button'") 'the failure names Button'
# the stated cost, with the corrected numbers: a Foundation timer that runs only while Home is open adds about 120/period switches over a floor of
# 6-13 per window; the runaway is 15/min = 30 per window, the old budget 6/min = 12.
function Timer([int]$Floor, [double]$Period) { Still 3 6 7 -Cs (($Floor + 120 / $Period) / 2) }
Check (-not (Timer 6 4).ok -and -not (Timer 13 4).ok) 'a hidden 4 s timer on Home fails at either floor'
Check ((Timer 6 6).ok -and -not (Timer 13 6).ok) 'a hidden 6 s timer fails or passes with the floor (6: 13/min passes; 13: 16.5/min fails)'
Check ((Timer 6 8).ok -and (Timer 13 8).ok) 'KNOWN GAP (stated in the PR): a hidden 8 s timer on the open Home passes at either floor (14/min at floor 13)'
Check ((Timer 13 20).ok) 'KNOWN GAP (stated in the PR): a hidden 20 s timer passes (the old 6/min budget, 12 cs per window, stopped catching at about 20 s at floor 6)'
Check ((Still 3 6 8).ok) 'KNOWN GAP (stated in the PR): one more loop pass than the baseline passes (a main-queue block about every 60 s or less adds two or more and fails)'

# the collection log: the fixture's clock fire, and the guard that keeps a window away from it
Check ((Get-PageClockSources $logWake).Count -eq 1) 'collection-log: the real release window (popoverClock:1) has a clock fire, which fails the window'
Check ((Get-PageClockSources $quietWake).Count -eq 0) 'collection-log: the real quiet window (no sources) has none and passes'
Check ((Get-PageClockSources @{ sources = @('animationClock:3', 'stackLayout:1') }).Count -eq 1 -and (Get-PageClockSources $null).Count -eq 0) 'the clock sources are read by name; no attribution has none (the gate fails it elsewhere)'
function Get-Code([string]$Path) { (Get-Content -Path $Path | Where-Object { $_ -notmatch '^\s*#' }) -join "`n" }   # source without its comment-only lines
$gateText = Get-Code "$PSScriptRoot/idle-gate.ps1"
$measureText = Get-Code "$PSScriptRoot/measure-idle.ps1"
Check ($gateText -notmatch "page -ne 'collection-log'") "the gate code no longer exempts the collection-log window from the clock rule"
Check ($gateText -match '(?m)^\s*\$judged = Test-StillWork \$w\.wake ' -and $gateText -match '(?m)^\s*if \(\$mode -eq ''open''\) \{\s*$') 'the gate code judges popover-open with the work rule'
Check ($gateText -match '(?m)^\s*\$summaryPhaseWait = Wait-PastGuards \$Label \(\$Seconds \+ 40\) \$phases' -and $gateText -match '(?m)^\s*\$phases = if \(\$CompanionFixture\) \{ Get-FixturePhases ') 'the gate code runs the wall-clock guards, with the fixture phases for every window that uses the companion fixture'
Check ($gateText -match '(?m)^\s*if \(\$clocks\.Count -gt 0\) \{ \$verdicts\[\$label\] = \$false \}') 'the gate code fails every page window whose clock fired'
Check ($measureText -match '(?m)^\s*Check "liveCyclesPerSec" \$result\.liveCyclesPerSec \$MaxLiveCyclesPerSec\s*$') 'measure-idle code enforces the live-thread cycles budget'
Check ($measureText -match '(?m)^\s*\$split = Get-CycleSplit \$procCycles ') 'measure-idle code splits the cycles with Get-CycleSplit'

. "$PSScriptRoot/midnight-guard.ps1"
$fixture = "$PSScriptRoot/fixtures/idle-companion-state.json"
$phases = Get-FixturePhases $fixture
Check (([regex]::Matches((Get-Content -Raw $fixture), '"caughtAt"')).Count -eq 40) 'the fixture holds 40 caughtAt dates'
Check ($phases.Count -ge 1 -and ($phases -contains 800)) "the fixture's dates step at 13:20 past the hour (phases: $($phases -join ','))"
function At([string]$When) { [datetime]::SpecifyKind([datetime]::Parse($When, [cultureinfo]::InvariantCulture), [datetimekind]::Utc) }
# What Measure-App passes: the window's 120 s + 40 s of launch and settle + 30 s margin = 190 s from the start of Measure-App.
# Real starts: the 18 collection-log windows of 18 runs, start = the window's end minus 155 s (launch, 30 s settle, 120 s).
$starts = [ordered]@{
    '2026-11-20 14:30:19' = 0; '2026-11-20 16:06:34' = 0; '2026-11-21 05:23:17' = 0; '2026-11-21 06:25:48' = 0; '2026-11-21 07:07:07' = 0; '2026-11-21 16:20:20' = 0
    '2026-11-22 12:43:20' = 0; '2026-11-23 09:52:21' = 0; '2026-11-23 16:42:24' = 0; '2026-11-24 10:24:28' = 0; '2026-11-24 11:45:05' = 0; '2026-11-24 16:35:34' = 0
    '2026-11-24 22:01:11' = 0; '2026-11-25 04:23:30' = 0; '2026-11-25 05:09:01' = 0; '2026-11-25 16:41:26' = 0; '2026-11-26 03:52:07' = 0
    '2026-11-26 03:11:13' = 142
}
Check ($starts.Count -eq 18) 'the table has the 18 real collection-log windows'
foreach ($k in $starts.Keys) {
    $w = Get-FixturePhaseWait (At $k) 190 $phases
    Check ($w -eq $starts[$k]) "collection-log window started $k UTC: wait $w s (expected $($starts[$k]); only the failing release window of 03:11:13 contains 03:13:20)"
}
Check ((Get-FixturePhaseWait (At '2026-11-26 03:11:13') 190 $phases) -eq 142) 'the release window: sleeps until 03:13:35, 15 s past the instant'
Check ((Get-FixturePhaseWait (At '2026-11-26 03:10:10') 190 @(800)) -eq 205 -and (Get-FixturePhaseWait (At '2026-11-26 03:10:10') 189 @(800)) -eq 0) 'the instant on the window end counts, one second later does not'
Check ((Get-FixturePhaseWait (At '2026-11-26 03:13:25') 190 @(800)) -eq 0) 'a start 5 s past the instant needs no wait (the next one is an hour away)'
Check ((Get-FixturePhaseWait (At '2026-11-26 03:13:20') 190 @(800)) -eq 15) 'a start on the instant itself waits the 15 s'
Check ((Get-FixturePhaseWait (At '2026-11-26 03:59:00') 190 @(800)) -eq 0 -and (Get-FixturePhaseWait (At '2026-11-26 04:11:00') 190 @(800)) -eq 155) 'across the hour: 03:59 clear, 04:11 waits to 04:13:35'
Check ((Get-FixturePhaseWait (At '2026-11-26 23:59:00') 190 @(800)) -eq 0 -and (Get-FixturePhaseWait (At '2026-11-27 00:11:00') 190 @(800)) -eq 155) 'across midnight the same'
Check ((Get-FixturePhaseWait (At '2026-11-26 03:12:00') 190 @(800, 1000)) -eq 295) 'two phases (13:20 and 16:40): the wait goes past the second one the first wait reaches'
function Throws([scriptblock]$Code, [string]$Pattern) { try { & $Code | Out-Null; return $false } catch { return ($_.Exception.Message -match $Pattern) } }
Check (Throws { Get-FixturePhaseWait (At '2026-11-26 03:12:00') 190 @() } 'no phases') 'a phase wait with no phases throws (a guard that read nothing must not wait 0 s)'
$tmp = Join-Path ([IO.Path]::GetTempPath()) "fixture-phase-$([guid]::NewGuid()).json"
Check (Throws { Get-FixturePhases $tmp } 'is missing') 'a missing fixture throws'
Set-Content -Path $tmp -Value '{"dex": []}'
Check (Throws { Get-FixturePhases $tmp } 'no caughtAt') 'a fixture with no caughtAt throws'
Set-Content -Path $tmp -Value '{"dex": [{"caughtAt": "2023-11-14T21:13:20Z"}, {"caughtAt": "2023-11-14T22:13:20Z"}]}'
Check (Throws { Get-FixturePhases $tmp } '2 of 2 caughtAt values') 'ISO-string dates throw (the phase cannot be read)'
Set-Content -Path $tmp -Value '{"dex": [{"caughtAt": 721689200}, {"caughtAt": "2023-11-14T22:13:20Z"}]}'
Check (Throws { Get-FixturePhases $tmp } '1 of 2 caughtAt values') 'one unreadable date among numbers throws'
Set-Content -Path $tmp -Value '{"dex": [{"caughtAt": 721689200}, {"caughtAt": 721692800.5}, {"caughtAt": 721685600}]}'
Check (((Get-FixturePhases $tmp) -join ',') -eq '800') 'numeric dates (integer, fractional) parse; one phase 800'
Remove-Item $tmp
# the cap and the passes: a wait over the cap throws instead of sleeping on, and an unsettled loop throws
Check (Throws { Get-FixturePhaseWait (At '2026-11-26 03:11:13') 190 @(800) 15 100 } 'over the cap of 100 s') 'a wait that needs 142 s throws under a cap of 100 s'
Check ((Get-FixturePhaseWait (At '2026-11-26 03:11:13') 190 @(800) 15 142) -eq 142) 'the same wait passes when the cap is 142 s'
$dense = 0..35 | ForEach-Object { $_ * 100 }
Check (Throws { Get-FixturePhaseWait (At '2026-11-26 03:00:00') 190 $dense 15 1000000 } 'still contains a fixture text change') 'phases so dense that every wait reaches the next instant: after the passes it throws'
Check (Throws { Get-FixturePhaseWait (At '2026-11-26 03:00:00') 190 $dense } 'over the cap of 600 s') 'the same dense phases under the default cap throw on the cap'
# both guards: the midnight wait can move the start into a fixture window (phase 03:00 past the hour = 180 s; start 23:57:30, 190 s window)
$start = At '2026-11-26 23:57:30'
Check ((Get-FixturePhaseWait $start 190 @(180)) -eq 0 -and (Get-MidnightWait $start 190) -eq 165) 'the old order breaks here: the phase guard alone waits 0, the midnight guard then moves the start to 00:00:15 ...'
Check ((Get-FixturePhaseWait (At '2026-11-27 00:00:15') 190 @(180)) -eq 180) '... where the 00:03:00 instant is inside the window'
Check ((Get-GuardsWait $start 190 @(180)) -eq 345) 'Get-GuardsWait repeats both until neither waits: 345 s to 00:03:15'
Check ((Get-GuardsWait (At '2026-11-26 03:11:13') 190 @(800)) -eq 142 -and (Get-GuardsWait (At '2026-11-26 12:00:00') 190 @(800)) -eq 0) 'without a midnight nearby the guards wait as the phase guard alone'
Check ((Get-GuardsWait (At '2026-11-26 23:58:03') 190 @()) -eq (Get-MidnightWait (At '2026-11-26 23:58:03') 190) -and (Get-GuardsWait (At '2026-11-26 23:58:03') 190 $null) -gt 0) 'a window without the fixture keeps the midnight guard alone (empty or null phases)'
Check (Throws { Get-GuardsWait $start 190 @(180) 300 } 'over the cap of 300 s') 'the combined wait over its cap throws'
$script:GuardsDryRun = $true
Check ((Wait-PastGuards 'case' 160 @(800) (At '2026-11-26 03:11:13')) -eq 142 -and (Wait-PastGuards 'case' 160 @(800) (At '2026-11-26 03:20:00')) -eq 0 -and (Wait-PastGuards 'case' 160 @(180) $start) -eq 345) 'Wait-PastGuards adds the 30 s margin: waits for the release window and the midnight case, not at 03:20'

# the cycles: threads alive at the end against the rest (run 44873075438: plaza-closed 486,741 cycles/s, 22 -> 4 threads)
$gate = Get-Content -Raw "$PSScriptRoot/idle-gate.ps1"
$gm = [regex]::Match($gate, '\$budget = @\{[^}]*?MaxLiveCyclesPerSec = (\d+); MaxProcessCyclesPerSec = (\d+)')
Check $gm.Success 'the gate budget names a live-thread and a process figure'
$maxLive = [double]$gm.Groups[1].Value; $maxProc = [double]$gm.Groups[2].Value
$split = Get-CycleSplit ([uint64]58408920) @([uint64]9205682, [uint64]5616957, [uint64]1324998) 120
Check ($split.live -eq 134564 -and $split.gone -eq 352177) "plaza-closed 44873075438: live 134,564/s and gone 352,177/s (got $($split.live), $($split.gone))"
Check ($split.live -le $maxLive -and ($split.live + $split.gone) -le $maxProc) 'plaza-closed 44873075438 passes the live and the process figure (it failed the old process-wide 450,000)'
$crash = Get-CycleSplit ([uint64]54241590) @([uint64]23971980, [uint64]7541700, [uint64]6233690, [uint64]4470970, [uint64]4232000, [uint64]1204510, [uint64]245870) 120
Check ($crash.live -eq 399173 -and $crash.live -le $maxLive) 'collection-log 45744414650: live 399,173/s is under the live budget (its failure was the clock fire, which the fixture guard and the clock rule own)'
Check ((Get-CycleSplit ([uint64](450000 * 120)) @([uint64](450000 * 120)) 120).live -gt $maxLive) 'a live 450,000/s process (threads alive at the end) fails the live budget'
$storm = Get-CycleSplit ([uint64](900000 * 120)) @([uint64](200000 * 120)) 120
Check ($storm.live -le $maxLive -and ($storm.live + $storm.gone) -gt $maxProc) 'a 900,000/s process with normal live threads (a storm of threads that exit) fails the process runaway figure'
Check ((Get-CycleSplit ([uint64](100 * 120)) @([uint64](500 * 120)) 120).gone -eq 0) 'threads that read more than the process (counters sampled at different moments) leave gone at 0, not negative'
$gap = Get-CycleSplit ([uint64](600000 * 120)) @([uint64](140000 * 120)) 120
Check ($gap.live -le $maxLive -and $gap.gone -eq 460000 -and ($gap.live + $gap.gone) -le $maxProc) 'KNOWN GAP (stated in the PR): 600,000/s with normal live threads (460,000/s in threads that exit within the window) passes: the old process-wide 450,000 failed it, and exited threads add no switches, so only 830,000 minus the live threads bounds them'

# ---- the run-loop wake lines (PR 3 data): their own lines, never in the `wake trace` regex's way
$wl = @('2026-11-26T03:08:28.0000000Z wake trace start: loops=40 messages_total=30 messages=0xf@Static:30 timers= sources=popoverClock:1', '2026-11-26T03:08:28.0010000Z run loop wakes start: 52',
        '2026-11-26T03:10:30.0000000Z wake trace exit: loops=47 messages_total=36 messages=0xf@Static:36 timers= sources=popoverClock:4', '2026-11-26T03:10:30.0010000Z run loop wakes exit: 63')
Check ((Get-RunLoopWakesFromLines $wl) -eq 11) 'the run loop wakes of a window are exit minus start (63 - 52)'
Check ($null -ne (Get-WakeDeltaFromLines $wl[0] $wl[2]) -and (Get-WakeDeltaFromLines $wl[0] $wl[2]).loops -eq 7) 'the new lines leave the wake trace fields as they were (loops 7)'
Check ($null -eq (ConvertFrom-WakeLine $wl[1])) 'a run loop wakes line is not a wake trace line'
Check ($null -eq (Get-RunLoopWakesFromLines @($wl[0], $wl[2]))) 'no run loop wakes lines (an app without the counter) read as null, not as 0'
Check ($null -eq (Get-RunLoopWakesFromLines @($wl[1]))) 'a start without an exit reads as null'
Check ($null -eq (Get-RunLoopWakesFromLines @($wl[3], $wl[1]))) 'an exit before the start reads as null'
Check ($null -eq (Get-RunLoopWakesFromLines $null)) 'no lines read as null'
Check ((Get-RunLoopWakesFromLines @('run loop wakes start: 5', 'run loop wakes exit: 5')) -eq 0) 'a window with no wakes reads as 0'
$tmpLog = Join-Path ([IO.Path]::GetTempPath()) "idle-rules-wakes-$PID.log"
Set-Content -Path $tmpLog -Value $wl
Check ((Get-RunLoopWakes $tmpLog) -eq 11 -and (Get-WakeDelta $tmpLog).loops -eq 7) 'from a log file: wakes 11, and the wake trace pair still reads (loops 7)'
Remove-Item $tmpLog -ErrorAction SilentlyContinue
Check ($null -eq (Get-RunLoopWakes (Join-Path ([IO.Path]::GetTempPath()) "no-such-$PID.log"))) 'a missing log reads as null'

"$script:count checks, $script:failed failed"
if ($script:failed -gt 0) { exit 1 }
