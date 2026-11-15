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
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class PtbCiProc {
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool GetTokenInformation(IntPtr token, int cls, out int value, int length, out int returned);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [StructLayout(LayoutKind.Sequential)] struct ByHandleInfo { public uint Attrs, C1, C2, A1, A2, W1, W2, Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow; }
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetFileInformationByHandle(SafeFileHandle h, out ByHandleInfo info);
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
    // The NTFS file id: a file Setup replaced (new file renamed over the name) gets a new one; tunnelling keeps the
    // creation time of a name deleted and re-created within 15 s, so the creation time cannot tell.
    public static string FileId(string path) {
        using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)) {
            ByHandleInfo i;
            if (!GetFileInformationByHandle(fs.SafeFileHandle, out i)) return "unknown";
            return i.IndexHigh.ToString("x8") + i.IndexLow.ToString("x8");
        }
    }
}
'@
}

# ISCC.exe, as the installer step finds it (that step installs Inno Setup when the image lacks it).
function Get-Iscc {
    $iscc = (Get-Command iscc.exe -ErrorAction SilentlyContinue).Source
    if (-not $iscc) { $iscc = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe' }
    if (-not (Test-Path $iscc)) { throw "ISCC.exe not found at $iscc" }
    $iscc
}

# Starts a setup exe and waits for IT only (Start-Process -Wait would also wait for the app Setup starts). Exit code.
function Invoke-Setup([string]$Setup, [string[]]$SetupArgs, [int]$TimeoutSec = 180) {
    $p = Start-Process -FilePath $Setup -ArgumentList $SetupArgs -PassThru
    $null = $p.Handle
    if (-not $p.WaitForExit($TimeoutSec * 1000)) { Stop-Process -Id $p.Id -Force; throw "$Setup did not end in $TimeoutSec s" }
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

# Relative path -> NTFS file id of every file under a folder.
function Get-FolderFileIds([string]$Dir) {
    $ids = @{}
    $root = (Resolve-Path $Dir).Path
    foreach ($f in Get-ChildItem $root -Recurse -File) { $ids[$f.FullName.Substring($root.Length + 1)] = [PtbCiProc]::FileId($f.FullName) }
    $ids
}

# The relative paths whose file id differs, appeared or went away between two Get-FolderFileIds results.
function Compare-FolderFileIds($Before, $After) {
    @(@($Before.Keys) + @($After.Keys) | Sort-Object -Unique | Where-Object { $Before[$_] -ne $After[$_] })
}

# Runs a setup exe with its wizard (a double-click; only /LOG added) and clicks it through with UI Automation:
# Next on every page, Install, Finish (the Finish page's launch box stays as Setup sets it). Exit code.
function Invoke-SetupWizard([string]$Setup, [string]$LogFile, [int]$TimeoutSec = 180) {
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
    $ae = [System.Windows.Automation.AutomationElement]
    $p = Start-Process -FilePath $Setup -ArgumentList "/LOG=`"$LogFile`"" -PassThru
    $null = $p.Handle
    $wizardCond = New-Object System.Windows.Automation.PropertyCondition($ae::ClassNameProperty, 'TWizardForm')
    $buttonCond = New-Object System.Windows.Automation.PropertyCondition($ae::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
    $clicked = @()
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while (-not $p.HasExited) {
        if ((Get-Date) -gt $deadline) { Stop-Process -Id $p.Id -Force; throw "the wizard did not finish in $TimeoutSec s (clicked: $($clicked -join ', '))" }
        $wizard = $ae::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Children, $wizardCond)
        if ($wizard) {
            $buttons = @($wizard.FindAll([System.Windows.Automation.TreeScope]::Descendants, $buttonCond) |
                Where-Object { $_.Current.IsEnabled -and -not $_.Current.IsOffscreen -and $_.Current.Name -match '^&?(Next|Install|Finish)' })
            if ($buttons.Count) {
                $b = $buttons[0]
                $clicked += $b.Current.Name
                $b.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
                Start-Sleep -Milliseconds 800
                continue
            }
        }
        Start-Sleep -Milliseconds 300
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
