# Upgrade from the newest published Windows release older than this build (windows-app.yml, level full, after the uninstall
# check). On a fresh profile: install that release's installer (downloaded from GitHub, size and digest checked), start it,
# write a setting, close it; install this run's installer over it; the version file must be this version, team.memberID and
# the setting must survive and the installer must start the app again; then uninstall.
# One PASS/FAIL line per check. Writes result=success|first to $GITHUB_OUTPUT; "first" when no earlier release has a Windows
# installer. Reads only: the releases API (GITHUB_TOKEN only for the rate limit) and the asset download. Uploads nothing.
# Usage: upgrade-from-release.ps1 -Version 2.5.640 -Installer installer-out\PokeTokenBar-Setup-2.5.640-win-x64.exe [-Api <base>]
param(
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][string]$Installer,
    [string]$Api = 'https://api.github.com/repos/likelion-campus/PokeTokenBar'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'ci-helpers.ps1')
$Installer = (Resolve-Path $Installer).Path
$logs = Join-Path $PWD 'collected'
New-Item -ItemType Directory -Force -Path $logs | Out-Null
function Set-Result([string]$Result) { if ($env:GITHUB_OUTPUT) { "result=$Result" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8 } }

# 1. The newest release (by version) older than this one, not a draft or prerelease, with one asset named for its own version.
$headers = @{ Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
if ($env:GITHUB_TOKEN) { $headers['Authorization'] = "Bearer $env:GITHUB_TOKEN" }
$current = [version]$Version
$best = $null
$read = 0
for ($page = 1; $page -le 10; $page++) {
    $resp = Invoke-WebRequest -Uri "$Api/releases?per_page=100&page=$page" -Headers $headers -TimeoutSec 60
    $releases = @($resp.Content | ConvertFrom-Json)
    $read += $releases.Count
    foreach ($r in $releases) {
        if ($r.draft -or $r.prerelease) { continue }
        $tv = ([string]$r.tag_name) -replace '^v', ''
        if ($tv -notmatch '^\d+\.\d+\.\d+$' -or [version]$tv -ge $current) { continue }
        $asset = @($r.assets | Where-Object { $_.name -ceq "PokeTokenBar-Setup-$tv-win-x64.exe" })
        if ($asset.Count -ne 1) { continue }
        if (-not $best -or [version]$tv -gt $best.Version) { $best = [pscustomobject]@{ Version = [version]$tv; Tag = [string]$r.tag_name; Asset = $asset[0] } }
    }
    if ($releases.Count -lt 100) { break }
}
if (-not $best) {
    "releases read: $read; none older than $Version has a Windows installer"
    'PASS upgrade.fromRelease: first (no earlier Windows release)'
    Set-Result 'first'
    exit 0
}

# 2. Download it; the size and the digest must be the release's.
$a = $best.Asset
"releases read: $read; upgrading from $($best.Tag): $($a.name), $($a.size) bytes, $($a.digest), state=$($a.state)"
Assert-That ($a.state -eq 'uploaded') 'upgrade.fromRelease.assetState' "state=$($a.state)"
$digest = [regex]::Match([string]$a.digest, '^sha256:([0-9a-f]{64})$')
Assert-That $digest.Success 'upgrade.fromRelease.digestGiven' "digest=$($a.digest)"
$tmp = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
$old = Join-Path $tmp $a.name
Invoke-WebRequest -Uri $a.browser_download_url -OutFile $old -TimeoutSec 600
$length = (Get-Item $old).Length
$hash = (Get-FileHash -Algorithm SHA256 $old).Hash.ToLowerInvariant()
Assert-That ($length -eq [int64]$a.size) 'upgrade.fromRelease.size' "$length bytes downloaded, the release says $($a.size)"
Assert-That ($hash -eq $digest.Groups[1].Value) 'upgrade.fromRelease.digest' "sha256 $hash"

# 3. A fresh profile (the earlier steps' logs are kept in collected\), the old release installed, run once, a setting written.
Get-Process PokeTokenBar -ErrorAction SilentlyContinue | Stop-Process -Force
$data = Join-Path $env:LOCALAPPDATA 'PokeTokenBar'
if (Test-Path (Join-Path $data 'Logs')) { Copy-Item -Recurse (Join-Path $data 'Logs') (Join-Path $logs 'logs-before-upgrade-from-release') -Force }
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $PtbPlist, "$PtbPlist.bak", $data
Assert-That (-not (Test-Path $PtbInstallDir)) 'upgrade.fromRelease.freshInstallFolder' "$PtbInstallDir absent before the old install"
$code = Invoke-Setup $old @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/CURRENTUSER', '/NORESTART', '/NOLAUNCH=1', "/LOG=$logs\upgrade-from-release-old.log")
Assert-That ($code -eq 0) 'upgrade.fromRelease.oldInstall' "$($a.name) exit $code"
$versionFile = Join-Path $PtbInstallDir 'PokeTokenBar.version'
$oldVersion = (Get-Content $versionFile -Raw).Trim()
Assert-That ($oldVersion -eq "$($best.Version)") 'upgrade.fromRelease.oldVersion' "version file $oldVersion"
$exe = Join-Path $PtbInstallDir 'PokeTokenBar.exe'
$app, $h = Start-App $exe
Start-Sleep -Seconds 3
$member = Get-MemberId
Assert-That ([bool]$member) 'upgrade.fromRelease.memberIdWritten' "team.memberID=$member"
Close-App $app $h
$xml = Get-Content $PtbPlist -Raw
$xml = $xml -replace '<key>statusChecksEnabled</key>\s*<(true|false)/>', ''
$xml = $xml -replace '</dict>\s*</plist>\s*$', '<key>statusChecksEnabled</key><false/></dict></plist>'
Set-Content -Path $PtbPlist -Value $xml -NoNewline -Encoding utf8NoBOM
Assert-That ((Get-Content $PtbPlist -Raw) -match '<key>statusChecksEnabled</key>\s*<false/>') 'upgrade.fromRelease.settingWritten' 'statusChecksEnabled=false'

# 4. This run's installer over it: this version's files, the same memberID and setting, and the app started again.
$code = Invoke-Setup $Installer @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/CURRENTUSER', '/NORESTART', "/LOG=$logs\upgrade-from-release-new.log")
Assert-That ($code -eq 0) 'upgrade.fromRelease.exit' "exit $code"
$newVersion = (Get-Content $versionFile -Raw).Trim()
Assert-That ($newVersion -eq $Version) 'upgrade.fromRelease.versionFile' "version file $oldVersion -> $newVersion"
$fresh = $null
for ($i = 0; $i -lt 100 -and -not $fresh; $i++) { Start-Sleep -Milliseconds 200; $fresh = Get-Process PokeTokenBar -ErrorAction SilentlyContinue | Select-Object -First 1 }
Assert-That ($null -ne $fresh) 'upgrade.fromRelease.relaunched' 'a PokeTokenBar process runs after the silent install'
$null = $fresh.Handle
$h = [IntPtr]::Zero
for ($i = 0; $i -lt 100 -and $h -eq [IntPtr]::Zero; $i++) { Start-Sleep -Milliseconds 200; $h = Find-Sink }
Start-Sleep -Seconds 2
$after = Get-MemberId
Assert-That ($after -eq $member) 'upgrade.fromRelease.memberIdKept' "before=$member after=$after"
Assert-That ((Get-Content $PtbPlist -Raw) -match '<key>statusChecksEnabled</key>\s*<false/>') 'upgrade.fromRelease.settingKept' 'statusChecksEnabled still false'
Close-App $fresh $h

# 5. Uninstall, so the job ends as the uninstall check left it.
$code = Invoke-Setup (Join-Path $PtbInstallDir 'unins000.exe') @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=$logs\upgrade-from-release-uninstall.log")
Assert-That ($code -eq 0) 'upgrade.fromRelease.uninstall' "exit $code"
for ($i = 0; $i -lt 60 -and (Test-Path $PtbInstallDir); $i++) { Start-Sleep -Milliseconds 500 }
Assert-That (-not (Test-Path $PtbInstallDir)) 'upgrade.fromRelease.uninstalled' $PtbInstallDir
"PASS upgrade.fromRelease: $($best.Tag) -> v$Version kept memberID and the setting, and started the new version"
Set-Result 'success'
