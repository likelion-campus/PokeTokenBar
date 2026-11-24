# DIAGNOSTIC (branch diag/update-runner-loss-2 only). Repeats one part of the in-app update for -Minutes, to find which part takes
# the VM down (experiment 6). Every phase is written to collected\in-app-update\iteration.txt first, so the heartbeats (scheduled
# tasks posting check runs) name the phase a lost runner was in.
#   appSetup   vN installed; the app started with the update flag downloads vN+1 from a loopback feed and starts its Setup, which
#              installs and starts vN+1 (the ok scenario's update, as a loop)
#   fakeSetup  the same, but the feed's "Setup" is a copy of dllhost.exe (a GUI-subsystem program that ends at once on these
#              arguments, so no console window either): the app downloads, checks and starts it and leaves; nothing is installed
#              (the app's side alone)
#   pwshSetup  vN installed; Setup of vN+1 started from pwsh as the app starts it (the in-app switches, the Logs folder as working
#              folder, a Path of System32 and Windows only), no app involved (Setup's side alone)
param([Parameter(Mandatory)] [ValidateSet('appSetup', 'fakeSetup', 'pwshSetup')] [string]$Arm,
      [Parameter(Mandatory)] [string]$Version, [Parameter(Mandatory)] [string]$NextVersion, [int]$Minutes = 9)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/ci-helpers.ps1"
$dir = (Resolve-Path 'collected\in-app-update').Path
$mark = Join-Path $dir 'iteration.txt'
$exe = Join-Path $PtbInstallDir 'PokeTokenBar.exe'
$versionFile = Join-Path $PtbInstallDir 'PokeTokenBar.version'
$logs = Join-Path $env:LOCALAPPDATA 'PokeTokenBar\Logs'
$setupV = (Resolve-Path "installer-out\PokeTokenBar-Setup-$Version-win-x64.exe").Path
$setupNext = (Resolve-Path "installer-next\PokeTokenBar-Setup-$NextVersion-win-x64.exe").Path
$fake = Join-Path $dir 'fake-setup.exe'
Copy-Item "$env:SystemRoot\System32\dllhost.exe" $fake -Force
function Phase([int]$I, [string]$What) { $t = (Get-Date).ToUniversalTime().ToString('HH:mm:ss'); "$Arm i=$I $What $t" | Set-Content $mark; "$t i=$I $What" }
function Get-InstalledVersion { if (Test-Path $versionFile) { (Get-Content $versionFile -Raw).Trim() } else { '<none>' } }
function Stop-Apps { Stop-Setups; Get-Process PokeTokenBar -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep -Milliseconds 500 }
function Wait-Until([scriptblock]$Condition, [int]$Seconds) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) { if (& $Condition) { return $true }; Start-Sleep -Milliseconds 250 }
    [bool](& $Condition)
}
function Read-Port([string]$PortFile) { $text = Get-Content $PortFile -Raw -ErrorAction SilentlyContinue; if ($text) { $text.Trim() -as [int] } else { $null } }
# A fake Setup leaves the pending-update mark, so the next start would hold the version back; every iteration starts without both.
function Clear-UpdateMarks {
    if (-not (Test-Path $PtbPlist)) { return }
    $xml = Get-Content $PtbPlist -Raw
    $xml = $xml -replace '<key>windows\.failedUpdateVersion</key>\s*<string>[^<]*</string>', ''
    $xml = $xml -replace '(?s)<key>windows\.pendingUpdate</key>\s*<dict>.*?</dict>', ''
    Set-Content -Path $PtbPlist -Value $xml -NoNewline -Encoding utf8NoBOM
}
function Install-Baseline([int]$I) {
    Phase $I 'baseline'
    Stop-Apps
    $code = Invoke-Setup $setupV @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/CURRENTUSER', '/NORESTART', '/NOLAUNCH=1', "/LOG=`"$(Join-Path $dir 'loop-baseline.log')`"")
    if ($code -ne 0 -or (Get-InstalledVersion) -ne $Version) { throw "baseline: exit $code, version $(Get-InstalledVersion)" }
}
function Start-Feed([int]$I, [string]$Payload) {
    Phase $I 'feed'
    $portFile = Join-Path $dir 'loop-port.txt'; $requests = Join-Path $dir 'loop-requests.log'
    Remove-Item -ErrorAction SilentlyContinue $portFile, $requests
    New-Item -ItemType File -Path $requests | Out-Null
    $p = Start-Process pwsh -ArgumentList '-NoProfile', '-File', (Join-Path $PSScriptRoot 'update-feed-server.ps1'), '-Payload', $Payload,
        '-Version', $NextVersion, '-Mode', 'ok', '-PortFile', $portFile, '-LogFile', $requests -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput (Join-Path $dir 'loop-feed.txt')
    if (-not (Wait-Until { (Read-Port $portFile) -gt 0 } 30)) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; throw 'no feed in 30 s' }
    [pscustomobject]@{ Process = $p; Port = (Read-Port $portFile) }
}
$start = Get-Date
$i = 0; $done = 0
while ((Get-Date) -lt $start.AddMinutes($Minutes)) {
    $i++
    $feed = $null
    try {
        Clear-UpdateMarks
        if ($Arm -eq 'pwshSetup') {
            if ((Get-InstalledVersion) -ne $Version) { Install-Baseline $i }
            Phase $i 'setup'
            $old = $env:Path; $env:Path = 'C:\Windows\System32;C:\Windows'
            try { $code = Invoke-Setup $setupNext (Get-UpdateSetupArgs (Join-Path $logs "update-$NextVersion.log")) -WorkingDirectory $logs } finally { $env:Path = $old }
            Phase $i "setup exit $code; waiting for the new app"
            $new = Wait-OtherApp -Seconds 30
            Phase $i "new app $(if ($new) { $new[0].Id } else { 'none' }) version $(Get-InstalledVersion)"
        } else {
            if ((Get-InstalledVersion) -ne $Version) { Install-Baseline $i }
            $feed = Start-Feed $i $(if ($Arm -eq 'fakeSetup') { $fake } else { $setupNext })
            Phase $i 'update'
            $app, $null = Start-App $exe @('--selftest-update-from', "http://127.0.0.1:$($feed.Port)/releases/latest")
            $left = $app.WaitForExit(60000)
            Phase $i "app left=$left$(if ($left) { " code $($app.ExitCode)" })"
            if ($Arm -eq 'appSetup') {
                $new = Wait-OtherApp -NotIds @($app.Id) -Seconds 60
                Phase $i "new app $(if ($new) { $new[0].Id } else { 'none' }) version $(Get-InstalledVersion)"
            } else { Start-Sleep -Seconds 2 }
        }
        $done++
    } catch { Phase $i "error: $($_.Exception.Message)" }
    finally {
        if ($feed) { Stop-Process -Id $feed.Process.Id -Force -ErrorAction SilentlyContinue }
        Stop-Apps
    }
}
Phase $i "end: $done of $i iterations completed in $([int]((Get-Date) - $start).TotalSeconds) s"
