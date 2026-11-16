# A failed update brings the old app back (windows-app.yml, step id failed-update-relaunch, full level).
# Setup runs as the in-app update will run it (stage 8 D8 step 6: /SILENT /SUPPRESSMSGBOXES /NORESTART /CURRENTUSER
# /PTBRELAUNCHONFAIL=1 /LOG="..."), over the installed vN, mostly while it runs. Scenarios:
#   wizard            a first install as a double-click runs it (the wizard, clicked through): no previous app, no
#                     relaunch from [Code], the Finish page starts the app.
#   fresh             a first install with the CI steps' silent switches: nothing started.
#   minVersion        the shipped script with MinVersion one build above this runner: exit 1 before any [Code], the
#                     running app neither closed nor restarted.
#   fromAppFolder     Setup started with the install folder as its working folder (as the app starts it), a failure
#                     after the exe was written: the previous contents come back, the app starts again.
#   failBeforeCopy    PrepareToInstall fails after the copy: exit 7, nothing touched, the copy removed, vN again.
#   failControl       the same with /PTBRELAUNCHONFAIL=0: nothing starts.
#   failDuringCopy    a failure after the exe was written: exit 5, previous contents back, vN again.
#   inAppOrder        the app already exited (mutex free) when Setup starts, then the same failure: vN again.
#   backupFails       the copy cannot be made: exit 7 before anything is touched, vN again.
#   lockedFile        the SHIPPED vN+1 installer while a licence file is held open: exit 5, exe and version kept, vN again.
#   failedRestore     a replaced file held open while Setup puts files back: no start, the complete copy kept; the
#                     next Setup recovers.
#   twoSetups         a second Setup while the first is in the copy: the second stops (exit 1) and starts nothing; the
#                     first fails and brings vN back.
#   staleComplete     a left-over copy of another version next to a complete app folder: removed, the update goes on.
#   staleIncomplete   a left-over copy next to a folder without the exe: put back first, the app starts again.
#   killedMidCopy     Setup killed after the exe was written: the folder still starts; the next Setup puts the copy
#                     back first (same version in both) and finishes.
#   failLate          a failure after every file, the version file too, was written: all of it comes back.
#   leftOverRestoreFails  a complete left-over copy that cannot be put back: exit 7, nothing installed or started.
#   noVersionFile     an exe without a version file next to a complete copy: put back first.
#   partialCopy       the copy fails part way: the partial copy goes, exit 7, nothing touched, vN again.
#   appFolderMissing  the app folder gone next to a complete copy: put back whole into a new folder.
#   killedFirstEntry  Setup killed after 5 files of the first [Files] entry: the folder starts; the next Setup finishes.
#   killedDuringRestore  Setup killed while putting files back after a late failure: the version file went back
#                     first, so the next Setup puts the copy back again (and, failing too, leaves vN).
#   appDoesNotClose   the app never closes (its mutex held, nothing answers WM_CLOSE): silent Setup ends by itself
#                     (exit 1) within its bound, touches nothing, starts nothing; uninstallAppDoesNotClose: the same
#                     for the silent uninstaller.
#   updateOk          the shipped vN+1 installer: exit 0, one vN+1 process from [Run], the copy removed; its time and size.
# The test builds install bundle-test: vN+1 with one byte appended to every file but the version file and THIRD-PARTY.txt
# (same size, same time, another first byte), so "the previous contents came back" is a SHA-256 comparison (a file
# copied back keeps the file id of the one Setup wrote) and the restore must compare contents, not size and time.
# Every check prints one PASS/FAIL line. A failed scenario is reported and the next one still runs; the script fails at
# the end. From the repository root, after the full-level installer step (bundle-next, installer-out, installer-next):
#   ./scripts/windows/failed-update-relaunch.ps1 -Version <vN> -NextVersion <vN+1>
param(
    [Parameter(Mandatory)] [string]$Version,
    [Parameter(Mandatory)] [string]$NextVersion,
    [string]$LogDir = 'collected\failed-update'
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/ci-helpers.ps1"

$root = (Get-Location).Path
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogDir = (Resolve-Path $LogDir).Path
$exe = Join-Path $PtbInstallDir 'PokeTokenBar.exe'
$versionFile = Join-Path $PtbInstallDir 'PokeTokenBar.version'
$aside = "$PtbInstallDir.previous"
$appLog = Join-Path $env:LOCALAPPDATA 'PokeTokenBar\Logs\PokeTokenBar.log'
$setupV = (Resolve-Path "installer-out\PokeTokenBar-Setup-$Version-win-x64.exe").Path
$setupNext = (Resolve-Path "installer-next\PokeTokenBar-Setup-$NextVersion-win-x64.exe").Path
$pauseDir = Join-Path $env:RUNNER_TEMP 'ptb-setup-pause'
$build = [Environment]::OSVersion.Version.Build
$me = Get-ProcessIdentity $PID
$failures = [System.Collections.Generic.List[string]]::new()
"invoking shell: $me; Windows $([Environment]::OSVersion.Version)"

function Get-InstalledVersion { if (Test-Path $versionFile) { (Get-Content $versionFile -Raw).Trim() } else { '<none>' } }
function Get-AppLogCount([string]$Text) { if (Test-Path $appLog) { ([regex]::Matches((Get-Content $appLog -Raw), [regex]::Escape($Text))).Count } else { 0 } }
function Stop-Apps { Stop-Setups; Get-Process PokeTokenBar -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep -Milliseconds 500 }
function Read-SetupLog([string]$Path) {
    $text = if (Test-Path $Path) { Get-Content $Path -Raw } else { '' }
    # The lines that tell what Setup did, for the job log.
    foreach ($line in $text -split "`r?`n") {
        if ($line -match 'PTB setup:|PTB uninstall:|PTB update:|PTB relaunch:|PTBTest|InitializeSetup|Rolling back|suppressed message box|User canceled|Installation process succeeded|Setup version:|does not support') { "  setup: $line" | Write-Host }
    }
    $text
}
# When a setup-log line was written (Inno prefixes each with a millisecond time).
function Get-SetupLogTime([string]$Text, [string]$Needle) {
    $m = [regex]::Match($Text, '(?m)^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3})\s+' + [regex]::Escape($Needle))
    if ($m.Success) { [datetime]::ParseExact($m.Groups[1].Value, 'yyyy-MM-dd HH:mm:ss.fff', $null) } else { $null }
}
function Set-StatusChecksOff {
    $xml = Get-Content $PtbPlist -Raw
    $xml = $xml -replace '<key>statusChecksEnabled</key>\s*<(true|false)/>', ''
    $xml = $xml -replace '</dict>\s*</plist>\s*$', '<key>statusChecksEnabled</key><false/></dict></plist>'
    Set-Content -Path $PtbPlist -Value $xml -NoNewline -Encoding utf8NoBOM
}
function Test-StatusChecksOff { (Get-Content $PtbPlist -Raw) -match '<key>statusChecksEnabled</key>\s*<false/>' }
# A copy as a Setup that did not end leaves it: the app folder, marked complete; -CopyVersion gives its version file another.
function New-LeftOverCopy([string]$CopyVersion = '') {
    Copy-Item $PtbInstallDir $aside -Recurse
    Set-Content -Path (Join-Path $aside 'PTB-backup-complete.txt') -Value 'left over'
    if ($CopyVersion) { Set-Content -Path (Join-Path $aside 'PokeTokenBar.version') -Value $CopyVersion -NoNewline }
}
# A process that holds a file open: -Share Read lets others read it (not write), None lets nobody open it.
function Start-Holder([string]$Path, [string]$Share = 'Read') {
    $h = Start-Process pwsh -ArgumentList '-NoProfile', '-Command', "`$f = [System.IO.File]::Open('$Path', 'Open', 'Read', '$Share'); Start-Sleep -Seconds 600" -PassThru -WindowStyle Hidden
    for ($i = 0; $i -lt 50; $i++) {
        Start-Sleep -Milliseconds 200
        try { ([System.IO.File]::Open($Path, 'Open', 'ReadWrite', 'ReadWrite')).Close() } catch { return $h }
    }
    Stop-Process -Id $h.Id -Force -ErrorAction SilentlyContinue
    throw "could not hold $Path open"
}
function Test-CompleteCopy { (Test-Path (Join-Path $aside 'PTB-backup-complete.txt')) -and (Test-Path (Join-Path $aside 'PokeTokenBar.exe')) }

# vN installed (an update vN over vN through the same Setup), nothing running, no copy left.
function Install-Baseline([string]$Tag) {
    Stop-Apps
    $log = Join-Path $LogDir "$Tag-baseline.log"
    $code = Invoke-Setup $setupV @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/CURRENTUSER', '/NORESTART', '/NOLAUNCH=1', "/LOG=`"$log`"")
    if ($code -ne 0 -or (Get-InstalledVersion) -ne $Version -or (Test-Path $aside)) { throw "baseline install of ${Version}: exit $code, version $(Get-InstalledVersion), copy left: $(Test-Path $aside)" }
}

function Start-Installed {
    $p, $h = Start-App $exe
    Start-Sleep -Seconds 2
    @($p, $h)
}

# A test build started with the pause switch (no wait): it stops after the exe was written until Resume-Setup.
# -At: exe (after the exe), first (after 5 files of the first [Files] entry) or restore (after the first file put back).
function Start-PausedSetup([string]$Setup, [string]$LogFile, [string]$WorkingDirectory = $root, [string]$At = 'exe') {
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $pauseDir
    New-Item -ItemType Directory -Force -Path $pauseDir | Out-Null
    $p = Start-Process -FilePath $Setup -ArgumentList ((Get-UpdateSetupArgs $LogFile) + "/PTBTESTPAUSE=`"$pauseDir`"" + "/PTBTESTPAUSEAT=$At") -WorkingDirectory $WorkingDirectory -PassThru
    $null = $p.Handle
    for ($i = 0; $i -lt 450 -and -not (Test-Path (Join-Path $pauseDir 'paused')); $i++) {
        if ($p.HasExited) { throw "the paused Setup ended early (exit $($p.ExitCode))" }
        Start-Sleep -Milliseconds 200
    }
    if (-not (Test-Path (Join-Path $pauseDir 'paused'))) { throw 'the test build did not reach its pause point in 90 s' }
    $p
}
function Resume-Setup($P, [int]$TimeoutSec = 180) {
    Set-Content -Path (Join-Path $pauseDir 'resume') -Value 'go'
    if (-not $P.WaitForExit($TimeoutSec * 1000)) { Stop-Setups; throw "the resumed Setup did not end in $TimeoutSec s" }
    $P.ExitCode
}

function Assert-OldClosed([string]$Tag, $Old, [int]$ClosesBefore) {
    $after = Get-AppLogCount 'exit code=0 reason=closeRequest'
    Assert-That ($Old.HasExited -and $Old.ExitCode -eq 0 -and $after -eq $ClosesBefore + 1) "$Tag.oldClosed" "old pid $($Old.Id) exited=$($Old.HasExited) code=$($Old.ExitCode); closeRequest exit lines $ClosesBefore -> $after"
}

# The one app process Setup started: from the install folder, the expected version, the invoking user and token,
# memberID and the setting kept. Closes it.
function Assert-Started([string]$Tag, $Old, [string]$ExpectVersion) {
    $new = Wait-OtherApp -NotIds @($(if ($Old) { $Old.Id })) -Seconds 30
    Assert-That ($null -ne $new) "$Tag.started" 'a PokeTokenBar process started after Setup ended'
    $p, $h = $new
    Assert-That ($p.Path -eq $exe) "$Tag.fromInstallFolder" $p.Path
    Start-Sleep -Seconds 2
    $all = @(Get-Process PokeTokenBar -ErrorAction SilentlyContinue)
    Assert-That ($all.Count -eq 1) "$Tag.oneInstance" "PokeTokenBar processes: $($all.Count)"
    Assert-That ((Get-InstalledVersion) -eq $ExpectVersion) "$Tag.version" "version file $(Get-InstalledVersion), expected $ExpectVersion"
    $id = Get-ProcessIdentity $p.Id
    Assert-That ($id -eq $me) "$Tag.sameUserAndToken" "app: $id; invoking shell: $me"
    $member = Get-MemberId
    Assert-That ($member -eq $script:memberId) "$Tag.memberIdKept" "before=$script:memberId after=$member"
    Assert-That (Test-StatusChecksOff) "$Tag.settingKept" 'statusChecksEnabled still false'
    Close-App $p $h
}

# -AfterFinishedSetup: a finished install appends to the uninstall log, so unins000.dat may differ.
function Assert-PreviousContents([string]$Tag, $Before, [switch]$AfterFinishedSetup) {
    $changed = @(Compare-FolderHashes $Before (Get-FolderHashes $PtbInstallDir) | Where-Object { -not $AfterFinishedSetup -or $_ -ne 'unins000.dat' })
    Assert-That ($changed.Count -eq 0 -and -not (Test-Path $aside)) "$Tag.previousContents" "files whose SHA-256 differs from before the update: $($changed.Count) of $($Before.Count) ($(($changed | Select-Object -First 6) -join ', ')); copy left: $(Test-Path $aside)"
}

function Invoke-Scenario([string]$Name, [scriptblock]$Body) {
    "---- $Name ----"
    try { Stop-Apps; & $Body }
    catch { $failures.Add($Name); "FAIL $Name stopped: $($_.Exception.Message)" }
    finally {
        Stop-Apps
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $pauseDir
        if (Test-Path $aside -PathType Leaf) { Remove-Item -Force $aside }  # backupFails' blocker
    }
}

# The test payload, the test builds and the MinVersion probe, side by side.
$iscc = Get-Iscc
"ISCC: $iscc (the Inno version is the 'Setup version' line of each setup log)"
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue bundle-test
Copy-Item bundle-next bundle-test -Recurse
# Every file but the version file gets one byte more; THIRD-PARTY.txt keeps its size AND its time and gets another first
# byte, so only a comparison of contents tells it from vN's (Inno rounds installed times to 2 s, and version files keep
# their length between versions).
$sameSize = Join-Path $root 'bundle-test\licenses\THIRD-PARTY.txt'
foreach ($f in Get-ChildItem bundle-test -Recurse -File | Where-Object { $_.Name -ne 'PokeTokenBar.version' -and $_.FullName -ne $sameSize }) {
    $s = [System.IO.File]::Open($f.FullName, 'Append'); try { $s.WriteByte(0) } finally { $s.Close() }
}
$time = (Get-Item $sameSize).LastWriteTimeUtc
$s = [System.IO.File]::Open($sameSize, 'Open', 'ReadWrite'); try { $b = $s.ReadByte(); $s.Position = 0; $s.WriteByte(($b + 1) % 256) } finally { $s.Close() }
(Get-Item $sameSize).LastWriteTimeUtc = $time
$shipped = Get-Content (Join-Path $root 'installer\PokeTokenBar.iss') -Raw
$probeIss = Join-Path $root 'installer\ptb-minversion-probe.iss'
Set-Content -Path $probeIss -NoNewline -Value ($shipped -replace '(?m)^MinVersion=10\.0\.19045(\r?)$', "MinVersion=10.0.$($build + 1)`$1")
$builds = @(
    @{ Name = 'fail-prepare'; Src = 'bundle-test'; Defines = @('/DPTBTestFailInstall=1'); Iss = (Join-Path $root 'installer\PokeTokenBar.iss') },
    @{ Name = 'fail-copy'; Src = 'bundle-test'; Defines = @('/DPTBTestFailCopy=1'); Iss = (Join-Path $root 'installer\PokeTokenBar.iss') },
    @{ Name = 'fail-late'; Src = 'bundle-test'; Defines = @('/DPTBTestFailLate=1'); Iss = (Join-Path $root 'installer\PokeTokenBar.iss') },
    @{ Name = 'minversion-probe'; Src = 'bundle-next'; Defines = @('/DPTBTestBuild=1'); Iss = $probeIss }
)
$compiled = $builds | ForEach-Object -ThrottleLimit 4 -Parallel {
    $out = (New-Item -ItemType Directory -Force -Path (Join-Path $using:root "installer-$($_.Name)")).FullName
    $src = Join-Path $using:root $_.Src
    # Every /D goes through $isccArgs (the rule of the installer step): iscc-defines.json records them per output folder.
    $isccArgs = @("/DSrcDir=$src", "/DAppVer=$($using:NextVersion)", "/DOutDir=$out") + @($_.Defines)
    $text = & $using:iscc /Q @isccArgs $_.Iss 2>&1 | Out-String
    $names = @($isccArgs | Where-Object { $_ -like '/D*' } | ForEach-Object { ($_ -replace '^/D', '') -replace '=.*$', '' })
    [pscustomobject]@{ Name = $_.Name; Code = $LASTEXITCODE; Out = $out; Text = $text; Defines = $names }
}
foreach ($c in $compiled) { if ($c.Code -ne 0) { $c.Text; throw "ISCC failed for $($c.Name) (exit $($c.Code))" } }
# The test builds join the installer step's record; the release manifest reads only installer-out's entry.
$record = if (Test-Path iscc-defines.json) { Get-Content iscc-defines.json -Raw | ConvertFrom-Json -AsHashtable } else { [ordered]@{} }
foreach ($c in $compiled) { $record["installer-$($c.Name)"] = $c.Defines }
$record | ConvertTo-Json | Set-Content iscc-defines.json -Encoding utf8NoBOM
"iscc-defines.json: $(($record.Keys | ForEach-Object { "$_=$($record[$_] -join ',')" }) -join '; ')"
$out = @{}; foreach ($c in $compiled) { $out[$c.Name] = $c.Out }
$testName = "PokeTokenBar-Setup-$NextVersion-win-x64-TESTFAIL.exe"
$failPrepare = Join-Path $out['fail-prepare'] $testName
$failCopy = Join-Path $out['fail-copy'] $testName
$failLate = Join-Path $out['fail-late'] $testName
$probe = Join-Path $out['minversion-probe'] $testName
# Inno pads the strings of Setup's version resource with spaces (the loader's resource is patched in place): compare trimmed.
$tests = foreach ($c in $compiled) { foreach ($f in Get-ChildItem $c.Out -Filter *.exe) { [pscustomobject]@{ Name = $f.Name; Description = $f.VersionInfo.FileDescription.TrimEnd() } } }
$shippedDescriptions = foreach ($f in (Get-Item $setupV), (Get-Item $setupNext)) { $f.VersionInfo.FileDescription.TrimEnd() }
"raw FileDescription of the shipped installer: '$((Get-Item $setupNext).VersionInfo.FileDescription)' ($((Get-Item $setupNext).VersionInfo.FileDescription.Length) characters)"
Assert-That (@($tests).Count -eq 4 -and -not ($tests | Where-Object { $_.Name -ne $testName -or $_.Description -ne 'PokeTokenBar Setup TESTFAIL' }) -and
    -not ($shippedDescriptions | Where-Object { $_ -ne 'PokeTokenBar Setup' })) 'build.testInstallersMarked' "test builds: $(($tests | ForEach-Object { "$($_.Name) '$($_.Description)'" }) -join '; '); shipped FileDescription: '$($shippedDescriptions -join "', '")'"

Invoke-Scenario 'wizard' {
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $PtbInstallDir, $aside
    $log = Join-Path $LogDir 'wizard.log'
    $code = Invoke-SetupWizard $setupV $log
    $text = Read-SetupLog $log
    Assert-That ($code -eq 0 -and (Get-InstalledVersion) -eq $Version) 'wizard.installed' "exit $code, version $(Get-InstalledVersion)"
    Assert-That ($text -match 'PTB update: no previous app' -and $text -match 'PTB update: setup finished' -and $text -match 'PTB relaunch: no \(setup finished\)') 'wizard.defaultPath' 'no previous app; setup finished; relaunch: no (setup finished)'
    $new = Wait-OtherApp -Seconds 30
    Assert-That ($null -ne $new) 'wizard.finishLaunches' 'the Finish page started the app (its launch box is checked by default)'
    $p, $h = $new
    $id = Get-ProcessIdentity $p.Id
    Assert-That ($p.Path -eq $exe -and $id -eq $me) 'wizard.startedAsUser' "$($p.Path); $id"
    Close-App $p $h
}

Invoke-Scenario 'fresh' {
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $PtbInstallDir, $aside
    $log = Join-Path $LogDir 'fresh.log'
    $code = Invoke-Setup $setupV @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/CURRENTUSER', '/NORESTART', '/NOLAUNCH=1', "/LOG=`"$log`"")
    $text = Read-SetupLog $log
    Assert-That ($code -eq 0 -and (Get-InstalledVersion) -eq $Version) 'fresh.installed' "exit $code, version $(Get-InstalledVersion)"
    Assert-That ($text -match 'PTB update: no previous app' -and $text -match 'PTB update: setup finished' -and $text -match 'PTB relaunch: no \(setup finished\)') 'fresh.defaultPath' 'no previous app; setup finished; relaunch: no (setup finished)'
    Assert-That (-not (Get-Process PokeTokenBar -ErrorAction SilentlyContinue)) 'fresh.nothingStarted' '/NOLAUNCH=1 and no PTBRELAUNCHONFAIL: no process'
    $p, $h = Start-App $exe
    Start-Sleep -Seconds 3
    $script:memberId = Get-MemberId
    Assert-That ([bool]$script:memberId) 'fresh.memberId' "team.memberID=$script:memberId"
    Close-App $p $h
    Set-StatusChecksOff
    Assert-That (Test-StatusChecksOff) 'fresh.settingWritten' 'statusChecksEnabled=false in PokeTokenBar.exe.plist'
}

Invoke-Scenario 'minVersion' {
    Assert-That ($shipped -match '(?m)^MinVersion=10\.0\.19045\r?$' -and $shipped -match '(?m)^ArchitecturesAllowed=x64compatible\r?$') 'minVersion.shippedValues' 'MinVersion=10.0.19045, ArchitecturesAllowed=x64compatible'
    Assert-That ((Get-Content $probeIss -Raw) -match "(?m)^MinVersion=10\.0\.$($build + 1)\r?$") 'minVersion.probeScript' "the probe is the shipped script with MinVersion=10.0.$($build + 1) (this runner: build $build), built as a TESTFAIL test build"
    Install-Baseline 'minVersion'
    $old, $null = Start-Installed
    $log = Join-Path $LogDir 'minversion-probe.log'
    $code = Invoke-Setup $probe (Get-UpdateSetupArgs $log)
    $text = Read-SetupLog $log
    Assert-That ($code -eq 1) 'minVersion.exit' "exit $code"
    Assert-That ($text -match 'does not support the version of Windows') 'minVersion.refused' 'This program does not support the version of Windows (suppressed message box)'
    Assert-That ($text -notmatch 'InitializeSetup: app mutex held|PTB setup:|PTB update:|PTB relaunch:') 'minVersion.noCode' 'no [Code] line in the setup log'
    Assert-That (-not $old.HasExited) 'minVersion.appUntouched' "the running app (pid $($old.Id)) was neither closed nor restarted"
    Assert-That ((Get-InstalledVersion) -eq $Version) 'minVersion.installUntouched' "version file $(Get-InstalledVersion)"
}

# A PokeTokenBar that never closes: a helper holds the app's mutex and has no window to answer WM_CLOSE. Silent Setup
# (the in-app update's switches) and the silent uninstaller must give up within their bound, say so in their log and
# leave everything as it was; nothing may wait for a click (a [Code] MsgBox ignores /SUPPRESSMSGBOXES).
function Start-AppMutexHolder {
    $h = Start-Process pwsh -ArgumentList '-NoProfile', '-Command', "`$m = [System.Threading.Mutex]::new(`$false, 'Local\PokeTokenBar-Team'); Start-Sleep -Seconds 600" -PassThru -WindowStyle Hidden
    for ($i = 0; $i -lt 50; $i++) {
        Start-Sleep -Milliseconds 200
        try { ([System.Threading.Mutex]::OpenExisting('Local\PokeTokenBar-Team')).Dispose(); return $h } catch { }
    }
    Stop-Process -Id $h.Id -Force -ErrorAction SilentlyContinue
    throw 'the helper did not create the app mutex'
}

Invoke-Scenario 'appDoesNotClose' {
    Install-Baseline 'appDoesNotClose'
    $before = Get-FolderHashes $PtbInstallDir
    $holder = Start-AppMutexHolder
    try {
        $log = Join-Path $LogDir 'app-does-not-close.log'
        $t0 = Get-Date
        $code = Invoke-Setup $setupNext (Get-UpdateSetupArgs $log) -TimeoutSec 120
        $secs = [int]((Get-Date) - $t0).TotalSeconds
        $text = Read-SetupLog $log
        Assert-That ($code -eq 1 -and $secs -ge 25 -and $secs -lt 60) 'appDoesNotClose.setupReturns' "silent Setup waited for the app, then ended by itself: exit $code after $secs s (the wait is 30 s)"
        Assert-That ($text -match 'PTB setup: PokeTokenBar did not close in \d+ s' -and $text -match 'PTB relaunch: no \(an instance is still running\)' -and $text -notmatch 'Dest filename:') 'appDoesNotClose.setupLog' 'did not close; relaunch: no (an instance is still running); no file written'
        Assert-That (-not (Get-Process -Name 'PokeTokenBar-Setup-*' -ErrorAction SilentlyContinue)) 'appDoesNotClose.noSetupLeft' 'no Setup process left'
        Assert-PreviousContents 'appDoesNotClose' $before
    } finally {
        Stop-Process -Id $holder.Id -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Scenario 'uninstallAppDoesNotClose' {
    Install-Baseline 'uninstallAppDoesNotClose'
    $holder = Start-AppMutexHolder
    try {
        $log = Join-Path $LogDir 'uninstall-app-does-not-close.log'
        $t0 = Get-Date
        $code = Invoke-Setup (Join-Path $PtbInstallDir 'unins000.exe') @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=`"$log`"") -TimeoutSec 120
        $secs = [int]((Get-Date) - $t0).TotalSeconds
        Start-Sleep -Seconds 2
        $text = Read-SetupLog $log
        Assert-That ($code -ne 0 -and $secs -ge 25 -and $secs -lt 60 -and (Test-Path $exe)) 'uninstallAppDoesNotClose.returns' "the silent uninstaller ended by itself: exit $code after $secs s; app folder kept: $(Test-Path $exe)"
        Assert-That ($text -match 'PTB uninstall: PokeTokenBar did not close in \d+ s') 'uninstallAppDoesNotClose.log' 'PTB uninstall: PokeTokenBar did not close'
    } finally {
        Stop-Process -Id $holder.Id -Force -ErrorAction SilentlyContinue
    }
}

# Started the way the app starts it: Setup's working folder (and so its loader's) is the install folder.
Invoke-Scenario 'fromAppFolder' {
    Install-Baseline 'fromAppFolder'
    $old, $null = Start-Installed
    $closes = Get-AppLogCount 'exit code=0 reason=closeRequest'
    $before = Get-FolderHashes $PtbInstallDir
    $log = Join-Path $LogDir 'from-app-folder.log'
    $code = Invoke-Setup $failCopy (Get-UpdateSetupArgs $log) -WorkingDirectory $PtbInstallDir
    $text = Read-SetupLog $log
    Assert-That ($code -eq 5) 'fromAppFolder.exit' "exit $code"
    Assert-OldClosed 'fromAppFolder' $old $closes
    Assert-PreviousContents 'fromAppFolder' $before
    Assert-Started 'fromAppFolder' $old $Version
    Assert-That ($text -match [regex]::Escape("PTB setup: working folder $PtbInstallDir") -and $text -match 'PTB update: copied the previous app to' -and $text -match 'PTB update: put the previous app back' -and $text -match 'PTB relaunch: started') 'fromAppFolder.setupLog' "Setup's working folder was the install folder; copied; put back; relaunch: started"
}

Invoke-Scenario 'failBeforeCopy' {
    Install-Baseline 'failBeforeCopy'
    $old, $null = Start-Installed
    $closes = Get-AppLogCount 'exit code=0 reason=closeRequest'
    $dups = Get-AppLogCount 'duplicate instance'
    $before = Get-FolderHashes $PtbInstallDir
    $log = Join-Path $LogDir 'fail-before-copy.log'
    $code = Invoke-Setup $failPrepare (Get-UpdateSetupArgs $log)
    $text = Read-SetupLog $log
    Assert-That ($code -eq 7) 'failBeforeCopy.exit' "exit $code"
    Assert-OldClosed 'failBeforeCopy' $old $closes
    $dest = ([regex]::Matches($text, 'Dest filename:')).Count
    Assert-That ($dest -eq 0) 'failBeforeCopy.noFileWritten' "'Dest filename' lines in the setup log: $dest"
    Assert-PreviousContents 'failBeforeCopy' $before
    Assert-Started 'failBeforeCopy' $old $Version
    Assert-That ((Get-AppLogCount 'duplicate instance') -eq $dups) 'failBeforeCopy.noSecondStart' "duplicate-instance lines $dups -> $(Get-AppLogCount 'duplicate instance')"
    Assert-That ($text -match 'PTB update: copied the previous app to' -and $text -match 'PTBTestFailInstall: stopping in PrepareToInstall' -and $text -match 'PTB update: nothing was installed; removing the copy' -and $text -match 'PTB relaunch: started') 'failBeforeCopy.setupLog' 'copied; PrepareToInstall stopped Setup; nothing was installed, copy removed; relaunch: started'
}

Invoke-Scenario 'failControl' {
    Install-Baseline 'failControl'
    $old, $null = Start-Installed
    $closes = Get-AppLogCount 'exit code=0 reason=closeRequest'
    $log = Join-Path $LogDir 'fail-control.log'
    $code = Invoke-Setup $failPrepare (Get-UpdateSetupArgs $log '0')
    $text = Read-SetupLog $log
    Assert-That ($code -eq 7) 'failControl.exit' "exit $code"
    Assert-OldClosed 'failControl' $old $closes
    Start-Sleep -Seconds 10
    $running = @(Get-Process PokeTokenBar -ErrorAction SilentlyContinue)
    Assert-That ($running.Count -eq 0) 'failControl.noRelaunch' "PokeTokenBar processes 10 s after Setup ended: $($running.Count)"
    Assert-That ($text -match 'PTB relaunch: no \(setup did not finish; PTBRELAUNCHONFAIL is not 1\)') 'failControl.setupLog' 'PTB relaunch: no (setup did not finish; PTBRELAUNCHONFAIL is not 1)'
}

Invoke-Scenario 'failDuringCopy' {
    Install-Baseline 'failDuringCopy'
    $old, $null = Start-Installed
    $closes = Get-AppLogCount 'exit code=0 reason=closeRequest'
    $before = Get-FolderHashes $PtbInstallDir
    $log = Join-Path $LogDir 'fail-during-copy.log'
    $code = Invoke-Setup $failCopy (Get-UpdateSetupArgs $log)
    $text = Read-SetupLog $log
    Assert-That ($code -eq 5) 'failDuringCopy.exit' "exit $code"
    Assert-OldClosed 'failDuringCopy' $old $closes
    Assert-PreviousContents 'failDuringCopy' $before
    Assert-Started 'failDuringCopy' $old $Version
    $written = ([regex]::Matches($text, 'Successfully installed the file')).Count
    $back = [regex]::Match($text, 'put the previous app back from .* \((\d+) files copied back, (\d+) unchanged\)')
    $ms = (Get-SetupLogTime $text 'PTB update: put the previous app back') - (Get-SetupLogTime $text 'Rolling back changes')
    Assert-That ($text -match 'Dest filename: .*\\PokeTokenBar\.exe' -and $written -gt 0 -and $text -match 'Rolling back changes' -and $back.Success -and $text -match 'PTB relaunch: started') 'failDuringCopy.setupLog' "$written files written (the exe among them) before the copy failed; Inno rolled back; $($back.Groups[1].Value) files copied back, $($back.Groups[2].Value) unchanged, rollback + restore $([int]$ms.TotalMilliseconds) ms; relaunch: started"
}

Invoke-Scenario 'inAppOrder' {
    Install-Baseline 'inAppOrder'
    $p, $h = Start-Installed
    Close-App $p $h  # the in-app update: the app has exited before Setup looks for it
    $before = Get-FolderHashes $PtbInstallDir
    $log = Join-Path $LogDir 'in-app-order.log'
    $code = Invoke-Setup $failCopy (Get-UpdateSetupArgs $log) -WorkingDirectory $PtbInstallDir
    $text = Read-SetupLog $log
    Assert-That ($code -eq 5 -and $text -match 'InitializeSetup: app mutex held = 0') 'inAppOrder.exit' "exit $code; app mutex free when Setup started: $($text -match 'InitializeSetup: app mutex held = 0')"
    Assert-PreviousContents 'inAppOrder' $before
    Assert-Started 'inAppOrder' $null $Version
}

Invoke-Scenario 'backupFails' {
    Install-Baseline 'backupFails'
    Set-Content -Path $aside -Value 'a file where the copy would go'  # the copy's folder cannot be made
    $old, $null = Start-Installed
    $closes = Get-AppLogCount 'exit code=0 reason=closeRequest'
    $before = Get-FolderHashes $PtbInstallDir
    $log = Join-Path $LogDir 'backup-fails.log'
    $code = Invoke-Setup $failCopy (Get-UpdateSetupArgs $log)
    $text = Read-SetupLog $log
    Assert-That ($code -eq 7) 'backupFails.exit' "exit $code"
    Assert-OldClosed 'backupFails' $old $closes
    $dest = ([regex]::Matches($text, 'Dest filename:')).Count
    $changed = Compare-FolderHashes $before (Get-FolderHashes $PtbInstallDir)
    Assert-That ($dest -eq 0 -and $changed.Count -eq 0) 'backupFails.nothingTouched' "'Dest filename' lines: $dest; files changed: $($changed.Count) of $($before.Count)"
    Remove-Item -Force $aside
    Assert-Started 'backupFails' $old $Version
    Assert-That ($text -match 'PTB update: could not copy the previous app' -and $text -match 'PTB relaunch: started') 'backupFails.setupLog' 'could not copy the previous app; nothing is changed; relaunch: started'
}

Invoke-Scenario 'lockedFile' {
    Install-Baseline 'lockedFile'
    $old, $null = Start-Installed
    $closes = Get-AppLogCount 'exit code=0 reason=closeRequest'
    # A .txt: Inno's Restart Manager filter (*.exe,*.dll,*.chm) does not look at it, so nothing closes the holder.
    $locked = Join-Path $PtbInstallDir 'licenses\THIRD-PARTY.txt'
    $holder = Start-Process pwsh -ArgumentList '-NoProfile', '-Command', "`$f = [System.IO.File]::Open('$locked', 'Open', 'Read', 'Read'); Start-Sleep -Seconds 600" -PassThru -WindowStyle Hidden
    try {
        $held = $false
        for ($i = 0; $i -lt 50 -and -not $held; $i++) {
            Start-Sleep -Milliseconds 200
            try { ([System.IO.File]::Open($locked, 'Open', 'ReadWrite', 'ReadWrite')).Close() } catch { $held = $true }
        }
        Assert-That $held 'lockedFile.held' "$locked is open in pid $($holder.Id) (read, share read)"
        $before = Get-FolderHashes $PtbInstallDir
        $log = Join-Path $LogDir 'locked-file.log'
        $code = Invoke-Setup $setupNext (Get-UpdateSetupArgs $log)
        $text = Read-SetupLog $log
        Assert-That ($code -eq 5) 'lockedFile.exit' "exit $code"
        Assert-OldClosed 'lockedFile' $old $closes
        Assert-PreviousContents 'lockedFile' $before
    } finally {
        Stop-Process -Id $holder.Id -Force -ErrorAction SilentlyContinue
    }
    Assert-Started 'lockedFile' $old $Version
    Assert-That ($text -match 'PTB update: copied the previous app to' -and $text -match 'Rolling back changes' -and $text -match 'PTB update: put the previous app back' -and $text -match 'PTB relaunch: started') 'lockedFile.setupLog' 'copied; the in-place copy stopped at the held file; put back; relaunch: started'
}

Invoke-Scenario 'failedRestore' {
    Install-Baseline 'failedRestore'
    $old, $null = Start-Installed
    $before = Get-FolderHashes $PtbInstallDir
    $log = Join-Path $LogDir 'failed-restore.log'
    $setup = Start-PausedSetup $failCopy $log
    # Paused after the exe: every file of the first [Files] entry is already the test payload's. Hold one of them.
    $held = Join-Path $PtbInstallDir 'swiftCore.dll'
    $holder = Start-Process pwsh -ArgumentList '-NoProfile', '-Command', "`$f = [System.IO.File]::Open('$held', 'Open', 'Read', 'Read'); Start-Sleep -Seconds 600" -PassThru -WindowStyle Hidden
    try {
        Start-Sleep -Seconds 3
        $code = Resume-Setup $setup
        $text = Read-SetupLog $log
        Assert-That ($code -eq 5) 'failedRestore.exit' "exit $code"
        Start-Sleep -Seconds 5
        $running = @(Get-Process PokeTokenBar -ErrorAction SilentlyContinue)
        Assert-That ($running.Count -eq 0) 'failedRestore.notStarted' "PokeTokenBar processes after a failed restore: $($running.Count)"
        Assert-That (Test-CompleteCopy) 'failedRestore.copyKept' "complete copy kept in $aside"
        Assert-That ($text -match 'PTB update: could not put back .*swiftCore\.dll' -and $text -match 'PTB update: could not put the previous app back; the complete copy stays' -and $text -match 'PTB relaunch: no \(the previous app could not be put back\)') 'failedRestore.setupLog' 'could not put back swiftCore.dll; the complete copy stays; relaunch: no (the previous app could not be put back)'
    } finally {
        Stop-Process -Id $holder.Id -Force -ErrorAction SilentlyContinue
    }
    # Recovery: the next Setup (vN again, as a user would run the release's installer) finishes from this state.
    Start-Sleep -Seconds 1
    $log2 = Join-Path $LogDir 'failed-restore-next.log'
    $code2 = Invoke-Setup $setupV @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/CURRENTUSER', '/NORESTART', '/NOLAUNCH=1', "/LOG=`"$log2`"")
    $text2 = Read-SetupLog $log2
    Assert-That ($code2 -eq 0 -and $text2 -match 'PTB update: put the left-over copy back \(app folder version "2\.5\.\d+", copy "2\.5\.\d+"; [1-9]\d* files copied back') 'failedRestore.nextSetupRecovers' "exit $code2; the kept copy put back first (same version in both: the folder was mixed), then the install finished"
    Assert-PreviousContents 'failedRestore.afterNextSetup' $before -AfterFinishedSetup
}

Invoke-Scenario 'twoSetups' {
    Install-Baseline 'twoSetups'
    $old, $null = Start-Installed
    $before = Get-FolderHashes $PtbInstallDir
    $logA = Join-Path $LogDir 'two-setups-first.log'
    $first = Start-PausedSetup $failCopy $logA -WorkingDirectory $PtbInstallDir
    $logB = Join-Path $LogDir 'two-setups-second.log'
    $codeB = Invoke-Setup $setupNext (Get-UpdateSetupArgs $logB)
    $textB = Read-SetupLog $logB
    $running = @(Get-Process PokeTokenBar -ErrorAction SilentlyContinue)
    Assert-That ($codeB -eq 1 -and $running.Count -eq 0 -and (Test-CompleteCopy)) 'twoSetups.secondStops' "second Setup exit $codeB; PokeTokenBar processes: $($running.Count); the first Setup's copy intact: $(Test-CompleteCopy)"
    Assert-That ($textB -match 'PTB setup: another PokeTokenBar Setup is running' -and $textB -match 'PTB relaunch: no \(another Setup is running\)' -and $textB -notmatch 'InitializeSetup: app mutex held') 'twoSetups.secondSetupLog' 'another PokeTokenBar Setup is running (before the app check); relaunch: no'
    $codeA = Resume-Setup $first
    $textA = Read-SetupLog $logA
    Assert-That ($codeA -eq 5) 'twoSetups.firstExit' "first Setup exit $codeA"
    Assert-PreviousContents 'twoSetups' $before
    Assert-Started 'twoSetups' $old $Version
}

Invoke-Scenario 'staleComplete' {
    Install-Baseline 'staleComplete'
    New-LeftOverCopy -CopyVersion '2.5.1'  # an older version's copy: the install after it wrote every file
    $old, $null = Start-Installed
    $log = Join-Path $LogDir 'stale-complete.log'
    $code = Invoke-Setup $setupNext (Get-UpdateSetupArgs $log)
    $text = Read-SetupLog $log
    Assert-That ($code -eq 0 -and -not (Test-Path $aside)) 'staleComplete.updated' "exit $code; copy left: $(Test-Path $aside)"
    Assert-That ($text -match "PTB update: removing a left-over copy of 2\.5\.1 \(the app folder has all of $([regex]::Escape($Version))\), result 1" -and $text -match 'PTB update: copied the previous app to') 'staleComplete.setupLog' "removing a left-over copy of 2.5.1 (the app folder has all of $Version); then the update copied the folder again"
    Assert-Started 'staleComplete' $old $NextVersion
}

Invoke-Scenario 'staleIncomplete' {
    Install-Baseline 'staleIncomplete'
    $before = Get-FolderHashes $PtbInstallDir
    New-LeftOverCopy
    Remove-Item -Force $exe  # as a Setup killed between deleting the exe and writing the new one would leave it
    $log = Join-Path $LogDir 'stale-incomplete.log'
    $code = Invoke-Setup $failPrepare (Get-UpdateSetupArgs $log)
    $text = Read-SetupLog $log
    Assert-That ($code -eq 7) 'staleIncomplete.exit' "exit $code"
    Assert-PreviousContents 'staleIncomplete' $before
    Assert-That ($text -match 'PTB update: put the left-over copy back \(app folder version' -and $text -match 'PTB relaunch: started') 'staleIncomplete.setupLog' 'put the left-over copy back (the exe was missing); relaunch: started'
    Assert-Started 'staleIncomplete' $null $Version
}

Invoke-Scenario 'killedMidCopy' {
    Install-Baseline 'killedMidCopy'
    $old, $null = Start-Installed
    $log = Join-Path $LogDir 'killed-mid-copy.log'
    $setup = Start-PausedSetup $failCopy $log
    Stop-Setups  # as power loss would: no rollback, no DeinitializeSetup
    Start-Sleep -Seconds 2
    $text = Read-SetupLog $log
    Assert-That ((Test-Path $exe) -and (Get-InstalledVersion) -eq $Version -and (Test-CompleteCopy)) 'killedMidCopy.folderLeft' "after the kill: exe present: $(Test-Path $exe); version file $(Get-InstalledVersion); complete copy beside it: $(Test-CompleteCopy)"
    $p, $h = Start-App $exe
    Start-Sleep -Seconds 2
    Assert-That (-not $p.HasExited) 'killedMidCopy.folderStarts' "the half-updated folder starts (pid $($p.Id)); it reports $(Get-InstalledVersion), so the update is offered again"
    Close-App $p $h
    $old, $null = Start-Installed
    $log2 = Join-Path $LogDir 'killed-mid-copy-next.log'
    $code = Invoke-Setup $setupNext (Get-UpdateSetupArgs $log2)
    $text2 = Read-SetupLog $log2
    Assert-That ($code -eq 0 -and -not (Test-Path $aside) -and $text2 -match 'PTB update: put the left-over copy back \(app folder version') 'killedMidCopy.nextSetupFinishes' "next Setup exit $code; the left-over copy put back first (the folder had the copy's version), then the update finished; copy left: $(Test-Path $aside)"
    Assert-Started 'killedMidCopy' $old $NextVersion
}

# The install fails after every file, the version file too, was written: all of it comes back.
Invoke-Scenario 'failLate' {
    Install-Baseline 'failLate'
    $old, $null = Start-Installed
    $closes = Get-AppLogCount 'exit code=0 reason=closeRequest'
    $before = Get-FolderHashes $PtbInstallDir
    $log = Join-Path $LogDir 'fail-late.log'
    $code = Invoke-Setup $failLate (Get-UpdateSetupArgs $log)
    $text = Read-SetupLog $log
    Assert-That ($code -eq 5) 'failLate.exit' "exit $code"
    Assert-OldClosed 'failLate' $old $closes
    Assert-PreviousContents 'failLate' $before
    Assert-Started 'failLate' $old $Version
    Assert-That ($text -match 'Dest filename: .*\\PokeTokenBar\.version' -and $text -match 'PTB update: put the previous app back') 'failLate.setupLog' 'the version file was written before the failure; put the previous app back'
}

# A complete left-over copy whose putting back fails: Setup stops (exit 7) before installing and starts nothing.
Invoke-Scenario 'leftOverRestoreFails' {
    Install-Baseline 'leftOverRestoreFails'
    New-LeftOverCopy  # the same version as the folder: put back first
    $differs = Join-Path $aside 'licenses\THIRD-PARTY.txt'
    $s = [System.IO.File]::Open($differs, 'Append'); try { $s.WriteByte(0) } finally { $s.Close() }  # so it must be copied back
    $old, $null = Start-Installed
    $holder = Start-Holder (Join-Path $PtbInstallDir 'licenses\THIRD-PARTY.txt') 'Read'
    try {
        $log = Join-Path $LogDir 'left-over-restore-fails.log'
        $code = Invoke-Setup $setupNext (Get-UpdateSetupArgs $log)
        $text = Read-SetupLog $log
        Assert-That ($code -eq 7) 'leftOverRestoreFails.exit' "exit $code"
        Start-Sleep -Seconds 5
        $running = @(Get-Process PokeTokenBar -ErrorAction SilentlyContinue)
        Assert-That ($running.Count -eq 0) 'leftOverRestoreFails.notStarted' "PokeTokenBar processes after the refusal: $($running.Count)"
        Assert-That (Test-CompleteCopy) 'leftOverRestoreFails.copyKept' "the complete copy stays in $aside"
        Assert-That ($text -match 'PTB update: could not put the left-over copy back; it stays' -and $text -notmatch 'Dest filename:' -and $text -match 'PTB relaunch: no \(the previous app could not be put back\)') 'leftOverRestoreFails.setupLog' 'could not put the left-over copy back; nothing installed; relaunch: no (the previous app could not be put back)'
    } finally {
        Stop-Process -Id $holder.Id -Force -ErrorAction SilentlyContinue
    }
}

# An exe without a version file next to a complete copy: the folder is not complete, so the copy is put back first.
Invoke-Scenario 'noVersionFile' {
    Install-Baseline 'noVersionFile'
    $before = Get-FolderHashes $PtbInstallDir
    New-LeftOverCopy
    Remove-Item -Force $versionFile
    $log = Join-Path $LogDir 'no-version-file.log'
    $code = Invoke-Setup $failPrepare (Get-UpdateSetupArgs $log)
    $text = Read-SetupLog $log
    Assert-That ($code -eq 7) 'noVersionFile.exit' "exit $code"
    Assert-PreviousContents 'noVersionFile' $before
    Assert-That ($text -match 'PTB update: put the left-over copy back \(app folder version "",') 'noVersionFile.setupLog' 'put the left-over copy back (the folder had no version file)'
    Assert-Started 'noVersionFile' $null $Version
}

# The copy fails part way (a licence file nobody may open): the partial copy goes, nothing is touched, the old app again.
Invoke-Scenario 'partialCopy' {
    Install-Baseline 'partialCopy'
    $old, $null = Start-Installed
    $before = Get-FolderHashes $PtbInstallDir
    $holder = Start-Holder (Join-Path $PtbInstallDir 'licenses\THIRD-PARTY.txt') 'None'
    try {
        $log = Join-Path $LogDir 'partial-copy.log'
        $code = Invoke-Setup $setupNext (Get-UpdateSetupArgs $log)
        $text = Read-SetupLog $log
    } finally {
        Stop-Process -Id $holder.Id -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 1
    Assert-That ($code -eq 7) 'partialCopy.exit' "exit $code"
    $copied = [regex]::Matches($text, 'PTB update: could not copy .*THIRD-PARTY\.txt').Count
    Assert-That ($copied -eq 1 -and $text -match 'removing the partial copy: 1' -and $text -notmatch 'Dest filename:') 'partialCopy.setupLog' 'could not copy THIRD-PARTY.txt (after the files before it); removing the partial copy: 1; nothing installed'
    Assert-PreviousContents 'partialCopy' $before
    Assert-Started 'partialCopy' $old $Version
}

# The app folder gone next to a complete copy (deleted by hand after a failed restore): the copy is put back whole.
Invoke-Scenario 'appFolderMissing' {
    Install-Baseline 'appFolderMissing'
    $before = Get-FolderHashes $PtbInstallDir
    New-LeftOverCopy
    Remove-Item -Recurse -Force $PtbInstallDir
    $log = Join-Path $LogDir 'app-folder-missing.log'
    $code = Invoke-Setup $failPrepare (Get-UpdateSetupArgs $log)
    $text = Read-SetupLog $log
    Assert-That ($code -eq 7) 'appFolderMissing.exit' "exit $code"
    Assert-PreviousContents 'appFolderMissing' $before
    Assert-That ($text -match 'PTB update: put the left-over copy back \(app folder version "",') 'appFolderMissing.setupLog' 'put the left-over copy back into the recreated folder'
    Assert-Started 'appFolderMissing' $null $Version
}

# Setup killed inside the first [Files] entry (5 files written): the folder still starts; the next Setup puts the copy
# back first and finishes.
Invoke-Scenario 'killedFirstEntry' {
    Install-Baseline 'killedFirstEntry'
    $old, $null = Start-Installed
    $log = Join-Path $LogDir 'killed-first-entry.log'
    $setup = Start-PausedSetup $failCopy $log -At 'first'
    Stop-Setups
    Start-Sleep -Seconds 2
    $written = ([regex]::Matches((Read-SetupLog $log), 'Successfully installed the file')).Count
    Assert-That ((Test-Path $exe) -and (Get-InstalledVersion) -eq $Version -and (Test-CompleteCopy) -and $written -ge 5) 'killedFirstEntry.folderLeft' "after the kill: $written files written; exe present: $(Test-Path $exe); version file $(Get-InstalledVersion); complete copy beside it: $(Test-CompleteCopy)"
    $p, $h = Start-App $exe
    Start-Sleep -Seconds 2
    Assert-That (-not $p.HasExited) 'killedFirstEntry.folderStarts' "the half-updated folder starts (pid $($p.Id))"
    Close-App $p $h
    $old, $null = Start-Installed
    $log2 = Join-Path $LogDir 'killed-first-entry-next.log'
    $code = Invoke-Setup $setupNext (Get-UpdateSetupArgs $log2)
    $text2 = Read-SetupLog $log2
    Assert-That ($code -eq 0 -and -not (Test-Path $aside) -and $text2 -match 'PTB update: put the left-over copy back \(app folder version') 'killedFirstEntry.nextSetupFinishes' "next Setup exit $code; the copy put back first, then the update finished; copy left: $(Test-Path $aside)"
    Assert-Started 'killedFirstEntry' $old $NextVersion
}

# Setup killed while putting files back after a late failure (every file, the version file too, had been written): the
# version file goes back first, so the next Setup takes the folder for a mixed one and puts the copy back again.
Invoke-Scenario 'killedDuringRestore' {
    Install-Baseline 'killedDuringRestore'
    $old, $null = Start-Installed
    $before = Get-FolderHashes $PtbInstallDir
    $log = Join-Path $LogDir 'killed-during-restore.log'
    $setup = Start-PausedSetup $failLate $log -At 'restore'
    Stop-Setups
    Start-Sleep -Seconds 2
    $text = Read-SetupLog $log
    $changed = Compare-FolderHashes $before (Get-FolderHashes $PtbInstallDir)
    Assert-That ((Get-InstalledVersion) -eq $Version -and (Test-CompleteCopy) -and $changed.Count -gt 1) 'killedDuringRestore.folderLeft' "after the kill: version file $(Get-InstalledVersion) (put back first); $($changed.Count) files still the update's; complete copy beside it: $(Test-CompleteCopy)"
    $log2 = Join-Path $LogDir 'killed-during-restore-next.log'
    $code = Invoke-Setup $failPrepare (Get-UpdateSetupArgs $log2)  # the next Setup fails too: what it puts back must be vN
    $text2 = Read-SetupLog $log2
    Assert-That ($code -eq 7 -and $text2 -match 'PTB update: put the left-over copy back \(app folder version') 'killedDuringRestore.nextSetupPutsBack' "next Setup exit $code; put the left-over copy back"
    Assert-PreviousContents 'killedDuringRestore' $before
    Assert-Started 'killedDuringRestore' $null $Version
}

Invoke-Scenario 'updateOk' {
    Install-Baseline 'updateOk'
    $old, $null = Start-Installed
    $closes = Get-AppLogCount 'exit code=0 reason=closeRequest'
    $dups = Get-AppLogCount 'duplicate instance'
    $log = Join-Path $LogDir 'update-ok.log'
    $t0 = Get-Date
    $code = Invoke-Setup $setupNext (Get-UpdateSetupArgs $log)
    $wall = (Get-Date) - $t0
    $text = Read-SetupLog $log
    Assert-That ($code -eq 0) 'updateOk.exit' "exit $code"
    Assert-OldClosed 'updateOk' $old $closes
    Assert-That (-not (Test-Path $aside)) 'updateOk.copyRemoved' "copy left: $(Test-Path $aside)"
    Assert-Started 'updateOk' $old $NextVersion
    Assert-That ((Get-AppLogCount 'duplicate instance') -eq $dups) 'updateOk.noSecondStart' "duplicate-instance lines $dups -> $(Get-AppLogCount 'duplicate instance')"
    $copy = [regex]::Match($text, 'PTB update: copied the previous app to .* \((\d+) files, (\d+) bytes\)')
    $copyMs = (Get-SetupLogTime $text 'PTB update: copied the previous app to') - (Get-SetupLogTime $text 'PTB update: copying the previous app to')
    $delMs = (Get-SetupLogTime $text 'PTB relaunch: no (setup finished)') - (Get-SetupLogTime $text 'PTB update: setup finished')
    Assert-That ($copy.Success -and $text -match 'PTB update: setup finished' -and $text -match 'PTB update: removing the copy of the previous app .*, result 1' -and $text -match 'PTB relaunch: no \(setup finished\)') 'updateOk.setupLog' "copy $($copy.Groups[1].Value) files, $($copy.Groups[2].Value) bytes in $([int]$copyMs.TotalMilliseconds) ms; removing it took $([int]$delMs.TotalMilliseconds) ms; Setup wall time $([int]$wall.TotalSeconds) s; setup finished; relaunch: no"
}

Remove-Item -ErrorAction SilentlyContinue $probeIss
if ($failures.Count) { throw "failed-update-relaunch: $($failures.Count) scenario(s) failed: $($failures -join ', ')" }
'failed-update-relaunch: every scenario passed'
