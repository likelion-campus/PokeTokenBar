# A failed update brings the old app back (windows-app.yml, step id failed-update-relaunch, full level).
# Setup runs as the in-app update will run it (stage 8 D8 step 6: /SILENT /SUPPRESSMSGBOXES /NORESTART /CURRENTUSER
# /PTBRELAUNCHONFAIL=1 /LOG="..."), over the installed vN while it runs. Scenarios:
#   wizard          a first install as a double-click runs it (the wizard, clicked through with UI Automation): no
#                   previous app, no relaunch from [Code], and the Finish page starts the app.
#   fresh           a first install with the CI steps' silent switches: no previous app, nothing started.
#   minVersion      a copy of the shipped script with MinVersion one build above this runner: Setup refuses (exit 1)
#                   before any [Code] runs, so it neither closes the running app nor starts one.
#   failBeforeCopy  test build PTBTestFailInstall: exit 7; the app was closed, no file was touched, and the same
#                   version starts again once, as the invoking user, with the same memberID and setting.
#   failControl     the same with /PTBRELAUNCHONFAIL=0: nothing starts.
#   failDuringCopy  test build PTBTestFailCopy (fails after the exe was written): exit 5; the previous folder is back
#                   with the same file ids, and it starts again.
#   lockedFile      the SHIPPED vN+1 installer while a licence file is held open: the folder cannot move aside, the
#                   in-place copy fails (exit 5), the exe and version file are untouched, and vN starts again.
#   updateOk        the shipped vN+1 installer: exit 0; one vN+1 process (from [Run]), no second start, the
#                   moved-aside folder removed.
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
$build = [Environment]::OSVersion.Version.Build
$me = Get-ProcessIdentity $PID
$failures = [System.Collections.Generic.List[string]]::new()
"invoking shell: $me; Windows $([Environment]::OSVersion.Version)"

function Get-InstalledVersion { if (Test-Path $versionFile) { (Get-Content $versionFile -Raw).Trim() } else { '<none>' } }
function Get-AppLogCount([string]$Text) { if (Test-Path $appLog) { ([regex]::Matches((Get-Content $appLog -Raw), [regex]::Escape($Text))).Count } else { 0 } }
function Stop-Apps { Get-Process PokeTokenBar -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep -Milliseconds 500 }
function Read-SetupLog([string]$Path) {
    $text = if (Test-Path $Path) { Get-Content $Path -Raw } else { '' }
    # The lines that tell what Setup did, for the job log.
    foreach ($line in $text -split "`r?`n") {
        if ($line -match 'PTB update:|PTB relaunch:|PTBTest|InitializeSetup|Rolling back|suppressed message box|User canceled|Installation process succeeded|Setup version:|Windows version:|does not support') { "  setup: $line" | Write-Host }
    }
    $text
}
function Set-StatusChecksOff {
    $xml = Get-Content $PtbPlist -Raw
    $xml = $xml -replace '<key>statusChecksEnabled</key>\s*<(true|false)/>', ''
    $xml = $xml -replace '</dict>\s*</plist>\s*$', '<key>statusChecksEnabled</key><false/></dict></plist>'
    Set-Content -Path $PtbPlist -Value $xml -NoNewline -Encoding utf8NoBOM
}
function Test-StatusChecksOff { (Get-Content $PtbPlist -Raw) -match '<key>statusChecksEnabled</key>\s*<false/>' }

# vN installed (an update vN over vN through the same Setup), nothing running.
function Install-Baseline([string]$Tag) {
    Stop-Apps
    $log = Join-Path $LogDir "$Tag-baseline.log"
    $code = Invoke-Setup $setupV @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/CURRENTUSER', '/NORESTART', '/NOLAUNCH=1', "/LOG=`"$log`"")
    if ($code -ne 0 -or (Get-InstalledVersion) -ne $Version) { throw "baseline install of ${Version}: exit $code, version $(Get-InstalledVersion)" }
}

function Start-Installed {
    $p, $h = Start-App $exe
    Start-Sleep -Seconds 2
    @($p, $h)
}

function Assert-OldClosed([string]$Tag, $Old, [int]$ClosesBefore) {
    $after = Get-AppLogCount 'exit code=0 reason=closeRequest'
    Assert-That ($Old.HasExited -and $Old.ExitCode -eq 0 -and $after -eq $ClosesBefore + 1) "$Tag.oldClosed" "old pid $($Old.Id) exited=$($Old.HasExited) code=$($Old.ExitCode); closeRequest exit lines $ClosesBefore -> $after"
}

# The one app process Setup started: from the install folder, the expected version, the invoking user and token,
# memberID and the setting kept. Closes it.
function Assert-Started([string]$Tag, $Old, [string]$ExpectVersion) {
    $new = Wait-OtherApp -NotIds @($Old.Id) -Seconds 30
    Assert-That ($null -ne $new) "$Tag.started" 'a PokeTokenBar process started after Setup closed the old one'
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

function Invoke-Scenario([string]$Name, [scriptblock]$Body) {
    "---- $Name ----"
    try { & $Body }
    catch { $failures.Add($Name); "FAIL $Name stopped: $($_.Exception.Message)" }
    finally { Stop-Apps }
}

# The test builds (and the MinVersion probe), from bundle-next, side by side.
$iscc = Get-Iscc
"ISCC: $iscc (the Inno version is the 'Setup version' line of each setup log)"
$shipped = Get-Content (Join-Path $root 'installer\PokeTokenBar.iss') -Raw
$probeIss = Join-Path $root 'installer\ptb-minversion-probe.iss'
Set-Content -Path $probeIss -NoNewline -Value ($shipped -replace '(?m)^MinVersion=10\.0\.19045(\r?)$', "MinVersion=10.0.$($build + 1)`$1")
$builds = @(
    @{ Name = 'fail-prepare'; Defines = @('/DPTBTestFailInstall=1'); Iss = (Join-Path $root 'installer\PokeTokenBar.iss') },
    @{ Name = 'fail-copy'; Defines = @('/DPTBTestFailCopy=1'); Iss = (Join-Path $root 'installer\PokeTokenBar.iss') },
    @{ Name = 'minversion-probe'; Defines = @(); Iss = $probeIss }
)
$src = (Resolve-Path bundle-next).Path
$compiled = $builds | ForEach-Object -ThrottleLimit 3 -Parallel {
    $out = (New-Item -ItemType Directory -Force -Path (Join-Path $using:root "installer-$($_.Name)")).FullName
    $text = & $using:iscc /Q "/DSrcDir=$($using:src)" "/DAppVer=$($using:NextVersion)" "/DOutDir=$out" @($_.Defines) $_.Iss 2>&1 | Out-String
    [pscustomobject]@{ Name = $_.Name; Code = $LASTEXITCODE; Out = $out; Text = $text }
}
foreach ($c in $compiled) { if ($c.Code -ne 0) { $c.Text; throw "ISCC failed for $($c.Name) (exit $($c.Code))" } }
$out = @{}; foreach ($c in $compiled) { $out[$c.Name] = $c.Out }
$failPrepare = Join-Path $out['fail-prepare'] "PokeTokenBar-Setup-$NextVersion-win-x64-TESTFAIL.exe"
$failCopy = Join-Path $out['fail-copy'] "PokeTokenBar-Setup-$NextVersion-win-x64-TESTFAIL.exe"
$probe = Join-Path $out['minversion-probe'] "PokeTokenBar-Setup-$NextVersion-win-x64.exe"
$names = foreach ($c in $compiled) { (Get-ChildItem $c.Out -Filter *.exe).Name -join ',' }
Assert-That ((Test-Path $failPrepare) -and (Test-Path $failCopy) -and (Test-Path $probe)) 'build.testInstallers' "test builds carry TESTFAIL in the name: $($names -join '; ')"

Invoke-Scenario 'wizard' {
    Stop-Apps
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
    Stop-Apps
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
    Assert-That ((Get-Content $probeIss -Raw) -match "(?m)^MinVersion=10\.0\.$($build + 1)\r?$") 'minVersion.probeScript' "the probe is the shipped script with MinVersion=10.0.$($build + 1) (this runner: build $build)"
    Install-Baseline 'minVersion'
    $old, $null = Start-Installed
    $log = Join-Path $LogDir 'minversion-probe.log'
    $code = Invoke-Setup $probe (Get-UpdateSetupArgs $log)
    $text = Read-SetupLog $log
    Assert-That ($code -eq 1) 'minVersion.exit' "exit $code"
    Assert-That ($text -match 'does not support the version of Windows') 'minVersion.refused' 'This program does not support the version of Windows (suppressed message box)'
    Assert-That ($text -notmatch 'InitializeSetup: app mutex held|PTB update:|PTB relaunch:') 'minVersion.noCode' 'no [Code] line in the setup log'
    Assert-That (-not $old.HasExited) 'minVersion.appUntouched' "the running app (pid $($old.Id)) was neither closed nor restarted"
    Assert-That ((Get-InstalledVersion) -eq $Version) 'minVersion.installUntouched' "version file $(Get-InstalledVersion)"
}

Invoke-Scenario 'failBeforeCopy' {
    Install-Baseline 'failBeforeCopy'
    $old, $null = Start-Installed
    $closes = Get-AppLogCount 'exit code=0 reason=closeRequest'
    $dups = Get-AppLogCount 'duplicate instance'
    $ids = Get-FolderFileIds $PtbInstallDir
    $log = Join-Path $LogDir 'fail-before-copy.log'
    $code = Invoke-Setup $failPrepare (Get-UpdateSetupArgs $log)
    $text = Read-SetupLog $log
    Assert-That ($code -eq 7) 'failBeforeCopy.exit' "exit $code"
    Assert-OldClosed 'failBeforeCopy' $old $closes
    $changed = Compare-FolderFileIds $ids (Get-FolderFileIds $PtbInstallDir)
    $dest = ([regex]::Matches($text, 'Dest filename:')).Count
    Assert-That ($changed.Count -eq 0 -and $dest -eq 0) 'failBeforeCopy.noFileTouched' "files with a new id: $($changed.Count) of $($ids.Count); 'Dest filename' lines in the setup log: $dest"
    Assert-Started 'failBeforeCopy' $old $Version
    Assert-That ((Get-AppLogCount 'duplicate instance') -eq $dups) 'failBeforeCopy.noSecondStart' "duplicate-instance lines $dups -> $(Get-AppLogCount 'duplicate instance')"
    Assert-That ($text -match 'PTBTestFailInstall: stopping in PrepareToInstall' -and $text -match 'PTB relaunch: started') 'failBeforeCopy.setupLog' 'PrepareToInstall stopped Setup; DeinitializeSetup: PTB relaunch: started'
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
    $ids = Get-FolderFileIds $PtbInstallDir
    $log = Join-Path $LogDir 'fail-during-copy.log'
    $code = Invoke-Setup $failCopy (Get-UpdateSetupArgs $log)
    $text = Read-SetupLog $log
    Assert-That ($code -eq 5) 'failDuringCopy.exit' "exit $code"
    Assert-OldClosed 'failDuringCopy' $old $closes
    $changed = Compare-FolderFileIds $ids (Get-FolderFileIds $PtbInstallDir)
    Assert-That ($changed.Count -eq 0 -and -not (Test-Path $aside)) 'failDuringCopy.previousFolderBack' "files with a new id: $($changed.Count) of $($ids.Count) ($(($changed | Select-Object -First 6) -join ', ')); $aside left: $(Test-Path $aside)"
    Assert-Started 'failDuringCopy' $old $Version
    $written = ([regex]::Matches($text, 'Successfully installed the file')).Count
    Assert-That ($text -match 'PTB update: moved the previous app aside' -and $text -match 'Dest filename: .*\\PokeTokenBar\.exe' -and $written -gt 0 -and $text -match 'Rolling back changes') 'failDuringCopy.failedAfterTheExe' "the previous folder moved aside; $written files written (the exe among them) before the copy failed; Inno rolled back"
    Assert-That ($text -match 'PTB update: put the previous app back' -and $text -match 'PTB relaunch: started') 'failDuringCopy.setupLog' 'PTB update: put the previous app back; PTB relaunch: started'
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
        $ids = Get-FolderFileIds $PtbInstallDir
        $log = Join-Path $LogDir 'locked-file.log'
        $code = Invoke-Setup $setupNext (Get-UpdateSetupArgs $log)
        $text = Read-SetupLog $log
        Assert-That ($code -eq 5) 'lockedFile.exit' "exit $code"
        Assert-OldClosed 'lockedFile' $old $closes
        $changed = Compare-FolderFileIds $ids (Get-FolderFileIds $PtbInstallDir)
        Assert-That ($changed -notcontains 'PokeTokenBar.exe' -and $changed -notcontains 'PokeTokenBar.version') 'lockedFile.exeAndVersionKept' "exe replaced: $($changed -contains 'PokeTokenBar.exe'); version file replaced: $($changed -contains 'PokeTokenBar.version'); replaced in place before the failure and left so (Inno keeps no copy): $($changed.Count) of $($ids.Count) files ($(($changed | Select-Object -First 8) -join ', '))"
    } finally {
        Stop-Process -Id $holder.Id -Force -ErrorAction SilentlyContinue
    }
    Assert-Started 'lockedFile' $old $Version
    Assert-That ($text -match 'PTB update: could not move' -and $text -match 'Rolling back changes' -and $text -match 'PTB relaunch: started') 'lockedFile.setupLog' 'could not move the folder aside; updated in place; Inno rolled back; PTB relaunch: started'
}

Invoke-Scenario 'updateOk' {
    Install-Baseline 'updateOk'
    $old, $null = Start-Installed
    $closes = Get-AppLogCount 'exit code=0 reason=closeRequest'
    $dups = Get-AppLogCount 'duplicate instance'
    $log = Join-Path $LogDir 'update-ok.log'
    $code = Invoke-Setup $setupNext (Get-UpdateSetupArgs $log)
    $text = Read-SetupLog $log
    Assert-That ($code -eq 0) 'updateOk.exit' "exit $code"
    Assert-OldClosed 'updateOk' $old $closes
    Assert-That ($text -match 'PTB update: moved the previous app aside' -and $text -match 'PTB update: setup finished' -and $text -match 'PTB update: removing the previous app .*, result 1' -and $text -match 'PTB relaunch: no \(setup finished\)') 'updateOk.setupLog' 'moved aside; setup finished; previous folder removed; relaunch: no (setup finished)'
    Assert-That (-not (Test-Path $aside)) 'updateOk.previousRemoved' "$aside left: $(Test-Path $aside)"
    Assert-Started 'updateOk' $old $NextVersion
    Assert-That ((Get-AppLogCount 'duplicate instance') -eq $dups) 'updateOk.noSecondStart' "duplicate-instance lines $dups -> $(Get-AppLogCount 'duplicate instance')"
}

Remove-Item -ErrorAction SilentlyContinue $probeIss
if ($failures.Count) { throw "failed-update-relaunch: $($failures.Count) scenario(s) failed: $($failures -join ', ')" }
'failed-update-relaunch: every scenario passed'
