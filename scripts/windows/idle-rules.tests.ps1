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
@('44200348337', 'popover-sprite-open-120s', 1221, 1222, 747.0)
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

"$script:count checks, $script:failed failed"
if ($script:failed -gt 0) { exit 1 }
