# Post-release smoke on a clean runner (windows-release-smoke.yml). Two phases, so the workflow can check out the release's
# tag between them (its scripts and fixtures) and a missing release or asset is reported before that checkout.
#   Acquire: get the installer and the digest it must have.
#     release  - GET releases/tags/v<Version>, the asset PokeTokenBar-Setup-<Version>-win-x64.exe, download it the way the
#                app does (no token), and check state, size and sha256 against what GitHub reports for the asset.
#     artifact - the windows-release artifact of a release-mode run (-ArtifactDir): the installer and windows-release.json;
#                size, sha256 and version come from that manifest.
#   Verify: the version stamped in the installer, silent install, the installed exe's version, the INSTALLED app's own
#     selftest from the install folder with a stripped Path, uninstall, and the folder is gone.
# One PASS/FAIL line per check. A failure ends the script with exit 1 and writes the reason to the job summary
# ($GITHUB_STEP_SUMMARY); the messages differ for: no release, no installer asset, wrong digest/size, wrong version.
# Reads only (the releases API and the asset download). Never writes a release.
# Usage: release-smoke.ps1 -Phase Acquire -Version 2.5.640 -Source release|artifact [-ArtifactDir dir] [-Api <base>]
#        release-smoke.ps1 -Phase Verify  -Version 2.5.640 [-FixtureSrc <repo root holding windows\selftest>]
param(
    [Parameter(Mandatory)][ValidateSet('Acquire', 'Verify')][string]$Phase,
    [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version,
    [ValidateSet('release', 'artifact')][string]$Source = 'release',
    [string]$ArtifactDir = '',
    [string]$FixtureSrc = '.',
    [string]$Api = 'https://api.github.com/repos/likelion-campus/PokeTokenBar'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'ci-helpers.ps1')
$work = Join-Path $PWD 'smoke'
New-Item -ItemType Directory -Force -Path $work | Out-Null
$stateFile = Join-Path $work 'acquired.json'
$assetName = "PokeTokenBar-Setup-$Version-win-x64.exe"

function Write-Summary([string]$Text) { if ($env:GITHUB_STEP_SUMMARY) { Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value $Text -Encoding utf8 } }
function Stop-Smoke([string]$Name, [string]$Reason) {
    Write-Host "FAIL ${Name}: $Reason"
    Write-Host "::error::$Name`: $Reason"
    Write-Summary "### Smoke FAILED for v$Version`n`n**$Name**: $Reason"
    exit 1
}
function Check([bool]$Ok, [string]$Name, [string]$Detail, [string]$Reason = $Detail) {
    if ($Ok) { Write-Host "PASS ${Name}: $Detail" } else { Stop-Smoke $Name $Reason }
}

try {
    if ($Phase -eq 'Acquire') {
        if ($Source -eq 'release') {
            $headers = @{ Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
            if ($env:GITHUB_TOKEN) { $headers['Authorization'] = "Bearer $env:GITHUB_TOKEN" }
            try {
                $rel = (Invoke-WebRequest -Uri "$Api/releases/tags/v$Version" -Headers $headers -TimeoutSec 60).Content | ConvertFrom-Json
            } catch {
                $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
                if ($code -eq 404) { Stop-Smoke 'smoke.release' "no release v$Version (the releases API answered 404)" }
                throw
            }
            Check (-not $rel.draft) 'smoke.release.published' "v$Version is published" "v$Version is still a draft"
            $asset = @($rel.assets | Where-Object { $_.name -ceq $assetName })
            if ($asset.Count -ne 1) {
                $names = (@($rel.assets | ForEach-Object { $_.name }) -join ', ')
                Stop-Smoke 'smoke.asset' "no Windows installer in v${Version}: expected exactly one asset named $assetName, the release has [$names]"
            }
            $a = $asset[0]
            "release v${Version}: $($a.name), $($a.size) bytes, $($a.digest), state=$($a.state)"
            Check ($a.state -eq 'uploaded') 'smoke.asset.state' "state=$($a.state)"
            $m = [regex]::Match([string]$a.digest, '^sha256:([0-9a-f]{64})$')
            Check $m.Success 'smoke.asset.digestGiven' "digest=$($a.digest)" "GitHub reports no sha256 digest for the asset ($($a.digest))"
            $expectedSha = $m.Groups[1].Value
            $expectedSize = [int64]$a.size
            $installer = Join-Path $work $a.name
            Invoke-WebRequest -Uri $a.browser_download_url -OutFile $installer -TimeoutSec 900   # no token: the app sends none
        } else {
            Check (-not [string]::IsNullOrEmpty($ArtifactDir) -and (Test-Path (Join-Path $ArtifactDir 'windows-release.json'))) 'smoke.artifact.manifest' "windows-release.json in $ArtifactDir" "no windows-release.json in the artifact ($ArtifactDir)"
            $man = Get-Content (Join-Path $ArtifactDir 'windows-release.json') -Raw | ConvertFrom-Json
            Check ($man.version -eq $Version) 'smoke.artifact.version' "manifest version $($man.version), requested $Version" "wrong version: the artifact is v$($man.version), v$Version was requested"
            $src = Join-Path $ArtifactDir $assetName
            if (-not (Test-Path $src)) { Stop-Smoke 'smoke.asset' "no Windows installer in the artifact: $assetName is missing" }
            $expectedSha = ([string]$man.installer.sha256).ToLowerInvariant()
            $expectedSize = [int64]$man.installer.size
            $installer = Join-Path $work $assetName
            Copy-Item $src $installer -Force
        }
        $length = (Get-Item $installer).Length
        $hash = (Get-FileHash -Algorithm SHA256 $installer).Hash.ToLowerInvariant()
        Check ($length -eq $expectedSize) 'smoke.size' "$length bytes, expected $expectedSize" "wrong size: $length bytes downloaded, expected $expectedSize"
        Check ($hash -eq $expectedSha) 'smoke.digest' "sha256 $hash" "wrong digest: the file is sha256 $hash, the $Source says $expectedSha"
        @{ installer = $installer; sha256 = $hash; source = $Source } | ConvertTo-Json | Set-Content $stateFile -Encoding utf8NoBOM
        exit 0
    }

    # ---- Verify ----
    Check (Test-Path $stateFile) 'smoke.state' $stateFile 'the Acquire phase left no state'
    $installer = (Get-Content $stateFile -Raw | ConvertFrom-Json).installer
    $vi = (Get-Item $installer).VersionInfo
    $fileVer = ([string]$vi.FileVersion).Trim(' ', [char]0)
    $prodVer = ([string]$vi.ProductVersion).Trim(' ', [char]0)
    Check ($fileVer -eq "$Version.0" -and $prodVer -eq $Version) 'smoke.installerVersion' "FileVersion='$fileVer' ProductVersion='$prodVer'" "wrong version: the installer is stamped FileVersion '$fileVer' / ProductVersion '$prodVer', v$Version was requested"

    Get-Process PokeTokenBar -ErrorAction SilentlyContinue | Stop-Process -Force
    Check (-not (Test-Path $PtbInstallDir)) 'smoke.cleanRunner' "$PtbInstallDir absent before the install" "the runner is not clean: $PtbInstallDir exists"
    $logs = Join-Path $PWD 'collected'
    New-Item -ItemType Directory -Force -Path $logs | Out-Null
    $code = Invoke-Setup $installer @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/CURRENTUSER', '/NORESTART', '/NOLAUNCH=1', "/LOG=$logs\smoke-install.log")
    Check ($code -eq 0) 'smoke.install' "exit $code"
    $exe = Join-Path $PtbInstallDir 'PokeTokenBar.exe'
    Check (Test-Path $exe) 'smoke.install.exe' $exe
    $iv = ([string](Get-Item $exe).VersionInfo.FileVersion).Trim(' ', [char]0)
    $verFile = (Get-Content (Join-Path $PtbInstallDir 'PokeTokenBar.version') -Raw).Trim()
    Check ($iv -eq "$Version.0" -and $verFile -eq $Version) 'smoke.installedVersion' "exe FileVersion='$iv' version file='$verFile'" "wrong version: the installed app is '$iv' / '$verFile', v$Version was requested"

    # The installed app's own selftest, from the install folder, with a Path that has no toolchain, on fixture data.
    $fx = Join-Path $work 'fixture'
    $proj = Join-Path $fx 'claude\projects\p'
    $state = Join-Path $fx 'state-installed'
    New-Item -ItemType Directory -Force -Path $proj, $state | Out-Null
    $fixture = Join-Path $FixtureSrc 'windows\selftest\claude\projects\p\s.jsonl'
    Check (Test-Path $fixture) 'smoke.fixture' $fixture "no selftest fixture at $fixture"
    $ts = (Get-Date).ToUniversalTime().AddSeconds(-30).ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    (Get-Content $fixture -Raw).Replace('__TIMESTAMP__', $ts) | Set-Content -NoNewline -Encoding utf8NoBOM -Path (Join-Path $proj 's.jsonl')
    $oldPath = $env:Path
    $env:Path = 'C:\Windows\System32;C:\Windows'
    $env:CLAUDE_CONFIG_DIR = Join-Path $fx 'claude'
    $env:PTB_STATE_DIR = $state
    $env:PTB_SELFTEST_EXPECT_TODAY_TOKENS = '3702'
    $out = Join-Path $work 'st-installed.json'
    $global:LASTEXITCODE = 0
    & (Join-Path $PSScriptRoot 'run-selftest.ps1') -Exe $exe -Out $out -ExpectStrategy cfRunLoopWithMessages
    if ($LASTEXITCODE -ne 0) {
        # Same single retry as the installed-selftest step of windows-app.yml (a modal-menu check flaked once); printed, not hidden.
        "::warning::installed selftest failed once; retrying"
        $global:LASTEXITCODE = 0
        & (Join-Path $PSScriptRoot 'run-selftest.ps1') -Exe $exe -Out $out -ExpectStrategy cfRunLoopWithMessages
    }
    $rc = $LASTEXITCODE
    $env:Path = $oldPath
    $failed = ''
    if (Test-Path $out) { $failed = ((Get-Content $out -Raw | ConvertFrom-Json).checks | Where-Object { -not $_.ok } | ForEach-Object { $_.name }) -join ', ' }
    Check ($rc -eq 0) 'smoke.selftest' "the installed app's selftest passed" "the installed app's selftest failed (exit $rc; failing checks: $failed)"

    # Uninstall and confirm it is gone.
    Get-Process PokeTokenBar -ErrorAction SilentlyContinue | Stop-Process -Force
    $code = Invoke-Setup (Join-Path $PtbInstallDir 'unins000.exe') @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=$logs\smoke-uninstall.log")
    Check ($code -eq 0) 'smoke.uninstall' "exit $code"
    for ($i = 0; $i -lt 60 -and (Test-Path $PtbInstallDir); $i++) { Start-Sleep -Milliseconds 500 }
    Check (-not (Test-Path $PtbInstallDir)) 'smoke.uninstalled' "$PtbInstallDir is gone" "uninstall left $PtbInstallDir behind"
    Write-Host "PASS smoke: v$Version installed, its own selftest passed from the install folder, uninstalled"
    Write-Summary "### Smoke passed for v$Version`n`nSource: $Source. Installer sha256 verified, version stamps $Version, installed selftest passed, uninstalled."
} catch {
    Stop-Smoke 'smoke.error' "$($_.Exception.Message)"
}
