# Release mode only, the last step of windows-app.yml (if: success()). Writes windows-release.json (schema 1) next to a copy
# of the shipped installer in -Out, the folder uploaded as the artifact windows-release. Fails, so that no artifact is left,
# unless: the checkout is release_sha, every version stamp equals release_version, the shipped installer was built with
# exactly the ISCC defines SrcDir, AppVer and OutDir and is not a test build (FileDescription), the level is full and
# every gate step succeeded.
# Reads env RELEASE_SHA, RELEASE_VERSION, PTB_LEVEL, PTB_STEPS (toJSON(steps)), GITHUB_SHA, GITHUB_RUN_ID, GITHUB_RUN_ATTEMPT,
# ImageVersion; and installer-out\, bundle\, iscc-defines.json (ISCC step), install-stamps.json (install step).
# Usage: release-manifest.ps1 [-Out windows-release]
param([string]$Out = 'windows-release')
$ErrorActionPreference = 'Stop'

# Manifest gate name -> step id in windows-app.yml. A task that adds a gate adds its line here and its name to
# REQUIRED_GATES in scripts/team_release.py, in the same PR.
$gateSteps = [ordered]@{
    bundleSelftest     = 'bundle-selftest'
    install            = 'install'
    upgrade            = 'upgrade'
    installedSelftest  = 'installed-selftest'
    idle               = 'idle'
    uninstall          = 'uninstall'
    upgradeFromRelease = 'upgrade-from-release'
    failedUpdateRelaunch = 'failed-update-relaunch'
    inAppUpdate        = 'in-app-update'
}

$problems = [System.Collections.Generic.List[string]]::new()
function Expect([bool]$ok, [string]$what) { if (-not $ok) { $problems.Add($what) } }

$sha = $env:RELEASE_SHA
$v = $env:RELEASE_VERSION
$head = (git rev-parse HEAD).Trim()
Expect ($head -eq $sha) "the checkout is $head, not release_sha $sha"
Expect ($env:PTB_LEVEL -eq 'full') "level is '$env:PTB_LEVEL', not full"

$steps = $env:PTB_STEPS | ConvertFrom-Json
$gates = [ordered]@{}
foreach ($g in $gateSteps.Keys) {
    $s = $steps.($gateSteps[$g])
    $outcome = if ($s) { [string]$s.outcome } else { 'missing' }
    if ($g -eq 'upgradeFromRelease' -and $outcome -eq 'success') { $outcome = [string]$s.outputs.result }
    $gates[$g] = $outcome
    $ok = $outcome -eq 'success' -or ($g -eq 'upgradeFromRelease' -and $outcome -eq 'first')
    Expect $ok "gate $g (step $($gateSteps[$g])) is '$outcome'"
}

$name = "PokeTokenBar-Setup-$v-win-x64.exe"
$built = @(Get-ChildItem installer-out -Filter *.exe | ForEach-Object Name)
Expect ($built.Count -eq 1 -and $built[0] -ceq $name) "installer-out holds '$($built -join ', ')', expected only $name"
$defines = @((Get-Content iscc-defines.json -Raw | ConvertFrom-Json).'installer-out')
Expect (($defines -join ',') -ceq 'SrcDir,AppVer,OutDir') "the shipped installer was built with the ISCC defines '$($defines -join ',')', expected exactly SrcDir,AppVer,OutDir"
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$setup = Join-Path $Out $name
Copy-Item (Join-Path installer-out $name) $setup -Force
$sha256 = (Get-FileHash -Algorithm SHA256 $setup).Hash.ToLowerInvariant()
Expect ($sha256 -eq (Get-FileHash -Algorithm SHA256 (Join-Path installer-out $name)).Hash.ToLowerInvariant()) 'the copied installer differs from installer-out'
$vi = (Get-Item $setup).VersionInfo
$fileVersion, $productVersion = $vi.FileVersion, $vi.ProductVersion | ForEach-Object { "$_".Trim([char[]]@([char]32, [char]0)) }  # Inno pads them
Expect ($fileVersion -eq "$v.0") "setup FileVersion '$fileVersion', expected $v.0"
Expect ($productVersion -eq $v) "setup ProductVersion '$productVersion', expected $v"
# A test build of the installer says TESTFAIL in its FileDescription (installer/PokeTokenBar.iss, PTBTest): the bytes, not
# only the name, tell a shipped installer from one.
$fileDescription = "$($vi.FileDescription)".TrimEnd([char[]]@([char]32, [char]0))
Expect ($fileDescription -ceq 'PokeTokenBar Setup') "setup FileDescription '$fileDescription', expected exactly 'PokeTokenBar Setup'"

$stamps = Get-Content install-stamps.json -Raw | ConvertFrom-Json
Expect ($stamps.fileVersion -eq "$v.0") "installed exe FileVersion '$($stamps.fileVersion)', expected $v.0"
Expect ($stamps.versionFile -eq $v) "installed PokeTokenBar.version '$($stamps.versionFile)', expected $v"
Expect ($stamps.uninstallDisplayVersion -eq $v) "Uninstall DisplayVersion '$($stamps.uninstallDisplayVersion)', expected $v"
$bundleVersion = (Get-Content bundle\PokeTokenBar.version -Raw).Trim()
Expect ($bundleVersion -eq $v) "bundle PokeTokenBar.version '$bundleVersion', expected $v"

$swiftText = (& swift --version 2>&1 | Out-String)
$swift = [regex]::Match($swiftText, 'Swift version (\d+(\.\d+)+)').Groups[1].Value
Expect ([bool]$swift) "no Swift version in: $($swiftText.Trim())"

$manifest = [ordered]@{
    schema      = 1
    sha         = $sha
    workflowSha = $env:GITHUB_SHA
    version     = $v
    level       = $env:PTB_LEVEL
    runId       = [int64]$env:GITHUB_RUN_ID
    runAttempt  = [int]$env:GITHUB_RUN_ATTEMPT
    runnerImage = $env:ImageVersion
    swift       = $swift
    installer   = [ordered]@{
        name           = $name
        size           = (Get-Item $setup).Length
        sha256         = $sha256
        fileVersion    = $fileVersion
        productVersion = $productVersion
        isccDefines    = $defines
    }
    app         = [ordered]@{
        fileVersion             = $stamps.fileVersion
        versionFile             = $stamps.versionFile
        uninstallDisplayVersion = $stamps.uninstallDisplayVersion
    }
    gates       = $gates
}
$json = $manifest | ConvertTo-Json -Depth 6
$json
if ($problems.Count -gt 0) {
    $problems | ForEach-Object { Write-Host "::error::release manifest: $_"; "FAIL release.manifest: $_" }
    Remove-Item -Recurse -Force $Out
    exit 1
}
Set-Content -Path (Join-Path $Out 'windows-release.json') -Value $json -Encoding utf8NoBOM
"PASS release.manifest: $name $sha256 ($($manifest.installer.size) bytes) for $sha, every gate passed"
