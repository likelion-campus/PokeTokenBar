# Shared by the installer steps of windows-app.yml (dot-source it). Starts and stops the installed or bundled app the way
# the earlier kill/exit step does: the app is found by its sink window, ended by WM_CLOSE (exit code 0 through WindowsApp.exit).
if (-not ([System.Management.Automation.PSTypeName]'PtbCi').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PtbCi {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowW(string cls, string title);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);
}
'@
}
$script:PtbPlist = Join-Path $env:LOCALAPPDATA 'PokeTokenBar.exe.plist'
$script:PtbInstallDir = Join-Path $env:LOCALAPPDATA 'Programs\PokeTokenBar'

function Find-Sink { [PtbCi]::FindWindowW('PokeTokenBarSink', [NullString]::Value) }

# Starts the exe with a Path that has no Swift toolchain (the app must not need it) and waits for its sink window.
function Start-App([string]$Exe, [string[]]$AppArgs = @()) {
    $old = $env:Path
    $env:Path = 'C:\Windows\System32;C:\Windows'
    try {
        $p = if ($AppArgs.Count) { Start-Process -FilePath $Exe -ArgumentList $AppArgs -PassThru } else { Start-Process -FilePath $Exe -PassThru }
    } finally { $env:Path = $old }
    $null = $p.Handle
    for ($i = 0; $i -lt 150; $i++) {
        if ($p.HasExited) { throw "the app exited early (code $($p.ExitCode))" }
        $h = Find-Sink
        if ($h -ne [IntPtr]::Zero) { return @($p, $h) }
        Start-Sleep -Milliseconds 200
    }
    throw 'the app made no sink window in 30 s'
}

function Close-App($p, $h) {
    $null = [PtbCi]::PostMessageW($h, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)  # WM_CLOSE
    if (-not $p.WaitForExit(20000)) { Stop-Process -Id $p.Id -Force; throw 'WM_CLOSE did not end the app in 20 s' }
    if ($p.ExitCode -ne 0) { throw "WM_CLOSE: exit code $($p.ExitCode)" }
}

function Get-MemberId {
    if (-not (Test-Path $script:PtbPlist)) { return $null }
    $m = [regex]::Match((Get-Content $script:PtbPlist -Raw), '<key>team\.memberID</key>\s*<string>([^<]+)</string>')
    if ($m.Success) { $m.Groups[1].Value } else { $null }
}

function Get-RunValue { (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'PokeTokenBar' -ErrorAction SilentlyContinue).PokeTokenBar }

function Assert-That([bool]$ok, [string]$name, [string]$detail) {
    Write-Host ("{0} {1}: {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail)
    if (-not $ok) { throw "FAIL $name" }
}

# ---- Setup runs as an in-app update does (failed-update-relaunch step) ----
if (-not ([System.Management.Automation.PSTypeName]'PtbCiProc').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PtbCiProc {
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool GetTokenInformation(IntPtr token, int cls, out int value, int length, out int returned);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    // "elevated=<0|1> type=<1 default|2 full|3 limited>" of a process's token (TokenElevation 20, TokenElevationType 18).
    public static string Elevation(int pid) {
        IntPtr p = OpenProcess(0x1000, false, pid);  // PROCESS_QUERY_LIMITED_INFORMATION
        if (p == IntPtr.Zero) return "unknown (OpenProcess " + Marshal.GetLastWin32Error() + ")";
        try {
            IntPtr t;
            if (!OpenProcessToken(p, 0x0008, out t)) return "unknown (OpenProcessToken " + Marshal.GetLastWin32Error() + ")";
            try {
                int elevated, type, n;
                if (!GetTokenInformation(t, 20, out elevated, 4, out n) || !GetTokenInformation(t, 18, out type, 4, out n))
                    return "unknown (GetTokenInformation " + Marshal.GetLastWin32Error() + ")";
                return "elevated=" + elevated + " type=" + type;
            } finally { CloseHandle(t); }
        } finally { CloseHandle(p); }
    }
}
'@
}

# ISCC.exe, as the build job's installer step finds it; installs Inno Setup when this runner image lacks it (the updates job
# is a fresh runner that never ran the build job's step).
function Get-Iscc {
    $iscc = (Get-Command iscc.exe -ErrorAction SilentlyContinue).Source
    if (-not $iscc) { $iscc = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe' }
    if (-not (Test-Path $iscc)) {
        choco install innosetup -y --no-progress | Out-Host
        $iscc = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'
    }
    if (-not (Test-Path $iscc)) { throw "ISCC.exe not found at $iscc (also not after choco install innosetup)" }
    $iscc
}

# Starts a setup exe (or an uninstaller) and waits for IT only (Start-Process -Wait would also wait for the app Setup
# starts). Exit code. It never waits longer than -TimeoutSec: then it names the windows on screen (a message box waiting
# for a click shows here), kills every Setup and uninstaller process, prints the end of the /LOG file and FAILS.
# -WorkingDirectory: the folder Setup inherits as its working folder (the app starts it from its own folder).
function Invoke-Setup([string]$Setup, [string[]]$SetupArgs, [int]$TimeoutSec = 180, [string]$WorkingDirectory = '') {
    $p = if ($WorkingDirectory) { Start-Process -FilePath $Setup -ArgumentList $SetupArgs -WorkingDirectory $WorkingDirectory -PassThru } else { Start-Process -FilePath $Setup -ArgumentList $SetupArgs -PassThru }
    $null = $p.Handle
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        $windows = [PtbCiWizard]::Describe('#32770')  # #32770: a dialog, which is what a message box is
        Stop-Setups
        $log = @($SetupArgs | Where-Object { $_ -like '/LOG=*' }) | Select-Object -First 1
        $log = "$log" -replace '^/LOG=', '' -replace '"', ''
        if ($log -and (Test-Path $log)) { Write-Host "---- the last lines of $log ----"; Get-Content $log -Tail 40 | Write-Host }
        throw "FAIL setup.timeout: $(Split-Path $Setup -Leaf) did not end in $TimeoutSec s; killed every Setup process; windows on screen: $windows"
    }
    $p.ExitCode
}

# The in-app update's arguments (stage 8 D8 step 6), in that order.
function Get-UpdateSetupArgs([string]$LogFile, [string]$RelaunchOnFail = '1') {
    @('/SILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CURRENTUSER', "/PTBRELAUNCHONFAIL=$RelaunchOnFail", "/LOG=`"$LogFile`"")
}

# "DOMAIN\user elevated=.. type=.." of a process.
function Get-ProcessIdentity([int]$ProcessId) {
    $cim = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId"
    if (-not $cim) { return "process $ProcessId is gone" }
    $owner = Invoke-CimMethod -InputObject $cim -MethodName GetOwner
    "$($owner.Domain)\$($owner.User) $([PtbCiProc]::Elevation($ProcessId))"
}

# Relative path -> SHA-256 of every file under a folder.
function Get-FolderHashes([string]$Dir) {
    $hashes = @{}
    $root = (Resolve-Path $Dir).Path
    foreach ($f in Get-ChildItem $root -Recurse -File) {
        $s = [System.IO.File]::Open($f.FullName, 'Open', 'Read', 'ReadWrite, Delete')
        try { $hashes[$f.FullName.Substring($root.Length + 1)] = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($s)) } finally { $s.Close() }
    }
    $hashes
}

# The relative paths whose contents differ, appeared or went away between two Get-FolderHashes results.
function Compare-FolderHashes($Before, $After) {
    @(@($Before.Keys) + @($After.Keys) | Sort-Object -Unique | Where-Object { $Before[$_] -ne $After[$_] })
}

# Every PokeTokenBar Setup process (the loader and the Setup it extracted, a .tmp exe) and uninstaller (unins000.exe and
# the copy it runs from TEMP, _unins.tmp: .NET keeps a .tmp extension in the process name, hence the wildcards).
function Stop-Setups { Get-Process -Name 'PokeTokenBar-Setup-*', 'unins000', '_unins*' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue }

# Runs a setup exe with its wizard (a double-click; only /LOG added) and clicks it through: Next on every page, Install,
# Finish (the Finish page's launch box stays as Setup sets it), and records the page title after each click. Exit code.
if (-not ([System.Management.Automation.PSTypeName]'PtbCiWizard').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class PtbCiWizard {
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent, EnumProc f, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder sb, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h, StringBuilder sb, int n);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindowEnabled(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr SendMessageTimeoutW(IntPtr h, uint msg, IntPtr w, IntPtr l, uint flags, uint ms, out IntPtr result);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    static string Cls(IntPtr h) { var sb = new StringBuilder(256); GetClassNameW(h, sb, 256); return sb.ToString(); }
    static string Text(IntPtr h) { var sb = new StringBuilder(256); GetWindowTextW(h, sb, 256); return sb.ToString(); }
    static IntPtr Find(string cls) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => { if (IsWindowVisible(h) && Cls(h) == cls) { found = h; return false; } return true; }, IntPtr.Zero);
        return found;
    }
    // The visible top-level windows and the wizard's child controls, for a failure message.
    public static string Describe(string cls) {
        var lines = new List<string>();
        EnumWindows((h, l) => { if (IsWindowVisible(h)) lines.Add(Cls(h) + " '" + Text(h) + "'"); return true; }, IntPtr.Zero);
        IntPtr w = Find(cls);
        if (w != IntPtr.Zero)
            EnumChildWindows(w, (h, l) => { lines.Add("  child " + Cls(h) + " '" + Text(h) + "' visible=" + IsWindowVisible(h) + " enabled=" + IsWindowEnabled(h)); return true; }, IntPtr.Zero);
        return string.Join(" | ", lines);
    }
    // The first visible static text of the window of class cls: the wizard page's title.
    public static string Title(string cls) {
        IntPtr w = Find(cls);
        string title = null;
        if (w != IntPtr.Zero)
            EnumChildWindows(w, (h, l) => { if (IsWindowVisible(h) && Cls(h) == "TNewStaticText" && Text(h).Length > 0) { title = Text(h); return false; } return true; }, IntPtr.Zero);
        return title;
    }
    // Clicks (BM_CLICK, sent with a 2 s timeout: Install runs the whole installation inside the click) the first visible,
    // enabled button of the visible window of class cls whose text without '&' starts with one of the prefixes (in their
    // order). A WM_COMMAND posted to the parent did not turn the page on the runner. The text clicked, or null.
    public static string Click(string cls, string[] prefixes) {
        IntPtr w = Find(cls);
        if (w == IntPtr.Zero) return null;
        var buttons = new List<IntPtr>();
        EnumChildWindows(w, (h, l) => { if (IsWindowVisible(h) && IsWindowEnabled(h) && Cls(h).IndexOf("Button", StringComparison.OrdinalIgnoreCase) >= 0) buttons.Add(h); return true; }, IntPtr.Zero);
        foreach (var prefix in prefixes)
            foreach (var b in buttons) {
                var t = Text(b).Replace("&", "");
                if (!t.StartsWith(prefix)) continue;
                IntPtr r;
                SetForegroundWindow(w);
                SendMessageTimeoutW(b, 0x00F5, IntPtr.Zero, IntPtr.Zero, 0x0002, 2000, out r);  // BM_CLICK, SMTO_ABORTIFHUNG
                return t;
            }
        return null;
    }
}
'@
}
function Invoke-SetupWizard([string]$Setup, [string]$LogFile, [int]$TimeoutSec = 180) {
    $p = Start-Process -FilePath $Setup -ArgumentList "/LOG=`"$LogFile`"" -PassThru
    $null = $p.Handle
    $clicked = @()
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while (-not $p.HasExited) {
        if ((Get-Date) -gt $deadline) {
            $windows = [PtbCiWizard]::Describe('TWizardForm')
            Stop-Process -Id $p.Id -Force
            Get-Process -Name 'PokeTokenBar-Setup-*' -ErrorAction SilentlyContinue | Stop-Process -Force  # the wizard's own process (.tmp)
            throw "the wizard did not finish in $TimeoutSec s ($($clicked.Count) clicks, the first: $(($clicked | Select-Object -First 8) -join ', ')); windows: $windows"
        }
        $t = [PtbCiWizard]::Click('TWizardForm', [string[]]@('Finish', 'Install', 'Next'))
        if ($t) {
            Start-Sleep -Milliseconds 1500
            $clicked += "$t (page now '$([PtbCiWizard]::Title('TWizardForm'))')"
        } else { Start-Sleep -Milliseconds 300 }
    }
    "wizard buttons clicked: $($clicked -join ' > ')" | Write-Host
    $p.ExitCode
}

# A PokeTokenBar process other than the given ids, with its sink window: @(process, hwnd), or $null after $Seconds.
function Wait-OtherApp([int[]]$NotIds = @(), [int]$Seconds = 30) {
    for ($i = 0; $i -lt $Seconds * 5; $i++) {
        $p = Get-Process PokeTokenBar -ErrorAction SilentlyContinue | Where-Object { $NotIds -notcontains $_.Id } | Select-Object -First 1
        if ($p) {
            $null = $p.Handle
            for ($j = 0; $j -lt 150; $j++) {
                $h = Find-Sink
                if ($h -ne [IntPtr]::Zero) { return @($p, $h) }
                if ($p.HasExited) { throw "the started app exited early (code $($p.ExitCode))" }
                Start-Sleep -Milliseconds 200
            }
            throw 'the started app made no sink window in 30 s'
        }
        Start-Sleep -Milliseconds 200
    }
    $null
}
# ---- end failed-update-relaunch helpers ----
