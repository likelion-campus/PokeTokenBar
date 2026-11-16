# The in-app update end to end (windows-app.yml, step id in-app-update, full level; stage 8 Task 6). The installed vN is
# started with CI=true --selftest-update-from <a loopback feed> (update-feed-server.ps1 in GitHub's JSON shape), so after its
# launch check it applies the offer exactly as the tray item's "Update" does: download through WinHTTP, the checks, the file,
# Setup started with the in-app switches, the app leaves; Setup starts the new version. Scenarios:
#   ok            vN+1 (the shipped next installer): the old app exits 0 (reason=update), Setup copies and finishes, vN+1 runs
#                 from the install folder as the same user with memberID and a setting kept, reports "update to vN+1 done",
#                 the Updates folder is emptied, the feed saw one JSON request and one download.
#   tampered      one byte flipped at the same size        -> refused by the digest
#   short / long  one byte less / one more than the size   -> refused by the length / by the download's cap (the size)
#   redirect      the download redirected to localhost     -> refused by the final host (the last hop's, not the first)
#   badurl        the JSON's address off the pattern       -> no installer; the release page would open, nothing downloaded
#   older         the feed offers vN-1                     -> not offered; the install path asked anyway refuses it, no download
#   setupRunning  Local\PokeTokenBar-Setup held            -> refused before the download; the app stays, the page stays closed
#   slowCancel    a slow download: the progress window shows progress (captured), its Cancel ends it; nothing left
#   failCopy      the TESTFAIL build that fails after the exe (exit 5): Setup puts vN back and starts it; that start says so once,
#                 nothing retries (one download, the same process), and a second "Update" opens the release page instead
#   failPrepare   the TESTFAIL build that stops before installing (exit 7): vN started again and told
# Each refusal: the app keeps running on vN, no Setup started, nothing under Updates, one log line with the reason.
# Every check prints one PASS/FAIL line; a failed scenario is reported and the next one still runs; the script fails at the end.
# From the repository root, after the full-level installer step (installer-out, installer-next, bundle-next):
#   ./scripts/windows/in-app-update.ps1 -Version <vN> -NextVersion <vN+1>
param(
    [Parameter(Mandatory)] [string]$Version,
    [Parameter(Mandatory)] [string]$NextVersion,
    [string]$LogDir = 'collected\in-app-update'
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/ci-helpers.ps1"
if (-not ([System.Management.Automation.PSTypeName]'PtbUpd').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class PtbUpd {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowW(string cls, string title);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowExW(IntPtr parent, IntPtr after, string cls, string title);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h, StringBuilder sb, int n);
    [DllImport("user32.dll")] static extern IntPtr SendMessageTimeoutW(IntPtr h, uint msg, IntPtr w, IntPtr l, uint flags, uint ms, out IntPtr result);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    public static string ChildText(IntPtr parent, string cls) {
        IntPtr c = FindWindowExW(parent, IntPtr.Zero, cls, null);
        if (c == IntPtr.Zero) return null;
        var sb = new StringBuilder(512); GetWindowTextW(c, sb, 512); return sb.ToString();
    }
    // BM_CLICK on the window's first Button (Cancel), sent with a timeout.
    public static bool ClickButton(IntPtr parent) {
        IntPtr b = FindWindowExW(parent, IntPtr.Zero, "Button", null);
        if (b == IntPtr.Zero) return false;
        IntPtr r; SendMessageTimeoutW(b, 0x00F5, IntPtr.Zero, IntPtr.Zero, 0x0002, 5000, out r); return true;
    }
}
'@
}

$root = (Get-Location).Path
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogDir = (Resolve-Path $LogDir).Path
$exe = Join-Path $PtbInstallDir 'PokeTokenBar.exe'
$versionFile = Join-Path $PtbInstallDir 'PokeTokenBar.version'
$logs = Join-Path $env:LOCALAPPDATA 'PokeTokenBar\Logs'
$appLog = Join-Path $logs 'PokeTokenBar.log'
$updates = Join-Path $env:LOCALAPPDATA 'PokeTokenBar\Updates'
$setupV = (Resolve-Path "installer-out\PokeTokenBar-Setup-$Version-win-x64.exe").Path
$setupNext = (Resolve-Path "installer-next\PokeTokenBar-Setup-$NextVersion-win-x64.exe").Path
$olderVersion = ($Version -replace '\d+$', { [string]([int]$_.Value - 1) })
$me = Get-ProcessIdentity $PID
$failures = [System.Collections.Generic.List[string]]::new()
$script:memberId = $null
"invoking shell: $me; CI=$env:CI; vN=$Version vN+1=$NextVersion vN-1=$olderVersion"
if ($env:CI -ne 'true') { throw 'the update flag needs CI=true (GitHub sets it)' }

# The TESTFAIL builds of vN+1 (the failed-update-relaunch step makes them; made here from bundle-next when it did not run).
$testName = "PokeTokenBar-Setup-$NextVersion-win-x64-TESTFAIL.exe"
function Get-TestBuild([string]$Name, [string]$Define) {
    $path = Join-Path $root "installer-$Name\$testName"
    if (Test-Path $path) { return $path }
    $out = (New-Item -ItemType Directory -Force -Path (Join-Path $root "installer-$Name")).FullName
    # Every /D goes through $isccArgs (the installer step's rule); iscc-defines.json records them per output folder.
    $isccArgs = @("/DSrcDir=$(Join-Path $root 'bundle-next')", "/DAppVer=$NextVersion", "/DOutDir=$out", "/D$Define=1")
    & (Get-Iscc) /Q @isccArgs (Join-Path $root 'installer\PokeTokenBar.iss')
    if ($LASTEXITCODE -ne 0) { throw "ISCC failed for $Name" }
    $record = if (Test-Path iscc-defines.json) { Get-Content iscc-defines.json -Raw | ConvertFrom-Json -AsHashtable } else { [ordered]@{} }
    $record["installer-$Name"] = @($isccArgs | ForEach-Object { ($_ -replace '^/D', '') -replace '=.*$', '' })
    $record | ConvertTo-Json | Set-Content iscc-defines.json -Encoding utf8NoBOM
    $path
}
$failCopy = Get-TestBuild 'fail-copy' 'PTBTestFailCopy'
$failPrepare = Get-TestBuild 'fail-prepare' 'PTBTestFailInstall'
"payloads: next $((Get-Item $setupNext).Length) bytes; fail-copy $((Get-Item $failCopy).Length); fail-prepare $((Get-Item $failPrepare).Length)"

function Get-InstalledVersion { if (Test-Path $versionFile) { (Get-Content $versionFile -Raw).Trim() } else { '<none>' } }
function Stop-Apps { Stop-Setups; Get-Process PokeTokenBar -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep -Milliseconds 500 }
# The app log, read while the app may hold it open for writing (File.ReadAllText shares only reading: a sharing violation).
function Read-AppLog {
    if (-not (Test-Path $appLog)) { return '' }
    $stream = [System.IO.File]::Open($appLog, 'Open', 'Read', 'ReadWrite, Delete')
    try { ([System.IO.StreamReader]::new($stream)).ReadToEnd() } finally { $stream.Dispose() }
}
# The app log written since $Mark (its length then); all of it when it rotated meanwhile.
function Get-LogSince([long]$Mark) {
    $text = Read-AppLog
    if ($text.Length -lt $Mark) { return $text }
    $text.Substring([int]$Mark)
}
function Get-LogMark { (Read-AppLog).Length }
function Wait-Until([scriptblock]$Condition, [int]$Seconds) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) { if (& $Condition) { return $true }; Start-Sleep -Milliseconds 250 }
    [bool](& $Condition)
}
function Get-UpdatesLeft { if (Test-Path $updates) { @(Get-ChildItem $updates -Recurse -Force -ErrorAction SilentlyContinue).Count } else { 0 } }
function Set-StatusChecksOff {
    $xml = Get-Content $PtbPlist -Raw
    $xml = $xml -replace '<key>statusChecksEnabled</key>\s*<(true|false)/>', ''
    $xml = $xml -replace '</dict>\s*</plist>\s*$', '<key>statusChecksEnabled</key><false/></dict></plist>'
    Set-Content -Path $PtbPlist -Value $xml -NoNewline -Encoding utf8NoBOM
}
function Test-StatusChecksOff { (Get-Content $PtbPlist -Raw) -match '<key>statusChecksEnabled</key>\s*<false/>' }
function Remove-HeldBack {
    if (-not (Test-Path $PtbPlist)) { return }
    $xml = Get-Content $PtbPlist -Raw
    Set-Content -Path $PtbPlist -Value ($xml -replace '<key>windows\.failedUpdateVersion</key>\s*<string>[^<]*</string>', '') -NoNewline -Encoding utf8NoBOM
}

# vN installed, nothing running.
function Install-Baseline([string]$Tag) {
    Stop-Apps
    $log = Join-Path $LogDir "$Tag-baseline.log"
    $code = Invoke-Setup $setupV @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/CURRENTUSER', '/NORESTART', '/NOLAUNCH=1', "/LOG=`"$log`"")
    if ($code -ne 0 -or (Get-InstalledVersion) -ne $Version) { throw "baseline install of ${Version}: exit $code, version $(Get-InstalledVersion)" }
}

function Start-Feed([string]$Tag, [string]$Mode, [string]$Payload, [string]$FeedVersion) {
    $portFile = Join-Path $LogDir "$Tag-port.txt"
    $requests = Join-Path $LogDir "$Tag-requests.log"
    Remove-Item -ErrorAction SilentlyContinue $portFile, $requests
    New-Item -ItemType File -Path $requests | Out-Null
    $p = Start-Process pwsh -ArgumentList '-NoProfile', '-File', (Join-Path $PSScriptRoot 'update-feed-server.ps1'), '-Payload', $Payload,
        '-Version', $FeedVersion, '-Mode', $Mode, '-PortFile', $portFile, '-LogFile', $requests -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput (Join-Path $LogDir "$Tag-feed.txt")
    if (-not (Wait-Until { Test-Path $portFile } 30)) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; throw 'the feed server did not start in 30 s' }
    [pscustomobject]@{ Process = $p; Port = [int](Get-Content $portFile -Raw); Requests = $requests; Version = $FeedVersion }
}
function Stop-Feed($Feed) { if ($Feed) { Stop-Process -Id $Feed.Process.Id -Force -ErrorAction SilentlyContinue } }
function Get-Requests($Feed) {
    $lines = @(Get-Content $Feed.Requests -ErrorAction SilentlyContinue)
    [pscustomobject]@{ Json = @($lines | Where-Object { $_ -match ' /releases/latest$' }).Count
                       Downloads = @($lines | Where-Object { $_ -match ' /releases/download/' }).Count; All = $lines }
}
# The installed app with the update flag (the feed on loopback); waits for its sink window.
function Start-Updating($Feed) { Start-App $exe @('--selftest-update-from', "http://127.0.0.1:$($Feed.Port)/releases/latest") }

function Invoke-Scenario([string]$Name, [scriptblock]$Body) {
    "---- $Name ----"
    $script:feed = $null
    # Each scenario starts from vN with no version held back, so one scenario's failure (a fault run's) does not spill over.
    try { Stop-Apps; Remove-HeldBack; if ((Get-InstalledVersion) -ne $Version) { Install-Baseline "$Name-reset" }; & $Body }
    catch { $failures.Add($Name); "FAIL $Name stopped: $($_.Exception.Message)" }
    finally {
        Stop-Feed $script:feed
        Stop-Apps
        if (Test-Path $appLog) { Copy-Item $appLog (Join-Path $LogDir "$Name-app.log") -Force }
    }
}

# A refusal: the app keeps running on vN, nothing started or left, one line with the reason.
# -Downloads: how many download requests the feed must have seen; -Page: 'opens' (logged instead of opened), 'closed' or 'none'.
function Assert-Refused([string]$Tag, $App, $Feed, [long]$Mark, [string]$Reason, [int]$Downloads, [string]$Page) {
    $p, $h = $App
    $seen = Wait-Until { (Get-LogSince $Mark).Contains($Reason) } 120
    Start-Sleep -Seconds 2
    $text = Get-LogSince $Mark
    $line = ($text -split "`r?`n" | Where-Object { $_.Contains($Reason) } | Select-Object -First 1)
    Assert-That $seen "$Tag.reasonLogged" "$line"
    Assert-That (-not $p.HasExited) "$Tag.appKeepsRunning" "pid $($p.Id) exited=$($p.HasExited); exit lines: $(([regex]::Matches($text, 'exit code=\d+ reason=\w+')).Value -join ', ')"
    Assert-That ((Get-InstalledVersion) -eq $Version -and $text -notmatch 'reason=update') "$Tag.versionUnchanged" "version file $(Get-InstalledVersion)"
    $setups = @(Get-Process -Name 'PokeTokenBar-Setup-*' -ErrorAction SilentlyContinue)
    Assert-That ($setups.Count -eq 0 -and $text -notmatch 'process: started') "$Tag.noSetup" "Setup processes: $($setups.Count); 'process: started' in the log: $($text -match 'process: started')"
    Assert-That ((Get-UpdatesLeft) -eq 0) "$Tag.nothingLeft" "entries under Updates: $(Get-UpdatesLeft)"
    $r = Get-Requests $Feed
    Assert-That ($r.Json -eq 1 -and $r.Downloads -eq $Downloads) "$Tag.feedRequests" "JSON $($r.Json), downloads $($r.Downloads) (expected 1, $Downloads): $($r.All -join ' | ')"
    $opens = $text -match 'selftest-update: the release page would open'
    $closed = $text -match 'update: the release page stays closed'
    $ok = switch ($Page) { 'opens' { $opens -and -not $closed } 'closed' { $closed -and -not $opens } default { -not $opens -and -not $closed } }
    Assert-That $ok "$Tag.releasePage" "expected '$Page': would open $opens, kept closed $closed"
    Close-App $p $h
}

Invoke-Scenario 'ok' {
    Install-Baseline 'ok'
    $p, $h = Start-App $exe
    Start-Sleep -Seconds 3
    $script:memberId = Get-MemberId
    Close-App $p $h
    Set-StatusChecksOff
    Assert-That ([bool]$script:memberId -and (Test-StatusChecksOff)) 'ok.settingsWritten' "team.memberID=$script:memberId; statusChecksEnabled=false"
    $setupLog = Join-Path $logs "update-$NextVersion.log"
    Remove-Item -ErrorAction SilentlyContinue $setupLog
    $script:feed = Start-Feed 'ok' 'ok' $setupNext $NextVersion
    $mark = Get-LogMark
    $t0 = Get-Date
    $old, $null = Start-Updating $script:feed
    $exited = $old.WaitForExit(120000)
    $text = Get-LogSince $mark
    Assert-That ($exited -and $old.ExitCode -eq 0 -and $text -match 'exit code=0 reason=update') 'ok.oldExitsForTheUpdate' "exited=$exited code=$(if ($exited) { $old.ExitCode }) after $([int]((Get-Date) - $t0).TotalSeconds) s; 'reason=update' logged: $($text -match 'exit code=0 reason=update')"
    Assert-That ($text -match "update: progress window shown for v$([regex]::Escape($NextVersion))" -and $text -match "process: started PokeTokenBar-Setup-$([regex]::Escape($NextVersion))-win-x64\.exe pid=\d+ in $([regex]::Escape($logs))") 'ok.progressAndSetupStarted' "progress window shown; Setup started with the logs folder as its working folder: $(($text -split "`r?`n" | Where-Object { $_ -match 'process: started' }) -join ' ')"
    $new = Wait-OtherApp -NotIds @($old.Id) -Seconds 60
    Assert-That ($null -ne $new) 'ok.newStarted' 'Setup started a PokeTokenBar process'
    $np, $nh = $new
    $setup = if (Test-Path $setupLog) { Get-Content $setupLog -Raw } else { '' }
    Assert-That ($setup -match 'PTB update: copied the previous app to' -and $setup -match 'PTB update: setup finished' -and $setup -notmatch [regex]::Escape("PTB setup: working folder $PtbInstallDir")) 'ok.setupLog' "update-$NextVersion.log: copied the previous app; setup finished; working folder outside the install folder: $(($setup -split "`r?`n" | Where-Object { $_ -match 'PTB setup: working folder' }) -join ' ')"
    Assert-That ($np.Path -eq $exe -and (Get-InstalledVersion) -eq $NextVersion) 'ok.newVersionRuns' "$($np.Path); version file $(Get-InstalledVersion)"
    $id = Get-ProcessIdentity $np.Id
    Assert-That ($id -eq $me) 'ok.sameUserAndToken' "app: $id; invoking shell: $me"
    Start-Sleep -Seconds 2
    Assert-That ((Get-MemberId) -eq $script:memberId -and (Test-StatusChecksOff)) 'ok.settingsKept' "memberID before=$script:memberId after=$(Get-MemberId); statusChecksEnabled still false: $(Test-StatusChecksOff)"
    $done = Wait-Until { (Get-LogSince $mark) -match "update: update to v$([regex]::Escape($NextVersion)) done" } 30
    Assert-That $done 'ok.doneLogged' "update to v$NextVersion done (logged by the new process)"
    $empty = Wait-Until { (Get-UpdatesLeft) -eq 0 } 30
    Assert-That $empty 'ok.updatesEmpty' "entries under Updates: $(Get-UpdatesLeft)"
    $r = Get-Requests $script:feed
    Assert-That ($r.Json -eq 1 -and $r.Downloads -eq 1) 'ok.feedRequests' "JSON $($r.Json), downloads $($r.Downloads): $($r.All -join ' | ')"
    Close-App $np $nh
}

# The refusals, on vN (each scenario goes back to it: the ok scenario left vN+1).
foreach ($case in @(
        @{ Tag = 'tampered'; Mode = 'tampered'; Reason = "not installed: the download's SHA-256 is not the release's digest"; Downloads = 1; Page = 'opens'; Told = $true },
        @{ Tag = 'short'; Mode = 'short'; Reason = "not installed: the download has $((Get-Item $setupNext).Length - 1) bytes, the release lists $((Get-Item $setupNext).Length)"; Downloads = 1; Page = 'opens'; Told = $true },
        @{ Tag = 'long'; Mode = 'long'; Reason = 'not installed: the download failed (URLError -1103)'; Downloads = 1; Page = 'opens'; Told = $true },
        @{ Tag = 'redirect'; Mode = 'redirect'; Reason = 'not installed: the download ended at localhost, not a GitHub download host'; Downloads = 2; Page = 'opens'; Told = $true },
        # No installer to download: "Update" opens the page as before stage 8, with the reason in the log (D8 step 2).
        @{ Tag = 'badurl'; Mode = 'badurl'; Reason = "in-app: the installer's address is not the release's download address"; Downloads = 0; Page = 'opens'; Told = $false })) {
    Invoke-Scenario $case.Tag {
        $script:feed = Start-Feed $case.Tag $case.Mode $setupNext $NextVersion
        $mark = Get-LogMark
        $app = Start-Updating $script:feed
        Assert-Refused $case.Tag $app $script:feed $mark $case.Reason $case.Downloads $case.Page
        $told = @((Get-LogSince $mark) -split "`r?`n" | Where-Object { $_ -match 'update: told the user: ' })
        Assert-That ($told.Count -eq [int]$case.Told) "$($case.Tag).toldTheUser" "expected $(if ($case.Told) { 'one balloon' } else { 'none' }): $($told -join ' ')"
    }
}

Invoke-Scenario 'older' {
    $script:feed = Start-Feed 'older' 'ok' $setupV $olderVersion
    $mark = Get-LogMark
    $app = Start-Updating $script:feed
    Assert-Refused 'older' $app $script:feed $mark "v$olderVersion not installed: the installer is not newer than the installed version" 0 'none'
    Assert-That ((Get-LogSince $mark) -match 'selftest-update: nothing offered') 'older.notOffered' 'the checker offered nothing; the install path was asked on its own'
}

Invoke-Scenario 'setupRunning' {
    $holder = Start-Process pwsh -ArgumentList '-NoProfile', '-Command', "`$m = [System.Threading.Mutex]::new(`$false, 'Local\PokeTokenBar-Setup'); Start-Sleep -Seconds 600" -PassThru -WindowStyle Hidden
    try {
        $held = Wait-Until { $m = $null; $ok = [System.Threading.Mutex]::TryOpenExisting('Local\PokeTokenBar-Setup', [ref]$m); if ($m) { $m.Dispose() }; $ok } 30
        Assert-That $held 'setupRunning.held' "Local\PokeTokenBar-Setup held by pid $($holder.Id)"
        $script:feed = Start-Feed 'setupRunning' 'ok' $setupNext $NextVersion
        $mark = Get-LogMark
        $app = Start-Updating $script:feed
        Assert-Refused 'setupRunning' $app $script:feed $mark 'not installed: another PokeTokenBar Setup is running' 0 'closed'
    } finally { Stop-Process -Id $holder.Id -Force -ErrorAction SilentlyContinue }
}

Invoke-Scenario 'slowCancel' {
    $script:feed = Start-Feed 'slowCancel' 'slow' $setupNext $NextVersion
    $mark = Get-LogMark
    $p, $h = Start-Updating $script:feed
    $found = Wait-Until { [PtbUpd]::FindWindowW('PokeTokenBarUpdateProgress', [NullString]::Value) -ne [IntPtr]::Zero } 60
    Assert-That $found 'slowCancel.windowShown' 'the progress window is up'
    $w = [PtbUpd]::FindWindowW('PokeTokenBarUpdateProgress', [NullString]::Value)
    Start-Sleep -Seconds 4
    $first = [PtbUpd]::ChildText($w, 'Static')
    Start-Sleep -Seconds 3
    $second = [PtbUpd]::ChildText($w, 'Static')
    $mb = { param($t) $m = [regex]::Match("$t", '([\d.]+) / ([\d.]+) MB'); if ($m.Success) { [double]$m.Groups[1].Value } else { -1 } }
    Assert-That ((& $mb $first) -gt 0 -and (& $mb $second) -gt (& $mb $first)) 'slowCancel.progressMoves' "'$($first -replace "`r?`n", ' | ')' then '$($second -replace "`r?`n", ' | ')'"
    # Captures for the PR (sample data, the CI runner): the progress window, then the tray menu opened meanwhile (its update
    # entry is the disabled "Updating…" row) next to it. The menu is opened as the shell opens it (the tray icon's callback
    # message, WM_CONTEXTMENU at a point) and closed with WM_CANCELMODE.
    Add-Type -AssemblyName System.Drawing, System.Windows.Forms
    $rect = New-Object PtbUpd+RECT
    if ([PtbUpd]::GetWindowRect($w, [ref]$rect)) {
        $bmp = New-Object System.Drawing.Bitmap ($rect.Right - $rect.Left), ($rect.Bottom - $rect.Top)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $bmp.Size)
        $bmp.Save((Join-Path $LogDir 'update-progress.png'), [System.Drawing.Imaging.ImageFormat]::Png)
        "captured the progress window: $($bmp.Width)x$($bmp.Height)"
        $x = [Math]::Max(0, $rect.Left - 300); $y = $rect.Top
        $null = [PtbCi]::PostMessageW($h, 0x8030 <# WM_APP + 0x30, the tray callback #>, [IntPtr](($y -shl 16) -bor $x), [IntPtr]0x007B <# WM_CONTEXTMENU #>)
        Start-Sleep -Milliseconds 1500
        $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $screen = New-Object System.Drawing.Bitmap $b.Width, $b.Height
        [System.Drawing.Graphics]::FromImage($screen).CopyFromScreen($b.Left, $b.Top, 0, 0, $screen.Size)
        $screen.Save((Join-Path $LogDir 'update-tray-menu.png'), [System.Drawing.Imaging.ImageFormat]::Png)
        "captured the screen with the tray menu open: $($b.Width)x$($b.Height)"
        $null = [PtbCi]::PostMessageW($h, 0x001F <# WM_CANCELMODE: closes the menu #>, [IntPtr]::Zero, [IntPtr]::Zero)
        Start-Sleep -Milliseconds 800
        # The popover opened over the running download (stage 7: the icon's select toggles it): the progress window stays and
        # the download goes on. Whether the popover takes the foreground here depends on the runner's foreground rules
        # (informational); the other order (Update in the popover's banner) closes the popover when the progress window
        # activates, as any non-owned window's activation does (WinPopover.deactivated).
        $null = [PtbCi]::PostMessageW($h, 0x8030, [IntPtr](($y -shl 16) -bor $x), [IntPtr]0x0400 <# NIN_SELECT #>)
        Start-Sleep -Milliseconds 1500
        $pop = [PtbUpd]::FindWindowW('PokeTokenBarPopover', [NullString]::Value)
        $popUp = $pop -ne [IntPtr]::Zero -and [PtbUpd]::IsWindowVisible($pop)
        $front = [PtbUpd]::GetForegroundWindow()
        "popover over the download (informational): shown=$popUp foreground=$(if ($front -eq $pop -and $popUp) { 'popover' } elseif ($front -eq $w) { 'progress window' } else { 'other' })"
        $both = New-Object System.Drawing.Bitmap $b.Width, $b.Height
        [System.Drawing.Graphics]::FromImage($both).CopyFromScreen($b.Left, $b.Top, 0, 0, $both.Size)
        $both.Save((Join-Path $LogDir 'update-with-popover.png'), [System.Drawing.Imaging.ImageFormat]::Png)
        $third = [PtbUpd]::ChildText($w, 'Static')
        Start-Sleep -Seconds 2
        $fourth = [PtbUpd]::ChildText($w, 'Static')
        Assert-That ([PtbUpd]::IsWindowVisible($w) -and (& $mb $fourth) -gt (& $mb $third) -and (& $mb $third) -ge (& $mb $second)) 'slowCancel.downloadGoesOnWithPopover' "popover shown=$popUp; progress '$($third -replace "`r?`n", ' | ')' then '$($fourth -replace "`r?`n", ' | ')'"
    }
    Assert-That ([PtbUpd]::ClickButton($w)) 'slowCancel.cancelClicked' 'Cancel pressed'
    $gone = Wait-Until { [PtbUpd]::FindWindowW('PokeTokenBarUpdateProgress', [NullString]::Value) -eq [IntPtr]::Zero } 15
    Assert-That $gone 'slowCancel.windowClosed' 'the progress window closed'
    Assert-Refused 'slowCancel' @($p, $h) $script:feed $mark 'not installed: cancelled by the user' 1 'closed'
    Assert-That ((Get-LogSince $mark) -notmatch 'told the user') 'slowCancel.noBalloon' 'nothing told after the user''s own cancel'
}

Invoke-Scenario 'failCopy' {
    Install-Baseline 'failCopy'
    $setupLog = Join-Path $logs "update-$NextVersion.log"
    Remove-Item -ErrorAction SilentlyContinue $setupLog
    $script:feed = Start-Feed 'failCopy' 'ok' $failCopy $NextVersion
    $mark = Get-LogMark
    $old, $null = Start-Updating $script:feed
    $exited = $old.WaitForExit(120000)
    Assert-That ($exited -and $old.ExitCode -eq 0 -and (Get-LogSince $mark) -match 'exit code=0 reason=update') 'failCopy.oldExitsForTheUpdate' "exited=$exited"
    $back = Wait-OtherApp -NotIds @($old.Id) -Seconds 90
    Assert-That ($null -ne $back) 'failCopy.previousStarted' 'Setup started the previous app again'
    $bp, $bh = $back
    $setup = if (Test-Path $setupLog) { Get-Content $setupLog -Raw } else { '' }
    Assert-That ($setup -match 'PTB update: put the previous app back' -and $setup -match 'PTB relaunch: started') 'failCopy.setupLog' "update-$NextVersion.log: put the previous app back; relaunch: started"
    Assert-That ($bp.Path -eq $exe -and (Get-InstalledVersion) -eq $Version) 'failCopy.previousVersionRuns' "$($bp.Path); version file $(Get-InstalledVersion)"
    $told = Wait-Until { (Get-LogSince $mark) -match "update: the update to v$([regex]::Escape($NextVersion)) did not install; this is v$([regex]::Escape($Version)).*told the user" } 30
    Assert-That $told 'failCopy.reportedOnce' "$(((Get-LogSince $mark) -split "`r?`n" | Where-Object { $_ -match 'did not install' }) -join ' ')"
    Start-Sleep -Seconds 20
    $text = Get-LogSince $mark
    $r = Get-Requests $script:feed
    $setups = @(Get-Process -Name 'PokeTokenBar-Setup-*' -ErrorAction SilentlyContinue)
    Assert-That (-not $bp.HasExited -and $r.Downloads -eq 1 -and $r.Json -eq 1 -and $setups.Count -eq 0 -and ([regex]::Matches($text, 'reason=update')).Count -eq 1 -and ([regex]::Matches($text, 'did not install;')).Count -eq 1) 'failCopy.noLoop' "20 s later: the same process runs ($($bp.Id), exited=$($bp.HasExited)); feed JSON $($r.Json), downloads $($r.Downloads); Setup processes $($setups.Count); update exits $(([regex]::Matches($text, 'reason=update')).Count); reports $(([regex]::Matches($text, 'did not install;')).Count)"
    $empty = Wait-Until { (Get-UpdatesLeft) -eq 0 } 30
    Assert-That $empty 'failCopy.updatesEmpty' "entries under Updates: $(Get-UpdatesLeft)"
    # A second "Update" for the version that just failed (a fresh feed offering it again): the release page, not a second
    # silent try.
    Close-App $bp $bh
    Stop-Feed $script:feed
    $script:feed = Start-Feed 'failCopySecond' 'ok' $failCopy $NextVersion
    $mark2 = Get-LogMark
    $again = Start-Updating $script:feed
    Assert-Refused 'failCopy.secondUpdate' $again $script:feed $mark2 "v$NextVersion did not install in-app last time; the release page opens instead" 0 'opens'
}

Invoke-Scenario 'failPrepare' {
    Install-Baseline 'failPrepare'
    $setupLog = Join-Path $logs "update-$NextVersion.log"
    Remove-Item -ErrorAction SilentlyContinue $setupLog
    $script:feed = Start-Feed 'failPrepare' 'ok' $failPrepare $NextVersion
    $mark = Get-LogMark
    $old, $null = Start-Updating $script:feed
    $exited = $old.WaitForExit(120000)
    Assert-That ($exited -and $old.ExitCode -eq 0) 'failPrepare.oldExitsForTheUpdate' "exited=$exited"
    $back = Wait-OtherApp -NotIds @($old.Id) -Seconds 90
    Assert-That ($null -ne $back) 'failPrepare.previousStarted' 'Setup started the previous app again'
    $bp, $bh = $back
    $setup = if (Test-Path $setupLog) { Get-Content $setupLog -Raw } else { '' }
    Assert-That ($setup -match 'PTBTestFailInstall: stopping in PrepareToInstall' -and $setup -match 'PTB relaunch: started' -and (Get-InstalledVersion) -eq $Version) 'failPrepare.setupLog' "stopped before installing (exit 7); relaunch: started; version file $(Get-InstalledVersion)"
    $told = Wait-Until { (Get-LogSince $mark) -match "update: the update to v$([regex]::Escape($NextVersion)) did not install.*told the user" } 30
    Assert-That $told 'failPrepare.reported' 'the previous app said so once'
    Close-App $bp $bh
}

Remove-HeldBack
if ($failures.Count) { throw "in-app-update: $($failures.Count) scenario(s) failed: $($failures -join ', ')" }
'in-app-update: every scenario passed'
