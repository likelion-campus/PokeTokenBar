# DIAGNOSTIC (branch diag/update-runner-loss-2 only). One sample of the VM, cheap enough to take every few seconds: memory and
# commit, disks, process counts, the busiest processes since the last sample, handles, TCP, whether the runner's own processes
# live, and how far the in-app update script got (its log). Dot-source it; Get-DiagSample returns @{ Short; Long }.
$script:DiagFamily = '^(PokeTokenBar|PokeTokenBar-Setup-.*|unins000|_unins.*)$'

function Get-DiagScriptProgress([string]$ScriptLog) {
    if (-not $ScriptLog -or -not (Test-Path $ScriptLog)) { return 'sc=? ' }
    $s = [System.IO.File]::Open($ScriptLog, 'Open', 'Read', 'ReadWrite, Delete')
    try { $text = ([System.IO.StreamReader]::new($s)).ReadToEnd() } finally { $s.Dispose() }
    $lines = $text -split "`r?`n" | Where-Object { $_ }
    $sc = ($lines | Where-Object { $_ -match '---- (\S+) ----' } | Select-Object -Last 1) -replace '.*---- (\S+) ----.*', '$1'
    $pass = @($lines | Where-Object { $_ -match '\bPASS ' }).Count
    $fail = @($lines | Where-Object { $_ -match '\bFAIL ' }).Count
    $end = if ($text -match 'SCRIPT END') { ' END' } else { '' }
    "sc=$sc P${pass}F$fail$end"
}

function Get-DiagSample([hashtable]$State, [string]$ScriptLog = '', [datetime]$Since = [datetime]::MinValue) {
    $now = Get-Date
    $all = [System.Diagnostics.Process]::GetProcesses()
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $freeG = if ($os) { [math]::Round($os.FreePhysicalMemory / 1MB, 1) } else { -1 }
    $commitG = if ($os) { [math]::Round(($os.TotalVirtualMemorySize - $os.FreeVirtualMemory) / 1MB, 1) } else { -1 }
    $limitG = if ($os) { [math]::Round($os.TotalVirtualMemorySize / 1MB, 0) } else { -1 }
    $c = try { [math]::Round((Get-PSDrive C -ErrorAction Stop).Free / 1GB, 0) } catch { -1 }
    $d = try { [math]::Round((Get-PSDrive D -ErrorAction Stop).Free / 1GB, 0) } catch { -1 }
    $elapsed = if ($State.ContainsKey('at')) { ($now - $State.at).TotalSeconds } else { 0 }
    $prev = if ($State.ContainsKey('cpu')) { $State.cpu } else { @{} }
    $cpuNow = @{}
    $rows = foreach ($p in $all) {
        $t = 0.0; try { $t = $p.TotalProcessorTime.TotalSeconds } catch { }
        $key = "$($p.Id)"
        $cpuNow[$key] = $t
        $delta = if ($prev.ContainsKey($key)) { $t - $prev[$key] } else { 0 }
        $priv = 0; try { $priv = $p.PrivateMemorySize64 } catch { }
        $hc = 0; try { $hc = $p.HandleCount } catch { }
        [pscustomobject]@{ N = $p.ProcessName; Id = $p.Id; Cpu = $delta; Priv = $priv; H = $hc; Th = $(try { $p.Threads.Count } catch { 0 }) }
    }
    $State.cpu = $cpuNow; $State.at = $now
    $cores = [Environment]::ProcessorCount
    $busy = [math]::Round((($rows | Where-Object { $_.N -ne 'Idle' } | Measure-Object Cpu -Sum).Sum) / [math]::Max(1, $elapsed) / $cores * 100, 0)
    $topCpu = $rows | Where-Object { $_.N -ne 'Idle' } | Sort-Object Cpu -Descending | Select-Object -First 3
    $topMem = $rows | Sort-Object Priv -Descending | Select-Object -First 3
    $topH = $rows | Sort-Object H -Descending | Select-Object -First 2
    $handles = ($rows | Measure-Object H -Sum).Sum
    $fam = @($rows | Where-Object { $_.N -match $script:DiagFamily })
    $ptb = @($fam | Where-Object { $_.N -eq 'PokeTokenBar' }).Count
    $su = @($fam | Where-Object { $_.N -ne 'PokeTokenBar' }).Count
    $pw = @($rows | Where-Object { $_.N -eq 'pwsh' }).Count
    $wer = @($rows | Where-Object { $_.N -match '^WerFault' }).Count
    $tcpAll = try { [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpConnections() } catch { @() }
    $tw = @($tcpAll | Where-Object { "$($_.State)" -eq 'TimeWait' }).Count
    $est = @($tcpAll | Where-Object { "$($_.State)" -eq 'Established' }).Count
    $rl = @($rows | Where-Object { $_.N -eq 'Runner.Listener' }).Count
    $rw = @($rows | Where-Object { $_.N -eq 'Runner.Worker' }).Count
    $ex = @($rows | Where-Object { $_.N -eq 'explorer' }).Count
    $t = if ($Since -ne [datetime]::MinValue) { [int]($now - $Since).TotalSeconds } else { 0 }
    $prog = Get-DiagScriptProgress $ScriptLog
    $cpuTxt = ($topCpu | ForEach-Object { "$($_.N -replace '^PokeTokenBar', 'PTB'):$([math]::Round($_.Cpu, 1))" }) -join ','
    $short = "t=$t $prog | cpu=$busy% $cpuTxt | free=${freeG}G cm=$commitG/${limitG}G C=$c D=$d | n=$($all.Count) ptb=$ptb su=$su pw=$pw wer=$wer h=$([int]($handles / 1000))k | tcp=$($tcpAll.Count) est=$est tw=$tw | rl=$rl rw=$rw ex=$ex"
    $long = "$($now.ToUniversalTime().ToString('HH:mm:ss.f')) $short | mem: $(($topMem | ForEach-Object { "$($_.N):$($_.Id):$([int]($_.Priv / 1MB))M/h$($_.H)/t$($_.Th)" }) -join ' ') | hmax: $(($topH | ForEach-Object { "$($_.N):$($_.Id):$($_.H)" }) -join ' ') | fam: $(($fam | ForEach-Object { "$($_.N):$($_.Id):$([int]($_.Priv / 1MB))M:c$([math]::Round($_.Cpu, 1))" }) -join ' ')"
    @{ Short = $short; Long = $long }
}

# The PokeTokenBar family and every pwsh, with parents and command lines (slower: CIM).
function Get-DiagProcessTable {
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^(PokeTokenBar|pwsh|unins000|_unins|Runner\.|WerFault|conhost|OpenConsole|WindowsTerminal|cmd|powershell|bash)' } |
        ForEach-Object { "  $($_.ProcessId) <- $($_.ParentProcessId) $($_.Name) started $($_.CreationDate.ToUniversalTime().ToString('HH:mm:ss')) ws=$([int]($_.WorkingSetSize / 1MB))M h=$($_.HandleCount) :: $("$($_.CommandLine)".Substring(0, [math]::Min(220, "$($_.CommandLine)".Length)))" }
}
