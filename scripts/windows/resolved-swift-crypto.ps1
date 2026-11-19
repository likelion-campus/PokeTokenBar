# Prints the swift-crypto version SwiftPM resolved for this build (Package.resolved, which a clean build writes and a seed carries) and compares
# it with scripts/windows/build-pins.json ("swiftCrypto"). Package.swift floats it (`from: "3.0.0"`), so a new upstream patch release changes what a
# clean build links: this makes the version visible. Drift is a ::warning:: in ordinary runs and a failure with -Strict (release mode).
# The last output line is the version. Writes PTB_SWIFT_CRYPTO_VERSION to GITHUB_ENV.
# Bump: after reading the release notes of the new swift-crypto, edit build-pins.json and run windows.yml + light windows-app.
# Missing or unreadable Package.resolved, or no (or two) swift-crypto pins, FAILS in both modes: a build that cannot say what it linked is broken.
# Tested by resolved-swift-crypto.tests.ps1 (CI: swift-crypto-rules.yml). -ResolvedPath/-PinsPath exist for that test.
param([switch]$Strict, [string]$ResolvedPath = 'Package.resolved', [string]$PinsPath = '')
$ErrorActionPreference = 'Stop'
if (-not $PinsPath) { $PinsPath = Join-Path $PSScriptRoot 'build-pins.json' }
$pin = (Get-Content $PinsPath -Raw | ConvertFrom-Json).swiftCrypto
if (-not $pin) { throw "no swiftCrypto in $PinsPath" }
if (-not (Test-Path $ResolvedPath)) { throw 'no Package.resolved: the build has not resolved its dependencies' }
try { $r = Get-Content $ResolvedPath -Raw | ConvertFrom-Json } catch { throw "Package.resolved is not JSON: $($_.Exception.Message)" }
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
