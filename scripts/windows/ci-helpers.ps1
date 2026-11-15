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
