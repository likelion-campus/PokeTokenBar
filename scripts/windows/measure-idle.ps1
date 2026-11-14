# Idle cost of a running process, by cycles and context switches (never GetProcessTimes, F20): the process's and every
# thread's QueryThreadCycleTime and the thread's ContextSwitches (NtQuerySystemInformation, SystemProcessInformation)
# are read once at each edge of the window and nothing in between, so the measurement itself does not wake the target.
# Also reported: process CPU time, private bytes and handle count at both edges (leak check), and the same totals for
# other processes by name (-Also explorer). Threads are named by GetThreadDescription and by the module + offset of their
# Win32 start routine, which is how the two ~1 Hz waker threads were attributed.
#
# -SliceSeconds n (diagnostics only, not for the gate): also reads the thread counters every n seconds and prints the
#   per-slice context switches of the busiest threads, to see WHEN a waker starts.
# Usage: measure-idle.ps1 -ProcessId <pid> -Seconds 120 [-Also explorer] [-Baseline] [-Out idle.json] [-Label name]
#        [-MaxMainCsPerMin n] [-MaxProcessCsPerMin n] [-MaxPrivateGrowthMB n] [-MaxHandleGrowth n] [-MaxProcessCyclesPerSec n]
# A -Max* value >= 0 is asserted (PASS/FAIL line each, exit 1 on any FAIL); the default -1 only reports.
param(
    [Parameter(Mandatory)][int]$ProcessId,
    [int]$Seconds = 120,
    [string[]]$Also = @(),
    [switch]$Baseline,
    [string]$Out = "",
    [string]$Label = "",
    [int]$SliceSeconds = 0,
    [double]$MaxMainCsPerMin = -1,
    [double]$MaxProcessCsPerMin = -1,
    [double]$MaxPrivateGrowthMB = -1,
    [double]$MaxHandleGrowth = -1,
    [double]$MaxProcessCyclesPerSec = -1
)
$ErrorActionPreference = "Stop"
if (-not ([System.Management.Automation.PSTypeName]'PtbIdle').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public sealed class PtbThread {
    public uint Tid; public uint ContextSwitches; public ulong Cycles; public long CreateTime; public ulong Win32Start; public string Description;
}

public static class PtbIdle {
    [DllImport("ntdll.dll")] static extern int NtQuerySystemInformation(int cls, IntPtr buffer, int length, out int needed);
    [DllImport("ntdll.dll")] static extern int NtQueryInformationThread(IntPtr h, int cls, out UIntPtr info, int length, IntPtr ret);
    [DllImport("kernel32.dll")] static extern IntPtr OpenThread(uint access, bool inherit, uint tid);
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll")] static extern bool QueryThreadCycleTime(IntPtr h, out ulong cycles);
    [DllImport("kernel32.dll")] static extern bool QueryProcessCycleTime(IntPtr h, out ulong cycles);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] static extern int GetThreadDescription(IntPtr h, out IntPtr name);
    [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr p);

    const uint THREAD_QUERY_LIMITED_INFORMATION = 0x0800, THREAD_QUERY_INFORMATION = 0x0040, PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;

    // x64: SYSTEM_PROCESS_INFORMATION is 0x100 bytes (NextEntryOffset 0, NumberOfThreads 4, UniqueProcessId 0x50), followed by
    // SYSTEM_THREAD_INFORMATION entries of 0x50 bytes (CreateTime 0x10, ClientId 0x28/0x30, ContextSwitches 0x40).
    public static PtbThread[] Threads(uint pid, bool withNames) {
        int size = 1 << 20;
        while (true) {
            IntPtr buffer = Marshal.AllocHGlobal(size);
            try {
                int needed;
                int status = NtQuerySystemInformation(5, buffer, size, out needed);
                if (status == unchecked((int)0xC0000004)) { size = Math.Max(size * 2, needed + 65536); continue; }
                if (status < 0) throw new Exception("NtQuerySystemInformation 0x" + status.ToString("X"));
                var list = new List<PtbThread>();
                int offset = 0;
                while (true) {
                    int next = Marshal.ReadInt32(buffer, offset);
                    int count = Marshal.ReadInt32(buffer, offset + 4);
                    if ((uint)Marshal.ReadInt64(buffer, offset + 0x50) == pid) {
                        for (int i = 0; i < count; i++) {
                            int b = offset + 0x100 + i * 0x50;
                            var t = new PtbThread();
                            t.CreateTime = Marshal.ReadInt64(buffer, b + 0x10);
                            t.Tid = (uint)Marshal.ReadInt64(buffer, b + 0x30);
                            t.ContextSwitches = (uint)Marshal.ReadInt32(buffer, b + 0x40);
                            list.Add(t);
                        }
                    }
                    if (next == 0) break;
                    offset += next;
                }
                foreach (var t in list) {
                    IntPtr h = OpenThread(THREAD_QUERY_LIMITED_INFORMATION | THREAD_QUERY_INFORMATION, false, t.Tid);
                    if (h == IntPtr.Zero) h = OpenThread(THREAD_QUERY_LIMITED_INFORMATION, false, t.Tid);
                    if (h == IntPtr.Zero) continue;
                    ulong cycles;
                    if (QueryThreadCycleTime(h, out cycles)) t.Cycles = cycles;
                    if (withNames) {
                        UIntPtr start;
                        if (NtQueryInformationThread(h, 9, out start, UIntPtr.Size, IntPtr.Zero) >= 0) t.Win32Start = (ulong)start;
                        IntPtr text;
                        if (GetThreadDescription(h, out text) >= 0 && text != IntPtr.Zero) { t.Description = Marshal.PtrToStringUni(text); LocalFree(text); }
                    }
                    CloseHandle(h);
                }
                return list.ToArray();
            } finally { Marshal.FreeHGlobal(buffer); }
        }
    }

    public static ulong ProcessCycles(uint pid) {
        IntPtr h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
        if (h == IntPtr.Zero) return 0;
        ulong cycles; if (!QueryProcessCycleTime(h, out cycles)) cycles = 0;
        CloseHandle(h);
        return cycles;
    }
}
'@
}

function Edge([int]$id, [bool]$names) {
    $p = Get-Process -Id $id -ErrorAction Stop
    [pscustomobject]@{
        Threads = [PtbIdle]::Threads([uint32]$id, $names)
        Cycles  = [PtbIdle]::ProcessCycles([uint32]$id)
        CpuSeconds = $p.TotalProcessorTime.TotalSeconds
        PrivateBytes = $p.PrivateMemorySize64
        Handles = $p.HandleCount
        Name = $p.ProcessName
    }
}
function Others() {
    $r = @{}
    foreach ($name in $Also) {
        $cs = [uint64]0; $cy = [uint64]0; $n = 0
        foreach ($p in (Get-Process -Name $name -ErrorAction SilentlyContinue)) {
            $n++
            $cy += [PtbIdle]::ProcessCycles([uint32]$p.Id)
            foreach ($t in [PtbIdle]::Threads([uint32]$p.Id, $false)) { $cs += $t.ContextSwitches }
        }
        $r[$name] = [pscustomobject]@{ Processes = $n; Cycles = $cy; ContextSwitches = $cs }
    }
    $r
}

$startedAt = (Get-Date).ToUniversalTime().ToString("o")
$a = Edge $ProcessId $false
$oa = Others
$slices = @()
if ($SliceSeconds -gt 0) {
    $prev = $a.Threads; $elapsed = 0
    while ($elapsed + $SliceSeconds -lt $Seconds) {
        Start-Sleep -Seconds $SliceSeconds; $elapsed += $SliceSeconds
        $now = [PtbIdle]::Threads([uint32]$ProcessId, $false)
        $before = @{}; foreach ($t in $prev) { $before[$t.Tid] = $t.ContextSwitches }
        $top = $now | ForEach-Object { [pscustomobject]@{ tid = $_.Tid; cs = [int]($_.ContextSwitches - $(if ($before.ContainsKey($_.Tid)) { $before[$_.Tid] } else { 0 })) } } | Sort-Object cs -Descending | Select-Object -First 3
        $slices += [pscustomobject]@{ at = $elapsed; top = @($top) }
        Write-Host ("  slice +{0,3} s: {1}" -f $elapsed, (($top | ForEach-Object { "tid $($_.tid) cs=$($_.cs)" }) -join "; "))
        $prev = $now
    }
    Start-Sleep -Seconds ($Seconds - $elapsed)
} else {
    Start-Sleep -Seconds $Seconds
}
$b = Edge $ProcessId $true
$ob = Others
$mods = @()
try { $mods = @((Get-Process -Id $ProcessId).Modules | ForEach-Object { [pscustomobject]@{ Name = $_.ModuleName; Base = [uint64]$_.BaseAddress.ToInt64(); Size = [uint64]$_.ModuleMemorySize } }) } catch { }
function Where-Address([uint64]$address) {
    foreach ($m in $mods) { if ($address -ge $m.Base -and $address -lt $m.Base + $m.Size) { return ("{0}+0x{1:x}" -f $m.Name, ($address - $m.Base)) } }
    if ($address -eq 0) { return "" } else { return ("0x{0:x}" -f $address) }
}

$before = @{}; foreach ($t in $a.Threads) { $before[$t.Tid] = $t }
$main = ($b.Threads | Sort-Object CreateTime | Select-Object -First 1).Tid
$rows = foreach ($t in $b.Threads) {
    $old = $before[$t.Tid]
    [pscustomobject]@{
        tid = $t.Tid
        main = ($t.Tid -eq $main)
        name = $t.Description
        start = (Where-Address $t.Win32Start)
        cycles = [uint64]($t.Cycles - $(if ($old) { $old.Cycles } else { 0 }))
        contextSwitches = [int]($t.ContextSwitches - $(if ($old) { $old.ContextSwitches } else { 0 }))
        newInWindow = ($null -eq $old)
    }
}
$gone = @($a.Threads | Where-Object { $b.Threads.Tid -notcontains $_.Tid }).Count
$minutes = $Seconds / 60.0
$mainRow = $rows | Where-Object { $_.main } | Select-Object -First 1
$totalCs = ($rows | Measure-Object contextSwitches -Sum).Sum
$procCycles = [uint64]($b.Cycles - $a.Cycles)
$result = [ordered]@{
    label = $(if ($Label) { $Label } else { $b.Name })
    baseline = [bool]$Baseline
    processId = $ProcessId
    processName = $b.Name
    startedAtUtc = $startedAt
    seconds = $Seconds
    processCycles = $procCycles
    processCyclesPerSec = [math]::Round($procCycles / $Seconds)
    processCpuSeconds = [math]::Round($b.CpuSeconds - $a.CpuSeconds, 3)
    contextSwitches = $totalCs
    contextSwitchesPerMin = [math]::Round($totalCs / $minutes, 2)
    mainThreadId = $main
    mainThreadContextSwitches = $(if ($mainRow) { $mainRow.contextSwitches } else { -1 })
    mainThreadCycles = $(if ($mainRow) { $mainRow.cycles } else { 0 })
    threadsStart = $a.Threads.Count
    threadsEnd = $b.Threads.Count
    threadsGone = $gone
    threads = @($rows | Sort-Object contextSwitches -Descending)
    slices = $slices
    privateMBStart = [math]::Round($a.PrivateBytes / 1MB, 2)
    privateMBEnd = [math]::Round($b.PrivateBytes / 1MB, 2)
    handlesStart = $a.Handles
    handlesEnd = $b.Handles
    explorerCycles = $(if ($ob.ContainsKey('explorer')) { [uint64]($ob['explorer'].Cycles - $oa['explorer'].Cycles) } else { $null })
    also = @($Also | ForEach-Object { [pscustomobject]@{ name = $_; processes = $ob[$_].Processes; cycles = [uint64]($ob[$_].Cycles - $oa[$_].Cycles); contextSwitches = [int64]($ob[$_].ContextSwitches - $oa[$_].ContextSwitches) } })
}
$json = [pscustomobject]$result | ConvertTo-Json -Depth 5
if ($Out) { Set-Content -Path $Out -Value $json -Encoding utf8 }

Write-Host ("IDLE {0}: {1} s, process cycles {2:N0} ({3:N0}/s), cpu {4} s, context switches {5} ({6}/min), main thread cs={7} cycles={8:N0}" -f `
    $result.label, $Seconds, $procCycles, $result.processCyclesPerSec, $result.processCpuSeconds, $totalCs, $result.contextSwitchesPerMin, $result.mainThreadContextSwitches, $result.mainThreadCycles)
Write-Host ("IDLE {0}: private {1} -> {2} MB, handles {3} -> {4}, threads {5} -> {6} ({7} gone)" -f $result.label, $result.privateMBStart, $result.privateMBEnd, $a.Handles, $b.Handles, $a.Threads.Count, $b.Threads.Count, $gone)
foreach ($t in ($rows | Where-Object { $_.contextSwitches -gt 0 -or $_.cycles -gt 0 } | Sort-Object cycles -Descending | Select-Object -First 12)) {
    Write-Host ("  thread {0}{1} cs={2} cycles={3:N0} start={4} name='{5}'{6}" -f $t.tid, $(if ($t.main) { " (main)" } else { "" }), $t.contextSwitches, $t.cycles, $t.start, $t.name, $(if ($t.newInWindow) { " NEW" } else { "" }))
}
foreach ($o in $result.also) { Write-Host ("IDLE {0}: {1} process(es), cycles {2:N0}, context switches {3}" -f $o.name, $o.processes, $o.cycles, $o.contextSwitches) }

$failed = $false
function Check([string]$name, [double]$value, [double]$max) {
    if ($max -lt 0) { return }
    $ok = $value -le $max
    Write-Host ("{0} idle.{1}: {2} <= {3}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name, $value, $max)
    if (-not $ok) { $script:failed = $true }
}
Check "mainThreadCsPerMin" ($result.mainThreadContextSwitches / $minutes) $MaxMainCsPerMin
Check "processCsPerMin" $result.contextSwitchesPerMin $MaxProcessCsPerMin
Check "processCyclesPerSec" $result.processCyclesPerSec $MaxProcessCyclesPerSec
Check "privateGrowthMB" ($result.privateMBEnd - $result.privateMBStart) $MaxPrivateGrowthMB
Check "handleGrowth" ($b.Handles - $a.Handles) $MaxHandleGrowth
if ($failed) { exit 1 }
