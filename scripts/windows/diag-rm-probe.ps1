# DIAGNOSTIC (branch diag/update-runner-loss-2 only). Asks the Restart Manager every -IntervalMs which processes and services use
# the install folder's .exe and .dll files (what Inno's CloseApplications pass asks before it shuts them down), and appends every
# non-empty answer to -LogFile. It only asks: RmGetList, never RmShutdown.
param([Parameter(Mandatory)] [string]$Folder, [Parameter(Mandatory)] [string]$LogFile, [int]$IntervalMs = 200, [int]$Minutes = 12)
$ErrorActionPreference = 'Continue'
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class DiagRm {
    [StructLayout(LayoutKind.Sequential)] public struct RM_UNIQUE_PROCESS { public int dwProcessId; public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] public struct RM_PROCESS_INFO {
        public RM_UNIQUE_PROCESS Process;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string strAppName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string strServiceShortName;
        public int ApplicationType; public uint AppStatus; public uint TSSessionId; [MarshalAs(UnmanagedType.Bool)] public bool bRestartable;
    }
    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)] static extern int RmStartSession(out uint h, int flags, System.Text.StringBuilder key);
    [DllImport("rstrtmgr.dll")] static extern int RmEndSession(uint h);
    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)] static extern int RmRegisterResources(uint h, uint nFiles, string[] files, uint nApps, IntPtr apps, uint nServices, string[] services);
    [DllImport("rstrtmgr.dll")] static extern int RmGetList(uint h, out uint needed, ref uint count, [In, Out] RM_PROCESS_INFO[] info, ref uint reasons);
    public static List<string> Who(string[] files) {
        var r = new List<string>();
        uint h; var key = new System.Text.StringBuilder(64);
        int e = RmStartSession(out h, 0, key);
        if (e != 0) { r.Add("RmStartSession " + e); return r; }
        try {
            e = RmRegisterResources(h, (uint)files.Length, files, 0, IntPtr.Zero, 0, null);
            if (e != 0) { r.Add("RmRegisterResources " + e); return r; }
            uint needed = 0, count = 0, reasons = 0;
            e = RmGetList(h, out needed, ref count, null, ref reasons);
            if (e == 234 && needed > 0) {
                var info = new RM_PROCESS_INFO[needed]; count = needed;
                e = RmGetList(h, out needed, ref count, info, ref reasons);
                for (int i = 0; i < count; i++)
                    r.Add("pid=" + info[i].Process.dwProcessId + " app='" + info[i].strAppName + "' service='" + info[i].strServiceShortName + "' type=" + info[i].ApplicationType + " status=" + info[i].AppStatus + " session=" + info[i].TSSessionId + " restartable=" + info[i].bRestartable);
                r.Add("reasons=" + reasons);
            } else if (e != 0) r.Add("RmGetList " + e);
        } finally { RmEndSession(h); }
        return r;
    }
}
'@
$deadline = (Get-Date).AddMinutes($Minutes)
$asks = 0; $hits = 0
while ((Get-Date) -lt $deadline) {
    $files = @(Get-ChildItem $Folder -File -Recurse -Include '*.exe', '*.dll' -ErrorAction SilentlyContinue | ForEach-Object FullName)
    if ($files.Count) {
        $asks++
        $who = [DiagRm]::Who([string[]]$files)
        if ($who.Count) {
            $hits++
            [System.IO.File]::AppendAllText($LogFile, "$((Get-Date).ToUniversalTime().ToString('HH:mm:ss.fff')) $($files.Count) files: $($who -join ' | ')" + [Environment]::NewLine)
        }
    }
    if ($asks % 300 -eq 0) { [System.IO.File]::AppendAllText($LogFile, "$((Get-Date).ToUniversalTime().ToString('HH:mm:ss')) asked $asks times, $hits answers with processes" + [Environment]::NewLine) }
    Start-Sleep -Milliseconds $IntervalMs
}
