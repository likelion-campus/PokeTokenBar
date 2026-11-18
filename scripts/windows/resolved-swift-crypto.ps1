# Prints the swift-crypto version SwiftPM resolved for this build (Package.resolved, which a clean build writes and a seed carries) and compares
# it with scripts/windows/build-pins.json ("swiftCrypto"). Package.swift floats it (`from: "3.0.0"`), so a new upstream patch release changes what a
# clean build links: this makes the version visible. Drift is a ::warning:: in ordinary runs and a failure with -Strict (release mode).
# The last output line is the version. Writes PTB_SWIFT_CRYPTO_VERSION to GITHUB_ENV.
# Bump: after reading the release notes of the new swift-crypto, edit build-pins.json and run windows.yml + light windows-app.
param([switch]$Strict)
$ErrorActionPreference = 'Stop'
$pin = (Get-Content (Join-Path $PSScriptRoot 'build-pins.json') -Raw | ConvertFrom-Json).swiftCrypto
if (-not (Test-Path Package.resolved)) { throw 'no Package.resolved: the build has not resolved its dependencies' }
$r = Get-Content Package.resolved -Raw | ConvertFrom-Json
$pins = if ($r.pins) { $r.pins } else { $r.object.pins }
$p = @($pins | Where-Object { ($_.identity -eq 'swift-crypto') -or ($_.package -eq 'swift-crypto') })
if ($p.Count -ne 1) { throw "Package.resolved lists swift-crypto $($p.Count) times" }
$v = [string]$p[0].state.version
if ($v -notmatch '^\d+\.\d+\.\d+$') { throw "swift-crypto resolved to '$v', expected a release version" }
if ($env:GITHUB_ENV) { "PTB_SWIFT_CRYPTO_VERSION=$v" >> $env:GITHUB_ENV }
if ($v -ne $pin) {
    $msg = "swift-crypto resolved to $v, pinned $pin in scripts/windows/build-pins.json (Package.swift floats it: from 3.0.0)"
    if ($Strict) { throw $msg }
    Write-Host "::warning title=swift-crypto drift::$msg"
}
"swift-crypto $v (pinned $pin)"
$v
