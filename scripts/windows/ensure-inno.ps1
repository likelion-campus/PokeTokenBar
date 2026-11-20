# Makes sure the Inno Setup the installers are built with is the pinned one (scripts/windows/build-pins.json, "innosetup"), installing it
# with chocolatey when the image carries another version (or none), and prints the path of ISCC.exe on its last line. Writes
# PTB_INNO_VERSION to GITHUB_ENV. Why install a pinned version rather than fail when the image differs: an image rollout would then turn every
# build red for a tool the installer checks do not depend on at the patch level; why not take whatever the image has: the installer is what
# people run, and the installer checks were calibrated with this version.
# Bump: change build-pins.json, run windows-app light once (the installer steps) and read docs/reference/windows-ci-build-seed.md, "Pinned build inputs".
$ErrorActionPreference = 'Stop'
$pin = (Get-Content (Join-Path $PSScriptRoot 'build-pins.json') -Raw | ConvertFrom-Json).innosetup
$exe = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'
function Get-InnoVersion {
    foreach ($k in 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1') {
        $v = (Get-ItemProperty $k -ErrorAction SilentlyContinue).DisplayVersion
        if ($v) { return [string]$v }
    }
    return ''
}
$have = if (Test-Path $exe) { Get-InnoVersion } else { '' }
if ($have -ne $pin) {
    "inno setup: image has '$have', pinned ${pin}: installing the pinned version"
    choco install innosetup --version=$pin -y --no-progress --allow-downgrade --force | Out-Host
    $have = Get-InnoVersion
}
if (-not (Test-Path $exe)) { throw "ISCC.exe not found at $exe" }
if ($have -ne $pin) { throw "Inno Setup is '$have' after the install, pinned $pin" }
"inno setup: $have (pinned)"
if ($env:GITHUB_ENV) { "PTB_INNO_VERSION=$have" >> $env:GITHUB_ENV }
$exe
